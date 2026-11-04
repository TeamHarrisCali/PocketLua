#include "uikit.h"
#include <M5Cardputer.h>
#include "icons.gen.h"

extern M5Canvas canvas;
extern int g_bandY;
extern int g_bandH;

namespace ui {

Colors col;
String themeName = "slate", accentName = "blue";
Status status;

struct ThemeDef {
  const char *name;
  uint8_t c[6][3];  // bg, surface, surface2, line, text, muted
};
static const ThemeDef THEME_DEFS[] = {
    {"slate", {{12, 14, 20}, {24, 28, 38}, {38, 44, 60}, {54, 62, 82}, {232, 236, 244}, {130, 138, 156}}},
    {"midnight", {{0, 0, 0}, {14, 16, 24}, {30, 34, 48}, {44, 50, 66}, {220, 226, 240}, {110, 118, 140}}},
    {"paper", {{236, 234, 226}, {250, 249, 244}, {214, 212, 204}, {190, 188, 180}, {30, 32, 38}, {100, 102, 110}}},
    {"terminal", {{0, 8, 2}, {6, 22, 10}, {12, 40, 18}, {20, 70, 30}, {160, 255, 170}, {70, 150, 90}}},
    {"sunset", {{24, 12, 20}, {40, 22, 32}, {60, 32, 46}, {84, 46, 62}, {255, 232, 220}, {186, 140, 140}}},
};
const char *const THEMES[] = {"slate", "midnight", "paper", "terminal", "sunset"};
const int THEME_COUNT = 5;

struct AccentDef { const char *name; uint8_t r, g, b; };
static const AccentDef ACCENT_DEFS[] = {{"blue", 64, 140, 255}, {"teal", 40, 200, 180}, {"green", 80, 200, 100},
                                        {"orange", 255, 150, 50}, {"purple", 170, 110, 255}, {"pink", 255, 100, 160},
                                        {"red", 240, 80, 80}};
const char *const ACCENTS[] = {"blue", "teal", "green", "orange", "purple", "pink", "red"};
const int ACCENT_COUNT = 7;

uint16_t rgb(int r, int g, int b) { return canvas.color565(r, g, b); }

static const ThemeDef &themeDef() {
  for (auto &t : THEME_DEFS)
    if (themeName == t.name) return t;
  return THEME_DEFS[0];
}

uint16_t accent(const char *name) {
  for (auto &a : ACCENT_DEFS)
    if (!strcmp(a.name, name)) return rgb(a.r, a.g, a.b);
  return rgb(64, 140, 255);
}

static void apply() {
  const ThemeDef &t = themeDef();
  uint16_t *dst[] = {&col.bg, &col.surface, &col.surface2, &col.line, &col.text, &col.muted};
  for (int i = 0; i < 6; i++) *dst[i] = rgb(t.c[i][0], t.c[i][1], t.c[i][2]);
  col.accent = accent(accentName.c_str());
  col.on_accent = themeName == "paper" ? rgb(255, 255, 255) : col.bg;
  col.good = rgb(90, 210, 120);
  col.warn = rgb(255, 190, 60);
  col.bad = rgb(240, 90, 90);
  col.white = rgb(255, 255, 255);
}

void setTheme(const char *name) {
  themeName = "slate";
  for (auto &t : THEME_DEFS)
    if (!strcmp(t.name, name)) themeName = name;
  apply();
}

void setAccent(const char *name) {
  accentName = "blue";
  for (auto &a : ACCENT_DEFS)
    if (!strcmp(a.name, name)) accentName = name;
  apply();
}

// ---------------------------------------------------------------- primitives
bool visible(int y, int h) { return y + h > g_bandY && y < g_bandY + g_bandH; }

void fill(int x, int y, int w, int h, uint16_t c) { canvas.fillRect(x, y - g_bandY, w, h, c); }
void rect(int x, int y, int w, int h, uint16_t c) { canvas.drawRect(x, y - g_bandY, w, h, c); }
void rfill(int x, int y, int w, int h, int r, uint16_t c) { canvas.fillRoundRect(x, y - g_bandY, w, h, r, c); }
void rrect(int x, int y, int w, int h, int r, uint16_t c) { canvas.drawRoundRect(x, y - g_bandY, w, h, r, c); }
void line(int x0, int y0, int x1, int y1, uint16_t c) { canvas.drawLine(x0, y0 - g_bandY, x1, y1 - g_bandY, c); }
void disc(int x, int y, int r, uint16_t c) { canvas.fillCircle(x, y - g_bandY, r, c); }
void circle(int x, int y, int r, uint16_t c) { canvas.drawCircle(x, y - g_bandY, r, c); }

void text(int x, int y, const char *s, uint16_t c, int size) {
  if (!visible(y, 8 * size)) return;
  canvas.setTextSize(size);
  canvas.setTextColor(c);
  canvas.drawString(s, x, y - g_bandY);
}
void center(int y, const char *s, uint16_t c, int size) { text((240 - (int)strlen(s) * 6 * size) / 2, y, s, c, size); }
void right(int x, int y, const char *s, uint16_t c, int size) { text(x - (int)strlen(s) * 6 * size, y, s, c, size); }

String fit(const String &s, int maxw, int size) {
  int n = maxw / (6 * size);
  if ((int)s.length() <= n) return s;
  return s.substring(0, n > 2 ? n - 2 : 0) + "..";
}

std::vector<String> wrap(const String &s, int maxw, int size) {
  std::vector<String> out;
  int cols = maxw / (6 * size);
  if (cols < 1) cols = 1;
  int start = 0;
  while (start <= (int)s.length()) {
    int nl = s.indexOf('\n', start);
    String para = s.substring(start, nl < 0 ? s.length() : nl);
    String line;
    int i = 0;
    while (i < (int)para.length()) {
      while (i < (int)para.length() && para[i] == ' ') i++;
      int j = i;
      while (j < (int)para.length() && para[j] != ' ') j++;
      String word = para.substring(i, j);
      i = j;
      if (!word.length()) break;
      while ((int)word.length() > cols) {
        if (line.length()) { out.push_back(line); line = ""; }
        out.push_back(word.substring(0, cols));
        word = word.substring(cols);
      }
      if (!line.length()) line = word;
      else if ((int)(line.length() + 1 + word.length()) <= cols) line += " " + word;
      else { out.push_back(line); line = word; }
    }
    out.push_back(line);
    if (nl < 0) break;
    start = nl + 1;
  }
  return out;
}

// ---------------------------------------------------------------- components
void footer(const Hint *h, int n) {
  if (!visible(124, 11)) return;
  fill(0, 124, 240, 11, col.bg);
  int x = 3;
  for (int i = 0; i < n; i++) {
    int kw = strlen(h[i].key) * 6 + 4, lw = strlen(h[i].label) * 6;
    if (x + kw + lw + 4 > 240) break;
    rfill(x, 125, kw, 10, 2, col.surface2);
    text(x + 2, 126, h[i].key, col.text);
    text(x + kw + 3, 126, h[i].label, col.muted);
    x += kw + lw + 10;
  }
}

void statusbar(const char *title) {
  if (!visible(0, 14)) return;
  fill(0, 0, 240, 14, col.surface);
  int bx = 216, pct = status.pct;
  uint16_t bc = status.charging ? col.good : (pct <= 15 ? col.bad : col.text);
  rrect(bx, 3, 19, 8, 2, bc);
  fill(bx + 19, 5, 2, 4, bc);
  fill(bx + 2, 5, 15 * pct / 100, 4, bc);
  if (status.charging) canvas.fillTriangle(bx + 10, 2 - g_bandY, bx + 6, 8 - g_bandY, bx + 11, 8 - g_bandY, col.warn);
  char pt[6];
  snprintf(pt, sizeof pt, "%d%%", pct);
  int px = bx - 3 - strlen(pt) * 6;
  text(px, 3, pt, col.muted);
  const char *tt = status.time.length() ? status.time.c_str() : "--:--";
  int tx = px - 7 - strlen(tt) * 6;
  text(tx, 3, tt, col.text);
  int left = tx - 4;
  if (status.wifiOn) {
    int wx = tx - 17;
    for (int i = 1; i <= 4; i++) fill(wx + (i - 1) * 3, 11 - i * 2, 2, i * 2, i <= status.wifi ? col.text : col.surface2);
    left = wx - 4;
  }
  if (status.unread > 0) {
    disc(left - 3, 7, 3, col.accent);
    left -= 10;
  }
  disc(6, 7, 2, col.accent);
  text(12, 3, fit(title, left - 12).c_str(), col.text);
}

void badge(int x, int y, int size, char letter, uint16_t c) {
  rfill(x, y, size, size, 3, c);
  char s[2] = {letter, 0};
  text(x + (size - 6) / 2, y + (size - 8) / 2, s, col.white);
}

void toggle(int x, int y, bool on) {
  rfill(x, y, 22, 10, 5, on ? col.accent : col.surface2);
  disc(on ? x + 17 : x + 5, y + 5, 3, on ? col.on_accent : col.muted);
}

static int listTop(int sel, int top, int n) {
  if (sel < top) top = sel;
  else if (sel > top + n - 1) top = sel - n + 1;
  return top < 1 ? 1 : top;
}

// Draws rows top..top+n-1 of `total`; row(i) gives row i (1-based), so only
// the visible rows need to exist.
template <class F>
static int listDraw(F row, int total, int sel, int top, int x, int y, int w, int rowh, int n) {
  top = listTop(sel, top, n);
  for (int i = 0; i < n; i++) {
    int idx = top + i;
    if (idx > total) break;
    const Row &r = row(idx);
    int ry = y + i * rowh;
    if (!visible(ry, rowh)) continue;
    bool on = idx == sel;
    if (on) {
      rfill(x, ry, w, rowh - 1, 4, col.surface2);
      rfill(x, ry + 2, 3, rowh - 5, 1, col.accent);
    }
    int tx = x + 7;
    if (r.badge) {
      badge(x + 6, ry + (rowh - 13) / 2, 13, r.badge, r.badgeColor ? r.badgeColor : col.surface2);
      tx = x + 24;
    }
    int ty = ry + (rowh - 9) / 2, rw = 0;
    if (r.sw >= 0) {
      toggle(x + w - 28, ry + (rowh - 11) / 2, r.sw == 1);
      rw = 30;
    } else if (r.value.length()) {
      String v = fit(r.value, w * 45 / 100);
      text(x + w - 6 - v.length() * 6, ty, v.c_str(), on ? col.accent : col.muted);
      rw = v.length() * 6 + 10;
    }
    text(tx, ty, fit(r.label, w - (tx - x) - rw - 2).c_str(), r.dim ? col.muted : col.text);
  }
  if (total > n) {
    int bh = max(6, n * rowh * n / total);
    int by = y + (n * rowh - bh) * (top - 1) / max(1, total - n);
    fill(x + w + 1, by, 2, bh, col.line);
  }
  return top;
}

int list(const std::vector<Row> &rows, int sel, int top, int x, int y, int w, int rowh, int n) {
  return listDraw([&](int i) -> const Row & { return rows[i - 1]; }, rows.size(), sel, top, x, y, w, rowh, n);
}

int tabs(const char *const *labels, int n, int active, int y) {
  int w = (240 - 8) / n;
  if (visible(y, 13)) {
    rfill(4, y, w * n, 13, 4, col.surface);
    for (int i = 0; i < n; i++) {
      int x = 4 + i * w;
      if (i + 1 == active) rfill(x + 1, y + 1, w - 2, 11, 3, col.accent);
      String s = fit(labels[i], w - 4);
      text(x + (w - s.length() * 6) / 2, y + 3, s.c_str(), i + 1 == active ? col.on_accent : col.muted);
    }
  }
  return y + 16;
}

void card(int x, int y, int w, int h, bool selected) {
  if (!visible(y, h)) return;
  rfill(x, y, w, h, 5, selected ? col.surface2 : col.surface);
  if (selected) rrect(x, y, w, h, 5, col.accent);
}

void box(int x, int y, int w, int h) {
  rfill(x, y, w, h, 6, col.surface);
  rrect(x, y, w, h, 6, col.accent);
}

void bar(int x, int y, int w, int h, float frac, uint16_t c) {
  if (frac < 0) frac = 0;
  if (frac > 1) frac = 1;
  rfill(x, y, w, h, h / 2, col.surface2);
  if (frac > 0) rfill(x, y, max(h, (int)(w * frac)), h, h / 2, c);
}

int button(int x, int y, const char *label, bool focused) {
  int w = strlen(label) * 6 + 12;
  rfill(x, y, w, 14, 4, focused ? col.accent : col.surface2);
  text(x + 6, y + 3, label, focused ? col.on_accent : col.text);
  return w;
}

void icon(const char *name, int x, int y, uint16_t fg, uint16_t bg) {
  const IconDef *def = nullptr, *fallback = nullptr;
  for (int i = 0; i < ICON_COUNT; i++) {
    if (!strcmp(ICONS[i].name, name)) def = &ICONS[i];
    if (!strcmp(ICONS[i].name, "app")) fallback = &ICONS[i];
  }
  if (!def) def = fallback;
  if (!def) return;
  int oy = y - g_bandY;
  for (int i = 0; i < def->count; i++) {
    const IconOp &o = def->ops[i];
    uint16_t c = o.bg ? bg : fg;
    const int16_t *a = o.a;
    switch (o.code) {
      case 'L': canvas.drawLine(x + a[0], oy + a[1], x + a[2], oy + a[3], c); break;
      case 'F': canvas.fillRect(x + a[0], oy + a[1], a[2], a[3], c); break;
      case 'R': canvas.drawRect(x + a[0], oy + a[1], a[2], a[3], c); break;
      case 'r': canvas.drawRoundRect(x + a[0], oy + a[1], a[2], a[3], a[4], c); break;
      case 'Q': canvas.fillRoundRect(x + a[0], oy + a[1], a[2], a[3], a[4], c); break;
      case 'C': canvas.drawCircle(x + a[0], oy + a[1], a[2], c); break;
      case 'D': canvas.fillCircle(x + a[0], oy + a[1], a[2], c); break;
      case 'T': canvas.fillTriangle(x + a[0], oy + a[1], x + a[2], oy + a[3], x + a[4], oy + a[5], c); break;
      case 'A': canvas.fillArc(x + a[0], oy + a[1], a[2], a[3], a[4], a[5], c); break;
    }
  }
}

void tile(int x, int y, int size, const char *name, uint16_t c) {
  if (!visible(y, size)) return;
  rfill(x, y, size, size, size / 4, c);
  icon(name, x + size / 2, y + size / 2, col.white, c);
}

void empty(const char *ic, const char *l1, const char *l2) {
  icon(ic ? ic : "warn", 120, 50, col.muted, col.bg);
  if (l1) center(68, l1, col.text);
  if (l2) center(80, l2, col.muted);
}

// ================================================================ Lua `ui`
static int I(lua_State *L, int i) { return (int)floorf((float)luaL_checknumber(L, i)); }
static int OI(lua_State *L, int i, int d) { return lua_isnoneornil(L, i) ? d : I(L, i); }
static uint16_t C(lua_State *L, int i, uint16_t d) { return lua_isnoneornil(L, i) ? d : (uint16_t)luaL_checkinteger(L, i); }

static void pushColors(lua_State *L) {
  lua_getglobal(L, "ui");
  if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
  lua_getfield(L, -1, "col");
  if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_newtable(L); lua_pushvalue(L, -1); lua_setfield(L, -3, "col"); }
  const struct { const char *k; uint16_t v; } kv[] = {
      {"bg", col.bg}, {"surface", col.surface}, {"surface2", col.surface2}, {"line", col.line},
      {"text", col.text}, {"muted", col.muted}, {"accent", col.accent}, {"on_accent", col.on_accent},
      {"good", col.good}, {"warn", col.warn}, {"bad", col.bad}, {"white", col.white},
      {"panel", col.surface}, {"panel2", col.surface2}, {"dim", col.muted}, {"bar", col.surface}};
  for (auto &e : kv) { lua_pushinteger(L, e.v); lua_setfield(L, -2, e.k); }
  lua_pop(L, 1);
  lua_pushstring(L, themeName.c_str()); lua_setfield(L, -2, "theme");
  lua_pushstring(L, accentName.c_str()); lua_setfield(L, -2, "accent");
  lua_pop(L, 1);
}

