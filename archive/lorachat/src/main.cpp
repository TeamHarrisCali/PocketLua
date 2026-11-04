// LoRaChat: off-grid LoRa messenger + GPS beacon for Cardputer ADV with Cap LoRa-1262.
// Tab cycles CHAT / PEERS / GPS. Commands: /call NAME, /beacon SECONDS, /sf 7-12
#include <M5Cardputer.h>
#include <M5Unified.h>
#include <RadioLib.h>
#include <TinyGPSPlus.h>
#include <Preferences.h>
#include <esp_mac.h>
#include <utility/PI4IOE5V6408_Class.hpp>
#include <vector>
#include <math.h>

// Cap LoRa-1262 pins (M5Stack docs)
static constexpr int PIN_NSS = 5, PIN_IRQ = 4, PIN_RST = 3, PIN_BUSY = 6;
static constexpr int PIN_GPS_RX = 15, PIN_GPS_TX = 13;

// US ISM band. Change for other regions.
static constexpr float LORA_FREQ = 915.0;
static constexpr float LORA_BW = 125.0;
static constexpr uint8_t LORA_CR = 5;
static constexpr uint8_t LORA_SYNC = 0x12;
static constexpr int8_t LORA_POWER = 14;
static constexpr uint16_t LORA_PREAMBLE = 12;

SX1262 radio = new Module(PIN_NSS, PIN_IRQ, PIN_RST, PIN_BUSY);
m5::PI4IOE5V6408_Class ioe(0x43, 400000, &m5::In_I2C);
TinyGPSPlus gps;
Preferences prefs;
M5Canvas canvas(&M5Cardputer.Display);

enum View { V_CHAT, V_PEERS, V_GPS, V_COUNT };
View view = V_CHAT;

struct Peer {
  String call;
  double lat = 0, lon = 0;
  int alt = 0;
  float rssi = 0, snr = 0;
  uint32_t lastSeen = 0;
};
std::vector<Peer> peers;
std::vector<String> chat;  // wrapped display lines
String input;
String callsign;
int spreadFactor = 9;
uint32_t beaconSec = 60;
uint32_t lastBeacon = 0;
String txQueue;
bool radioOk = false;
volatile bool radioFlag = false;
bool transmitting = false;
uint32_t txCount = 0, rxCount = 0;

void IRAM_ATTR onRadio() { radioFlag = true; }

void addChat(const String &s) {
  const int w = 39;
  for (int i = 0; i < (int)s.length(); i += w) chat.push_back(s.substring(i, i + w));
  while (chat.size() > 40) chat.erase(chat.begin());
}

double haversine(double la1, double lo1, double la2, double lo2) {
  const double R = 6371000.0, r = M_PI / 180.0;
  double dla = (la2 - la1) * r, dlo = (lo2 - lo1) * r;
  double a = sin(dla / 2) * sin(dla / 2) + cos(la1 * r) * cos(la2 * r) * sin(dlo / 2) * sin(dlo / 2);
  return 2 * R * asin(sqrt(a));
}

double bearing(double la1, double lo1, double la2, double lo2) {
  const double r = M_PI / 180.0;
  double y = sin((lo2 - lo1) * r) * cos(la2 * r);
  double x = cos(la1 * r) * sin(la2 * r) - sin(la1 * r) * cos(la2 * r) * cos((lo2 - lo1) * r);
  double b = atan2(y, x) / r;
  return fmod(b + 360.0, 360.0);
}

bool hasFix() { return gps.location.isValid() && gps.location.age() < 5000; }

bool radioBegin() {
  int st = radio.begin(LORA_FREQ, LORA_BW, spreadFactor, LORA_CR, LORA_SYNC, LORA_POWER, LORA_PREAMBLE, 3.0, true);
  if (st != RADIOLIB_ERR_NONE) {
    Serial.printf("radio.begin failed: %d\n", st);
    return false;
  }
  radio.setCurrentLimit(140);
  radio.setPacketReceivedAction(onRadio);
  radio.startReceive();
  return true;
}

void sendRaw(String s) {
  if (!radioOk || transmitting) return;
  transmitting = true;
  radio.startTransmit(s);
  txCount++;
}

