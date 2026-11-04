/* In-place stripping of debug information (PocketLua addition). */
#ifndef lstrip_h
#define lstrip_h

#include "lua.h"

LUA_API void lua_stripdebug (lua_State *L);

#endif
