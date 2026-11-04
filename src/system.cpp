// The native OS layer. Everything here lives in flash, so the desktop, the
// drawer and all system UI cost almost no RAM; Lua runs only inside apps.
#include "system.h"
#include <M5Cardputer.h>
#include <WiFi.h>
#include <esp_heap_caps.h>
#include <esp_rom_crc.h>
#include <algorithm>
#include <functional>
#include <time.h>
#include <vector>
#include "bindings.h"
#include "embedded.h"
#include "storage.h"
#include "uikit.h"
#include "usbdev.h"
#include "vm.h"

extern bool g_displayAsleep;
extern bool g_displayHold;
extern String g_screenshotPath;
extern M5Canvas canvas;

using ui::col;

extern const char *volatile g_crumb;  // main.cpp: what the main loop is doing
bool appstorePending();  // appstore.cpp: the App Store asked for a download
void appstoreRun();
void hwReleaseAudio();  // hw.cpp: speaker and mic off when idle
void hwReleaseDrivers();  // hw.cpp: LoRa and GPS off

String tlsBench();  // tlsbench.cpp: crypto speed test (USB console !bench)

namespace shell {

// ================================================================ state
enum Screen { DESKTOP, DRAWER, APP, ERRSCREEN };
enum Overlay { OV_NONE, OV_LOCK, OV_QUICK, OV_NOTES, OV_HELP };
static Screen screen = DESKTOP;
static Overlay overlay = OV_NONE;
static bool safe = false;

static const char *DEFAULT_TZ = "PST8PDT,M3.2.0,M11.1.0";
static const size_t MIN_FREE_TO_OPEN = 28 * 1024;
static const size_t WIFI_RESERVE = 12 * 1024;  // left over after Wi-Fi starts

static size_t freeHeap() { return heap_caps_get_free_size(MALLOC_CAP_8BIT); }
static String cget(const char *k, const char *d = "") { return cfgGet(k, d); }

// ================================================================ time
static String formatTime(int h, int m) {
  char b[12];
  if (cget("clock12") == "1") {
    int hh = h % 12;
    snprintf(b, sizeof b, "%d:%02d %s", hh ? hh : 12, m, h < 12 ? "AM" : "PM");
  } else {
    snprintf(b, sizeof b, "%02d:%02d", h, m);
  }
  return b;
}

static bool now(struct tm &tm) {
  time_t t = time(nullptr);
  localtime_r(&t, &tm);
  return t > 1700000000;
}

static String tz() { return cget("tz", DEFAULT_TZ); }

// ================================================================ sounds
struct Note { uint16_t f, ms; };
static const Note S_BOOT[] = {{523, 70}, {659, 70}, {784, 120}, {0, 0}};
static const Note S_NOTIFY[] = {{1319, 60}, {1976, 90}, {0, 0}};
static const Note S_ERROR[] = {{220, 120}, {1, 60}, {220, 160}, {0, 0}};
static const Note S_LOW[] = {{784, 120}, {523, 200}, {0, 0}};
static const Note S_ALARM[] = {{1760, 150}, {1, 100}, {1760, 150}, {1, 100}, {1760, 150}, {1, 400}, {0, 0}};
static const Note *tune = nullptr;
static float tuneLeft = 0;
static bool tuneQuiet = false;  // the boot chime plays at a quarter of the volume

static void tuneVolume(bool quiet) {
  int v = cget("vol", "100").toInt();
  M5Cardputer.Speaker.setVolume(quiet ? max(v / 4, 12) : v);
  tuneQuiet = quiet;
}

static void sound(const char *kind, bool force = false) {
  if (!force && cget("sounds") == "0") return;
  if (tuneQuiet) tuneVolume(false);
  tune = !strcmp(kind, "boot") ? S_BOOT : !strcmp(kind, "notify") ? S_NOTIFY : !strcmp(kind, "error") ? S_ERROR
       : !strcmp(kind, "low") ? S_LOW : !strcmp(kind, "alarm") ? S_ALARM : nullptr;
  tuneLeft = 0;
  if (tune == S_BOOT) tuneVolume(true);
}

static void soundTick(float dt) {
  if (!tune) return;
  tuneLeft -= dt * 1000;
  if (tuneLeft > 0) return;
  if (!tune->ms) {
    tune = nullptr;
    if (tuneQuiet) tuneVolume(false);
    return;
  }
  if (tune->f > 1) playTone(tune->f, tune->ms);
  tuneLeft = tune->ms;
  tune++;
}

// ================================================================ toasts and notifications
static String toastMsg;
static float toastLeft = 0;
static void toast(const String &m, float secs = 2) { toastMsg = m; toastLeft = secs; }

struct Notification { String title, body, time; };
static std::vector<Notification> notes;

static void notify(const String &title, const String &body = "", const char *snd = "notify") {
  struct tm tm;
  String t = now(tm) ? formatTime(tm.tm_hour, tm.tm_min) : "";
  notes.insert(notes.begin(), {title, body, t});
  if (notes.size() > 20) notes.pop_back();
  ui::status.unread++;
  toast(title, 3);
  sound(snd);
}

// ================================================================ dialogs
enum DlgKind { DLG_NONE, DLG_ALERT, DLG_CONFIRM, DLG_PROMPT, DLG_MENU };
struct Dialog {
  DlgKind kind = DLG_NONE;
  String title, msg, text;
  std::vector<String> items;
  int sel = 1;
  bool secret = false;
  int luaRef = LUA_NOREF;  // callback in the app VM
  uint32_t vmGen = 0;
  std::function<void(bool, int, const String &)> native;
};
static Dialog dlg;
static uint32_t vmGen = 0;  // bumps every time an app VM opens
static String clipboard;

static void fail(const String &msg);

// Runs the dialog's callback: Lua callbacks get (true/false), (index/nil) or (text/nil).
static void finishDialog(bool ok, int idx, const String &text) {
  Dialog d = dlg;
  dlg = Dialog();
  if (d.native) { d.native(ok, idx, text); return; }
  if (d.luaRef == LUA_NOREF || !vm::L || d.vmGen != vmGen) return;
  lua_State *L = vm::L;
  lua_rawgeti(L, LUA_REGISTRYINDEX, d.luaRef);
  luaL_unref(L, LUA_REGISTRYINDEX, d.luaRef);
  if (!lua_isfunction(L, -1)) { lua_pop(L, 1); return; }
  int n = 1;
  switch (d.kind) {
    case DLG_ALERT: n = 0; break;
    case DLG_CONFIRM: lua_pushboolean(L, ok); break;
    case DLG_MENU: if (ok) lua_pushinteger(L, idx); else lua_pushnil(L); break;
    case DLG_PROMPT: if (ok) lua_pushstring(L, text.c_str()); else lua_pushnil(L); break;
    default: n = 0;
  }
  if (!vm::call(n, 0)) fail(vm::lastError);
}

static void openDialog(DlgKind kind, const String &title, const String &msg) {
  if (dlg.kind != DLG_NONE && dlg.luaRef != LUA_NOREF && vm::L && dlg.vmGen == vmGen)
    luaL_unref(vm::L, LUA_REGISTRYINDEX, dlg.luaRef);
  dlg = Dialog();
  dlg.kind = kind;
  dlg.title = title;
  dlg.msg = msg;
  dlg.vmGen = vmGen;
}

static void dialogKey(const Key &k) {
  String key = k.key;
  if (dlg.kind == DLG_ALERT) {
    if (key == "enter" || key == "esc") finishDialog(true, 0, "");
  } else if (dlg.kind == DLG_CONFIRM) {
    if (key == "enter" || (k.text && k.text[0] == 'y')) finishDialog(true, 0, "");
    else if (key == "esc" || (k.text && k.text[0] == 'n')) finishDialog(false, 0, "");
  } else if (dlg.kind == DLG_PROMPT) {
    if (key == "enter") finishDialog(true, 0, dlg.text);
    else if (key == "esc") finishDialog(false, 0, "");
    else if (key == "backspace") dlg.text.remove(dlg.text.length() ? dlg.text.length() - 1 : 0);
    else if (k.ctrl && k.text && k.text[0] == 'v') {
      String c = clipboard;
      int nl = c.indexOf('\n');
      if (nl >= 0) c = c.substring(0, nl);
      dlg.text = (dlg.text + c).substring(0, 64);
    } else if (k.ctrl && k.text && k.text[0] == 'c') clipboard = dlg.text;
    else if (k.text && !k.ctrl && dlg.text.length() < 64) dlg.text += k.text;
  } else if (dlg.kind == DLG_MENU) {
    int n = dlg.items.size();
    bool up = key == "up" || (k.text && k.text[0] == ';' && !k.fn);
    bool down = key == "down" || (k.text && k.text[0] == '.' && !k.fn);
    if (up) dlg.sel = (dlg.sel - 2 + n) % n + 1;
    else if (down) dlg.sel = dlg.sel % n + 1;
    else if (key == "enter") finishDialog(true, dlg.sel, "");
    else if (key == "esc") finishDialog(false, 0, "");
    else if (k.text && k.text[0] >= '1' && k.text[0] <= '9' && k.text[0] - '0' <= n) finishDialog(true, k.text[0] - '0', "");
  }
}

static void drawDialog() {
  if (dlg.kind == DLG_ALERT || dlg.kind == DLG_CONFIRM) {
    auto lines = ui::wrap(dlg.msg, 180);
    if (lines.size() > 6) lines.resize(6);
    int h = 40 + lines.size() * 10, x = 20, y = (135 - h) / 2;
    ui::box(x, y, 200, h);
    ui::text(x + 8, y + 6, ui::fit(dlg.title, 184).c_str(), col.accent);
    for (size_t i = 0; i < lines.size(); i++) ui::text(x + 8, y + 20 + i * 10, lines[i].c_str(), col.text);
    if (dlg.kind == DLG_CONFIRM) {
      ui::text(x + 8, y + h - 14, "Y yes", col.good);
      ui::text(x + 70, y + h - 14, "N no", col.muted);
    } else {
      ui::text(x + 8, y + h - 14, "Enter ok", col.muted);
    }
  } else if (dlg.kind == DLG_PROMPT) {
    int x = 16, y = 36;
    ui::box(x, y, 208, 62);
    ui::text(x + 8, y + 6, ui::fit(dlg.title, 190).c_str(), col.accent);
    ui::rfill(x + 8, y + 20, 192, 16, 3, col.bg);
    String shown = dlg.secret ? String() : dlg.text;
    if (dlg.secret) for (size_t i = 0; i < dlg.text.length(); i++) shown += '*';
    if (shown.length() > 30) shown = shown.substring(shown.length() - 30);
    if ((millis() / 500) % 2 == 0) shown += "_";
    ui::text(x + 12, y + 24, shown.c_str(), col.text);
    ui::text(x + 8, y + 44, "Enter ok   Esc cancel", col.muted);
  } else if (dlg.kind == DLG_MENU) {
    int n = dlg.items.size(), rows = min(n, 6), h = 26 + rows * 12, x = 30, y = (135 - h) / 2;
    ui::box(x, y, 180, h);
    ui::text(x + 8, y + 6, ui::fit(dlg.title, 164).c_str(), col.accent);
    int top = max(1, min(dlg.sel - rows + 1, n - rows + 1));
    if (dlg.sel < top) top = dlg.sel;
    for (int i = 0; i < rows; i++) {
      int idx = top + i;
      if (idx > n) break;
      int ry = y + 20 + i * 12;
      if (idx == dlg.sel) ui::rfill(x + 4, ry - 1, 172, 11, 3, col.accent);
      ui::text(x + 8, ry, ui::fit(dlg.items[idx - 1], 164).c_str(), idx == dlg.sel ? col.on_accent : col.text);
    }
  }
}

// ================================================================ timers and alarms
struct Timer {
  int id;
  float left, total;
  String label, pomo;  // pomo: "work"/"break" for Pomodoro phases
  int count = 0, work = 0, rest = 0;
};
static std::vector<Timer> timers;
static int nextTimerId = 1;

static Timer &startTimer(float secs, const String &label) {
  timers.push_back({nextTimerId++, secs, secs, label});
  return timers.back();
}

static void wake();

static void timerTick(float dt) {
  for (size_t i = 0; i < timers.size();) {
    Timer &t = timers[i];
    t.left -= dt;
    if (t.left > 0) { i++; continue; }
    Timer done = t;
    timers.erase(timers.begin() + i);
    wake();
    notify(done.label + " done", "", "alarm");
    if (done.pomo.length()) {  // the Pomodoro cycle continues on its own
      bool work = done.pomo == "work";
      Timer &n = startTimer(work ? done.rest : done.work, work ? "Pomodoro break" : "Pomodoro work");
      n.pomo = work ? "break" : "work";
      n.count = work ? done.count + 1 : done.count;
      n.work = done.work;
      n.rest = done.rest;
    }
  }
}

static int lastAlarmMin = -1;
static void alarmCheck(const struct tm &tm) {
  int key = tm.tm_hour * 60 + tm.tm_min;
  if (key == lastAlarmMin) return;
  lastAlarmMin = key;
  char nowS[6];
  snprintf(nowS, sizeof nowS, "%02d:%02d", tm.tm_hour, tm.tm_min);
  String all = cget("alarms");
  int start = 0;
  while (start < (int)all.length()) {
    int end = all.indexOf(';', start);
    if (end < 0) end = all.length();
    String item = all.substring(start, end);
    start = end + 1;
    if (item.startsWith(nowS)) {
      int bar = item.indexOf('|');
      wake();
      notify("Alarm " + formatTime(tm.tm_hour, tm.tm_min), bar >= 0 ? item.substring(bar + 1) : "", "alarm");
    }
  }
}

// ================================================================ apps on the device
struct AppInfo {
  String name, title, icon, cat;
  uint16_t color;
  int order;
};
static std::vector<AppInfo> apps;
static bool appsDirty = true;

static String field(const String &t, const char *name) {
  int i = t.indexOf(name);
  while (i >= 0) {
    int j = i + strlen(name);
    while (j < (int)t.length() && t[j] == ' ') j++;
    if (j < (int)t.length() && t[j] == '=') {
      j++;
      while (j < (int)t.length() && t[j] == ' ') j++;
      if (j < (int)t.length() && t[j] == '"') {
        int e = t.indexOf('"', j + 1);
        return e > j ? t.substring(j + 1, e) : "";
      }
      int e = j;
      while (e < (int)t.length() && (isalnum(t[e]) || t[e] == '_')) e++;
      return t.substring(j, e);
    }
    i = t.indexOf(name, i + 1);
  }
  return "";
}

// Each app is a folder: apps/<name>/main.lua (and main.luac from the App
// Store), plus any files of its own.
static String appFile(const String &name) { return "apps/" + name + "/main.lua"; }

static void scanApps() {
  appsDirty = false;
  apps.clear();
  for (auto &e : store::list("apps")) {
    if (!e.dir) continue;
    String name = e.name;
    String buf;
    const char *p;
    size_t n;
    if (!store::view(appFile(name), buf, p, n, false, 768)) continue;
    String head;
    head.concat(p, n);
    int a = head.indexOf("local app");
    int b = a >= 0 ? head.indexOf('}', a) : -1;
    String t = (a >= 0 && b > a) ? head.substring(a, b) : "";
    if (field(t, "hidden") == "true") continue;
    AppInfo info;
    info.name = name;
    info.title = field(t, "title");
    if (!info.title.length()) info.title = name;
    info.icon = field(t, "icon");
    if (!info.icon.length()) info.icon = "app";
    info.cat = field(t, "category");
    if (!info.cat.length()) info.cat = "tools";
    String o = field(t, "order");
    info.order = o.length() ? o.toInt() : 100;
    String c = field(t, "color");
    if (c.length()) info.color = ui::accent(c.c_str());
    else info.color = ui::accent(ui::ACCENTS[name.length() % ui::ACCENT_COUNT]);
    apps.push_back(info);
  }
  std::sort(apps.begin(), apps.end(), [](const AppInfo &a, const AppInfo &b) {
    if (a.order != b.order) return a.order < b.order;
    return a.title < b.title;
  });
}

static const AppInfo *findApp(const String &name) {
  for (auto &a : apps)
    if (a.name == name) return &a;
  return nullptr;
}

// ================================================================ app lifecycle
static String appName, appTitle;
static int appRef = LUA_NOREF;
static bool appHold = false, holdNow = false;
static std::vector<String> backStack;
struct Saved { String name, data; };
static std::vector<Saved> savedStates;
struct ErrorInfo { String msg, file, app; int line = 0; bool oom = false; };
static ErrorInfo err;

// Pushes app[fn] when it is a function; returns false otherwise.
static bool appFn(const char *fn) {
  if (!vm::L || appRef == LUA_NOREF) return false;
  lua_State *L = vm::L;
  lua_rawgeti(L, LUA_REGISTRYINDEX, appRef);
  lua_getfield(L, -1, fn);
  lua_remove(L, -2);
  if (lua_isfunction(L, -1)) return true;
  lua_pop(L, 1);
  return false;
}

// Focus mode: an app that needs the RAM and CPU (the music player) turns off
// background services while it is open. Wi-Fi (and with it NTP and roaming)
// comes back when the app closes, however it closes.
static bool wifiStartSvc(const String &ssid, const String &pass, bool quiet);
static bool focusWifi = false;
static uint32_t wifiRestoreAt = 0;  // when to turn Wi-Fi back on after focus mode (0: not pending)
static int wifiRestoreTries = 0;
static void focus(bool on) {
  if (on && !focusWifi && WiFi.getMode() != WIFI_OFF) {
    wifiEnable(false);
    focusWifi = true;
    usbdev::log("focus mode: wifi off");
  } else if (!on && focusWifi) {
    // Not at once: the app's audio task and the speaker driver are still
    // letting go of their memory. services() restarts Wi-Fi, retrying a few
    // times, and only says so if it can't.
    focusWifi = false;
    wifiRestoreAt = millis() + 1500;
    wifiRestoreTries = 0;
    usbdev::log("focus mode ended: wifi back on shortly");
  }
}

static void closeApp(bool save) {
  if (!vm::L) return;
  lua_State *L = vm::L;
  if (save && appFn("save") && vm::call(0, 1)) {
    if (lua_istable(L, -1)) {
      lua_getglobal(L, "__ser");
      lua_insert(L, -2);
      if (vm::call(1, 1) && lua_isstring(L, -1)) {
        String data = lua_tostring(L, -1);
        bool found = false;
        for (auto &s : savedStates)
          if (s.name == appName) { s.data = data; found = true; }
        if (!found) {
          if (savedStates.size() >= 10) savedStates.erase(savedStates.begin());
          savedStates.push_back({appName, data});
        }
      }
    }
    lua_settop(L, 0);
  }
  if (appFn("close")) vm::call(0, 0);
  if (dlg.luaRef != LUA_NOREF) dlg = Dialog();
  vm::close();
  appRef = LUA_NOREF;
  appHold = holdNow = false;
  g_displayHold = false;
  appsDirty = true;  // the app may have installed or edited apps
  focus(false);      // after vm::close(), so Wi-Fi gets the freed RAM
  hwReleaseAudio();  // the speaker/mic drivers an app started (unless audio still plays)
  hwReleaseDrivers();
}

static void fail(const String &msg) {
  usbdev::log("app error: " + msg);
  err = ErrorInfo();
  err.msg = msg;
  err.app = appName;
  err.oom = msg.indexOf("not enough memory") >= 0;
  int dot = msg.indexOf(".lua:");
  if (dot >= 0) {
    int s = dot;
    while (s > 0 && msg[s - 1] != ' ' && msg[s - 1] != '\n') s--;
    err.file = msg.substring(s, dot + 4);
    err.line = msg.substring(dot + 5).toInt();
  }
  closeApp(false);
  screen = ERRSCREEN;
  sound("error");
}

static void launch(const String &name, const String &path = "", int line = 0, bool returning = false);

// Home: the app is closed and everything it held is released (its Lua state,
// audio drivers); only the shell's services (clock, alarms, timers, Wi-Fi)
// keep running. The log shows what is free, to check nothing is left behind.
static void goHome() {
  backStack.clear();
  bool hadApp = vm::L != nullptr;
  closeApp(true);
  screen = DESKTOP;
  if (hadApp)
    usbdev::log(String("home: heap free=") + freeHeap() + " largest=" + heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) +
                " arena free=" + vm::arenaFree());
}

