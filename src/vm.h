#pragma once
#include <Arduino.h>
#include <lua.hpp>

// The Lua VM. It exists only while an app is open: vm::open() builds a fresh
// state with every API and the app runtime (runtime.lua), vm::close() frees
// all of it. On the desktop Lua uses no RAM at all.
namespace vm {

extern lua_State *L;
extern String lastError;

// Reserves the Lua arena. Call once at boot, before Wi-Fi starts: Wi-Fi's
// buffers fragment the heap, and Lua needs blocks bigger than what is left.
void reserveArena();
size_t arenaFree();
// Lend the arena's spare room to native code (see vm.cpp); return it with
// arenaReturn. inArena tells whose block a pointer is.
void *arenaBorrow(size_t n);
bool inArena(const void *p);
void arenaReturn(void *p);
size_t arenaLargest();
// The reserved TLS block (once at a time), and giving it back: giveSlab is
// false for any other pointer.
void *takeSlab(size_t n);
bool giveSlab(void *p);

// reserveTls: set aside a block for a TLS record buffer first (apps with
// `tls = true` in their header); see takeSlab.
bool open(bool reserveTls = false);
void close();
// lua_pcall with the script time budget; on error sets lastError, pops it
// and returns false.
bool call(int nargs, int nresults);
size_t memUsed();

}  // namespace vm

void luaBudgetReset();
