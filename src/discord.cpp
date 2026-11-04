// Discord client for the Discord app, using a bot account and Discord's HTTP
// API (reading and sending messages in one channel). A background task does
// every request, so the screen never waits on the network; the app polls this
// module each frame.
//
// TLS is BearSSL (lib/bearssl), not the core's mbedTLS: mbedTLS wants two
// 16.7 KB record buffers plus ~12 KB of scattered allocations per connection,
// which never fit next to Wi-Fi and a Lua app. BearSSL shares one 16.7 KB
// buffer for both directions (the block vm::open sets aside for `tls = true`
// apps) and ~6 KB of state allocated once, and allocates nothing during a
// connection. Replies are parsed as they stream in; only id/name/author/text
// are kept.
//
// The bot token is read from data/discord.txt (put there from a PC) and never
// passed to Lua. Certificates are checked against Google Trust Services roots
// (src/discord_ta.h, from tools/gen_trust_anchors.py).
#include <Arduino.h>
#include <WiFi.h>
#include <esp_heap_caps.h>
#include <esp_random.h>
#include <time.h>
#include "bearssl.h"
#include <functional>
#include <lua.hpp>
#include <vector>
#include "discord_ta.h"
#include "discord_tls.h"
#include "musiclib.h"
#include "storage.h"
#include "usbdev.h"
#include "vm.h"

