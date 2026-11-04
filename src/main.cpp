// LiveOS for the Cardputer ADV. The OS itself (desktop, drawer, system UI,
// services) is native code in system.cpp; apps are live-editable Lua that
// runs in a VM created only while the app is open (vm.cpp).
// Runs as a normal app image, so M5Launcher can start it.
#include <esp_system.h>
#include <M5Cardputer.h>
#include <WiFi.h>
#include <esp_heap_caps.h>
#include <Preferences.h>
#include "bindings.h"
#include "embedded.h"
#include "hw.h"
#include "luapool.h"
#include "storage.h"
#include "system.h"
#include "usbdev.h"
#include "vm.h"
#include "syslog.h"

// A quarter-screen frame buffer (16 KB instead of 65 KB): each frame is drawn
// in four bands; g_bandY tells the drawing code which band it is.
M5Canvas canvas(&M5Cardputer.Display);
static const int BAND_H = (SCREEN_H + 3) / 4;
int g_bandY = 0;
int g_bandH = BAND_H;

// Stall diagnosis: the main loop leaves a breadcrumb (what it is doing) and a
// heartbeat. A small task watches the heartbeat: if the loop stops for 8 s it
// logs the breadcrumb (USB still works from another task); after 30 s it
// restarts, and the next boot logs where the last run was stuck. The text is
// kept in RTC memory, which survives a software restart.
const char *volatile g_crumb = "boot";
static volatile uint32_t g_beat = 0;
RTC_NOINIT_ATTR static char stuckAt[40];
RTC_NOINIT_ATTR static uint32_t stuckMagic;
static const uint32_t STUCK = 0x57A11ED;

static void watchMain(void *) {
  uint32_t last = g_beat, since = millis();
  bool told = false;
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(1000));
    if (g_beat != last) { last = g_beat; since = millis(); told = false; continue; }
    uint32_t stuck = millis() - since;
    if (stuck > 8000 && !told) {
      told = true;
      usbdev::log(String("main loop stuck for 8 s at: ") + g_crumb);
    }
    if (stuck > 30000) {
      strlcpy(stuckAt, g_crumb, sizeof stuckAt);
      stuckMagic = STUCK;
      esp_restart();
    }
  }
}

bool g_displayAsleep = false;  // display sleep: nothing is drawn
bool g_displayHold = false;    // an app draws straight to the panel
String g_screenshotPath;       // taken on the next frame

size_t luaMemUsed() { return vm::memUsed(); }

static void logHeap(const char *tag) {
  usbdev::log(String("heap ") + tag + ": free=" + ESP.getFreeHeap() + " largest=" +
              heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) + " lua=" + vm::memUsed() +
              " pool=" + luapool::pageBytes() + " arena_free=" + vm::arenaFree() +
              " stack_free=" + uxTaskGetStackHighWaterMark(nullptr));
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
  for (g_bandY = 0; g_bandY < SCREEN_H; g_bandY += g_bandH) {
    shell::drawBand();
    for (int y = 0; y < g_bandH && g_bandY + y < SCREEN_H; y++) {
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
  shell::Key k = {e.key, e.text[0] ? e.text : nullptr, st.ctrl, st.shift, st.fn, st.alt};
  shell::key(k);
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
    // Time the hold from after the handler: a slow one (starting the mic takes
    // ~250 ms) would otherwise turn a normal press into a repeat.
    heldSince = lastRepeat = millis();
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


// Why the last run ended, for the log: a crash shows up as PANIC or a watchdog.
static const char *resetReason() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON: return "power on";
    case ESP_RST_SW: return "software restart";
    case ESP_RST_PANIC: return "PANIC (crash)";
    case ESP_RST_INT_WDT: return "INTERRUPT WATCHDOG";
    case ESP_RST_TASK_WDT: return "TASK WATCHDOG";
    case ESP_RST_WDT: return "WATCHDOG";
    case ESP_RST_BROWNOUT: return "BROWNOUT (low power)";
    case ESP_RST_DEEPSLEEP: return "deep sleep";
    default: return "other";
  }
}

