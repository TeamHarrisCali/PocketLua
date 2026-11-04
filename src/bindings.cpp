#include "bindings.h"
#include <vector>
#include <M5Cardputer.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <Preferences.h>
#include <time.h>
#include <math.h>
#include <esp_heap_caps.h>
#include "storage.h"
#include "usbdev.h"
#include "mesh.h"
#include "system.h"
#include "vm.h"
extern "C" {
#include "lstrip.h"
}

extern M5Canvas canvas;
// ---------------------------------------------------------------- settings
// Settings live in data/settings.txt (key=value lines), cached in RAM and
// written 2 s after the last change. They used to be in NVS, the chip's small
// settings partition shared with M5Launcher and Wi-Fi; LiveOS filled it and
// Wi-Fi could no longer start (ESP_ERR_NVS_NOT_ENOUGH_SPACE).
static const char *SETTINGS_FILE = "data/settings.txt";
static std::vector<std::pair<String, String>> settings;
static bool settingsLoaded = false, settingsDirty = false;
static uint32_t settingsChanged = 0;

static const char *OLD_KEYS[] = {
    "2048_best", "accent", "alarms", "am_axes", "am_flags", "am_sens", "blocks_best", "bright", "click", "clock12",
    "debug_sys", "dev_key", "dev_name", "dev_on", "dock", "gps_log_n", "gps_units", "ir_brand", "ir_saddr", "lock",
    "lora_beacon", "lora_call", "lora_freq", "lora_sf", "marble_axes", "marble_b1", "marble_b2", "marble_b3",
    "marble_b4", "marble_b5", "marble_cal", "morse_best", "morse_wpm", "shot_n", "sleep", "snake_best", "sounds",
    "steps_day", "steps_goal", "steps_n", "steps_sens", "steps_stride", "store_url", "theme", "tz", "usb_console",
    "usb_drive", "usb_kbd", "usb_mouse", "usb_serial", "vol", "wifi_auto", "wifi_pass", "wifi_ssid", "wx_last",
    "wx_loc", "wx_time", "wx_units"};

static String escapeValue(const String &v) {
  String o;
  for (char c : v) {
    if (c == '\\') o += "\\\\";
    else if (c == '\n') o += "\\n";
    else o += c;
  }
  return o;
}

static String unescapeValue(const String &v) {
  String o;
  for (size_t i = 0; i < v.length(); i++) {
    if (v[i] == '\\' && i + 1 < v.length()) { o += v[i + 1] == 'n' ? '\n' : v[i + 1]; i++; }
    else o += v[i];
  }
  return o;
}

static void saveSettingsNow() {
  String out;
  for (auto &kv : settings) out += kv.first + "=" + escapeValue(kv.second) + "\n";
  if (store::write(SETTINGS_FILE, out)) settingsDirty = false;
}

static void loadSettings() {
  settingsLoaded = true;
  String text;
  if (store::readText(SETTINGS_FILE, text)) {
    int s = 0;
    while (s < (int)text.length()) {
      int e = text.indexOf('\n', s);
      if (e < 0) e = text.length();
      String line = text.substring(s, e);
      int eq = line.indexOf('=');
      if (eq > 0) settings.push_back({line.substring(0, eq), unescapeValue(line.substring(eq + 1))});
      s = e + 1;
    }
    return;
  }
  // First boot with the file: move the old NVS settings over, then free NVS.
  Preferences p;
  if (p.begin("liveos", false)) {
    for (auto k : OLD_KEYS)
      if (p.isKey(k)) settings.push_back({k, p.getString(k, "")});
    saveSettingsNow();
    if (!settingsDirty) p.clear();
    p.end();
    usbdev::log(String("settings moved from NVS to ") + SETTINGS_FILE + ": " + settings.size() + " keys");
  }
}

static std::pair<String, String> *findSetting(const char *key) {
  if (!settingsLoaded) loadSettings();
  for (auto &kv : settings)
    if (kv.first == key) return &kv;
  return nullptr;
}

