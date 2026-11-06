// Mesh background listener. While the Mesh app is closed (and no other app has
// the radio), the Cap LoRa-1262 keeps listening on Mesh's preset. Packets
// addressed to us go to data/mesh/inbox.txt for the app to file when it opens;
// a text DM it can read (PKI, from a node whose key Mesh saved) is confirmed
// to the sender and notified, following Mesh's quiet settings. On/off is cfg
// mesh_bg (Mesh > Setup); the first boot turns it on only if the cap is there.
// Protocol: docs/MESHTASTIC.md; the Lua side is lib/meshtastic.lua.
#include <Arduino.h>
#include <FS.h>
#include <esp_random.h>
#include <string.h>
#include "bindings.h"
#include "hw.h"
#include "mesh.h"
#include "meshcrypto.h"
#include "storage.h"
#include "usbdev.h"

namespace shell { void systemNotify(const String &title, const String &body, const char *snd); }  // system.cpp
using shell::systemNotify;

namespace {

struct Preset { const char *name; float bw; int sf, cr; };
// the order of Mesh's presets (lib/meshtastic.lua M.PRESETS; cfg mesh_preset is 1-based)
const Preset PRESETS[] = {{"LongFast", 250, 11, 5}, {"MediumFast", 250, 9, 5}, {"MediumSlow", 250, 10, 5},
                          {"ShortFast", 250, 7, 5}, {"ShortSlow", 250, 8, 5}, {"LongSlow", 125, 12, 8},
                          {"LongMod", 125, 11, 8}};
const uint8_t DEFAULT_KEY[16] = {0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
                                 0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01};
const char *INBOX = "data/mesh/inbox.txt";
const size_t INBOX_MAX = 16 * 1024;

bool want = false, running = false, paused = false;
uint32_t nextTry = 0, lastCheck = 0;
uint32_t me = 0;
uint8_t chanHash = 0;
uint32_t seen[32][2];
int seenAt = 0;
uint8_t ack[48];
size_t ackLen = 0;
uint32_t ackAt = 0;

uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
void wr32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
uint8_t lastByte(uint32_t n) { return (n & 0xFF) ? (n & 0xFF) : 0xFF; }

String hex8(uint32_t v) {
  char b[9];
  snprintf(b, sizeof b, "%08x", (unsigned)v);
  return b;
}

bool unhex(const String &s, uint8_t *out, size_t n) {
  if (s.length() != n * 2) return false;
  for (size_t i = 0; i < n; i++) out[i] = (uint8_t)strtoul(s.substring(i * 2, i * 2 + 2).c_str(), nullptr, 16);
  return true;
}

// as the app: the last 4 bytes of mesh::mac() (net.mac() in Lua)
uint32_t nodeNum() {
  String m = mesh::mac(), h;
  for (char c : m) if (isxdigit((unsigned char)c)) h += c;
  uint32_t n = h.length() >= 8 ? strtoul(h.substring(h.length() - 8).c_str(), nullptr, 16) : 0;
  return (n < 4 || n == 0xFFFFFFFF) ? 0x50430001 : n;
}

bool isNew(uint32_t from, uint32_t id) {
  for (auto &s : seen) if (s[0] == from && s[1] == id) return false;
  seen[seenAt][0] = from;
  seen[seenAt][1] = id;
  seenAt = (seenAt + 1) % 32;
  return true;
}

size_t fileSize(const char *rel) {
  String real;
  fs::FS *fs = store::resolve(rel, real);
  File f = fs ? fs->open(real) : File();
  size_t n = f ? f.size() : 0;
  if (f) f.close();
  return n;
}

// A line of a small text file starting with prefix (nodes.txt, contacts.txt).
String findLine(const char *rel, const String &prefix) {
  String real, out;
  fs::FS *fs = store::resolve(rel, real);
  File f = fs ? fs->open(real) : File();
  while (f && f.available()) {
    String l = f.readStringUntil('\n');
    if (l.startsWith(prefix)) { out = l; break; }
  }
  if (f) f.close();
  return out;
}

bool listHas(const String &list, const String &item) {
  return (String(",") + list + ",").indexOf(String(",") + item + ",") >= 0;
}

// nodes.txt: hex|long|short|pubhex
String field(const String &line, int i) {
  int s = 0;
  for (int k = 0; k < i; k++) { s = line.indexOf('|', s) + 1; if (s <= 0) return ""; }
  int e = line.indexOf('|', s);
  return line.substring(s, e < 0 ? line.length() : e);
}

// Data { portnum 1, payload 2 }: the two fields we need, the rest skipped
bool parseData(const uint8_t *p, size_t n, uint32_t &port, const uint8_t *&pay, size_t &payLen) {
  port = 0, pay = nullptr, payLen = 0;
  size_t i = 0;
  auto varint = [&](uint32_t &v) {
    v = 0;
    for (int shift = 0; i < n && shift < 64; shift += 7) {
      uint8_t b = p[i++];
      if (shift < 32) v |= (uint32_t)(b & 0x7F) << shift;
      if (b < 0x80) return true;
    }
    return false;
  };
  while (i < n) {
    uint32_t k, v;
    if (!varint(k)) return false;
    uint32_t num = k >> 3, wire = k & 7;
    if (wire == 0) { if (!varint(v)) return false; if (num == 1) port = v; }
    else if (wire == 2) {
      if (!varint(v) || i + v > n) return false;
      if (num == 2) { pay = p + i; payLen = v; }
      i += v;
    } else if (wire == 5) i += 4;
    else if (wire == 1) i += 8;
    else return false;
  }
  return port != 0 && i == n;
}

bool start() {
  int pi = cfgGet("mesh_preset", "1").toInt();
  if (pi < 1 || pi > (int)(sizeof PRESETS / sizeof PRESETS[0])) pi = 1;
  const Preset &p = PRESETS[pi - 1];
  uint32_t h = 5381;
  for (const char *c = p.name; *c; c++) h = h * 33 + (uint8_t)*c;
  uint32_t channels = (uint32_t)(26.0f / (p.bw / 1000.0f));
  LoraParams lp;
  lp.freq = 902.0f + p.bw / 2000.0f + (h % channels) * (p.bw / 1000.0f);
  lp.bw = p.bw, lp.sf = p.sf, lp.cr = p.cr, lp.sync = 0x2B, lp.preamble = 16, lp.power = 22, lp.tcxo = 1.8f;
  chanHash = 0;
  for (const char *c = p.name; *c; c++) chanHash ^= (uint8_t)*c;
  for (uint8_t b : DEFAULT_KEY) chanHash ^= b;
  me = nodeNum();
  if (!hwLoraBegin(lp)) return false;
  usbdev::log(String("mesh listener: on, ") + p.name + " " + String(lp.freq, 3) + " MHz as !" + hex8(me));
  return true;
}

// Routing ACK (Data{portnum 5, payload 18 00, request_id, bitfield}) on the
// public channel's key, sent a moment later
void queueAck(uint32_t to, uint32_t reqId, uint8_t reqFlags) {
  int hopStart = reqFlags >> 5, hopLimit = reqFlags & 7;
  int limit = hopStart == 0 ? 0 : min(3, hopStart - hopLimit + 2);
  uint32_t id = esp_random();
  if (!id) id = 1;
  wr32(ack, to), wr32(ack + 4, me), wr32(ack + 8, id);
  ack[12] = (uint8_t)(limit | limit << 5), ack[13] = chanHash, ack[14] = 0, ack[15] = lastByte(me);
  uint8_t d[] = {0x08, 0x05, 0x12, 0x02, 0x18, 0x00, 0x35, 0, 0, 0, 0, 0x48, 0x00};
  wr32(d + 7, reqId);
  uint8_t iv[16] = {0};
  wr32(iv, id), wr32(iv + 8, me);
  meshcrypto::aesCtr(DEFAULT_KEY, 16, iv, d, sizeof d);
  memcpy(ack + 16, d, sizeof d);
  ackLen = 16 + sizeof d;
  ackAt = millis() + 100 + esp_random() % 250;
  isNew(me, id);
}

void onPacket(const uint8_t *b, size_t n, float rssi, float snr) {
  if (n < 16) return;
  uint32_t to = rd32(b), from = rd32(b + 4), id = rd32(b + 8);
  uint8_t flags = b[12], ch = b[13];
  if (to != me || from == me || !isNew(from, id)) return;  // only what is addressed to us
  if (fileSize(INBOX) < INBOX_MAX) {
    String line = String((int)rssi) + " " + String(snr, 1) + " ";
    char hx[3];
    for (size_t i = 0; i < n; i++) { snprintf(hx, sizeof hx, "%02x", b[i]); line += hx; }
    line += "\n";
    store::mkdirs("data/mesh");
    store::append(INBOX, line.c_str(), line.length());
  }
  // read it if we can: a text DM sent with PKI by a node whose key Mesh saved
  String node = findLine("data/mesh/nodes.txt", hex8(from) + "|");
  uint8_t plain[256];
  size_t pn = 0;
  bool read = false;
  if (ch == 0 && n > 16 + 12) {
    uint8_t priv[32], pub[32], shared[32], key[32];
    if (unhex(cfgGet("mesh_priv"), priv, 32) && unhex(field(node, 3), pub, 32) &&
        meshcrypto::x25519Shared(priv, pub, shared)) {
      meshcrypto::sha256(shared, 32, key);
      pn = n - 16 - 12;
      memcpy(plain, b + 16, pn);
      uint8_t nonce[13] = {0};
      wr32(nonce, id);
      memcpy(nonce + 4, b + 16 + pn + 8, 4);
      wr32(nonce + 8, from);
      read = meshcrypto::ccmDecrypt(key, nonce, plain, pn, b + 16 + pn);
    }
  } else if (ch == chanHash) {
    pn = n - 16;
    memcpy(plain, b + 16, pn);
    uint8_t iv[16] = {0};
    wr32(iv, id), wr32(iv + 8, from);
    read = meshcrypto::aesCtr(DEFAULT_KEY, 16, iv, plain, pn);
  }
  uint32_t port;
  const uint8_t *pay;
  size_t payLen;
  bool parsed = read && parseData(plain, pn, port, pay, payLen);
  if (parsed && port != 1) return;  // receipts and the like: the app files them
  if (parsed && (flags & 0x08)) queueAck(from, id, flags);
  // the notification, quiet as Mesh > Setup says
  String hx = hex8(from);
  String who = field(node, 2);
  if (who == "") who = field(node, 1);
  if (who == "") who = "!" + hx.substring(4);
  bool contact = findLine("data/mesh/contacts.txt", hx).length() > 0;
  bool quiet = listHas(cfgGet("mesh_mute_dm"), hx) || (!contact && cfgGet("mesh_dm_new", "1") == "0");
  String text;
  if (parsed) {
    for (size_t i = 0; i < payLen && text.length() < 80; i++) text += (pay[i] >= 32 && pay[i] < 127) ? (char)pay[i] : '?';
  } else {
    text = "Open Mesh to read it";
  }
  usbdev::log("mesh listener: DM from !" + hx + (parsed ? "" : " (not readable here)") + (quiet ? ", quiet" : ""));
  systemNotify("Mesh: " + who, text, quiet ? "none" : "notify");
}

}  // namespace

