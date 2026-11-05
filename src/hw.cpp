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
#include "bindings.h"
#include "musiclib.h"
#include "storage.h"
#include "usbdev.h"
#include "vm.h"

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
static void eqProcess(int16_t *s, int n, int ch, uint32_t rate);  // the equalizer, below

// How much of its 6 KB stack an audio task never touched (logged as it ends).
static void logAudioStack(const char *what) {
  usbdev::log(String("audio: ") + what + " task left " + uxTaskGetStackHighWaterMark(nullptr) + " of 6144 stack bytes unused");
}

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

// No pops. The codec ramps its DAC volume itself (REG37) once that is on, so
// the speaker path starts silent and fades in, and stopping, pausing and
// seeking fade out first; cutting the sound mid-wave, or powering the
// headphone driver up at full volume (what M5Unified does), pops loudly in
// headphones. All on the main task: the I2C bus is shared with the keyboard.
//
// The volume is set here too, in the codec's DAC (0.5 dB steps, 0xBF = 0 dB):
// M5Unified's own volume scales the samples before they are cut to 16 bits,
// which at headphone levels (-30 dB) left ~11 bits of detail. Its master
// volume stays at unity (UNITY_MASTER) instead.
static const uint8_t UNITY_MASTER = 182;  // 16 x 182^2 x 255^2 x 2 / 2^36 ~= 1 for mono
static uint8_t dacVol = 0;                // the DAC volume last written
static uint8_t dacTarget = 0xBF;          // what the volume setting asks for
static bool faded = true;                 // faded out (or not started): DAC at 0
static uint32_t fadeInAt = 0;
static void dacSet(uint8_t v) {
  if (v == dacVol) return;
  M5.In_I2C.writeRegister8(ES8311, 0x32, v, 400000);
  dacVol = v;
}
static void fadeOut() {
  if (faded || !M5Cardputer.Speaker.isRunning()) return;
  faded = true;
  dacSet(0);
  delay(45);  // the codec's ramp (~35 ms)
}
static void fadeIn() {
  if (!M5Cardputer.Speaker.isRunning()) return;
  faded = false;
  dacSet(dacTarget);
}
static bool codecVolume() { return M5.getBoard() == m5::board_t::board_M5CardputerADV; }

// The "vol" setting (0-255, see volumeLevel in bindings.cpp) as the codec's
// DAC volume: each of the 20 levels is as loud as it was with M5Unified's
// volume (level 20 = +5.9 dB, as master 255 was), 2.5 dB apart.
void hwSetVolume(int raw) {
  if (!codecVolume()) { M5Cardputer.Speaker.setVolume(constrain(raw, 0, 255)); return; }
  int level = volumeLevel(raw);
  dacTarget = level ? (uint8_t)constrain(0xBF + (int)lroundf(2 * (5.9f + (level - 20) * 2.5f)), 1, 0xFF) : 0;
  if (!faded && M5Cardputer.Speaker.isRunning()) dacSet(dacTarget);
}