String cfgGet(const char *key, const char *def) {
  auto *kv = findSetting(key);
  return kv ? kv->second : String(def);
}

void cfgSet(const char *key, const String &value) {
  auto *kv = findSetting(key);
  if (kv && kv->second == value) return;
  if (kv) kv->second = value;
  else settings.push_back({key, value});
  settingsDirty = true;
  settingsChanged = millis();
}

static void cfgRemove(const char *key) {
  findSetting(key);
  for (size_t i = 0; i < settings.size(); i++)
    if (settings[i].first == key) {
      settings.erase(settings.begin() + i);
      settingsDirty = true;
      settingsChanged = millis();
      return;
    }
}

// Called every frame: writes the file a little after the last change.
void settingsTick() {
  if (settingsDirty && millis() - settingsChanged > 2000) saveSettingsNow();
}
void settingsFlush() {
  if (settingsDirty) saveSettingsNow();
}

static int num(lua_State *L, int i) { return (int)floorf((float)luaL_checknumber(L, i)); }
static int ny(lua_State *L, int i) { return num(L, i) - g_bandY; }  // screen y -> band y
static uint16_t col(lua_State *L, int i, uint16_t def = 0xFFFF) {
  return lua_isnoneornil(L, i) ? def : (uint16_t)luaL_checkinteger(L, i);
}
static String str(lua_State *L, int i) {
  size_t n;
  const char *s = luaL_checklstring(L, i, &n);
  return String(s);
}

// ---------------------------------------------------------------- gfx
static int g_rgb(lua_State *L) {
  lua_pushinteger(L, canvas.color565(num(L, 1), num(L, 2), num(L, 3)));
  return 1;
}
static int g_clear(lua_State *L) { canvas.fillSprite(col(L, 1, 0)); return 0; }
static int g_px(lua_State *L) { canvas.drawPixel(num(L, 1), ny(L, 2), col(L, 3)); return 0; }
static int g_line(lua_State *L) { canvas.drawLine(num(L, 1), ny(L, 2), num(L, 3), ny(L, 4), col(L, 5)); return 0; }
static int g_rect(lua_State *L) { canvas.drawRect(num(L, 1), ny(L, 2), num(L, 3), num(L, 4), col(L, 5)); return 0; }
static int g_fill(lua_State *L) { canvas.fillRect(num(L, 1), ny(L, 2), num(L, 3), num(L, 4), col(L, 5)); return 0; }
static int g_rrect(lua_State *L) { canvas.drawRoundRect(num(L, 1), ny(L, 2), num(L, 3), num(L, 4), num(L, 5), col(L, 6)); return 0; }
static int g_rfill(lua_State *L) { canvas.fillRoundRect(num(L, 1), ny(L, 2), num(L, 3), num(L, 4), num(L, 5), col(L, 6)); return 0; }
static int g_circle(lua_State *L) { canvas.drawCircle(num(L, 1), ny(L, 2), num(L, 3), col(L, 4)); return 0; }
static int g_disc(lua_State *L) { canvas.fillCircle(num(L, 1), ny(L, 2), num(L, 3), col(L, 4)); return 0; }
static int g_tri(lua_State *L) {
  canvas.fillTriangle(num(L, 1), ny(L, 2), num(L, 3), ny(L, 4), num(L, 5), ny(L, 6), col(L, 7));
  return 0;
}
static int g_arc(lua_State *L) {
  canvas.fillArc(num(L, 1), ny(L, 2), num(L, 3), num(L, 4), (float)luaL_checknumber(L, 5), (float)luaL_checknumber(L, 6), col(L, 7));
  return 0;
}
// Text is drawn straight from the Lua string: these run hundreds of times per
// second, and a heap String per call would fragment the small internal RAM.
static int g_text(lua_State *L) {
  const char *s = luaL_checkstring(L, 3);
  canvas.setTextSize((float)luaL_optnumber(L, 5, 1));
  canvas.setTextColor(col(L, 4));
  canvas.drawString(s, num(L, 1), ny(L, 2));
  return 0;
}
static int g_text_w(lua_State *L) {
  const char *s = luaL_checkstring(L, 1);
  canvas.setTextSize((float)luaL_optnumber(L, 2, 1));
  lua_pushinteger(L, canvas.textWidth(s));
  return 1;
}
static int g_clip(lua_State *L) { canvas.setClipRect(num(L, 1), ny(L, 2), num(L, 3), num(L, 4)); return 0; }
static int g_noclip(lua_State *L) { canvas.clearClipRect(); return 0; }
static int g_brightness(lua_State *L) {
  M5Cardputer.Display.setBrightness((uint8_t)constrain(num(L, 1), 0, 255));
  return 0;
}