static void back() {
  while (!backStack.empty()) {
    String prev = backStack.back();
    backStack.pop_back();
    if (prev != appName && store::exists(appFile(prev))) { launch(prev, "", 0, true); return; }
  }
  if (screen == APP || screen == ERRSCREEN) {
    closeApp(true);
    screen = DESKTOP;
  }
}

static void launch(const String &name, const String &path, int line, bool returning) {
  if (!store::exists(appFile(name))) {  // apps come from the App Store
    toast(name + " isn't installed: get it in the App Store", 3);
    return;
  }
  if (!returning && screen == APP && appName.length() && appName != name) {
    backStack.push_back(appName);
    if (backStack.size() > 4) backStack.erase(backStack.begin());
  }
  closeApp(true);
  appName = name;
  appTitle = name;
  if (const AppInfo *a = findApp(name)) appTitle = a->title;
  if (vm::arenaFree() < MIN_FREE_TO_OPEN) { fail("not enough memory to open " + name); return; }
  usbdev::log(String("open ") + name + ": heap free=" + heap_caps_get_free_size(MALLOC_CAP_8BIT) + " largest=" +
              heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) + " arena free=" + vm::arenaFree());
  if (!vm::open()) { fail(vm::lastError); return; }
  vmGen++;
  lua_State *L = vm::L;
  String file = appFile(name), e;
  // Debug info is kept for a script edited on the device (its errors show
  // lines). An App Store copy runs from its bytecode (main.luac); editing the
  // source deletes that, so "has bytecode" means "unedited".
  bool strip = cget("debug_sys") != "1" && (!store::inStorage(file) || store::inStorage(file + "c"));
  if (!loadChunk(L, file, false, strip, e)) { fail(e.length() ? e : "app not found: " + file); return; }
  if (!vm::call(0, 1)) { fail(vm::lastError); return; }
  if (!lua_istable(L, -1)) { lua_pop(L, 1); fail(file + ": app must return a table"); return; }
  appRef = luaL_ref(L, LUA_REGISTRYINDEX);
  screen = APP;
  if (appFn("init")) {
    if (path.length()) {
      lua_createtable(L, 0, 2);
      lua_pushstring(L, path.c_str()); lua_setfield(L, -2, "path");
      if (line) { lua_pushinteger(L, line); lua_setfield(L, -2, "line"); }
    } else {
      lua_pushnil(L);
    }
    bool pushedSaved = false;
    for (auto &s : savedStates)
      if (s.name == name) {
        lua_getglobal(L, "__deser");
        lua_pushstring(L, s.data.c_str());
        pushedSaved = vm::call(1, 1);
      }
    if (!pushedSaved) lua_pushnil(L);
    if (!vm::call(2, 0)) fail(vm::lastError);
  }
}