namespace {

// ---------------------------------------------------------------- TLS state
volatile bool busy = false;  // a request is running (Wi-Fi roaming waits)

// BearSSL's contexts (~6 KB) live as long as the task; the I/O buffer is the
// TLS block set aside when the app opened (else the arena, else the heap).
struct Tls {
  br_ssl_client_context sc;
  br_x509_minimal_context xc;
  br_x509_trust_anchor tas[DISCORDTRUSTANCHORS_COUNT];
};
Tls *tls = nullptr;
unsigned char *iobuf = nullptr;

void freeTls() {
  if (iobuf && !vm::giveSlab(iobuf)) {
    if (vm::inArena(iobuf)) vm::arenaReturn(iobuf);
    else heap_caps_free(iobuf);
  }
  iobuf = nullptr;
  heap_caps_free(tls);
  tls = nullptr;
}

bool allocTls() {
  if (!tls) tls = (Tls *)heap_caps_malloc(sizeof(Tls), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (!tls) tls = (Tls *)vm::arenaBorrow(sizeof(Tls));
  if (!iobuf) iobuf = (unsigned char *)vm::takeSlab(BR_SSL_BUFSIZE_MONO);
  if (!iobuf) iobuf = (unsigned char *)vm::arenaBorrow(BR_SSL_BUFSIZE_MONO);
  if (!iobuf) iobuf = (unsigned char *)heap_caps_malloc(BR_SSL_BUFSIZE_MONO, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  return tls && iobuf;
}

int sockRead(void *ctx, unsigned char *buf, size_t len) {
  WiFiClient *c = (WiFiClient *)ctx;
  uint32_t t0 = millis();
  while (millis() - t0 < 10000) {
    int n = c->read(buf, len);
    if (n > 0) return n;
    if (!c->connected()) return -1;
    delay(2);
  }
  return -1;
}
int sockWrite(void *ctx, const unsigned char *buf, size_t len) {
  size_t n = ((WiFiClient *)ctx)->write(buf, len);
  return n > 0 ? (int)n : -1;
}

// ---------------------------------------------------------------- JSON
// A streaming parser for Discord's replies (arrays of objects). It reports
// each string/number/bool value with its depth (top array = 1, its objects =
// 2, objects inside them = 3), its key and its parent's key, and the end of
// each object. Strings are folded to ASCII and cut at ~200 characters.
struct Json {
  std::function<void(int depth, const char *key, const char *parent, const String &v)> onValue;
  std::function<void(int depth)> onEnd;
  int depth = 0;
  char keys[8][24] = {};  // key being read at each depth
  bool isObj[8] = {};
  enum { VALUE, KEY, STR, LIT } mode = VALUE;
  bool expectKey = false, esc = false;
  int uni = -1;  // hex digits left in \uXXXX
  uint32_t code = 0;
  String raw;    // the string or literal being read (UTF-8)

  void feed(char c) {
    if (mode == STR || mode == KEY) {
      if (uni >= 0) {
        code = code << 4 | (isdigit(c) ? c - '0' : (tolower(c) - 'a' + 10));
        if (--uni == 0) {
          uni = -1;
          if (code < 0x80) raw += (char)code;
          else if (code < 0x800) { raw += (char)(0xC0 | code >> 6); raw += (char)(0x80 | (code & 0x3F)); }
          else { raw += (char)(0xE0 | code >> 12); raw += (char)(0x80 | ((code >> 6) & 0x3F)); raw += (char)(0x80 | (code & 0x3F)); }
        }
        return;
      }
      if (esc) {
        esc = false;
        if (c == 'u') { uni = 4; code = 0; return; }
        if (raw.length() < 240) raw += c == 'n' || c == 'r' || c == 't' ? ' ' : c;
        return;
      }
      if (c == '\\') { esc = true; return; }
      if (c != '"') { if (raw.length() < 240) raw += c; return; }
      if (mode == KEY) {
        strlcpy(keys[depth], raw.c_str(), sizeof keys[0]);
        expectKey = false;
      } else {
        value();
      }
      raw = "";
      mode = VALUE;
      return;
    }
    if (mode == LIT) {
      if (isalnum((unsigned char)c) || c == '.' || c == '-' || c == '+') { if (raw.length() < 24) raw += c; return; }
      value();
      raw = "";
      mode = VALUE;  // and handle c below
    }
    switch (c) {
      case '{': case '[':
        if (depth < 7) { depth++; isObj[depth] = c == '{'; keys[depth][0] = 0; }
        expectKey = c == '{';
        break;
      case '}': case ']':
        if (c == '}' && onEnd) onEnd(depth);
        if (depth > 0) depth--;
        expectKey = false;
        break;
      case ',': expectKey = isObj[depth]; break;
      case ':': expectKey = false; break;
      case '"': mode = expectKey ? KEY : STR; raw = ""; break;
      default:
        if (isalnum((unsigned char)c) || c == '-') { mode = LIT; raw = String(c); }
    }
  }
  void value() {
    if (!onValue || !isObj[depth]) return;
    String v;
    if (mode == STR) {
      utf8Ascii(v, (const uint8_t *)raw.c_str(), raw.length());
      v.trim();
      if (v.length() > 200) v = v.substring(0, 200);
    } else {
      v = raw;
    }
    onValue(depth, keys[depth], depth > 1 ? keys[depth - 1] : "", v);
  }
};

// ---------------------------------------------------------------- state
struct Item { String id, name; };
struct Msg { uint32_t seq; String author, text; bool mine; };

String token;                      // never leaves this file
TaskHandle_t task = nullptr;
SemaphoreHandle_t mu = nullptr;    // guards everything below
volatile bool quit = false;
enum Cmd { NONE, GUILDS, CHANNELS, OPEN };
Cmd cmd = NONE;
String cmdArg, channel, botId;
std::vector<Item> items;           // result of GUILDS / CHANNELS
bool itemsReady = false;
std::vector<Msg> msgs;             // newest last, at most MAX_MSGS
const size_t MAX_MSGS = 30;
uint32_t seq = 0;
uint64_t lastId = 0;
std::vector<String> outbox;        // messages waiting to be sent
String state = "idle", error;
uint32_t nextPoll = 0;

struct Lock {
  Lock() { xSemaphoreTake(mu, portMAX_DELAY); }
  ~Lock() { xSemaphoreGive(mu); }
};

void setState(const String &s, const String &e = "") {
  Lock l;
  state = s;
  error = e;
}

bool loadToken() {
  String buf;
  const char *p;
  size_t n;
  if (!store::view("data/discord.txt", buf, p, n, false, 512)) return false;
  String s = buf.length() ? buf : String(p);
  int at = s.indexOf("token=");
  s = at >= 0 ? s.substring(at + 6) : s;
  int nl = s.indexOf('\n');
  if (nl >= 0) s = s.substring(0, nl);
  s.trim();
  if (s.startsWith("Bot ")) s = s.substring(4);
  token = s;
  return token.length() > 20;
}

// ---------------------------------------------------------------- HTTP
// One request over TLS; the body streams into json. Returns the HTTP status,
// or < 0 when the connection failed (see failure()). Retry-After (rate
// limits) goes to retryMs.
int request(const char *method, const String &path, const String &body, Json &json, uint32_t &retryMs) {
  if (WiFi.status() != WL_CONNECTED) return -2;
  time_t now = time(nullptr);
  if (now < 1700000000) return -3;  // the clock isn't set yet (NTP), so certificates can't be checked
  if (!allocTls()) {
    usbdev::log(String("discord: no memory for TLS, heap largest=") + heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) +
                " arena largest=" + vm::arenaLargest());
    return -1;
  }
  WiFiClient tcp;
  if (!tcp.connect("discord.com", 443)) return -4;
  busy = true;
  discordTrustAnchors(tls->tas);
  discordTlsInit(&tls->sc, &tls->xc, tls->tas, DISCORDTRUSTANCHORS_COUNT);
  br_ssl_engine_set_buffer(&tls->sc.eng, iobuf, BR_SSL_BUFSIZE_MONO, 0);  // one buffer, both directions
  uint8_t seed[32];
  esp_fill_random(seed, sizeof seed);
  br_ssl_engine_inject_entropy(&tls->sc.eng, seed, sizeof seed);
  br_x509_minimal_set_time(&tls->xc, (uint32_t)(now / 86400 + 719528), (uint32_t)(now % 86400));
  br_ssl_client_reset(&tls->sc, "discord.com", 0);
  br_sslio_context io;
  br_sslio_init(&io, &tls->sc.eng, sockRead, &tcp, sockWrite, &tcp);

  String req = String(method) + " /api/v10" + path + " HTTP/1.0\r\nHost: discord.com\r\nAuthorization: Bot " + token +
               "\r\nUser-Agent: DiscordBot (https://github.com/, 1) LiveOS\r\n";
  if (body.length()) req += "Content-Type: application/json\r\nContent-Length: " + String(body.length()) + "\r\n";
  req += "\r\n" + body;
  if (br_sslio_write_all(&io, req.c_str(), req.length()) < 0 || br_sslio_flush(&io) < 0) {
    usbdev::log(String("discord: TLS handshake failed, BearSSL error ") + br_ssl_engine_last_error(&tls->sc.eng));
    tcp.stop();
    busy = false;
    return -1;
  }
  static bool shown = false;  // the margin, once per boot
  if (!shown) {
    shown = true;
    usbdev::log(String("discord: connected (BearSSL), heap free=") + heap_caps_get_free_size(MALLOC_CAP_8BIT) +
                " largest=" + heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) + " arena free=" + vm::arenaFree());
  }
  int status = 0;
  bool headers = true;
  String line;
  char buf[256];
  int n;
  while ((n = br_sslio_read(&io, buf, sizeof buf)) > 0) {
    for (int i = 0; i < n; i++) {
      char ch = buf[i];
      if (!headers) { json.feed(ch); continue; }
      if (ch == '\r') continue;
      if (ch != '\n') { if (line.length() < 200) line += ch; continue; }
      if (!status && line.startsWith("HTTP/")) status = line.substring(9, 12).toInt();
      String low = line;
      low.toLowerCase();
      if (low.startsWith("retry-after:")) retryMs = (uint32_t)(low.substring(12).toFloat() * 1000) + 200;
      if (!line.length()) headers = false;
      line = "";
    }
  }
  tcp.stop();
  busy = false;
  return status;
}

String jsonEscape(const String &s) {
  String o = "\"";
  for (char ch : s) {
    if (ch == '"' || ch == '\\') { o += '\\'; o += ch; }
    else if ((uint8_t)ch < 0x20) o += ' ';
    else o += ch;
  }
  return o + "\"";
}

String failure(int code) {
  return code == -2 ? "Wi-Fi is not connected" : code == -3 ? "Clock not set yet: wait for Wi-Fi time"
       : code == -4 ? "Can't connect to discord.com" : code == -1 ? "Secure connection failed (see log)"
       : code == 401 ? "Bad token (check data/discord.txt)"
       : code == 403 ? "The bot can't read this channel" : code == 404 ? "Not found"
       : "Discord error " + String(code);
}

// GET a list (servers, channels) into items.
void fetchList(Cmd which, const String &arg) {
  std::vector<Item> got;
  Item cur;
  int type = 0;
  Json j;
  j.onValue = [&](int d, const char *k, const char *, const String &v) {
    if (d != 2) return;
    if (!strcmp(k, "id")) cur.id = v;
    else if (!strcmp(k, "name")) cur.name = v;
    else if (!strcmp(k, "type")) type = v.toInt();
  };
  j.onEnd = [&](int d) {
    if (d != 2) return;
    if (cur.id.length() && (which == GUILDS || type == 0 || type == 5) && got.size() < 60) got.push_back(cur);
    cur = Item();
    type = 0;
  };
  uint32_t retry = 0;
  setState("working");
  int code = request("GET", which == GUILDS ? String("/users/@me/guilds") : "/guilds/" + arg + "/channels", "", j, retry);
  Lock l;
  if (code == 200) { items = got; itemsReady = true; state = "ok"; error = ""; }
  else { state = "error"; error = failure(code); itemsReady = true; items.clear(); }
}

// New messages in the open channel (Discord returns newest first).
void poll() {
  struct New { uint64_t id; String author, authorId, text; };
  std::vector<New> got;
  New cur = {0, "", "", ""};
  String user, global;
  Json j;
  j.onValue = [&](int d, const char *k, const char *parent, const String &v) {
    if (d == 2 && !strcmp(k, "id")) cur.id = strtoull(v.c_str(), nullptr, 10);
    else if (d == 2 && !strcmp(k, "content")) cur.text = v;
    else if (d == 3 && !strcmp(parent, "author")) {
      if (!strcmp(k, "username")) user = v;
      else if (!strcmp(k, "global_name") && v != "null") global = v;
      else if (!strcmp(k, "id")) cur.authorId = v;
    }
  };
  j.onEnd = [&](int d) {
    if (d != 2) return;
    cur.author = global.length() ? global : user;
    if (cur.id && got.size() < 20) got.push_back(cur);
    cur = {0, "", "", ""};
    user = global = "";
  };
  String path = "/channels/" + channel + "/messages?limit=" + (lastId ? "20&after=" + String((unsigned long long)lastId) : "15");
  uint32_t retry = 0;
  int code = request("GET", path, "", j, retry);
  Lock l;
  if (code != 200) {
    state = "error";
    error = failure(code);
    nextPoll = millis() + (retry ? retry : 8000);
    return;
  }
  state = "ok";
  error = "";
  for (int i = (int)got.size() - 1; i >= 0; i--) {  // oldest first
    New &m = got[i];
    if (m.id <= lastId) continue;
    lastId = m.id;
    msgs.push_back({++seq, m.author, m.text.length() ? m.text : String("(attachment or embed)"), m.authorId == botId});
    if (msgs.size() > MAX_MSGS) msgs.erase(msgs.begin());
  }
  nextPoll = millis() + 4000;
}

void send(const String &text) {
  Json j;  // the reply is the message; the next poll picks it up
  uint32_t retry = 0;
  int code = request("POST", "/channels/" + channel + "/messages", "{\"content\":" + jsonEscape(text) + "}", j, retry);
  Lock l;
  if (code == 200) { state = "ok"; error = ""; nextPoll = 0; }
  else { state = "error"; error = code == 403 ? "The bot can't send here" : failure(code); }
}

void taskMain(void *) {
  while (!quit) {
    Cmd c;
    String arg, out;
    {
      Lock l;
      c = cmd;
      arg = cmdArg;
      cmd = NONE;
      if (!outbox.empty()) { out = outbox.front(); outbox.erase(outbox.begin()); }
    }
    if (c == GUILDS || c == CHANNELS) fetchList(c, arg);
    else if (c == OPEN) {
      Json j;  // who the bot is, to mark its own messages
      String id;
      j.onValue = [&](int d, const char *k, const char *, const String &v) { if (d == 1 && !strcmp(k, "id")) id = v; };
      uint32_t retry = 0;
      setState("working");
      if (request("GET", "/users/@me", "", j, retry) == 200) { Lock l; botId = id; }
      poll();
    } else if (out.length()) send(out);
    else if (channel.length() && (int32_t)(millis() - nextPoll) >= 0) poll();
    else ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(200));
  }
  freeTls();
  {
    Lock l;  // released before the task ends: a task that deletes itself never runs the unlock
    task = nullptr;
  }
  vTaskDelete(nullptr);
}

