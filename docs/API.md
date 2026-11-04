# LiveOS Lua API

Apps are Lua 5.4 files in `userland/apps/<name>.lua`. Numbers are 32-bit (floats are single precision), and there is no `io`, `os` or `debug` library.

## App structure

```lua
-- Clock: alarms, timers, stopwatch and Pomodoro.
local col = ui.col
local app = { title = "Clock", icon = "clock", color = "orange", order = 20, category = "tools" }

function app.init(args, saved) end   -- args from shell.launch, saved from app.save()
function app.update(dt) end          -- once per frame (~30 fps); change state here
function app.draw() end              -- once per screen band; draw only, no state changes
function app.key(k) return true end  -- true = handled; return false for Esc to go home
function app.save() return {} end    -- optional: small state to resume later
function app.close() end             -- optional: release hardware and memory

return app
```

**Keys.** `k.key` is the key name ("a", "enter", "esc", "backspace", "delete", "tab", "space", "up", "down", "left", "right"). `k.text` is the typed character, if any. `k.ctrl`, `k.shift`, `k.fn` and `k.alt` are the modifiers.

**Errors.** Any error in an app shows the error screen, from which the user can edit the app. A call that takes longer than 2.5 s is stopped.

## System

| Call | Returns / does |
|---|---|
| `sys.millis()` | Milliseconds since boot |
| `sys.heap()` | Free bytes, Lua bytes, largest block, total |
| `sys.battery()` | Percent, charging |
| `sys.read_text(path[, max])` | File contents or `nil`. Paths are LiveOS-relative (`data/x.txt`, stored in `/liveos/` on the card); write only there, `sd:/...` is for reading the user's own files |
| `sys.write_text(path, s)` | Writes atomically (temp file, then rename) |
| `sys.append_text(path, s)` | Appends without reading the file (logs, tracks) |
| `sys.rename(from, to)` | Moves a file, replacing the destination |
| `sys.list(dir)` | Directory listing |
| `sys.list_names(dir [, "mp3,wav" [, max]])` | Sorted names as plain strings, folders first with a `/` suffix, files limited to the given extensions, at most `max` entries. Far smaller than `sys.list` for big folders |
| `sys.exists(path)`, `sys.remove(path)`, `sys.mkdirs(path)`, `sys.storage()` | File helpers and storage info |
| `sys.display_hold(on)` | Stop redrawing so the app can draw with `disp.*` |
| `sys.screenshot(path)` | Save a screenshot |
| `sys.reboot()`, `sys.reload()`, `sys.log(s)` | Restart, reload the Lua system, write to the device log |
| `cfg.get(key)`, `cfg.set(key, value or nil)` | Persistent string settings. Keys are 15 characters at most; prefix them with your app name |
| `clock.now()` | `{valid, h, m, s, year, month, day, wday}` |
| `shell.format_time(t)` | Time in the user's 12- or 24-hour format |

## Drawing (`gfx`)

| Call | Draws |
|---|---|
| `rgb(r, g, b)` | Returns a colour value |
| `clear(c)`, `px(x, y, c)` | Whole screen, one pixel |
| `line(x0, y0, x1, y1, c)` | Line |
| `rect` / `fill(x, y, w, h, c)` | Rectangle outline / filled |
| `rrect` / `rfill(x, y, w, h, r, c)` | Rounded rectangle outline / filled |
| `circle` / `disc(x, y, r, c)` | Circle outline / filled |
| `tri(x0, y0, x1, y1, x2, y2, c)` | Filled triangle |
| `arc(x, y, r0, r1, a0, a1, c)` | Filled arc |
| `text(x, y, s, c, size)`, `text_w(s, size)` | Text, text width |
| `clip(x, y, w, h)`, `noclip()` | Clipping rectangle |
| `brightness(0-255)` | Backlight |

Use the `ui.*` toolkit (see `docs/UI.md`) rather than raw drawing where possible.

## Sound and audio

| Call | Does |
|---|---|
| `snd.tone(freq, ms)`, `snd.stop()`, `snd.volume(0-255)` | Simple tones; a new tone replaces the current one; the volume also applies to `audio.play` |
| `shell.sound(kind)` | System sounds: "notify", "error", "alarm", "boot", "low" |
| `audio.record(path[, rate=16000])` | Record WAV to a file. Returns true/false |
| `audio.play(path [, seconds])` | Play an MP3 or a 16-bit PCM WAV, optionally from a position (MP3 is mixed to mono and needs about 47 KB of RAM: use `shell.focus(true)`). Returns true, or false and a reason |
| `audio.pause(on)`, `audio.seek(seconds)` | Pause/resume and jump within the playing track; `audio.status()` then reports "paused" |
| `audio.tags(path)` | `{title, artist, album, track}` from the file's ID3 tag (missing fields left out) |
| `musiclib.info()`, `.rows(kind, first, n)`, `.item(kind, i)`, `.albums_in(first, count)` | The music library index built by `tools/music_library.py` (see `src/musiclib.cpp`); `info()` is nil without one |
| `musiclib.scan([full])`, `musiclib.scan_status()` | Rebuild that index on the device in the background (new files are read, known ones reused; `full` re-reads all). Status: "reading"/"sorting"/"writing"/"done"/"failed", track count, message. Stop playback first |
| `audio.stop()` | Stop recording or playback |
| `audio.status()` | "idle", "recording" or "playing"; seconds done; seconds total |
| `audio.analyze()` | Listens for ~32 ms: level and peak (linear, 0-1 of full scale), pitch in Hz (0 = none), and 8 band amplitudes (0-1) centred on 100, 180, 320, 560, 1000, 1700, 2800 and 4000 Hz |

