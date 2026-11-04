// Hardware drivers for Lua. Each one allocates only while in use.
#define DISABLE_CODE_FOR_RECEIVER  // IR is send-only on the Cardputer
#define SEND_PWM_BY_TIMER
#include <SD.h>  // before M5GFX so its file-drawing helpers are available
#include <M5Cardputer.h>
#include <IRremote.hpp>
#include <RadioLib.h>
#include <TinyGPSPlus.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <utility/PI4IOE5V6408_Class.hpp>
#include <driver/i2s_std.h>
// MP3 decoder: Layer III only, scalar code, and its ~15 KB scratch area on
// the heap instead of the stack (see the MINIMP3_SCRATCH patch in minimp3.h).
#define MINIMP3_IMPLEMENTATION
#define MINIMP3_ONLY_MP3
#define MINIMP3_NO_SIMD
static void *mp3Scratch = nullptr;
#define MINIMP3_SCRATCH mp3Scratch
#include <minimp3.h>
#include "hw.h"
#include "storage.h"
#include "usbdev.h"

static String str(lua_State *L, int i) { return String(luaL_checkstring(L, i)); }
static int num(lua_State *L, int i) { return (int)luaL_checknumber(L, i); }

// =============================================================== audio
// The mic and speaker share the codec's I2S bus, so only one runs at a time.
// Recording and playback stream to/from the SD card in a small task using two
// 2 KB buffers.
enum AudioMode { A_IDLE, A_REC, A_PLAY };
static volatile AudioMode aMode = A_IDLE;
static volatile bool aStop = false;
static TaskHandle_t aTask = nullptr;
static File aFile;
static uint32_t aRate = 16000;
static volatile uint32_t aSamples = 0, aTotal = 0;
static volatile bool aPaused = false;
static volatile int32_t aSeekTo = -1;     // seconds; the playback task seeks when it sees it
static size_t aDataStart = 0;             // where the audio starts in aFile (after headers/tags)
static bool aStereo = false;
static uint32_t spkLastUse = 0;
static const size_t ABUF = 1024;  // samples per buffer

// The ADV's mic goes through an ES8311 codec that shares its I2S pins with the
// speaker. M5Unified's Mic reads a constant value once the speaker has used the
// pins (IDF 5.5, espressif/esp-idf#18621), so the mic is driven here instead:
// reset the pins, reset and set up the codec's ADC, open our own I2S RX channel.
static i2s_chan_handle_t micRx = nullptr;
static uint32_t micRate = 0, micLastUse = 0;
static const uint8_t ES8311 = 0x18;

static void micClose() {
  if (!micRx) return;
  i2s_channel_disable(micRx);
  i2s_del_channel(micRx);
  micRx = nullptr;
  micRate = 0;
  M5.In_I2C.writeRegister8(ES8311, 0x0D, 0xFC, 400000);  // power down the analog side
}

static int micSlot = -1;  // 0 = left, 1 = right, -1 = average both

// Reads n mono samples at micRate.
static bool micRead(int16_t *out, size_t n) {
  int16_t in[256];  // 64 output samples per read
  while (n) {
    size_t want = n < 64 ? n : 64, got = 0;
    if (i2s_channel_read(micRx, in, want * 8, &got, 500) != ESP_OK || got < want * 8) return false;
    for (size_t i = 0; i < want; i++) {
      const int16_t *f = in + i * 4;  // L R L R
      *out++ = micSlot < 0 ? ((int)f[0] + f[1] + f[2] + f[3]) / 4 : ((int)f[micSlot] + f[2 + micSlot]) / 2;
    }
    n -= want;
  }
  micLastUse = millis();
  return true;
}

// Drops the codec's start-up transient (~150 ms), then listens for ~60 ms to
// see which slot carries the mic.
static void micPickSlot() {
  int16_t in[256];
  size_t got;
  for (int i = 0; i < 75; i++) i2s_channel_read(micRx, in, sizeof(in), &got, 500);
  uint32_t l = 0, r = 0;
  for (int i = 0; i < 30; i++) {
    if (i2s_channel_read(micRx, in, sizeof(in), &got, 500) != ESP_OK) break;
    for (size_t k = 0; k + 1 < got / 2; k += 2) { l += abs(in[k]); r += abs(in[k + 1]); }
  }
  micSlot = l > 4 * r ? 0 : r > 4 * l ? 1 : -1;
  usbdev::log(String("mic slots L=") + l + " R=" + r);
}

static void useSpeaker() {
  micClose();
  if (!M5Cardputer.Speaker.isRunning()) M5Cardputer.Speaker.begin();
  spkLastUse = millis();
}

static bool useMic(uint32_t rate) {
  micLastUse = millis();
  if (micRx && micRate == rate) return true;
  if (M5Cardputer.Speaker.isRunning()) M5Cardputer.Speaker.end();
  if (M5Cardputer.Mic.isRunning()) M5Cardputer.Mic.end();
  micClose();
  // Silence the speaker path first (DAC volume, output driver, DAC power):
  // resetting the codec while it is live pops. Speaker.begin() turns it back on.
  static const uint8_t quiet[][2] = {{0x32, 0x00}, {0x13, 0x00}, {0x12, 0x02}};
  for (auto &r : quiet) M5.In_I2C.writeRegister8(ES8311, r[0], r[1], 400000);
  delay(5);
  for (int p : {41, 42, 43, 46}) gpio_reset_pin((gpio_num_t)p);

  M5.In_I2C.writeRegister8(ES8311, 0x00, 0x1F, 400000);  // reset
  delay(20);
  static const uint8_t regs[][2] = {
      {0x00, 0x00}, {0x45, 0x00}, {0x00, 0x80},  // leave reset, power on
      {0x01, 0xBA}, {0x02, 0x18},                // MCLK from BCLK, x8
      {0x0A, 0x0C},                              // ADC out: I2S, 16-bit
      {0x0D, 0x01}, {0x0E, 0x02}, {0x12, 0x02},  // analog + ADC on, DAC off
      {0x14, 0x1A},                              // Mic1, preamp +30 dB
      {0x17, 0xBF}, {0x1C, 0x6A}};               // ADC 0 dB, remove DC
  for (auto &r : regs) M5.In_I2C.writeRegister8(ES8311, r[0], r[1], 400000);
  uint8_t id = M5.In_I2C.readRegister8(ES8311, 0xFD, 400000);

  // Stereo frames at twice the rate; micRead() averages pairs and uses the
  // slot the codec puts the ADC on (picked below). 8 KB of DMA = 64 ms, so a
  // slow SD write while recording doesn't drop samples.
  i2s_chan_config_t cc = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO, I2S_ROLE_MASTER);
  cc.dma_desc_num = 8;
  cc.dma_frame_num = 256;
  i2s_std_config_t sc = {
      .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(rate * 2),
      .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
      .gpio_cfg = {I2S_GPIO_UNUSED, GPIO_NUM_41, GPIO_NUM_43, I2S_GPIO_UNUSED, GPIO_NUM_46, {0, 0, 0}},
  };
  bool ok = i2s_new_channel(&cc, nullptr, &micRx) == ESP_OK;
  if (ok) ok = i2s_channel_init_std_mode(micRx, &sc) == ESP_OK && i2s_channel_enable(micRx) == ESP_OK;
  if (!ok && micRx) { i2s_del_channel(micRx); micRx = nullptr; }
  if (ok) micRate = rate;
  if (ok) micPickSlot();
  usbdev::log(String("mic begin ") + (ok ? "ok" : "FAILED") + " rate=" + rate + " codec id=0x" + String(id, HEX) +
              " slot=" + (micSlot < 0 ? "both" : micSlot ? "R" : "L"));
  return ok;
}

