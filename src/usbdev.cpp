#include "usbdev.h"
#include <USB.h>
#include <USBHIDKeyboard.h>
#include <USBHIDMouse.h>
#include <USBMSC.h>
#include <USBCDC.h>
#include <SD.h>
#include "storage.h"

namespace usbdev {

static USBHIDKeyboard kbd;
static USBHIDMouse mouse;
static bool msOn = false;
static USBMSC msc;
static USBCDC cdc(0);
static bool kOn = false, mOn = false, cOn = false, shared = false, consoleOn = false;
static String ring;
static TaskHandle_t mainTask = nullptr;
static bool wasConnected = false;

static int32_t onRead(uint32_t lba, uint32_t, void *buf, uint32_t size) {
  if (!shared) return -1;
  for (uint32_t i = 0; i < size / 512; i++)
    if (!SD.readRAW((uint8_t *)buf + i * 512, lba + i)) return -1;
  return size;
}

static int32_t onWrite(uint32_t lba, uint32_t, uint8_t *buf, uint32_t size) {
  if (!shared) return -1;
  for (uint32_t i = 0; i < size / 512; i++)
    if (!SD.writeRAW(buf + i * 512, lba + i)) return -1;
  return size;
}

static bool onStartStop(uint8_t, bool, bool) { return true; }

void begin(bool keyboard, bool drive, bool serial, bool console, bool mouseWanted) {
  mainTask = xTaskGetCurrentTaskHandle();
  // keep the file log small: start a fresh one each boot
  store::write("data/log.txt", "");
  consoleOn = console;
  msOn = mouseWanted;
  kOn = keyboard;
  mOn = drive && store::hasSd();
  cOn = serial;
  if (!kOn && !mOn && !cOn && !msOn) return;

  USB.manufacturerName("LiveOS");
  USB.productName("Cardputer LiveOS");
  if (cOn) {
    cdc.setRxBufferSize(2048);  // fits one push.py line (~1 KB)
    cdc.begin(115200);
  }
  if (kOn) kbd.begin();
  if (msOn) mouse.begin();
  if (mOn) {
    msc.vendorID("LiveOS");
    msc.productID("SD Card");
    msc.productRevision("1.0");
    msc.onRead(onRead);
    msc.onWrite(onWrite);
    msc.onStartStop(onStartStop);
    msc.mediaPresent(false);
    msc.begin(SD.numSectors(), 512);
  }
  USB.begin();
}

bool keyboardOn() { return kOn; }
bool mouseOn() { return msOn; }

static uint8_t buttonBit(const char *b) {
  return !strcmp(b, "right") ? MOUSE_RIGHT : !strcmp(b, "middle") ? MOUSE_MIDDLE : MOUSE_LEFT;
}
void mouseMove(int dx, int dy, int wheel) {
  if (msOn) mouse.move(constrain(dx, -127, 127), constrain(dy, -127, 127), constrain(wheel, -127, 127));
}
void mouseClick(const char *b) {
  if (msOn) mouse.click(buttonBit(b));
}
void mouseButton(const char *b, bool down) {
  if (!msOn) return;
  if (down) mouse.press(buttonBit(b)); else mouse.release(buttonBit(b));
}
bool driveOn() { return mOn; }
bool serialOn() { return cOn; }
bool serialConnected() { return cOn && cdc; }

void typeText(const String &s) {
  if (kOn) kbd.print(s);
}

static uint8_t namedKey(const String &n) {
  static const struct { const char *name; uint8_t code; } table[] = {
      {"enter", KEY_RETURN}, {"tab", KEY_TAB}, {"esc", KEY_ESC}, {"backspace", KEY_BACKSPACE},
      {"delete", KEY_DELETE}, {"up", KEY_UP_ARROW}, {"down", KEY_DOWN_ARROW}, {"left", KEY_LEFT_ARROW},
      {"right", KEY_RIGHT_ARROW}, {"home", KEY_HOME}, {"end", KEY_END}, {"pageup", KEY_PAGE_UP},
      {"pagedown", KEY_PAGE_DOWN}, {"space", ' '}};
  for (auto &e : table)
    if (n == e.name) return e.code;
  if (n.length() >= 2 && n[0] == 'f') {
    int f = n.substring(1).toInt();
    if (f >= 1 && f <= 12) return KEY_F1 + (f - 1);
  }
  return n.length() == 1 ? (uint8_t)n[0] : 0;
}

void key(const String &spec) {
  if (!kOn) return;
  String s = spec;
  s.toLowerCase();
  uint8_t mods[4];
  int nm = 0;
  while (true) {
    int plus = s.indexOf('+');
    if (plus <= 0 || plus == (int)s.length() - 1) break;
    String m = s.substring(0, plus);
    uint8_t code = m == "ctrl" ? KEY_LEFT_CTRL : m == "shift" ? KEY_LEFT_SHIFT : m == "alt" ? KEY_LEFT_ALT
                 : (m == "gui" || m == "win" || m == "cmd") ? KEY_LEFT_GUI : 0;
    if (code && nm < 4) mods[nm++] = code;
    s = s.substring(plus + 1);
  }
  uint8_t k = namedKey(s);
  if (!k) return;
  for (int i = 0; i < nm; i++) kbd.press(mods[i]);
  kbd.press(k);
  delay(12);
  kbd.releaseAll();
}

// Writes everything, waiting briefly for buffer space instead of dropping bytes.
void serialWrite(const String &s) {
  if (!serialConnected()) return;
  const uint8_t *p = (const uint8_t *)s.c_str();
  size_t off = 0, len = s.length();
  uint32_t t0 = millis();
  while (off < len && millis() - t0 < 250) {
    size_t room = cdc.availableForWrite();
    if (!room) { delay(2); continue; }
    size_t n = room < len - off ? room : len - off;
    cdc.write(p + off, n);
    off += n;
  }
}

String serialRead() {
  String out;
  if (!cOn) return out;
  while (cdc.available() && out.length() < 2048) out += (char)cdc.read();
  return out;
}

// The log is also appended to data/log.txt on the card (main task only), so it
// can be read later even if USB was not connected when something failed.
static bool inFileLog = false;
void log(const String &line) {
  Serial.println(line);
  if (!inFileLog && xTaskGetCurrentTaskHandle() == mainTask) {
    inFileLog = true;
    String l = String(millis() / 1000) + "s " + line + "\n";
    store::append("data/log.txt", l.c_str(), l.length());
    inFileLog = false;
  }
  ring += line;
  ring += '\n';
  if (ring.length() > 3000) ring.remove(0, ring.length() - 3000);
  if (!consoleOn && serialConnected()) serialWrite("# " + line + "\n");
}

String logDump() { return ring; }

void tick() {
  static uint32_t connectedAt = 0;
  static bool pending = false;
  bool now = serialConnected();
  if (now && !wasConnected) { pending = true; connectedAt = millis(); }
  // A host can ask for the backlog at any time by sending ENQ (0x05); the
  // connect edge alone is unreliable because other programs may open the port.
  if (now && !consoleOn && cdc.available() && cdc.peek() == 0x05) {
    cdc.read();
    pending = true;
    connectedAt = millis() - 1000;
  }
  if (!now) pending = false;
  wasConnected = now;
  // give the host a moment to start reading before the backlog is sent
  if (pending && millis() - connectedAt > 500 && !consoleOn) {
    pending = false;
    serialWrite("# --- log so far ---\n");
    int start = 0;
    while (start < (int)ring.length()) {  // line by line so the CDC buffer is never overrun
      int nl = ring.indexOf('\n', start);
      if (nl < 0) nl = ring.length();
      serialWrite("# " + ring.substring(start, nl) + "\n");
      start = nl + 1;
      delay(2);
    }
    serialWrite("# --- live ---\n");
  }
}

void share(bool on) {
  if (!mOn || on == shared) return;
  if (on) {
    store::pin(true);  // mounted card needed for raw sector access
    store::lock(true);
    shared = true;
    msc.mediaPresent(true);
  } else {
    msc.mediaPresent(false);
    shared = false;
    delay(100);
    store::remount();
    store::pin(false);
  }
}

bool sharing() { return shared; }

}  // namespace usbdev