The mic and speaker cannot run at the same time; the drivers switch between them. Call `audio.stop()` in `close()`.

## Sensors and I/O

| Call | Does |
|---|---|
| `imu.read()` | `{ax, ay, az, gx, gy, gz}` (g and deg/s) |
| `ir.send(proto, addr, cmd[, repeats[, bits]])` | Send an IR code. `proto`: nec, samsung, sony, lg, rc5, panasonic |
| `i2c.scan()` | Array of addresses on the Grove port |
| `i2c.read(addr, n)`, `i2c.write(addr, bytes)` | Raw read and write |
| `i2c.read_reg(addr, reg, n)`, `i2c.write_reg(addr, reg, bytes)` | Register read and write |
| `usb.type(s)`, `usb.key("ctrl+c")` | USB keyboard (enabled in Settings > USB) |
| `usb.mouse_move(dx, dy[, wheel])`, `usb.mouse_click("left")`, `usb.mouse_press(btn, down)` | USB mouse (enabled in Settings > USB) |
| `usb.status()` | `{keyboard, mouse, drive, serial, connected}` |

## Network

| Call | Does |
|---|---|
| `wifi.status()` | "off", "idle", "connecting", "connected" or "failed" |
| `wifi.scan_start()`, `wifi.scan_result()` | Scan; results are `{ssid, rssi, secure, channel, bssid}`, or nil while scanning |
| `shell.wifi_start([ssid, pass])` | Turn Wi-Fi on. It checks memory first and reports problems |
| `shell.focus(true)` | Focus mode: turn Wi-Fi (and NTP and roaming) off while this app is open, to free RAM and CPU. It comes back on when the app closes |
| `http.get(url[, max_bytes=8192])` | Body and status, or nil and an error. Plain http only |
| `http.download(url, path[, max])` | Streams straight to a file (no RAM copy): bytes, status, or nil and an error |
| `http.dns(host)`, `http.ping(host[, port])` | IP address; TCP connect time in ms |
| `lora.begin([freq=915, sf=9, power=14])` | Start the Cap LoRa-1262. Returns true, or false and an error |
| `lora.send(s)`, `lora.recv()` | Send; receive `{data, rssi, snr}` or nil. Call `recv()` every frame |
| `lora.busy()`, `lora.stop()` | Transmit in progress; shut the radio down |
| `gps.start()`, `gps.read()`, `gps.stop()` | GPS on the Cap LoRa-1262. `read()` gives `{valid, lat, lon, alt, sats, hdop, speed, course, time, date, chars}` |
| `dev.mount(name)` | Use another LiveOS device's hardware (see lib/dev.lua) |

## Shell services

| Call | Does |
|---|---|
| `shell.launch(name[, args])`, `shell.home()` | Open an app; go home |
| `shell.edit(path)`, `shell.open_file(path)` | Open a file in the editor; open it with the app for its extension |
| `shell.toast(msg[, secs])` | Short message |
| `shell.notify(title[, body])` | Message kept in the notification center |
| `shell.alert(title, msg[, cb])`, `shell.confirm(title, msg, cb)` | Information; yes/no |
| `shell.prompt(title, default, cb[, {secret=true}])`, `shell.menu(title, items, cb)` | Text input; choose from a list |
| `shell.start_timer(seconds, label)` | Background countdown. Returns a handle (`left`, `total`, `label`, optional `done` callback); fires a notification and alarm sound |
| `shell.cancel_timer(handle)`, `shell.timers` | Cancel a timer; list of running timers |
| `cfg "alarms"` | Daily alarms as `"HH:MM\|label;HH:MM\|label"`. The shell checks them every minute |
| `shell.clipboard` | Shared text clipboard |
| `shell.free_memory()` | Drop caches and collect garbage. Returns free bytes |

**Memory.** About 50 KB is free while an app runs with Wi-Fi on, and about 110 KB with it off. Keep tables small, free big data in `close()`, and avoid building strings in `draw()`.