static void wavHeader(uint8_t *h, uint32_t rate, uint32_t dataBytes) {
  auto put32 = [&](int o, uint32_t v) { h[o] = v; h[o + 1] = v >> 8; h[o + 2] = v >> 16; h[o + 3] = v >> 24; };
  auto put16 = [&](int o, uint16_t v) { h[o] = v; h[o + 1] = v >> 8; };
  memcpy(h, "RIFF", 4); put32(4, 36 + dataBytes); memcpy(h + 8, "WAVEfmt ", 8);
  put32(16, 16); put16(20, 1); put16(22, 1); put32(24, rate); put32(28, rate * 2); put16(32, 2); put16(34, 16);
  memcpy(h + 36, "data", 4); put32(40, dataBytes);
}

static void recTask(void *) {
  // The I2S DMA buffers (32 ms) keep capturing while a block goes to the card.
  int16_t *buf = (int16_t *)malloc(ABUF * 2);
  int peak = 0;
  uint64_t sumAbs = 0;
  bool readOk = true;
  while (buf && !aStop && aSamples < aRate * 600) {  // 10 minutes max
    if (!(readOk = micRead(buf, ABUF))) break;
    for (size_t i = 0; i < ABUF; i++) {
      int v = abs(buf[i]);
      if (v > peak) peak = v;
      sumAbs += v;
    }
    aFile.write((uint8_t *)buf, ABUF * 2);
    aSamples = aSamples + ABUF;
  }
  usbdev::log(String("recording done: ") + aSamples + " samples (" + (aSamples / (aRate ? aRate : 1)) + " s) peak=" +
              peak + " avg=" + (uint32_t)(aSamples ? sumAbs / aSamples : 0) +
              (buf ? "" : " - no buffer memory") + (readOk ? "" : " - mic read failed"));
  uint8_t h[44];
  wavHeader(h, aRate, aSamples * 2);
  aFile.seek(0);
  aFile.write(h, 44);
  aFile.close();
  free(buf);
  micClose();
  store::pin(false);
  aMode = A_IDLE;
  aTask = nullptr;
  vTaskDelete(nullptr);
}

// While paused the playback task idles here. The speaker channel is cut at
// once; a seek request or stop ends the wait.
static void pausedWait() {
  M5Cardputer.Speaker.stop(0);
  while (aPaused && !aStop && aSeekTo < 0) vTaskDelay(20);
}

static void playTask(void *) {
  int16_t *buf[2] = {(int16_t *)malloc(ABUF * 2), (int16_t *)malloc(ABUF * 2)};
  if (buf[0] && buf[1]) {
    int idx = 0;
    size_t frame = aStereo ? 4 : 2;
    while (!aStop) {
      if (aSeekTo >= 0) {
        uint32_t at = aSeekTo;
        aSeekTo = -1;
        if (at * aRate > aTotal) at = aTotal / aRate;
        M5Cardputer.Speaker.stop(0);
        aFile.seek(aDataStart + (size_t)at * aRate * frame);
        aSamples = at * aRate;
      }
      if (aPaused) { pausedWait(); continue; }
      // playRaw() plays from our buffer without copying it, so wait until
      // buf[idx] has finished playing before reading the next block into it.
      while (M5Cardputer.Speaker.isPlaying(0) >= 2 && !aStop && !aPaused && aSeekTo < 0) vTaskDelay(1);
      if (aStop || aPaused || aSeekTo >= 0) continue;
      int n = aFile.read((uint8_t *)buf[idx], ABUF * 2);
      if (n <= 0) break;
      M5Cardputer.Speaker.playRaw(buf[idx], n / 2, aRate, aStereo, 1, 0);
      aSamples = aSamples + n / frame;
      spkLastUse = millis();
      idx ^= 1;
    }
    if (aStop) M5Cardputer.Speaker.stop(0);
    while (M5Cardputer.Speaker.isPlaying(0)) vTaskDelay(2);
  }
  aFile.close();
  free(buf[0]);
  free(buf[1]);
  store::pin(false);
  aMode = A_IDLE;
  aTask = nullptr;
  vTaskDelete(nullptr);
}

// MP3 playback, mixed to mono (the ADV has one speaker and a mono DAC). About
// 38 KB while playing, in five blocks so a fragmented heap can still fit it;
// all of it is freed when playback ends.
static const size_t MP3_IN = 4096, MP3_FRAME = 1152;
static mp3dec_t *mDec = nullptr;
static uint8_t *mIn = nullptr;
static int16_t *mPcm = nullptr, *mOut = nullptr;  // mOut: 3 mono frames
static int mInLen = 0;
static uint32_t mKbps = 0, mXingBytes = 0;
static uint8_t *mToc = nullptr;  // Xing seek table (100 bytes), VBR files only

static void mp3Free() {
  free(mDec); free(mp3Scratch); free(mIn); free(mPcm); free(mOut); free(mToc);
  mDec = nullptr; mp3Scratch = nullptr; mIn = nullptr; mPcm = mOut = nullptr; mToc = nullptr;
}

