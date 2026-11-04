// LiveOS: a live-editable shell for the Cardputer ADV. The C++ core owns the
// hardware and the Lua VM; everything the user sees is Lua that can be edited
// on the device. Runs as a normal app image, so M5Launcher can start it.
#include <M5Cardputer.h>
#include <lua.hpp>
#include <esp_heap_caps.h>
#include <functional>
#include "bindings.h"
#include "embedded.h"
#include "storage.h"
#include "usbdev.h"
#include "hw.h"
#include "luapool.h"
#include <Preferences.h>

// A quarter-screen frame buffer (16 KB instead of 65 KB): each frame is drawn
// in four bands, with g_bandY telling the drawing calls which band.
M5Canvas canvas(&M5Cardputer.Display);
static const int BAND_H = (SCREEN_H + 3) / 4;  // 4 bands: 16 KB buffer
int g_bandY = 0;
bool g_displayAsleep = false;  // set by sys.display_sleep(); skips drawing
bool g_displayHold = false;    // set by sys.display_hold(); the app draws directly
String g_screenshotPath;       // set by sys.screenshot(); taken on the next frame
bool g_reloadRequested = false;
String g_recoveredMsg;

static lua_State *L = nullptr;
static size_t memUsed = 0;
// Scripts may use up to MEM_LIMIT, but never push free internal RAM below
// HEAP_RESERVE: Wi-Fi, USB and the SD driver allocate at run time and the
// ESP32-S3 here has no PSRAM to fall back on.
static const size_t MEM_LIMIT = 160 * 1024;
static const size_t HEAP_RESERVE = 20 * 1024;
static const uint32_t CALL_BUDGET_MS = 2500;
static uint32_t callStart = 0;
static bool timedOut = false;
static String lastError;
static int failStreak = 0;

size_t luaMemUsed() { return memUsed; }

// ---------------------------------------------------------------- Lua VM
static void releaseBlock(void *p, size_t size) {
  if (size <= luapool::MAX_SMALL) luapool::release(p, size);
  else free(p);
}

// Lua passes the old block size with every free/realloc, so small blocks are
// routed to the pool (see luapool.h) and larger ones to the normal heap.
static void *luaAlloc(void *, void *ptr, size_t osize, size_t nsize) {
  if (ptr == nullptr) osize = 0;
  if (nsize == 0) {
    if (ptr) { memUsed -= osize; releaseBlock(ptr, osize); }
    return nullptr;
  }
  if (nsize > osize) {
    size_t grow = nsize - osize;
    if (memUsed + grow > MEM_LIMIT) return nullptr;
    if (heap_caps_get_free_size(MALLOC_CAP_8BIT) < grow + HEAP_RESERVE) return nullptr;
  }
  bool oldSmall = ptr && osize <= luapool::MAX_SMALL;
  bool newSmall = nsize <= luapool::MAX_SMALL;
  void *p;
  if (!ptr) {
    p = newSmall ? luapool::alloc(nsize) : malloc(nsize);
  } else if (oldSmall && newSmall && luapool::sameClass(osize, nsize)) {
    p = ptr;
  } else if (!oldSmall && !newSmall) {
    p = realloc(ptr, nsize);
  } else {
    p = newSmall ? luapool::alloc(nsize) : malloc(nsize);
    if (p) {
      memcpy(p, ptr, osize < nsize ? osize : nsize);
      releaseBlock(ptr, osize);
    }
  }
  if (p) memUsed = memUsed - osize + nsize;
  return p;
}

// A script that never returns would freeze the whole device, so fail it instead.
static void luaHook(lua_State *Ls, lua_Debug *) {
  if (!timedOut && millis() - callStart > CALL_BUDGET_MS) {
    timedOut = true;
    luaL_error(Ls, "script timed out (no return after %d ms)", (int)CALL_BUDGET_MS);
  }
}

static void logHeap(const char *tag);

void luaBudgetReset() { callStart = millis(); }

static bool pcallTimed(int nargs) {
  callStart = millis();
  timedOut = false;
  if (lua_pcall(L, nargs, 0, 0) != LUA_OK) {
    lastError = lua_tostring(L, -1) ? lua_tostring(L, -1) : "unknown error";
    usbdev::log("lua error: " + lastError);
    if (failStreak == 0) logHeap("at error");
    lua_pop(L, 1);
    return false;
  }
  return true;
}

static bool callGlobal(const char *name, const std::function<int(lua_State *)> &push) {
  int top = lua_gettop(L);
  lua_getglobal(L, name);
  if (!lua_isfunction(L, -1)) { lua_settop(L, top); return true; }
  int n = push ? push(L) : 0;
  bool ok = pcallTimed(n);
  lua_settop(L, top);
  return ok;
}

