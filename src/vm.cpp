#include "vm.h"
#include <esp_heap_caps.h>
#include <multi_heap.h>
#include "bindings.h"
#include "hw.h"
#include "luapool.h"
#include "storage.h"
#include "system.h"
#include "uikit.h"
#include "usbdev.h"

namespace vm {

lua_State *L = nullptr;
String lastError;

static size_t used = 0;
// Lua gets its own contiguous arena, reserved at boot before Wi-Fi starts, so
// Wi-Fi's churn of small buffers can never fragment it. Without an arena
// (reservation failed) it falls back to the system heap with a reserve.
static const size_t ARENA_SIZE = 84 * 1024;
static const size_t MEM_LIMIT = 160 * 1024;
static const size_t HEAP_RESERVE = 16 * 1024;
static multi_heap_handle_t arena = nullptr;
static void *arenaMem = nullptr;

static void *aMalloc(size_t n) { return arena ? multi_heap_malloc(arena, n) : malloc(n); }
static void *aRealloc(void *p, size_t n) { return arena ? multi_heap_realloc(arena, p, n) : realloc(p, n); }
static void aFree(void *p) { if (arena) multi_heap_free(arena, p); else free(p); }
static void *arenaPage(size_t size, size_t align) { return multi_heap_aligned_alloc(arena, size, align); }
static void arenaPageFree(void *p) { multi_heap_free(arena, p); }

void reserveArena() {
  if (arena) return;
  arenaMem = heap_caps_malloc(ARENA_SIZE, MALLOC_CAP_8BIT);
  if (!arenaMem) { usbdev::log("lua arena: could not reserve, using the shared heap"); return; }
  arena = multi_heap_register(arenaMem, ARENA_SIZE);
  if (!arena) { heap_caps_free(arenaMem); arenaMem = nullptr; return; }
  luapool::setBackend(arenaPage, arenaPageFree);
  usbdev::log(String("lua arena: ") + ARENA_SIZE / 1024 + " KB reserved");
}

// While no app is open the arena is empty: native code (the App Store's
// downloads) may use it then. Never while a Lua state exists.
void *arenaBorrow(size_t n) { return arena && !L ? multi_heap_malloc(arena, n) : nullptr; }
void arenaReturn(void *p) {
  if (arena && p) multi_heap_free(arena, p);
}

size_t arenaFree() { return arena ? multi_heap_free_size(arena) : heap_caps_get_free_size(MALLOC_CAP_8BIT); }
static const uint32_t CALL_BUDGET_MS = 2500;
static uint32_t callStart = 0;
static bool timedOut = false;

size_t memUsed() { return used; }

static void releaseBlock(void *p, size_t size) {
  if (size <= luapool::MAX_SMALL) luapool::release(p, size);
  else aFree(p);
}

// Lua passes the old block size with every free/realloc, so small blocks go to
// the pool (see luapool.h) and larger ones to the normal heap.
static void *alloc(void *, void *ptr, size_t osize, size_t nsize) {
  if (ptr == nullptr) osize = 0;
  if (nsize == 0) {
    if (ptr) { used -= osize; releaseBlock(ptr, osize); }
    return nullptr;
  }
  if (nsize > osize && !arena) {
    size_t grow = nsize - osize;
    if (used + grow > MEM_LIMIT) return nullptr;
    if (heap_caps_get_free_size(MALLOC_CAP_8BIT) < grow + HEAP_RESERVE) return nullptr;
  }
  bool oldSmall = ptr && osize <= luapool::MAX_SMALL;
  bool newSmall = nsize <= luapool::MAX_SMALL;
  void *p;
  if (!ptr) {
    p = newSmall ? luapool::alloc(nsize) : aMalloc(nsize);
  } else if (oldSmall && newSmall && luapool::sameClass(osize, nsize)) {
    p = ptr;
  } else if (!oldSmall && !newSmall) {
    p = aRealloc(ptr, nsize);
  } else {
    p = newSmall ? luapool::alloc(nsize) : aMalloc(nsize);
    if (p) {
      memcpy(p, ptr, osize < nsize ? osize : nsize);
      releaseBlock(ptr, osize);
    }
  }
  if (p) used = used - osize + nsize;
  return p;
}

// A script that never returns would freeze the device, so fail it instead.
static void hook(lua_State *Ls, lua_Debug *) {
  if (!timedOut && millis() - callStart > CALL_BUDGET_MS) {
    timedOut = true;
    luaL_error(Ls, "script timed out (no return after %d ms)", (int)CALL_BUDGET_MS);
  }
}

bool call(int nargs, int nresults) {
  callStart = millis();
  timedOut = false;
  if (lua_pcall(L, nargs, nresults, 0) != LUA_OK) {
    lastError = lua_tostring(L, -1) ? lua_tostring(L, -1) : "unknown error";
    usbdev::log("lua error: " + lastError);
    lua_pop(L, 1);
    return false;
  }
  return true;
}

bool open() {
  close();
  used = 0;
  L = lua_newstate(alloc, nullptr);
  if (!L) { lastError = "not enough memory"; return false; }
  luaL_requiref(L, "_G", luaopen_base, 1);
  luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);  // math, table, utf8, coroutine: on first use (hw.cpp)
  lua_settop(L, 0);
  lua_pushnil(L); lua_setglobal(L, "dofile");
  lua_pushnil(L); lua_setglobal(L, "loadfile");
  lua_sethook(L, hook, LUA_MASKCOUNT, 20000);
  size_t m0 = used;
  registerApi(L);
  size_t m1 = used;
  registerHw(L);
  ui::registerLua(L);
  size_t m2 = used;
  shell::registerLua(L);
  size_t m3 = used;
  String err;
  if (!loadChunk(L, "runtime.lua", true, true, err)) { lastError = err; close(); return false; }
  if (!call(0, 0)) { close(); return false; }
  lua_gc(L, LUA_GCCOLLECT);
  // what every app starts with (see where to slim it down)
  usbdev::log(String("vm: lua ") + m0 + " + api " + (m1 - m0) + " + ui " + (m2 - m1) + " + shell " + (m3 - m2) +
              " + runtime " + (used - m3) + " = " + used);
  return true;
}

void close() {
  if (L) lua_close(L);
  L = nullptr;
  used = 0;
}

}  // namespace vm

void luaBudgetReset() { vm::callStart = millis(); }
