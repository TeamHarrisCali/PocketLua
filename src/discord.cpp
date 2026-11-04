// Discord client for the Discord app, using a bot account and Discord's HTTP
// API (reading and sending messages in one channel). A background task does
// every request, so the screen never waits on the network; the app polls this
// module each frame.
//
// Memory: one TLS connection needs ~45 KB (two 16 KB record buffers plus the
// handshake). While a request runs, mbedTLS allocates from the Lua arena's
// spare room first (see vm::arenaBorrow), then from the heap. Replies are
// parsed as they stream in; only id/name/author/text are kept.
//
// The bot token is read from data/discord.txt (put there from a PC) and never
// passed to Lua. Certificates are checked against Google Trust Services roots.
#include <Arduino.h>
#include <WiFi.h>
#include <NetworkClientSecure.h>
#include <esp_heap_caps.h>
#include <mbedtls/platform.h>
#include <functional>
#include <lua.hpp>
#include <vector>
#include "discord_ca.h"
#include "musiclib.h"
#include "storage.h"
#include "usbdev.h"
#include "vm.h"

namespace {

// ---------------------------------------------------------------- TLS memory
volatile bool lend = false;  // borrow from the Lua arena (only during our requests)

// Big blocks (the 16 KB record buffers) try the arena first and small ones the
// heap first, so neither side's large free blocks get chipped away.
void *tlsCalloc(size_t n, size_t size) {
  size_t total = n * size;
  if (size && total / size != n) return nullptr;
  auto heap = [](size_t t) { return heap_caps_malloc(t, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT); };
  void *p;
  if (!lend) p = heap(total);
  else if (total >= 4096) { p = vm::arenaBorrow(total); if (!p) p = heap(total); }
  else { p = heap(total); if (!p) p = vm::arenaBorrow(total); }
  if (p) memset(p, 0, total);
  return p;
}
void tlsFree(void *p) {
  if (!p) return;
  if (vm::inArena(p)) vm::arenaReturn(p);
  else heap_caps_free(p);
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
// One request; the body streams into json. Returns the HTTP status, or -1
// when the connection failed. Retry-After (rate limits) goes to retryMs.
int request(const char *method, const String &path, const String &body, Json &json, uint32_t &retryMs) {
  if (WiFi.status() != WL_CONNECTED) return -2;
  NetworkClientSecure c;
  c.setCACert(DISCORD_CA);
  c.setTimeout(10);
  lend = true;
  if (!c.connect("discord.com", 443)) {
    char why[80] = "";
    c.lastError(why, sizeof why);
    lend = false;
    usbdev::log(String("discord: TLS connect failed (") + why + "), heap free=" + heap_caps_get_free_size(MALLOC_CAP_8BIT) +
                " largest=" + heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) + " arena free=" + vm::arenaFree() +
                " largest=" + vm::arenaLargest());
    return -1;
  }
  String req = String(method) + " /api/v10" + path + " HTTP/1.0\r\nHost: discord.com\r\nAuthorization: Bot " + token +
               "\r\nUser-Agent: DiscordBot (https://github.com/, 1) LiveOS\r\n";
  if (body.length()) req += "Content-Type: application/json\r\nContent-Length: " + String(body.length()) + "\r\n";
  req += "\r\n";
  c.print(req);
  if (body.length()) c.print(body);
  int status = 0;
  bool headers = true;
  String line;
  uint8_t buf[256];
  uint32_t t0 = millis();
  while ((c.connected() || c.available()) && millis() - t0 < 10000) {
    int n = c.read(buf, sizeof buf);
    if (n <= 0) { delay(5); continue; }
    t0 = millis();
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
  c.stop();
  lend = false;
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
  return code == -2 ? "Wi-Fi is not connected" : code == -1 ? "Can't reach Discord (TLS or memory)"
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
  static bool hooked = false;
  if (!hooked) { mbedtls_platform_set_calloc_free(tlsCalloc, tlsFree); hooked = true; }
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
  Lock l;
  task = nullptr;
  vTaskDelete(nullptr);
}

// The task's stack (the TLS handshake runs on it) comes from the Lua arena
// too: the heap's large blocks are needed for the record buffers.
const size_t STACK_WORDS = 8192 / sizeof(StackType_t);
StackType_t *stack = nullptr;
StaticTask_t tcb;
TaskHandle_t handle = nullptr;  // stays set until the stack can be returned

void releaseStack() {
  if (!stack) return;
  if (handle && eTaskGetState(handle) != eDeleted) return;  // still running
  vm::arenaReturn(stack);
  stack = nullptr;
  handle = nullptr;
}

bool ensureTask() {
  if (!mu) mu = xSemaphoreCreateMutex();
  if (task) return true;
  releaseStack();
  if (!stack) stack = (StackType_t *)vm::arenaBorrow(STACK_WORDS * sizeof(StackType_t));
  if (!stack) return false;
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
bool discordBusy() { return lend; }

extern const luaL_Reg discordFns[] = {{"ready", l_ready}, {"guilds", l_guilds}, {"channels", l_channels},
                                      {"list", l_list}, {"open", l_open}, {"send", l_send},
                                      {"messages", l_messages}, {"status", l_status}, {"stop", l_stop},
                                      {nullptr, nullptr}};