// ================================================================ Wi-Fi service
static bool wifiStartSvc(const String &ssid, const String &pass, bool quiet) {
  if (WiFi.getMode() == WIFI_OFF) {
    // make room first: idle audio drivers, Lua garbage
    hwReleaseAudio();
    if (vm::L) lua_gc(vm::L, LUA_GCCOLLECT);
    size_t f = freeHeap();
    if (f < wifiStartCost() + WIFI_RESERVE) {
      if (!quiet) toast(String("Not enough memory for Wi-Fi (") + (f / 1024) + "K free)", 4);
      usbdev::log(String("wifi refused: free=") + f + " needs=" + (wifiStartCost() + WIFI_RESERVE) + " largest=" + heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) +
                  (screen == APP ? " app=" + appName : String("")));
      return false;
    }
    if (!wifiEnable(true)) {
      if (!quiet) toast("Wi-Fi failed to start", 4);
      return false;
    }
  }
  if (ssid.length()) wifiConnect(ssid.c_str(), pass.c_str());
  return true;
}

// ================================================================ display sleep and lock
static float idle = 0;
static bool asleep = false;
static int sleepAfter = 60;

static void applySettings() {
  ui::setTheme(cget("theme", "slate").c_str());
  ui::setAccent(cget("accent", "blue").c_str());
  M5Cardputer.Display.setBrightness(cget("bright", "160").toInt());
  M5Cardputer.Speaker.setVolume(cget("vol", "100").toInt());
  setenv("TZ", tz().c_str(), 1);
  tzset();
  sleepAfter = cget("sleep", "60").toInt();
}

static void displaySleep(bool on) {
  if (on == g_displayAsleep) return;
  g_displayAsleep = on;
  if (on) {
    M5Cardputer.Display.setBrightness(0);
    M5Cardputer.Display.sleep();
  } else {
    M5Cardputer.Display.wakeup();
    M5Cardputer.Display.setBrightness(cget("bright", "160").toInt());
  }
}

static void wake() {
  idle = 0;
  if (!asleep) return;
  asleep = false;
  displaySleep(false);
  if (cget("lock") != "0") overlay = OV_LOCK;
}

// ================================================================ desktop
static int dockSel = 0;
static std::vector<String> dock() {
  std::vector<String> out;
  // Once: a dock saved before the App Store existed gets it (in Notes' place,
  // else the last slot); the user asked for it on the home screen.
  if (cget("dock_store") != "1") {
    String saved = cget("dock");
    if (saved.length() && ("," + saved + ",").indexOf(",store,") < 0) {
      String with = ("," + saved + ",");
      if (with.indexOf(",notes,") >= 0) with.replace(",notes,", ",store,");
      else {
        int last = with.lastIndexOf(',', with.length() - 2);
        with = with.substring(0, last + 1) + "store,";
      }
      cfgSet("dock", with.substring(1, with.length() - 1));
    }
    cfgSet("dock_store", "1");
  }
  String d = cget("dock", "files,clock,music,store,settings");
  int s = 0;
  while (s < (int)d.length() && out.size() < 5) {
    int e = d.indexOf(',', s);
    if (e < 0) e = d.length();
    String n = d.substring(s, e);
    if (findApp(n)) out.push_back(n);
    s = e + 1;
  }
  return out;
}

static void togglePin(const String &name) {
  auto d = dock();
  bool pinned = false;
  for (size_t i = 0; i < d.size(); i++)
    if (d[i] == name) { d.erase(d.begin() + i); pinned = true; break; }
  if (!pinned) {
    if (d.size() >= 5) { toast("The dock holds 5 apps - unpin one first"); return; }
    d.push_back(name);
  }
  String s;
  for (auto &n : d) s += (s.length() ? "," : "") + n;
  cfgSet("dock", s);
  toast(pinned ? "Removed from the dock" : "Pinned to the dock");
}

static const char *DAYS[] = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
static const char *MONTHS[] = {"January", "February", "March", "April", "May", "June", "July",
                               "August", "September", "October", "November", "December"};

static void drawDesktop() {
  struct tm tm;
  bool valid = now(tm);
  if (valid) {
    String t = formatTime(tm.tm_hour, tm.tm_min);
    int sp = t.indexOf(' ');
    String hm = sp > 0 ? t.substring(0, sp) : t;
    ui::center(22, hm.c_str(), col.text, 4);
    if (sp > 0) ui::text((240 + hm.length() * 24) / 2 + 3, 46, t.substring(sp + 1).c_str(), col.muted);
    char d[40];
    snprintf(d, sizeof d, "%s, %s %d", DAYS[tm.tm_wday], MONTHS[tm.tm_mon], tm.tm_mday);
    ui::center(58, d, col.muted);
  } else {
    ui::center(26, "PocketLua", col.accent, 3);
    ui::center(58, "Set the clock: connect to Wi-Fi", col.muted);
  }
  // one quiet line of status: next alarm, notifications, timers
  String info;
  if (ui::status.unread) info += String(ui::status.unread) + (ui::status.unread == 1 ? " notification" : " notifications");
  if (!timers.empty()) info += String(info.length() ? "  -  " : "") + timers.size() + (timers.size() == 1 ? " timer" : " timers");
  if (info.length()) ui::center(70, info.c_str(), col.accent);

  auto d = dock();
  if (dockSel >= (int)d.size()) dockSel = max(0, (int)d.size() - 1);
  int slot = 46, x0 = (240 - (int)d.size() * slot) / 2;
  for (size_t i = 0; i < d.size(); i++) {
    const AppInfo *a = findApp(d[i]);
    if (!a) continue;
    int x = x0 + i * slot;
    bool on = (int)i == dockSel;
    if (on) ui::card(x + 1, 82, slot - 2, 41, true);
    ui::tile(x + 9, 85, 28, a->icon.c_str(), a->color);
    String l = ui::fit(a->title, slot - 4);
    ui::text(x + (slot - l.length() * 6) / 2, 115, l.c_str(), on ? col.text : col.muted);
  }
  static const ui::Hint h[] = {{"Enter", "Open"}, {"Tab", "All apps"}, {"Fn+Q", "Quick"}};
  ui::footer(h, 3);
}

// ================================================================ app drawer
static const char *CATS[] = {"system", "tools", "media", "games", "net"};
static const char *CAT_LABELS[] = {"System", "Tools", "Media", "Games", "Connect"};
static const char *CAT_ICONS[] = {"gear", "calc", "music", "pad", "wifi"};
static int folder = -1, drawerSel = 1, drawerTop = 1;
static String query;