static int l_text(lua_State *L) { text(I(L, 1), I(L, 2), luaL_checkstring(L, 3), C(L, 4, col.text), OI(L, 5, 1)); return 0; }
static int l_center(lua_State *L) { center(I(L, 1), luaL_checkstring(L, 2), C(L, 3, col.text), OI(L, 4, 1)); return 0; }
static int l_right(lua_State *L) { right(I(L, 1), I(L, 2), luaL_checkstring(L, 3), C(L, 4, col.text), OI(L, 5, 1)); return 0; }
static int l_big(lua_State *L) { center(I(L, 1), luaL_checkstring(L, 2), C(L, 3, col.text), OI(L, 4, 3)); return 0; }
static int l_title(lua_State *L) { text(I(L, 1), I(L, 2), luaL_checkstring(L, 3), col.muted); return 0; }
static int l_fit(lua_State *L) {
  String s = fit(luaL_checkstring(L, 1), I(L, 2), OI(L, 3, 1));
  lua_pushstring(L, s.c_str());
  return 1;
}
static int l_wrap(lua_State *L) {
  // the width and size first: luaL_tolstring pushes its result, which would
  // otherwise be read as argument 3
  int w = I(L, 2), size = OI(L, 3, 1);
  auto lines = wrap(luaL_tolstring(L, 1, nullptr), w, size);
  lua_pop(L, 1);
  lua_createtable(L, lines.size(), 0);
  for (size_t i = 0; i < lines.size(); i++) { lua_pushstring(L, lines[i].c_str()); lua_rawseti(L, -2, i + 1); }
  return 1;
}
static int l_visible(lua_State *L) { lua_pushboolean(L, visible(I(L, 1), I(L, 2))); return 1; }

