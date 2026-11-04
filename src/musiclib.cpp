// Music library index (built on a PC by tools/music_library.py) for the Music
// app. Lists are fixed-size text records under data/music/.library/, so a
// row is read by seeking to row * size: the app only ever holds the rows on
// screen, however big the library is.
#include <Arduino.h>
#include <lua.hpp>
#include "storage.h"

static const char *DIR_ = "data/music/.library/";

static int recSize(const char *kind) {
  return !strcmp(kind, "tracks") ? 512 : !strcmp(kind, "gtracks") ? 8 : 128;
}

// Reads record i of kind into buf and splits it at tabs into f[] (trailing
// padding removed). Returns the number of fields, 0 if there is no such row.
static int readRec(File &file, const char *kind, int i, char *buf, char **f, int maxF) {
  int size = recSize(kind);
  if (i < 0 || !file.seek((size_t)i * size) || file.read((uint8_t *)buf, size) != (size_t)size) return 0;
  buf[size - 1] = 0;
  for (int k = size - 2; k >= 0 && buf[k] == ' '; k--) buf[k] = 0;
  int n = 0;
  f[n++] = buf;
  for (char *p = buf; *p && n < maxF; p++)
    if (*p == '\t') { *p = 0; f[n++] = p + 1; }
  return n;
}

static File openKind(const char *kind) {
  String real;
  fs::FS *fs = store::resolve(String(DIR_) + kind + ".dat", real);
  return fs ? fs->open(real, "r") : File();
}

// info() -> {tracks=, artists=, albums=, genres=}, or nil without a library
static int ml_info(lua_State *L) {
  String real;
  fs::FS *fs = store::resolve(String(DIR_) + "info.txt", real);
  File f = fs ? fs->open(real, "r") : File();
  if (!f) { lua_pushnil(L); return 1; }
  char buf[160];
  int n = f.read((uint8_t *)buf, sizeof buf - 1);
  f.close();
  buf[n > 0 ? n : 0] = 0;
  if (strncmp(buf, "liveos-library 1\n", 17)) { lua_pushnil(L); return 1; }
  lua_newtable(L);
  for (char *line = strtok(buf + 17, "\n"); line; line = strtok(nullptr, "\n")) {
    char *sp = strchr(line, ' ');
    if (!sp) continue;
    *sp = 0;
    lua_pushinteger(L, atoi(sp + 1));
    lua_setfield(L, -2, line);
  }
  return 1;
}

// rows(kind, first, n) -> list rows for ui.list: {label=, value=}. Kinds:
// "artists" and "genres" (value: track count), "albums" (value: artist),
// "tracks" (label: title, value: artist).
static int ml_rows(lua_State *L) {
  const char *kind = luaL_checkstring(L, 1);
  int first = luaL_checkinteger(L, 2), n = luaL_checkinteger(L, 3);
  File file = openKind(kind);
  lua_createtable(L, n > 0 ? n : 0, 0);
  if (!file) return 1;
  char buf[512], *f[8];
  for (int i = 0; i < n; i++) {
    int nf = readRec(file, kind, first + i - 1, buf, f, 8);
    if (!nf) break;
    bool track = !strcmp(kind, "tracks"), album = !strcmp(kind, "albums");
    lua_createtable(L, 0, 2);
    lua_pushstring(L, track ? (nf > 1 ? f[1] : "") : f[0]);
    lua_setfield(L, -2, "label");
    const char *v = track ? (nf > 2 ? f[2] : "") : album ? (nf > 1 ? f[1] : "") : (nf > 2 ? f[2] : "");
    lua_pushstring(L, v);
    lua_setfield(L, -2, "value");
    lua_rawseti(L, -2, i + 1);
  }
  file.close();
  return 1;
}

// item(kind, i) -> for artists/genres: name, first, count; albums: album,
// artist, first, count; tracks: path, title, artist, album, genre, track;
// gtracks: the track row. Rows count from 1.
static int ml_item(lua_State *L) {
  const char *kind = luaL_checkstring(L, 1);
  int i = luaL_checkinteger(L, 2);
  File file = openKind(kind);
  char buf[512], *f[8];
  int nf = file ? readRec(file, kind, i - 1, buf, f, 8) : 0;
  if (file) file.close();
  if (!nf) return 0;
  if (!strcmp(kind, "gtracks")) { lua_pushinteger(L, atoi(f[0]) + 1); return 1; }
  bool track = !strcmp(kind, "tracks");
  for (int k = 0; k < nf; k++) {
    bool numeric = !track && k >= nf - 2;  // first, count
    if (numeric) lua_pushinteger(L, atoi(f[k]) + (k == nf - 2 ? 1 : 0));
    else if (track && k == 0) lua_pushstring(L, (String("data/music/") + f[0]).c_str());
    else lua_pushstring(L, f[k]);
  }
  return nf;
}

// albums_in(first, count) -> the albums in a run of tracks (an artist's), as
// list rows {label=album, value=tracks, first=, count=}.
static int ml_albums_in(lua_State *L) {
  int first = luaL_checkinteger(L, 1), count = luaL_checkinteger(L, 2);
  File file = openKind("tracks");
  lua_newtable(L);
  if (!file) return 1;
  char buf[512], *f[8], last[64] = "";
  int n = 0, start = 0, run = 0;
  auto flush = [&]() {
    if (!run) return;
    lua_createtable(L, 0, 4);
    lua_pushstring(L, last); lua_setfield(L, -2, "label");
    lua_pushstring(L, String(run).c_str()); lua_setfield(L, -2, "value");
    lua_pushinteger(L, start); lua_setfield(L, -2, "first");
    lua_pushinteger(L, run); lua_setfield(L, -2, "count");
    lua_rawseti(L, -2, ++n);
  };
  for (int i = first; i < first + count; i++) {
    int nf = readRec(file, "tracks", i - 1, buf, f, 8);
    if (nf < 4) break;
    if (strcmp(f[3], last)) {
      flush();
      strlcpy(last, f[3], sizeof last);
      start = i, run = 0;
    }
    run++;
  }
  flush();
  file.close();
  return 1;
}

extern const luaL_Reg musiclibFns[] = {{"info", ml_info}, {"rows", ml_rows}, {"item", ml_item},
                                       {"albums_in", ml_albums_in}, {nullptr, nullptr}};