// ---------------------------------------------------------------- snd / imu
// The speaker is stopped at boot to free its DMA buffers and task; it starts on
// the first sound.
void hwUseSpeaker();  // hw.cpp: stops the mic, starts the speaker
void playTone(uint16_t freq, uint32_t ms) {
  hwUseSpeaker();
  M5Cardputer.Speaker.tone(freq, ms);
}
static int s_tone(lua_State *L) {
  hwUseSpeaker();
  M5Cardputer.Speaker.tone((float)luaL_checknumber(L, 1), (uint32_t)luaL_optinteger(L, 2, 100));
  return 0;
}
static int s_stop(lua_State *L) { M5Cardputer.Speaker.stop(); return 0; }
static int s_volume(lua_State *L) {
  M5Cardputer.Speaker.setVolume((uint8_t)constrain(num(L, 1), 0, 255));
  return 0;
}

static int i_read(lua_State *L) {
  float ax = 0, ay = 0, az = 0, gx = 0, gy = 0, gz = 0;
  M5.Imu.update();
  M5.Imu.getAccel(&ax, &ay, &az);
  M5.Imu.getGyro(&gx, &gy, &gz);
  lua_createtable(L, 0, 6);
  const char *k[] = {"ax", "ay", "az", "gx", "gy", "gz"};
  float v[] = {ax, ay, az, gx, gy, gz};
  for (int i = 0; i < 6; i++) {
    lua_pushnumber(L, v[i]);
    lua_setfield(L, -2, k[i]);
  }
  return 1;
}

// ---------------------------------------------------------------- sys
static int y_millis(lua_State *L) { lua_pushinteger(L, (lua_Integer)(millis() & 0x7fffffff)); return 1; }
static int y_delay(lua_State *L) { delay(constrain(num(L, 1), 0, 50)); return 0; }
static int y_heap(lua_State *L) {
  lua_pushinteger(L, ESP.getFreeHeap());
  lua_pushinteger(L, (lua_Integer)vm::memUsed());
  lua_pushinteger(L, (lua_Integer)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
  lua_pushinteger(L, (lua_Integer)heap_caps_get_total_size(MALLOC_CAP_8BIT));
  return 4;
}
void batteryInfo(int &pct, bool &charging) {
  pct = constrain((int)M5Cardputer.Power.getBatteryLevel(), 0, 100);
  charging = M5Cardputer.Power.isCharging() == m5::Power_Class::is_charging;
}
static int y_battery(lua_State *L) {
  int pct;
  bool chg;
  batteryInfo(pct, chg);
  lua_pushinteger(L, pct);
  lua_pushboolean(L, chg);
  return 2;
}
static int y_reboot(lua_State *L) { settingsFlush(); ESP.restart(); return 0; }
// The app draws straight to the panel (disp.*) and frames are not redrawn.
static int y_display_hold(lua_State *L) { shell::setHold(lua_toboolean(L, 1)); return 0; }
static int y_screenshot(lua_State *L) { g_screenshotPath = str(L, 1); return 0; }

// Turns the panel off (backlight and controller sleep) and stops drawing.
// Waking leaves brightness at 0; the shell restores the user's setting.
static int y_display_sleep(lua_State *L) {
  bool on = lua_toboolean(L, 1);
  if (on == g_displayAsleep) return 0;
  g_displayAsleep = on;
  if (on) {
    M5Cardputer.Display.setBrightness(0);
    M5Cardputer.Display.sleep();
  } else {
    M5Cardputer.Display.wakeup();
  }
  return 0;
}
static int y_reload(lua_State *L) { shell::requestHome(); return 0; }
static int y_log(lua_State *L) { usbdev::log(str(L, 1)); return 0; }
static int y_recovered(lua_State *L) { lua_pushnil(L); return 1; }
static int y_read_text(lua_State *L) {
  String buf;
  const char *p;
  size_t n;
  size_t max = (size_t)luaL_optinteger(L, 2, 0);  // optional: only the first `max` bytes
  if (!store::view(str(L, 1), buf, p, n, false, max)) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, p, n);
  return 1;
}