static std::vector<const AppInfo *> drawerApps() {
  std::vector<const AppInfo *> out;
  String q = query;
  q.toLowerCase();
  for (auto &a : apps) {
    if (q.length()) {
      String t = a.title;
      t.toLowerCase();
      if (t.indexOf(q) >= 0) out.push_back(&a);
    } else if (folder >= 0 && a.cat == CATS[folder]) {
      out.push_back(&a);
    }
  }
  return out;
}

static void drawDrawer() {
  std::vector<ui::Row> rows;
  int y = 18;
  if (query.length()) {
    ui::rfill(4, 16, 232, 13, 4, col.surface);
    ui::text(9, 19, "Search:", col.muted);
    ui::text(57, 19, (query + ((millis() / 500) % 2 ? "_" : "")).c_str(), col.text);
    y = 32;
  }
  auto d = dock();
  if (folder < 0 && !query.length()) {
    for (int i = 0; i < 5; i++) {
      int n = 0;
      for (auto &a : apps) n += a.cat == CATS[i];
      ui::Row r;
      r.label = CAT_LABELS[i];
      r.value = String(n);
      r.badge = CAT_LABELS[i][0];
      r.badgeColor = ui::accent(ui::ACCENTS[(i * 2) % ui::ACCENT_COUNT]);
      rows.push_back(r);
    }
  } else {
    for (auto *a : drawerApps()) {
      ui::Row r;
      r.label = a->title;
      r.badge = a->title[0];
      r.badgeColor = a->color;
      for (auto &n : d) if (n == a->name) r.value = "docked";
      rows.push_back(r);
    }
  }
  if (rows.empty()) ui::center(64, "No apps match", col.muted);
  else {
    drawerSel = max(1, min(drawerSel, (int)rows.size()));
    drawerTop = ui::list(rows, drawerSel, drawerTop, 4, y, 230, 17, query.length() ? 5 : 6);
  }
  if (folder < 0 && !query.length()) {
    static const ui::Hint h[] = {{"Enter", "Open"}, {"abc", "Search"}, {"Esc", "Back"}};
    ui::footer(h, 3);
  } else {
    static const ui::Hint h[] = {{"Enter", "Open"}, {"P", "Dock"}, {"^E", "Edit"}, {"Esc", "Back"}};
    ui::footer(h, 4);
  }
}

static const char *TEMPLATE =
    "-- %s: edit me, then press Ctrl+S to save and Ctrl+R to run.\n"
    "local app = { title = \"%s\", icon = \"app\", category = \"tools\" }\n\n"
    "local t = 0\n\n"
    "function app.update(dt)\n  t = t + dt\nend\n\n"
    "function app.draw()\n"
    "  ui.center(52, \"Hello from %s\", ui.col.text)\n"
    "  ui.big(68, string.format(\"%%.1f s\", t), ui.col.accent, 2)\n"
    "  ui.footer({ { \"Esc\", \"Home\" } })\nend\n\n"
    "function app.key(k)\n  -- return true when the key is handled; Esc goes back by itself\nend\n\n"
    "return app\n";

static void newApp() {
  openDialog(DLG_PROMPT, "New app name", "");
  dlg.native = [](bool ok, int, const String &text) {
    if (!ok) return;
    String name;
    for (char c : text) if (isalnum(c) || c == '_') name += (char)tolower(c);
    if (!name.length()) return;
    String path = appFile(name);
    if (store::exists(path)) { toast("Already exists: " + name); return; }
    char buf[900];
    snprintf(buf, sizeof buf, TEMPLATE, name.c_str(), name.c_str(), name.c_str());
    if (!store::write(path, buf)) { toast("Could not write file"); return; }
    appsDirty = true;
    launch("edit", path);
  };
}

static void drawerKey(const Key &k) {
  String key = k.key;
  bool typed = k.text && !k.ctrl && !k.fn && isalnum((unsigned char)k.text[0]);
  auto list = drawerApps();
  int n = (folder < 0 && !query.length()) ? 5 : list.size();
  if (k.ctrl && k.text) {
    char c = tolower(k.text[0]);
    if (c == 'n') newApp();
    else if (c == 'e' && (folder >= 0 || query.length()) && drawerSel <= (int)list.size())
      launch("edit", appFile(list[drawerSel - 1]->name));
    return;
  }
  if (key == "up" || (!query.length() && k.text && k.text[0] == ';')) drawerSel = max(1, drawerSel - 1);
  else if (key == "down" || (!query.length() && k.text && k.text[0] == '.')) drawerSel = min(n, drawerSel + 1);
  else if (key == "enter") {
    if (folder < 0 && !query.length()) { folder = drawerSel - 1; drawerSel = drawerTop = 1; }
    else if (drawerSel <= (int)list.size()) launch(list[drawerSel - 1]->name);
  } else if (key == "esc") {
    if (query.length()) { query = ""; drawerSel = drawerTop = 1; }
    else if (folder >= 0) { drawerSel = folder + 1; folder = -1; drawerTop = 1; }
    else screen = DESKTOP;
  } else if (key == "backspace" && query.length()) {
    query.remove(query.length() - 1);
    drawerSel = drawerTop = 1;
  } else if (k.text && (k.text[0] == 'p' || k.text[0] == 'P') && !query.length() && folder >= 0) {
    if (drawerSel <= (int)list.size()) togglePin(list[drawerSel - 1]->name);
  } else if (typed || (query.length() && k.text && k.text[0] == ' ')) {
    query += k.text;
    drawerSel = drawerTop = 1;
  }
}

static void desktopKey(const Key &k) {
  String key = k.key;
  auto d = dock();
  if (key == "left" || (k.text && k.text[0] == ',' && !k.fn)) dockSel = max(0, dockSel - 1);
  else if (key == "right" || (k.text && k.text[0] == '/' && !k.fn)) dockSel = min((int)d.size() - 1, dockSel + 1);
  else if (key == "enter" && dockSel < (int)d.size()) launch(d[dockSel]);
  else if (key == "tab" || key == "down" || key == "up" || (k.text && (k.text[0] == '.' || k.text[0] == ';') && !k.fn)) {
    screen = DRAWER;
    folder = -1;
    drawerSel = drawerTop = 1;
  } else if (k.ctrl && k.text && tolower(k.text[0]) == 'e' && dockSel < (int)d.size()) {
    launch("edit", appFile(d[dockSel]));
  } else if (k.ctrl && k.text && tolower(k.text[0]) == 'n') {
    newApp();
  } else if (k.text && !k.ctrl && !k.fn && isalnum((unsigned char)k.text[0])) {
    screen = DRAWER;  // typing searches every app
    folder = -1;
    query = k.text;
    drawerSel = drawerTop = 1;
  }
}

// ================================================================ error screen
static void drawError() {
  ui::icon("warn", 20, 29, col.warn, col.bg);
  ui::text(36, 25, err.oom ? "Not enough memory" : "Something went wrong", col.bad);
  String m = err.oom ? "There is not enough free memory to run this. Turn Wi-Fi off (Fn+Q) and try again." : err.msg;
  auto lines = ui::wrap(m, 224);
  for (size_t i = 0; i < lines.size() && i < 8; i++) ui::text(8, 42 + i * 10, lines[i].c_str(), col.text);
  ui::Hint h[4];
  int n = 0;
  if (err.file.length() && !err.oom) h[n++] = {"E", "Edit"};
  if (err.app.length()) h[n++] = {"R", "Retry"};
  h[n++] = {"Esc", "Back"};
  ui::footer(h, n);
}

static void errorKey(const Key &k) {
  char c = k.text ? tolower(k.text[0]) : 0;
  if (c == 'e' && err.file.length() && !err.oom) launch("edit", err.file, err.line);
  else if (c == 'r' && err.app.length()) launch(err.app, "", 0, true);
  else if (String(k.key) == "esc") back();
}

// ================================================================ overlays
static int quickSel = 0, notesSel = 1, notesTop = 1;
static const int SLEEP_OPTS[] = {0, 30, 60, 120, 300, 600};

static String sleepLabel(int s) {
  if (!s) return "Never";
  if (s < 60) return String(s) + " s";
  return String(s / 60) + " min";
}

static void quickAdjust(int i, int d) {
  if (i == 0) {
    int v = constrain(cget("bright", "160").toInt() + d * 32, 16, 255);
    cfgSet("bright", String(v));
    M5Cardputer.Display.setBrightness(v);
  } else if (i == 1) {
    int v = constrain(cget("vol", "100").toInt() + d * 32, 0, 255);
    cfgSet("vol", String(v));
    M5Cardputer.Speaker.setVolume(v);
    playTone(880, 60);
  } else if (i == 2) {
    if (WiFi.getMode() == WIFI_OFF) {
      cfgSet("wifi_auto", "1");
      wifiStartSvc(cget("wifi_ssid"), cget("wifi_pass"), false);
    } else {
      cfgSet("wifi_auto", "0");
      wifiEnable(false);
    }
  } else if (i == 3) {
    int idx = 0;
    for (int t = 0; t < ui::THEME_COUNT; t++) if (ui::themeName == ui::THEMES[t]) idx = t;
    idx = (idx + d + ui::THEME_COUNT) % ui::THEME_COUNT;
    cfgSet("theme", ui::THEMES[idx]);
    ui::setTheme(ui::THEMES[idx]);
  } else if (i == 4) {
    int idx = 2;
    for (int t = 0; t < 6; t++) if (SLEEP_OPTS[t] == sleepAfter) idx = t;
    idx = (idx + d + 6) % 6;
    sleepAfter = SLEEP_OPTS[idx];
    cfgSet("sleep", String(sleepAfter));
  }
}

static void screenshot();

