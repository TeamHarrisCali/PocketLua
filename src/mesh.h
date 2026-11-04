#pragma once
#include <Arduino.h>

// Thin ESP-NOW transport. Peers that share a passphrase can exchange
// encrypted unicast packets; discovery beacons go out unencrypted as
// broadcasts. All protocol logic lives in Lua (lib/dev.lua).
namespace mesh {

struct Packet {
  String from;  // 12 hex digits
  String data;
  int rssi;
  bool bcast;
};

bool start(const String &passphrase);
void stop();
bool running();
String mac();
bool addPeer(const String &macHex);
bool send(const String &macHex, const String &data);
bool broadcast(const String &data);
bool recv(Packet &p);

}  // namespace mesh
