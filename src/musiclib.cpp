// Music library index (built on a PC by tools/music_library.py) for the Music
// app. Lists are fixed-size text records under data/music/.library/, so a
// row is read by seeking to row * size: the app only ever holds the rows on
// screen, however big the library is.
#include <Arduino.h>
#include <lua.hpp>
#include <SD.h>
#include <dirent.h>
#include <algorithm>
#include <functional>
#include "musiclib.h"
#include "storage.h"
#include "usbdev.h"

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

// ---------------------------------------------------------------- tags
// Text to plain ASCII: Latin-1 letters folded (e -> e), typographic quotes
// and dashes simplified, anything else '?'.
void putAscii(String &out, uint32_t c) {
  static const char fold[] = "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYPsaaaaaaaceeeeiiiidnooooo/ouuuuypy";
  if (!c) return;
  if (c < 0x80) out += c == '\t' || c < 0x20 ? ' ' : (char)c;
  else if (c >= 0xC0 && c <= 0xFF) out += fold[c - 0xC0];
  else if (c == 0x2018 || c == 0x2019) out += '\'';
  else if (c == 0x201C || c == 0x201D) out += '"';
  else if (c == 0x2013 || c == 0x2014) out += '-';
  else if (c == 0x2026) out += "...";
  else out += '?';
}

void utf8Ascii(String &out, const uint8_t *p, size_t n) {
  for (size_t i = 0; i < n && p[i];) {
    uint32_t c = p[i];
    int more = c < 0x80 ? 0 : c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : -1;
    i++;
    if (more < 0) continue;
    c &= more ? (0x3F >> more) : 0x7F;
    for (int k = 0; k < more && i < n; k++, i++) c = c << 6 | (p[i] & 0x3F);
    putAscii(out, c);
  }
}

// An ID3v2 text frame body (encoding byte first) as ASCII.
static String id3Text(const uint8_t *p, size_t n) {
  String out;
  if (!n) return out;
  uint8_t enc = *p++;
  n--;
  if (enc == 1 || enc == 2) {  // UTF-16 (with a byte order mark) or UTF-16BE
    bool be = enc == 2;
    size_t i = 0;
    if (enc == 1 && n >= 2 && ((p[0] == 0xFF && p[1] == 0xFE) || (p[0] == 0xFE && p[1] == 0xFF))) { be = p[0] == 0xFE; i = 2; }
    for (; i + 1 < n; i += 2) {
      uint32_t c = be ? (p[i] << 8 | p[i + 1]) : (p[i + 1] << 8 | p[i]);
      if (!c) break;
      if (c >= 0xD800 && c < 0xE000) { if (c < 0xDC00) putAscii(out, '?'); continue; }
      putAscii(out, c);
    }
  } else if (enc == 3) {
    utf8Ascii(out, p, n);
  } else {  // ISO-8859-1
    for (size_t i = 0; i < n && p[i]; i++) putAscii(out, p[i]);
  }
  out.trim();
  return out;
}

static const char *const GENRES[] = {
    "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
    "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
    "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
    "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
    "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
    "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
    "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
    "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"};

// "(17)", "17" or "(17)Rock" (ID3v1 genre numbers) to a name.
static String genreName(const String &g) {
  String s = g;
  if (s.startsWith("(")) {
    int close = s.indexOf(')');
    if (close > 0 && close + 1 < (int)s.length()) return s.substring(close + 1);
    s = s.substring(1, close > 0 ? close : s.length());
  }
  bool digits = s.length() > 0;
  for (char c : s) digits = digits && isdigit((unsigned char)c);
  if (!digits) return g;
  int n = s.toInt();
  return n < (int)(sizeof GENRES / sizeof *GENRES) ? GENRES[n] : "";
}

