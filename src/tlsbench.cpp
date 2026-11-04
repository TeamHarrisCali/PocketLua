// One-off speed test of the crypto an HTTPS update check needs (USB console
// command "!bench"): key agreement, RSA signature checks, AES-GCM and SHA-256.
// Tells whether a TLS handshake fits in a few seconds on this board.
#include <Arduino.h>
#include <esp_heap_caps.h>
#include <functional>
#include "bearssl.h"

String tlsBench() {
  String out;
  auto time = [&](const char *what, int reps, std::function<void()> fn) {
    uint32_t t0 = micros();
    for (int i = 0; i < reps; i++) fn();
    uint32_t us = (micros() - t0) / reps;
    out += String(what) + " " + (us / 1000.0f) + " ms; ";
  };
  uint8_t scalar[32];
  for (int i = 0; i < 32; i++) scalar[i] = i * 7 + 1;
  uint8_t point[133];

  // key agreement (one of these per handshake, twice: key pair + shared secret)
  time("x25519", 1, [&]() { br_ec_c25519_m31.mulgen(point, scalar, 32, BR_EC_curve25519); });
  time("p256", 1, [&]() { br_ec_p256_m31.mulgen(point, scalar, 32, BR_EC_secp256r1); });

  // RSA signature checks (public key ops, e = 65537): 2048 and 4096 bit
  static uint8_t n[512], x[512], e[3] = {1, 0, 1};
  for (int i = 0; i < 512; i++) n[i] = 0xC3 ^ i;
  n[0] = 0xF1;
  n[511] |= 1;
  br_rsa_public_key pk = {n, 256, e, 3};
  memset(x, 0x11, sizeof x);
  time("rsa2048", 2, [&]() { pk.nlen = 256; uint8_t t[256]; memcpy(t, x, 256); br_rsa_i31_public(t, 256, &pk); });
  time("rsa4096", 1, [&]() { pk.nlen = 512; uint8_t *t = (uint8_t *)malloc(512); memcpy(t, x, 512); br_rsa_i31_public(t, 512, &pk); free(t); });

  // bulk speed: what a 3 MB firmware download costs
  const size_t LEN = 8192;
  uint8_t *buf = (uint8_t *)heap_caps_malloc(LEN, MALLOC_CAP_8BIT);
  if (buf) {
    memset(buf, 0x5A, LEN);
    br_aes_ct_ctr_keys ctr;
    uint8_t key[16] = {1}, iv[12] = {2}, tag[16];
    br_aes_ct_ctr_init(&ctr, key, 16);
    br_gcm_context gcm;
    br_gcm_init(&gcm, &ctr.vtable, br_ghash_ctmul32);
    uint32_t t0 = micros();
    for (int i = 0; i < 4; i++) {
      br_gcm_reset(&gcm, iv, 12);
      br_gcm_flip(&gcm);
      br_gcm_run(&gcm, 0, buf, LEN);
      br_gcm_get_tag(&gcm, tag);
    }
    out += String("aes-gcm ") + (4.0f * LEN / ((micros() - t0) / 1e6f) / 1024) + " KB/s; ";
    br_sha256_context sha;
    br_sha256_init(&sha);
    t0 = micros();
    for (int i = 0; i < 8; i++) br_sha256_update(&sha, buf, LEN);
    br_sha256_out(&sha, tag);
    out += String("sha256 ") + (8.0f * LEN / ((micros() - t0) / 1e6f) / 1024) + " KB/s";
    free(buf);
  }
  return out;
}