static bool mp3Alloc() {
  mDec = (mp3dec_t *)malloc(sizeof(mp3dec_t));
  mp3Scratch = malloc(sizeof(mp3dec_scratch_t));
  mIn = (uint8_t *)malloc(MP3_IN);
  mPcm = (int16_t *)malloc(MINIMP3_MAX_SAMPLES_PER_FRAME * 2);
  mOut = (int16_t *)malloc(3 * MP3_FRAME * 2);
  if (mDec && mp3Scratch && mIn && mPcm && mOut) { mp3dec_init(mDec); mInLen = 0; return true; }
  mp3Free();
  return false;
}

// Decodes the next frame into out as mono; returns the sample count, 0 at the end.
static int mp3Next(int16_t *out, mp3dec_frame_info_t &info) {
  while (true) {
    if (mInLen < (int)MP3_IN / 2) {
      int n = aFile.read(mIn + mInLen, MP3_IN - mInLen);
      if (n > 0) mInLen += n;
    }
    if (!mInLen) return 0;
    int s = mp3dec_decode_frame(mDec, mIn, mInLen, mPcm, &info);
    int used = info.frame_bytes;
    if (used > 0) {
      mInLen -= used;
      memmove(mIn, mIn + used, mInLen);
    }
    if (s > 0) {
      if (info.channels == 2)
        for (int i = 0; i < s; i++) out[i] = ((int)mPcm[2 * i] + mPcm[2 * i + 1]) / 2;
      else
        memcpy(out, mPcm, s * 2);
      return s;
    }
    if (used == 0) return 0;  // no frame left (end of file, or junk)
  }
}

// Jumps to `sec` seconds: through the Xing table for VBR files, by bitrate
// otherwise. The decoder resyncs on the next frame.
static void mp3Seek(uint32_t sec) {
  size_t bytes = aFile.size() - aDataStart, pos;
  if (aTotal && (uint64_t)sec * aRate > aTotal) sec = aTotal / aRate;
  if (mToc && aTotal) {
    float pct = (float)sec * aRate * 100 / aTotal;
    int i = pct >= 99 ? 99 : (int)pct;
    float a = mToc[i], b = i < 99 ? mToc[i + 1] : 256;
    pos = (size_t)((a + (b - a) * (pct - i)) / 256 * (mXingBytes ? mXingBytes : bytes));
  } else {
    pos = (size_t)sec * mKbps * 125;
  }
  if (pos >= bytes) pos = bytes ? bytes - 1 : 0;
  M5Cardputer.Speaker.stop(0);
  aFile.seek(aDataStart + pos);
  mInLen = 0;
  mp3dec_init(mDec);
  aSamples = sec * aRate;
}

static void mp3Task(void *) {
  mp3dec_frame_info_t info;
  int idx = 0;
  while (!aStop) {
    if (aSeekTo >= 0) { uint32_t at = aSeekTo; aSeekTo = -1; mp3Seek(at); }
    if (aPaused) { pausedWait(); continue; }
    // three buffers: one playing, one queued, one being decoded
    int16_t *o = mOut + idx * MP3_FRAME;
    int n = mp3Next(o, info);
    if (n <= 0) break;
    while (M5Cardputer.Speaker.isPlaying(0) >= 2 && !aStop && !aPaused && aSeekTo < 0) vTaskDelay(1);
    if (aStop || aSeekTo >= 0) continue;
    M5Cardputer.Speaker.playRaw(o, n, info.hz, false, 1, 0);
    aSamples = aSamples + n;
    spkLastUse = millis();
    idx = (idx + 1) % 3;
    // Always give up the CPU briefly: if decoding ever falls behind, the wait
    // above never blocks and core 0's idle task (the watchdog's check) starves.
    vTaskDelay(1);
  }
  if (aStop) M5Cardputer.Speaker.stop(0);
  while (M5Cardputer.Speaker.isPlaying(0)) vTaskDelay(2);
  aFile.close();
  mp3Free();
  store::pin(false);
  aMode = A_IDLE;
  aTask = nullptr;
  vTaskDelete(nullptr);
}

// Opens aFile (already open) as MP3 and starts playback. Returns an error or "".
static const char *mp3Start() {
  uint8_t h[10];
  size_t start = 0;  // skip an ID3v2 tag: it can hold cover art
  if (aFile.read(h, 10) == 10 && !memcmp(h, "ID3", 3))
    start = 10 + ((h[6] & 0x7F) << 21 | (h[7] & 0x7F) << 14 | (h[8] & 0x7F) << 7 | (h[9] & 0x7F)) + (h[5] & 0x10 ? 10 : 0);
  aFile.seek(start);
  if (!mp3Alloc()) return "not enough memory for MP3";
  mInLen = aFile.read(mIn, MP3_IN);
  mp3dec_frame_info_t info;
  if (mInLen <= 0 || mp3dec_decode_frame(mDec, mIn, mInLen, nullptr, &info) <= 0) { mp3Free(); return "no MP3 audio found"; }
  mp3dec_init(mDec);  // the probe above only read the header
  aRate = info.hz;
  aDataStart = start;
  mKbps = info.bitrate_kbps;
  mXingBytes = 0;
  // length from the first frame's bitrate: exact for constant bitrate, close for VBR
  aTotal = mKbps ? (uint64_t)(aFile.size() - start) * info.hz / (mKbps * 125) : 0;
  // A Xing/Info frame (written by LAME and most encoders) gives the exact
  // frame count, and for VBR a table for seeking.
  const uint8_t *fr = mIn + info.frame_offset;
  int span = info.frame_bytes - info.frame_offset;
  if (span > 200) span = 200;
  for (int i = 4; i + 8 <= span; i++) {
    if (memcmp(fr + i, "Xing", 4) && memcmp(fr + i, "Info", 4)) continue;
    auto be32 = [](const uint8_t *b) { return (uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]; };
    uint32_t flags = be32(fr + i + 4);
    const uint8_t *p = fr + i + 8;
    int perFrame = ((fr[1] >> 3) & 3) == 3 ? 1152 : 576;  // MPEG-1 or MPEG-2/2.5
    if (flags & 1) { aTotal = be32(p) * perFrame; p += 4; }
    if (flags & 2) { mXingBytes = be32(p); p += 4; }
    if ((flags & 4) && !memcmp(fr + i, "Xing", 4) && p + 100 <= fr + span + 100 && (mToc = (uint8_t *)malloc(100)))
      memcpy(mToc, p, 100);
    break;
  }
  return "";
}

