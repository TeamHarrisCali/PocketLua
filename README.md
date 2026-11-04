# LiveOS for the Cardputer ADV

A live-editable OS for the M5Stack Cardputer ADV. The C++ core owns the hardware and a Lua 5.4 VM. The home screen, apps, settings and system UI are Lua scripts you can edit on the device.

## Install (M5Launcher)

Copy `dist/LiveOS.bin` to the SD card and launch it from M5Launcher. It is a plain app image, so Launcher is untouched. To flash directly instead, hold G0 while resetting and run `pio run -t upload`.

## Keys

| Key | Action |
|---|---|
| Fn + `;` `.` `,` `/` | Up, down, left, right. The bare keys also move in menus |
| Fn + `` ` `` | Esc: back (to the app that opened this one, or home) |
| G0 button | Home from anywhere |
| Fn+Q | Quick settings: brightness, volume, Wi-Fi, theme, sleep |
| Fn+N | Notification center |
| Fn+P | Screenshot, saved as a BMP in `sd:/screenshots` |
| Fn+L | Lock screen |
| Hold `S` at boot | Safe mode (built-in system only) |

**Home screen:** Tab switches category (All, System, Tools, Media, Games, Net), typing searches, Enter opens, Ctrl+E edits the app's source, and Ctrl+N creates a new app.

**Editor:** Ctrl+S save, Ctrl+R save and run, Ctrl+Z undo, Ctrl+C/X/V copy, cut and paste a line, Ctrl+K delete a line.

## Apps

| Category | Apps |
|---|---|
| System | Settings, Task Manager, Files, App Store |
| Tools | Clock (alarms, timer, stopwatch, Pomodoro), Notes and To-do, Calculator and unit converter, Lua REPL, Morse, Steps, Sensors (Grove I2C), Level, Hello |
| Media | Recorder, Music (WAV), Sound Lab (level, spectrum, tuner), Beat Box, Piano, Images |
| Games | Snake, Blocks, 2048, Marble (tilt maze), Adventure |
| Net | Weather, Network (scan, DNS, ping), IR Remote, Air Mouse, LoRa Chat, GPS, Nearby, USB Keys, USB Serial |

LoRa Chat and GPS need the Cap LoRa-1262. Air Mouse and USB Keys need Settings > USB > Mouse or Keyboard, followed by a reboot.

## OS features

- **Themes:** Slate, Midnight, Paper, Terminal and Sunset, plus an accent colour (Settings > Display). Every app uses the shared toolkit, so it follows the theme. See `docs/UI.md`.
- **Lock screen and display sleep:** set the sleep time in Settings > Display; any key wakes the screen.
- **Notifications:** apps, alarms, timers and the low-battery warning post to the notification center. A dot in the status bar means unread.
- **Background timers and daily alarms** keep running whichever app is open.
- **Resume:** apps remember where you were. Files open in the app that handles their type (`.txt`, `.lua` editor; `.wav` Music; `.bmp`, `.jpg`, `.png` Images).
- **System sounds** (Settings > Sound), a 12-hour clock option, and screenshots.

## Memory

The board has about 250 KB of usable RAM and no PSRAM. Only a small core is always loaded: the shell (app switching, keys, status bar, background services) and the UI toolkit. Everything else loads when opened and is freed when closed. That includes every app, the home screen, dialogs, icons, Settings pages and overlays. Built-in system code loads without debug info. Before opening an app or starting Wi-Fi (about 60 KB) the system frees what it can, and says so if there is still not enough. Task Manager shows memory, loaded modules and services.

## Live editing and recovery

Scripts are built into the firmware and can be overridden by files in `/liveos/` on the SD card. Saving in the editor writes the override, so a change takes effect at once, and in Files `X` on an "edited" file reverts it. If an edited system file fails to load, the built-in copy is used and you are told. A script that never returns is stopped after 2.5 s.

## USB (Settings > USB, applies after a reboot)

- **Keyboard / Mouse:** USB Keys types snippets or acts as a live keyboard. Air Mouse turns the gyro into a mouse.
- **Serial + log:** on by default. It streams the device log; read it with `python3 tools/monitor.py --seconds 15`.
- **Lua console:** type Lua in a terminal, or push files with `tools/push.py`:

  ```bash
  python3 tools/push.py put userland/apps/hello.lua apps/hello.lua --run hello
  ```
- **Drive:** Settings > USB > Share SD shows the card as a USB drive while that screen is open.

## Writing apps

See `docs/API.md` for the Lua API and `docs/UI.md` for the design rules. An app is one file in `userland/apps/` with a one-line header such as:

```lua
local app = { title = "Piano", icon = "piano", color = "purple", order = 30, category = "media" }
```

## Building and testing

```bash
uv tool install platformio        # once
pio run                           # builds .pio/build/cardputer-adv/firmware.bin
sh tools/run_tests.sh             # all headless test suites (desktop Lua 5.4 with stubbed hardware)
lua5.4 tools/mem_probe.lua        # Lua memory use of every app
```

`userland/` is embedded by `tools/gen_embed.py` before each build. `archive/lorachat/` holds the earlier standalone LoRa messenger.
