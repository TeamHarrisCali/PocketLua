// BearSSL client set up for discord.com only: TLS 1.2, ECDHE with AES-GCM or
// ChaCha20-Poly1305, RSA certificates. Only RSA suites are offered: Discord
// then sends its RSA chain (to GTS Root R1), whose signatures are far cheaper
// to check than the P-384 ECDSA one in its other chain (PC: 4.6 vs 13 ms of
// CPU; on the device that was the difference between ~5 and ~15 s). Linking just this (instead of
// br_ssl_client_init_full, which pulls in every suite, TLS 1.0, DES, ...)
// keeps the firmware smaller. Shared with the PC test of the connection.
#pragma once
#include "bearssl.h"

static void discordTlsInit(br_ssl_client_context *cc, br_x509_minimal_context *xc,
                           const br_x509_trust_anchor *tas, size_t ntas) {
  static const uint16_t suites[] = {BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                                    BR_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                                    BR_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384};
  br_ssl_client_zero(cc);
  br_ssl_engine_set_versions(&cc->eng, BR_TLS12, BR_TLS12);
  br_ssl_engine_set_suites(&cc->eng, suites, sizeof suites / sizeof *suites);
  // certificate checks (the chain is signed with ECDSA or RSA, SHA-256/384)
  br_x509_minimal_init(xc, &br_sha256_vtable, tas, ntas);
  br_x509_minimal_set_hash(xc, br_sha256_ID, &br_sha256_vtable);
  br_x509_minimal_set_hash(xc, br_sha384_ID, &br_sha384_vtable);
  br_x509_minimal_set_hash(xc, br_sha512_ID, &br_sha512_vtable);
  br_ssl_engine_set_default_rsavrfy(&cc->eng);
  br_ssl_engine_set_default_ecdsa(&cc->eng);
  br_x509_minimal_set_rsa(xc, br_ssl_engine_get_rsavrfy(&cc->eng));
  br_x509_minimal_set_ecdsa(xc, br_ssl_engine_get_ec(&cc->eng), br_ssl_engine_get_ecdsa(&cc->eng));
  br_ssl_engine_set_x509(&cc->eng, &xc->vtable);
  // the handshake and record layer
  br_ssl_engine_set_hash(&cc->eng, br_sha256_ID, &br_sha256_vtable);
  br_ssl_engine_set_hash(&cc->eng, br_sha384_ID, &br_sha384_vtable);
  br_ssl_engine_set_prf_sha256(&cc->eng, &br_tls12_sha256_prf);
  br_ssl_engine_set_prf_sha384(&cc->eng, &br_tls12_sha384_prf);
  br_ssl_engine_set_default_aes_gcm(&cc->eng);
  br_ssl_engine_set_default_chapol(&cc->eng);
}
