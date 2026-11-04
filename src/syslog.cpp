#include "syslog.h"
#include <Arduino.h>
#include <esp_log.h>
#include <esp_rom_sys.h>
#include "usbdev.h"

namespace syslog {

// Lines are collected here from any task and forwarded by the main loop.
static const int LINES = 8, WIDTH = 120;
static char ring[LINES][WIDTH];
static volatile uint8_t head = 0, tail = 0;
static char cur[WIDTH];
static volatile int curLen = 0;

static void putChar(char c) {
  if (c == '\r') return;
  if (c == '\n' || curLen >= WIDTH - 1) {
    if (curLen == 0) return;
    uint8_t next = (head + 1) % LINES;
    if (next != tail) {
      memcpy(ring[head], cur, curLen);
      ring[head][curLen] = 0;
      head = next;
    }
    curLen = 0;
    if (c == '\n') return;
  }
  cur[curLen++] = c;
}

static int vprintfHook(const char *fmt, va_list ap) {
  char b[160];
  int n = vsnprintf(b, sizeof b, fmt, ap);
  for (int i = 0; b[i]; i++) putChar(b[i]);
  return n;
}

void begin() {
  esp_rom_install_channel_putc(1, putChar);  // ets_printf -> here
  esp_log_set_vprintf(vprintfHook);          // ESP-IDF ESP_LOGx -> here
}

void drain() {
  while (tail != head) {
    usbdev::log(String("sys: ") + ring[tail]);
    tail = (tail + 1) % LINES;
  }
}

}  // namespace syslog