static int l_footer(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  Hint h[6];
  String keep[12];
  int n = 0;
  for (int i = 1; i <= 6; i++) {
    lua_rawgeti(L, 1, i);
    if (!lua_istable(L, -1)) { lua_pop(L, 1); break; }
    lua_rawgeti(L, -1, 1); keep[n * 2] = luaL_optstring(L, -1, ""); lua_pop(L, 1);
    lua_rawgeti(L, -1, 2); keep[n * 2 + 1] = luaL_optstring(L, -1, ""); lua_pop(L, 1);
    lua_pop(L, 1);
    n++;
  }
  for (int i = 0; i < n; i++) h[i] = {keep[i * 2].c_str(), keep[i * 2 + 1].c_str()};
  footer(h, n);
  return 0;
}
static int l_hint(lua_State *L) {
  if (!visible(124, 11)) return 0;
  fill(0, 124, 240, 11, col.bg);
  text(4, 126, luaL_checkstring(L, 1), col.muted);
  return 0;
}

static const char *NAVKEYS[] = {"up", "down", "left", "right"};
static int l_nav(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "key");
  const char *k = lua_tostring(L, -1);
  for (auto n : NAVKEYS)
    if (k && !strcmp(k, n)) { lua_pushstring(L, n); return 1; }
  lua_getfield(L, 1, "text");
  lua_getfield(L, 1, "ctrl");
  lua_getfield(L, 1, "fn");
  const char *t = lua_tostring(L, -3);
  if (t && !lua_toboolean(L, -2) && !lua_toboolean(L, -1) && t[0] && !t[1]) {
    const char *d = t[0] == ';' ? "up" : t[0] == '.' ? "down" : t[0] == ',' ? "left" : t[0] == '/' ? "right" : nullptr;
    if (d) { lua_pushstring(L, d); return 1; }
  }
  lua_pushnil(L);
  return 1;
}

