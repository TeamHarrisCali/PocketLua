# LiveOS to-do

Open issues found on the device. Newest first.

- [ ] **Parked (user, 2026-11-04): firmware over USB** (`tools/deploy.sh`, `push.py send`). The code
  is in (`!fput` with a "+" per line, console input filtering) but has never been tested on the
  device; updates go through the card reader for now.
- [ ] USB drive sharing (Settings > USB) shows "No medium found" on the PC; not investigated.
- [ ] MP3 playback is built (`bc65456`) but not yet heard on the device.

- [ ] Mic preamp raised from +24 dB to +30 dB (`useMic` in `hw.cpp`, ES8311 register
  0x14 = 0x1A); the louder level needs a device test.
- [ ] Not yet verified on the device: IR codes, tilt directions (Marble, Air Mouse,
  Level), LoRa Chat and GPS with the Cap LoRa-1262.

## Planned

- **MP3 player, a nice one** (user request 2026-11-04, for another time). Plays MP3 and WAV
  from `/liveos/data/music`, with album and artist from ID3 tags, a queue, shuffle and repeat,
  resume where you left off, and playback that keeps going on the desktop with a status-bar
  control. Output goes to the speaker, or to the 3.5 mm jack as line out through the ES8311
  DAC (check whether the ADV switches the jack and speaker automatically or needs a register
  or amp-enable change). Memory: a fixed-point MP3 decoder (Helix) needs about 25–30 KB plus
  buffers, so decode in a task with fixed buffers and no Lua VM while playing in the
  background. When the player starts, it turns off services it doesn't need (Wi-Fi, NTP,
  roaming, ESP-NOW, the mic) to free RAM and CPU, and restores them when it closes.

## Done

- [x] **Mic recording** (fixed 2026-11-04, confirmed on the device). M5Unified's Mic read a
  constant value on IDF 5.5 once the speaker had used the shared I2S pins
  (espressif/esp-idf#18621). `hw.cpp` now drives the ES8311 and its own I2S RX channel.
  The same pass fixed playback crackle (`playTask` refilled the buffer that was still
  playing), the pop at record start, and clipping.
- [x] **Apps running out of memory with Wi-Fi on.** Lua has its own 84 KB arena reserved
  at boot before Wi-Fi (`vm::reserveArena`). The user confirmed Wi-Fi works.