static void logHeap(const char *tag) {
  usbdev::log(String("heap ") + tag + ": free=" + ESP.getFreeHeap() + " largest=" +
              heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) + " lua=" + memUsed +
              " pool=" + luapool::pageBytes() + " stack_free=" + uxTaskGetStackHighWaterMark(nullptr));
}

static bool bootLua(bool safe) {
  store::safeMode = safe;
  memUsed = 0;
  L = lua_newstate(luaAlloc, nullptr);
  if (!L) { lastError = "out of memory"; return false; }
  luaL_requiref(L, "_G", luaopen_base, 1);
  luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);
  luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
  luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);
  luaL_requiref(L, LUA_UTF8LIBNAME, luaopen_utf8, 1);
  luaL_requiref(L, LUA_COLIBNAME, luaopen_coroutine, 1);
  lua_settop(L, 0);
  lua_pushnil(L); lua_setglobal(L, "dofile");
  lua_pushnil(L); lua_setglobal(L, "loadfile");
  lua_sethook(L, luaHook, LUA_MASKCOUNT, 20000);
  registerApi(L);
  registerHw(L);

  String buf;
  const char *src;
  size_t srcLen;
  if (!store::view("boot.lua", buf, src, srcLen)) { lastError = "boot.lua missing"; return false; }
  if (luaL_loadbuffer(L, src, srcLen, "@boot.lua") != LUA_OK) {
    lastError = lua_tostring(L, -1);
    return false;
  }
  return pcallTimed(0);
}

static void closeLua() {
  if (L) lua_close(L);
  L = nullptr;
}

// gfx.band_y / gfx.band_h tell Lua which rows the current band covers, so
// drawing code can skip what lies outside it (ui.visible).
static void setBand() {
  lua_getglobal(L, "gfx");
  lua_pushinteger(L, g_bandY);
  lua_setfield(L, -2, "band_y");
  lua_pushinteger(L, BAND_H);
  lua_setfield(L, -2, "band_h");
  lua_pop(L, 1);
}

// Renders the next frame band by band into a 24-bit BMP (top-down rows).
static bool writeScreenshot(const String &path) {
  String real;
  fs::FS *fs = store::resolve(path, real, true);
  if (!fs) return false;
  File f = fs->open(real, "w");
  if (!f) return false;
  uint8_t h[54] = {'B', 'M'};
  auto put32 = [&](int o, int32_t v) { h[o] = v; h[o + 1] = v >> 8; h[o + 2] = v >> 16; h[o + 3] = v >> 24; };
  const int rowBytes = SCREEN_W * 3;
  put32(2, 54 + rowBytes * SCREEN_H); put32(10, 54); put32(14, 40);
  put32(18, SCREEN_W); put32(22, -SCREEN_H);  // negative height: rows top to bottom
  h[26] = 1; h[28] = 24;
  put32(34, rowBytes * SCREEN_H);
  f.write(h, 54);
  uint8_t row[SCREEN_W * 3];
  for (g_bandY = 0; g_bandY < SCREEN_H; g_bandY += BAND_H) {
    setBand();
    callGlobal("on_draw", nullptr);
    for (int y = 0; y < BAND_H && g_bandY + y < SCREEN_H; y++) {
      for (int x = 0; x < SCREEN_W; x++) {
        uint16_t c = canvas.readPixel(x, y);
        row[x * 3] = (c & 0x1F) << 3;
        row[x * 3 + 1] = ((c >> 5) & 0x3F) << 2;
        row[x * 3 + 2] = (c >> 11) << 3;
      }
      f.write(row, rowBytes);
    }
    canvas.pushSprite(0, g_bandY);
  }
  g_bandY = 0;
  f.close();
  return true;
}

// Static screens draw straight to the display; the frame buffer is only half
// the screen tall.
static void showFatal(const String &msg) {
  auto &d = M5Cardputer.Display;
  d.fillScreen(TFT_BLACK);
  d.setTextSize(1);
  d.setTextColor(TFT_RED);
  d.drawString("LiveOS could not start", 4, 4);
  d.setTextColor(TFT_WHITE);
  for (int i = 0, y = 20; i < (int)msg.length() && y < 125; i += 38, y += 10)
    d.drawString(msg.substring(i, i + 38), 4, y);
}