// Stops recording or playback and waits for the task to finish (it closes
// the file and frees its buffers). True once audio is idle.
static bool audioStop() {
  if (aMode == A_IDLE) return true;
  aStop = true;
  uint32_t t0 = millis();
  while (aMode != A_IDLE && millis() - t0 < 3000) delay(5);
  luaBudgetReset();
  if (aMode != A_IDLE) usbdev::log("audio: task did not stop in 3 s");
  return aMode == A_IDLE;
}

static int au_record(lua_State *L) {
  if (!audioStop()) { lua_pushboolean(L, 0); lua_pushstring(L, "audio busy"); return 2; }
  String real;
  fs::FS *fs = store::resolve(str(L, 1), real, true);
  aRate = (uint32_t)luaL_optinteger(L, 2, 16000);
  if (!fs || !(aFile = fs->open(real, "w"))) { lua_pushboolean(L, 0); return 1; }
  uint8_t h[44] = {0};
  aFile.write(h, 44);
  store::pin(true);
  if (!useMic(aRate)) {
    aFile.close();
    store::pin(false);
    lua_pushboolean(L, 0);
    lua_pushstring(L, "microphone failed to start");
    return 2;
  }
  aSamples = 0;
  aStop = false;
  aMode = A_REC;
  // 8 KB: SD writes (FATFS + SPI) need more than 4 KB of stack
  xTaskCreatePinnedToCore(recTask, "rec", 8192, nullptr, 3, &aTask, 0);
  lua_pushboolean(L, 1);
  return 1;
}

// Plays an MP3 or 16-bit PCM WAV file. Returns true, or false + reason.
static int au_play(lua_State *L) {
  if (!audioStop()) { lua_pushboolean(L, 0); lua_pushstring(L, "audio busy"); return 2; }
  String real;
  fs::FS *fs = store::resolve(str(L, 1), real);
  if (!fs || !(aFile = fs->open(real, "r"))) { lua_pushboolean(L, 0); lua_pushstring(L, "cannot open"); return 2; }
  String lower = real;
  lower.toLowerCase();
  aPaused = false;
  aSeekTo = lua_isnumber(L, 2) && lua_tonumber(L, 2) > 0 ? (int32_t)lua_tonumber(L, 2) : -1;
  if (lower.endsWith(".mp3")) {
    const char *why = mp3Start();
    if (*why) { aFile.close(); lua_pushboolean(L, 0); lua_pushstring(L, why); return 2; }
    aSamples = 0;
    store::pin(true);
    useSpeaker();
    aStop = false;
    aMode = A_PLAY;
    xTaskCreatePinnedToCore(mp3Task, "mp3", 8192, nullptr, 3, &aTask, 0);
    lua_pushboolean(L, 1);
    return 1;
  }
  uint8_t h[12];
  if (aFile.read(h, 12) != 12 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)) {
    aFile.close(); lua_pushboolean(L, 0); lua_pushstring(L, "not a WAV file"); return 2;
  }
  uint16_t fmt = 0, ch = 1, bits = 0;
  uint32_t dataLen = 0;
  while (aFile.available()) {  // walk chunks until "data"
    uint8_t c[8];
    if (aFile.read(c, 8) != 8) break;
    uint32_t len = c[4] | c[5] << 8 | c[6] << 16 | (uint32_t)c[7] << 24;
    if (!memcmp(c, "fmt ", 4)) {
      uint8_t f[16];
      aFile.read(f, 16);
      fmt = f[0] | f[1] << 8; ch = f[2] | f[3] << 8;
      aRate = f[4] | f[5] << 8 | f[6] << 16 | (uint32_t)f[7] << 24;
      bits = f[14] | f[15] << 8;
      if (len > 16) aFile.seek(aFile.position() + len - 16);
    } else if (!memcmp(c, "data", 4)) {
      dataLen = len;
      aDataStart = aFile.position();
      break;
    } else {
      aFile.seek(aFile.position() + len);
    }
  }
  if (fmt != 1 || bits != 16 || !dataLen) {
    aFile.close(); lua_pushboolean(L, 0); lua_pushstring(L, "only 16-bit PCM WAV is supported"); return 2;
  }
  aStereo = ch == 2;
  aTotal = dataLen / 2 / ch;
  aSamples = 0;
  store::pin(true);
  useSpeaker();
  aStop = false;
  aMode = A_PLAY;
  xTaskCreatePinnedToCore(playTask, "play", 8192, nullptr, 3, &aTask, 0);
  lua_pushboolean(L, 1);
  return 1;
}

static int au_stop(lua_State *L) {
  audioStop();
  return 0;
}

// pause(on) pauses or resumes playback; returns whether it is paused.
static int au_pause(lua_State *L) {
  if (aMode == A_PLAY) aPaused = lua_toboolean(L, 1);
  lua_pushboolean(L, aMode == A_PLAY && aPaused);
  return 1;
}

// seek(seconds) jumps within the playing track.
static int au_seek(lua_State *L) {
  if (aMode == A_PLAY) aSeekTo = max(0, (int)luaL_checknumber(L, 1));
  return 0;
}

// status() -> "idle"|"recording"|"playing"|"paused", seconds done, seconds total
static int au_status(lua_State *L) {
  lua_pushstring(L, aMode == A_REC ? "recording" : aMode == A_PLAY ? (aPaused ? "paused" : "playing") : "idle");
  lua_pushnumber(L, (float)aSamples / aRate);
  lua_pushnumber(L, aMode == A_PLAY ? (float)aTotal / aRate : 0);
  return 3;
}

// ID3 text to plain ASCII: the UI font has no accented letters, so Latin-1
// letters are folded (é -> e) and typographic quotes and dashes simplified.
static void id3Put(String &out, uint32_t c) {
  static const char fold[] = "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYPsaaaaaaaceeeeiiiidnooooo/ouuuuypy";
  if (!c) return;
  if (c < 0x80) out += (char)c;
  else if (c >= 0xC0 && c <= 0xFF) out += fold[c - 0xC0];
  else if (c == 0x2018 || c == 0x2019) out += '\'';
  else if (c == 0x201C || c == 0x201D) out += '"';
  else if (c == 0x2013 || c == 0x2014) out += '-';
  else if (c == 0x2026) out += "...";
  else out += '?';
}