bool readTags(const String &path, Tags &t) {
  String real;
  fs::FS *fs = store::resolve(path, real);
  File f = fs ? fs->open(real, "r") : File();
  if (!f) return false;
  int found = 0;
  uint8_t h[10], buf[160];
  auto syncsafe = [](const uint8_t *b) { return (uint32_t)(b[0] & 0x7F) << 21 | (b[1] & 0x7F) << 14 | (b[2] & 0x7F) << 7 | (b[3] & 0x7F); };
  if (f.read(h, 10) == 10 && !memcmp(h, "ID3", 3) && h[3] >= 2 && h[3] <= 4) {
    int ver = h[3], hdr = ver == 2 ? 6 : 10;
    size_t end = 10 + syncsafe(h + 6), pos = 10;
    if ((h[5] & 0x40) && ver >= 3 && f.read(buf, 4) == 4)  // extended header
      pos = ver == 4 ? 10 + syncsafe(buf) : 14 + ((uint32_t)buf[0] << 24 | buf[1] << 16 | buf[2] << 8 | buf[3]);
    while (pos + hdr <= end && found < 7) {
      f.seek(pos);
      if (f.read(buf, hdr) != (size_t)hdr || !buf[0]) break;  // padding
      uint32_t size = ver == 2 ? (buf[3] << 16 | buf[4] << 8 | buf[5])
                    : ver == 4 ? syncsafe(buf + 4) : ((uint32_t)buf[4] << 24 | buf[5] << 16 | buf[6] << 8 | buf[7]);
      char id[5] = {0};
      memcpy(id, buf, ver == 2 ? 3 : 4);
      auto is = [&](const char *v3, const char *v2) { return !strcmp(id, v3) || !strcmp(id, v2); };
      String *field = is("TIT2", "TT2") ? &t.title : is("TPE1", "TP1") ? &t.artist : is("TALB", "TAL") ? &t.album
                    : is("TRCK", "TRK") ? &t.track : is("TPE2", "TP2") ? &t.albumArtist : is("TCON", "TCO") ? &t.genre
                    : is("TPOS", "TPA") ? &t.disc : nullptr;
      if (field && size > 1) {
        size_t n = size < sizeof buf ? size : sizeof buf;
        if (f.read(buf, n) == n && (*field = id3Text(buf, n)).length()) found++;
      }
      pos += hdr + size;
    }
    if (t.genre.length()) t.genre = genreName(t.genre);
  }
  if (!found && f.size() > 128 && f.seek(f.size() - 128) && f.read(buf, 128) == 128 && !memcmp(buf, "TAG", 3)) {
    auto field = [&](int at, int len) {  // ID3v1: fixed-width Latin-1 fields
      uint8_t tmp[32] = {0};
      memcpy(tmp + 1, buf + at, len);
      return id3Text(tmp, len + 1);
    };
    t.title = field(3, 30);
    t.artist = field(33, 30);
    t.album = field(63, 30);
    if (!buf[125] && buf[126]) t.track = String(buf[126]);
    if (buf[127] < sizeof GENRES / sizeof *GENRES) t.genre = GENRES[buf[127]];
  }
  f.close();
  return true;
}

// ---------------------------------------------------------------- rescan
// Rebuilds the index on the device, in a task, with Music showing progress.
// Files already in the index keep their record (no tags read), new ones are
// read, removed ones drop out. Sorting needs the whole library in RAM, so
// each track is kept as a few small ids into pools of unique names (~10 bytes
// a track, ~30 KB for 1500 tracks); playback must be stopped first.
struct Pool {  // unique strings, case-insensitive
  char *buf = nullptr;
  uint32_t *at = nullptr;
  uint16_t *owner = nullptr;  // albums: the album artist's id
  size_t used = 0, cap = 0, n = 0, ncap = 0;
  const char *str(int i) const { return buf + at[i]; }
  int find(const char *s, int own) {
    for (size_t i = 0; i < n; i++)
      if ((!owner || owner[i] == own) && !strcasecmp(buf + at[i], s)) return i;
    return -1;
  }
  int add(const char *s, int own = 0) {
    int i = find(s, own);
    if (i >= 0) return i;
    size_t len = strlen(s) + 1;
    if (used + len > cap) {
      size_t c = cap + 1024;
      while (c < used + len) c += 1024;
      char *nb = (char *)realloc(buf, c);
      if (!nb) return -1;
      buf = nb, cap = c;
    }
    if (n == ncap) {
      size_t c = ncap + 64;
      uint32_t *na = (uint32_t *)realloc(at, c * sizeof *at);
      if (!na) return -1;
      at = na;
      if (owner) {
        uint16_t *no = (uint16_t *)realloc(owner, c * sizeof *owner);
        if (!no) return -1;
        owner = no;
      }
      ncap = c;
    }
    at[n] = used;
    if (owner) owner[n] = own;
    memcpy(buf + used, s, len);
    used += len;
    return n++;
  }
  void clear() { free(buf); free(at); free(owner); *this = Pool(); }
};

