# PocketLua to-do

Open issues found on the device. Newest first.

- [ ] **Parked (user, 2026-11-04): firmware over USB** (`tools/deploy.sh`, `push.py send`). The code
  is in (`!fput` with a "+" per line, console input filtering) but has never been tested on the
  device; updates go through the card reader for now.
- [ ] USB drive sharing (Settings > USB) shows "No medium found" on the PC; not investigated.

- [ ] Mic preamp raised from +24 dB to +30 dB (`useMic` in `hw.cpp`, ES8311 register
  0x14 = 0x1A); the louder level needs a device test.
- [ ] Not yet verified on the device: IR codes, tilt directions (Marble, Air Mouse,
  Level), LoRa Chat and GPS with the Cap LoRa-1262.

## Planned

- **Flash space** was ~90% used (2026-11-04). If it runs short, compress the
  embedded sources: the device runs the bytecode, and only the editor reads the source, so about
  270 KB of it could shrink. Also check how large an app M5Launcher accepts.

- **App updates over the internet** (user idea, 2026-11-04; built as the App Store, see README): publish the apps on GitHub; on startup
  (with Wi-Fi) PocketLua checks a manifest and downloads new or changed apps to `/pocketlua/apps/`, so new apps
  and fixes don't need a new firmware. Only native changes (C++) would need a firmware update.
  Notes for the design:
  - Ship apps as precompiled bytecode (`.luac` from `tools/luac32`, built by a script or GitHub
    Actions), not source. Compiling on the device needs about 2x the RAM, which is why Music
    couldn't open until built-ins became bytecode. The loader would prefer `apps/x.luac` over `x.lua`.
  - The manifest lists each app with its version, size and SHA-256. Check it before replacing anything,
    and keep the previous copy to roll back if the new one fails to load.
  - HTTPS is the hard part: a Discord client (2026-11-04, abandoned) showed TLS barely fits next to
    Wi-Fi and a Lua app. mbedTLS needs two 16.7 KB buffers; BearSSL with one buffer connected, but its
    handshake took ~5-15 s of CPU on the device. Check for updates once at boot, before any app opens,
    or fetch the manifest over plain HTTP with SHA-256 hashes and only the downloads over HTTPS.
  - The bytecode format depends on the firmware's Lua build, so the manifest names the firmware
    versions an app needs.
  - The existing Store app may be the place for the UI.
- **Music:** the on-device "Rescan library" has not been tried on a real card yet. (Background
  playback outside the app: dropped by the user, because of the memory risk.)

## Done

- [x] **Discord client: abandoned by the user (2026-11-04).** Lessons are in the app-update note above
  and in memory.

- [x] **Music player** (2026-11-04, working on the device): MP3 with pause and seek, Now Playing, a
  library (Artists/Albums/Genres) indexed on the PC (`tools/music_library.py`) or on the device, shuffle,
  repeat, resume, and focus mode (Wi-Fi off while it runs). `tools/convert_music.py` makes MP3 copies.
- [x] **Fn+H key help** in every app (`app.help`).

- [x] **Mic recording** (fixed 2026-11-04, confirmed on the device). M5Unified's Mic read a
  constant value on IDF 5.5 once the speaker had used the shared I2S pins
  (espressif/esp-idf#18621). `hw.cpp` now drives the ES8311 and its own I2S RX channel.
  The same pass fixed playback crackle (`playTask` refilled the buffer that was still
  playing), the pop at record start, and clipping.
- [x] **Apps running out of memory with Wi-Fi on.** Lua has its own 84 KB arena reserved
  at boot before Wi-Fi (`vm::reserveArena`). The user confirmed Wi-Fi works.
