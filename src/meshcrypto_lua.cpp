// The crypto table for Lua apps (the Mesh app's Meshtastic encryption).
// Keys, nonces and data are binary strings.
#include <esp_random.h>
#include <string.h>
#include "bindings.h"
#include "meshcrypto.h"

static const uint8_t *arg(lua_State *L, int i, size_t want, size_t *len = nullptr) {
  size_t n;
  const char *s = luaL_checklstring(L, i, &n);
  if (want && n != want) luaL_error(L, "argument %d must be %d bytes", i, (int)want);
  if (len) *len = n;
  return (const uint8_t *)s;
}

// aes_ctr(key16or32, counter_block16, data) -> data (encrypt and decrypt alike)
static int cr_aes_ctr(lua_State *L) {
  size_t kn, n;
  const uint8_t *key = arg(L, 1, 0, &kn), *iv = arg(L, 2, 16), *d = arg(L, 3, 0, &n);
  if (n > 256) return luaL_error(L, "data too long");
  uint8_t buf[256];
  memcpy(buf, d, n);
  if (!meshcrypto::aesCtr(key, kn, iv, buf, n)) return luaL_error(L, "key must be 16 or 32 bytes");
  lua_pushlstring(L, (const char *)buf, n);
  return 1;
}

// ccm_encrypt(key32, nonce13, data) -> ciphertext, tag8
static int cr_ccm_encrypt(lua_State *L) {
  size_t n;
  const uint8_t *key = arg(L, 1, 32), *nonce = arg(L, 2, 13), *d = arg(L, 3, 0, &n);
  if (n > 256) return luaL_error(L, "data too long");
  uint8_t buf[256], tag[8];
  memcpy(buf, d, n);
  meshcrypto::ccmEncrypt(key, nonce, buf, n, tag);
  lua_pushlstring(L, (const char *)buf, n);
  lua_pushlstring(L, (const char *)tag, 8);
  return 2;
}

// ccm_decrypt(key32, nonce13, ciphertext, tag8) -> plaintext, or nil if the tag is wrong
static int cr_ccm_decrypt(lua_State *L) {
  size_t n;
  const uint8_t *key = arg(L, 1, 32), *nonce = arg(L, 2, 13), *d = arg(L, 3, 0, &n), *tag = arg(L, 4, 8);
  if (n > 256) return luaL_error(L, "data too long");
  uint8_t buf[256];
  memcpy(buf, d, n);
  if (!meshcrypto::ccmDecrypt(key, nonce, buf, n, tag)) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, (const char *)buf, n);
  return 1;
}

// public(priv32) -> pub32
static int cr_public(lua_State *L) {
  uint8_t pub[32];
  meshcrypto::x25519Public(arg(L, 1, 32), pub);
  lua_pushlstring(L, (const char *)pub, 32);
  return 1;
}

// shared(priv32, pub32) -> secret32, or nil for a degenerate key
static int cr_shared(lua_State *L) {
  uint8_t out[32];
  if (!meshcrypto::x25519Shared(arg(L, 1, 32), arg(L, 2, 32), out)) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, (const char *)out, 32);
  return 1;
}

// sha256(data) -> digest32
static int cr_sha256(lua_State *L) {
  size_t n;
  const uint8_t *d = arg(L, 1, 0, &n);
  uint8_t out[32];
  meshcrypto::sha256(d, n, out);
  lua_pushlstring(L, (const char *)out, 32);
  return 1;
}

// random(n) -> n random bytes from the hardware generator (n <= 64)
static int cr_random(lua_State *L) {
  int n = (int)luaL_checkinteger(L, 1);
  if (n < 0 || n > 64) return luaL_error(L, "1 to 64 bytes");
  uint8_t buf[64];
  esp_fill_random(buf, n);
  lua_pushlstring(L, (const char *)buf, n);
  return 1;
}

extern const luaL_Reg cryptoFns[] = {{"aes_ctr", cr_aes_ctr}, {"ccm_encrypt", cr_ccm_encrypt},
                                     {"ccm_decrypt", cr_ccm_decrypt}, {"public", cr_public},
                                     {"shared", cr_shared}, {"sha256", cr_sha256},
                                     {"random", cr_random}, {nullptr, nullptr}};