// ---------------------------------------------------------------- keyboard
// Fixed-size key records: this runs every frame while a key is held, so it
// must not allocate (heap churn fragments the small internal RAM).
struct KeyEv {
  char key[10];
  char text[2];
};
static const int MAX_KEYS = 8;
static KeyEv prevKeys[MAX_KEYS];
static int prevCount = 0;
static KeyEv lastEv;
static uint32_t heldSince = 0, lastRepeat = 0;

static void setKey(KeyEv &e, const char *key, char text) {
  strncpy(e.key, key, sizeof e.key - 1);
  e.key[sizeof e.key - 1] = 0;
  e.text[0] = text;
  e.text[1] = 0;
}

static void emitKey(const KeyEv &e, const Keyboard_Class::KeysState &st) {
  callGlobal("on_key", [&](lua_State *Ls) {
    lua_createtable(Ls, 0, 6);
    lua_pushstring(Ls, e.key); lua_setfield(Ls, -2, "key");
    if (e.text[0]) { lua_pushstring(Ls, e.text); lua_setfield(Ls, -2, "text"); }
    lua_pushboolean(Ls, st.ctrl); lua_setfield(Ls, -2, "ctrl");
    lua_pushboolean(Ls, st.shift); lua_setfield(Ls, -2, "shift");
    lua_pushboolean(Ls, st.fn); lua_setfield(Ls, -2, "fn");
    lua_pushboolean(Ls, st.alt); lua_setfield(Ls, -2, "alt");
    return 1;
  });
}

static int currentKeys(const Keyboard_Class::KeysState &st, KeyEv *cur) {
  int n = 0;
  bool space = st.space;
  for (char c : st.word) {
    if (c == ' ') { space = true; continue; }
    if (n >= MAX_KEYS - 4) break;  // leave room for the special keys below
    const char *named = nullptr;
    if (st.fn) {
      switch (c) {
        case ';': named = "up"; break;
        case '.': named = "down"; break;
        case ',': named = "left"; break;
        case '/': named = "right"; break;
        case '`': named = "esc"; break;
        default: break;
      }
    }
    if (named) {
      setKey(cur[n++], named, 0);
    } else {
      char k[2] = {c, 0};
      setKey(cur[n++], k, c);
    }
  }
  if (space) setKey(cur[n++], "space", ' ');
  if (st.enter) setKey(cur[n++], "enter", 0);
  if (st.del) setKey(cur[n++], st.fn ? "delete" : "backspace", 0);
  if (st.tab) setKey(cur[n++], "tab", 0);
  return n;
}

static void pollKeys() {
  M5Cardputer.update();
  const auto &st = M5Cardputer.Keyboard.keysState();
  if (M5Cardputer.BtnA.wasPressed()) {
    KeyEv home;
    setKey(home, "home", 0);
    emitKey(home, st);
  }
  if (!M5Cardputer.Keyboard.isPressed()) {
    prevCount = 0;
    return;
  }
  KeyEv cur[MAX_KEYS];
  int n = currentKeys(st, cur);
  bool same = n == prevCount;
  for (int i = 0; same && i < n; i++) same = strcmp(cur[i].key, prevKeys[i].key) == 0;
  uint32_t now = millis();
  if (!same) {
    for (int i = 0; i < n; i++) {
      bool isNew = true;
      for (int j = 0; j < prevCount; j++)
        if (strcmp(prevKeys[j].key, cur[i].key) == 0) isNew = false;
      if (isNew) { emitKey(cur[i], st); lastEv = cur[i]; }
    }
    memcpy(prevKeys, cur, sizeof(KeyEv) * n);
    prevCount = n;
    heldSince = lastRepeat = now;
  } else if (n > 0 && now - heldSince > 400 && now - lastRepeat > 60) {
    emitKey(lastEv, st);
    lastRepeat = now;
  }
}

static bool safeKeyHeld() {
  M5Cardputer.update();
  if (!M5Cardputer.Keyboard.isPressed()) return false;
  for (char c : M5Cardputer.Keyboard.keysState().word)
    if (c == 's' || c == 'S') return true;
  return false;
}

// ---------------------------------------------------------------- main task
static void splash() {
  auto &d = M5Cardputer.Display;
  d.fillScreen(TFT_BLACK);
  d.setTextColor(d.color565(64, 140, 255));
  d.setTextSize(3);
  d.drawString("LiveOS", 56, 40);
  d.setTextSize(1);
  d.setTextColor(d.color565(130, 138, 156));
  d.drawString("hold S for safe mode", 66, 90);
}