// Compiles a script straight from flash or SD so its source text never has to
// be copied into the Lua heap. Returns the chunk, or nil + error (nil alone
// when the file does not exist). loadfile(path, builtin_only, strip): strip
// drops debug info (line numbers, local names), about 20% less RAM for code
// that stays loaded.
bool loadChunk(lua_State *L, const String &path, bool builtinOnly, bool strip, String &err) {
  String buf;
  const char *p;
  size_t n;
  err = "";
  if (!store::view(path, buf, p, n, builtinOnly)) return false;
  String chunk = "@" + path;
  if (luaL_loadbuffer(L, p, n, chunk.c_str()) != LUA_OK) {
    err = lua_tostring(L, -1);
    lua_pop(L, 1);
    return false;
  }
  if (strip) lua_stripdebug(L);  // in place: no dump buffer (see lstrip.c)
  return true;
}

static int y_loadfile(lua_State *L) {
  String err;
  if (loadChunk(L, str(L, 1), lua_toboolean(L, 2), lua_toboolean(L, 3), err)) return 1;
  lua_pushnil(L);
  if (!err.length()) return 1;
  lua_pushstring(L, err.c_str());
  return 2;
}
static int y_read_builtin(lua_State *L) {
  String buf;
  const char *p;
  size_t n;
  if (!store::view(str(L, 1), buf, p, n, true)) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, p, n);
  return 1;
}
static int y_write_text(lua_State *L) {
  size_t n;
  const char *s = luaL_checklstring(L, 2, &n);
  String data;
  if (n && !data.reserve(n + 1)) { lua_pushboolean(L, 0); return 1; }
  data.concat(s, n);
  lua_pushboolean(L, data.length() == n && store::write(str(L, 1), data));
  return 1;
}
// Appends to a file without reading it (logs, CSV tracks).
static int y_append_text(lua_State *L) {
  size_t n;
  const char *s = luaL_checklstring(L, 2, &n);
  lua_pushboolean(L, store::append(str(L, 1), s, n));
  return 1;
}
static int y_rename(lua_State *L) { lua_pushboolean(L, store::rename(str(L, 1), str(L, 2))); return 1; }
static int y_remove(lua_State *L) { lua_pushboolean(L, store::remove(str(L, 1))); return 1; }
static int y_exists(lua_State *L) { lua_pushboolean(L, store::exists(str(L, 1))); return 1; }
static int y_mkdirs(lua_State *L) { lua_pushboolean(L, store::mkdirs(str(L, 1))); return 1; }
static int y_in_storage(lua_State *L) { lua_pushboolean(L, store::inStorage(str(L, 1))); return 1; }
static int y_is_embedded(lua_State *L) { lua_pushboolean(L, store::embedded(str(L, 1))); return 1; }
static int y_list(lua_State *L) {
  auto items = store::list(str(L, 1));
  lua_createtable(L, items.size(), 0);
  int i = 1;
  for (auto &e : items) {
    lua_createtable(L, 0, 5);
    lua_pushstring(L, e.name.c_str()); lua_setfield(L, -2, "name");
    lua_pushboolean(L, e.dir); lua_setfield(L, -2, "dir");
    lua_pushboolean(L, e.stored); lua_setfield(L, -2, "stored");
    lua_pushboolean(L, e.emb); lua_setfield(L, -2, "emb");
    lua_pushinteger(L, (lua_Integer)e.size); lua_setfield(L, -2, "size");
    lua_rawseti(L, -2, i++);
  }
  return 1;
}
// Free space needs a scan of the whole FAT, so it is cached for 30 s.
static int y_storage(lua_State *L) {
  static uint32_t at = 0;
  static float total = 0, used = 0;
  if (!at || millis() - at > 30000) {
    total = (float)(store::totalBytes() / 1024);
    used = (float)(store::usedBytes() / 1024);
    at = millis();
    luaBudgetReset();
  }
  lua_pushstring(L, store::kind());
  lua_pushnumber(L, total);
  lua_pushnumber(L, used);
  return 3;
}

