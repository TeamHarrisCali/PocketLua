#include "storage.h"
#include <FS.h>
#include <SD.h>
#include <SPI.h>
#include <LittleFS.h>
#include <algorithm>
#include "embedded.h"

namespace store {

bool safeMode = false;
static fs::FS *fsys = nullptr;
static bool sdOk = false;
static bool locked = false;
static const char *ROOT = "/liveos";

static bool badPath(const String &p) { return p.indexOf("..") >= 0 || p.indexOf('\\') >= 0; }

// Maps a script-visible path to a real path. Empty string means rejected.
static String realPath(const String &rel) {
  if (badPath(rel) || locked) return "";
  if (rel.startsWith("sd:")) {
    if (!sdOk) return "";
    String p = rel.substring(3);
    return p.startsWith("/") ? p : "/" + p;
  }
  String p = rel;
  while (p.startsWith("/")) p.remove(0, 1);
  return p.length() ? String(ROOT) + "/" + p : String(ROOT);
}

static const EmbFile *findEmb(const String &rel) {
  for (size_t i = 0; i < EMBEDDED_COUNT; i++)
    if (rel == EMBEDDED[i].path) return &EMBEDDED[i];
  return nullptr;
}

bool begin() {
  SPI.begin(40, 39, 14, 12);
  if (SD.begin(12, SPI, 25000000, "/sd", 2)) {
    fsys = &SD;
    sdOk = true;
  } else if (LittleFS.begin(true)) {
    fsys = &LittleFS;
  } else {
    return false;
  }
  if (!fsys->exists(ROOT)) fsys->mkdir(ROOT);
  return true;
}

const char *kind() { return sdOk ? "SD" : "flash"; }
bool hasSd() { return sdOk; }

bool embedded(const String &rel) { return !rel.startsWith("sd:") && findEmb(rel) != nullptr; }

bool inStorage(const String &rel) {
  String p = realPath(rel);
  return fsys && p.length() && fsys->exists(p);
}

bool exists(const String &rel) { return inStorage(rel) || embedded(rel); }

// Reads a whole file in blocks. (Stream::readString() waits a full second at
// the end of every file, which stalls boot and can trip the script time limit.)
static bool readFile(const String &path, String &out, size_t maxBytes = 0) {
  File f = fsys->open(path, "r");
  if (!f || f.isDirectory()) return false;
  size_t size = f.size();
  if (maxBytes && size > maxBytes) size = maxBytes;
  out = "";
  if (size && !out.reserve(size + 1)) { f.close(); return false; }
  uint8_t buf[512];
  size_t total = 0;
  while (total < size) {
    size_t want = size - total < sizeof buf ? size - total : sizeof buf;
    size_t n = f.read(buf, want);
    if (n == 0 || n == (size_t)-1) break;
    out.concat((const char *)buf, n);
    total += n;
  }
  f.close();
  return total == size;
}

static bool readBuiltin(const String &rel, String &out) {
  const EmbFile *e = rel.startsWith("sd:") ? nullptr : findEmb(rel);
  if (!e) return false;
  out = "";
  if (!out.reserve(e->len + 1)) return false;
  out.concat((const char *)e->data, e->len);
  return out.length() == e->len;
}

bool readText(const String &rel, String &out, bool builtinOnly) {
  bool systemFile = rel.startsWith("lib/") || rel == "boot.lua";
  if (!builtinOnly && !(safeMode && systemFile) && inStorage(rel) && readFile(realPath(rel), out)) return true;
  return readBuiltin(rel, out);
}

bool view(const String &rel, String &buf, const char *&ptr, size_t &len, bool builtinOnly, size_t maxBytes) {
  bool systemFile = rel.startsWith("lib/") || rel == "boot.lua";
  if (!builtinOnly && !(safeMode && systemFile) && inStorage(rel) && readFile(realPath(rel), buf, maxBytes)) {
    ptr = buf.c_str();
    len = buf.length();
    return true;
  }
  const EmbFile *e = rel.startsWith("sd:") ? nullptr : findEmb(rel);
  if (!e) return false;
  ptr = (const char *)e->data;
  len = maxBytes && e->len > maxBytes ? maxBytes : e->len;
  return true;
}

bool mkdirs(const String &rel) {
  String p = realPath(rel);
  if (!fsys || !p.length()) return false;
  for (int i = 1; i <= (int)p.length(); i++) {
    if (i == (int)p.length() || p[i] == '/') {
      String part = p.substring(0, i);
      if (!fsys->exists(part)) fsys->mkdir(part);
    }
  }
  return fsys->exists(p);
}

bool write(const String &rel, const String &data) {
  String p = realPath(rel);
  if (!fsys || !p.length()) return false;
  int slash = p.lastIndexOf('/');
  if (rel.startsWith("sd:")) {
    if (slash > 0) mkdirs("sd:" + p.substring(0, slash));
  } else if (slash > (int)strlen(ROOT)) {
    mkdirs(p.substring(strlen(ROOT) + 1, slash));
  }
  // Write to a temp file first so a failed or interrupted save never leaves a
  // half-written script behind.
  String tmp = p + ".tmp";
  File f = fsys->open(tmp, "w");
  if (!f) return false;
  size_t n = f.write((const uint8_t *)data.c_str(), data.length());
  f.close();
  if (n != data.length()) {
    fsys->remove(tmp);
    return false;
  }
  if (fsys->exists(p)) fsys->remove(p);
  if (fsys->rename(tmp, p)) return true;
  // rename failed: fall back to writing in place (we still hold the data)
  fsys->remove(tmp);
  File g = fsys->open(p, "w");
  if (!g) return false;
  size_t m = g.write((const uint8_t *)data.c_str(), data.length());
  g.close();
  return m == data.length();
}

bool append(const String &rel, const char *data, size_t len) {
  String real;
  fs::FS *fs = resolve(rel, real, true);
  if (!fs) return false;
  File f = fs->open(real, "a");
  if (!f) return false;
  size_t n = f.write((const uint8_t *)data, len);
  f.close();
  return n == len;
}

bool rename(const String &from, const String &to) {
  String a, b;
  fs::FS *fa = resolve(from, a);
  fs::FS *fb = resolve(to, b, true);
  if (!fa || fa != fb || !fa->exists(a)) return false;
  if (fb->exists(b)) fb->remove(b);
  return fa->rename(a, b);
}

bool remove(const String &rel) {
  String p = realPath(rel);
  if (!fsys || !p.length() || !fsys->exists(p)) return false;
  File f = fsys->open(p);
  bool isDir = f.isDirectory();
  f.close();
  return isDir ? fsys->rmdir(p) : fsys->remove(p);
}

std::vector<Entry> list(const String &dirIn) {
  std::vector<Entry> out;
  String dir = dirIn;
  while (dir.endsWith("/") && dir.length() > 1) dir.remove(dir.length() - 1);
  bool raw = dir.startsWith("sd:");
  String prefix = (dir.length() && dir != "/" && dir != "sd:" && dir != "sd:/") ? dir + "/" : "";
  if (raw && dir == "sd:") prefix = "";

  auto find = [&](const String &n) -> Entry * {
    for (auto &e : out)
      if (e.name == n) return &e;
    return nullptr;
  };

  if (fsys) {
    String p = realPath(dir.length() ? dir : "");
    if (raw && (dir == "sd:" || dir == "sd:/")) p = "/";
    if (p.length() && fsys->exists(p)) {
      File d = fsys->open(p);
      if (d && d.isDirectory()) {
        File e;
        while ((e = d.openNextFile())) {
          String n = e.name();
          int s = n.lastIndexOf('/');
          if (s >= 0) n = n.substring(s + 1);
          if (n.startsWith(".")) { e.close(); continue; }
          out.push_back({n, e.isDirectory(), true, false, (size_t)e.size()});
          e.close();
        }
        d.close();
      }
    }
  }

  if (!raw) {
    for (size_t i = 0; i < EMBEDDED_COUNT; i++) {
      String path = EMBEDDED[i].path;
      if (!path.startsWith(prefix)) continue;
      String rest = path.substring(prefix.length());
      int s = rest.indexOf('/');
      String name = s >= 0 ? rest.substring(0, s) : rest;
      bool isDir = s >= 0;
      Entry *e = find(name);
      if (e) {
        e->emb = true;
        if (!isDir) e->size = EMBEDDED[i].len;
      } else {
        out.push_back({name, isDir, false, true, isDir ? 0 : EMBEDDED[i].len});
      }
    }
  }

  std::sort(out.begin(), out.end(), [](const Entry &a, const Entry &b) {
    if (a.dir != b.dir) return a.dir;
    return a.name < b.name;
  });
  return out;
}

void lock(bool on) { locked = on; }

fs::FS *resolve(const String &rel, String &real, bool forWrite) {
  real = realPath(rel);
  if (!fsys || !real.length()) return nullptr;
  if (forWrite) {
    int slash = real.lastIndexOf('/');
    if (slash > 0) {
      String dir = real.substring(0, slash);
      for (int i = 1; i <= (int)dir.length(); i++)
        if (i == (int)dir.length() || dir[i] == '/') {
          String part = dir.substring(0, i);
          if (!fsys->exists(part)) fsys->mkdir(part);
        }
    }
  }
  return fsys;
}

bool remount() {
  if (!sdOk) return false;
  SD.end();
  delay(50);
  locked = false;
  return SD.begin(12, SPI, 25000000, "/sd", 2);
}

uint64_t totalBytes() { return sdOk ? SD.totalBytes() : LittleFS.totalBytes(); }
uint64_t usedBytes() { return sdOk ? SD.usedBytes() : LittleFS.usedBytes(); }

}  // namespace store
