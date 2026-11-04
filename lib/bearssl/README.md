# BearSSL

BearSSL by Thomas Pornin (MIT license, see `src/LICENSE.txt`), as bundled in
arduino-libraries/ArduinoBearSSL. Used by `src/discord.cpp` for TLS because it
needs one 16.7 KB buffer and allocates nothing while connected; the core's
mbedTLS client did not fit in RAM next to Wi-Fi and a Lua app. The setup is in
`src/discord_tls.h`, and the trust anchors in `src/discord_ta.h` come from
`tools/gen_trust_anchors.py`.