static bool spkEnable(void *, bool on) {
  if (on) {
    static const uint8_t regs[][2] = {
        {0x00, 0x80}, {0x01, 0xB5}, {0x02, 0x18}, {0x0D, 0x01},  // power on, clocks from BCLK, analog up
        {0x37, 0x18},                                            // DAC volume ramps (and its EQ bypassed)
        {0x32, 0x00},                                            // silent until fadeIn()
        {0x12, 0x00}, {0x13, 0x10}};                             // DAC and headphone driver on
    for (auto &r : regs) M5.In_I2C.writeRegister8(ES8311, r[0], r[1], 400000);
    dacVol = 0;
    faded = true;
  } else {
    fadeOut();  // the driver stays powered: switching it off clicks too
  }
  return true;
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

// Playback keeps the speaker driver until its app closes (hwReleaseAudio):
// once Music has run a while the heap is in pieces and the driver's 8 KB of
// DMA buffers could not be had again, so songs after a pause played silent.
static bool spkHeld = false;

static bool useSpeaker() {
  micClose();
  if (!M5Cardputer.Speaker.isRunning() && !M5Cardputer.Speaker.begin()) {
    usbdev::log(String("speaker: could not start, heap free=") + heap_caps_get_free_size(MALLOC_CAP_8BIT) +
                " largest=" + heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
    return false;
  }
  fadeIn();
  spkLastUse = millis();
  return true;
}

// Replaces M5Unified's speaker on/off step (see spkEnable); main.cpp calls it
// once after M5Cardputer.begin().
// For finding a headphone-detect line (USB console "!pins"): the raw input
// levels of every GPIO, the keyboard controller's (TCA8418, 0x34) GPIO status
// and which chips answer on the internal I2C bus. Reads only.
String hwProbe() {
  char b[96];
  snprintf(b, sizeof b, "gpio in0=%08lx in1=%08lx", (unsigned long)REG_READ(GPIO_IN_REG), (unsigned long)REG_READ(GPIO_IN1_REG));
  String out = b;
  out += " tca8418=";
  for (uint8_t r : {0x14, 0x15, 0x16}) {
    snprintf(b, sizeof b, "%02x ", M5.In_I2C.readRegister8(0x34, r, 400000));
    out += b;
  }
  out += "i2c:";
  for (uint8_t a = 0x08; a < 0x78; a++)
    if (M5.In_I2C.scanID(a, 400000)) { snprintf(b, sizeof b, " %02x", a); out += b; }
  return out;
}

// setCallback is protected in M5Unified; a derived class may take its address.
struct SpkHook : m5::Speaker_Class {
  static void install(m5::Speaker_Class &spk, bool (*fn)(void *, bool)) { (spk.*(&SpkHook::setCallback))(nullptr, fn); }
};
void hwAudioBegin() {
  if (!codecVolume()) return;
  SpkHook::install(M5Cardputer.Speaker, spkEnable);
  // 44.1 kHz like nearly all music: M5Unified ran at 48 kHz and resampled by
  // straight-line interpolation, which dulls the highs and adds distortion
  auto c = M5Cardputer.Speaker.config();
  c.sample_rate = 44100;
  // 6 DMA buffers of 256 frames (35 ms) instead of 8: 2 KB less while playing;
  // the decoder keeps three ~26 ms frames queued ahead of them anyway
  c.dma_buf_count = 6;
  M5Cardputer.Speaker.config(c);
  M5Cardputer.Speaker.setVolume(UNITY_MASTER);
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
  logAudioStack("record");
  aTask = nullptr;
  vTaskDelete(nullptr);
}

// Lets the last queued buffers play out, at most 2 s: a speaker that never
// finishes must not keep the task (and "audio busy") alive.
static void speakerDrain() {
  uint32_t t0 = millis();
  while (M5Cardputer.Speaker.isPlaying(0) && millis() - t0 < 2000) vTaskDelay(2);
  if (M5Cardputer.Speaker.isPlaying(0)) M5Cardputer.Speaker.stop(0);
}

// Starts an audio task, or logs why it couldn't (its stack is 8 KB in one
// block, which a fragmented heap may not have).
static bool startAudioTask(TaskFunction_t fn, const char *name) {
  // 6 KB: the decoder works in its heap buffers; its largest local array is
  // 768 bytes (the log shows what each run used, see logAudioStack)
  if (xTaskCreatePinnedToCore(fn, name, 6144, nullptr, 3, &aTask, 0) == pdPASS) return true;
  aTask = nullptr;
  usbdev::log(String("audio: no memory for the ") + name + " task, heap free=" + heap_caps_get_free_size(MALLOC_CAP_8BIT) +
              " largest=" + heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
  return false;
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
      eqProcess(buf[idx], n / 2, aStereo ? 2 : 1, aRate);
      M5Cardputer.Speaker.playRaw(buf[idx], n / 2, aRate, aStereo, 1, 0);
      aSamples = aSamples + n / frame;
      spkLastUse = millis();
      idx ^= 1;
    }
    if (aStop) M5Cardputer.Speaker.stop(0);
    speakerDrain();
  }
  aFile.close();
  free(buf[0]);
  free(buf[1]);
  store::pin(false);
  aMode = A_IDLE;
  logAudioStack("WAV");
  aTask = nullptr;
  vTaskDelete(nullptr);
}

// MP3 playback, mixed to mono (the ADV has one speaker and a mono DAC). About
// 38 KB while playing, all of it freed when playback ends. No single block is
// over 8.4 KB: with Wi-Fi off the heap has room, but in pieces (one 16 KB
// block was often not to be had), so the decoder's scratch arrays and the
// three output frames are separate blocks.
// MP3_IN holds the frame being decoded and the start of the next; it is
// topped up whenever less than MP3_REFILL is left, which is more than the
// largest frame (1441 bytes), so a frame is never cut in two.
static const size_t MP3_IN = 2560, MP3_REFILL = 1536, MP3_FRAME = 1152;
static const size_t GRBUF = 2 * 576 * sizeof(float), SYN = (18 + 15) * 2 * 32 * sizeof(float);
static mp3dec_t *mDec = nullptr;
static uint8_t *mIn = nullptr;
static int16_t *mPcm = nullptr, *mOut[3] = {nullptr, nullptr, nullptr};  // three mono frames
static int mInLen = 0;
static uint32_t mKbps = 0, mXingBytes = 0;
static uint8_t *mToc = nullptr;  // Xing seek table (100 bytes), VBR files only

static void mp3Free() {
  if (mp3Scratch) {
    mp3dec_scratch_t *sc = (mp3dec_scratch_t *)mp3Scratch;
    vm::audioFree(sc->grbuf);
    vm::audioFree(sc->syn);
  }
  vm::audioFree(mDec); vm::audioFree(mp3Scratch); vm::audioFree(mIn); vm::audioFree(mPcm); free(mToc);
  for (auto &o : mOut) { vm::audioFree(o); o = nullptr; }
  mDec = nullptr; mp3Scratch = nullptr; mIn = nullptr; mPcm = nullptr; mToc = nullptr;
}

// Largest first, so the big blocks get the big gaps; any that the heap can't
// hold come from the Lua arena's spare room (vm::audioAlloc).
static bool mp3Alloc() {
  float (*syn)[2 * 32] = (float (*)[2 * 32])vm::audioAlloc(SYN);
  mDec = (mp3dec_t *)vm::audioAlloc(sizeof(mp3dec_t));
  float (*grbuf)[576] = (float (*)[576])vm::audioAlloc(GRBUF);
  mPcm = (int16_t *)vm::audioAlloc(MINIMP3_MAX_SAMPLES_PER_FRAME * 2);
  mIn = (uint8_t *)vm::audioAlloc(MP3_IN);
  mp3Scratch = vm::audioAlloc(sizeof(mp3dec_scratch_t));
  if (mp3Scratch) {
    memset(mp3Scratch, 0, sizeof(mp3dec_scratch_t));
    ((mp3dec_scratch_t *)mp3Scratch)->grbuf = grbuf;
    ((mp3dec_scratch_t *)mp3Scratch)->syn = syn;
  } else {
    vm::audioFree(grbuf);
    vm::audioFree(syn);
  }
  for (auto &o : mOut) o = (int16_t *)vm::audioAlloc(MP3_FRAME * 2);
  bool ok = mDec && mp3Scratch && grbuf && syn && mIn && mPcm && mOut[0] && mOut[1] && mOut[2];
  int borrowed = 0;
  for (const void *p : {(const void *)syn, (const void *)mDec, (const void *)grbuf, (const void *)mPcm, (const void *)mIn,
                        (const void *)mp3Scratch, (const void *)mOut[0], (const void *)mOut[1], (const void *)mOut[2]})
    if (p && vm::inArena(p)) borrowed++;
  if (ok) {
    mp3dec_init(mDec);
    mInLen = 0;
    if (borrowed) usbdev::log(String("mp3: ") + borrowed + " of 9 buffers from the Lua arena (heap largest " +
                              heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) + ")");
    return true;
  }
  usbdev::log(String("mp3: not enough memory, heap free=") + heap_caps_get_free_size(MALLOC_CAP_8BIT) + " largest=" +
              heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) + " arena free=" + vm::arenaFree());
  mp3Free();
  return false;
}

