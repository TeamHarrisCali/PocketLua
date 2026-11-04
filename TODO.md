# LiveOS to-do

Open issues found on the device. Newest first.

- [ ] **Mic recording does not work** (Recorder app, reported 2026-11-04). Check the
  device log (`python3 tools/monitor.py`) while recording; suspects: mic not starting
  on the ADV's ES8311 codec (M5Unified `Mic.begin` after `internal_mic=true` + `Mic.end()`
  at boot), or the record task / SD streaming in `src/hw.cpp` (`au_record`, `recTask`).
- [ ] **Apps run out of memory with Wi-Fi on** although 70-88 KB is free: Wi-Fi
  fragments the heap (largest free block 5-12 KB). Plan: reserve a contiguous Lua arena
  at boot (before Wi-Fi) with its own allocator (`multi_heap_register`).
- [ ] Not yet verified on the device: IR codes, tilt directions (Marble, Air Mouse,
  Level), audio playback, LoRa Chat and GPS with the Cap LoRa-1262.