static String id3Text(const uint8_t *p, size_t n) {
  String out;
  if (!n) return out;
  uint8_t enc = *p++;
  n--;
  if (enc == 1 || enc == 2) {  // UTF-16 (with a byte order mark) or UTF-16BE
    bool be = enc == 2;
    size_t i = 0;
    if (enc == 1 && n >= 2 && ((p[0] == 0xFF && p[1] == 0xFE) || (p[0] == 0xFE && p[1] == 0xFF))) { be = p[0] == 0xFE; i = 2; }
    for (; i + 1 < n; i += 2) {
      uint32_t c = be ? (p[i] << 8 | p[i + 1]) : (p[i + 1] << 8 | p[i]);
      if (!c) break;
      if (c >= 0xD800 && c < 0xE000) { if (c < 0xDC00) id3Put(out, '?'); continue; }  // outside the BMP
      id3Put(out, c);
    }
  } else if (enc == 3) {  // UTF-8
    for (size_t i = 0; i < n && p[i];) {
      uint32_t c = p[i];
      int more = c < 0x80 ? 0 : c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : -1;
      if (more < 0) { i++; continue; }
      c &= more ? (0x3F >> more) : 0x7F;
      i++;
      for (int k = 0; k < more && i < n; k++, i++) c = c << 6 | (p[i] & 0x3F);
      id3Put(out, c);
    }
  } else {  // ISO-8859-1
    for (size_t i = 0; i < n && p[i]; i++) id3Put(out, p[i]);
  }
  out.trim();
  return out;
}

// tags(path) -> {title, artist, album, track} from the ID3v2 tag (versions
// 2.2-2.4) or an ID3v1 tag; fields that are missing are left out.
static int au_tags(lua_State *L) {
  String real;
  fs::FS *fs = store::resolve(str(L, 1), real);
  File f = fs ? fs->open(real, "r") : File();
  lua_newtable(L);
  if (!f) return 1;
  int found = 0;
  uint8_t h[10], buf[160];
  auto syncsafe = [](const uint8_t *b) { return (uint32_t)(b[0] & 0x7F) << 21 | (b[1] & 0x7F) << 14 | (b[2] & 0x7F) << 7 | (b[3] & 0x7F); };
  auto set = [&](const char *key, const String &v) {
    if (!v.length()) return;
    lua_pushstring(L, v.c_str());
    lua_setfield(L, -2, key);
    found++;
  };
  if (f.read(h, 10) == 10 && !memcmp(h, "ID3", 3) && h[3] >= 2 && h[3] <= 4) {
    int ver = h[3], hdr = ver == 2 ? 6 : 10;
    size_t end = 10 + syncsafe(h + 6), pos = 10;
    if ((h[5] & 0x40) && ver >= 3 && f.read(buf, 4) == 4)  // extended header
      pos = ver == 4 ? 10 + syncsafe(buf) : 14 + ((uint32_t)buf[0] << 24 | buf[1] << 16 | buf[2] << 8 | buf[3]);
    while (pos + hdr <= end && found < 4) {
      f.seek(pos);
      if (f.read(buf, hdr) != hdr || !buf[0]) break;  // padding
      uint32_t size = ver == 2 ? (buf[3] << 16 | buf[4] << 8 | buf[5])
                    : ver == 4 ? syncsafe(buf + 4) : ((uint32_t)buf[4] << 24 | buf[5] << 16 | buf[6] << 8 | buf[7]);
      char id[5] = {0};
      memcpy(id, buf, ver == 2 ? 3 : 4);
      const char *key = !strcmp(id, "TIT2") || !strcmp(id, "TT2") ? "title"
                      : !strcmp(id, "TPE1") || !strcmp(id, "TP1") ? "artist"
                      : !strcmp(id, "TALB") || !strcmp(id, "TAL") ? "album"
                      : !strcmp(id, "TRCK") || !strcmp(id, "TRK") ? "track" : nullptr;
      if (key && size > 1) {
        size_t n = size < sizeof buf ? size : sizeof buf;
        if (f.read(buf, n) == n) set(key, id3Text(buf, n));
      }
      pos += hdr + size;
    }
  }
  if (!found && f.size() > 128 && f.seek(f.size() - 128) && f.read(buf, 128) == 128 && !memcmp(buf, "TAG", 3)) {
    auto field = [&](int at, int len) {  // ID3v1: fixed-width Latin-1 fields
      uint8_t t[32] = {0};
      memcpy(t + 1, buf + at, len);
      return id3Text(t, len + 1);
    };
    set("title", field(3, 30));
    set("artist", field(33, 30));
    set("album", field(63, 30));
    if (!buf[125] && buf[126]) set("track", String(buf[126]));
  }
  f.close();
  return 1;
}

