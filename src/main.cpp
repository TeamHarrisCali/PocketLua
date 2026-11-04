// LiveOS for the Cardputer ADV. The OS itself (desktop, drawer, system UI,
// services) is native code in system.cpp; apps are live-editable Lua that
// runs in a VM created only while the app is open (vm.cpp).
// Runs as a normal app image, so M5Launcher can start it.
#include <M5Cardputer.h>
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
bool g_displayAsleep = false;  // display sleep: nothing is drawn
bool g_displayHold = false;    // an app draws straight to the panel
String g_screenshotPath;       // taken on the next frame

size_t luaMemUsed() { return vm::memUsed(); }

static void logHeap(const char *tag) {
  usbdev::log(String("heap ") + tag + ": free=" + ESP.getFreeHeap() + " largest=" +
              heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) + " lua=" + vm::memUsed() +
              " pool=" + luapool::pageBytes() + " stack_free=" + uxTaskGetStackHighWaterMark(nullptr));
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
    shell::drawBand();
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
  bool safe = false;
  for (int i = 0; i < 12; i++) {
    if (safeKeyHeld()) safe = true;
    delay(60);
  }
  store::safeMode = safe;
  shell::begin(safe);
  logHeap(safe ? "booted (safe)" : "booted");

  uint32_t last = millis(), lastHeapLog = 0;
  for (;;) {
    uint32_t t0 = millis();
    usbdev::tick();
    syslog::drain();
    hwTick();
    if (millis() - lastHeapLog > 30000) {
      lastHeapLog = millis();
      logHeap("periodic");
    }
    pollKeys();
    float dt = (t0 - last) / 1000.0f;
    last = t0;
    shell::update(dt);
    if (g_screenshotPath.length() && !g_displayAsleep && !g_displayHold) {
      String path = g_screenshotPath;
      g_screenshotPath = "";
      shell::screenshotDone(path, writeScreenshot(path));
    } else if (!g_displayAsleep && !g_displayHold) {
      for (g_bandY = 0; g_bandY < SCREEN_H; g_bandY += BAND_H) {
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
  Serial.begin(115200);
  syslog::begin();
  osMain();  // never returns
}

void loop() {}