// Rows are tables ({label, value, badge, badge_color, dim, switch}) or plain
// strings. Only the visible rows are copied out of Lua, so long lists (a music
// library) cost nothing extra per frame.
static int l_list(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int total = lua_rawlen(L, 1), sel = I(L, 2), n = I(L, 8);
  if (n < 1 || n > 16) n = n < 1 ? 1 : 16;
  int top = listTop(sel, I(L, 3), n);
  Row win[16];
  for (int i = 0; i < n && top + i <= total; i++) {
    Row &r = win[i];
    lua_rawgeti(L, 1, top + i);
    if (lua_type(L, -1) == LUA_TSTRING) {
      r.label = lua_tostring(L, -1);
    } else if (lua_istable(L, -1)) {
      lua_getfield(L, -1, "label"); r.label = lua_isnil(L, -1) ? "" : luaL_tolstring(L, -1, nullptr); lua_pop(L, lua_isnil(L, -1) ? 1 : 2);
      lua_getfield(L, -1, "value");
      if (!lua_isnil(L, -1)) { r.value = luaL_tolstring(L, -1, nullptr); lua_pop(L, 1); }
      lua_pop(L, 1);
      lua_getfield(L, -1, "badge"); if (lua_isstring(L, -1)) r.badge = lua_tostring(L, -1)[0]; lua_pop(L, 1);
      lua_getfield(L, -1, "badge_color"); if (lua_isinteger(L, -1)) r.badgeColor = lua_tointeger(L, -1); lua_pop(L, 1);
      lua_getfield(L, -1, "dim"); r.dim = lua_toboolean(L, -1); lua_pop(L, 1);
      lua_getfield(L, -1, "switch"); if (!lua_isnil(L, -1)) r.sw = lua_toboolean(L, -1) ? 1 : 0; lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
  lua_pushinteger(L, listDraw([&](int i) -> const Row & { return win[i - top]; }, total, sel, top, I(L, 4), I(L, 5),
                              I(L, 6), I(L, 7), n));
  return 1;
}

static int l_tabs(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int n = min((int)lua_rawlen(L, 1), 8);
  String keep[8];
  const char *labels[8];
  for (int i = 0; i < n; i++) {
    lua_rawgeti(L, 1, i + 1);
    keep[i] = luaL_optstring(L, -1, "");
    lua_pop(L, 1);
    labels[i] = keep[i].c_str();
  }
  lua_pushinteger(L, tabs(labels, n, I(L, 2), OI(L, 3, 16)));
  return 1;
}

static int l_card(lua_State *L) { card(I(L, 1), I(L, 2), I(L, 3), I(L, 4), lua_toboolean(L, 5)); return 0; }
static int l_box(lua_State *L) { box(I(L, 1), I(L, 2), I(L, 3), I(L, 4)); return 0; }
static int l_badge(lua_State *L) { badge(I(L, 1), I(L, 2), I(L, 3), luaL_checkstring(L, 4)[0], C(L, 5, col.surface2)); return 0; }
static int l_switch(lua_State *L) { toggle(I(L, 1), I(L, 2), lua_toboolean(L, 3)); return 0; }
static int l_bar(lua_State *L) { bar(I(L, 1), I(L, 2), I(L, 3), I(L, 4), (float)luaL_checknumber(L, 5), C(L, 6, col.accent)); return 0; }
static int l_button(lua_State *L) { lua_pushinteger(L, button(I(L, 1), I(L, 2), luaL_checkstring(L, 3), lua_toboolean(L, 4))); return 1; }
static int l_icon(lua_State *L) { icon(luaL_checkstring(L, 1), I(L, 2), I(L, 3), C(L, 4, col.white), C(L, 5, col.bg)); return 0; }
static int l_tile(lua_State *L) { tile(I(L, 1), I(L, 2), I(L, 3), luaL_checkstring(L, 4), C(L, 5, col.accent)); return 0; }
static int l_empty(lua_State *L) { empty(luaL_optstring(L, 1, "warn"), luaL_optstring(L, 2, nullptr), luaL_optstring(L, 3, nullptr)); return 0; }
static int l_set_theme(lua_State *L) { setTheme(luaL_checkstring(L, 1)); pushColors(L); return 0; }
static int l_set_accent(lua_State *L) { setAccent(luaL_checkstring(L, 1)); pushColors(L); return 0; }

void registerLua(lua_State *L) {
  static const luaL_Reg fns[] = {
      {"text", l_text}, {"center", l_center}, {"right", l_right}, {"big", l_big}, {"title", l_title},
      {"fit", l_fit}, {"wrap", l_wrap}, {"visible", l_visible}, {"footer", l_footer}, {"hint", l_hint},
      {"nav", l_nav}, {"list", l_list}, {"tabs", l_tabs}, {"card", l_card}, {"box", l_box},
      {"badge", l_badge}, {"switch", l_switch}, {"bar", l_bar}, {"button", l_button}, {"icon", l_icon},
      {"tile", l_tile}, {"empty", l_empty}, {"set_theme", l_set_theme}, {"set_accent", l_set_accent},
      {nullptr, nullptr}};
  luaL_newlib(L, fns);
  const struct { const char *k; int v; } dims[] = {{"W", 240}, {"H", 135}, {"BAR", 14}, {"TOP", 16}, {"BOTTOM", 124}};
  for (auto &d : dims) { lua_pushinteger(L, d.v); lua_setfield(L, -2, d.k); }
  lua_createtable(L, 0, ACCENT_COUNT);
  for (auto &a : ACCENT_DEFS) { lua_pushinteger(L, rgb(a.r, a.g, a.b)); lua_setfield(L, -2, a.name); }
  lua_setfield(L, -2, "accents");
  lua_createtable(L, ACCENT_COUNT, 0);
  for (int i = 0; i < ACCENT_COUNT; i++) { lua_pushstring(L, ACCENTS[i]); lua_rawseti(L, -2, i + 1); }
  lua_setfield(L, -2, "accent_names");
  lua_createtable(L, THEME_COUNT, 0);
  for (int i = 0; i < THEME_COUNT; i++) { lua_pushstring(L, THEMES[i]); lua_rawseti(L, -2, i + 1); }
  lua_setfield(L, -2, "theme_names");
  // raw theme colours, for apps that blend their own (2048)
  static const char *keys[] = {"bg", "surface", "surface2", "line", "text", "muted"};
  lua_createtable(L, 0, THEME_COUNT);
  for (auto &t : THEME_DEFS) {
    lua_createtable(L, 0, 6);
    for (int i = 0; i < 6; i++) {
      lua_createtable(L, 3, 0);
      for (int k = 0; k < 3; k++) { lua_pushinteger(L, t.c[i][k]); lua_rawseti(L, -2, k + 1); }
      lua_setfield(L, -2, keys[i]);
    }
    lua_setfield(L, -2, t.name);
  }
  lua_setfield(L, -2, "themes");
  lua_newtable(L);
  lua_setfield(L, -2, "col");
  lua_setglobal(L, "ui");
  pushColors(L);
}

}  // namespace ui
