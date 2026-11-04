#pragma once
#include <stddef.h>

// Small-block pool for the Lua heap. The prebuilt ESP-IDF enables heap
// poisoning, which adds ~12 bytes of header and canaries to every malloc;
// Lua makes thousands of 16-64 byte allocations, so that overhead was about a
// third of all Lua memory. Small blocks are carved from 2 KB pages instead,
// one page per size class, and a page goes back to the system when empty.
namespace luapool {

static const size_t MAX_SMALL = 64;  // larger blocks use the normal heap

void *alloc(size_t n);         // 1 <= n <= MAX_SMALL
void release(void *p, size_t n);
bool sameClass(size_t a, size_t b);
size_t pageBytes();            // RAM currently held in pages

}  // namespace luapool
