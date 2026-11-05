// Backup and restore (Settings > Backup). One file under backups/ holds the
// settings, notes, app data and the scripts made or edited on the device.
// Media (music, recordings, screenshots), logs, the App Store's cache and App
// Store installs (the store can get them again) are left out, so a backup is
// small. Files are streamed one at a time with a small buffer: at most two
// files are open (the SD card allows two), and nothing large is held in RAM.
//
// File format: "PLBACKUP 1\n", then for each file "F <size> <path>\n", its
// bytes and "\n", and "E\n" at the end.
#include <Arduino.h>
#include <lua.hpp>
#include <time.h>
#include <algorithm>
#include <vector>
#include "bindings.h"
#include "storage.h"
#include "usbdev.h"

void feedWatch();  // main.cpp

namespace {

const char *DIR = "backups";
const char *MAGIC = "PLBACKUP 1";
const int KEEP = 5;  // older backups are deleted when a new one is made

// Media, caches and logs in data/: not backed up.
bool skipped(const String &rel) {
  static const char *SKIP[] = {"data/music", "data/recordings", "data/screenshots", "data/store", "data/images"};
  for (auto s : SKIP)
    if (rel == s || rel.startsWith(String(s) + "/")) return true;
  return rel == "data/log.txt" || rel == "data/log.old.txt" || rel.endsWith(".part");
}

// In apps/ and lib/: only what was made or edited on the device. An App Store
// copy has its .luac beside it (saving in the editor deletes that).
bool userFile(fs::FS &fs, const String &rel, const String &real) {
  if (rel.endsWith(".luac") || rel.endsWith(".bak") || rel.endsWith(".part")) return false;
  if (rel.endsWith(".lua")) return !fs.exists(real + "c");
  return true;  // an app's own data in its folder
}

// Every file under rel worth keeping. Each folder is closed before its
// subfolders are read, so only one directory is open at a time.
void collect(const String &rel, std::vector<String> &out) {
  String real;
  fs::FS *fs = store::resolve(rel, real);
  if (!fs) return;
  File d = fs->open(real);
  if (!d || !d.isDirectory()) return;
  std::vector<String> dirs;
  File e;
  while ((e = d.openNextFile())) {
    String n = e.name();
    int s = n.lastIndexOf('/');
    if (s >= 0) n = n.substring(s + 1);
    bool isDir = e.isDirectory();
    e.close();
    if (n.startsWith(".")) continue;
    String r = rel + "/" + n;
    if (skipped(r)) continue;
    if (isDir) dirs.push_back(r);
    else if (rel.startsWith("data") || userFile(*fs, r, real + "/" + n)) out.push_back(r);
  }
  d.close();
  for (auto &sub : dirs) collect(sub, out);
}

// backups/*.plb, newest first (names start with a sequence number).
std::vector<String> backups() {
  std::vector<String> out;
  for (auto &e : store::list(DIR))
    if (!e.dir && e.name.endsWith(".plb")) out.push_back(e.name);
  std::sort(out.begin(), out.end(), [](const String &a, const String &b) { return a > b; });
  return out;
}

bool copy(File &from, File &to, size_t n) {
  uint8_t buf[512];
  while (n > 0) {
    size_t want = n < sizeof buf ? n : sizeof buf;
    size_t got = from.read(buf, want);
    if (got == 0 || to.write(buf, got) != got) return false;
    n -= got;
    feedWatch();
  }
  return true;
}

String readLine(File &f) {
  String s;
  int c;
  while ((c = f.read()) >= 0 && c != '\n' && s.length() < 300) s += (char)c;
  return s;
}

// Only paths a backup can contain: no "..", nothing outside PocketLua's folders.
bool safePath(const String &p) {
  if (p.indexOf("..") >= 0 || p.startsWith("/")) return false;
  return p.startsWith("data/") || p.startsWith("apps/") || p.startsWith("lib/") || p == "boot.lua";
}

// make() -> name, files, bytes | nil, error
int l_make(lua_State *L) {
  std::vector<String> files;
  collect("data", files);
  collect("apps", files);
  collect("lib", files);
  if (store::inStorage("boot.lua")) files.push_back("boot.lua");
  // b0007-20261104-1732.plb: the number keeps the order even without a clock
  int seq = cfgGet("backup_n", "0").toInt() + 1;
  char name[40];
  time_t now = time(nullptr);
  struct tm tm;
  localtime_r(&now, &tm);
  if (now > 1700000000) {
    snprintf(name, sizeof name, "b%04d-%04d%02d%02d-%02d%02d.plb", seq, tm.tm_year + 1900, tm.tm_mon + 1,
             tm.tm_mday, tm.tm_hour, tm.tm_min);
  } else {
    snprintf(name, sizeof name, "b%04d.plb", seq);
  }
  String real;
  fs::FS *fs = store::resolve(String(DIR) + "/" + name + ".part", real, true);
  File out = fs ? fs->open(real, "w") : File();
  if (!out) { lua_pushnil(L); lua_pushstring(L, "can't write to the card"); return 2; }
  out.print(MAGIC);
  out.print("\n");
  size_t bytes = 0;
  int count = 0;
  bool ok = true;
  for (auto &rel : files) {
    String r;
    fs::FS *ifs = store::resolve(rel, r);
    File in = ifs ? ifs->open(r, "r") : File();
    if (!in) continue;
    size_t n = in.size();
    out.printf("F %u %s\n", (unsigned)n, rel.c_str());
    ok = copy(in, out, n);
    in.close();
    out.print("\n");
    if (!ok) break;
    bytes += n;
    count++;
  }
  out.print("E\n");
  out.close();
  if (!ok) {
    fs->remove(real);
    lua_pushnil(L); lua_pushstring(L, "writing the backup failed (card full?)");
    return 2;
  }
  String done = real.substring(0, real.length() - 5);  // without ".part"
  fs->remove(done);
  fs->rename(real, done);
  cfgSet("backup_n", String(seq));
  auto all = backups();
  for (size_t i = KEEP; i < all.size(); i++) store::remove(String(DIR) + "/" + all[i]);
  usbdev::log(String("backup: ") + name + ", " + count + " files, " + bytes + " bytes");
  lua_pushstring(L, name);
  lua_pushinteger(L, count);
  lua_pushinteger(L, bytes);
  return 3;
}

// list() -> { {name=, date="2026-11-04 17:32" or "", size=}, ... } newest first
int l_list(lua_State *L) {
  auto all = backups();
  lua_createtable(L, all.size(), 0);
  int i = 0;
  for (auto &n : all) {
    lua_createtable(L, 0, 3);
    lua_pushstring(L, n.c_str()); lua_setfield(L, -2, "name");
    String date;
    if (n.length() >= 19 && n[5] == '-')  // b0007-20261104-1732.plb
      date = n.substring(6, 10) + "-" + n.substring(10, 12) + "-" + n.substring(12, 14) + " " + n.substring(15, 17) +
             ":" + n.substring(17, 19);
    lua_pushstring(L, date.c_str()); lua_setfield(L, -2, "date");
    String real;
    fs::FS *fs = store::resolve(String(DIR) + "/" + n, real);
    File f = fs ? fs->open(real, "r") : File();
    lua_pushinteger(L, f ? f.size() : 0); lua_setfield(L, -2, "size");
    if (f) f.close();
    lua_rawseti(L, -2, ++i);
  }
  return 1;
}

// restore(name): writes every file of the backup back, then restarts (it
// returns only on failure: nil, error). Settings changed in memory are not
// saved first, so the restored settings file is what the device starts with.
int l_restore(lua_State *L) {
  String name = luaL_checkstring(L, 1);
  if (name.indexOf('/') >= 0 || !name.endsWith(".plb")) { lua_pushnil(L); lua_pushstring(L, "not a backup"); return 2; }
  String real;
  fs::FS *fs = store::resolve(String(DIR) + "/" + name, real);
  File in = fs ? fs->open(real, "r") : File();
  if (!in) { lua_pushnil(L); lua_pushstring(L, "can't open the backup"); return 2; }
  if (readLine(in) != MAGIC) { in.close(); lua_pushnil(L); lua_pushstring(L, "not a PocketLua backup"); return 2; }
  int count = 0;
  String err;
  while (true) {
    String h = readLine(in);
    if (h == "E") break;
    int sp = h.indexOf(' ', 2);
    if (!h.startsWith("F ") || sp < 0) { err = "the backup is damaged"; break; }
    size_t n = h.substring(2, sp).toInt();
    String rel = h.substring(sp + 1);
    if (!safePath(rel)) { err = "the backup has a bad path: " + rel; break; }
    String to;
    fs::FS *ofs = store::resolve(rel + ".part", to, true);
    File out = ofs ? ofs->open(to, "w") : File();
    if (!out) { err = "can't write " + rel; break; }
    bool ok = copy(in, out, n);
    out.close();
    if (!ok) { ofs->remove(to); err = "the backup is damaged (" + rel + ")"; break; }
    in.read();  // the "\n" after the bytes
    String target = to.substring(0, to.length() - 5);
    ofs->remove(target);
    ofs->rename(to, target);
    count++;
  }
  in.close();
  store::rescan();
  usbdev::log("restore: " + name + ", " + count + " files" + (err.length() ? ", stopped: " + err : ", restarting"));
  if (err.length()) {
    lua_pushnil(L);
    lua_pushstring(L, (err + (count ? " (" + String(count) + " files were restored)" : "")).c_str());
    return 2;
  }
  delay(300);
  ESP.restart();
  return 0;
}

// remove(name) -> true | false
int l_remove(lua_State *L) {
  String name = luaL_checkstring(L, 1);
  bool ok = name.indexOf('/') < 0 && name.endsWith(".plb") && store::remove(String(DIR) + "/" + name);
  lua_pushboolean(L, ok);
  return 1;
}

}  // namespace

extern const luaL_Reg backupFns[] = {
    {"make", l_make}, {"list", l_list}, {"restore", l_restore}, {"remove", l_remove}, {nullptr, nullptr}};