static void quickKey(const Key &k) {
  String key = k.key;
  bool up = key == "up" || (k.text && k.text[0] == ';'), down = key == "down" || (k.text && k.text[0] == '.');
  bool left = key == "left" || (k.text && k.text[0] == ','), right = key == "right" || (k.text && k.text[0] == '/');
  if (up) quickSel = (quickSel + 7) % 8;
  else if (down) quickSel = (quickSel + 1) % 8;
  else if ((left || right) && quickSel <= 4) quickAdjust(quickSel, left ? -1 : 1);
  else if (key == "enter") {
    if (quickSel <= 4) quickAdjust(quickSel, 1);
    else if (quickSel == 5) { overlay = OV_NOTES; ui::status.unread = 0; notesSel = notesTop = 1; }
    else if (quickSel == 6) { overlay = OV_NONE; screenshot(); }
    else if (quickSel == 7) { overlay = OV_NONE; launch("tasks"); }
  } else if (key == "esc") overlay = OV_NONE;
}

static void drawQuick() {
  const char *labels[] = {"Brightness", "Volume", "Wi-Fi", "Theme", "Sleep after", "Notifications", "Screenshot", "Task Manager"};
  String vals[8];
  vals[0] = String(cget("bright", "160").toInt() * 100 / 255) + "%";
  vals[1] = String(cget("vol", "100").toInt() * 100 / 255) + "%";
  vals[2] = WiFi.getMode() == WIFI_OFF ? "Off" : (WiFi.status() == WL_CONNECTED ? "Connected" : "On");
  vals[3] = ui::themeName;
  vals[4] = sleepLabel(sleepAfter);
  vals[5] = String(ui::status.unread) + " new";
  vals[6] = "Fn+P";
  int x = 30, y = 18, w = 180, rh = 13;
  ui::box(x, y, w, 12 + 8 * rh);
  for (int i = 0; i < 8; i++) {
    int ry = y + 5 + i * rh;
    if (i == quickSel) ui::rfill(x + 3, ry, w - 6, rh - 1, 3, col.surface2);
    ui::text(x + 8, ry + 2, labels[i], i == quickSel ? col.accent : col.text);
    ui::right(x + w - 8, ry + 2, vals[i].c_str(), col.muted);
  }
  static const ui::Hint h[] = {{"<>", "Change"}, {"Enter", "Open"}, {"Esc", "Close"}};
  ui::footer(h, 3);
}

static void drawLock() {
  ui::fill(0, 14, 240, 121, col.bg);
  struct tm tm;
  if (now(tm)) {
    String t = formatTime(tm.tm_hour, tm.tm_min);
    int sp = t.indexOf(' ');
    ui::center(30, (sp > 0 ? t.substring(0, sp) : t).c_str(), col.text, 4);
    if (sp > 0) ui::center(66, t.substring(sp + 1).c_str(), col.muted);
    char d[40];
    snprintf(d, sizeof d, "%s, %s %d", DAYS[tm.tm_wday], MONTHS[tm.tm_mon], tm.tm_mday);
    ui::center(78, d, col.muted);
  } else {
    ui::center(40, "PocketLua", col.accent, 3);
  }
  if (!notes.empty() && ui::status.unread) {
    ui::card(20, 94, 200, 16, false);
    ui::text(26, 98, ui::fit(notes[0].title, 150).c_str(), col.text);
    ui::right(214, 98, (String(ui::status.unread) + " new").c_str(), col.accent);
  }
  static const ui::Hint h[] = {{"any key", "Unlock"}};
  ui::footer(h, 1);
}

// ---------------------------------------------------------------- Fn+H help
// The keys for what is on screen (an app's `help` table, or the desktop's
// and drawer's own), then the system-wide ones. Built when opened.
static std::vector<ui::Row> helpRows;
static int helpSel = 1, helpTop = 1;

static void helpAdd(const char *key, const String &what, bool dim = false) {
  ui::Row r;
  r.label = what;
  r.value = key;
  r.dim = dim;
  helpRows.push_back(r);
}

static void openHelp() {
  helpRows.clear();
  helpSel = helpTop = 1;
  if (screen == APP && vm::L && appRef != LUA_NOREF) {
    lua_State *L = vm::L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, appRef);
    lua_getfield(L, -1, "help");
    int n = lua_istable(L, -1) ? lua_rawlen(L, -1) : 0;
    for (int i = 1; i <= n && i <= 16; i++) {
      lua_rawgeti(L, -1, i);
      if (lua_istable(L, -1)) {
        lua_rawgeti(L, -1, 1);
        lua_rawgeti(L, -2, 2);
        if (lua_isstring(L, -2) && lua_isstring(L, -1)) helpAdd(lua_tostring(L, -2), lua_tostring(L, -1));
        lua_pop(L, 2);
      }
      lua_pop(L, 1);
    }
    lua_pop(L, 2);
    if (helpRows.empty()) helpAdd("", "No key list for this app", true);
  } else if (screen == DESKTOP) {
    helpAdd(",/", "Choose a dock app");
    helpAdd("Enter", "Open it");
    helpAdd("Tab", "All apps");
    helpAdd("A-Z", "Search apps");
  } else if (screen == DRAWER) {
    helpAdd(";.", "Move");
    helpAdd("Enter", "Open app / folder");
    helpAdd("A-Z", "Search");
    helpAdd("P", "Pin to dock");
    helpAdd("^E", "Edit the app");
    helpAdd("^N", "New app");
    helpAdd("Esc", "Back");
  }
  helpAdd("", "Anywhere", true);
  helpAdd("Fn+H", "This help");
  helpAdd("Fn+Q", "Quick settings");
  helpAdd("Fn+N", "Notifications");
  helpAdd("Fn+P", "Screenshot");
  helpAdd("Fn+L", "Lock");
  helpAdd("Fn+;.,/", "Arrow keys");
  helpAdd("Fn+`", "Esc");
  overlay = OV_HELP;
}

static void drawHelp() {
  ui::fill(0, 14, 240, 121, col.bg);
  ui::text(6, 17, "KEYS", col.muted);
  helpTop = ui::list(helpRows, helpSel, helpTop, 4, 28, 230, 15, 6);
  static const ui::Hint h[] = {{";.", "Scroll"}, {"Esc", "Close"}};
  ui::footer(h, 2);
}

static void helpKey(const Key &k) {
  String key = k.key;
  if (key == "up" || (k.text && k.text[0] == ';')) helpSel = max(1, helpSel - 1);
  else if (key == "down" || (k.text && k.text[0] == '.')) helpSel = min((int)helpRows.size(), helpSel + 1);
  else if (key == "esc" || key == "enter") { overlay = OV_NONE; helpRows.clear(); }
}

static void drawNotes() {
  ui::fill(0, 14, 240, 121, col.bg);
  ui::text(6, 17, "NOTIFICATIONS", col.muted);
  if (notes.empty()) ui::center(64, "Nothing new", col.muted);
  else {
    std::vector<ui::Row> rows;
    for (auto &n : notes) { ui::Row r; r.label = n.title; r.value = n.time; rows.push_back(r); }
    notesSel = max(1, min(notesSel, (int)rows.size()));
    notesTop = ui::list(rows, notesSel, notesTop, 4, 28, 230, 16, 6);
  }
  static const ui::Hint h[] = {{"Enter", "Read"}, {"C", "Clear all"}, {"Esc", "Close"}};
  ui::footer(h, 3);
}

static void notesKey(const Key &k) {
  String key = k.key;
  if (key == "up" || (k.text && k.text[0] == ';')) notesSel = max(1, notesSel - 1);
  else if (key == "down" || (k.text && k.text[0] == '.')) notesSel = min((int)notes.size(), notesSel + 1);
  else if (key == "enter" && notesSel <= (int)notes.size()) {
    openDialog(DLG_ALERT, notes[notesSel - 1].title, notes[notesSel - 1].body.length() ? notes[notesSel - 1].body : "(no details)");
  } else if (k.text && tolower(k.text[0]) == 'c') notes.clear();
  else if (key == "esc") overlay = OV_NONE;
}

// ================================================================ screenshots
static void screenshot() {
  int n = cget("shot_n", "0").toInt() + 1;
  cfgSet("shot_n", String(n));
  char p[48];
  snprintf(p, sizeof p, "data/screenshots/shot_%03d.bmp", n);
  g_screenshotPath = p;
}

void screenshotDone(const String &path, bool ok) {
  if (ok) notify("Screenshot saved", path);
  else toast("Screenshot failed");
}

// ================================================================ USB console
// Native, so it works with no app open. Lua is evaluated in the open app.
static String conBuf, recvPath, recvData;
static bool conOn = false;
static const char *B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void reply(const String &s) { usbdev::serialWrite(s + "\n"); }

// Appends received bytes as text. Control bytes are dropped: String::indexOf
// stops at a NUL, so one stray NUL would hide every later newline and the
// console would never see another command. CR also ends a line.
static void addInput(String &buf, const String &s) {
  buf.reserve(buf.length() + s.length());
  for (char c : s) {
    if (c == '\n' || c == '\r') buf += '\n';
    else if ((uint8_t)c >= 0x20 || c == '\t') buf += c;
  }
}

static String b64decode(const String &in) {
  String out;
  int val = 0, bits = -8;
  for (char c : in) {
    const char *p = strchr(B64, c);
    if (!p || !c) continue;
    val = (val << 6) | (p - B64);
    bits += 6;
    if (bits >= 0) { out += (char)((val >> bits) & 0xFF); bits -= 8; }
  }
  return out;
}

static String b64encode(const char *s, size_t n) {
  String out;
  for (size_t i = 0; i < n; i += 3) {
    uint32_t v = (uint8_t)s[i] << 16 | (i + 1 < n ? (uint8_t)s[i + 1] << 8 : 0) | (i + 2 < n ? (uint8_t)s[i + 2] : 0);
    out += B64[(v >> 18) & 63];
    out += B64[(v >> 12) & 63];
    out += i + 1 < n ? B64[(v >> 6) & 63] : '=';
    out += i + 2 < n ? B64[v & 63] : '=';
  }
  return out;
}

// "!fput <path> <bytes>" streams a large file (a firmware update) straight to
// storage: base64 lines follow, each answered with "+" once it is on the card.
// The host waits for that before sending the next line: Arduino's USB serial
// drops bytes when its receive queue is full (e.g. during a slow SD write), so
// there is no flow control to rely on. The UI is paused meanwhile. The file is
// written as .part and renamed at the end. Replies "ok <path> <bytes> <crc32>".
static int b64value(char c) {
  const char *p = c ? strchr(B64, c) : nullptr;
  return p ? (int)(p - B64) : -1;
}

