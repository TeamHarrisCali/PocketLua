#include "luapool.h"
#include <stdint.h>
#include <esp_heap_caps.h>

namespace luapool {

static const size_t PAGE = 2048;  // pages are PAGE-aligned, so a block finds its page by masking
static const size_t STEP = 8;     // size classes 8, 16, ... 64 (8-byte aligned for doubles)
static const int NCLS = MAX_SMALL / STEP;

struct Page {
  Page *prev, *next;  // in the class's list of pages with free slots
  void *freeList;     // freed slots in this page
  uint16_t cls, used, cap, fresh;  // fresh: next never-used slot
};
static const size_t HDR = (sizeof(Page) + STEP - 1) & ~(STEP - 1);

static Page *partial[NCLS];
static size_t pages = 0;

static void *defaultAlloc(size_t size, size_t align) { return heap_caps_aligned_alloc(align, size, MALLOC_CAP_8BIT); }
static void (*freePage)(void *) = heap_caps_free;
static void *(*allocPage)(size_t, size_t) = defaultAlloc;

void setBackend(void *(*a)(size_t, size_t), void (*f)(void *)) {
  allocPage = a;
  freePage = f;
}

static inline int classOf(size_t n) { return (int)((n + STEP - 1) / STEP) - 1; }
static inline size_t slotSize(int c) { return (size_t)(c + 1) * STEP; }

static void unlink(Page *p) {
  if (p->prev) p->prev->next = p->next;
  else partial[p->cls] = p->next;
  if (p->next) p->next->prev = p->prev;
  p->prev = p->next = nullptr;
}

static void pushFront(Page *p) {
  p->prev = nullptr;
  p->next = partial[p->cls];
  if (p->next) p->next->prev = p;
  partial[p->cls] = p;
}

void *alloc(size_t n) {
  int c = classOf(n);
  Page *p = partial[c];
  if (!p) {
    p = (Page *)allocPage(PAGE, PAGE);
    if (!p) return nullptr;
    p->cls = c;
    p->used = 0;
    p->fresh = 0;
    p->freeList = nullptr;
    p->cap = (uint16_t)((PAGE - HDR) / slotSize(c));
    p->prev = p->next = nullptr;
    pushFront(p);
    pages++;
  }
  void *b;
  if (p->freeList) {
    b = p->freeList;
    p->freeList = *(void **)b;
  } else {
    b = (uint8_t *)p + HDR + (size_t)p->fresh * slotSize(c);
    p->fresh++;
  }
  if (++p->used == p->cap) unlink(p);  // full pages leave the list
  return b;
}

void release(void *b, size_t) {
  Page *p = (Page *)((uintptr_t)b & ~(uintptr_t)(PAGE - 1));
  bool wasFull = p->used == p->cap;
  *(void **)b = p->freeList;
  p->freeList = b;
  if (--p->used == 0) {
    if (!wasFull) unlink(p);
    freePage(p);
    pages--;
    return;
  }
  if (wasFull) pushFront(p);
}

bool sameClass(size_t a, size_t b) { return classOf(a) == classOf(b); }

size_t pageBytes() { return pages * PAGE; }

}  // namespace luapool
