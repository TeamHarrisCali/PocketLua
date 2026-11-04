#include "mesh.h"
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_mac.h>
#include <mbedtls/sha256.h>
#include <string.h>

namespace mesh {

static const uint8_t BCAST[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
static const int MAX_PAYLOAD = 250;

struct Slot {
  uint8_t mac[6];
  uint8_t len;
  uint8_t data[MAX_PAYLOAD];
  int8_t rssi;
  bool bcast;
};
static Slot ring[8];
static volatile uint8_t head = 0, tail = 0;  // written by the Wi-Fi task, read by the OS task
static uint8_t lmk[16];
static bool up = false;

static void onRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  if (len <= 0 || len > MAX_PAYLOAD) return;
  uint8_t next = (head + 1) % 8;
  if (next == tail) return;  // full: drop
  Slot &s = ring[head];
  memcpy(s.mac, info->src_addr, 6);
  memcpy(s.data, data, len);
  s.len = len;
  s.rssi = info->rx_ctrl ? info->rx_ctrl->rssi : 0;
  s.bcast = memcmp(info->des_addr, BCAST, 6) == 0;
  __sync_synchronize();
  head = next;
}

static String toHex(const uint8_t *m) {
  char buf[13];
  snprintf(buf, sizeof buf, "%02x%02x%02x%02x%02x%02x", m[0], m[1], m[2], m[3], m[4], m[5]);
  return String(buf);
}

static bool fromHex(const String &h, uint8_t *m) {
  if (h.length() != 12) return false;
  for (int i = 0; i < 6; i++) {
    char b[3] = {h[i * 2], h[i * 2 + 1], 0};
    char *end;
    m[i] = (uint8_t)strtol(b, &end, 16);
    if (*end) return false;
  }
  return true;
}

bool start(const String &passphrase) {
  if (up) stop();
  if (WiFi.getMode() == WIFI_OFF) WiFi.mode(WIFI_STA);
  if (esp_now_init() != ESP_OK) return false;
  esp_now_register_recv_cb(onRecv);

  uint8_t hash[32];
  mbedtls_sha256((const uint8_t *)passphrase.c_str(), passphrase.length(), hash, 0);
  memcpy(lmk, hash, 16);

  esp_now_peer_info_t p = {};
  memcpy(p.peer_addr, BCAST, 6);
  p.ifidx = WIFI_IF_STA;
  p.encrypt = false;
  esp_now_add_peer(&p);
  head = tail = 0;
  up = true;
  return true;
}

void stop() {
  if (up) esp_now_deinit();
  up = false;
}

bool running() { return up; }

String mac() {
  uint8_t m[6];
  esp_read_mac(m, ESP_MAC_WIFI_STA);
  return toHex(m);
}

bool addPeer(const String &macHex) {
  uint8_t m[6];
  if (!up || !fromHex(macHex, m)) return false;
  if (esp_now_is_peer_exist(m)) esp_now_del_peer(m);
  esp_now_peer_info_t p = {};
  memcpy(p.peer_addr, m, 6);
  p.ifidx = WIFI_IF_STA;
  p.encrypt = true;
  memcpy(p.lmk, lmk, 16);
  return esp_now_add_peer(&p) == ESP_OK;
}

bool send(const String &macHex, const String &data) {
  uint8_t m[6];
  if (!up || !fromHex(macHex, m) || data.length() > MAX_PAYLOAD) return false;
  return esp_now_send(m, (const uint8_t *)data.c_str(), data.length()) == ESP_OK;
}

bool broadcast(const String &data) {
  if (!up || data.length() > MAX_PAYLOAD) return false;
  return esp_now_send(BCAST, (const uint8_t *)data.c_str(), data.length()) == ESP_OK;
}

bool recv(Packet &p) {
  if (tail == head) return false;
  Slot &s = ring[tail];
  p.from = toHex(s.mac);
  p.data = "";
  p.data.reserve(s.len);
  for (int i = 0; i < s.len; i++) p.data += (char)s.data[i];
  p.rssi = s.rssi;
  p.bcast = s.bcast;
  __sync_synchronize();
  tail = (tail + 1) % 8;
  return true;
}

}  // namespace mesh