static void conPut(const String &arg) {
  int sp = arg.lastIndexOf(' ');
  String path = sp > 0 ? arg.substring(0, sp) : "";
  size_t total = sp > 0 ? arg.substring(sp + 1).toInt() : 0;
  String real;
  fs::FS *fs = path.length() ? store::resolve(path, real, true) : nullptr;
  const size_t LINE = 4096;  // base64 characters per line, at most
  char *line = (char *)malloc(LINE);
  uint8_t *bin = (uint8_t *)malloc(LINE / 4 * 3);
  File f;
  if (!line || !bin || !fs || !total || !(f = fs->open(real + ".part", "w"))) {
    free(line); free(bin);
    reply("error: cannot write " + path);
    return;
  }
  wake();
  auto &d = M5Cardputer.Display;
  d.fillRect(20, 45, 200, 45, ui::col.surface);
  d.setTextColor(ui::col.text);
  d.drawString("Receiving " + path, 28, 52);
  conBuf = "";
  reply("ready");

  size_t got = 0, nextDraw = 0, len = 0;
  uint32_t crc = 0, last = millis();
  bool ok = true;
  while (ok && got < total && millis() - last < 3000) {
    int c = usbdev::serialGet();
    if (c < 0) { delay(1); continue; }
    last = millis();
    if (c != '\n' && c != '\r') {
      if (c >= 0x20 && len < LINE) line[len++] = (char)c;  // control bytes dropped
      continue;
    }
    if (!len) continue;
    size_t n = 0;
    int val = 0, bits = -8;
    for (size_t i = 0; i < len; i++) {
      int v = b64value(line[i]);
      if (v < 0) continue;  // padding
      val = (val << 6) | v;
      bits += 6;
      if (bits >= 0) { bin[n++] = (uint8_t)(val >> bits); bits -= 8; }
    }
    len = 0;
    ok = got + n <= total && f.write(bin, n) == n;
    crc = esp_rom_crc32_le(crc, bin, n);
    got += n;
    reply("+");
    if (got >= nextDraw) {
      d.fillRect(28, 72, (int)(184ULL * got / total), 8, ui::col.accent);
      nextDraw = got + 32768;
    }
  }
  f.close();
  free(line);
  free(bin);
  if (got != total) {
    fs->remove(real + ".part");
    reply("error: got " + String(got) + " of " + String(total) + " bytes");
    return;
  }
  fs->remove(real);
  fs->rename(real + ".part", real);
  reply("ok " + path + " " + String(got) + " " + String(crc, HEX));
  usbdev::log("received " + path + " (" + String(got) + " bytes)");
  notify("Received " + path, String(got / 1024) + " KB");
}

static void conLine(String line) {
  while (line.length() && line[0] == 0x05) line.remove(0, 1);  // log backlog requests
  line.trim();
  if (!line.length()) return;
  if (line[0] == '!') {
    int sp = line.indexOf(' ');
    String cmd = line.substring(1, sp < 0 ? line.length() : sp), arg = sp < 0 ? "" : line.substring(sp + 1);
    if (cmd == "begin") { recvPath = arg; recvData = ""; reply("ok"); }
    else if (cmd == "data") { recvData += b64decode(arg); reply("+"); }
    else if (cmd == "end") {
      bool ok = recvPath.length() && store::write(recvPath, recvData);
      reply(ok ? "ok " + recvPath : "error: write failed");
      recvPath = recvData = "";
      appsDirty = true;
    } else if (cmd == "get") {
      String buf;
      const char *p;
      size_t n;
      if (!store::view(arg, buf, p, n)) { reply("error: not found"); return; }
      for (size_t i = 0; i < n; i += 768) reply("!data " + b64encode(p + i, min((size_t)768, n - i)));
      reply("!end");
    } else if (cmd == "fput") conPut(arg);
    else if (cmd == "bench") { reply("benchmarking crypto (a few seconds)..."); reply(tlsBench()); }
    else if (cmd == "run") { launch(arg); reply("ok"); }
    else if (cmd == "ls") { for (auto &e : store::list(arg)) reply(String(e.dir ? "d " : "- ") + e.name); }
    else if (cmd == "log") {
      String r = usbdev::logDump();
      int s = 0;
      while (s < (int)r.length()) { int e = r.indexOf('\n', s); if (e < 0) e = r.length(); reply("# " + r.substring(s, e)); s = e + 1; }
    } else reply("error: unknown command");
    return;
  }
  if (!conOn) { reply("Lua console is off (Settings > USB)"); return; }
  if (!vm::L) { reply("no app is open: open the Lua REPL app to evaluate Lua"); return; }
  lua_State *L = vm::L;
  String chunk = "return " + line;
  if (luaL_loadbuffer(L, chunk.c_str(), chunk.length(), "=console") != LUA_OK) {
    lua_pop(L, 1);
    if (luaL_loadbuffer(L, line.c_str(), line.length(), "=console") != LUA_OK) {
      reply(lua_tostring(L, -1));
      lua_pop(L, 1);
      return;
    }
  }
  int top = lua_gettop(L) - 1;
  if (!vm::call(0, LUA_MULTRET)) { reply(vm::lastError); return; }
  int last = lua_gettop(L);
  for (int i = top + 1; i <= last; i++) {
    reply(luaL_tolstring(L, i, nullptr));
    lua_pop(L, 1);
  }
  lua_settop(L, top);
}

// "!" file commands work whenever USB serial is on; evaluating Lua needs the
// Lua console setting.
static void conPoll() {
  static bool wasConnected = false;
  bool connected = usbdev::serialConnected();
  if (connected && !wasConnected) conBuf = "";  // new session: drop half lines from the last one
  wasConnected = connected;
  String s = usbdev::serialRead();
  if (!s.length()) return;
  addInput(conBuf, s);
  int nl;
  while ((nl = conBuf.indexOf('\n')) >= 0) {
    String line = conBuf.substring(0, nl);
    conBuf = conBuf.substring(nl + 1);
    conLine(line);
  }
  if (conBuf.length() > 4096) conBuf = "";
}

// ================================================================ Wi-Fi roaming
// When the signal gets weak, look for a clearly stronger access point with the
// same network name (mesh, office and campus Wi-Fi) and move to it.
static const int ROAM_BELOW = -72, ROAM_GAIN = 8;
static int roamWait = 20;
static bool roamScanning = false;


static void roamTick() {
  if (WiFi.status() != WL_CONNECTED) { roamScanning = false; return; }
  if (roamScanning) {
    int n = WiFi.scanComplete();
    if (n == WIFI_SCAN_RUNNING) return;
    roamScanning = false;
    if (n <= 0) { WiFi.scanDelete(); return; }
    String ssid = WiFi.SSID(), cur = WiFi.BSSIDstr();
    int curRssi = WiFi.RSSI(), best = -1, bestRssi = curRssi + ROAM_GAIN;
    for (int i = 0; i < n; i++)
      if (WiFi.SSID(i) == ssid && WiFi.BSSIDstr(i) != cur && WiFi.RSSI(i) >= bestRssi) { best = i; bestRssi = WiFi.RSSI(i); }
    if (best >= 0) {
      uint8_t bssid[6];
      memcpy(bssid, WiFi.BSSID(best), 6);
      int ch = WiFi.channel(best);
      usbdev::log(String("wifi roam: ") + cur + " (" + curRssi + ") -> " + WiFi.BSSIDstr(best) + " ch" + ch + " (" + bestRssi + ")");
      WiFi.scanDelete();
      WiFi.begin(ssid.c_str(), cget("wifi_pass").c_str(), ch, bssid);
    } else {
      WiFi.scanDelete();
    }
    return;
  }
  if (--roamWait > 0) return;
  roamWait = 20;  // check every 20 s
  if (WiFi.RSSI() < ROAM_BELOW && WiFi.scanComplete() != WIFI_SCAN_RUNNING) {
    WiFi.scanNetworks(true);
    roamScanning = true;
  }
}

// ================================================================ services
static bool synced = false, warnedLow = false;
static float serviceAcc = 1;

static void services() {
  if (wifiRestoreAt && (int32_t)(millis() - wifiRestoreAt) >= 0) {
    if (WiFi.getMode() != WIFI_OFF || wifiStartSvc(cget("wifi_ssid"), cget("wifi_pass"), true)) {
      wifiRestoreAt = 0;
      usbdev::log("wifi restored after focus mode");
    } else if (++wifiRestoreTries < 5) {
      wifiRestoreAt = millis() + 3000;
    } else {
      wifiRestoreAt = 0;
      toast("Wi-Fi couldn't restart: not enough memory", 4);
    }
  }
  int pct;
  bool chg;
  batteryInfo(pct, chg);
  ui::status.pct = pct;
  ui::status.charging = chg;
  if (chg) warnedLow = false;
  else if (pct <= 10 && !warnedLow) { warnedLow = true; notify("Battery low", String(pct) + "% left", "low"); }
  ui::status.wifiOn = WiFi.getMode() != WIFI_OFF;
  if (WiFi.status() == WL_CONNECTED) {
    int r = WiFi.RSSI();
    ui::status.wifi = r > -55 ? 4 : r > -65 ? 3 : r > -75 ? 2 : 1;
    if (!synced) { configTzTime(tz().c_str(), "pool.ntp.org", "time.nist.gov"); synced = true; }
  } else {
    ui::status.wifi = 0;
    synced = false;
  }
  struct tm tm;
  if (now(tm)) {
    ui::status.time = formatTime(tm.tm_hour, tm.tm_min);
    alarmCheck(tm);
  } else {
    ui::status.time = "";
  }
  sleepAfter = cget("sleep", "60").toInt();
  roamTick();
}