void meshsvcBegin() {
  if (cfgGet("mesh_bg") == "") cfgSet("mesh_bg", hwLoraCap() ? "1" : "0");  // first start: on if the cap is there
  want = cfgGet("mesh_bg") == "1";
  nextTry = millis() + 3000;  // after boot settles
}

void meshsvcPause() {
  running = false;
  paused = true;
  ackLen = 0;
}

void meshsvcTick() {
  uint32_t now = millis();
  if (hwLoraAppOwns()) { running = false; return; }
  if (paused) { paused = false; nextTry = now + 1500; }  // the app gave the radio back
  if (now - lastCheck > 2000) { lastCheck = now; want = cfgGet("mesh_bg") == "1"; }
  if (!want) {
    if (running) { hwLoraStop(); running = false; usbdev::log("mesh listener: off"); }
    return;
  }
  if (!running) {
    if ((int32_t)(now - nextTry) < 0) return;
    running = start();
    if (!running) { nextTry = now + 60000; return; }  // no cap: look again in a minute
  }
  uint8_t buf[256];
  float rssi = 0, snr = 0;
  size_t n = hwLoraRecv(buf, rssi, snr);
  if (n) onPacket(buf, n, rssi, snr);
  if (ackLen && !hwLoraBusy() && (int32_t)(now - ackAt) >= 0) {
    hwLoraSend(ack, ackLen);
    ackLen = 0;
  }
}
