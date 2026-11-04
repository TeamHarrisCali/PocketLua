# LiveOS to-do

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

- **Music, next steps** (the player works on the device as of `ab4037c`):
  - Background playback: keep playing on the desktop, with controls in the status bar. The decoding is
    native already; the queue and next-track logic would have to move out of the Music app's Lua.
  - The on-device "Rescan library" has not been tried on a real card yet.

## Done

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