// ---------------------------------------------------------------- equalizer
// Bass (low shelf 150 Hz), middle (peak 1.5 kHz) and treble (high shelf 5 kHz)
// on what plays, in the audio task. The preset is chosen from Lua (eqWant);
// the task recomputes its filters when that or the sample rate changes.
// Boosts come with an equal cut in front, so they can't clip.
struct EqPreset { const char *id, *name; int8_t bass, mid, treble; };
static const EqPreset EQ_PRESETS[] = {
    {"flat", "Flat", 0, 0, 0},     {"warm", "Warm", 2, 0, -6},   {"soft", "Less treble", 0, 0, -9},
    {"bass", "Bass", 6, 0, -3},    {"vocal", "Vocal", -3, 3, -3}};
static const int EQ_COUNT = sizeof EQ_PRESETS / sizeof EQ_PRESETS[0];
static volatile int eqWant = -1;  // -1: read the setting at the next play
static int eqHave = -2;
static uint32_t eqRate = 0;
struct Biquad { float b0, b1, b2, a1, a2, z1[2], z2[2]; bool on; };
static Biquad eqBands[3];
static float eqPre = 1;

static int eqIndex(const String &id) {
  for (int i = 0; i < EQ_COUNT; i++) if (id == EQ_PRESETS[i].id) return i;
  return 0;
}

