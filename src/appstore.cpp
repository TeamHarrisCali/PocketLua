// App Store: installs, updates and removes apps from the GitHub repository's
// release/ folder (made by tools/release.py). Network work runs here, in
// native code, with the App Store app closed: a TLS connection does not fit
// next to an open Lua app on this board, but with no app open the Lua arena
// is free for BearSSL's 16.7 KB buffer and state. The App Store app asks for
// an operation (appstore.run), the shell closes it, runs the operation with a
// progress screen, and reopens it (appstore.result says how it went).
//
// Every file is checked against its SHA-256 from the catalog before it
// replaces anything; the previous copy is kept as <file>.bak.
#include <Arduino.h>
#include <M5Cardputer.h>
#include <WiFi.h>
#include <esp_random.h>
#include <time.h>
#include <functional>
#include <vector>
#include <lua.hpp>
#include "bearssl.h"
#include "bindings.h"
#include "embedded.h"
#include "github_ta.h"
#include "https_tls.h"
#include "storage.h"
#include "uikit.h"
#include "usbdev.h"
#include "vm.h"

void feedWatch();  // main.cpp

namespace {

const char *HOST = "raw.githubusercontent.com";
const char *REPO = "/TeamHarrisCali/PocketLua/";
const char *CATALOG = "data/store/catalog.txt";

String channel() { return cfgGet("store_channel", "beta"); }

// ---------------------------------------------------------------- progress
void progress(const String &line, int pct = -1) {
  auto &d = M5Cardputer.Display;
  d.fillRect(10, 40, 220, 56, ui::col.surface);
  d.setTextColor(ui::col.text, ui::col.surface);
  d.setTextSize(1);
  d.drawString("App Store", 18, 46);
  d.setTextColor(ui::col.muted, ui::col.surface);
  d.drawString(ui::fit(line, 204), 18, 62);
  if (pct >= 0) {
    d.fillRect(18, 80, 204, 6, ui::col.line);
    d.fillRect(18, 80, 204 * (pct > 100 ? 100 : pct) / 100, 6, ui::col.accent);
  }
  feedWatch();
}

// ---------------------------------------------------------------- TLS
struct Tls {
  br_ssl_client_context sc;
  br_x509_minimal_context xc;
  br_x509_trust_anchor tas[GITHUBTRUSTANCHORS_COUNT];
  br_sslio_context io;
};
Tls *tls = nullptr;
unsigned char *iobuf = nullptr;
WiFiClient tcp;
bool up = false;

int sockRead(void *ctx, unsigned char *buf, size_t len) {
  WiFiClient *c = (WiFiClient *)ctx;
  uint32_t t0 = millis();
  while (millis() - t0 < 10000) {
    int avail = c->available();
    if (avail > 0) {
      int n = c->read(buf, len < (size_t)avail ? len : (size_t)avail);
      if (n > 0) return n;
    } else if (!c->connected()) {
      return -1;
    }
    feedWatch();
    delay(2);
  }
  return -1;
}
int sockWrite(void *ctx, const unsigned char *buf, size_t len) {
  WiFiClient *c = (WiFiClient *)ctx;
  uint32_t t0 = millis();
  while (millis() - t0 < 10000) {
    size_t n = c->write(buf, len);
    if (n > 0) return (int)n;
    if (!c->connected()) return -1;
    delay(5);
  }
  return -1;
}

void closeConn() {
  if (up) tcp.stop();
  up = false;
}

void freeTls() {
  closeConn();
  vm::arenaReturn(iobuf);
  vm::arenaReturn(tls);
  iobuf = nullptr;
  tls = nullptr;
}

bool openConn(String &err) {
  closeConn();
  if (!tls) tls = (Tls *)vm::arenaBorrow(sizeof(Tls));
  if (!iobuf) iobuf = (unsigned char *)vm::arenaBorrow(BR_SSL_BUFSIZE_MONO);
  if (!tls || !iobuf) { err = "not enough memory"; return false; }
  if (!tcp.connect(HOST, 443)) { err = "can't reach GitHub"; return false; }
  githubTrustAnchors(tls->tas);
  httpsTlsInit(&tls->sc, &tls->xc, tls->tas, GITHUBTRUSTANCHORS_COUNT);
  br_ssl_engine_set_buffer(&tls->sc.eng, iobuf, BR_SSL_BUFSIZE_MONO, 0);
  uint8_t seed[32];
  esp_fill_random(seed, sizeof seed);
  br_ssl_engine_inject_entropy(&tls->sc.eng, seed, sizeof seed);
  time_t now = time(nullptr);
  br_x509_minimal_set_time(&tls->xc, (uint32_t)(now / 86400 + 719528), (uint32_t)(now % 86400));
  br_ssl_client_reset(&tls->sc, HOST, 0);
  br_sslio_init(&tls->io, &tls->sc.eng, sockRead, &tcp, sockWrite, &tcp);
  up = true;
  return true;
}

// GET <release path>; the body goes to sink in pieces (false from sink stops
// the transfer). Returns the HTTP status, or -1 if the connection failed.
// One connection is kept open for all files; a closed one is reopened once.
int get(const String &path, const std::function<bool(const uint8_t *, size_t)> &sink, String &err) {
  String req = "GET " + String(REPO) + channel() + "/release/" + path + " HTTP/1.1\r\nHost: " + HOST +
               "\r\nUser-Agent: PocketLua\r\nConnection: keep-alive\r\n\r\n";
  for (int attempt = 0; attempt < 2; attempt++) {
    bool fresh = !up || !tcp.connected();
    if (fresh && !openConn(err)) return -1;
    uint32_t t0 = millis();
    if (br_sslio_write_all(&tls->io, req.c_str(), req.length()) < 0 || br_sslio_flush(&tls->io) < 0) {
      int e = br_ssl_engine_last_error(&tls->sc.eng);
      closeConn();
      if (!fresh) continue;
      err = "secure connection failed (" + String(e) + ")";
      usbdev::log("store: TLS failed, BearSSL error " + String(e));
      return -1;
    }
    if (fresh) usbdev::log(String("store: connected to GitHub in ") + (millis() - t0) + " ms");
    // the response: status, headers, then exactly Content-Length bytes (or chunks)
    int status = 0;
    long length = -1, chunkLeft = -1;
    bool headers = true, chunked = false, keep = true, gotAny = false, stopped = false;
    String line;
    uint8_t buf[512];
    while (true) {
      if (!headers && !chunked && length == 0) break;
      int n = br_sslio_read(&tls->io, buf, sizeof buf);
      if (n <= 0) {
        keep = false;
        break;
      }
      gotAny = true;
      feedWatch();
      int i = 0;
      while (i < n) {
        if (headers) {
          char ch = buf[i++];
          if (ch == '\r') continue;
          if (ch != '\n') { if (line.length() < 200) line += ch; continue; }
          String low = line;
          low.toLowerCase();
          if (!status && low.startsWith("http/")) status = line.substring(9, 12).toInt();
          else if (low.startsWith("content-length:")) length = low.substring(15).toInt();
          else if (low.startsWith("transfer-encoding:") && low.indexOf("chunked") > 0) chunked = true;
          else if (low.startsWith("connection:") && low.indexOf("close") > 0) keep = false;
          if (!line.length()) headers = false;
          line = "";
          continue;
        }
        if (!chunked) {
          size_t take = n - i;
          if (length >= 0 && (long)take > length) take = length;
          if (!stopped && status == 200 && !sink(buf + i, take)) stopped = true;
          if (length >= 0) length -= take;
          i += take;
          continue;
        }
        // chunked: "<hex size>\r\n<data>\r\n" ... "0\r\n\r\n"
        if (chunkLeft > 0) {
          size_t take = n - i;
          if ((long)take > chunkLeft) take = chunkLeft;
          if (!stopped && status == 200 && !sink(buf + i, take)) stopped = true;
          chunkLeft -= take;
          i += take;
          continue;
        }
        char ch = buf[i++];
        if (ch == '\r') continue;
        if (ch != '\n') { if (line.length() < 16) line += ch; continue; }
        if (!line.length()) continue;  // the line end after a chunk's data
        chunkLeft = strtol(line.c_str(), nullptr, 16);
        line = "";
        if (chunkLeft == 0) { chunked = false; length = 0; keep = false; }  // trailers: let the server close
      }
    }
    if (!gotAny) {
      closeConn();
      if (!fresh) continue;
      err = "no answer from GitHub";
      return -1;
    }
    if (!keep) closeConn();
    if (stopped) { err = "write to the card failed"; return -1; }
    return status;
  }
  err = "connection lost";
  return -1;
}

// ---------------------------------------------------------------- files
String hex(const uint8_t *h, size_t n) {
  static const char *d = "0123456789abcdef";
  String s;
  for (size_t i = 0; i < n; i++) { s += d[h[i] >> 4]; s += d[h[i] & 15]; }
  return s;
}

// SHA-256 of the copy of rel the device would use (the card's, else the
// built-in source), or "" if there is none.
String localSha(const String &rel) {
  br_sha256_context c;
  br_sha256_init(&c);
  uint8_t out[32];
  File f = store::openStored(rel);
  if (f) {
    uint8_t buf[512];
    int n;
    while ((n = f.read(buf, sizeof buf)) > 0) br_sha256_update(&c, buf, n);
    f.close();
  } else {
    String b;
    const char *p;
    size_t n;
    if (!store::view(rel, b, p, n, true)) return "";
    br_sha256_update(&c, p, n);
  }
  br_sha256_out(&c, out);
  return hex(out, 32);
}

// Downloads release/<rel> to /pocketlua/<rel>, checking its size and SHA-256;
// the old copy becomes <rel>.bak.
bool download(const String &rel, long size, const String &sha, String &err, int pct) {
  String real;
  fs::FS *fs = store::resolve(rel, real, true);
  if (!fs) { err = "no storage"; return false; }
  File f = fs->open(real + ".part", "w");
  if (!f) { err = "can't write " + rel; return false; }
  br_sha256_context c;
  br_sha256_init(&c);
  long got = 0;
  uint32_t shown = 0;
  int st = get(rel, [&](const uint8_t *p, size_t n) {
    br_sha256_update(&c, p, n);
    got += n;
    if (millis() - shown > 300) {  // big files (the firmware): show the bytes
      shown = millis();
      progress(rel + "  " + String(got / 1024) + " / " + String(size / 1024) + " KB", pct);
    }
    return f.write(p, n) == n;
  }, err);
  f.close();
  uint8_t out[32];
  br_sha256_out(&c, out);
  if (st != 200 || got != size || hex(out, 32) != sha) {
    fs->remove(real + ".part");
    if (st > 0 && st != 200) err = rel + ": GitHub answered " + String(st);
    else if (st == 200) err = rel + ": download didn't match its checksum";
    return false;
  }
  if (fs->exists(real)) {
    fs->remove(real + ".bak");
    fs->rename(real, real + ".bak");
  }
  return fs->rename(real + ".part", real);
}

// ---------------------------------------------------------------- catalog
struct Entry {
  String kind, name, flag, srcSha, codeSha, title, cat, icon, libs, desc;
  long srcSize = 0, codeSize = 0;
};

// Parses catalog.txt line by line from the card (no copy of the whole file:
// with an app open the heap may not have a 12 KB block); firmware fills
// build/size/sha.
bool readCatalog(std::vector<Entry> &out, String &fwBuild, long &fwSize, String &fwSha) {
  File file = store::openStored(CATALOG);
  if (!file) return false;
  String line;
  uint8_t buf[256];
  auto parse = [&]() {
    std::vector<String> f;
    int s = 0;
    while (true) {
      int t = line.indexOf('\t', s);
      f.push_back(line.substring(s, t < 0 ? line.length() : t));
      if (t < 0) break;
      s = t + 1;
    }
    if (f[0] == "firmware" && f.size() >= 4) { fwBuild = f[1]; fwSize = f[2].toInt(); fwSha = f[3]; }
    else if (f[0] == "app" && f.size() >= 12) {
      Entry e;
      e.kind = "app"; e.name = f[1]; e.flag = f[2];
      e.srcSize = f[3].toInt(); e.srcSha = f[4]; e.codeSize = f[5].toInt(); e.codeSha = f[6];
      e.title = f[7]; e.cat = f[8]; e.icon = f[9]; e.libs = f[10] == "-" ? "" : f[10]; e.desc = f[11];
      out.push_back(e);
    } else if (f[0] == "lib" && f.size() >= 6) {
      Entry e;
      e.kind = "lib"; e.name = f[1];
      e.srcSize = f[2].toInt(); e.srcSha = f[3]; e.codeSize = f[4].toInt(); e.codeSha = f[5];
      out.push_back(e);
    }
  };
  int n;
  while ((n = file.read(buf, sizeof buf)) > 0) {
    for (int i = 0; i < n; i++) {
      if (buf[i] == '\n') { if (line.length()) parse(); line = ""; }
      else if (line.length() < 600) line += (char)buf[i];
    }
  }
  if (line.length()) parse();
  file.close();
  return true;
}

String appPath(const String &name) { return "apps/" + name + "/main.lua"; }

// installed | update | available, for an app or library entry
String status(const Entry &e) {
  String rel = e.kind == "app" ? appPath(e.name) : e.name;
  String have = localSha(rel);
  return !have.length() ? "available" : have == e.srcSha ? "installed" : "update";
}

String running() {
  String b = POCKETLUA_BUILD + 8;
  if (b.endsWith("+")) b.remove(b.length() - 1);
  return b;
}

// ---------------------------------------------------------------- operations
String result;  // what the last operation did, for the App Store app

bool ready(String &err) {
  if (WiFi.status() != WL_CONNECTED) { err = "Wi-Fi isn't connected (Settings > Wi-Fi)"; return false; }
  for (int i = 0; i < 100 && time(nullptr) < 1700000000; i++) {  // the clock comes from the network
    progress("Waiting for the clock...");
    delay(100);
  }
  if (time(nullptr) < 1700000000) { err = "the clock isn't set yet; try again in a moment"; return false; }
  return true;
}

void check() {
  String err;
  if (!ready(err)) { result = "error: " + err; return; }
  progress("Connecting to GitHub...");
  String real;
  fs::FS *fs = store::resolve(CATALOG, real, true);
  File f = fs ? fs->open(real + ".part", "w") : File();
  if (!f) { result = "error: can't write to the card"; return; }
  int st = get("catalog.txt", [&](const uint8_t *p, size_t n) { return f.write(p, n) == n; }, err);
  f.close();
  if (st != 200) {
    fs->remove(real + ".part");
    result = "error: " + (st > 0 ? "GitHub answered " + String(st) : err);
    return;
  }
  fs->remove(real);
  fs->rename(real + ".part", real);
  result = "checked";
}

// ops: "install:<app>,remove:<app>,firmware"
void apply(const String &ops) {
  std::vector<Entry> cat;
  String fwBuild, fwSha, err;
  long fwSize = 0;
  if (!readCatalog(cat, fwBuild, fwSize, fwSha)) { result = "error: check for updates first"; return; }
  if (!ready(err)) { result = "error: " + err; return; }
  // the files to fetch: each app's source and bytecode, plus its libraries
  struct Job { String rel; long size; String sha; };
  std::vector<Job> jobs;
  std::vector<String> removes;
  bool firmware = false;
  int installs = 0;
  auto addLib = [&](const String &mod) {
    for (auto &e : cat)
      if (e.kind == "lib" && e.name == "lib/" + mod + ".lua" && status(e) != "installed") {
        jobs.push_back({e.name, e.srcSize, e.srcSha});
        jobs.push_back({e.name + "c", e.codeSize, e.codeSha});
      }
  };
  int s = 0;
  while (s < (int)ops.length()) {
    int c = ops.indexOf(',', s);
    if (c < 0) c = ops.length();
    String op = ops.substring(s, c);
    s = c + 1;
    if (op == "firmware") { firmware = true; continue; }
    int colon = op.indexOf(':');
    String what = op.substring(0, colon), name = op.substring(colon + 1);
    if (what == "remove") { removes.push_back(name); continue; }
    for (auto &e : cat) {
      if (e.kind != "app" || e.name != name) continue;
      jobs.push_back({appPath(name), e.srcSize, e.srcSha});
      jobs.push_back({appPath(name) + "c", e.codeSize, e.codeSha});
      installs++;
      int l = 0;
      while (l < (int)e.libs.length()) {
        int k = e.libs.indexOf(',', l);
        if (k < 0) k = e.libs.length();
        addLib(e.libs.substring(l, k));
        l = k + 1;
      }
    }
  }
  int done = 0, total = jobs.size() + (firmware ? 1 : 0), failed = 0;
  String firstErr;
  for (auto &j : jobs) {
    int pct = total ? done * 100 / total : 0;
    progress("Getting " + j.rel, pct);
    if (!download(j.rel, j.size, j.sha, err, pct)) { failed++; if (!firstErr.length()) firstErr = err; }
    done++;
  }
  if (firmware) {
    progress("Getting the firmware (" + String(fwSize / 1024) + " KB)", total ? done * 100 / total : 0);
    if (!download("PocketLua.bin", fwSize, fwSha, err, 100 * done / total)) { failed++; if (!firstErr.length()) firstErr = err; }
  }
  for (auto &name : removes) {
    // the app's folder: main.lua, main.luac, backups and any files of its own
    for (auto &e : store::list("apps/" + name)) {
      if (!e.dir) store::remove("apps/" + name + "/" + e.name);
    }
    store::remove("apps/" + name);
  }
  freeTls();
  store::rescan();
  String msg;
  if (installs) msg += String(installs) + (installs == 1 ? " app installed" : " apps installed");
  if (removes.size()) msg += String(msg.length() ? ", " : "") + removes.size() + " removed";
  if (firmware && !failed) msg += String(msg.length() ? ". " : "") + "Firmware saved: install PocketLua.bin from M5Launcher";
  result = failed ? "error: " + String(failed) + " failed: " + firstErr : (msg.length() ? msg : String("Nothing to do"));
  usbdev::log("store: " + result);
}

// ---------------------------------------------------------------- Lua
String pendingOp, pendingArg;

// list() -> {firmware = {build=, running=, status=}, apps = {{name=, title=,
// category=, icon=, desc=, size=, core=, status=}, ...}} from the last catalog,
// or nil if there is none yet.
int l_list(lua_State *L) {
  std::vector<Entry> cat;
  String fwBuild, fwSha;
  long fwSize = 0;
  if (!readCatalog(cat, fwBuild, fwSize, fwSha)) return 0;
  lua_newtable(L);
  lua_createtable(L, 0, 4);
  lua_pushstring(L, fwBuild.c_str()); lua_setfield(L, -2, "build");
  lua_pushstring(L, running().c_str()); lua_setfield(L, -2, "running");
  lua_pushinteger(L, fwSize); lua_setfield(L, -2, "size");
  lua_pushstring(L, fwBuild == running() ? "installed" : "update"); lua_setfield(L, -2, "status");
  lua_setfield(L, -2, "firmware");
  lua_newtable(L);
  int n = 0;
  for (auto &e : cat) {
    if (e.kind != "app") continue;
    lua_createtable(L, 0, 8);
    lua_pushstring(L, e.name.c_str()); lua_setfield(L, -2, "name");
    lua_pushstring(L, e.title.c_str()); lua_setfield(L, -2, "title");
    lua_pushstring(L, e.cat.c_str()); lua_setfield(L, -2, "category");
    lua_pushstring(L, e.icon.c_str()); lua_setfield(L, -2, "icon");
    lua_pushstring(L, e.desc.c_str()); lua_setfield(L, -2, "desc");
    lua_pushinteger(L, e.srcSize + e.codeSize); lua_setfield(L, -2, "size");
    lua_pushboolean(L, e.flag == "core"); lua_setfield(L, -2, "core");
    lua_pushstring(L, status(e).c_str()); lua_setfield(L, -2, "status");
    lua_rawseti(L, -2, ++n);
    feedWatch();
  }
  lua_setfield(L, -2, "apps");
  return 1;
}

// run("check") or run("apply", "install:music,remove:snake,firmware"): the
// shell closes the App Store, does it, and reopens it.
int l_run(lua_State *L) {
  pendingOp = luaL_checkstring(L, 1);
  pendingArg = luaL_optstring(L, 2, "");
  return 0;
}

// result() -> what the last run did ("checked", a summary, or "error: ...")
int l_result(lua_State *L) {
  lua_pushstring(L, result.c_str());
  return 1;
}

int l_channel(lua_State *L) {
  if (lua_isstring(L, 1)) cfgSet("store_channel", lua_tostring(L, 1));
  lua_pushstring(L, channel().c_str());
  return 1;
}

}  // namespace

// For the shell: an operation the App Store asked for, run with no app open.
bool appstorePending() { return pendingOp.length() > 0; }
void appstoreRun() {
  String op = pendingOp, arg = pendingArg;
  pendingOp = pendingArg = "";
  result = "";
  usbdev::log("store: " + op + " " + arg + " (channel " + channel() + ")");
  if (op == "check") check();
  else if (op == "apply") apply(arg);
  freeTls();
}

extern const luaL_Reg appstoreFns[] = {{"list", l_list}, {"run", l_run}, {"result", l_result},
                                       {"channel", l_channel}, {nullptr, nullptr}};