struct Trk { uint16_t group, album, genre, order; };  // order: disc * 1000 + track

static volatile int scanPhase = 0;  // 0 idle, 1 reading, 2 sorting, 3 writing, 4 done, -1 failed
static volatile int scanDone = 0, scanTotal = 0;
static String scanMsg;
static bool scanFull = false;

static uint32_t fnv(const char *s) {
  uint32_t h = 2166136261u;
  while (*s) h = (h ^ (uint8_t)*s++) * 16777619u;
  return h;
}

static String vfs(const String &real) { return String(store::kind()[0] == 'S' ? "/sd" : "/littlefs") + real; }

static void scanTask(void *) {
  const size_t REC = 512, MAXN = 3000;
  fs::FS *fs = nullptr;
  String root;
  fs = store::resolve("data/music", root);
  String libDir = String(root) + "/.library";
  struct Old { uint32_t h; uint16_t row; };
  Old *old = nullptr;
  size_t nOld = 0;
  Trk *trk = nullptr;
  size_t n = 0, ncap = 0;
  Pool groups, albums, genres;
  albums.owner = (uint16_t *)malloc(2);
  File oldF, tmp;
  char rec[REC + 1], *f[8];
  bool ok = fs != nullptr && albums.owner;
  if (ok) {
    fs->mkdir(libDir);
    oldF = fs->open(libDir + "/tracks.dat", "r");
    // 1. the old index, as path hashes, to reuse records of known files
    if (oldF && !scanFull) {
      size_t rows = oldF.size() / REC;
      old = (Old *)malloc((rows ? rows : 1) * sizeof(Old));
      for (size_t i = 0; old && i < rows && i < MAXN; i++) {
        if (oldF.read((uint8_t *)rec, REC) != REC) break;
        rec[REC] = 0;
        char *tab = strchr(rec, '\t');
        if (tab) *tab = 0;
        old[nOld++] = {fnv(rec), (uint16_t)i};
      }
      std::sort(old, old + nOld, [](const Old &a, const Old &b) { return a.h < b.h; });
    }
    if (oldF) oldF.close();  // reopened per reused record: the card allows 2 open files
    tmp = fs->open(libDir + "/tracks.tmp", "w");
    ok = (bool)tmp;
  }
  // 2. walk the folders; reuse or read each track, append it to tracks.tmp
  scanPhase = 1;
  struct Level { DIR *d; size_t parentLen; };  // parentLen: length of rel before entering
  Level stack[5];
  int depth = 0;
  String rel;  // path under data/music
  if (ok) {
    stack[0] = {opendir(vfs(root).c_str()), 0};
    depth = stack[0].d ? 1 : 0;
  }
  while (ok && depth > 0) {
    Level &lv = stack[depth - 1];
    struct dirent *e = readdir(lv.d);
    if (!e) {
      closedir(lv.d);
      rel.remove(lv.parentLen);
      depth--;
      continue;
    }
    const char *name = e->d_name;
    if (name[0] == '.') continue;
    String path = rel.length() ? rel + "/" + name : String(name);
    if (e->d_type == DT_DIR) {
      if (depth < 5) {
        DIR *d = opendir(vfs(root + "/" + path).c_str());
        if (d) { stack[depth++] = {d, rel.length()}; rel = path; }
      }
      continue;
    }
    String lower = path;
    lower.toLowerCase();
    if (!lower.endsWith(".mp3") && !lower.endsWith(".wav")) continue;
    if (path.length() > 300 || n >= MAXN) continue;
    // reuse the old record, or read the tags
    String line;
    uint32_t h = fnv(path.c_str());
    Old *hit = std::lower_bound(old, old + nOld, Old{h, 0}, [](const Old &a, const Old &b) { return a.h < b.h; });
    bool reused = false;
    if (hit < old + nOld && hit->h == h && (oldF = fs->open(libDir + "/tracks.dat", "r")) &&
        oldF.seek((size_t)hit->row * REC) && oldF.read((uint8_t *)rec, REC) == REC) {
      oldF.close();
      rec[REC - 1] = 0;
      for (int k = REC - 2; k >= 0 && rec[k] == ' '; k--) rec[k] = 0;
      if (!strncmp(rec, path.c_str(), path.length()) && rec[path.length()] == '\t') { line = rec; reused = true; }
    }
    if (oldF) oldF.close();
    if (!reused) {
      Tags t;
      readTags("data/music/" + path, t);
      int s1 = path.lastIndexOf('/'), s0 = s1 > 0 ? path.lastIndexOf('/', s1 - 1) : -1;
      auto folded = [](const String &s) { String o; utf8Ascii(o, (const uint8_t *)s.c_str(), s.length()); o.trim(); return o; };
      String file = path.substring(s1 + 1), album = s1 > 0 ? path.substring(s0 + 1, s1) : "";
      String artist = s0 > 0 ? path.substring(path.lastIndexOf('/', s0 - 1) + 1, s0) : "";
      if (!t.title.length()) t.title = folded(file.substring(0, file.lastIndexOf('.')));
      if (!t.artist.length()) t.artist = artist.length() ? folded(artist) : "Unknown artist";
      if (!t.album.length()) t.album = album.length() ? folded(album) : "Unknown album";
      if (!t.genre.length()) t.genre = "Unknown genre";
      if (!t.albumArtist.length()) t.albumArtist = t.artist;
      // the text gets whatever room the path leaves in the 512-byte record
      int room = (480 - (int)path.length()) / 5;
      auto cut = [room](String s, int max) {
        s = s.substring(0, max < room ? max : room);
        s.trim();
        return s.length() ? s : String("(untitled)");
      };
      line = path + "\t" + cut(t.title, 80) + "\t" + cut(t.artist, 60) + "\t" + cut(t.album, 60) + "\t" + cut(t.genre, 30) +
             "\t" + String(t.track.toInt() > 0 ? String(t.track.toInt()) : "") + "\t" + cut(t.albumArtist, 60) + "\t" +
             String(t.disc.toInt());
    }
    // the sort keys: album artist (or artist), album, genre, disc/track
    strlcpy(rec, line.c_str(), sizeof rec);
    int nf = 0;
    f[nf++] = rec;
    for (char *p = rec; *p && nf < 8; p++)
      if (*p == '\t') { *p = 0; f[nf++] = p + 1; }
    if (nf < 6) continue;
    if (n == ncap) {
      Trk *nt = (Trk *)realloc(trk, (ncap + 128) * sizeof(Trk));
      if (!nt) { ok = false; scanMsg = "not enough memory"; break; }
      trk = nt, ncap += 128;
    }
    int g = groups.add(nf > 6 && *f[6] ? f[6] : f[2]);
    int a = g >= 0 ? albums.add(f[3], g) : -1;
    int ge = genres.add(f[4]);
    if (g < 0 || a < 0 || ge < 0) { ok = false; scanMsg = "not enough memory"; break; }
    int disc = nf > 7 ? atoi(f[7]) : 0;
    trk[n] = {(uint16_t)g, (uint16_t)a, (uint16_t)ge, (uint16_t)(disc * 1000 + atoi(f[5]))};
    // the record as written, padded to its fixed size
    size_t len = line.length();
    String padded;
    padded.reserve(REC + 1);
    padded = line;
    while (padded.length() < REC - 1) padded += ' ';
    padded += '\n';
    if (len >= REC) continue;  // cannot happen with the cuts above; skip rather than fail
    if (tmp.write((const uint8_t *)padded.c_str(), REC) != REC) { ok = false; scanMsg = "write failed"; break; }
    n++;
    scanDone = n;
    if ((n & 15) == 0) vTaskDelay(1);
  }
  while (depth > 0) closedir(stack[--depth].d);
  free(old);
  if (oldF) oldF.close();
  if (tmp) tmp.close();

  // 3. sort: tracks by album artist, album, disc/track; albums by name
  uint16_t *ord = nullptr, *gRank = nullptr, *aRank = nullptr, *aOrd = nullptr, *geOrd = nullptr;
  if (ok) {
    scanPhase = 2;
    ord = (uint16_t *)malloc(n * 2 + 2);
    gRank = (uint16_t *)malloc(groups.n * 2 + 2), aRank = (uint16_t *)malloc(albums.n * 2 + 2);
    aOrd = (uint16_t *)malloc(albums.n * 2 + 2), geOrd = (uint16_t *)malloc(genres.n * 2 + 2);
    ok = ord && gRank && aRank && aOrd && geOrd;
    if (!ok) scanMsg = "not enough memory";
  }
  if (ok) {
    for (size_t i = 0; i < groups.n; i++) ord[i] = i;
    std::sort(ord, ord + groups.n, [&](uint16_t a, uint16_t b) { return strcasecmp(groups.str(a), groups.str(b)) < 0; });
    for (size_t i = 0; i < groups.n; i++) gRank[ord[i]] = i;
    for (size_t i = 0; i < albums.n; i++) aOrd[i] = i;
    std::sort(aOrd, aOrd + albums.n, [&](uint16_t a, uint16_t b) {
      if (albums.owner[a] != albums.owner[b]) return gRank[albums.owner[a]] < gRank[albums.owner[b]];
      return strcasecmp(albums.str(a), albums.str(b)) < 0;
    });
    for (size_t i = 0; i < albums.n; i++) aRank[aOrd[i]] = i;
    for (size_t i = 0; i < n; i++) ord[i] = i;
    std::sort(ord, ord + n, [&](uint16_t a, uint16_t b) {
      const Trk &x = trk[a], &y = trk[b];
      if (x.group != y.group) return gRank[x.group] < gRank[y.group];
      if (x.album != y.album) return aRank[x.album] < aRank[y.album];
      if (x.order != y.order) return x.order < y.order;
      return a < b;
    });
    for (size_t i = 0; i < genres.n; i++) geOrd[i] = i;
    std::sort(geOrd, geOrd + genres.n, [&](uint16_t a, uint16_t b) { return strcasecmp(genres.str(a), genres.str(b)) < 0; });
    // albums.dat is sorted by album name (then artist)
    std::sort(aOrd, aOrd + albums.n, [&](uint16_t a, uint16_t b) {
      int c = strcasecmp(albums.str(a), albums.str(b));
      return c ? c < 0 : strcasecmp(groups.str(albums.owner[a]), groups.str(albums.owner[b])) < 0;
    });
  }

  // 4. write the new files next to the old ones, then swap them in
  if (ok) {
    scanPhase = 3;
    scanDone = 0;
    File in = fs->open(libDir + "/tracks.tmp", "r"), out = fs->open(libDir + "/tracks.new", "w");
    ok = in && out;
    for (size_t r = 0; ok && r < n; r++) {
      ok = in.seek((size_t)ord[r] * REC) && in.read((uint8_t *)rec, REC) == REC && out.write((uint8_t *)rec, REC) == REC;
      scanDone = r + 1;
      if ((r & 15) == 0) vTaskDelay(1);
    }
    if (in) in.close();
    if (out) out.close();
    if (!ok) scanMsg = "write failed";
  }
  auto writeRows = [&](const char *name, int size, std::function<bool(String &, size_t)> row, size_t count) {
    File out = fs->open(libDir + "/" + name + ".new", "w");
    if (!out) return false;
    String line;
    for (size_t i = 0; i < count; i++) {
      line = "";
      if (!row(line, i)) continue;
      while ((int)line.length() < size - 1) line += ' ';
      line = line.substring(0, size - 1) + "\n";
      if (out.write((const uint8_t *)line.c_str(), size) != (size_t)size) { out.close(); return false; }
    }
    out.close();
    return true;
  };
  size_t nArtists = 0, nAlbums = albums.n, nGenres = 0;
  if (ok) {
    // artists: runs of the same album artist in track order
    ok = writeRows("artists", 128, [&](String &line, size_t r) {
      int g = trk[ord[r]].group;
      if (r > 0 && trk[ord[r - 1]].group == g) return false;
      size_t c = 1;
      while (r + c < n && trk[ord[r + c]].group == g) c++;
      line = String(groups.str(g)) + "\t" + r + "\t" + c;
      nArtists++;
      return true;
    }, n);
    // albums: tracks of an album are contiguous; find each one's first row
    ok = ok && writeRows("albums", 128, [&](String &line, size_t i) {
      int a = aOrd[i];
      size_t first = n, c = 0;
      for (size_t r = 0; r < n; r++)
        if (trk[ord[r]].album == a) { if (first == n) first = r; c++; }
      if (!c) return false;
      line = String(albums.str(a)) + "\t" + groups.str(albums.owner[a]) + "\t" + first + "\t" + c;
      return true;
    }, albums.n);
    // genres and the rows of each genre's tracks
    File gt = fs->open(libDir + "/gtracks.new", "w");
    size_t written = 0;
    ok = ok && gt && writeRows("genres", 128, [&](String &line, size_t i) {
      int ge = geOrd[i];
      size_t first = written;
      char num[9];
      for (size_t r = 0; r < n; r++)
        if (trk[ord[r]].genre == ge) {
          snprintf(num, sizeof num, "%07u\n", (unsigned)r);
          gt.write((const uint8_t *)num, 8);
          written++;
        }
      if (written == first) return false;
      line = String(genres.str(ge)) + "\t" + first + "\t" + (written - first);
      nGenres++;
      return true;
    }, genres.n);
    if (gt) gt.close();
    if (!ok) scanMsg = "write failed";
  }
  if (ok) {
    for (const char *name : {"tracks", "artists", "albums", "genres", "gtracks"}) {
      fs->remove(libDir + "/" + name + ".dat");
      fs->rename(libDir + "/" + name + ".new", libDir + "/" + name + ".dat");
    }
    File info = fs->open(libDir + "/info.txt", "w");
    if (info) {
      info.printf("liveos-library 1\ntracks %u\nartists %u\nalbums %u\ngenres %u\n", (unsigned)n, (unsigned)nArtists,
                  (unsigned)nAlbums, (unsigned)nGenres);
      info.close();
    }
  }
  fs->remove(libDir + "/tracks.tmp");
  free(trk); free(ord); free(gRank); free(aRank); free(aOrd); free(geOrd);
  groups.clear(); albums.clear(); genres.clear();
  usbdev::log(String("library rescan: ") + (ok ? "ok, " : "FAILED (" + scanMsg + "), ") + n + " tracks");
  store::pin(false);
  scanPhase = ok ? 4 : -1;
  vTaskDelete(nullptr);
}

