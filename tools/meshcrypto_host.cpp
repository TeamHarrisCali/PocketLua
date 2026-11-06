// PC build of src/meshcrypto.cpp, for the Mesh tests (tools/tests/mesh.lua
// builds it on first use).
//   meshcrypto_host selftest              the vectors in docs/MESHTASTIC.md
//   meshcrypto_host ctr KEY IV DATA       hex in, hex out
//   meshcrypto_host ccm-enc KEY NONCE DATA       -> ciphertext||tag
//   meshcrypto_host ccm-dec KEY NONCE DATA TAG   -> plaintext, or FAIL
//   meshcrypto_host pub PRIV | shared PRIV PUB | sha256 DATA
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>
#include "../src/meshcrypto.h"

using Bytes = std::vector<uint8_t>;

static Bytes unhex(const char *s) {
  Bytes b;
  for (size_t i = 0; s[i] && s[i + 1]; i += 2) {
    unsigned v;
    sscanf(s + i, "%2x", &v);
    b.push_back((uint8_t)v);
  }
  return b;
}
static std::string hex(const uint8_t *p, size_t n) {
  std::string s;
  char t[3];
  for (size_t i = 0; i < n; i++) { snprintf(t, sizeof t, "%02x", p[i]); s += t; }
  return s;
}
static std::string hex(const Bytes &b) { return hex(b.data(), b.size()); }

static int fails = 0;
static void check(bool ok, const char *what) {
  printf("%s %s\n", ok ? "ok:  " : "FAIL:", what);
  if (!ok) fails++;
}