// The task's stack (the TLS handshake runs on it), from the heap or the arena.
const size_t STACK_WORDS = 8192 / sizeof(StackType_t);
StackType_t *stack = nullptr;
StaticTask_t tcb;
TaskHandle_t handle = nullptr;  // stays set until the stack can be returned

void releaseStack() {
  if (!stack) return;
  if (handle && eTaskGetState(handle) != eDeleted) return;  // still running
  if (vm::inArena(stack)) vm::arenaReturn(stack);
  else heap_caps_free(stack);
  stack = nullptr;
  handle = nullptr;
}

bool ensureTask() {
  if (!mu) mu = xSemaphoreCreateMutex();
  if (task) return true;
  releaseStack();
  // The heap first: the arena is short once the app's TLS block is set aside
  // (vm::open), and the heap's largest block (~28 KB) holds this and the
  // other 16.7 KB record buffer.
  size_t bytes = STACK_WORDS * sizeof(StackType_t);
  if (!stack) stack = (StackType_t *)heap_caps_malloc(bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (!stack) stack = (StackType_t *)vm::arenaBorrow(bytes);
  if (!stack) {
    usbdev::log(String("discord: no memory for the task stack, heap largest=") +
                heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) + " arena largest=" + vm::arenaLargest());
    return false;
  }
  quit = false;
  task = handle = xTaskCreateStaticPinnedToCore(taskMain, "discord", STACK_WORDS, nullptr, 1, stack, &tcb, 0);
  return task != nullptr;
}

