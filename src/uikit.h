#pragma once
#include <Arduino.h>
#include <lua.hpp>
#include <vector>

// The LiveOS look, in native code (flash, no RAM). The system draws with it
// directly, and apps reach the same components through the Lua `ui` table.
// Screen 240x135: status bar y 0-13, content y 16-122, footer y 124-134.
// All coordinates are screen coordinates; drawing is clipped to the band
// being rendered (see g_bandY in main.cpp).
namespace ui {

struct Colors {
  uint16_t bg, surface, surface2, line, text, muted, accent, on_accent, good, warn, bad, white;
};
extern Colors col;
extern String themeName, accentName;

void setTheme(const char *name);
void setAccent(const char *name);
uint16_t accent(const char *name);  // accent colour by name (blue if unknown)
extern const char *const THEMES[];
extern const int THEME_COUNT;
extern const char *const ACCENTS[];
extern const int ACCENT_COUNT;

bool visible(int y, int h);
uint16_t rgb(int r, int g, int b);

// primitives
void fill(int x, int y, int w, int h, uint16_t c);
void rect(int x, int y, int w, int h, uint16_t c);
void rfill(int x, int y, int w, int h, int r, uint16_t c);
void rrect(int x, int y, int w, int h, int r, uint16_t c);
void line(int x0, int y0, int x1, int y1, uint16_t c);
void disc(int x, int y, int r, uint16_t c);
void circle(int x, int y, int r, uint16_t c);
void text(int x, int y, const char *s, uint16_t c, int size = 1);
void center(int y, const char *s, uint16_t c, int size = 1);
void right(int x, int y, const char *s, uint16_t c, int size = 1);
String fit(const String &s, int maxw, int size = 1);
std::vector<String> wrap(const String &s, int maxw, int size = 1);

// components
struct Hint { const char *key, *label; };
void footer(const Hint *h, int n);
void statusbar(const char *title);
struct Row {
  String label, value;
  char badge = 0;
  uint16_t badgeColor = 0;
  bool dim = false;
  int sw = -1;  // -1 none, 0 off, 1 on
};
int list(const std::vector<Row> &rows, int sel, int top, int x, int y, int w, int rowh, int n);
int tabs(const char *const *labels, int n, int active, int y);
void card(int x, int y, int w, int h, bool selected);
void box(int x, int y, int w, int h);
void badge(int x, int y, int size, char letter, uint16_t c);
void toggle(int x, int y, bool on);
void bar(int x, int y, int w, int h, float frac, uint16_t c);
int button(int x, int y, const char *label, bool focused);
void icon(const char *name, int x, int y, uint16_t fg, uint16_t bg);
void tile(int x, int y, int size, const char *icon, uint16_t c);
void empty(const char *icon, const char *l1, const char *l2);

// Filled in by the system once a second; the status bar shows it.
struct Status {
  int pct = 0;
  bool charging = false;
  int wifi = 0;
  bool wifiOn = false;
  String time;
  int unread = 0;
};
extern Status status;

void registerLua(lua_State *L);

}  // namespace ui