// ================================================================ entry points
void begin(bool safeMode) {
  safe = safeMode;
  applySettings();
  scanApps();
  conOn = !safe && cget("usb_console") == "1" && usbdev::serialOn();
  String ssid = cget("wifi_ssid");
  bool autoOn = cget("wifi_auto") != "0";
  usbdev::log(String("wifi at boot: saved network=") + (ssid.length() ? "yes" : "no") + " auto=" + (autoOn ? "on" : "off") +
              (safe ? " (safe mode: skipped)" : ""));
  if (!safe && ssid.length() && autoOn) wifiStartSvc(ssid, cget("wifi_pass"), true);
  if (safe) toast("Safe mode: no background services", 4);
  sound("boot");
  // after a firmware update from the App Store: did the new build start?
  String expect = cget("fw_expect");
  if (expect.length()) {
    cfgSet("fw_expect", "");
    String now = POCKETLUA_BUILD + 8;
    if (now.startsWith(expect)) notify("Firmware updated", "Now on build " + expect);
    else notify("Firmware update undone", "Build " + expect + " didn't start; back on " + now);
    usbdev::log("firmware update to " + expect + (now.startsWith(expect) ? ": running" : ": rolled back to " + now));
  }
}

void setHold(bool on) { appHold = on; }
static bool pendingHomeFlag = false;
void requestHome() { pendingHomeFlag = true; }  // called from inside Lua: defer

void runPending();

void update(float dt) {
  if (pendingHomeFlag) { pendingHomeFlag = false; goHome(); }
  // The App Store's downloads need the RAM an open app uses: close it, do the
  // work (appstore.cpp draws its own progress), then open the store again.
  if (appstorePending()) {
    g_crumb = "app store";
    closeApp(true);
    M5Cardputer.Display.fillScreen(col.bg);
    appstoreRun();
    appsDirty = true;
    launch("store", "", 0, true);
    return;
  }
  runPending();
  serviceAcc += dt;
  if (serviceAcc >= 1) { serviceAcc = 0; services(); }
  soundTick(dt);
  timerTick(dt);
  conPoll();
  if (toastMsg.length()) { toastLeft -= dt; if (toastLeft <= 0) toastMsg = ""; }
  if (!asleep) {
    idle += dt;
    if (sleepAfter > 0 && idle >= sleepAfter) { asleep = true; displaySleep(true); }
  }
  if (appsDirty && screen != APP) scanApps();

  // apps that draw straight to the panel lose the hold while system UI shows
  bool want = appHold && dlg.kind == DLG_NONE && overlay == OV_NONE && !toastMsg.length();
  if (want != holdNow) {
    holdNow = want;
    g_displayHold = want;
    if (want && appFn("repaint")) { if (!vm::call(0, 0)) fail(vm::lastError); }
  }

  if (screen == APP && vm::L) {
    lua_State *L = vm::L;
    g_crumb = "app update";
    if (appFn("update")) {
      lua_pushnumber(L, dt);
      if (!vm::call(1, 0)) { fail(vm::lastError); return; }
    }
    lua_rawgeti(L, LUA_REGISTRYINDEX, appRef);
    lua_getfield(L, -1, "title");
    if (lua_isstring(L, -1)) appTitle = lua_tostring(L, -1);
    lua_pop(L, 2);
  }
}

void drawBand() {
  canvas.fillSprite(col.bg);
  String title = "PocketLua";
  switch (screen) {
    case DESKTOP: drawDesktop(); break;
    case DRAWER:
      drawDrawer();
      title = query.length() ? "Search" : folder >= 0 ? CAT_LABELS[folder] : "Apps";
      break;
    case APP:
      g_crumb = "app draw";
      if (appFn("draw") && !vm::call(0, 0)) fail(vm::lastError);
      canvas.clearClipRect();
      title = appTitle;
      break;
    case ERRSCREEN: drawError(); title = "Error"; break;
  }
  if (safe) title = "SAFE - " + title;
  ui::statusbar(title.c_str());
  if (overlay == OV_LOCK) drawLock();
  else if (overlay == OV_QUICK) drawQuick();
  else if (overlay == OV_NOTES) drawNotes();
  else if (overlay == OV_HELP) drawHelp();
  if (dlg.kind != DLG_NONE) drawDialog();
  if (toastMsg.length()) {
    String m = ui::fit(toastMsg, 220);
    int w = m.length() * 6 + 16, x = (240 - w) / 2;
    if (ui::visible(108, 16)) {
      ui::rfill(x, 108, w, 16, 6, col.surface2);
      ui::rrect(x, 108, w, 16, 6, col.accent);
      ui::text(x + 8, 112, m.c_str(), col.text);
    }
  }
}

static void appKey(const Key &k) {
  lua_State *L = vm::L;
  bool consumed = false;
  g_crumb = "app key";
  if (L && appFn("key")) {
    lua_createtable(L, 0, 6);
    lua_pushstring(L, k.key); lua_setfield(L, -2, "key");
    if (k.text) { lua_pushstring(L, k.text); lua_setfield(L, -2, "text"); }
    lua_pushboolean(L, k.ctrl); lua_setfield(L, -2, "ctrl");
    lua_pushboolean(L, k.shift); lua_setfield(L, -2, "shift");
    lua_pushboolean(L, k.fn); lua_setfield(L, -2, "fn");
    lua_pushboolean(L, k.alt); lua_setfield(L, -2, "alt");
    if (!vm::call(1, 1)) { fail(vm::lastError); return; }
    consumed = lua_toboolean(L, -1);
    lua_pop(L, 1);
  }
  if (!consumed && !strcmp(k.key, "esc") && screen == APP) back();
}

void key(const Key &k) {
  if (asleep || g_displayAsleep) { wake(); return; }
  idle = 0;
  if (cget("click") == "1") playTone(2400, 6);
  if (!strcmp(k.key, "home")) {
    if (dlg.kind != DLG_NONE) finishDialog(false, 0, "");
    overlay = OV_NONE;
    goHome();
    return;
  }
  if (overlay == OV_LOCK) { overlay = OV_NONE; return; }
  if (k.fn && k.text && dlg.kind == DLG_NONE) {
    char c = tolower(k.text[0]);
    if (c == 'q') { overlay = overlay == OV_QUICK ? OV_NONE : OV_QUICK; quickSel = 0; return; }
    if (c == 'n') { overlay = overlay == OV_NOTES ? OV_NONE : OV_NOTES; ui::status.unread = 0; notesSel = notesTop = 1; return; }
    if (c == 'p') { screenshot(); return; }
    if (c == 'l') { if (cget("lock") != "0") overlay = OV_LOCK; return; }
    if (c == 'h') { if (overlay == OV_HELP) { overlay = OV_NONE; helpRows.clear(); } else openHelp(); return; }
  }
  if (dlg.kind != DLG_NONE) { dialogKey(k); return; }
  if (overlay == OV_QUICK) { quickKey(k); return; }
  if (overlay == OV_NOTES) { notesKey(k); return; }
  if (overlay == OV_HELP) { helpKey(k); return; }
  switch (screen) {
    case DESKTOP: desktopKey(k); break;
    case DRAWER: drawerKey(k); break;
    case APP: appKey(k); break;
    case ERRSCREEN: errorKey(k); break;
  }
}

// ================================================================ Lua `shell`
static String S(lua_State *L, int i) { return String(luaL_checkstring(L, i)); }
static String OS(lua_State *L, int i) { return lua_isstring(L, i) ? String(lua_tostring(L, i)) : String(); }

static int storeCallback(lua_State *L, int idx) {
  if (!lua_isfunction(L, idx)) return LUA_NOREF;
  lua_pushvalue(L, idx);
  return luaL_ref(L, LUA_REGISTRYINDEX);
}

static int l_toast(lua_State *L) {
  float secs = lua_isnumber(L, 2) ? (float)lua_tonumber(L, 2) : 2;  // lenient: some apps pass extra text
  toast(luaL_tolstring(L, 1, nullptr), secs);
  return 0;
}
static int l_alert(lua_State *L) { openDialog(DLG_ALERT, S(L, 1), OS(L, 2)); dlg.luaRef = storeCallback(L, 3); return 0; }
static int l_confirm(lua_State *L) { openDialog(DLG_CONFIRM, S(L, 1), OS(L, 2)); dlg.luaRef = storeCallback(L, 3); return 0; }
static int l_prompt(lua_State *L) {
  openDialog(DLG_PROMPT, S(L, 1), "");
  dlg.text = OS(L, 2);
  dlg.luaRef = storeCallback(L, 3);
  if (lua_istable(L, 4)) { lua_getfield(L, 4, "secret"); dlg.secret = lua_toboolean(L, -1); lua_pop(L, 1); }
  return 0;
}
static int l_menu(lua_State *L) {
  openDialog(DLG_MENU, S(L, 1), "");
  luaL_checktype(L, 2, LUA_TTABLE);
  for (int i = 1; i <= (int)lua_rawlen(L, 2); i++) {
    lua_rawgeti(L, 2, i);
    dlg.items.push_back(luaL_tolstring(L, -1, nullptr));
    lua_pop(L, 2);
  }
  if (dlg.items.empty()) { dlg = Dialog(); return 0; }
  dlg.luaRef = storeCallback(L, 3);
  return 0;
}
static int l_notify(lua_State *L) { notify(S(L, 1), OS(L, 2), lua_isstring(L, 3) ? lua_tostring(L, 3) : "notify"); return 0; }
static int l_sound(lua_State *L) { sound(luaL_checkstring(L, 1), lua_toboolean(L, 2)); return 0; }

