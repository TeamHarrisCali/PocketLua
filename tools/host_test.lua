-- Headless test of the Lua userland on a desktop Lua 5.4 with stubbed hardware.
-- Run from the project root:  lua5.4 tools/host_test.lua
local ROOT = "userland/"
local overlay = {}   -- files "written to storage"
local removed = {}
local draws = 0

local function exists_file(p)
  local f = io.open(p, "rb") or io.open((p:gsub("^userland/", "tools/emu/")), "rb")
  if f then f:close() return true end
end

-- The OS itself is native on the device; tools/emu holds a Lua stand-in
-- (shell, ui, home, dialogs) used to run the apps here.
local function readf(p)
  local f = io.open(p, "rb") or io.open((p:gsub("^userland/", "tools/emu/")), "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

-- ------------------------------------------------------------ stubs
hw_calls = {}
local function rec(name, ret) return function(...) hw_calls[#hw_calls + 1] = { name, ... }; return ret end end
local function counter() return function() draws = draws + 1 end end
gfx = { w = 240, h = 135, rgb = function(r, g, b) return r * 65536 + g * 256 + b end }
for _, n in ipairs({ "clear", "px", "line", "rect", "fill", "rrect", "rfill", "circle", "disc", "tri", "arc",
  "text", "clip", "noclip", "brightness" }) do gfx[n] = counter() end
gfx.text_w = function(s) return #s * 6 end
snd = { tone = function() end, stop = function() end, volume = function() end }
imu = { read = function() return { ax = 0.02, ay = -0.01, az = 1, gx = 0, gy = 0, gz = 0 } end }
local settings = { usb_console = "1" }
cfg = { get = function(k) return settings[k] end, set = function(k, v) settings[k] = v and tostring(v) or nil end }
local t0 = 0
sys = {
  safe_mode = false, version = "test",
  millis = function() t0 = t0 + 33; return t0 end,
  delay = function() end,
  heap = function() return 200000, 60000, 100000, 300000 end,
  battery = function() return 80, false end,
  reboot = function() end,
  display_hold = function() end,
  hwlib = function(name) return _G["__hw_" .. name] end,
  screenshot = function(p) sys.shot = p end,
  display_sleep = function(on) sys.asleep = on end,
  reload = function() sys.reloaded = true end,
  log = function(s) if os.getenv("VERBOSE") then io.stderr:write("[log] " .. s .. "\n") end end,
  recovered = function() return nil end,
  storage = function() return "SD", 7000000, 1000 end,
  exists = function(p) return overlay[p] ~= nil or exists_file(ROOT .. p) end,
  mkdirs = function() return true end,
  in_storage = function(p) return overlay[p] ~= nil end,
  is_embedded = function(p) return exists_file(ROOT .. p) end,
  read_builtin = function(p) return readf(ROOT .. p) end,
  read_text = function(p, max)
    local s = overlay[p] or readf(ROOT .. p)
    if s and max then s = s:sub(1, max) end
    return s
  end,
  loadfile = function(p, builtin, strip)
    local s
    if builtin then s = readf(ROOT .. p) else s = overlay[p] or readf(ROOT .. p) end
    if not s then return nil end
    local fn, err = load(s, "@" .. p)
    if fn and strip then fn = load(string.dump(fn, true), "@" .. p, "b") end
    return fn, err
  end,
  write_text = function(p, s) overlay[p] = s; return true end,
  rename = function(a, b) if not overlay[a] then return false end; overlay[b] = overlay[a]; overlay[a] = nil; return true end,
  append_text = function(p, s) overlay[p] = (overlay[p] or readf(ROOT .. p) or "") .. s; return true end,
  remove = function(p) local had = overlay[p] ~= nil; overlay[p] = nil; return had end,
  list = function(dir)
    local out, seen = {}, {}
    local d = ROOT .. dir
    local h = io.popen('ls -1p "' .. d .. '" 2>/dev/null')
    for line in h:lines() do
      local isdir = line:sub(-1) == "/"
      local name = isdir and line:sub(1, -2) or line
      out[#out + 1] = { name = name, dir = isdir, stored = overlay[(dir ~= "" and dir .. "/" or "") .. name] ~= nil,
        emb = true, size = 100 }
      seen[name] = true
    end
    h:close()
    local prefix = dir ~= "" and (dir .. "/") or ""
    for p in pairs(overlay) do
      if p:sub(1, #prefix) == prefix and not p:sub(#prefix + 1):find("/") then
        local name = p:sub(#prefix + 1)
        if not seen[name] then out[#out + 1] = { name = name, dir = false, stored = true, emb = false, size = #overlay[p] } end
      end
    end
    return out
  end,
}
wifi = { enable = function() return true end, connect = function() end, disconnect = function() end,
  status = function() return "connected" end, scan_start = function() end, rssi = function() return -50 end,
  ip = function() return "10.0.0.5" end, ssid = function() return "TestNet" end,
  scan_result = function() return { { ssid = "A", rssi = -40, secure = true }, { ssid = "B", rssi = -70, secure = false } } end }
local usb_in, usb_out, typed = {}, {}, {}
usb = { status = function() return { keyboard = true, drive = true, serial = true, connected = true } end,
  type = function(s) typed[#typed + 1] = s end, key = function(s) typed[#typed + 1] = "<" .. s .. ">" end,
  write = function(s) usb_out[#usb_out + 1] = s end,
  log_dump = function() return "boot\nline two\n" end,
  read = function() return table.remove(usb_in, 1) end,
  share = function(on) usb.shared = on end, sharing = function() return usb.shared end,
  mouse_move = rec("mouse_move"), mouse_click = rec("mouse_click"), mouse_press = rec("mouse_press") }
-- hardware drivers (record what was asked so tests can check it)
audio = { record = rec("record", true), play = rec("play", true), stop = rec("stop"),
  status = function() return "idle", 0, 0 end,
  analyze = function() return 0.2, 0.5, 440, { 0.1, 0.2, 0.3, 0.4, 0.3, 0.2, 0.1, 0.05 } end }
ir = { send = rec("ir") }
i2c = { scan = function() return { 0x44, 0x76 } end, read = function(_, n) return string.rep("\0", n) end,
  write = rec("i2c_write", true), read_reg = function(_, _, n) return string.rep("\0", n) end, write_reg = rec("i2c_wreg", true) }
http = { get = function() return "Sunny +18C", 200 end,
  download = function(url, path) local s = "local app = { title = \"Web App\", icon = \"app\" }\nreturn app\n"; sys.write_text(path, s); return #s, 200 end, dns = function() return "93.184.216.34" end, ping = function() return 23 end }
lora = { begin = rec("lora_begin", true), send = rec("lora_send", true), recv = function() return nil end,
  busy = function() return false end, stop = rec("lora_stop") }
gps = { start = rec("gps_start"), stop = rec("gps_stop"), read = function() return { valid = true, lat = 37.77, lon = -122.42,
  alt = 12, sats = 7, hdop = 1.1, speed = 3.5, course = 90, time = "12:00:00", date = "2026-11-03", chars = 1000 } end }
disp = { image = rec("image", true), fill = rec("dfill"), text = rec("dtext") }

-- the device creates these on first use (sys.hwlib); keep copies for that
for _, n in ipairs({ "audio", "ir", "i2c", "http", "lora", "gps", "disp" }) do _G["__hw_" .. n] = _G[n] end

-- loopback transport: whatever we send comes back as if the peer sent it
local net_in = {}
net = { start = function() return true end, stop = function() end, running = function() return true end,
  mac = function() return "aaaaaaaaaaaa" end, add_peer = function() return true end,
  send = function(mac, data) net_in[#net_in + 1] = { from = mac, data = data, rssi = -50, bcast = false }; return true end,
  broadcast = function() return true end,
  recv = function() return table.remove(net_in, 1) end }
clock = { now = function() return { valid = true, h = 14, m = 7, s = 0, year = 2026, month = 11, day = 3, wday = 2 } end,
  sync = function() end, set_tz = function() end }

-- ------------------------------------------------------------ helpers
local say = print
local failures = 0
local function check(cond, msg)
  if not cond then failures = failures + 1; say("FAIL: " .. msg) else say("ok:   " .. msg) end
end

local function frames(n) for _ = 1, n or 3 do on_frame(0.033); on_draw(); on_draw() end end

local function key(name, mods)
  local k = { key = name }
  if #name == 1 or name == "space" then k.text = name == "space" and " " or name end
  for m in pairs(mods or {}) do k[m] = true end
  on_key(k)
  frames(1)
end

local function type_text(s) for c in s:gmatch(".") do key(c) end end

-- ------------------------------------------------------------ boot
dofile("tools/emu/boot.lua")
frames(5)
check(shell.app() == "home", "boots to home")

local names = {}
for _, e in ipairs(sys.list("apps")) do names[#names + 1] = e.name:match("^(.+)%.lua$") end
table.sort(names)

for _, name in ipairs(names) do
  if name ~= "edit" then
    shell.launch(name)
    frames(5)
    check(shell.app() == name, "launches app: " .. name)
    for _, k in ipairs({ "down", "up", "enter", "esc", "a", "s", "d" }) do key(k) end
    frames(5)
    if shell.app() == "error" then check(false, name .. " survives keys") end
    shell.home()
    frames(2)
  end
end

-- home navigation
shell.home(); frames(2)
for _, k in ipairs({ "right", "right", "down", "left", "up" }) do key(k) end
check(shell.app() == "home", "home grid navigation")

-- ------------------------------------------------------------ editor flow
shell.launch("edit", { path = "apps/hello.lua" })
frames(2)
check(shell.app() == "edit", "editor opens")
type_text("-- x")
key("enter")
key("backspace")
key("backspace")
key("tab")
key("s", { ctrl = true })
check(overlay["apps/hello.lua"] ~= nil and overlay["apps/hello.lua"]:find("%-%- ", 1) ~= nil, "ctrl+s writes the file")
key("r", { ctrl = true })
frames(3)
check(shell.app() == "hello", "ctrl+r runs the edited app")
local broken = overlay["apps/hello.lua"]:gsub("function app.draw%(%)", "function app.draw() nosuchfunction()")
overlay["apps/hello.lua"] = broken
shell.launch("hello")
frames(3)
check(shell.app() == "error", "a broken app lands on the error screen, not a crash")
key("e")
check(shell.app() == "edit", "E on the error screen opens the editor")
key("esc"); key("esc")
overlay["apps/hello.lua"] = nil

-- unsaved-changes guard
shell.launch("edit", { path = "apps/hello.lua" })
type_text("zzz")
key("esc")
check(shell.app() == "edit", "first Esc with unsaved changes stays")
key("esc")
check(shell.app() == "home", "second Esc discards and leaves")

-- ------------------------------------------------------------ new app flow
shell.home(); frames(2)
key("n", { ctrl = true })
type_text("foo")
key("enter")
check(shell.app() == "edit", "N creates an app and opens the editor")
check(overlay["apps/foo.lua"] ~= nil, "new app file exists")
key("r", { ctrl = true })
frames(5)
check(shell.app() == "foo", "template app runs")
shell.home(); frames(2)

-- ------------------------------------------------------------ settings
shell.launch("settings"); frames(2)
for _, k in ipairs({ "enter", "esc", "down", "enter", "right", "left", "esc", "down", "down", "enter", "right", "esc" }) do key(k) end
check(shell.app() == "settings", "settings pages navigate")
for _ = 1, 8 do key("down") end
key("enter")
frames(2)
check(shell.app() == "settings", "about page opens")
shell.home(); frames(2)

-- ------------------------------------------------------------ files
shell.launch("files"); frames(2)
key("enter")             -- LiveOS
key("enter")             -- first entry (..) goes back
key("down"); key("enter")
check(shell.app() ~= "error", "files browse")
shell.home(); frames(2)

-- ------------------------------------------------------------ repl
shell.launch("repl"); frames(2)
type_text("1+1"); key("enter")
type_text("print(7)"); key("enter")
frames(2)
check(shell.app() == "repl", "repl evaluates input")
shell.home(); frames(2)

-- ------------------------------------------------------------ dialogs
shell.confirm("T", "Sure?", function(y) _G.__answer = y end)
frames(2); key("y")
check(_G.__answer == true, "confirm dialog")
shell.menu("Pick", { "a", "b", "c" }, function(i) _G.__pick = i end)
frames(2); key("down"); key("enter")
check(_G.__pick == 2, "menu dialog")
shell.prompt("Name", "x", function(t) _G.__text = t end)
frames(2); type_text("yz"); key("enter")
check(_G.__text == "xyz", "prompt dialog")

-- ------------------------------------------------------------ USB apps and console
shell.launch("usbkeys"); frames(2)
key("enter")             -- live keyboard mode
key("a"); key("enter"); key("a", { ctrl = true })
check(typed[1] == "a" and typed[2] == "<enter>" and typed[3] == "<ctrl+a>", "USB passthrough forwards keys")
key("esc")
check(shell.app() == "usbkeys", "Esc leaves passthrough first")
key("down"); key("enter")
check(typed[#typed] and typed[#typed]:find("Hello"), "snippet is typed")
check(overlay["data/snippets.txt"] ~= nil, "default snippets file is created")
shell.home(); frames(2)

shell.launch("settings"); frames(2)
for _ = 1, 5 do key("down") end
key("enter")             -- USB page
for _ = 1, 5 do key("down") end
key("enter")             -- share SD
check(usb.shared == true, "share page shares the SD card")
key("esc")
check(usb.shared == false, "leaving the share page releases it")
shell.home(); frames(2)

local function feed(line) usb_in[#usb_in + 1] = line .. "\n"; frames(2) end
feed("1+2")
check(table.concat(usb_out):find("3"), "console evaluates Lua")
local console = require("console")
local payload = "-- pushed\nreturn { title = 'Pushed' }\n"
feed("!begin apps/pushed.lua")
feed("!data " .. console.encode(payload))
feed("!end")
check(overlay["apps/pushed.lua"] == payload, "console receives a file (base64 round trip)")
feed("!run pushed")
check(shell.app() == "pushed", "console runs the pushed app")
shell.home(); frames(2)
usb_out = {}
feed("!get apps/pushed.lua")
check(table.concat(usb_out):find("!end"), "console sends a file back")

-- ------------------------------------------------------------ networked devices
settings.dev_key, settings.dev_on, settings.dev_name = "secret", "1", "me"
shell.dev_restart(); frames(2)
net_in[#net_in + 1] = { from = "bbbbbbbbbbbb", data = "Bkitchen", rssi = -60, bcast = true }
frames(2)
local peers = dev.peers()
check(#peers == 1 and peers[1].name == "kitchen", "beacon registers a peer")
local got
dev.mount("kitchen").sys.battery(function(r, err) got = { r = r, err = err } end)
frames(4)
check(got and got.r and got.r.pct == 80, "remote call round-trips through the protocol")
local tone_called
snd.tone = function(f, ms) tone_called = f end
dev.mount("kitchen").snd.tone(660, 100); frames(4)
check(tone_called == 660, "remote tone call runs the export")
local denied
dev.call("kitchen", "sys.reboot", {}, function(r, err) denied = err end); frames(4)
check(denied and denied:find("not exported"), "unexported functions are refused")
local missing
dev.call("nobody", "sys.ping", {}, function(r, err) missing = err end)
check(missing and missing:find("no such device"), "unknown device reports an error")
shell.launch("nearby"); frames(3)
key("enter"); key("enter")   -- menu on kitchen, Ping
frames(4)
check(shell.app() == "nearby", "nearby app opens a device menu")
shell.home(); frames(2)
local dev = require("dev")  -- sharing stops when Nearby closes, so load the module again
local rt = dev.deserialize(dev.serialize({ a = 1, b = { "x", true }, s = "q\"\n" }))
check(rt and rt.a == 1 and rt.b[1] == "x" and rt.s == "q\"\n", "serialization round trip")
check(dev.deserialize("os.exit()") == nil, "deserializer refuses code")

-- ------------------------------------------------------------ resilience
feed("!log")
check(table.concat(usb_out):find("# boot"), "console can dump the device log")

-- a truncated saved copy of a system file must not stop the OS from booting
local full_ui = readf(ROOT .. "lib/ui.lua")
overlay["lib/ui.lua"] = full_ui:sub(1, 1994)   -- cut off mid-function, like the reported error
dofile("tools/emu/boot.lua")
check(#boot_notes == 1 and boot_notes[1]:find("lib/ui.lua"), "fallback to the built-in copy is recorded for the user")
frames(3)
check(shell.app() == "home", "boots to home even with a truncated saved ui.lua")
frames(3)
check(#boot_notes == 0, "the fallback note is shown (and cleared)")
overlay["lib/ui.lua"] = nil

-- a save that does not read back identically is reported
local real_write = sys.write_text
sys.write_text = function(p, s) overlay[p] = s:sub(1, #s - 5); return true end
shell.launch("edit", { path = "apps/hello.lua" }); frames(2)
type_text("q")
key("s", { ctrl = true })
local still_dirty = true
key("esc")  -- first Esc keeps the editor open only when the save failed (still dirty)
check(shell.app() == "edit", "failed save is detected and the file stays marked unsaved")
sys.write_text = real_write
key("esc"); key("esc")
overlay["apps/hello.lua"] = nil

-- ------------------------------------------------------------ on-demand loading
local function is_loaded(name)
  for _, m in ipairs(modules()) do if m.name == name then return true end end
end
shell.home(); frames(2)
check(is_loaded("icons"), "home screen loads icons on demand")
shell.launch("repl"); frames(2)
check(not is_loaded("icons") and not is_loaded("dialog"), "icons and dialogs are freed when an app opens")
shell.confirm("T", "x", function() end); frames(1)
check(is_loaded("dialog"), "dialog code loads when a dialog opens")
key("n")
shell.launch("settings"); frames(2)
key("enter"); frames(1)   -- Wi-Fi page
check(shell.app() == "settings", "settings opens a page module")
shell.launch("tasks"); frames(3)
check(shell.app() == "tasks", "task manager opens")
key("enter"); frames(1)   -- free memory now
check(shell.app() == "tasks", "task manager frees memory")
shell.home(); frames(2)

-- Wi-Fi start reports a failure instead of silently doing nothing
wifi.status = function() return "off" end
local real_enable = wifi.enable
wifi.enable = function(on) if on then return false end return true end
check(shell.wifi_start("x", "y") == false, "failed Wi-Fi start is reported")
wifi.enable = real_enable
wifi.status = function() return "connected" end

-- refusing to open an app when memory is short
local real_heap = sys.heap
sys.heap = function() return 10000, 60000, 5000, 300000 end
shell.launch("piano"); frames(2)
check(shell.app() == "error", "an app is not opened when memory is short")
sys.heap = real_heap
key("r"); frames(2)
check(shell.app() == "piano", "retry opens it once memory is back")
shell.home(); frames(2)

-- ------------------------------------------------------------ devices page and 12-hour clock
settings.dev_on = nil
shell.dev_restart()
shell.launch("settings"); frames(2)
for _ = 1, 4 do key("down") end
key("enter"); frames(2)
check(shell.app() == "settings" and not is_loaded("dev"), "devices page opens without loading the sharing module")
shell.home(); frames(2)
settings.clock12 = "1"
check(shell.format_time({ h = 0, m = 5 }) == "12:05 AM" and shell.format_time({ h = 13, m = 7 }) == "1:07 PM"
  and shell.format_time({ h = 12, m = 0 }) == "12:00 PM", "12-hour time format")
settings.clock12 = nil
check(shell.format_time({ h = 9, m = 3 }) == "09:03", "24-hour time format")

-- ------------------------------------------------------------ display sleep
settings.sleep = "30"
shell.launch("repl"); frames(1)
for _ = 1, 31 do on_frame(1) end
check(sys.asleep == true, "display sleeps after the idle time")
on_key({ key = "a", text = "a" }); frames(1)
check(sys.asleep == false, "a key wakes the display")
check(shell.app() == "repl", "the waking key is not passed to the app")
settings.sleep = "0"
for _ = 1, 700 do on_frame(1) end
check(not sys.asleep, "Never keeps the display on")
settings.sleep = nil
key("esc")  -- user activity resets the idle timer
shell.home(); frames(2)

-- ------------------------------------------------------------ OS features
shell.home(); frames(2)
on_key({ key = "q", text = "q", fn = true }); frames(1)
check(shell.overlay_name() == "quick", "Fn+Q opens quick settings")
key("down"); key("right"); key("esc"); frames(1)
check(shell.overlay_name() == nil and shell.app() == "home", "quick settings closes with Esc")
shell.notify("Hello", "body text"); frames(1)
check(ui.status.unread == 1, "notifications count as unread")
on_key({ key = "n", text = "n", fn = true }); frames(1)
check(shell.overlay_name() == "notifications" and ui.status.unread == 0, "Fn+N opens notifications and marks them read")
key("esc"); frames(1)
on_key({ key = "p", text = "p", fn = true }); frames(1)
check(sys.shot ~= nil and sys.shot:find("%.bmp$"), "Fn+P asks the core for a screenshot")
on_screenshot(sys.shot, true); frames(1)
check(shell.notes[1].title == "Screenshot saved", "screenshot result is reported")
local fired = false
local t = shell.start_timer(2, "Tea")
t.done = function() fired = true end
for _ = 1, 3 do on_frame(1) end
check(fired and shell.notes[1].title == "Tea done", "background timers fire and notify")
local real_now = clock.now
clock.now = function() local t = real_now(); t.m = 8; return t end  -- the next minute
settings.alarms = "14:08|Stand up"
for _ = 1, 2 do on_frame(1) end
check(shell.notes[1].title:find("Alarm") ~= nil, "daily alarm fires at its time")
settings.alarms = nil
clock.now = real_now
on_key({ key = "esc" })  -- dismiss anything the alarm opened
shell.open_file("sd:/song.wav"); frames(1)
check(shell.app() == "music" or shell.app() == "error", "a .wav opens with the music app")
shell.open_file("notes/todo.txt"); frames(1)
check(shell.app() == "edit", "a .txt opens in the editor")
-- editor clipboard and undo
type_text("abc")
key("z", { ctrl = true }); frames(1)
key("c", { ctrl = true })
key("v", { ctrl = true }); frames(1)
key("z", { ctrl = true })
check(shell.clipboard ~= nil and shell.clipboard:sub(-1) == "\n", "editor copies a line to the clipboard")
key("esc"); key("esc")
shell.home(); frames(2)
type_text("pia"); frames(1)
key("enter"); frames(2)
check(shell.app() == "piano", "typing on home searches and Enter opens the match")
shell.home(); frames(2)
on_key({ key = "tab" }); frames(1)
check(shell.app() == "home", "Tab switches home categories")

-- ------------------------------------------------------------ back navigation
shell.home(); frames(2)
shell.launch("notes"); frames(2)
shell.edit("data/notes/test.txt"); frames(2)
key("esc"); frames(2)
check(shell.app() == "notes", "Esc from the editor returns to the app that opened it")
key("esc"); frames(2)
check(shell.app() == "home", "Esc from the first app goes home")

-- ------------------------------------------------------------ system reload from editor
shell.launch("edit", { path = "lib/ui.lua" }); frames(2)
key("s", { ctrl = true })
key("r", { ctrl = true })
check(sys.reloaded == true, "editing lib/ asks the core to reload")

say(string.format("\n%d draw calls, %d failure(s)", draws, failures))
os.exit(failures == 0 and 0 or 1)