void onPacket() {
  String s;
  int st = radio.readData(s);
  if (st != RADIOLIB_ERR_NONE) return;
  rxCount++;
  float rssi = radio.getRSSI(), snr = radio.getSNR();
  // M|call|text   or   P|call|lat|lon|alt
  int a = s.indexOf('|'), b = s.indexOf('|', a + 1);
  if (a != 1 || b < 0) return;
  char type = s[0];
  String call = s.substring(a + 1, b);
  if (call == callsign) return;
  if (type == 'M') {
    addChat(call + ": " + s.substring(b + 1));
    M5Cardputer.Speaker.tone(2200, 70);
  } else if (type == 'P') {
    int c = s.indexOf('|', b + 1), d = s.indexOf('|', c + 1);
    if (c < 0 || d < 0) return;
    Peer *p = nullptr;
    for (auto &x : peers) if (x.call == call) p = &x;
    if (!p) { peers.push_back(Peer()); p = &peers.back(); p->call = call; }
    p->lat = s.substring(b + 1, c).toDouble();
    p->lon = s.substring(c + 1, d).toDouble();
    p->alt = s.substring(d + 1).toInt();
    p->rssi = rssi;
    p->snr = snr;
    p->lastSeen = millis();
  }
}

void sendBeacon() {
  if (!hasFix()) return;
  char buf[96];
  snprintf(buf, sizeof buf, "P|%s|%.5f|%.5f|%d", callsign.c_str(), gps.location.lat(), gps.location.lng(),
           (int)gps.altitude.meters());
  sendRaw(buf);
  lastBeacon = millis();
}

void submit() {
  input.trim();
  if (!input.length()) return;
  if (input[0] == '/') {
    if (input.startsWith("/call ")) {
      callsign = input.substring(6);
      callsign.trim();
      callsign = callsign.substring(0, 10);
      callsign.replace("|", "");
      prefs.putString("call", callsign);
      addChat("* callsign " + callsign);
    } else if (input.startsWith("/beacon ")) {
      beaconSec = max(10, (int)input.substring(8).toInt());
      prefs.putUInt("beacon", beaconSec);
      addChat("* beacon " + String(beaconSec) + "s");
    } else if (input.startsWith("/sf ")) {
      int sf = input.substring(4).toInt();
      if (sf >= 7 && sf <= 12) {
        spreadFactor = sf;
        prefs.putInt("sf", sf);
        radioOk = radioBegin();
        addChat("* SF" + String(sf));
      }
    } else {
      addChat("* unknown command");
    }
  } else {
    txQueue = "M|" + callsign + "|" + input;
    addChat("me: " + input);
  }
  input = "";
}

void handleKeys() {
  if (!M5Cardputer.Keyboard.isChange() || !M5Cardputer.Keyboard.isPressed()) return;
  auto st = M5Cardputer.Keyboard.keysState();
  if (st.tab) { view = (View)((view + 1) % V_COUNT); return; }
  for (char c : st.word) if (input.length() < 120 && c != '|') input += c;
  if (st.del && input.length()) input.remove(input.length() - 1);
  if (st.enter) submit();
}

void drawHeader() {
  canvas.fillRect(0, 0, 240, 12, TFT_NAVY);
  canvas.setTextColor(TFT_WHITE, TFT_NAVY);
  canvas.setCursor(2, 2);
  const char *names[] = {"CHAT", "PEERS", "GPS"};
  canvas.printf("%s %s", names[view], callsign.c_str());
  canvas.setCursor(150, 2);
  canvas.setTextColor(hasFix() ? TFT_GREEN : TFT_ORANGE, TFT_NAVY);
  canvas.printf("%s%2d", hasFix() ? "FIX " : "---- ", (int)gps.satellites.value());
  canvas.setTextColor(radioOk ? TFT_GREEN : TFT_RED, TFT_NAVY);
  canvas.setCursor(204, 2);
  canvas.print(radioOk ? "LoRa" : "NoRF");
}

void drawChat() {
  canvas.setTextColor(TFT_WHITE, TFT_BLACK);
  const int rows = 10;
  int start = max(0, (int)chat.size() - rows);
  for (int i = start; i < (int)chat.size(); i++) {
    canvas.setCursor(2, 15 + (i - start) * 10);
    canvas.print(chat[i]);
  }
  canvas.drawFastHLine(0, 119, 240, TFT_DARKGREY);
  canvas.setTextColor(TFT_YELLOW, TFT_BLACK);
  canvas.setCursor(2, 123);
  String shown = input.length() > 37 ? input.substring(input.length() - 37) : input;
  canvas.print("> " + shown + ((millis() / 500) % 2 ? "_" : ""));
}