static void osTask(void *) {
  auto cfg = M5.config();
  cfg.internal_mic = true;  // configures the codec pins; started only when an app records
  logHeap("start");
  M5Cardputer.begin(cfg, true);
  M5Cardputer.Speaker.end();  // started on the first sound (see snd.tone)
  M5Cardputer.Mic.end();
  logHeap("after M5 begin");
  M5Cardputer.Display.setRotation(1);
  M5Cardputer.Display.setFont(&fonts::Font0);
  M5Cardputer.Display.setTextDatum(top_left);
  canvas.createSprite(SCREEN_W, BAND_H);
  canvas.setFont(&fonts::Font0);
  canvas.setTextDatum(top_left);
  logHeap("after frame buffer");
  M5Cardputer.Speaker.setVolume(100);

  splash();
  store::begin();
  logHeap("after storage");
  {
    // USB classes are chosen in Settings and take effect at boot.
    Preferences p;
    p.begin("liveos", true);
    bool kbd = p.getString("usb_kbd", "0") == "1";
    bool drive = p.getString("usb_drive", "0") == "1";
    bool serial = p.getString("usb_serial", "1") == "1";  // on by default so the log can be read
    bool console = p.getString("usb_console", "0") == "1";
    bool mouse = p.getString("usb_mouse", "0") == "1";
    p.end();
    usbdev::begin(kbd, drive, serial, console, mouse);
    usbdev::log(String("LiveOS boot, storage=") + store::kind() + ", embedded files=" + (int)EMBEDDED_COUNT);
  }
  logHeap("after usb");
  bool safe = false;
  for (int i = 0; i < 12; i++) {
    if (safeKeyHeld()) safe = true;
    delay(60);
  }

  while (!bootLua(safe)) {
    String err = lastError;
    closeLua();
    if (!safe) {
      usbdev::log("boot failed, retrying in safe mode: " + err);
      g_recoveredMsg = err;
      safe = true;
      continue;
    }
    showFatal(err);
    for (;;) { usbdev::tick(); delay(50); }  // keep the USB log readable
  }

  logHeap(safe ? "booted (safe)" : "booted");
  uint32_t last = millis();
  for (;;) {
    uint32_t t0 = millis();
    if (g_reloadRequested) {
      g_reloadRequested = false;
      closeLua();
      while (!bootLua(safe)) {
        g_recoveredMsg = lastError;
        closeLua();
        if (safe) {
          showFatal(lastError);
          for (;;) { usbdev::tick(); delay(50); }  // keep the USB log readable
        }
        safe = true;
      }
      failStreak = 0;
    }

    usbdev::tick();
    store::idleTick();
    static uint32_t lastHeapLog = 0;
    if (millis() - lastHeapLog > 30000) {
      lastHeapLog = millis();
      logHeap("periodic");
    }
    pollKeys();
    float dt = (t0 - last) / 1000.0f;
    last = t0;
    bool ok = callGlobal("on_frame", [&](lua_State *Ls) { lua_pushnumber(Ls, dt); return 1; });
    hwTick();
    if (g_screenshotPath.length() && !g_displayAsleep && !g_displayHold) {
      String path = g_screenshotPath;
      g_screenshotPath = "";
      bool shot = writeScreenshot(path);
      callGlobal("on_screenshot", [&](lua_State *Ls) {
        lua_pushstring(Ls, path.c_str());
        lua_pushboolean(Ls, shot);
        return 2;
      });
    } else if (!g_displayAsleep && !g_displayHold) {
      for (g_bandY = 0; g_bandY < SCREEN_H; g_bandY += BAND_H) {
        setBand();
        ok = callGlobal("on_draw", nullptr) && ok;
        canvas.pushSprite(0, g_bandY);
      }
      g_bandY = 0;
    }

    // The shell catches app errors itself; an error reaching here means the
    // shell is broken, so fall back to the built-in one after repeated failures.
    failStreak = ok ? 0 : failStreak + 1;
    if (failStreak >= 3 && !safe) {
      g_recoveredMsg = lastError;
      safe = true;
      g_reloadRequested = true;
    } else if (failStreak >= 3) {
      showFatal(lastError);
      delay(2000);
    }

    // asleep: nothing is drawn, so poll less often and save battery
    uint32_t frameMs = g_displayAsleep ? 100 : 33;
    uint32_t el = millis() - t0;
    if (el < frameMs) delay(frameMs - el);
  }
}

// The OS runs on Arduino's own loop task (with a larger stack) instead of a
// second task, which saves that task's stack.
SET_LOOP_TASK_STACK_SIZE(20 * 1024);  // Lua C-call depth is capped (LUAI_MAXCCALLS) to fit

void setup() {
  Serial.begin(115200);
  osTask(nullptr);  // never returns
}

void loop() { vTaskDelay(pdMS_TO_TICKS(1000)); }