// ---------------------------------------------------------------- cfg
static int c_get(lua_State *L) {
  auto *kv = findSetting(luaL_checkstring(L, 1));
  if (!kv) { lua_pushnil(L); return 1; }
  lua_pushstring(L, kv->second.c_str());
  return 1;
}
static int c_set(lua_State *L) {
  const char *k = luaL_checkstring(L, 1);
  if (strlen(k) > 24) return luaL_error(L, "cfg key too long (max 24)");
  if (lua_isnil(L, 2)) cfgRemove(k);
  else cfgSet(k, luaL_tolstring(L, 2, nullptr));
  return 0;
}

// ---------------------------------------------------------------- wifi
static bool wifiConnecting = false;
static uint32_t wifiStart = 0;

// Returns whether the radio is now in the requested state. Starting it needs
// ~40-50 KB, so Lua garbage is collected first and the outcome is logged.
bool wifiEnable(bool on) {
  if (on) {
    WiFi.persistent(false);  // keep Wi-Fi config in RAM: NVS is small and shared with M5Launcher
    size_t before = heap_caps_get_free_size(MALLOC_CAP_8BIT);
    size_t largest = heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
    bool modeOk = WiFi.mode(WIFI_STA);
    wifi_mode_t gm = WiFi.getMode();
    bool ok = modeOk && gm != WIFI_OFF;
    usbdev::log(String("wifi start ") + (ok ? "ok" : "FAILED") + ": mode()=" + modeOk + " getMode=" + (int)gm +
                " free before=" + before + " largest=" + largest + " after=" + heap_caps_get_free_size(MALLOC_CAP_8BIT));
    if (!ok) {
      // WiFi.mode() only says yes/no. Ask the driver which step fails; these
      // calls do not tear anything down.
      wifi_mode_t dm = WIFI_MODE_NULL;
      esp_err_t ge = esp_wifi_get_mode(&dm);
      esp_err_t se = esp_wifi_set_mode(WIFI_MODE_STA);
      esp_err_t st = esp_wifi_start();
      usbdev::log(String("wifi diag: get_mode=") + esp_err_to_name(ge) + "/" + (int)dm + " set_mode=" + esp_err_to_name(se) +
                  " start=" + esp_err_to_name(st) + " internal_free=" + heap_caps_get_free_size(MALLOC_CAP_INTERNAL) +
                  " dma_largest=" + heap_caps_get_largest_free_block(MALLOC_CAP_DMA));
      if (st == ESP_OK) esp_wifi_stop();
    }
    return ok;
  }
  wifiConnecting = false;
  WiFi.disconnect(true);
  WiFi.mode(mesh::running() ? WIFI_STA : WIFI_OFF);  // device sharing needs the radio
  return true;
}
void wifiConnect(const char *ssid, const char *pass) {
  // Many networks have several access points with the same name on different
  // channels. Scan them all and join the strongest (the default fast scan
  // takes the first one it finds).
  WiFi.setScanMethod(WIFI_ALL_CHANNEL_SCAN);
  WiFi.setSortMethod(WIFI_CONNECT_AP_BY_SIGNAL);
  WiFi.begin(ssid, pass);
  wifiConnecting = true;
  wifiStart = millis();
}
// Apps should start Wi-Fi through shell.wifi_start (it checks memory first).
static int w_enable(lua_State *L) {
  if (lua_toboolean(L, 1)) lua_gc(L, LUA_GCCOLLECT);
  lua_pushboolean(L, wifiEnable(lua_toboolean(L, 1)));
  return 1;
}
static int w_connect(lua_State *L) {
  if (WiFi.getMode() == WIFI_OFF && !wifiEnable(true)) return 0;
  wifiConnect(str(L, 1).c_str(), lua_isnoneornil(L, 2) ? "" : str(L, 2).c_str());
  return 0;
}
static int w_disconnect(lua_State *L) {
  wifiConnecting = false;
  WiFi.disconnect();
  return 0;
}
static int w_status(lua_State *L) {
  const char *s = "idle";
  if (WiFi.getMode() == WIFI_OFF) {
    s = "off";
  } else if (WiFi.status() == WL_CONNECTED) {
    s = "connected";
    wifiConnecting = false;
  } else if (wifiConnecting) {
    wl_status_t st = WiFi.status();
    bool dead = st == WL_CONNECT_FAILED || st == WL_NO_SSID_AVAIL;
    s = (!dead && millis() - wifiStart < 15000) ? "connecting" : "failed";
  }
  lua_pushstring(L, s);
  return 1;
}
static int w_scan_start(lua_State *L) {
  if (WiFi.getMode() == WIFI_OFF) WiFi.mode(WIFI_STA);
  WiFi.scanNetworks(true);
  return 0;
}
static int w_scan_result(lua_State *L) {
  int n = WiFi.scanComplete();
  if (n == WIFI_SCAN_RUNNING) { lua_pushnil(L); return 1; }
  lua_createtable(L, n > 0 ? n : 0, 0);
  for (int i = 0; i < n && i < 20; i++) {
    lua_createtable(L, 0, 3);
    lua_pushstring(L, WiFi.SSID(i).c_str()); lua_setfield(L, -2, "ssid");
    lua_pushinteger(L, WiFi.RSSI(i)); lua_setfield(L, -2, "rssi");
    lua_pushboolean(L, WiFi.encryptionType(i) != WIFI_AUTH_OPEN); lua_setfield(L, -2, "secure");
    lua_pushinteger(L, WiFi.channel(i)); lua_setfield(L, -2, "channel");
    lua_pushstring(L, WiFi.BSSIDstr(i).c_str()); lua_setfield(L, -2, "bssid");
    lua_rawseti(L, -2, i + 1);
  }
  WiFi.scanDelete();
  return 1;
}
static int w_rssi(lua_State *L) { lua_pushinteger(L, WiFi.status() == WL_CONNECTED ? WiFi.RSSI() : -127); return 1; }
static int w_ip(lua_State *L) { lua_pushstring(L, WiFi.localIP().toString().c_str()); return 1; }
static int w_ssid(lua_State *L) { lua_pushstring(L, WiFi.SSID().c_str()); return 1; }