static int selftest() {
  {  // RFC 3686 vectors, as in the firmware's test_AES_CTR
    Bytes k = unhex("776BEFF2851DB06F4C8A0542C8696F6C6A81AF1EEC96B4D37FC1D689E6C1C104");
    Bytes iv = unhex("00000060DB5672C97AA8F0B200000001");
    Bytes d((const uint8_t *)"Single block msg", (const uint8_t *)"Single block msg" + 16);
    meshcrypto::aesCtr(k.data(), k.size(), iv.data(), d.data(), d.size());
    check(hex(d) == "145ad01dbf824ec7560863dc71e3e0c0", "AES-256-CTR (RFC 3686)");
    k = unhex("AE6852F8121067CC4BF7A5765577F39E");
    iv = unhex("00000030000000000000000000000001");
    d.assign((const uint8_t *)"Single block msg", (const uint8_t *)"Single block msg" + 16);
    meshcrypto::aesCtr(k.data(), k.size(), iv.data(), d.data(), d.size());
    check(hex(d) == "e4095d4fb7a7b3792d6175a3261311b8", "AES-128-CTR (RFC 3686)");
  }
  {  // a channel packet with the default key (from 0x929, id 0x13b2d662)
    Bytes k = unhex("d4f1bb3a20290759f0bcffabcf4e6901");
    Bytes iv = unhex("62d6b213000000002909000000000000");
    Bytes d = unhex("08011204746573744800");
    meshcrypto::aesCtr(k.data(), k.size(), iv.data(), d.data(), d.size());
    check(hex(d) == "46f2ecd0b02ac4cf2be5", "default channel key, Meshtastic counter block");
  }
  {  // X25519, Wycheproof (the firmware's test_DH25519)
    Bytes pub = unhex("504a36999f489cd2fdbc08baff3d88fa00569ba986cba22548ffde80f9806829");
    Bytes priv = unhex("c8a9d5a91091ad851c668b0736c1c9a02936c0d3ad62670858088047ba057475");
    uint8_t out[32];
    check(meshcrypto::x25519Shared(priv.data(), pub.data(), out) &&
              hex(out, 32) == "436a2c040cf45fea9b29a0cb81b1f41458f863d0d61b453d0a982720d6d61320",
          "X25519 shared secret");
  }
  {  // PKI direct message (the firmware's test_PKC)
    Bytes priv = unhex("a00330633e63522f8a4d81ec6d9d1e6617f6c8ffd3a4c698229537d44e522277");
    Bytes pub = unhex("db18fc50eea47f00251cb784819a3cf5fc361882597f589f0d7ff820e8064457");
    Bytes frame = unhex("8c646d7a2909000062d6b2136b00000040df24abfcc30a17a3d9046726099e796a1c036a792b");
    uint8_t shared[32], key[32];
    meshcrypto::x25519Shared(priv.data(), pub.data(), shared);
    meshcrypto::sha256(shared, 32, key);
    check(hex(key, 8) == "777b1545c9d6f9a2", "PKI key = SHA-256(X25519)");
    const uint8_t *p = frame.data() + 16;
    size_t n = frame.size() - 16 - 12;
    uint8_t nonce[13] = {0};
    memcpy(nonce, frame.data() + 8, 4);        // id
    memcpy(nonce + 4, p + n + 8, 4);           // extra nonce, after the tag
    memcpy(nonce + 8, frame.data() + 4, 4);    // from
    check(hex(nonce, 13) == "62d6b213036a792b2909000000", "PKI nonce layout");
    Bytes d(p, p + n);
    bool ok = meshcrypto::ccmDecrypt(key, nonce, d.data(), d.size(), p + n);
    check(ok && hex(d) == "08011204746573744800", "PKI AES-256-CCM decrypt");
    Bytes e = unhex("08011204746573744800");
    uint8_t tag[8];
    meshcrypto::ccmEncrypt(key, nonce, e.data(), e.size(), tag);
    check(hex(e) + hex(tag, 8) == hex(p, n + 8), "PKI AES-256-CCM encrypt matches");
    Bytes bad(p, p + n);
    uint8_t badTag[8];
    memcpy(badTag, p + n, 8);
    badTag[0] ^= 1;
    check(!meshcrypto::ccmDecrypt(key, nonce, bad.data(), bad.size(), badTag), "PKI rejects a bad tag");
  }
  {  // public key from private key, both ways round
    Bytes a = unhex("a00330633e63522f8a4d81ec6d9d1e6617f6c8ffd3a4c698229537d44e522277");
    Bytes b = unhex("c8a9d5a91091ad851c668b0736c1c9a02936c0d3ad62670858088047ba057475");
    uint8_t pa[32], pb[32], s1[32], s2[32];
    meshcrypto::x25519Public(a.data(), pa);
    meshcrypto::x25519Public(b.data(), pb);
    meshcrypto::x25519Shared(a.data(), pb, s1);
    meshcrypto::x25519Shared(b.data(), pa, s2);
    check(memcmp(s1, s2, 32) == 0, "X25519 public keys agree");
  }
  printf("%d failure(s)\n", fails);
  return fails ? 1 : 0;
}

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  std::string op = argv[1];
  if (op == "selftest") return selftest();
  if (op == "ctr" && argc == 5) {
    Bytes k = unhex(argv[2]), iv = unhex(argv[3]), d = unhex(argv[4]);
    if (iv.size() != 16 || !meshcrypto::aesCtr(k.data(), k.size(), iv.data(), d.data(), d.size())) return 1;
    puts(hex(d).c_str());
  } else if (op == "ccm-enc" && argc == 5) {
    Bytes k = unhex(argv[2]), nonce = unhex(argv[3]), d = unhex(argv[4]);
    uint8_t tag[8];
    meshcrypto::ccmEncrypt(k.data(), nonce.data(), d.data(), d.size(), tag);
    puts((hex(d) + hex(tag, 8)).c_str());
  } else if (op == "ccm-dec" && argc == 6) {
    Bytes k = unhex(argv[2]), nonce = unhex(argv[3]), d = unhex(argv[4]), tag = unhex(argv[5]);
    puts(meshcrypto::ccmDecrypt(k.data(), nonce.data(), d.data(), d.size(), tag.data()) ? hex(d).c_str() : "FAIL");
  } else if (op == "pub" && argc == 3) {
    Bytes priv = unhex(argv[2]);
    uint8_t pub[32];
    meshcrypto::x25519Public(priv.data(), pub);
    puts(hex(pub, 32).c_str());
  } else if (op == "shared" && argc == 4) {
    Bytes priv = unhex(argv[2]), pub = unhex(argv[3]);
    uint8_t out[32];
    puts(meshcrypto::x25519Shared(priv.data(), pub.data(), out) ? hex(out, 32).c_str() : "FAIL");
  } else if (op == "sha256" && argc == 3) {
    Bytes d = unhex(argv[2]);
    uint8_t out[32];
    meshcrypto::sha256(d.data(), d.size(), out);
    puts(hex(out, 32).c_str());
  } else {
    return 2;
  }
  return 0;
}