// Launching from inside a Lua call would close the VM under it, so it is
// deferred to the next frame.
static String pendingApp, pendingPath;
static int pendingLine = 0;
static bool pendingHome = false, pendingBack = false;
static int l_launch(lua_State *L) {
  pendingApp = S(L, 1);
  pendingPath = "";
  pendingLine = 0;
  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "path"); pendingPath = OS(L, -1); lua_pop(L, 1);
    lua_getfield(L, 2, "line"); pendingLine = lua_isinteger(L, -1) ? lua_tointeger(L, -1) : 0; lua_pop(L, 1);
  }
  return 0;
}
static int l_edit(lua_State *L) { pendingApp = "edit"; pendingPath = S(L, 1); pendingLine = (int)luaL_optinteger(L, 2, 0); return 0; }
static int l_home(lua_State *L) { pendingHome = true; return 0; }
static int l_back(lua_State *L) { pendingBack = true; return 0; }
static int l_open_file(lua_State *L) {
  String p = S(L, 1);
  int dot = p.lastIndexOf('.');
  String ext = dot >= 0 ? p.substring(dot + 1) : "";
  ext.toLowerCase();
  String app = (ext == "wav" || ext == "mp3") ? "music" : (ext == "bmp" || ext == "jpg" || ext == "jpeg" || ext == "png") ? "images" : "edit";
  if (!store::exists(appFile(app))) { toast("Get " + app + " from the App Store to open this"); return 0; }
  pendingApp = app;
  pendingPath = p;
  pendingLine = 0;
  return 0;
}
static int l_run_file(lua_State *L) {
  String p = S(L, 1);
  if (p.startsWith("apps/") && p.endsWith("/main.lua")) { pendingApp = p.substring(5, p.length() - 9); pendingPath = ""; }
  else toast("Saved " + p);
  appsDirty = true;
  return 0;
}
static int l_app(lua_State *L) { lua_pushstring(L, screen == APP ? appName.c_str() : "home"); return 1; }
static int l_format_time(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "h"); int h = lua_tointeger(L, -1);
  lua_getfield(L, 1, "m"); int m = lua_tointeger(L, -1);
  lua_pop(L, 2);
  lua_pushstring(L, formatTime(h, m).c_str());
  return 1;
}
static int l_tz(lua_State *L) { lua_pushstring(L, tz().c_str()); return 1; }
static int l_wifi_start(lua_State *L) { lua_pushboolean(L, wifiStartSvc(OS(L, 1), OS(L, 2), false)); return 1; }
static int l_wifi_stop(lua_State *L) { wifiEnable(false); return 0; }
static int l_focus(lua_State *L) { focus(lua_toboolean(L, 1)); return 0; }
static int l_start_timer(lua_State *L) {
  Timer &t = startTimer((float)luaL_checknumber(L, 1), lua_isstring(L, 2) ? lua_tostring(L, 2) : "Timer");
  if (lua_istable(L, 3)) {
    lua_getfield(L, 3, "pomo"); t.pomo = OS(L, -1); lua_pop(L, 1);
    lua_getfield(L, 3, "count"); t.count = lua_tointeger(L, -1); lua_pop(L, 1);
    lua_getfield(L, 3, "work"); t.work = lua_tointeger(L, -1); lua_pop(L, 1);
    lua_getfield(L, 3, "rest"); t.rest = lua_tointeger(L, -1); lua_pop(L, 1);
  }
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, t.id); lua_setfield(L, -2, "id");
  lua_pushstring(L, t.label.c_str()); lua_setfield(L, -2, "label");
  return 1;
}
static int l_cancel_timer(lua_State *L) {
  int id = 0;
  if (lua_istable(L, 1)) { lua_getfield(L, 1, "id"); id = lua_tointeger(L, -1); lua_pop(L, 1); }
  else id = (int)luaL_optinteger(L, 1, 0);
  for (size_t i = 0; i < timers.size(); i++)
    if (timers[i].id == id) { timers.erase(timers.begin() + i); break; }
  return 0;
}
static int l_free_memory(lua_State *L) {
  lua_gc(L, LUA_GCCOLLECT);
  lua_pushinteger(L, freeHeap());
  return 1;
}
static int l_screenshot(lua_State *L) { screenshot(); return 0; }
static int l_sleep_after(lua_State *L) { lua_pushinteger(L, sleepAfter); return 1; }
static int l_lock(lua_State *L) { if (cget("lock") != "0") overlay = OV_LOCK; return 0; }
static int l_wake(lua_State *L) { wake(); return 0; }
static int l_apply_settings(lua_State *L) {
  applySettings();
  lua_getglobal(L, "ui");
  if (lua_istable(L, -1)) {  // refresh ui.col in this VM
    lua_getfield(L, -1, "set_theme");
    lua_pushstring(L, ui::themeName.c_str());
    lua_call(L, 1, 0);
  }
  lua_pop(L, 1);
  return 0;
}
static int l_overlay(lua_State *L) {
  String n = S(L, 1);
  overlay = n == "quick" ? OV_QUICK : n == "notifications" ? OV_NOTES : n == "lock" ? OV_LOCK : OV_NONE;
  quickSel = 0;
  return 0;
}
static int l_close_overlay(lua_State *L) { overlay = OV_NONE; return 0; }
static int l_overlay_name(lua_State *L) {
  const char *n = overlay == OV_QUICK ? "quick" : overlay == OV_NOTES ? "notifications" : overlay == OV_LOCK ? "lock" : nullptr;
  if (n) lua_pushstring(L, n); else lua_pushnil(L);
  return 1;
}
static int l_console_running(lua_State *L) { lua_pushboolean(L, conOn); return 1; }
static int l_mark_read(lua_State *L) { ui::status.unread = 0; return 0; }
static std::vector<String> logRing;
static int l_log_line(lua_State *L) {
  String s = S(L, 1);
  usbdev::log(s);
  logRing.push_back(s);
  if (logRing.size() > 30) logRing.erase(logRing.begin());
  return 0;
}

static int l_index(lua_State *L) {
  String k = OS(L, 2);
  if (k == "clipboard") { lua_pushstring(L, clipboard.c_str()); return 1; }
  if (k == "timers") {
    lua_createtable(L, timers.size(), 0);
    for (size_t i = 0; i < timers.size(); i++) {
      auto &t = timers[i];
      lua_createtable(L, 0, 6);
      lua_pushinteger(L, t.id); lua_setfield(L, -2, "id");
      lua_pushstring(L, t.label.c_str()); lua_setfield(L, -2, "label");
      lua_pushnumber(L, t.left); lua_setfield(L, -2, "left");
      lua_pushnumber(L, t.total); lua_setfield(L, -2, "total");
      if (t.pomo.length()) { lua_pushstring(L, t.pomo.c_str()); lua_setfield(L, -2, "pomo"); }
      lua_pushinteger(L, t.count); lua_setfield(L, -2, "count");
      lua_rawseti(L, -2, i + 1);
    }
    return 1;
  }
  if (k == "log") {
    lua_createtable(L, logRing.size(), 0);
    for (size_t i = 0; i < logRing.size(); i++) { lua_pushstring(L, logRing[i].c_str()); lua_rawseti(L, -2, i + 1); }
    return 1;
  }
  if (k == "notes") {
    lua_createtable(L, notes.size(), 0);
    for (size_t i = 0; i < notes.size(); i++) {
      lua_createtable(L, 0, 3);
      lua_pushstring(L, notes[i].title.c_str()); lua_setfield(L, -2, "title");
      lua_pushstring(L, notes[i].body.c_str()); lua_setfield(L, -2, "body");
      lua_pushstring(L, notes[i].time.c_str()); lua_setfield(L, -2, "time");
      lua_rawseti(L, -2, i + 1);
    }
    return 1;
  }
  if (k == "handlers") {
    lua_newtable(L);
    const char *edit[] = {"lua", "txt", "md", "csv", "json", "cfg", "conf", "ini", "log"};
    for (auto e : edit) { lua_pushstring(L, "edit"); lua_setfield(L, -2, e); }
    for (auto e : {"wav", "mp3"}) { lua_pushstring(L, "music"); lua_setfield(L, -2, e); }
    for (auto e : {"bmp", "jpg", "jpeg", "png"}) { lua_pushstring(L, "images"); lua_setfield(L, -2, e); }
    return 1;
  }
  return 0;
}
static int l_newindex(lua_State *L) {
  if (OS(L, 2) == "clipboard") clipboard = OS(L, 3);
  else lua_rawset(L, 1);
  return 0;
}

void registerLua(lua_State *L) {
  static const luaL_Reg fns[] = {
      {"toast", l_toast}, {"alert", l_alert}, {"confirm", l_confirm}, {"prompt", l_prompt}, {"menu", l_menu},
      {"notify", l_notify}, {"sound", l_sound}, {"launch", l_launch}, {"edit", l_edit}, {"home", l_home},
      {"back", l_back}, {"open_file", l_open_file}, {"run_file", l_run_file}, {"app", l_app},
      {"format_time", l_format_time}, {"tz", l_tz}, {"wifi_start", l_wifi_start}, {"wifi_stop", l_wifi_stop}, {"focus", l_focus},
      {"start_timer", l_start_timer}, {"cancel_timer", l_cancel_timer}, {"free_memory", l_free_memory},
      {"screenshot", l_screenshot}, {"sleep_after", l_sleep_after}, {"lock", l_lock}, {"wake", l_wake},
      {"apply_settings", l_apply_settings}, {"overlay", l_overlay}, {"close_overlay", l_close_overlay},
      {"overlay_name", l_overlay_name}, {"console_running", l_console_running}, {"mark_read", l_mark_read},
      {"log_line", l_log_line}, {nullptr, nullptr}};
  luaL_newlib(L, fns);
  lua_createtable(L, 0, 2);
  lua_pushcfunction(L, l_index); lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, l_newindex); lua_setfield(L, -2, "__newindex");
  lua_setmetatable(L, -2);
  lua_setglobal(L, "shell");
}

// Deferred navigation requested from Lua (see l_launch).
void runPending() {
  if (pendingHome) { pendingHome = false; pendingApp = ""; goHome(); return; }
  if (pendingBack) { pendingBack = false; back(); return; }
  if (pendingApp.length()) {
    String a = pendingApp, p = pendingPath;
    int l = pendingLine;
    pendingApp = "";
    launch(a, p, l);
  }
}

}  // namespace shell