// analyze() listens for ~32 ms and returns level (0-1), peak (0-1), pitch in Hz
// (0 if none) and a table of 8 band levels from 100 Hz to 4 kHz.
static int au_analyze(lua_State *L) {
  if (aMode != A_IDLE) return luaL_error(L, "audio busy");
  const int N = 512;
  const uint32_t rate = 16000;
  int16_t *s = (int16_t *)malloc(N * 2);
  if (!s) return luaL_error(L, "not enough memory");
  if (!useMic(rate) || !micRead(s, N)) { free(s); return luaL_error(L, "microphone failed to start"); }

  double sum = 0;
  int peak = 0;
  for (int i = 0; i < N; i++) {
    int v = s[i];
    sum += (double)v * v;
    if (abs(v) > peak) peak = abs(v);
  }
  float rms = sqrt(sum / N) / 32768.0f;

  // pitch: best normalised autocorrelation lag between 60 Hz and 1 kHz
  float pitch = 0;
  if (rms > 0.01f) {
    int minLag = rate / 1000, maxLag = rate / 60;
    float best = 0;
    int bestLag = 0;
    for (int lag = minLag; lag <= maxLag && lag < N / 2; lag++) {
      float c = 0;
      for (int i = 0; i < N - lag; i++) c += (float)s[i] * s[i + lag];
      if (c > best) { best = c; bestLag = lag; }
    }
    if (bestLag && best > 0.3f * sum) pitch = (float)rate / bestLag;
  }

  lua_pushnumber(L, rms);
  lua_pushnumber(L, peak / 32768.0f);
  lua_pushnumber(L, pitch);
  // 8 log-spaced bands with the Goertzel algorithm
  static const float freqs[8] = {100, 180, 320, 560, 1000, 1700, 2800, 4000};
  lua_createtable(L, 8, 0);
  for (int b = 0; b < 8; b++) {
    float k = 2.0f * cosf(2.0f * PI * freqs[b] / rate);
    float s1 = 0, s2 = 0;
    for (int i = 0; i < N; i++) {
      float s0 = s[i] / 32768.0f + k * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    float power = s1 * s1 + s2 * s2 - k * s1 * s2;
    lua_pushnumber(L, sqrtf(power) / (N / 2));
    lua_rawseti(L, -2, b + 1);
  }
  free(s);
  return 4;
}

void hwTick() {
  // Stop the speaker a few seconds after the last sound to free its buffers.
  if (aMode == A_IDLE && M5Cardputer.Speaker.isRunning()) {
    if (M5Cardputer.Speaker.isPlaying()) spkLastUse = millis();
    else if (millis() - spkLastUse > 4000) M5Cardputer.Speaker.end();
  }
  // Same for the mic once analyze() stops being called.
  if (aMode == A_IDLE && micRx && millis() - micLastUse > 4000) micClose();
}

// Shared by snd.tone in bindings.cpp. False while recording: the speaker would
// take the mic's pins and end the recording.
bool hwUseSpeaker() {
  if (aMode == A_REC) return false;
  useSpeaker();
  return true;
}

// =============================================================== ir
static bool irReady = false;
// send(protocol, address, command[, repeats]); protocol: nec, samsung, sony,
// lg, rc5, panasonic.
static int ir_send(lua_State *L) {
  if (!irReady) {
    IrSender.begin(DISABLE_LED_FEEDBACK);
    IrSender.setSendPin(44);
    irReady = true;
  }
  String p = str(L, 1);
  uint16_t addr = num(L, 2), cmd = num(L, 3);
  int rep = (int)luaL_optinteger(L, 4, 0);
  if (p == "nec") IrSender.sendNEC(addr, cmd, rep);
  else if (p == "samsung") IrSender.sendSamsung(addr, cmd, rep);
  else if (p == "sony") IrSender.sendSony(addr, cmd, rep, (uint8_t)luaL_optinteger(L, 5, 12));
  else if (p == "lg") IrSender.sendLG(addr, cmd, rep);
  else if (p == "rc5") IrSender.sendRC5(addr, cmd, rep);
  else if (p == "panasonic") IrSender.sendPanasonic(addr, cmd, rep);
  else return luaL_error(L, "unknown IR protocol: %s", p.c_str());
  luaBudgetReset();
  return 0;
}

// =============================================================== i2c (Grove port A)
static bool i2cReady = false;
static void i2cBegin() {
  if (!i2cReady) { M5.Ex_I2C.begin(); i2cReady = true; }
}
static int i2_scan(lua_State *L) {
  i2cBegin();
  lua_newtable(L);
  int n = 0;
  for (int a = 0x08; a < 0x78; a++)
    if (M5.Ex_I2C.scanID(a)) { lua_pushinteger(L, a); lua_rawseti(L, -2, ++n); }
  return 1;
}
static int i2_write(lua_State *L) {
  i2cBegin();
  size_t n;
  const char *d = luaL_checklstring(L, 2, &n);
  bool ok = M5.Ex_I2C.start(num(L, 1), false, 100000) && M5.Ex_I2C.write((const uint8_t *)d, n);
  M5.Ex_I2C.stop();
  lua_pushboolean(L, ok);
  return 1;
}
static int i2_read(lua_State *L) {
  i2cBegin();
  int n = constrain(num(L, 2), 1, 64);
  uint8_t buf[64];
  bool ok = M5.Ex_I2C.start(num(L, 1), true, 100000) && M5.Ex_I2C.read(buf, n, true);
  M5.Ex_I2C.stop();
  if (!ok) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, (const char *)buf, n);
  return 1;
}
static int i2_read_reg(lua_State *L) {
  i2cBegin();
  int n = constrain(num(L, 3), 1, 64);
  uint8_t buf[64];
  if (!M5.Ex_I2C.readRegister(num(L, 1), num(L, 2), buf, n, 100000)) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, (const char *)buf, n);
  return 1;
}
static int i2_write_reg(lua_State *L) {
  i2cBegin();
  size_t n;
  const char *d = luaL_checklstring(L, 3, &n);
  lua_pushboolean(L, M5.Ex_I2C.writeRegister(num(L, 1), num(L, 2), (const uint8_t *)d, n, 100000));
  return 1;
}

// =============================================================== http and network tools
// get(url[, max_bytes]) -> body, status | nil, error. Plain HTTP only: TLS
// needs ~40 KB more RAM than this board has to spare with Wi-Fi on.
static int ht_get(lua_State *L) {
  String url = str(L, 1);
  size_t max = (size_t)luaL_optinteger(L, 2, 8192);
  if (WiFi.status() != WL_CONNECTED) { lua_pushnil(L); lua_pushstring(L, "Wi-Fi not connected"); return 2; }
  if (url.startsWith("https://")) { lua_pushnil(L); lua_pushstring(L, "https is not supported"); return 2; }
  WiFiClient client;
  HTTPClient http;
  http.setTimeout(5000);
  http.setUserAgent("LiveOS-Cardputer");
  if (!http.begin(client, url)) { lua_pushnil(L); lua_pushstring(L, "bad url"); return 2; }
  int code = http.GET();
  if (code <= 0) {
    String e = http.errorToString(code);
    http.end();
    luaBudgetReset();
    lua_pushnil(L);
    lua_pushstring(L, e.c_str());
    return 2;
  }
  String body;
  WiFiClient *s = http.getStreamPtr();
  int len = http.getSize();
  uint32_t t0 = millis();
  while (http.connected() && (len < 0 || (int)body.length() < len) && body.length() < max && millis() - t0 < 5000) {
    while (s->available() && body.length() < max) body += (char)s->read();
    delay(1);
  }
  http.end();
  luaBudgetReset();
  lua_pushlstring(L, body.c_str(), body.length());
  lua_pushinteger(L, code);
  return 2;
}

