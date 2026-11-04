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
static bool aStereo = false;
static uint32_t spkLastUse = 0;
static const size_t ABUF = 1024;  // samples per buffer

static void useSpeaker() {
  if (M5Cardputer.Mic.isRunning()) M5Cardputer.Mic.end();
  if (!M5Cardputer.Speaker.isRunning()) M5Cardputer.Speaker.begin();
  spkLastUse = millis();
}

static bool useMic(uint32_t rate) {
  if (M5Cardputer.Speaker.isRunning()) M5Cardputer.Speaker.end();
  auto c = M5Cardputer.Mic.config();
  if (!M5Cardputer.Mic.isRunning() || c.sample_rate != rate) {
    M5Cardputer.Mic.end();
    c.sample_rate = rate;
    M5Cardputer.Mic.config(c);
    bool ok = M5Cardputer.Mic.begin();
    usbdev::log(String("mic begin ") + (ok ? "ok" : "FAILED") + " rate=" + rate + " enabled=" +
                M5Cardputer.Mic.isEnabled() + " running=" + M5Cardputer.Mic.isRunning());
    return ok;
  }
  return true;
}

static void wavHeader(uint8_t *h, uint32_t rate, uint32_t dataBytes) {
  auto put32 = [&](int o, uint32_t v) { h[o] = v; h[o + 1] = v >> 8; h[o + 2] = v >> 16; h[o + 3] = v >> 24; };
  auto put16 = [&](int o, uint16_t v) { h[o] = v; h[o + 1] = v >> 8; };
  memcpy(h, "RIFF", 4); put32(4, 36 + dataBytes); memcpy(h + 8, "WAVEfmt ", 8);
  put32(16, 16); put16(20, 1); put16(22, 1); put32(24, rate); put32(28, rate * 2); put16(32, 2); put16(34, 16);
  memcpy(h + 36, "data", 4); put32(40, dataBytes);
}

static void recTask(void *) {
  int16_t *buf[2] = {(int16_t *)malloc(ABUF * 2), (int16_t *)malloc(ABUF * 2)};
  if (buf[0] && buf[1]) {
    M5Cardputer.Mic.record(buf[0], ABUF, aRate);
    M5Cardputer.Mic.record(buf[1], ABUF, aRate);
    int idx = 0;
    while (!aStop && aSamples < aRate * 600) {  // 10 minutes max
      while (M5Cardputer.Mic.isRecording() == 2) vTaskDelay(1);
      aFile.write((uint8_t *)buf[idx], ABUF * 2);
      aSamples = aSamples + ABUF;
      M5Cardputer.Mic.record(buf[idx], ABUF, aRate);
      idx ^= 1;
    }
    while (M5Cardputer.Mic.isRecording()) vTaskDelay(1);
  }
  usbdev::log(String("recording done: ") + aSamples + " samples (" + (aSamples / (aRate ? aRate : 1)) + " s)" +
              (buf[0] && buf[1] ? "" : " - no buffer memory"));
  uint8_t h[44];
  wavHeader(h, aRate, aSamples * 2);
  aFile.seek(0);
  aFile.write(h, 44);
  aFile.close();
  free(buf[0]);
  free(buf[1]);
  M5Cardputer.Mic.end();
  store::pin(false);
  aMode = A_IDLE;
  aTask = nullptr;
  vTaskDelete(nullptr);
}

static void playTask(void *) {
  int16_t *buf[2] = {(int16_t *)malloc(ABUF * 2), (int16_t *)malloc(ABUF * 2)};
  if (buf[0] && buf[1]) {
    int idx = 0;
    while (!aStop) {
      int n = aFile.read((uint8_t *)buf[idx], ABUF * 2);
      if (n <= 0) break;
      while (M5Cardputer.Speaker.isPlaying(0) >= 2 && !aStop) vTaskDelay(1);
      M5Cardputer.Speaker.playRaw(buf[idx], n / 2, aRate, aStereo, 1, 0);
      aSamples = aSamples + n / 2 / (aStereo ? 2 : 1);
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

static int au_record(lua_State *L) {
  if (aMode != A_IDLE) return luaL_error(L, "audio busy");
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

// Plays a 16-bit PCM WAV file. Returns true, or false + reason.
static int au_play(lua_State *L) {
  if (aMode != A_IDLE) return luaL_error(L, "audio busy");
  String real;
  fs::FS *fs = store::resolve(str(L, 1), real);
  if (!fs || !(aFile = fs->open(real, "r"))) { lua_pushboolean(L, 0); lua_pushstring(L, "cannot open"); return 2; }
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
  if (aMode == A_IDLE) return 0;
  aStop = true;
  uint32_t t0 = millis();
  while (aMode != A_IDLE && millis() - t0 < 1500) delay(5);
  luaBudgetReset();
  return 0;
}

// status() -> "idle"|"recording"|"playing", seconds done, seconds total
static int au_status(lua_State *L) {
  lua_pushstring(L, aMode == A_REC ? "recording" : aMode == A_PLAY ? "playing" : "idle");
  lua_pushnumber(L, (float)aSamples / aRate);
  lua_pushnumber(L, aMode == A_PLAY ? (float)aTotal / aRate : 0);
  return 3;
}

// analyze() listens for ~32 ms and returns level (0-1), peak (0-1), pitch in Hz
// (0 if none) and a table of 8 band levels from 100 Hz to 4 kHz.
static int au_analyze(lua_State *L) {
  if (aMode != A_IDLE) return luaL_error(L, "audio busy");
  const int N = 512;
  const uint32_t rate = 16000;
  int16_t *s = (int16_t *)malloc(N * 2);
  if (!s) return luaL_error(L, "not enough memory");
  if (!useMic(rate)) { free(s); return luaL_error(L, "microphone failed to start"); }
  M5Cardputer.Mic.record(s, N, rate);
  while (M5Cardputer.Mic.isRecording()) vTaskDelay(1);

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
}

// Shared by snd.tone in bindings.cpp
void hwUseSpeaker() { useSpeaker(); }

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
                                    {"status", au_status}, {"analyze", au_analyze}, {nullptr, nullptr}};
static const luaL_Reg irLib[] = {{"send", ir_send}, {nullptr, nullptr}};
static const luaL_Reg i2cLib[] = {{"scan", i2_scan}, {"read", i2_read}, {"write", i2_write},
                                  {"read_reg", i2_read_reg}, {"write_reg", i2_write_reg}, {nullptr, nullptr}};
static const luaL_Reg httpLib[] = {{"get", ht_get}, {"download", ht_download}, {"dns", ht_dns}, {"ping", ht_ping}, {nullptr, nullptr}};
static const luaL_Reg loraLib[] = {{"begin", lo_begin}, {"send", lo_send}, {"recv", lo_recv},
                                   {"busy", lo_busy}, {"stop", lo_stop}, {nullptr, nullptr}};
static const luaL_Reg gpsLib[] = {{"start", gp_start}, {"stop", gp_stop}, {"read", gp_read}, {nullptr, nullptr}};
static const luaL_Reg dispLib[] = {{"image", di_image}, {"fill", di_fill}, {"text", di_text}, {nullptr, nullptr}};
static const struct { const char *name; const luaL_Reg *fns; } HW_LIBS[] = {
    {"audio", audioLib}, {"ir", irLib}, {"i2c", i2cLib}, {"http", httpLib},
    {"lora", loraLib}, {"gps", gpsLib}, {"disp", dispLib}};

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
