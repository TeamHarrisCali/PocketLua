// BearSSL client setup for the update check (raw.githubusercontent.com):
// TLS 1.2, ECDHE key exchange, RSA certificates only (GitHub's chain is all
// RSA, whose signatures are cheap to check here: measured 0.17 s for 2048-bit
// and 0.8 s for 4096-bit, against seconds for P-384 ECDSA), ChaCha20 first
// (faster than constant-time AES in software). Shared with the PC test.
#pragma once
#include "bearssl.h"

static void httpsTlsInit(br_ssl_client_context *cc, br_x509_minimal_context *xc,
                         const br_x509_trust_anchor *tas, size_t ntas) {
  static const uint16_t suites[] = {BR_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                                    BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                                    BR_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384};
  br_ssl_client_zero(cc);
  br_ssl_engine_set_versions(&cc->eng, BR_TLS12, BR_TLS12);
  br_ssl_engine_set_suites(&cc->eng, suites, sizeof suites / sizeof *suites);
  br_x509_minimal_init(xc, &br_sha256_vtable, tas, ntas);
  br_x509_minimal_set_hash(xc, br_sha256_ID, &br_sha256_vtable);
  br_x509_minimal_set_hash(xc, br_sha384_ID, &br_sha384_vtable);
  br_x509_minimal_set_hash(xc, br_sha512_ID, &br_sha512_vtable);
  br_ssl_engine_set_default_rsavrfy(&cc->eng);
  br_ssl_engine_set_default_ecdsa(&cc->eng);
  br_x509_minimal_set_rsa(xc, br_ssl_engine_get_rsavrfy(&cc->eng));
  br_x509_minimal_set_ecdsa(xc, br_ssl_engine_get_ec(&cc->eng), br_ssl_engine_get_ecdsa(&cc->eng));
  br_ssl_engine_set_x509(&cc->eng, &xc->vtable);
  br_ssl_engine_set_hash(&cc->eng, br_sha256_ID, &br_sha256_vtable);
  br_ssl_engine_set_hash(&cc->eng, br_sha384_ID, &br_sha384_vtable);
  br_ssl_engine_set_prf_sha256(&cc->eng, &br_tls12_sha256_prf);
  br_ssl_engine_set_prf_sha384(&cc->eng, &br_tls12_sha384_prf);
  br_ssl_engine_set_default_chapol(&cc->eng);
  br_ssl_engine_set_default_aes_gcm(&cc->eng);
}
