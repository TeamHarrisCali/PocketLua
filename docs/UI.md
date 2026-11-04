# PocketLua design guide

Every screen uses the toolkit in `userland/lib/ui.lua`, so apps look like one system and follow the user's theme (Settings > Display > Theme) and accent colour. Don't hard-code colours: use `ui.col`.

## Screen layout (240×135)

| Area | Rows | Owner |
|---|---|---|
| Status bar | y 0–13 | The shell draws it. Its title is `app.title` |
| Content | y 16–122 | The app |
| Footer | y 124–134 | The app, with `ui.footer` |

- Keep a 4 px side margin.
- Text is 6×8 px per character at size 1, so 40 characters per line at most.
- Row heights: lists use 15–17 px rows, dialogs and menus use 12–13 px.

## Colours (`ui.col`)

| Token | Use |
|---|---|
| `bg` | Screen background |
| `surface` | Cards, bars, unselected tabs |
| `surface2` | Raised or selected items, keycaps, empty bar track |
| `line` | Dividers, scrollbars |
| `text` | Primary text |
| `muted` | Secondary text, labels, hints |
| `accent` | Focus, selection, the one important thing on screen |
| `on_accent` | Text drawn on an accent fill |
| `good` / `warn` / `bad` | Status only (OK / caution / error) |

The old names (`panel`, `panel2`, `dim`, `bar`) still work, but use the tokens above in new code.

## Components

| Function | Use for |
|---|---|
| `ui.footer({ {"Enter","Open"}, {"Esc","Back"} })` | Key hints, drawn as keycaps. Every screen has one; at most 4 hints; the most important first |
| `ui.list(rows, sel, top, x, y, w, rowh, n)` | Any vertical choice. The selected row is raised with an accent bar. Rows are tables (`label`, plus optional `value`, `badge`, `switch`, `dim`) or plain strings. Only visible rows are read, so long lists are cheap |
| `ui.tabs(labels, active, y)` | Switching between modes of one app (Clock: Alarm, Timer, Stopwatch). Tab / Shift+Tab move between them. Returns the y below the tabs |
| `ui.card(x, y, w, h, selected)` | Grouping a block of info. Selected cards get an accent outline |
| `ui.big(y, text, colour, size)` | One dominant number: a clock, a result, a level |
| `ui.bar(x, y, w, h, frac, colour)` | Progress and levels |
| `ui.switch(x, y, on)` | On/off state |
| `ui.button(x, y, label, focused)` | A command on a form; returns its width |
| `ui.title(x, y, "SECTION")` | Small muted section heading, in capitals |
| `ui.empty(icon, line1, line2)` | Nothing to show, or a feature is off ("USB keyboard is off", "Settings > USB") |
| `ui.tile(x, y, size, icon, colour)`, `ui.icon(name, x, y, fg, bg)` | App icons (lib/icons.lua, loaded on demand) |
| `shell.toast`, `shell.alert`, `shell.confirm`, `shell.prompt`, `shell.menu` | Feedback and dialogs |
| `shell.notify(title, body)` | Things the user may want later. They go to the notification center |

## Behaviour rules

- **Keys.** Arrows are Fn + `;` `.` `,` `/`. On screens without text input the bare `;` `.` `,` `/` keys also move (`ui.nav`). Enter selects. Esc goes back, and Esc on an app's top screen goes home (return `false` from `app.key`). Tab switches tabs. Ctrl+letter is for commands in text screens.
- **Reserved keys.** Fn+Q, Fn+N, Fn+P, Fn+L, Fn+H, Fn+- and Fn+= and the G0 button belong to the system. Don't use them in apps.
- **Feedback.** Every action shows a result: a toast, a sound, or a visible change. Errors say what to do next ("Connect to Wi-Fi first").
- **Drawing.** `draw()` must not change state. It runs once per screen band (three times per frame). Compute in `update(dt)` or `key(k)`.
- **Files.** Everything PocketLua or an app writes goes under its own folder on the card (`/pocketlua/`): use PocketLua-relative paths like `data/<app>/...`. Never write to `sd:/...` outside `/pocketlua/`. The Files app may still browse the whole card.
- **Memory.** Load data when needed and free it in `close()`. Build lists in `update()` or on key presses, not in `draw()`. Never run anything just to read metadata.
- **App header.** Keep it on one line: `local app = { title = "Clock", icon = "clock", color = "orange", order = 20, category = "tools" }`. The home screen reads it as text. Categories: `system`, `tools`, `media`, `games`, `net`.
- **Resume.** If returning to an app should feel continuous, return a small table from `app.save()`. It comes back as the second argument of `app.init(args, saved)`.

## Key help (Fn+H)

Every app lists its keys in `app.help = { { "Enter", "Play / pause" }, ... }` right after its header line: short key labels like the footer's, descriptions of at most 22 characters. Fn+H shows them in an overlay, followed by the system keys; `tools/tests/help.lua` checks every app has them.
