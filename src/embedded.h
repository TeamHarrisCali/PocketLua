#pragma once
#include <stddef.h>

// Lua files compiled into the firmware (see tools/gen_embed.py).
struct EmbFile {
  const char *path;
  const unsigned char *data;
  size_t len;
};
extern const EmbFile EMBEDDED[];
extern const size_t EMBEDDED_COUNT;
