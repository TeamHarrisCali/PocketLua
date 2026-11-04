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
static portMUX_TYPE arenaLock = portMUX_INITIALIZER_UNLOCKED;  // Lua and the Discord TLS task share it

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
  multi_heap_set_lock(arena, &arenaLock);
  luapool::setBackend(arenaPage, arenaPageFree);
  usbdev::log(String("lua arena: ") + ARENA_SIZE / 1024 + " KB reserved");
}

// Native code may borrow the arena's spare room (TLS buffers while an app
// talks HTTPS): what Lua isn't using would otherwise sit idle.
void *arenaBorrow(size_t n) { return arena ? multi_heap_malloc(arena, n) : nullptr; }
bool inArena(const void *p) {
  return arenaMem && p >= arenaMem && (const uint8_t *)p < (const uint8_t *)arenaMem + ARENA_SIZE;
}
void arenaReturn(void *p) { multi_heap_free(arena, p); }
size_t arenaLargest() {
  if (!arena) return 0;
  multi_heap_info_t info;
  multi_heap_get_info(arena, &info);
  return info.largest_free_block;
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

// A block for a TLS record buffer, set aside when an app that declares
// `tls = true` opens, while the arena is still empty: by the time the app
// makes its first HTTPS request, Lua has broken the free space into pieces
// smaller than the ~16.7 KB mbedTLS needs. Freed when the app closes.
static const size_t TLS_SLAB = 17 * 1024;
static void *slab = nullptr;
static bool slabUsed = false;

void *takeSlab(size_t n) {
  if (!slab || slabUsed || n > TLS_SLAB) return nullptr;
  slabUsed = true;
  return slab;
}
bool giveSlab(void *p) {
  if (!p || p != slab) return false;
  slabUsed = false;
  return true;
}

bool open(bool reserveTls) {
  close();
  used = 0;
  if (reserveTls && arena) slab = multi_heap_malloc(arena, TLS_SLAB);
  L = lua_newstate(alloc, nullptr);
  if (!L) { lastError = "not enough memory"; return false; }
  luaL_requiref(L, "_G", luaopen_base, 1);
  luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);
  luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
  luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);
  luaL_requiref(L, LUA_UTF8LIBNAME, luaopen_utf8, 1);
  luaL_requiref(L, LUA_COLIBNAME, luaopen_coroutine, 1);
  lua_settop(L, 0);
  lua_pushnil(L); lua_setglobal(L, "dofile");
  lua_pushnil(L); lua_setglobal(L, "loadfile");
  lua_sethook(L, hook, LUA_MASKCOUNT, 20000);
  registerApi(L);
  registerHw(L);
  ui::registerLua(L);
  shell::registerLua(L);
  String err;
  if (!loadChunk(L, "runtime.lua", true, true, err)) { lastError = err; close(); return false; }
  if (!call(0, 0)) { close(); return false; }
  return true;
}

void close() {
  if (L) lua_close(L);
  L = nullptr;
  used = 0;
  if (slab) multi_heap_free(arena, slab);
  slab = nullptr;
  slabUsed = false;
}

}  // namespace vm

void luaBudgetReset() { vm::callStart = millis(); }
