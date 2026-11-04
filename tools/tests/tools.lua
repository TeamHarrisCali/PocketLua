-- Headless tests for the tool apps: Clock, Notes, Calculator, Images, App Store.
-- Run from the project root:  lua5.4 tools/tests/tools.lua
local say = print
local src = assert(io.open("tools/host_test.lua")):read("a")
assert(load(src:match("^(.-)%-%- %-+ helpers"), "=stubs"))()

-- record what is drawn as text, and the display hold state
local drawn = {}
local real_text = gfx.text
gfx.text = function(x, y, s, ...) drawn[#drawn + 1] = s; return real_text(x, y, s, ...) end
local held = false
sys.display_hold = function(on) held = on and true or false end

dofile("tools/emu/boot.lua")

local fails, passes = 0, 0
local function check(c, m)
  if c then passes = passes + 1; say("ok:   " .. m) else fails = fails + 1; say("FAIL: " .. m) end
end
local function frames(n) for _ = 1, n or 3 do on_frame(0.033); on_draw(); on_draw(); on_draw() end end
local function key(name, mods)
  local k = { key = name }
  if #name == 1 then k.text = name elseif name == "space" then k.text = " " end
  for m in pairs(mods or {}) do k[m] = true end
  on_key(k)
  frames(1)
end
local function type_text(s) for c in s:gmatch(".") do key(c) end end

-- Strings drawn by one on_draw pass.
local function screen()
  drawn = {}
  on_draw()
  return drawn
end
local function shows(s)  -- some drawn string contains s
  for _, d in ipairs(screen()) do if d:find(s, 1, true) then return true end end
  return false
end
local function drew(s)   -- some drawn string is exactly s
  for _, d in ipairs(screen()) do if d == s then return true end end
  return false
end
local function launch(name, args) shell.launch(name, args); frames(2) end
local function no_error(name) check(shell.app() == name, name .. " is still running (no error screen)") end

frames(3)

-- ================================================================ Calculator
launch("calc")
check(shell.app() == "calc", "calc launches")
local function calc(expr) type_text(expr); key("enter") end
calc("2+3*4");      check(drew("14"), "2+3*4 = 14")
calc("(1+2)^2");    check(drew("9"), "(1+2)^2 = 9")
calc("sqrt(16)");   check(drew("4"), "sqrt(16) = 4")
calc("-2^2");       check(drew("-4"), "-2^2 = -4")
calc("10%4");       check(drew("2"), "10%4 = 2")
calc("2pi");        check(drew("6.283185"), "implicit product 2pi")
calc("2^3^2");      check(drew("512"), "^ is right associative")
calc("log(1000)+ln(1)"); check(drew("3"), "log and ln")
calc("abs(-7.5)");  check(drew("7.5"), "abs")
key("+"); type_text("1"); key("enter")
check(drew("8.5"), "operator on empty input continues from ans")
calc("ans*2");      check(drew("17"), "ans constant")
calc("1/0");        check(shows("divide by zero"), "divide by zero is an error")
calc("2+");         check(shows("Error"), "incomplete expression is an error")
key("esc")          -- clears the failed input
calc("os.exit()");  check(shows("Error"), "Lua code is not evaluated")
key("esc")
calc("((1)");       check(shows("missing )"), "unbalanced brackets")
key("esc")
key("d", { ctrl = true })
calc("sin(90)");    check(drew("1"), "degrees mode")
key("d", { ctrl = true })
calc("cos(pi)");    check(drew("-1"), "radians mode")
key("up")
check(shows("cos(pi)"), "Up recalls history")
key("esc")
no_error("calc")
-- units
key("tab")
check(shows("Category") and shows("Length"), "units tab shows the category")
type_text("1")
check(shows("0.6213712 mi"), "1 km = 0.6213712 mi")
key("right")        -- category: Mass
key("right")        -- category: Temperature
key("backspace"); type_text("100")
check(shows("= 212 F"), "100 C = 212 F")
key("s")
check(shows("= 37.77778 C"), "swap converts F to C")
key("down"); key("down"); key("right"); key("right")
check(shows("= 310.9278 K"), "changing the target unit (100 F = 310.9278 K)")
key("right"); key("right"); key("right")  -- data
key("up"); key("up"); key("right"); key("right"); key("right")
no_error("calc")
key("esc"); key("esc")
check(shell.app() == "home", "Esc clears then goes home")
launch("calc")
check(shows("Category"), "calc remembers the Units tab")
shell.home(); frames(2)

-- ================================================================ Clock
cfg.set("alarms", "08:00|Standup;bad;09:15")
launch("clock")
check(shell.app() == "clock", "clock launches")
check(drew("14:07") and shows("Tuesday, 3 November 2026"), "clock tab shows time and date")
check(shows("Next alarm 08:00 Standup"), "clock tab shows the next alarm")
key("tab")
check(shows("Standup") and drew("09:15"), "alarms are parsed from cfg (bad entry skipped)")
key("a"); type_text("7:30 Wake up"); key("enter")
check(cfg.get("alarms") == "07:30|Wake up;08:00|Standup;09:15|", "alarm added, sorted and written to cfg")
key("a"); type_text("25:00 bad"); key("enter")
check(cfg.get("alarms") == "07:30|Wake up;08:00|Standup;09:15|", "invalid time is refused")
check(shows("HH:MM"), "invalid time explains the format")
key("a"); type_text("6:05pm Gym;x"); key("enter")
check(cfg.get("alarms") == "07:30|Wake up;08:00|Standup;09:15|;18:05|Gym x", "12-hour input and separators are cleaned")
for _ = 1, 5 do key("up") end
key("x")
check(cfg.get("alarms") == "08:00|Standup;09:15|;18:05|Gym x", "X deletes the selected alarm")
key("x"); key("x"); key("x")
check(cfg.get("alarms") == nil, "deleting every alarm clears cfg")
check(shows("No alarms"), "empty alarm list")
-- timer
key("tab")
local before = #shell.timers
key("right"); key("right")
check(shows("7 min"), "right raises the minutes")
key("enter")
check(#shell.timers == before + 1 and shell.timers[#shell.timers].total == 420
  and shell.timers[#shell.timers].label == "Timer", "Enter starts a 7 minute timer")
type_text("10"); key("enter")
check(#shell.timers == before + 2 and shell.timers[#shell.timers].total == 600, "typed digits set 10 minutes")
frames(10)
check(drew("Timer") and drew("10:00") and drew("07:00"), "running timers are listed with time left")
key("x")
check(#shell.timers == before + 1, "X cancels the selected timer")
-- stopwatch
key("tab")
check(drew("00:00.00"), "stopwatch starts at zero")
key("enter"); frames(10)
key("l"); frames(5)
key("l")
key("enter")
check(shows("Lap 1") and shows("Lap 2"), "laps are listed")
check(not drew("00:00.00"), "stopwatch counted time")
key("r")
check(drew("00:00.00") and not shows("Lap 1"), "R resets")
-- pomodoro
key("tab")
check(shows("25 min focus"), "pomodoro idle screen")
key("enter")
local pomo
for _, t in ipairs(shell.timers) do if t.pomo then pomo = t end end
check(pomo and pomo.total == 1500 and pomo.pomo == "work", "Enter starts a 25 min focus timer")
frames(3)
check(shows("FOCUS") and drew("25:00"), "pomodoro shows phase and time left")
-- leave the app: timers keep running in the shell
shell.home(); frames(2)
pomo.left = 0.01
frames(2)
local nxt
for _, t in ipairs(shell.timers) do if t.pomo then nxt = t end end
check(nxt and nxt ~= pomo and nxt.pomo == "break" and nxt.total == 300 and nxt.count == 1,
  "work phase ends with the app closed and starts a 5 min break")
nxt.left = 0.01; frames(2)
for _, t in ipairs(shell.timers) do if t.pomo then nxt = t end end
check(nxt.pomo == "work" and nxt.count == 1, "break ends and the next focus phase starts")
launch("clock")
check(shows("FOCUS") and shows("Completed: 1"), "clock reopens on the Pomodoro tab with the count")
key("x")
local still = false
for _, t in ipairs(shell.timers) do if t.pomo then still = true end end
check(not still, "X stops the Pomodoro")
check(#shell.timers == before + 1, "the plain timer is still running")
for i = #shell.timers, 1, -1 do shell.cancel_timer(shell.timers[i]) end
no_error("clock")
key("esc")
check(shell.app() == "home", "Esc goes home from clock")

-- ================================================================ Notes
launch("notes")
check(shell.app() == "notes", "notes launches")
check(shows("No notes yet"), "empty notes list")
key("n"); type_text("Shop/ping!"); key("enter")
check(shell.app() == "edit" and sys.read_text("data/notes/Shopping.txt") == "", "N creates the note and opens the editor")
key("esc")
launch("notes")
check(shows("Shopping"), "the note is listed")
key("enter")
check(shell.app() == "edit", "Enter opens the note in the editor")
launch("notes")
key("x"); key("y")
check(not sys.exists("data/notes/Shopping.txt") and shows("No notes yet"), "X deletes after confirming")
key("tab")
check(shows("Nothing to do"), "empty to-do list")
key("a"); type_text("milk"); key("enter")
key("a"); type_text("eggs"); key("enter")
check(sys.read_text("data/todo.txt") == "[ ] milk\n[ ] eggs\n", "items are added and saved")
key("up"); key("enter")
check(sys.read_text("data/todo.txt") == "[x] milk\n[ ] eggs\n", "Enter toggles and saves")
key("down"); key("space")
check(sys.read_text("data/todo.txt") == "[x] milk\n[x] eggs\n", "Space toggles")
key("space")
key("c"); key("y")
check(sys.read_text("data/todo.txt") == "[ ] eggs\n", "C clears done items")
key("x")
check(sys.read_text("data/todo.txt") == "", "X deletes an item")
sys.write_text("data/todo.txt", "[x] call Bob\nplain line\n")
shell.home(); frames(2)
launch("notes")
check(shows("call Bob") and shows("plain line"), "notes reopens on the To-do tab and reads the file")
key("down"); key("enter")
check(sys.read_text("data/todo.txt") == "[x] call Bob\n[x] plain line\n", "plain lines become items")
no_error("notes")
key("esc")
check(shell.app() == "home", "Esc goes home from notes")

-- ================================================================ Images
launch("images")
check(shows("No images yet"), "empty image list")
shell.home(); frames(2)
sys.write_text("data/screenshots/shot_001.bmp", "BM")
sys.write_text("data/screenshots/shot_002.bmp", "BM")
sys.write_text("data/images/cat.jpg", "\255\216")
launch("images")
frames(120)  -- let earlier toasts expire: the shell lifts the hold while one is showing
check(shows("shot_002.bmp") and shows("shot_001.bmp") and shows("cat.jpg"), "images from both folders are listed")
hw_calls = {}
key("enter")
local function last_image()
  for i = #hw_calls, 1, -1 do if hw_calls[i][1] == "image" then return hw_calls[i][2], hw_calls[i] end end
end
check(held and last_image() == "data/screenshots/shot_002.bmp", "Enter holds the display and draws the newest screenshot")
local n = #hw_calls
frames(5)
check(#hw_calls == n, "no redraw while the picture is unchanged")
key("right")
check(last_image() == "data/screenshots/shot_001.bmp", "right shows the next image")
key("right")
check(last_image() == "data/images/cat.jpg", "and the next folder")
key("right")
check(last_image() == "data/screenshots/shot_002.bmp", "wraps around")
key("left")
check(last_image() == "data/images/cat.jpg", "left goes back")
local caption = false
for _, c in ipairs(hw_calls) do if c[1] == "dtext" and tostring(c[4]):find("cat.jpg") then caption = true end end
check(caption, "caption bar names the image")
key("esc")
check(not held and shell.app() == "images", "Esc returns to the list and releases the display")
key("enter"); frames(120)
check(held, "viewing again holds the display")
shell.home(); frames(2)
check(not held, "closing the app releases the display")
shell.open_file("data/screenshots/shot_001.bmp"); frames(120)
check(shell.app() == "images" and held and last_image() == "data/screenshots/shot_001.bmp", "open_file shows the image")
key("esc")
check(not held, "Esc leaves the viewer")
key("down"); key("down"); key("x"); key("y")
check(not sys.exists("data/images/cat.jpg") and not shows("cat.jpg"), "X deletes an image")
no_error("images")
key("esc")
check(shell.app() == "home", "Esc goes home from images")

-- ================================================================ Tip & Split
-- a store-only app (store/apps): put it where an install from the store would
sys.write_text("apps/tip.lua", assert(io.open("store/apps/tip.lua")):read("a"))
launch("tip")
check(shell.app() == "tip" and shows("Type the bill amount") and shows("20%"), "tip: asks for the bill, 20% by default")
type_text("50")
check(shows("$50") and shows("Tip $10.00") and shows("Total $60.00") and shows("$30.00 each"), "tip: 50 at 20% for 2 is 30.00 each")
key("down"); type_text("18")
check(shows("18%") and shows("Total $59.00") and shows("$29.50 each"), "tip: typing on Tip sets 18%")
key("down"); key("right")
check(shows("$19.67 each"), "tip: 3 people, shares rounded up to the cent")
key("down"); key("right")
check(shows("Each up") and shows("$20.00 each") and shows("Total $60.00") and shows("Tip $10.00 (20.0%)"), "tip: Each up rounds each share to a dollar")
key("right")
check(shows("Total up") and shows("Total $59.00") and shows("$19.67 each"), "tip: Total up rounds the total")
key("enter")
check(drew("Bill"), "tip: Enter wraps to the first field")
key("backspace"); key("backspace"); type_text("12.345")
check(shows("$12.34") and not shows("$12.345"), "tip: two decimal places at most")
key("esc")
check(shell.app() == "tip" and shows("Type the bill amount"), "tip: Esc clears the bill first")
type_text("1234567")
check(shows("$123456") and not shows("$1234567"), "tip: bill is at most six digits before the point")
key("down"); key("backspace"); key("backspace")
check(shows("Tip $0.00"), "tip: Backspace on Tip goes to 0%")
key("down"); for _ = 1, 3 do key("left") end
check(shows("Total $123456.00") and not shows("each"), "tip: one person sees just the total")
no_error("tip")
shell.home(); frames(2)
launch("tip")
check(shows("$123456") and shows("0%"), "tip: resumes where it was")
key("esc"); key("esc")
check(shell.app() ~= "tip", "tip: Esc with no bill leaves the app")

-- ================================================================ App Store
-- a fake appstore module (the real one is native: src/appstore.cpp)
local AS = { cat = nil, runs = {}, result = "" }
appstore = {
  list = function() return AS.cat end,
  run = function(op, arg) AS.runs[#AS.runs + 1] = { op, arg or "" } end,
  result = function() return AS.result end,
  channel = function() return AS.channel or "beta", "beta" end,
}
__hw_appstore = appstore
local function lastrun() local r = AS.runs[#AS.runs]; return r and (r[1] .. " " .. r[2]) or "" end
launch("store")
check(shell.app() == "store" and shows("No catalog yet") and shows("Press C"), "store: explains C before the first check")
key("c")
check(lastrun() == "check ", "store: C asks the shell to check GitHub")
local function a(name, title, status, core) return { name = name, title = title, status = status, core = core or false,
  category = "tools", icon = "app", desc = title .. " does things", size = 20000 } end
AS.cat = { firmware = { build = "abc12345", running = "0e065750", size = 2600000, status = "update" }, apps = {
  a("music", "Music", "available"), a("clock", "Clock", "update"), a("settings", "Settings", "installed", true),
  a("snake", "Snake", "installed"), a("edit", "Editor", "installed", true), a("gps", "GPS", "available") } }
AS.result = "checked"
launch("store")
check(shows("Firmware abc12345") and shows("Clock") and not shows("Music"), "store: Updates lists firmware and newer apps")
key("enter")
check(lastrun() == "check " and shows("restarts"), "store: Enter on the firmware asks first (it restarts)")
key("y")
check(lastrun() == "apply firmware", "store: yes downloads the firmware")
key("down"); key("space"); key("enter")
check(lastrun() == "apply install:clock", "store: Space marks, Enter installs what is marked")
key("tab")
check(shows("Music") and shows("GPS") and not shows("Snake"), "store: Browse lists apps you don't have")
key("g"); key("p")
check(shows("Search: gp") and shows("GPS") and not shows("Music"), "store: typing searches Browse")
key("enter")
check(lastrun() == "apply install:gps", "store: Enter installs from Browse")
key("esc")
check(shows("Music") and shell.app() == "store", "store: Esc clears the search first")
key("tab")
check(shows("Settings") and shows("Snake") and not shows("Editor"), "store: Installed lists your apps, not the editor")
key("down"); key("x")  -- rows: Clock, Settings, Snake
check(lastrun() == "apply install:gps" and not shows("Uninstall"), "store: system apps can't be uninstalled")
key("down"); key("x"); key("y")
check(lastrun() == "apply remove:snake", "store: X and confirm uninstalls")
local function updates_tab()  -- the store reopens on the last tab
  for _ = 1, 3 do if shows("Everything is up to date") or shows("Firmware abc12345") or shows("Clock") and not shows("Settings") then return end; key("tab") end
end
launch("store"); updates_tab()
check(shows("Firmware abc12345"), "store: (control) a newer firmware is offered")
AS.cat.firmware.status = "older"
launch("store"); updates_tab()
check(not shows("Firmware abc12345") and shows("Clock") and not shows("Settings"), "store: an older firmware is not offered")
AS.result = "1 app installed"
launch("store")
check(shows("1 app installed"), "store: shows what the last run did")
AS.result = "error: Wi-Fi isn't connected (Settings > Wi-Fi)"
launch("store")
check(shows("Wi-Fi isn't connected"), "store: shows errors")
no_error("store")
key("esc")
check(shell.app() ~= "store" and shell.app() ~= "error", "Esc leaves the store (back to the previous app or home)")

-- ---------------------------------------------------------------- Settings > About > Updates
local function updates_row()
  launch("settings")
  for _ = 1, 6 do key("down") end
  key("enter")   -- About
  key("down")    -- Updates
end
AS.runs = {}
AS.channel = "beta"
updates_row()
check(shows("Updates") and drew("Beta"), "channel: About shows Updates: Beta")
key("enter")
check(shows("Leave Beta") and shows("older"), "channel: leaving Beta asks first, with a warning")
key("n")
check(lastrun() == "", "channel: N keeps Beta")
key("enter"); key("y")
check(lastrun() == "switch main" and not shows("Type RELEASE"), "channel: Y switches to Release, no typing")
shell.home(); frames(2)
AS.runs = {}
AS.channel = "main"
updates_row()
check(drew("Release"), "channel: About shows Updates: Release")
key("enter")
check(shows("Join Beta"), "channel: joining Beta asks once")
key("y")
check(lastrun() == "switch beta" and not shows("Type RELEASE"), "channel: yes switches to Beta, no typing")
shell.home(); frames(2)
AS.runs = {}
updates_row()
key("right")
check(shows("Join Beta"), "channel: <> (the footer's Change) asks too")
key("n")
check(lastrun() == "", "channel: no keeps the channel")
no_error("settings")
shell.home(); frames(2)

-- ================================================================ all five survive random keys
for _, name in ipairs({ "clock", "notes", "calc", "images", "store" }) do
  launch(name)
  for _, k in ipairs({ "tab", "down", "up", "left", "right", "enter", "esc", "tab", "x", "n", "1", "backspace", "esc" }) do
    key(k)
    if shell.app() == "error" then break end
  end
  frames(3)
  check(shell.app() ~= "error", name .. " survives key mashing")
  shell.home(); frames(2)
end

say(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
