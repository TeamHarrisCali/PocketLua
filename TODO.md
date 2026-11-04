# LiveOS to-do

Open issues found on the device. Newest first.

- [ ] **Mic recording does not work** (Recorder app, reported 2026-11-04). Fix attempted,
  needs a device test: UART0 is no longer started (its TX pin GPIO43 is the mic's I2S
  word-select line on the ADV), the record/play tasks get 8 KB of stack, and the log now
  shows `mic begin ok/FAILED` and `recording done: N samples`.
- [ ] **Apps run out of memory with Wi-Fi on** (heap fragmented by Wi-Fi). Fix attempted,
  needs a device test: Lua now has its own 84 KB arena reserved at boot before Wi-Fi
  (`vm::reserveArena`, `multi_heap_register`); the log shows `arena_free=`.
- [ ] Not yet verified on the device: IR codes, tilt directions (Marble, Air Mouse,
  Level), audio playback, LoRa Chat and GPS with the Cap LoRa-1262.
