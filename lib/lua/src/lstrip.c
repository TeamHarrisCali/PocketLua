/*
** In-place stripping of debug information (LiveOS addition, not part of Lua).
** Frees line info, local variable names and upvalue names of a compiled
** chunk without dumping and reloading it, so no large temporary buffer is
** needed (the dump/reload approach failed on a fragmented heap).
*/
#define lstrip_c
#define LUA_CORE

#include "lprefix.h"
#include "lua.h"
#include "lobject.h"
#include "lstate.h"
#include "lmem.h"
#include "lstrip.h"

static void stripproto (lua_State *L, Proto *f) {
  int i;
  luaM_freearray(L, f->lineinfo, f->sizelineinfo);
  f->lineinfo = NULL;
  f->sizelineinfo = 0;
  luaM_freearray(L, f->abslineinfo, f->sizeabslineinfo);
  f->abslineinfo = NULL;
  f->sizeabslineinfo = 0;
  luaM_freearray(L, f->locvars, f->sizelocvars);
  f->locvars = NULL;
  f->sizelocvars = 0;
  for (i = 0; i < f->sizeupvalues; i++)
    f->upvalues[i].name = NULL;
  f->source = NULL;
  for (i = 0; i < f->sizep; i++)
    stripproto(L, f->p[i]);
}

/* Strips the Lua function on top of the stack (no-op for C functions). */
LUA_API void lua_stripdebug (lua_State *L) {
  const TValue *o = s2v(L->top.p - 1);
  if (ttisLclosure(o))
    stripproto(L, clLvalue(o)->p);
}
