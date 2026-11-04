// Host tool for tools/gen_embed.py: compiles a Lua file to stripped bytecode
// for the device. Built from lib/lua/src, whose luaconf.h sets LUA_32BITS,
// so the integers and floats in the bytecode match the ESP32 build.
//   luac32 in.lua out.luac
#include <stdio.h>
#include "lauxlib.h"
#include "lua.h"

static int writer(lua_State *L, const void *p, size_t size, void *ud) {
  (void)L;
  return fwrite(p, 1, size, (FILE *)ud) != size;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: luac32 in.lua out.luac\n"); return 2; }
  lua_State *L = luaL_newstate();
  if (luaL_loadfile(L, argv[1]) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
  FILE *f = fopen(argv[2], "wb");
  if (!f) { perror(argv[2]); return 1; }
  int bad = lua_dump(L, writer, f, 1);
  fclose(f);
  lua_close(L);
  return bad;
}