// RBJ audio EQ cookbook: type 0 low shelf, 1 peak, 2 high shelf.
static void eqDesign(Biquad &q, int type, float f, float db, uint32_t rate) {
  q.on = db != 0;
  q.z1[0] = q.z1[1] = q.z2[0] = q.z2[1] = 0;
  if (!q.on) return;
  float A = powf(10, db / 40), w = 2 * (float)M_PI * f / rate, c = cosf(w), sn = sinf(w);
  float b0, b1, b2, a0, a1, a2;
  if (type == 1) {
    float al = sn / (2 * 0.9f);
    b0 = 1 + al * A; b1 = -2 * c; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * c; a2 = 1 - al / A;
  } else {
    float al = sn / 2 * sqrtf(2), r = 2 * sqrtf(A) * al;
    if (type == 0) {
      b0 = A * ((A + 1) - (A - 1) * c + r); b1 = 2 * A * ((A - 1) - (A + 1) * c); b2 = A * ((A + 1) - (A - 1) * c - r);
      a0 = (A + 1) + (A - 1) * c + r; a1 = -2 * ((A - 1) + (A + 1) * c); a2 = (A + 1) + (A - 1) * c - r;
    } else {
      b0 = A * ((A + 1) + (A - 1) * c + r); b1 = -2 * A * ((A - 1) + (A + 1) * c); b2 = A * ((A + 1) + (A - 1) * c - r);
      a0 = (A + 1) - (A - 1) * c + r; a1 = 2 * ((A - 1) - (A + 1) * c); a2 = (A + 1) - (A - 1) * c - r;
    }
  }
  q.b0 = b0 / a0; q.b1 = b1 / a0; q.b2 = b2 / a0; q.a1 = a1 / a0; q.a2 = a2 / a0;
}

// Filters n samples in place (ch = 1 mono, 2 interleaved stereo).
static void eqProcess(int16_t *s, int n, int ch, uint32_t rate) {
  int want = eqWant < 0 ? 0 : eqWant;
  if (want != eqHave || rate != eqRate) {
    const EqPreset &p = EQ_PRESETS[want];
    eqDesign(eqBands[0], 0, 150, p.bass, rate);
    eqDesign(eqBands[1], 1, 1500, p.mid, rate);
    eqDesign(eqBands[2], 2, 5000, p.treble, rate);
    int boost = max(0, (int)max(p.bass, max(p.mid, p.treble)));
    eqPre = powf(10, -boost / 20.0f);
    eqHave = want, eqRate = rate;
  }
  if (!eqBands[0].on && !eqBands[1].on && !eqBands[2].on) return;
  for (int i = 0; i < n; i++) {
    int c = ch == 2 ? (i & 1) : 0;
    float x = s[i] * eqPre;
    for (auto &q : eqBands) {
      if (!q.on) continue;
      float y = q.b0 * x + q.z1[c];
      q.z1[c] = q.b1 * x - q.a1 * y + q.z2[c];
      q.z2[c] = q.b2 * x - q.a2 * y;
      x = y;
    }
    s[i] = x > 32767 ? 32767 : x < -32768 ? -32768 : (int16_t)x;
  }
}

