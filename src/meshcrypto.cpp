#include "meshcrypto.h"
#include <string.h>
#include "bearssl.h"

namespace meshcrypto {

bool aesCtr(const uint8_t *key, size_t keyLen, const uint8_t iv[16], uint8_t *buf, size_t len) {
  if (keyLen != 16 && keyLen != 32) return false;
  br_aes_ct_ctr_keys ctx;
  br_aes_ct_ctr_init(&ctx, key, keyLen);
  // BearSSL takes the counter block as a 12-byte IV plus a 32-bit counter
  uint32_t cc = (uint32_t)iv[12] << 24 | (uint32_t)iv[13] << 16 | (uint32_t)iv[14] << 8 | iv[15];
  br_aes_ct_ctr_run(&ctx, iv, cc, buf, len);
  return true;
}

static void ccmStart(br_ccm_context *ccm, br_aes_ct_ctrcbc_keys *keys, const uint8_t key[32],
                     const uint8_t nonce[13], size_t len) {
  br_aes_ct_ctrcbc_init(keys, key, 32);
  br_ccm_init(ccm, &keys->vtable);
  br_ccm_reset(ccm, nonce, 13, 0, len, 8);
  br_ccm_flip(ccm);  // no associated data
}

void ccmEncrypt(const uint8_t key[32], const uint8_t nonce[13], uint8_t *buf, size_t len, uint8_t tag[8]) {
  br_aes_ct_ctrcbc_keys keys;
  br_ccm_context ccm;
  ccmStart(&ccm, &keys, key, nonce, len);
  br_ccm_run(&ccm, 1, buf, len);
  br_ccm_get_tag(&ccm, tag);
}

bool ccmDecrypt(const uint8_t key[32], const uint8_t nonce[13], uint8_t *buf, size_t len, const uint8_t tag[8]) {
  br_aes_ct_ctrcbc_keys keys;
  br_ccm_context ccm;
  ccmStart(&ccm, &keys, key, nonce, len);
  br_ccm_run(&ccm, 0, buf, len);
  return br_ccm_check_tag(&ccm, tag) == 1;
}

// BearSSL's Curve25519 takes the scalar little-endian and clamps it, as RFC 7748.
void x25519Public(const uint8_t priv[32], uint8_t pub[32]) {
  br_ec_c25519_m15.mulgen(pub, priv, 32, BR_EC_curve25519);
}

bool x25519Shared(const uint8_t priv[32], const uint8_t pub[32], uint8_t out[32]) {
  memcpy(out, pub, 32);
  br_ec_c25519_m15.mul(out, 32, priv, 32, BR_EC_curve25519);
  uint8_t any = 0;
  for (int i = 0; i < 32; i++) any |= out[i];
  return any != 0;
}

void sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
  br_sha256_context c;
  br_sha256_init(&c);
  br_sha256_update(&c, data, len);
  br_sha256_out(&c, out);
}

}  // namespace meshcrypto
