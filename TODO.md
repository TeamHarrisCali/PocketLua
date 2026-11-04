# LiveOS to-do

Open issues found on the device. Newest first.

- [ ] Recordings are clean but a little quiet (peak about 3500, average about 250 of 32767).
  If needed, raise the ES8311 preamp in `useMic` (`hw.cpp`, register 0x14) from 0x18
  (+24 dB) to 0x1A (+30 dB).
- [ ] Not yet verified on the device: IR codes, tilt directions (Marble, Air Mouse,
  Level), LoRa Chat and GPS with the Cap LoRa-1262.

## Done

- [x] **Mic recording** (fixed 2026-11-04, confirmed on the device). M5Unified's Mic read a
  constant value on IDF 5.5 once the speaker had used the shared I2S pins
  (espressif/esp-idf#18621). `hw.cpp` now drives the ES8311 and its own I2S RX channel.
  The same pass fixed playback crackle (`playTask` refilled the buffer that was still
  playing), the pop at record start, and clipping.
- [x] **Apps running out of memory with Wi-Fi on.** Lua has its own 84 KB arena reserved
  at boot before Wi-Fi (`vm::reserveArena`). The user confirmed Wi-Fi works.