// ---------------------------------------------------------------- clock
static int k_now(lua_State *L) {
  time_t t = time(nullptr);
  struct tm tm;
  localtime_r(&t, &tm);
  lua_createtable(L, 0, 8);
  lua_pushboolean(L, t > 1700000000); lua_setfield(L, -2, "valid");
  lua_pushinteger(L, tm.tm_hour); lua_setfield(L, -2, "h");
  lua_pushinteger(L, tm.tm_min); lua_setfield(L, -2, "m");
  lua_pushinteger(L, tm.tm_sec); lua_setfield(L, -2, "s");
  lua_pushinteger(L, tm.tm_year + 1900); lua_setfield(L, -2, "year");
  lua_pushinteger(L, tm.tm_mon + 1); lua_setfield(L, -2, "month");
  lua_pushinteger(L, tm.tm_mday); lua_setfield(L, -2, "day");
  lua_pushinteger(L, tm.tm_wday); lua_setfield(L, -2, "wday");
  return 1;
}
static int k_sync(lua_State *L) {
  configTzTime(str(L, 1).c_str(), "pool.ntp.org", "time.nist.gov");
  return 0;
}
static int k_set_tz(lua_State *L) {
  setenv("TZ", str(L, 1).c_str(), 1);
  tzset();
  return 0;
}