void start(Cmd c, const String &arg) {
  if (!ensureTask()) { setState("error", "Not enough memory to start"); return; }
  Lock l;
  cmd = c;
  cmdArg = arg;
  itemsReady = false;
  xTaskNotifyGive(task);
}

// ---------------------------------------------------------------- Lua
// ready() -> true if data/discord.txt has a token
int l_ready(lua_State *L) { lua_pushboolean(L, loadToken()); return 1; }
// guilds() / channels(guild_id): start fetching a list; see list()
int l_guilds(lua_State *L) { start(GUILDS, ""); return 0; }
int l_channels(lua_State *L) { start(CHANNELS, luaL_checkstring(L, 1)); return 0; }
// list() -> nil while fetching, then {{id=, name=}, ...} (empty on error)
int l_list(lua_State *L) {
  if (!mu) return 0;
  Lock l;
  if (!itemsReady) return 0;
  lua_createtable(L, items.size(), 0);
  for (size_t i = 0; i < items.size(); i++) {
    lua_createtable(L, 0, 2);
    lua_pushstring(L, items[i].id.c_str()); lua_setfield(L, -2, "id");
    lua_pushstring(L, items[i].name.c_str()); lua_setfield(L, -2, "name");
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}
// open(channel_id): start reading that channel (polled every 4 s);
// open("") stops reading.
int l_open(lua_State *L) {
  {
    if (!mu) mu = xSemaphoreCreateMutex();
    Lock l;
    channel = luaL_checkstring(L, 1);
    msgs.clear();
    lastId = 0;
  }
  if (channel.length()) start(OPEN, "");
  return 0;
}
// send(text): queue a message for the open channel
int l_send(lua_State *L) {
  if (!mu) return 0;
  {
    Lock l;
    if (outbox.size() < 3) outbox.push_back(luaL_checkstring(L, 1));
  }
  if (task) xTaskNotifyGive(task);
  return 0;
}
// messages(after) -> messages with seq > after: {{seq=, author=, text=, mine=}, ...}
int l_messages(lua_State *L) {
  uint32_t after = luaL_optinteger(L, 1, 0);
  lua_newtable(L);
  if (!mu) return 1;
  Lock l;
  int n = 0;
  for (auto &m : msgs) {
    if (m.seq <= after) continue;
    lua_createtable(L, 0, 4);
    lua_pushinteger(L, m.seq); lua_setfield(L, -2, "seq");
    lua_pushstring(L, m.author.c_str()); lua_setfield(L, -2, "author");
    lua_pushstring(L, m.text.c_str()); lua_setfield(L, -2, "text");
    lua_pushboolean(L, m.mine); lua_setfield(L, -2, "mine");
    lua_rawseti(L, -2, ++n);
  }
  return 1;
}
// status() -> "idle"|"working"|"ok"|"error", error message
int l_status(lua_State *L) {
  if (!mu) { lua_pushstring(L, "idle"); return 1; }
  Lock l;
  lua_pushstring(L, state.c_str());
  lua_pushstring(L, error.c_str());
  return 2;
}
// stop(): end the task (waits for a request in flight) and forget the token
int l_stop(lua_State *L) {
  if (task) {
    quit = true;
    xTaskNotifyGive(task);
    uint32_t t0 = millis();
    while (task && millis() - t0 < 12000) delay(20);
    delay(20);  // let it finish vTaskDelete before its stack is returned
    releaseStack();
    luaBudgetReset();
  }
  if (mu) {
    Lock l;
    channel = "";
    msgs.clear();
    msgs.shrink_to_fit();
    items.clear();
    items.shrink_to_fit();
    outbox.clear();
    state = "idle";
  }
  token = "";
  return 0;
}

}  // namespace

// True while a request runs: Wi-Fi roaming waits (its scans need heap too).
bool discordBusy() { return busy; }

extern const luaL_Reg discordFns[] = {{"ready", l_ready}, {"guilds", l_guilds}, {"channels", l_channels},
                                      {"list", l_list}, {"open", l_open}, {"send", l_send},
                                      {"messages", l_messages}, {"status", l_status}, {"stop", l_stop},
                                      {nullptr, nullptr}};