// scan([full]) starts rebuilding the index; full re-reads every file's tags.
static int ml_scan(lua_State *L) {
  if (scanPhase >= 1 && scanPhase <= 3) { lua_pushboolean(L, 0); lua_pushstring(L, "already scanning"); return 2; }
  scanFull = lua_toboolean(L, 1);
  scanPhase = 1, scanDone = 0, scanTotal = 0, scanMsg = "";
  store::pin(true);
  if (xTaskCreatePinnedToCore(scanTask, "libscan", 12288, nullptr, 1, nullptr, 0) != pdPASS) {
    scanPhase = -1;
    store::pin(false);
    lua_pushboolean(L, 0);
    lua_pushstring(L, "not enough memory");
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

// scan_status() -> "idle"|"reading"|"sorting"|"writing"|"done"|"failed", count, message
static int ml_scan_status(lua_State *L) {
  static const char *const names[] = {"failed", "idle", "reading", "sorting", "writing", "done"};
  lua_pushstring(L, names[scanPhase + 1]);
  lua_pushinteger(L, scanDone);
  lua_pushstring(L, scanMsg.c_str());
  return 3;
}

extern const luaL_Reg musiclibFns[] = {{"info", ml_info}, {"rows", ml_rows}, {"item", ml_item},
                                       {"albums_in", ml_albums_in}, {"scan", ml_scan},
                                       {"scan_status", ml_scan_status}, {nullptr, nullptr}};