static void osMain() {
  auto cfg = M5.config();
  cfg.internal_mic = true;  // configures the codec pins; started only when an app records
  logHeap("start");
  M5Cardputer.begin(cfg, true);
  M5Cardputer.Speaker.end();  // started on the first sound
  M5Cardputer.Mic.end();
  M5Cardputer.Display.setRotation(1);
  M5Cardputer.Display.setFont(&fonts::Font0);
  M5Cardputer.Display.setTextDatum(top_left);
  canvas.createSprite(SCREEN_W, BAND_H);
  canvas.setFont(&fonts::Font0);
  canvas.setTextDatum(top_left);
  splash();
  store::begin();
  {
    // USB classes are chosen in Settings and take effect at boot.
    bool kbd = cfgGet("usb_kbd", "0") == "1";
    bool drive = cfgGet("usb_drive", "0") == "1";
    bool serial = cfgGet("usb_serial", "1") == "1";  // on by default so the log can be read
    bool console = cfgGet("usb_console", "0") == "1";
    bool mouse = cfgGet("usb_mouse", "0") == "1";
    usbdev::begin(kbd, drive, serial, console, mouse);
    usbdev::log(String("reset reason: ") + resetReason());
    if (stuckMagic == STUCK) {
      stuckAt[sizeof stuckAt - 1] = 0;
      usbdev::log(String("previous run: main loop stuck 30 s at: ") + stuckAt + ", restarted");
      stuckMagic = 0;
    }
    usbdev::log(String("PocketLua boot, build ") + (LIVEOS_BUILD + 8) + ", storage=" + store::kind() + ", embedded files=" + (int)EMBEDDED_COUNT +
                ", board=" + (int)M5.getBoard() + (M5.getBoard() == m5::board_t::board_M5CardputerADV ? " (ADV)" : ""));
  }
  bool safe = false;
  for (int i = 0; i < 12; i++) {
    if (safeKeyHeld()) safe = true;
    delay(60);
  }
  store::safeMode = safe;
  vm::reserveArena();  // before Wi-Fi can fragment the heap
  shell::begin(safe);
  logHeap(safe ? "booted (safe)" : "booted");

  uint32_t last = millis(), lastHeapLog = 0;
  xTaskCreatePinnedToCore(watchMain, "watch", 3072, nullptr, 2, nullptr, 0);
  for (;;) {
    uint32_t t0 = millis();
    g_beat++;
    g_crumb = "usb tick";
    usbdev::tick();
    syslog::drain();
    g_crumb = "settings";
    settingsTick();
    g_crumb = "hw tick";
    hwTick();
    if (millis() - lastHeapLog > 30000) {
      lastHeapLog = millis();
      logHeap("periodic");
      usbdev::log(String("wifi: mode=") + (WiFi.getMode() == WIFI_OFF ? "off" : "on") +
                  " connected=" + (WiFi.status() == WL_CONNECTED ? "yes" : "no"));
    }
    g_crumb = "keys";
    pollKeys();
    float dt = (t0 - last) / 1000.0f;
    last = t0;
    g_crumb = "shell update";
    shell::update(dt);
    g_crumb = "draw";
    if (g_screenshotPath.length() && !g_displayAsleep && !g_displayHold) {
      String path = g_screenshotPath;
      g_screenshotPath = "";
      shell::screenshotDone(path, writeScreenshot(path));
    } else if (!g_displayAsleep && !g_displayHold) {
      for (g_bandY = 0; g_bandY < SCREEN_H; g_bandY += g_bandH) {
        shell::drawBand();
        canvas.pushSprite(0, g_bandY);
      }
      g_bandY = 0;
    }
    uint32_t frameMs = g_displayAsleep ? 100 : 33;  // asleep: poll less, save battery
    uint32_t el = millis() - t0;
    if (el < frameMs) delay(frameMs - el);
  }
}

SET_LOOP_TASK_STACK_SIZE(20 * 1024);  // Lua C-call depth is capped (LUAI_MAXCCALLS) to fit

void setup() {
  // No Serial.begin(): UART0 TX is GPIO43, which the ADV uses for the mic's
  // I2S word-select line. Logs go to USB serial and the SD card instead.
  syslog::begin();
  osMain();  // never returns
}

void loop() {}
