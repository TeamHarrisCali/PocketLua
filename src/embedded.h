#pragma once
#include <stddef.h>

// Lua files compiled into the firmware (see tools/gen_embed.py).
struct EmbFile {
  const char *path;
  const unsigned char *data;  // source
  size_t len;
  const unsigned char *code;  // stripped bytecode, or nullptr
  size_t codeLen;
};
extern const EmbFile EMBEDDED[];
extern const size_t EMBEDDED_COUNT;

// "PLBUILD:<git commit>[+]" (see gen_embed.py); the App Store compares the
// part after the colon with the catalog's firmware build.
extern const char POCKETLUA_BUILD[];
extern const long POCKETLUA_BUILD_TIME;  // commit time (Unix seconds)