// ---------------------------------------------------------------- usb
static int u_status(lua_State *L) {
  lua_createtable(L, 0, 4);
  lua_pushboolean(L, usbdev::keyboardOn()); lua_setfield(L, -2, "keyboard");
  lua_pushboolean(L, usbdev::driveOn()); lua_setfield(L, -2, "drive");
  lua_pushboolean(L, usbdev::serialOn()); lua_setfield(L, -2, "serial");
  lua_pushboolean(L, usbdev::serialConnected()); lua_setfield(L, -2, "connected");
  lua_pushboolean(L, usbdev::mouseOn()); lua_setfield(L, -2, "mouse");
  return 1;
}
static int u_type(lua_State *L) { usbdev::typeText(str(L, 1)); return 0; }
static int u_key(lua_State *L) { usbdev::key(str(L, 1)); return 0; }
static int u_write(lua_State *L) { usbdev::serialWrite(str(L, 1)); return 0; }
static int u_read(lua_State *L) {
  String s = usbdev::serialRead();
  if (s.length()) lua_pushlstring(L, s.c_str(), s.length());
  else lua_pushnil(L);
  return 1;
}
static int u_log_dump(lua_State *L) {
  String s = usbdev::logDump();
  lua_pushlstring(L, s.c_str(), s.length());
  return 1;
}
static int u_mouse_move(lua_State *L) {
  usbdev::mouseMove((int)luaL_checknumber(L, 1), (int)luaL_checknumber(L, 2), (int)luaL_optnumber(L, 3, 0));
  return 0;
}
static int u_mouse_click(lua_State *L) { usbdev::mouseClick(luaL_optstring(L, 1, "left")); return 0; }
static int u_mouse_press(lua_State *L) { usbdev::mouseButton(luaL_optstring(L, 1, "left"), lua_toboolean(L, 2)); return 0; }
static int u_share(lua_State *L) { usbdev::share(lua_toboolean(L, 1)); return 0; }
static int u_sharing(lua_State *L) { lua_pushboolean(L, usbdev::sharing()); return 1; }

// ---------------------------------------------------------------- net (ESP-NOW)
static int n_start(lua_State *L) { lua_pushboolean(L, mesh::start(str(L, 1))); return 1; }
static int n_stop(lua_State *L) { mesh::stop(); return 0; }
static int n_running(lua_State *L) { lua_pushboolean(L, mesh::running()); return 1; }
static int n_mac(lua_State *L) { lua_pushstring(L, mesh::mac().c_str()); return 1; }
static int n_add_peer(lua_State *L) { lua_pushboolean(L, mesh::addPeer(str(L, 1))); return 1; }
static int n_send(lua_State *L) { lua_pushboolean(L, mesh::send(str(L, 1), str(L, 2))); return 1; }
static int n_broadcast(lua_State *L) { lua_pushboolean(L, mesh::broadcast(str(L, 1))); return 1; }
static int n_recv(lua_State *L) {
  mesh::Packet p;
  if (!mesh::recv(p)) { lua_pushnil(L); return 1; }
  lua_createtable(L, 0, 4);
  lua_pushstring(L, p.from.c_str()); lua_setfield(L, -2, "from");
  lua_pushlstring(L, p.data.c_str(), p.data.length()); lua_setfield(L, -2, "data");
  lua_pushinteger(L, p.rssi); lua_setfield(L, -2, "rssi");
  lua_pushboolean(L, p.bcast); lua_setfield(L, -2, "bcast");
  return 1;
}

// ---------------------------------------------------------------- registration
static void add(lua_State *L, const char *name, const luaL_Reg *fns) {
  luaL_newlib(L, fns);
  lua_setglobal(L, name);
}

