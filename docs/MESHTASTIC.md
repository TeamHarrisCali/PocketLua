# Mesh app: Meshtastic interop notes

Status (2026-11-06): research done, implementation started. Our own
implementation from the protocol, not a port of the (GPL) firmware.

Scope the user chose: a Meshtastic-compatible app with channel chat, node
list, direct messages and position sharing.

Facts below were checked against meshtastic/firmware `master` (2.7.27, the
stable line) and meshtastic/protobufs `master`. 2.8 (develop, and what the docs
now describe) adds optional features, all off by default. Sources are the
firmware's `src/mesh/` unless stated. The PKI test vector and the AES-CTR layout
were re-verified with standard crypto: plain X25519, SHA-256, AES-256-CCM and
AES-CTR, with nothing custom.

## Done so far

- `userland/lib/protobuf.lua`: protobuf wire codec (uint, bool, int32 with
  10-byte negatives, fixed32/sfixed32, bytes). It is 32-bit safe for the
  device's `LUA_32BITS` Lua.
- `tools/tests/mesh.lua`: codec tests. All pass on PC Lua and on a 32-bit build
  of `lib/lua`, built with the commands below.
- BearSSL (`lib/bearssl`, already linked for HTTPS) has everything needed:
  `br_aes_ct_ctr`, `br_ccm_*`, `br_ec_c25519_m15`/`i15`, and `br_sha256`.