// download(url, path[, max_bytes]) -> bytes, status | nil, error. Streams to a
// file, so the size of the download never has to fit in RAM.
static int ht_download(lua_State *L) {
  String url = str(L, 1);
  size_t max = (size_t)luaL_optinteger(L, 3, 1 << 20);
  if (WiFi.status() != WL_CONNECTED) { lua_pushnil(L); lua_pushstring(L, "Wi-Fi not connected"); return 2; }
  if (url.startsWith("https://")) { lua_pushnil(L); lua_pushstring(L, "https is not supported"); return 2; }
  String real;
  fs::FS *fs = store::resolve(str(L, 2), real, true);
  if (!fs) { lua_pushnil(L); lua_pushstring(L, "bad path"); return 2; }
  WiFiClient client;
  HTTPClient http;
  http.setTimeout(5000);
  http.setUserAgent("LiveOS-Cardputer");
  if (!http.begin(client, url)) { lua_pushnil(L); lua_pushstring(L, "bad url"); return 2; }
  int code = http.GET();
  if (code <= 0) {
    String e = http.errorToString(code);
    http.end();
    luaBudgetReset();
    lua_pushnil(L);
    lua_pushstring(L, e.c_str());
    return 2;
  }
  File f = fs->open(real, "w");
  if (!f) { http.end(); lua_pushnil(L); lua_pushstring(L, "cannot write file"); return 2; }
  WiFiClient *s = http.getStreamPtr();
  int len = http.getSize();
  size_t total = 0;
  uint8_t buf[256];
  uint32_t last = millis();
  while (http.connected() && (len < 0 || (int)total < len) && total < max && millis() - last < 5000) {
    size_t n = s->available();
    if (!n) { delay(2); continue; }
    if (n > sizeof buf) n = sizeof buf;
    n = s->readBytes(buf, n);
    f.write(buf, n);
    total += n;
    last = millis();
  }
  f.close();
  http.end();
  luaBudgetReset();
  lua_pushinteger(L, total);
  lua_pushinteger(L, code);
  return 2;
}

static int ht_dns(lua_State *L) {
  IPAddress ip;
  bool ok = WiFi.status() == WL_CONNECTED && WiFi.hostByName(str(L, 1).c_str(), ip);
  luaBudgetReset();
  if (!ok) { lua_pushnil(L); return 1; }
  lua_pushstring(L, ip.toString().c_str());
  return 1;
}

// ping(host[, port]) -> milliseconds for a TCP connect, or nil
static int ht_ping(lua_State *L) {
  if (WiFi.status() != WL_CONNECTED) { lua_pushnil(L); return 1; }
  WiFiClient c;
  uint32_t t0 = millis();
  bool ok = c.connect(str(L, 1).c_str(), (uint16_t)luaL_optinteger(L, 2, 80), 3000);
  uint32_t ms = millis() - t0;
  c.stop();
  luaBudgetReset();
  if (!ok) { lua_pushnil(L); return 1; }
  lua_pushinteger(L, ms);
  return 1;
}

// =============================================================== LoRa (Cap LoRa-1262)
static SX1262 *radio = nullptr;
static volatile bool radioFlag = false;
static bool radioTx = false;
static void IRAM_ATTR onRadio() { radioFlag = true; }

// begin([freq_mhz=915][, sf=9][, power_dbm=14]) -> true | false, error
static int lo_begin(lua_State *L) {
  float freq = (float)luaL_optnumber(L, 1, 915.0);
  int sf = (int)luaL_optinteger(L, 2, 9);
  int power = (int)luaL_optinteger(L, 3, 14);
  m5::PI4IOE5V6408_Class ioe(0x43, 400000, &m5::In_I2C);
  if (!ioe.begin()) { lua_pushboolean(L, 0); lua_pushstring(L, "LoRa cap not found"); return 2; }
  ioe.setDirection(0, true);
  ioe.setHighImpedance(0, false);
  ioe.digitalWrite(0, true);  // RF switch
  if (!radio) radio = new SX1262(new Module(5, 4, 3, 6));
  int st = radio->begin(freq, 125.0, sf, 5, 0x12, power, 12, 3.0, true);
  luaBudgetReset();
  if (st != RADIOLIB_ERR_NONE) { lua_pushboolean(L, 0); lua_pushfstring(L, "radio error %d", st); return 2; }
  radio->setCurrentLimit(140);
  radio->setPacketReceivedAction(onRadio);
  radio->startReceive();
  radioTx = false;
  lua_pushboolean(L, 1);
  return 1;
}

static int lo_send(lua_State *L) {
  if (!radio || radioTx) { lua_pushboolean(L, 0); return 1; }
  String s = str(L, 1);
  if (s.length() > 240) s = s.substring(0, 240);
  radioTx = true;
  lua_pushboolean(L, radio->startTransmit(s) == RADIOLIB_ERR_NONE);
  return 1;
}

// recv() -> { data=, rssi=, snr= } or nil. Call every frame; also finishes sends.
static int lo_recv(lua_State *L) {
  if (!radio || !radioFlag) { lua_pushnil(L); return 1; }
  radioFlag = false;
  if (radioTx) {
    radio->finishTransmit();
    radioTx = false;
    radio->startReceive();
    lua_pushnil(L);
    return 1;
  }
  String s;
  int st = radio->readData(s);
  float rssi = radio->getRSSI(), snr = radio->getSNR();
  radio->startReceive();
  if (st != RADIOLIB_ERR_NONE) { lua_pushnil(L); return 1; }
  lua_createtable(L, 0, 3);
  lua_pushlstring(L, s.c_str(), s.length()); lua_setfield(L, -2, "data");
  lua_pushnumber(L, rssi); lua_setfield(L, -2, "rssi");
  lua_pushnumber(L, snr); lua_setfield(L, -2, "snr");
  return 1;
}

static int lo_busy(lua_State *L) { lua_pushboolean(L, radioTx); return 1; }

static int lo_stop(lua_State *L) {
  if (radio) { radio->sleep(); delete radio; radio = nullptr; }
  return 0;
}