void registerApi(lua_State *L) {

  static const luaL_Reg gfxLib[] = {
      {"rgb", g_rgb}, {"clear", g_clear}, {"px", g_px}, {"line", g_line}, {"rect", g_rect}, {"fill", g_fill},
      {"rrect", g_rrect}, {"rfill", g_rfill}, {"circle", g_circle}, {"disc", g_disc}, {"tri", g_tri},
      {"arc", g_arc}, {"text", g_text}, {"text_w", g_text_w}, {"clip", g_clip}, {"noclip", g_noclip},
      {"brightness", g_brightness}, {nullptr, nullptr}};
  luaL_newlib(L, gfxLib);
  lua_pushinteger(L, SCREEN_W); lua_setfield(L, -2, "w");
  lua_pushinteger(L, SCREEN_H); lua_setfield(L, -2, "h");
  lua_setglobal(L, "gfx");

  static const luaL_Reg sndLib[] = {{"tone", s_tone}, {"stop", s_stop}, {"volume", s_volume}, {nullptr, nullptr}};
  add(L, "snd", sndLib);
  static const luaL_Reg imuLib[] = {{"read", i_read}, {nullptr, nullptr}};
  add(L, "imu", imuLib);

  static const luaL_Reg sysLib[] = {
      {"millis", y_millis}, {"delay", y_delay}, {"heap", y_heap}, {"battery", y_battery},
      {"reboot", y_reboot}, {"display_sleep", y_display_sleep}, {"display_hold", y_display_hold},
      {"screenshot", y_screenshot}, {"reload", y_reload}, {"log", y_log}, {"recovered", y_recovered},
      {"read_text", y_read_text}, {"append_text", y_append_text}, {"rename", y_rename}, {"read_builtin", y_read_builtin}, {"loadfile", y_loadfile}, {"write_text", y_write_text}, {"remove", y_remove},
      {"exists", y_exists}, {"mkdirs", y_mkdirs}, {"in_storage", y_in_storage},
      {"is_embedded", y_is_embedded}, {"list", y_list}, {"storage", y_storage}, {nullptr, nullptr}};
  luaL_newlib(L, sysLib);
  lua_pushboolean(L, store::safeMode); lua_setfield(L, -2, "safe_mode");
  lua_pushstring(L, "0.1"); lua_setfield(L, -2, "version");
  lua_setglobal(L, "sys");

  static const luaL_Reg cfgLib[] = {{"get", c_get}, {"set", c_set}, {nullptr, nullptr}};
  add(L, "cfg", cfgLib);

  static const luaL_Reg wifiLib[] = {
      {"enable", w_enable}, {"connect", w_connect}, {"disconnect", w_disconnect}, {"status", w_status},
      {"scan_start", w_scan_start}, {"scan_result", w_scan_result}, {"rssi", w_rssi}, {"ip", w_ip},
      {"ssid", w_ssid}, {nullptr, nullptr}};
  add(L, "wifi", wifiLib);

  static const luaL_Reg usbLib[] = {
      {"status", u_status}, {"type", u_type}, {"key", u_key}, {"write", u_write},
      {"read", u_read}, {"log_dump", u_log_dump}, {"share", u_share},
      {"mouse_move", u_mouse_move}, {"mouse_click", u_mouse_click}, {"mouse_press", u_mouse_press}, {"sharing", u_sharing}, {nullptr, nullptr}};
  add(L, "usb", usbLib);

  static const luaL_Reg netLib[] = {
      {"start", n_start}, {"stop", n_stop}, {"running", n_running}, {"mac", n_mac},
      {"add_peer", n_add_peer}, {"send", n_send}, {"broadcast", n_broadcast}, {"recv", n_recv},
      {nullptr, nullptr}};
  add(L, "net", netLib);

  static const luaL_Reg clockLib[] = {{"now", k_now}, {"sync", k_sync}, {"set_tz", k_set_tz}, {nullptr, nullptr}};
  add(L, "clock", clockLib);
}
