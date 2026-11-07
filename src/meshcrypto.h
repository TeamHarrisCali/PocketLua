// Crypto for the Mesh app (Meshtastic interop), on BearSSL. No Arduino code,
// so tools/meshcrypto_host.cpp builds the same file on the PC for the tests.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace meshcrypto {

// AES-CTR in place: 16- or 32-byte key, 16-byte counter block (the last 4
// bytes are the big-endian block counter).
bool aesCtr(const uint8_t *key, size_t keyLen, const uint8_t iv[16], uint8_t *buf, size_t len);

// AES-256-CCM in place, 13-byte nonce, 8-byte tag, no associated data.
// Decrypting returns false when the tag doesn't match.
void ccmEncrypt(const uint8_t key[32], const uint8_t nonce[13], uint8_t *buf, size_t len, uint8_t tag[8]);
bool ccmDecrypt(const uint8_t key[32], const uint8_t nonce[13], uint8_t *buf, size_t len, const uint8_t tag[8]);

// X25519 (RFC 7748 byte order). shared() returns false for an all-zero result.
void x25519Public(const uint8_t priv[32], uint8_t pub[32]);
bool x25519Shared(const uint8_t priv[32], const uint8_t pub[32], uint8_t out[32]);

void sha256(const uint8_t *data, size_t len, uint8_t out[32]);

}  // namespace meshcrypto
