-- LiveOS shell: the small part of the system that is always in memory. It runs
-- one app at a time, routes keys, draws the status bar and toasts, and runs the
-- background services (battery, clock, Wi-Fi, console, device sharing).
-- Everything else, including the home screen, dialogs and icons, is loaded when
-- it is opened and freed when it is closed: the ESP32-S3 has no PSRAM.
-- The C++ core calls on_frame(dt), on_draw() (once per screen band) and on_key(k).
local ui = require("ui")
local col = ui.col

local shell = {}
_G.shell = shell

local DEFAULT_TZ = "PST8PDT,M3.2.0,M11.1.0"
local MIN_FREE_TO_OPEN = 24 * 1024  -- refuse to open an app below this much free RAM
local MIN_FREE_FOR_WIFI = 100 * 1024 -- Wi-Fi takes ~60 KB; Lua needs ~40 KB left after it

local current, current_name = nil, nil
local modal = nil
local overlay = nil        -- lock screen, quick settings, notifications (lib/overlays/*)
local saved_state = {}     -- what each app's save() returned, handed back on reopen
shell.clipboard = ""
local toast_msg, toast_left = nil, 0
local logbuf = {}
shell.log = logbuf

-- print goes to the serial port and a ring buffer the REPL shows.
function print(...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
  local s = table.concat(t, "\t")
  sys.log(s)
  logbuf[#logbuf + 1] = s
  if #logbuf > 30 then table.remove(logbuf, 1) end
end

-- ---------------------------------------------------------------- settings
function shell.tz()
  return cfg.get("tz") or DEFAULT_TZ
end

-- Formats a clock.now() table as HH:MM, or h:MM AM/PM when the 12-hour clock is on.
function shell.format_time(t)
  if cfg.get("clock12") ~= "1" then return string.format("%02d:%02d", t.h, t.m) end
  local h = t.h % 12
  return string.format("%d:%02d %s", h == 0 and 12 or h, t.m, t.h < 12 and "AM" or "PM")
end

function shell.apply_settings()
  ui.set_theme(cfg.get("theme") or "slate")
  ui.set_accent(cfg.get("accent") or "blue")
  gfx.brightness(tonumber(cfg.get("bright")) or 160)
  snd.volume(tonumber(cfg.get("vol")) or 100)
  clock.set_tz(shell.tz())
end

-- ---------------------------------------------------------------- toasts and dialogs
function shell.toast(msg, secs)
  toast_msg, toast_left = tostring(msg), secs or 2
end

-- ---------------------------------------------------------------- system sounds
-- A tiny queue so sounds can be short melodies without blocking a frame.
local SOUNDS = {
  boot = { { 523, 70 }, { 659, 70 }, { 784, 120 } },
  notify = { { 1319, 60 }, { 1976, 90 } },
  error = { { 220, 120 }, { 0, 60 }, { 220, 160 } },
  low = { { 784, 120 }, { 523, 200 } },
  alarm = { { 1760, 150 }, { 0, 100 }, { 1760, 150 }, { 0, 100 }, { 1760, 150 }, { 0, 400 } },
}
local tune, tune_i, tune_left = nil, 0, 0

function shell.sound(kind, force)
  if not force and cfg.get("sounds") == "0" then return end
  tune, tune_i, tune_left = SOUNDS[kind], 0, 0
end

local function sound_tick(dt)
  if not tune then return end
  tune_left = tune_left - dt * 1000
  if tune_left > 0 then return end
  tune_i = tune_i + 1
  local n = tune[tune_i]
  if not n then tune = nil; return end
  if n[1] > 0 then snd.tone(n[1], n[2]) end
  tune_left = n[2]
end

-- ---------------------------------------------------------------- notifications
-- Kept until cleared in the notification center (Fn+N); the newest is first.
local notes = {}
shell.notes = notes

function shell.notify(title, body, sound)
  local t = clock.now()
  table.insert(notes, 1, { title = tostring(title), body = body and tostring(body) or "",
    time = t.valid and shell.format_time(t) or "" })
  if #notes > 20 then notes[#notes] = nil end
  ui.status.unread = (ui.status.unread or 0) + 1
  shell.toast(title, 3)
  shell.sound(sound or "notify")
end

function shell.mark_read() ui.status.unread = 0 end

-- ---------------------------------------------------------------- timers and alarms
-- Background countdowns (Clock app, Pomodoro) and daily alarms keep running
-- whatever app is open. Alarms are stored in cfg "alarms" as "HH:MM|label;...".
local timers = {}
shell.timers = timers

function shell.start_timer(seconds, label)
  timers[#timers + 1] = { left = seconds, total = seconds, label = label or "Timer" }
  return timers[#timers]
end

function shell.cancel_timer(t)
  for i, x in ipairs(timers) do if x == t then table.remove(timers, i); return end end
end

local function timer_tick(dt)
  for i = #timers, 1, -1 do
    local t = timers[i]
    t.left = t.left - dt
    if t.left <= 0 then
      table.remove(timers, i)
      shell.wake()
      shell.notify(t.label .. " done", nil, "alarm")
      if t.done then pcall(t.done) end
    end
  end
end

local last_alarm_min = -1
local function alarm_check(t)
  if not t.valid then return end
  local key = t.h * 60 + t.m
  if key == last_alarm_min then return end
  last_alarm_min = key
  local now = string.format("%02d:%02d", t.h, t.m)
  for item in (cfg.get("alarms") or ""):gmatch("[^;]+") do
    local at, label = item:match("^(%d%d:%d%d)|?(.*)$")
    if at == now then
      shell.wake()
      shell.notify("Alarm " .. shell.format_time(t), label ~= "" and label or nil, "alarm")
    end
  end
end

-- Dialog state is a small table; the code that runs it is lib/dialog.lua.
function shell.alert(title, msg, cb) modal = { kind = "alert", title = title, msg = msg, cb = cb } end
function shell.confirm(title, msg, cb) modal = { kind = "confirm", title = title, msg = msg, cb = cb } end
-- opts.secret hides the typed text.
function shell.prompt(title, default, cb, opts)
  modal = { kind = "prompt", title = title, text = default or "", cb = cb, secret = opts and opts.secret }
end
-- items: array of strings. cb(index) or cb(nil) when cancelled.
function shell.menu(title, items, cb) modal = { kind = "menu", title = title, items = items, sel = 1, cb = cb } end

local function close_modal() modal = nil end

local function draw_toast()
  if not toast_msg then return end
  local msg = ui.fit(toast_msg, 220)
  local w = #msg * 6 + 16
  local x = math.floor((ui.W - w) / 2)
  gfx.rfill(x, 108, w, 16, 6, col.panel2)
  gfx.rrect(x, 108, w, 16, 6, col.accent)
  ui.text(x + 8, 112, msg, col.text)
end

-- ---------------------------------------------------------------- memory
local release_dev  -- defined with the device service below

-- Drops everything that can be reloaded later and runs a full collection.
-- Returns free RAM in bytes.
function shell.free_memory()
  if not modal then unload("dialog") end
  unload("icons")
  release_dev()
  collectgarbage("collect")
  collectgarbage("collect")
  return (sys.heap())
end

-- ---------------------------------------------------------------- apps
local function make_error_app(msg, file, line, retry)
  local oom = msg:find("not enough memory", 1, true) ~= nil
  local lines = ui.wrap(oom and "There is not enough free memory to run this. Stop Wi-Fi or other services in Task Manager, then retry." or msg, 224)
  local app = { title = oom and "Out of memory" or "Error" }
  function app.draw()
    ui.icon("warn", 20, 29, col.warn, col.bg)
    ui.text(36, 25, oom and "Not enough memory" or "Something went wrong", col.bad)
    for i = 1, math.min(#lines, 8) do ui.text(8, 42 + (i - 1) * 10, lines[i], col.text) end
    local hints = {}
    if file and not oom then hints[#hints + 1] = { "E", "Edit" } end
    if retry then hints[#hints + 1] = { "R", "Retry" } end
    if oom then hints[#hints + 1] = { "T", "Tasks" } end
    hints[#hints + 1] = { "Esc", "Home" }
    ui.footer(hints)
  end
  function app.key(k)
    if k.text == "e" and file and not oom then shell.edit(file, line); return true end
    if k.text == "r" and retry then retry(); return true end
    if k.text == "t" and oom then shell.launch("tasks"); return true end
  end
  return app
end

local function fail(msg, retry)
  msg = tostring(msg)
  sys.log("app error: " .. msg)
  shell.sound("error")
  local file, line = msg:match("([%w_%./%-]+%.lua):(%d+):")
  current, current_name = nil, nil
  collectgarbage("collect")  -- the failed app may have left a lot behind
  current = make_error_app(msg, file, tonumber(line), retry)
  current_name = "error"
end

-- Runs fn(...) and turns any error into the error screen instead of a crash.
local function guard(fn, ...)
  local ok, r = xpcall(fn, function(e) return e end, ...)
  if not ok then fail(r) end
  return ok, r
end

-- Modules that stay loaded across apps; anything else an app required is
-- unloaded when it closes, so helper libraries never pile up.
local RESIDENT = { ui = true, shell = true, console = true }

local function unload_app_modules()
  for _, m in ipairs(modules()) do
    if not RESIDENT[m.name] and not (m.name == "dev" and rawget(_G, "dev") and dev.running()) then
      unload(m.name)
    end
  end
end

local function close_current()
  if current and current.save then
    local ok, st = pcall(current.save)
    if ok and type(st) == "table" then saved_state[current_name] = st end
  end
  if current and current.close then pcall(current.close) end
  sys.display_hold(false)
  current, current_name = nil, nil
  unload_app_modules()
  shell.free_memory()  -- free the old app and caches before the next one loads
end

function shell.load_app(name)
  local path = "apps/" .. name .. ".lua"
  local fn, err = sys.loadfile(path)
  if not fn then return nil, err or ("app not found: " .. path) end
  local ok, app = pcall(fn)
  if not ok then return nil, app end
  if type(app) ~= "table" then return nil, path .. ": app must return a table" end
  return app
end

-- Apps to return to with Esc, e.g. Notes -> editor -> Esc -> Notes.
local back = {}

-- Opens an app. Only one app is in memory at a time. `returning` is set when
-- going back, so the stack is not pushed again.
function shell.launch(name, args, returning)
  local from = current_name
  if not returning and from and from ~= "home" and from ~= "error" and from ~= name then
    back[#back + 1] = from
    if #back > 4 then table.remove(back, 1) end
  end
  close_current()
  local retry = function() shell.launch(name, args) end
  if sys.heap() < MIN_FREE_TO_OPEN then
    fail("not enough memory to open " .. name, retry)
    return
  end
  local app, err = shell.load_app(name)
  if not app then fail(err, retry); return end
  current, current_name = app, name
  if app.init then guard(app.init, args, saved_state[name]) end
end

function shell.home()
  back = {}
  shell.launch("home", nil, true)
end

-- Esc at an app's top level: back to the app that opened it, else home.
function shell.back()
  local prev = table.remove(back)
  while prev and (prev == current_name or not sys.exists("apps/" .. prev .. ".lua")) do
    prev = table.remove(back)  -- skip apps that were uninstalled meanwhile
  end
  if prev then shell.launch(prev, nil, true) else shell.home() end
end

-- Name of the running app ("home", "error", ...), handy for scripts and tests.
function shell.app()
  return current_name
end

function shell.edit(path, line)
  shell.launch("edit", { path = path, line = line })
end

-- Run or reload a file after it has been saved in the editor.
function shell.run_file(path)
  local app = path:match("^apps/(.+)%.lua$")
  if app then shell.launch(app); return end
  if path:match("^lib/") or path == "boot.lua" then
    shell.toast("Reloading system...", 1)
    sys.reload()
    return
  end
  shell.toast("Saved " .. path)
end

-- Opens a file with the app registered for its extension.
shell.handlers = {
  lua = "edit", txt = "edit", md = "edit", csv = "edit", json = "edit", cfg = "edit", conf = "edit",
  ini = "edit", log = "edit", wav = "music", bmp = "images", jpg = "images", jpeg = "images", png = "images",
}
function shell.open_file(path)
  local ext = (path:match("%.([%w]+)$") or ""):lower()
  local app = shell.handlers[ext]
  if not app then shell.toast("No app opens ." .. ext .. " files"); return end
  if app == "edit" then shell.edit(path) else shell.launch(app, { path = path }) end
end

-- Screenshots (Fn+P) are written as BMP by the core on the next frame.
function shell.screenshot()
  local dir = sys.storage() == "SD" and "sd:/screenshots" or "data/screenshots"
  sys.mkdirs(dir)
  local n = (tonumber(cfg.get("shot_n")) or 0) + 1
  cfg.set("shot_n", n)
  sys.screenshot(string.format("%s/shot_%03d.bmp", dir, n))
end

function on_screenshot(path, ok)
  if ok then shell.notify("Screenshot saved", path) else shell.toast("Screenshot failed") end
end

-- Overlays draw over the current app: lib/overlays/<name>.lua returns
-- { update(dt), draw(), key(k) } and is loaded only while open.
function shell.overlay(name, args)
  local fn, err = sys.loadfile("lib/overlays/" .. name .. ".lua")
  if not fn then shell.toast(tostring(err)); return end
  local ok, ov = pcall(fn, args)
  if not ok then shell.toast(tostring(ov)); return end
  overlay = ov
  overlay.name = name
end

function shell.close_overlay()
  overlay = nil
  collectgarbage("collect")
end

function shell.overlay_name() return overlay and overlay.name end

-- ---------------------------------------------------------------- Wi-Fi service
-- Wi-Fi is the largest single user of RAM, so starting it frees what it can
-- first and reports clearly when there is not enough.
function shell.wifi_start(ssid, pass)
  if wifi.status() == "off" then
    local free = shell.free_memory()
    if free < MIN_FREE_FOR_WIFI then
      shell.toast(string.format("Not enough memory for Wi-Fi (%dK free)", free // 1024), 4)
      return false
    end
    if not wifi.enable(true) then
      shell.toast("Wi-Fi failed to start (memory)", 4)
      return false
    end
  end
  if ssid then wifi.connect(ssid, pass or "") end
  return true
end

function shell.wifi_stop()
  wifi.enable(false)
  collectgarbage("collect")
end

-- ---------------------------------------------------------------- background services
local synced = false
local warned_low = false
local function services()
  local S = ui.status
  S.pct, S.charging = sys.battery()
  if S.charging then warned_low = false
  elseif S.pct <= 10 and not warned_low then
    warned_low = true
    shell.notify("Battery low", S.pct .. "% left", "low")
  end
  local st = wifi.status()
  S.wifi_on = st ~= "off"
  if st == "connected" then
    local r = wifi.rssi()
    S.wifi = r > -55 and 4 or r > -65 and 3 or r > -75 and 2 or 1
    if not synced then
      clock.sync(shell.tz())
      synced = true
    end
  else
    S.wifi, synced = 0, false
  end
  local t = clock.now()
  S.time = t.valid and shell.format_time(t) or nil
  alarm_check(t)
end

-- Lua console over USB serial (opt-in in Settings > USB).
local console
local function setup_console()
  if cfg.get("usb_console") == "1" and usb.status().serial then
    local ok, mod = pcall(require, "console")
    if ok then console = mod else sys.log("console: " .. tostring(mod)) end
  end
end
function shell.console_running() return console ~= nil end

-- Networked devices (Settings > Devices): loaded only while sharing is on or
-- an app uses it.
local dev_loaded = false
function shell.dev_restart()
  if cfg.get("dev_on") ~= "1" then
    if dev_loaded and dev.running() then dev.stop() end
    return
  end
  if not dev_loaded then
    local ok, err = pcall(require, "dev")
    if not ok then sys.log("dev: " .. tostring(err)); return end
    dev_loaded = true
  end
  if dev.running() then dev.stop() end
  local ok, err = dev.start()
  if not ok then shell.toast("Devices: " .. tostring(err), 3) end
end

function release_dev()
  if rawget(_G, "dev") and not dev.running() then
    unload("dev")
    _G.dev = nil
    dev_loaded = false
  end
end

-- ---------------------------------------------------------------- display hold
-- Apps that draw straight to the panel call sys.display_hold(true). The shell
-- lets go of the hold while a dialog, overlay or toast needs the screen, then
-- asks the app to repaint (app.repaint) when it takes it back.
local raw_hold = sys.display_hold
local app_hold, hold_now = false, false
function sys.display_hold(on) app_hold = on and true or false end

local function hold_tick()
  local want = app_hold and not modal and not overlay and not toast_msg
  if want == hold_now then return end
  hold_now = want
  raw_hold(want)
  if want and current and current.repaint then pcall(current.repaint) end
end

-- ---------------------------------------------------------------- display sleep
-- The screen turns off after Settings > Display > Sleep after (seconds, 0 =
-- never) without a key press. The key that wakes it is not passed on.
local idle, asleep = 0, false

function shell.sleep_after()
  return tonumber(cfg.get("sleep")) or 60
end

local function sleep_tick(dt)
  idle = idle + dt
  local limit = shell.sleep_after()
  if not asleep and limit > 0 and idle >= limit then
    asleep = true
    sys.display_sleep(true)
  end
end

-- Returns true when the key only woke the screen. Waking shows the lock
-- screen unless it is turned off in Settings > Display.
local function wake()
  idle = 0
  if not asleep then return false end
  asleep = false
  sys.display_sleep(false)
  gfx.brightness(tonumber(cfg.get("bright")) or 160)
  if cfg.get("lock") ~= "0" then shell.overlay("lock") end
  return true
end
shell.wake = wake

function shell.lock()
  if cfg.get("lock") ~= "0" then shell.overlay("lock") end
end

-- ---------------------------------------------------------------- entry points
-- on_frame(dt) runs once per frame and updates state; on_draw() runs once per
-- screen band (the frame buffer covers a third of the screen to save RAM), so
-- drawing must not change state.
local acc = 1
function on_frame(dt)
  acc = acc + dt
  if acc >= 1 then acc = 0; services() end
  sleep_tick(dt)
  sound_tick(dt)
  timer_tick(dt)
  if overlay and overlay.update then
    local ok, err = pcall(overlay.update, dt)
    if not ok then sys.log("overlay: " .. tostring(err)); overlay = nil end
  end
  if console then
    local ok, err = pcall(console.poll)
    if not ok then usb.write("error: " .. tostring(err) .. "\n") end
  end
  if dev_loaded or rawget(_G, "dev") then
    dev_loaded = true
    local ok, err = pcall(dev.poll)
    if not ok then sys.log("dev.poll: " .. tostring(err)) end
  end
  hold_tick()
  if current and current.update then guard(current.update, dt) end
  if toast_msg then
    toast_left = toast_left - dt
    if toast_left <= 0 then toast_msg = nil end
  end
  if boot_notes[1] and not modal then
    shell.alert("Built-in copy in use", table.remove(boot_notes, 1) .. " Revert it in Files (X).")
  end
end

function on_draw()
  gfx.noclip()
  gfx.clear(col.bg)
  if current and current.draw then guard(current.draw) end
  gfx.noclip()
  local title = current and (current.title or current_name) or "LiveOS"
  if sys.safe_mode then title = "SAFE MODE - " .. title end
  ui.statusbar(title)
  if overlay then
    local ok, err = pcall(overlay.draw)
    if not ok then sys.log("overlay: " .. tostring(err)); overlay = nil end
  end
  if modal then
    local ok, d = pcall(require, "dialog")
    if ok then d.draw(modal) end
  end
  draw_toast()
end

function on_key(k)
  if wake() then return end
  if cfg.get("click") == "1" then snd.tone(2400, 6) end
  if k.key == "home" then
    modal, overlay = nil, nil
    shell.home()
    return
  end
  -- system shortcuts work from any app
  if k.fn and k.text and not modal then
    local c = k.text:lower()
    if c == "q" then if shell.overlay_name() == "quick" then shell.close_overlay() else shell.overlay("quick") end; return end
    if c == "n" then if shell.overlay_name() == "notifications" then shell.close_overlay() else shell.overlay("notifications") end; return end
    if c == "p" then shell.screenshot(); return end
    if c == "l" then shell.lock(); return end
  end
  if overlay and not modal then
    local ok, err = pcall(overlay.key, k)
    if not ok then sys.log("overlay: " .. tostring(err)); overlay = nil end
    return
  end
  if modal then
    local ok, d = pcall(require, "dialog")
    if ok then d.key(modal, k, close_modal) else modal = nil end
    return
  end
  if current and current.key then
    local ok, consumed = guard(current.key, k)
    if not ok or consumed then return end
  end
  if k.key == "esc" and current_name ~= "home" then shell.back() end
end

-- ---------------------------------------------------------------- boot
shell.apply_settings()
-- Safe mode starts nothing in the background, so a setting that crashes the
-- system (e.g. Wi-Fi without enough memory) can always be turned off.
if not sys.safe_mode then
  setup_console()
  shell.dev_restart()
  local ssid = cfg.get("wifi_ssid")
  if ssid and cfg.get("wifi_auto") ~= "0" then shell.wifi_start(ssid, cfg.get("wifi_pass") or "") end
end
shell.home()
shell.sound("boot")

local recovered = sys.recovered()
if recovered then
  shell.alert("Recovered", "Your last change broke the system, so the built-in version is running. " ..
    "Revert it in Files. Error: " .. recovered)
end

return shell