// =============================================================== GPS (Cap LoRa-1262)
static TinyGPSPlus *gpsP = nullptr;
static int gp_start(lua_State *L) {
  if (!gpsP) gpsP = new TinyGPSPlus();
  Serial1.begin(115200, SERIAL_8N1, 15, 13);
  return 0;
}
static int gp_stop(lua_State *L) {
  Serial1.end();
  delete gpsP;
  gpsP = nullptr;
  return 0;
}
// read() -> table with valid, lat, lon, alt, sats, hdop, speed (km/h), course,
// time ("hh:mm:ss" UTC), date ("yyyy-mm-dd"), chars (NMEA characters seen)
static int gp_read(lua_State *L) {
  if (!gpsP) { lua_pushnil(L); return 1; }
  while (Serial1.available()) gpsP->encode(Serial1.read());
  TinyGPSPlus &g = *gpsP;
  lua_createtable(L, 0, 11);
  lua_pushboolean(L, g.location.isValid() && g.location.age() < 5000); lua_setfield(L, -2, "valid");
  lua_pushnumber(L, g.location.lat()); lua_setfield(L, -2, "lat");
  lua_pushnumber(L, g.location.lng()); lua_setfield(L, -2, "lon");
  lua_pushnumber(L, g.altitude.meters()); lua_setfield(L, -2, "alt");
  lua_pushinteger(L, g.satellites.value()); lua_setfield(L, -2, "sats");
  lua_pushnumber(L, g.hdop.hdop()); lua_setfield(L, -2, "hdop");
  lua_pushnumber(L, g.speed.kmph()); lua_setfield(L, -2, "speed");
  lua_pushnumber(L, g.course.deg()); lua_setfield(L, -2, "course");
  char b[16];
  snprintf(b, sizeof b, "%02d:%02d:%02d", g.time.hour(), g.time.minute(), g.time.second());
  lua_pushstring(L, g.time.isValid() ? b : ""); lua_setfield(L, -2, "time");
  snprintf(b, sizeof b, "%04d-%02d-%02d", g.date.year(), g.date.month(), g.date.day());
  lua_pushstring(L, g.date.isValid() ? b : ""); lua_setfield(L, -2, "date");
  lua_pushinteger(L, (lua_Integer)g.charsProcessed()); lua_setfield(L, -2, "chars");
  return 1;
}

// =============================================================== disp (direct drawing)
// For apps that show a still picture with sys.display_hold(true): these draw
// straight to the panel, bypassing the banded frame buffer.
static int di_image(lua_State *L) {
  String real;
  fs::FS *fs = store::resolve(str(L, 1), real);
  int x = (int)luaL_optinteger(L, 2, 0), y = (int)luaL_optinteger(L, 3, 0);
  float scale = (float)luaL_optnumber(L, 4, 1.0);
  bool ok = false;
  if (fs && fs->exists(real)) {
    String lower = real;
    lower.toLowerCase();
    auto &d = M5Cardputer.Display;
    if (lower.endsWith(".bmp")) ok = d.drawBmpFile(*fs, real.c_str(), x, y, 0, 0, 0, 0, scale, scale);
    else if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) ok = d.drawJpgFile(*fs, real.c_str(), x, y, 0, 0, 0, 0, scale, scale);
    else if (lower.endsWith(".png")) ok = d.drawPngFile(*fs, real.c_str(), x, y, 0, 0, 0, 0, scale, scale);
  }
  luaBudgetReset();
  lua_pushboolean(L, ok);
  return 1;
}
static int di_fill(lua_State *L) {
  M5Cardputer.Display.fillRect(num(L, 1), num(L, 2), num(L, 3), num(L, 4), (uint16_t)luaL_optinteger(L, 5, 0));
  return 0;
}
static int di_text(lua_State *L) {
  auto &d = M5Cardputer.Display;
  d.setTextSize(1);
  d.setTextColor((uint16_t)luaL_optinteger(L, 4, 0xFFFF));
  d.drawString(luaL_checkstring(L, 3), num(L, 1), num(L, 2));
  return 0;
}

// =============================================================== registration
// Hardware tables are created on first use (see boot.lua's _G metatable) and
// dropped when an app closes, so their ~40 entries cost nothing until needed.
static const luaL_Reg audioLib[] = {{"record", au_record}, {"play", au_play}, {"stop", au_stop},
                                    {"pause", au_pause}, {"seek", au_seek}, {"tags", au_tags},
                                    {"status", au_status}, {"analyze", au_analyze}, {nullptr, nullptr}};
static const luaL_Reg irLib[] = {{"send", ir_send}, {nullptr, nullptr}};
static const luaL_Reg i2cLib[] = {{"scan", i2_scan}, {"read", i2_read}, {"write", i2_write},
                                  {"read_reg", i2_read_reg}, {"write_reg", i2_write_reg}, {nullptr, nullptr}};
static const luaL_Reg httpLib[] = {{"get", ht_get}, {"download", ht_download}, {"dns", ht_dns}, {"ping", ht_ping}, {nullptr, nullptr}};
static const luaL_Reg loraLib[] = {{"begin", lo_begin}, {"send", lo_send}, {"recv", lo_recv},
                                   {"busy", lo_busy}, {"stop", lo_stop}, {nullptr, nullptr}};
static const luaL_Reg gpsLib[] = {{"start", gp_start}, {"stop", gp_stop}, {"read", gp_read}, {nullptr, nullptr}};
static const luaL_Reg dispLib[] = {{"image", di_image}, {"fill", di_fill}, {"text", di_text}, {nullptr, nullptr}};
extern const luaL_Reg musiclibFns[];  // musiclib.cpp
static const struct { const char *name; const luaL_Reg *fns; } HW_LIBS[] = {
    {"audio", audioLib}, {"ir", irLib}, {"i2c", i2cLib}, {"http", httpLib},
    {"lora", loraLib}, {"gps", gpsLib}, {"disp", dispLib}, {"musiclib", musiclibFns}};

// sys.hwlib(name) -> the table for that driver, or nil
static int hw_lib(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  for (auto &l : HW_LIBS)
    if (!strcmp(l.name, name)) { luaL_newlib(L, l.fns); return 1; }
  lua_pushnil(L);
  return 1;
}

void registerHw(lua_State *L) {
  lua_getglobal(L, "sys");
  lua_pushcfunction(L, hw_lib);
  lua_setfield(L, -2, "hwlib");
  lua_pop(L, 1);
}