// eq([id]) -> id, name: the preset (saved as the "eq" setting); with an id it
// is changed first. eq_presets() -> { {id=, name=}, ... }
static int au_eq(lua_State *L) {
  if (lua_isstring(L, 1)) {
    eqWant = eqIndex(lua_tostring(L, 1));
    cfgSet("eq", EQ_PRESETS[eqWant].id);
  } else if (eqWant < 0) {
    eqWant = eqIndex(cfgGet("eq", "flat"));
  }
  lua_pushstring(L, EQ_PRESETS[eqWant].id);
  lua_pushstring(L, EQ_PRESETS[eqWant].name);
  return 2;
}
static int au_eq_presets(lua_State *L) {
  lua_createtable(L, EQ_COUNT, 0);
  for (int i = 0; i < EQ_COUNT; i++) {
    lua_createtable(L, 0, 2);
    lua_pushstring(L, EQ_PRESETS[i].id); lua_setfield(L, -2, "id");
    lua_pushstring(L, EQ_PRESETS[i].name); lua_setfield(L, -2, "name");
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

// Decodes the next frame into out as mono; returns the sample count, 0 at the end.
static int mp3Next(int16_t *out, mp3dec_frame_info_t &info) {
  while (true) {
    if (mInLen < (int)MP3_REFILL) {
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

// Created before the MP3 buffers (so its stack gets a block while large ones
// are still free); it waits until au_play has set everything up, or exits if
// that failed.
static void mp3Task(void *) {
  ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
  if (aStop) vTaskDelete(nullptr);  // au_play already forgot this task
  mp3dec_frame_info_t info;
  int idx = 0;
  while (!aStop) {
    if (aSeekTo >= 0) { uint32_t at = aSeekTo; aSeekTo = -1; mp3Seek(at); }
    if (aPaused) { pausedWait(); continue; }
    // three buffers: one playing, one queued, one being decoded
    int16_t *o = mOut[idx];
    int n = mp3Next(o, info);
    if (n <= 0) break;
    eqProcess(o, n, 1, info.hz);
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
  speakerDrain();
  aFile.close();
  mp3Free();
  store::pin(false);
  aMode = A_IDLE;
  logAudioStack("MP3");
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
  if (aMode == A_PLAY) fadeOut();
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
  if (!startAudioTask(recTask, "rec")) {
    aMode = A_IDLE;
    aFile.close(); micClose(); store::pin(false); lua_pushboolean(L, 0); lua_pushstring(L, "not enough memory to record"); return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

// Plays an MP3 or 16-bit PCM WAV file. Returns true, or false + reason.
static int au_play(lua_State *L) {
  if (eqWant < 0) eqWant = eqIndex(cfgGet("eq", "flat"));
  if (!audioStop()) { lua_pushboolean(L, 0); lua_pushstring(L, "audio busy"); return 2; }
  String real;
  fs::FS *fs = store::resolve(str(L, 1), real);
  if (!fs || !(aFile = fs->open(real, "r"))) { lua_pushboolean(L, 0); lua_pushstring(L, "cannot open"); return 2; }
  String lower = real;
  lower.toLowerCase();
  aPaused = false;
  aSeekTo = lua_isnumber(L, 2) && lua_tonumber(L, 2) > 0 ? (int32_t)lua_tonumber(L, 2) : -1;
  // the speaker's DMA buffers first, while the heap has room for them
  if (!useSpeaker()) { aFile.close(); lua_pushboolean(L, 0); lua_pushstring(L, "not enough memory for the speaker"); return 2; }
  spkHeld = true;
  if (lower.endsWith(".mp3")) {
    aStop = false;
    if (!startAudioTask(mp3Task, "mp3")) {
      aFile.close(); lua_pushboolean(L, 0); lua_pushstring(L, "not enough memory to play"); return 2;
    }
    const char *why = mp3Start();
    if (*why) {
      aStop = true;  // the waiting task exits
      xTaskNotifyGive(aTask);
      aTask = nullptr;
      aFile.close(); lua_pushboolean(L, 0); lua_pushstring(L, why); return 2;
    }
    aSamples = 0;
    store::pin(true);
    fadeIn();
    aMode = A_PLAY;
    xTaskNotifyGive(aTask);
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
  fadeIn();
  aStop = false;
  aMode = A_PLAY;
  if (!startAudioTask(playTask, "play")) {
    aMode = A_IDLE;
    aFile.close(); store::pin(false); lua_pushboolean(L, 0); lua_pushstring(L, "not enough memory to play"); return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int au_stop(lua_State *L) {
  audioStop();
  return 0;
}

// pause(on) pauses or resumes playback; returns whether it is paused.
static int au_pause(lua_State *L) {
  bool on = lua_toboolean(L, 1);
  if (aMode == A_PLAY && on && !aPaused) { fadeOut(); aPaused = true; }
  else if (aMode == A_PLAY && !on && aPaused) { aPaused = false; fadeIn(); }
  lua_pushboolean(L, aMode == A_PLAY && aPaused);
  return 1;
}

// seek(seconds) jumps within the playing track.
static int au_seek(lua_State *L) {
  if (aMode == A_PLAY) {
    fadeOut();
    aSeekTo = max(0, (int)luaL_checknumber(L, 1));
    fadeInAt = millis() + 60;  // once the new position plays (hwTick)
  }
  return 0;
}

// status() -> "idle"|"recording"|"playing"|"paused", seconds done, seconds total
static int au_status(lua_State *L) {
  lua_pushstring(L, aMode == A_REC ? "recording" : aMode == A_PLAY ? (aPaused ? "paused" : "playing") : "idle");
  lua_pushnumber(L, (float)aSamples / aRate);
  lua_pushnumber(L, aMode == A_PLAY ? (float)aTotal / aRate : 0);
  return 3;
}

// tags(path) -> {title, artist, album, track, genre} from the file's ID3 tag
// (see readTags in musiclib.cpp); missing fields are left out.
static int au_tags(lua_State *L) {
  Tags t;
  readTags(str(L, 1), t);
  lua_newtable(L);
  auto set = [&](const char *key, const String &v) {
    if (!v.length()) return;
    lua_pushstring(L, v.c_str());
    lua_setfield(L, -2, key);
  };
  set("title", t.title);
  set("artist", t.artist);
  set("album", t.album);
  set("track", t.track);
  set("genre", t.genre);
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
  if (fadeInAt && (int32_t)(millis() - fadeInAt) >= 0) { fadeInAt = 0; if (aMode == A_PLAY && !aPaused) fadeIn(); }
  // Stop the speaker a few seconds after the last sound to free its buffers.
  if (aMode == A_IDLE && !spkHeld && M5Cardputer.Speaker.isRunning()) {
    if (M5Cardputer.Speaker.isPlaying()) spkLastUse = millis();
    else if (millis() - spkLastUse > 4000) M5Cardputer.Speaker.end();
  }
  // Same for the mic once analyze() stops being called.
  if (aMode == A_IDLE && micRx && millis() - micLastUse > 4000) micClose();
}

// Frees the speaker and mic drivers when nothing is playing or recording
// (their DMA buffers and task hold over 10 KB): the shell calls this before
// starting Wi-Fi, which needs every KB it can get.
void hwReleaseAudio() {
  if (aMode != A_IDLE) return;
  spkHeld = false;
  if (M5Cardputer.Speaker.isRunning()) M5Cardputer.Speaker.end();
  micClose();
}

// Whether a recording or playback is running (the shell skips its beeps).
bool hwAudioBusy() { return aMode != A_IDLE; }

// Shared by snd.tone in bindings.cpp. False while recording: the speaker would
// take the mic's pins and end the recording.
bool hwUseSpeaker() {
  if (aMode == A_REC) return false;
  return useSpeaker();
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
  http.setUserAgent("PocketLua-Cardputer");
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
  http.setUserAgent("PocketLua-Cardputer");
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
static Module *radioMod = nullptr;  // SX1262 does not own it
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
  if (!radio) radio = new SX1262(radioMod = new Module(5, 4, 3, 6));
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

static void loraOff() {
  if (radio) { radio->sleep(); delete radio; radio = nullptr; }
  delete radioMod;
  radioMod = nullptr;
}
static int lo_stop(lua_State *L) { loraOff(); return 0; }

// =============================================================== GPS (Cap LoRa-1262)
static TinyGPSPlus *gpsP = nullptr;
static int gp_start(lua_State *L) {
  if (!gpsP) gpsP = new TinyGPSPlus();
  Serial1.begin(115200, SERIAL_8N1, 15, 13);
  return 0;
}
static void gpsOff() {
  if (gpsP) Serial1.end();
  delete gpsP;
  gpsP = nullptr;
}
static int gp_stop(lua_State *L) { gpsOff(); return 0; }

// Called by the shell when an app closes (or fails): the LoRa radio and the GPS
// serial port go off and give back their memory, whether or not the app
// stopped them. Drivers belong to the core; an app only borrows them.
void hwReleaseDrivers() {
  loraOff();
  gpsOff();
}

// Before deep sleep: playback and recording stopped, the speaker driver
// released, the codec and the IMU powered down, LoRa and GPS off.
void hwSleepPrepare() {
  audioStop();
  spkHeld = false;
  if (M5Cardputer.Speaker.isRunning()) M5Cardputer.Speaker.end();
  micClose();
  if (codecVolume()) {
    static const uint8_t off[][2] = {{0x32, 0x00}, {0x13, 0x00}, {0x12, 0x02}, {0x0D, 0xFC}};
    for (auto &r : off) M5.In_I2C.writeRegister8(ES8311, r[0], r[1], 400000);
  }
  hwReleaseDrivers();
  M5.Imu.sleep();
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
                                    {"status", au_status}, {"analyze", au_analyze}, {"eq", au_eq},
                                    {"eq_presets", au_eq_presets}, {nullptr, nullptr}};
static const luaL_Reg irLib[] = {{"send", ir_send}, {nullptr, nullptr}};
static const luaL_Reg i2cLib[] = {{"scan", i2_scan}, {"read", i2_read}, {"write", i2_write},
                                  {"read_reg", i2_read_reg}, {"write_reg", i2_write_reg}, {nullptr, nullptr}};
static const luaL_Reg httpLib[] = {{"get", ht_get}, {"download", ht_download}, {"dns", ht_dns}, {"ping", ht_ping}, {nullptr, nullptr}};
static const luaL_Reg loraLib[] = {{"begin", lo_begin}, {"send", lo_send}, {"recv", lo_recv},
                                   {"busy", lo_busy}, {"stop", lo_stop}, {nullptr, nullptr}};
static const luaL_Reg gpsLib[] = {{"start", gp_start}, {"stop", gp_stop}, {"read", gp_read}, {nullptr, nullptr}};
static const luaL_Reg dispLib[] = {{"image", di_image}, {"fill", di_fill}, {"text", di_text}, {nullptr, nullptr}};
extern const luaL_Reg musiclibFns[];  // musiclib.cpp
extern const luaL_Reg appstoreFns[];  // appstore.cpp
extern const luaL_Reg backupFns[];    // backup.cpp
static const struct { const char *name; const luaL_Reg *fns; } HW_LIBS[] = {
    {"audio", audioLib}, {"ir", irLib}, {"i2c", i2cLib}, {"http", httpLib},
    {"lora", loraLib}, {"gps", gpsLib}, {"disp", dispLib}, {"musiclib", musiclibFns},
    {"appstore", appstoreFns}, {"backup", backupFns}};

// sys.hwlib(name) -> the table for that driver or library, or nil (runtime.lua
// calls it the first time an app uses one of these globals)
static int hw_lib(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  for (auto &l : HW_LIBS)
    if (!strcmp(l.name, name)) { luaL_newlib(L, l.fns); return 1; }
  if (openApiLib(L, name)) return 1;
  // standard libraries most apps don't need at once (vm.cpp opens base and string)
  static const struct { const char *name; lua_CFunction open; } STD[] = {
      {"math", luaopen_math}, {"table", luaopen_table}, {"utf8", luaopen_utf8}, {"coroutine", luaopen_coroutine}};
  for (auto &l : STD)
    if (!strcmp(l.name, name)) { luaL_requiref(L, l.name, l.open, 0); return 1; }
  lua_pushnil(L);
  return 1;
}

void registerHw(lua_State *L) {
  lua_getglobal(L, "sys");
  lua_pushcfunction(L, hw_lib);
  lua_setfield(L, -2, "hwlib");
  lua_pop(L, 1);
}
