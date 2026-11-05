# PocketLua for the Cardputer ADV

A live-editable OS for the M5Stack Cardputer ADV. The C++ core owns the hardware and a Lua 5.4 VM; apps are Lua scripts you can edit on the device. (It began as "LiveOS": the card folder `/liveos/` is renamed to `/pocketlua/` at first boot.)

## Install

Flash it over USB with `pio run -t upload` (PlatformIO puts the running firmware into download mode by itself). This replaces whatever was on the device, M5Launcher included. The firmware is still a plain app image, so M5Launcher can also start `PocketLua.bin` from the SD card.

After that, firmware updates come from the **App Store**: the device restarts first (so the download has the memory it needs), writes the new build into the flash's spare app slot, checks it, and restarts into it. Channel switches work the same way. The new build is marked good after it has run for 10 s; if it crashes before that, the device goes back to the previous build and says so. Only a build newer than the running one is offered.

The firmware holds only the core: Settings, the App Store and the editor. Every other app comes from the **App Store**, which downloads from this repository's `release/` folder over HTTPS (BearSSL, checked against ISRG Root X1) with the store app closed, verifies each file's SHA-256, and keeps the previous copy. Nothing updates by itself: press C in the store to check, then choose.

On the card everything lives in `/pocketlua/` (renamed from `/liveos/` at first boot): `apps/<name>/main.lua` (+ `main.luac`, the bytecode that runs), `lib/`, `data/`.

## Release and Beta

There are two update channels, each a branch of this repository with its own `release/` folder:

- **Release** (`main`): the official builds.
- **Beta** (`beta`): what comes next, to test before it goes to Release.

A firmware is built for one channel and the App Store reads that channel. To change it, go to Settings > About > Updates. Joining Beta takes one confirmation; the device then installs the Beta firmware and the Beta version of every installed app, and restarts. Going back to Release warns first: it installs the older Release firmware and apps, and data written by Beta apps may not work with them. Apps that exist only in Beta stay installed.

## Publishing

Beta, from `development`:

```bash
pio run                    # a beta build (the firmware records the git commit and its channel)
python3 tools/release.py   # release/: catalog.txt, apps and libraries as source + bytecode, PocketLua.bin
git add release && git commit -m "Release (beta)" && git push origin development:beta
```

Release, once Beta has been tested:

```bash
git checkout main && git merge -X theirs beta
PL_CHANNEL=main pio run    # a Release build
python3 tools/release.py   # refuses a channel/branch mismatch
git add release && git commit -m "Release" && git push origin main && git checkout development
```

Store-only apps (not built into the firmware) go in `store/apps/`.

## Keys

| Key | Action |
|---|---|
| Fn + `;` `.` `,` `/` | Up, down, left, right. The bare keys also move in menus |
| Fn + `` ` `` | Esc: back (to the app that opened this one, or home) |
| G0 button | Home from anywhere |
| Fn+Q | Quick settings: brightness, volume, headphones, Wi-Fi, theme, sleep |
| Fn+N | Notification center |
| Fn+P | Screenshot, saved as a BMP in `data/screenshots` |
| Fn+L | Lock screen |
| Fn+`-` / Fn+`=` | Volume down / up, from anywhere |
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
- **Volume** moves in 20 even steps (2.5 dB). **Headphone mode** (Quick settings or Settings > Sound) keeps its own volume and stops at a maximum you set; the board can't sense the jack, so it is switched by hand.
- **Music**: equalizer presets (E on Now Playing), Tab between Now Playing and the lists, A / T for the song's album / artist.
- **Backup and restore** (Settings > Backup): settings, notes, app data and the scripts you made or edited go into one file in `/pocketlua/backups/` (the 5 newest are kept). Music, recordings, screenshots and App Store apps are left out. Restoring writes them back and restarts.

## Memory

The board has about 250 KB of usable RAM and no PSRAM. Only a small core is always loaded: the shell (app switching, keys, status bar, background services) and the UI toolkit. Everything else loads when opened and is freed when closed. That includes every app, the home screen, dialogs, icons, Settings pages and overlays. Built-in system code loads without debug info. Before opening an app or starting Wi-Fi (about 60 KB) the system frees what it can, and says so if there is still not enough. Task Manager shows memory, loaded modules and services.

## Live editing and recovery

Scripts are built into the firmware and can be overridden by files in `/pocketlua/` on the SD card. Saving in the editor writes the override, so a change takes effect at once, and in Files `X` on an "edited" file reverts it. If an edited system file fails to load, the built-in copy is used and you are told. A script that never returns is stopped after 2.5 s.

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