void drawPeers() {
  canvas.setTextColor(TFT_CYAN, TFT_BLACK);
  canvas.setCursor(2, 15);
  canvas.print("CALL        DIST   BRG  RSSI  AGE");
  canvas.setTextColor(TFT_WHITE, TFT_BLACK);
  int y = 27;
  for (auto &p : peers) {
    if (y > 120) break;
    canvas.setCursor(2, y);
    String dist = "--", brg = "--";
    if (hasFix()) {
      double d = haversine(gps.location.lat(), gps.location.lng(), p.lat, p.lon);
      dist = d >= 1000 ? String(d / 1000.0, 1) + "km" : String((int)d) + "m";
      brg = String((int)bearing(gps.location.lat(), gps.location.lng(), p.lat, p.lon));
    }
    canvas.printf("%-10.10s %6s %4s %5d %3ds", p.call.c_str(), dist.c_str(), brg.c_str(), (int)p.rssi,
                  (int)((millis() - p.lastSeen) / 1000));
    y += 10;
  }
  if (peers.empty()) {
    canvas.setCursor(2, 30);
    canvas.print("no beacons heard yet");
  }
}

void drawGps() {
  canvas.setTextColor(TFT_WHITE, TFT_BLACK);
  int y = 16;
  auto line = [&](const String &s) { canvas.setCursor(2, y); canvas.print(s); y += 11; };
  if (gps.location.isValid()) {
    line("Lat  " + String(gps.location.lat(), 6));
    line("Lon  " + String(gps.location.lng(), 6));
  } else {
    line("Lat  waiting for fix");
    line("Lon  (needs sky view)");
  }
  line("Alt  " + String(gps.altitude.meters(), 0) + " m");
  line("Spd  " + String(gps.speed.kmph(), 1) + " km/h  Crs " + String(gps.course.deg(), 0));
  line("Sats " + String(gps.satellites.value()) + "  HDOP " + String(gps.hdop.hdop(), 1));
  char t[32] = "--:--:-- UTC";
  if (gps.time.isValid()) snprintf(t, sizeof t, "%02d:%02d:%02d UTC", gps.time.hour(), gps.time.minute(), gps.time.second());
  line(String("Time ") + t);
  line("NMEA chars " + String(gps.charsProcessed()) + "  bad " + String(gps.failedChecksum()));
  line("TX " + String(txCount) + "  RX " + String(rxCount) + "  SF" + String(spreadFactor) + " " + String(LORA_FREQ, 1) + "MHz");
}

void draw() {
  canvas.fillSprite(TFT_BLACK);
  drawHeader();
  if (view == V_CHAT) drawChat();
  else if (view == V_PEERS) drawPeers();
  else drawGps();
  canvas.pushSprite(0, 0);
}

void setup() {
  auto cfg = M5.config();
  M5Cardputer.begin(cfg, true);
  M5Cardputer.Display.setRotation(1);
  M5Cardputer.Speaker.setVolume(128);
  canvas.createSprite(240, 135);
  canvas.setTextSize(1);
  canvas.setFont(&fonts::Font0);

  prefs.begin("lorachat", false);
  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char def[16];
  snprintf(def, sizeof def, "CP-%02X%02X", mac[4], mac[5]);
  callsign = prefs.getString("call", def);
  spreadFactor = prefs.getInt("sf", 9);
  beaconSec = prefs.getUInt("beacon", 60);

  Serial1.begin(115200, SERIAL_8N1, PIN_GPS_RX, PIN_GPS_TX);

  // Cap LoRa-1262: expander P0 drives the RF switch
  if (ioe.begin()) {
    ioe.setDirection(0, true);
    ioe.setHighImpedance(0, false);
    ioe.digitalWrite(0, true);
  } else {
    addChat("* cap not detected");
  }
  radioOk = radioBegin();
  addChat(radioOk ? "* radio ready, " + String(LORA_FREQ, 1) + "MHz SF" + String(spreadFactor)
                  : "* radio init failed");
  addChat("* Tab = switch view. /call /beacon /sf");
}

void loop() {
  M5Cardputer.update();
  handleKeys();
  while (Serial1.available()) gps.encode(Serial1.read());

  if (radioFlag) {
    radioFlag = false;
    if (transmitting) {
      radio.finishTransmit();
      transmitting = false;
    } else {
      onPacket();
    }
    radio.startReceive();
  }
  if (!transmitting) {
    if (txQueue.length()) {
      sendRaw(txQueue);
      txQueue = "";
    } else if (millis() - lastBeacon > beaconSec * 1000UL) {
      sendBeacon();
      if (millis() - lastBeacon > beaconSec * 1000UL) lastBeacon = millis() - beaconSec * 1000UL + 5000;
    }
  }

  static uint32_t lastDraw = 0;
  if (millis() - lastDraw > 100) {
    lastDraw = millis();
    draw();
  }
}