Build the 32-bit test Lua like this (`main32.c` opens base/string/table/math
and adds `os.exit`):

    gcc -O1 -w -DLUA_USE_LINUX -Ilib/lua/src -o lua32 main32.c lib/lua/src/*.c -lm -ldl

## Plan (remaining)

1. **Native layer** (hw.cpp `lora` lib plus a new `crypto` hw lib):
   - Extend `lora.begin` to take an options table: bw, sf, cr, sync 0x2B,
     preamble 16, power, and a TCXO 1.8 V attempt with crystal fallback.
     Keep positional args for LoRa Chat.
   - Make `lora.send`/`lora.recv` binary-safe. Today they go through Arduino
     `String`, which breaks on a NUL byte. Switch them to byte buffers.
   - Add `crypto.aes_ctr(key, iv, data)` and `crypto.ccm(encrypt, key,
     nonce13, data, taglen 8)`, plus `crypto.x25519(priv, pub)`,
     `crypto.keypair()`, `crypto.sha256(s)` and `crypto.random(n)`.
2. **`userland/lib/meshtastic.lua`**:
   - Header pack/unpack, channel hash, default key / PSK expansion, djb2
     frequency.
   - Data/User/Position/Routing encode and decode, and PKI wrap/unwrap.
   - Duplicate history.
   - Tests use the vectors below.
3. **App `userland/apps/mesh.lua`**, with tabs Chat / Nodes / DMs / Setup.
   - It acts as role CLIENT_MUTE (1), so it never relays.
   - hw_model is PRIVATE_HW (255).
   - The node DB, messages and keys live under `data/` (the private key is
     generated once and stored there).
   - NodeInfo goes out 30 s after start, then every 3 h, and in reply to
     want_response requests.
   - Position comes from the cap's GPS, with precision 13 bits on the
     primary channel.
4. **Test on the device:** receive LongFast traffic first, then send.

## 1. Radio (US, LongFast default)

- **Begin call:** `begin(freq, bw, sf, cr, 0x2B, power, preamble 16, tcxo, false)`.
  - CR is the denominator (5 = 4/5).
  - Explicit header, CRC on, IQ not inverted.
  - LDRO is on when 2^SF/BW(kHz) >= 16 ms. That is off for LongFast and on
    for LongSlow and LongModerate.
- **SX1262 settings:**
  - OCP 140 mA, DC-DC regulator.
  - The firmware sets bit 0 of register 0x8B5 (an RX sensitivity patch).
  - RX boosted gain is optional.
- **Cardputer ADV pins** (the firmware has a variant for it):
  - CS=5, SCK=40, MISO=39, MOSI=14, RESET=3, DIO1=4, BUSY=6.
  - DIO2 is the RF switch; DIO3 drives a 1.8 V TCXO, which is optional
    (fall back to 0 V).
  - GPS on RX=15, TX=13 at 115200 baud.
- **US power:** the limit is 30 dBm, and the SX1262 clamps it to 22 dBm.
- **Presets** (BW kHz / SF / CR, the name that gets hashed, and the US default
  frequency in MHz):

  | Preset | BW | SF | CR | Name hashed | US freq |
  |---|---|---|---|---|---|
  | LONG_FAST 0 | 250 | 11 | 5 | LongFast | 906.875 |
  | LONG_SLOW 1 | 125 | 12 | 8 | LongSlow | 905.3125 |
  | MEDIUM_SLOW 3 | 250 | 10 | 5 | MediumSlow | 914.875 |
  | MEDIUM_FAST 4 | 250 | 9 | 5 | MediumFast | 913.125 |
  | SHORT_SLOW 5 | 250 | 8 | 5 | ShortSlow | 920.625 |
  | SHORT_FAST 6 | 250 | 7 | 5 | ShortFast | 918.875 |
  | LONG_MODERATE 7 | 125 | 11 | 8 | "LongMod" | 902.6875 |
  | SHORT_TURBO 8 | 500 | 7 | 5 | ShortTurbo | 926.75 |
  | LONG_TURBO 9 | 500 | 11 | 8 | LongTurbo | 908.75 |

## 2. Frequency

- **US region:** 902.0–928.0 MHz, spacing 0.
- **Channel count:** `numChannels = floor(26 / (bw/1000))`, which is 104 at
  BW 250.
- **Name hash:** djb2 over the name's bytes, uint32: start with `h = 5381`, then
  `h = h*33 + c` for each byte.
- **Which name:** the primary channel's name. If it's empty, the preset's
  display name ("LongFast").
- **Slot:** `slot0 = (channel_num ? channel_num - 1 : djb2(name)) % numChannels`.
  channel_num is 1-based, and 0 means use the hash.
- **Frequency:** `freq = 902.0 + bw/2000 + slot0 * bw/1000`.
- **Worked example:** djb2("LongFast") = 0x07C63403 = 130429955, and mod 104
  that is 19. So freq = 902.125 + 19 × 0.25 = **906.875**, which is the docs'
  "slot 20".

## 3. Frame

The 16-byte header is little-endian:

| Offset | Field |
|---|---|
| 0x00 | to (u32) |
| 0x04 | from (u32) |
| 0x08 | id (u32) |
| 0x0C | flags |
| 0x0D | channel hash (0 for PKI) |
| 0x0E | next_hop (u8) |
| 0x0F | relay_node (u8) |
| 0x10 | encrypted payload |

- **Flags byte:** bits 0–2 are hop_limit, 0x08 is want_ack, 0x10 is via_mqtt,
  and bits 5–7 are hop_start.
- **Last-byte fields:** next_hop and relay_node take the node number's last
  byte (0xFF if that byte is 0). Ignore them when hop_start is 0 (old
  firmware).
- **Broadcast address:** 0xFFFFFFFF.
- **Size limits:**
  - The whole frame is at most 255 bytes, so the payload is at most 239.
  - Plaintext is at most 239 for a channel packet and 227 for PKI.
  - `Data.payload` is at most 233.
- **Flags values we originate:** a DM with want_ack and hop 3 is 0x6B. A
  broadcast is 0x63 (want_ack is cleared on broadcasts).

## 4. Channel encryption

- **Cipher:** AES-CTR. A 16-byte key means AES-128, and 32 bytes means AES-256.
- **Default key** (PSK index 1, "AQ=="): `d4f1bb3a20290759f0bcffabcf4e6901`.
- **Key expansion:**
  - A single byte 0 means no encryption.
  - A single byte N from 1 to 10 means the default key with N−1 added to its
    last byte.
  - 2–15 bytes are zero-padded to 16; 17–31 bytes are zero-padded to 32.
  - A secondary channel with an empty PSK uses the primary's key.
- **IV (16 bytes):**

  | Bytes | Content |
  |---|---|
  | 0–7 | packet id, u64 LE (bytes 4–7 are 0) |
  | 8–11 | from, u32 LE |
  | 12–15 | counter, big-endian, starting at 0 |

  This is the same as standard CTR.
- **What is encrypted:** the encoded `Data` protobuf.
- **Channel hash:** XOR of the name's bytes, then XOR of the expanded key's
  bytes. Values with the default key:

  | Channel | Hash |
  |---|---|
  | LongFast | 0x08 |
  | MediumFast | 0x1F |
  | LongSlow | 0x0F |
  | ShortFast | 0x70 |

  A receiver tries each channel whose hash matches. A protobuf that fails to
  decode, or a portnum of 0, means wrong key.
- **Test vectors:**
  - **AES-256 (RFC 3686):**
    - key `776BEFF2851DB06F4C8A0542C8696F6C6A81AF1EEC96B4D37FC1D689E6C1C104`
    - IV `00000060DB5672C97AA8F0B200000001`
    - plaintext "Single block msg"
    - ciphertext `145AD01DBF824EC7560863DC71E3E0C0`
  - **AES-128:**
    - key `AE6852F8121067CC4BF7A5765577F39E`
    - IV `00000030000000000000000000000001`
    - same plaintext
    - ciphertext `E4095D4FB7A7B3792D6175A3261311B8`
  - **Meshtastic layout** (computed during research, not from the firmware
    repo):
    - default key, from 0x00000929, id 0x13b2d662
    - IV `62d6b213000000002909000000000000`
    - plaintext `08011204746573744800`
    - ciphertext `46f2ecd0b02ac4cf2be5`
- **2.8 only:** a per-channel `use_aead` (AES-CCM) option, off by default.
  Ignore it.

## 5. PKI direct messages

- **Key:** `X25519(my_priv, their_pub)`, then `key = SHA-256(shared)`, giving
  AES-256-CCM. Reject an all-zero shared secret.
- **CCM:** tag 8 bytes, L = 2, a 13-byte nonce, and **no AAD**.
- **Nonce (13 bytes):**

  | Bytes | Content |
  |---|---|
  | 0–3 | id, u32 LE |
  | 4–7 | extraNonce (4 random bytes, as on air) |
  | 8–11 | from, u32 LE |
  | 12 | 0x00 |

- **On-air payload:** `ciphertext ‖ tag(8) ‖ extraNonce(4)`, and the channel
  hash byte is 0.
- **Receive:** try PKI when the channel byte is 0, the packet is to us
  (unicast), we know the sender's key, and the length is over 12.
- **Send:** use PKI for unicast packets from us, except portnums 70, 4, 5 and
  3, which stay on the channel key. If we don't know the destination's key,
  don't send.
- **Critical:** stable firmware **drops channel-encrypted text DMs** ("Rejecting
  legacy DM"), so text DMs must be sent with PKI.
- **Keys:**
  - Public keys arrive in `User.public_key` (field 8) inside NODEINFO.
    Firmware keeps the first key it hears for a node.
  - A want_ack PKI packet sent to a node that lacks our key comes back as a
    NAK with PKI_UNKNOWN_PUBKEY (35). Answer that by sending our NodeInfo.
- **Test vector** (firmware `test/test_crypto`, re-verified):
  - priv `a00330633e63522f8a4d81ec6d9d1e6617f6c8ffd3a4c698229537d44e522277`
  - remote pub `db18fc50eea47f00251cb784819a3cf5fc361882597f589f0d7ff820e8064457`
  - from 0x0929, id 0x13b2d662
  - first 8 bytes of SHA-256(shared) = `777b1545c9d6f9a2`
  - frame `8c646d7a2909000062d6b2136b00000040df24abfcc30a17a3d9046726099e796a1c036a792b`
  - nonce `62d6b213036a792b2909000000`
  - plaintext `08011204746573744800`
- **X25519 (Wycheproof):**
  - pub `504a36999f489cd2fdbc08baff3d88fa00569ba986cba22548ffde80f9806829`
  - priv `c8a9d5a91091ad851c668b0736c1c9a02936c0d3ad62670858088047ba057475`
  - shared `436a2c040cf45fea9b29a0cb81b1f41458f863d0d61b453d0a982720d6d61320`
- **2.8 only:** an XEdDSA signature (Data field 10) and `Routing.ack_proof`
  (field 4) are optional. Ignore them on receive.

## 6. Protobufs

- **Data:**

  | # | Field | Type |
  |---|---|---|
  | 1 | portnum | varint |
  | 2 | payload | bytes |
  | 3 | want_response | bool |
  | 4 | dest | fixed32 |
  | 5 | source | fixed32 |
  | 6 | request_id | fixed32 |
  | 7 | reply_id | fixed32 |
  | 8 | emoji | fixed32 |
  | 9 | bitfield | uint32 |
  | 10 | xeddsa_signature | bytes |

  Always send the **bitfield**, even as 0: its bit 0 is ok_to_mqtt and bit 1
  want_response, and receivers trust hop_start only when it is present.
- **User:**

  | # | Field | Type / limit |
  |---|---|---|
  | 1 | id | "!xxxxxxxx" |
  | 2 | long_name | ≤ 39 bytes |
  | 3 | short_name | ≤ 4 bytes |
  | 4 | macaddr | deprecated |
  | 5 | hw_model | enum |
  | 6 | is_licensed | bool |
  | 7 | role | enum |
  | 8 | public_key | 32 bytes |
  | 9 | is_unmessagable | bool |

- **Position:**

  | # | Field | Type |
  |---|---|---|
  | 1 | latitude_i | sfixed32, degrees × 1e7 |
  | 2 | longitude_i | sfixed32 |
  | 3 | altitude | int32, m |
  | 4 | time | fixed32, unix seconds |
  | 5 | location_source | enum: 0 unset, 1 manual, 2 internal, 3 external |
  | 6 | altitude_source | |
  | 7 | timestamp | fixed32 |
  | 14 | gps_accuracy | |
  | 15 | ground_speed | |
  | 16 | ground_track | |
  | 19 | sats_in_view | |
  | 23 | precision_bits | |

- **Position precision p:** set `v & (0xFFFFFFFF << (32-p))`, add
  `1 << (31-p)`, and send `precision_bits = p`. The default primary channel
  uses p = 13.
- **Routing:**
  - Fields 1 (route_request) and 2 (route_reply) are RouteDiscovery; field 3 is
    error_reason. These three are a oneof.
  - Field 4 is ack_proof.
  - An ACK's payload is `18 00`.
  - Error values:
    - 0 NONE, 1 NO_ROUTE, 2 GOT_NAK, 3 TIMEOUT, 4 NO_INTERFACE
    - 5 MAX_RETRANSMIT, 6 NO_CHANNEL, 7 TOO_LARGE, 8 NO_RESPONSE
    - 9 DUTY_CYCLE_LIMIT, 32 BAD_REQUEST, 33 NOT_AUTHORIZED, 34 PKI_FAILED
    - 35 PKI_UNKNOWN_PUBKEY, 38 RATE_LIMIT_EXCEEDED, 39 PKI_SEND_FAIL_PUBLIC_KEY
- **PortNum values:** TEXT 1, POSITION 3, NODEINFO 4, ROUTING 5, TELEMETRY 67,
  TRACEROUTE 70. The value 0 means decryption failed.
- **Identity:**
  - hw_model: PRIVATE_HW = 255 is meant for DIY ports. M5STACK_CARDPUTER_ADV =
    112 would claim stock firmware.
  - Role values: CLIENT 0, CLIENT_MUTE 1, ROUTER 2, TRACKER 5, SENSOR 6,
    CLIENT_HIDDEN 8, CLIENT_BASE 12.

## 7. Node number

- **How it's made:** the last 4 bytes of the MAC, big-endian
  (`MAC[2]<<24 | … | MAC[5]`).
- **Values to avoid:** 0–3 and 0xFFFFFFFF.
- **ID format:** `"!%08x"`, lowercase.
- **Default names:** long name "Meshtastic %04x" and short name "%04x", both
  from `nodeNum & 0xFFFF`.
- **2.8:** derives the number from crc32(public key), but receivers don't
  enforce it.

## 8. Mesh behaviour

- **Hops:**
  - hop_limit defaults to 3, with a maximum of 7.
  - The originator sets hop_start = hop_limit.
  - hopsAway = hop_start − hop_limit.
- **Packet ID:** non-zero. The low 10 bits are a counter seeded randomly; the
  high 22 bits are random.
- **Duplicates:** keep an LRU of (from, id), at least 100 entries, and include
  the packets we send ourselves.
- **Relaying:**
  - CLIENT_MUTE never relays, which is fine for a handheld.
  - Before originating, back off by `rand(0, 2^CW)` slots (a slot is about
    28 ms on LongFast) and listen first with CAD.
- **Implicit ACK and retries:**
  - Hearing someone else rebroadcast our packet (same from and id) counts as
    an ACK.
  - Up to 3 transmissions in total.
  - Retry delay is about `2*airtime + (2^CW + 2*CWmax + 2^((CWmax+CWmin)/2))*slot + 4500 ms`,
    with CWmin 3 and CWmax 8.
- **ACKs for a DM to us:**
  - Reply to the original `from` with ROUTING (5) and payload `18 00`, with
    `request_id` set to the original id and the bitfield included.
  - Send it channel-encrypted on the channel it arrived on; a PKI DM counts as
    the primary channel.
  - hop_limit is hopsAway + 2 (0 if the request's hop_start was 0, capped at 3).
  - Stable firmware sends text-DM ACKs with want_ack. If such an ACK reaches
    us directly (hopsAway 0), answer it with a 0-hop ACK.
  - On 2.8, ACKs may arrive PKI-encrypted, so try PKI on ROUTING packets too.
- **NodeInfo:**
  - Broadcast it 30 s after start, then every 3 h, always channel-encrypted.
  - Firmware that hears an unknown node DMs it its NodeInfo with
    want_response. Reply with ours, want_response false.
  - Don't resend within 10 min.
- **Airtime:** the US has no duty-cycle limit. Skip optional TX when the
  channel is busy.

## Unverified

- The 2.8 CRC-32 variant used for node numbers.
- The traceroute reply format beyond its fields.
- ACKs with want_ack, checked on master and develop only.
