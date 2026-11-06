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
-- the emulator's clock is Tuesday 3 November 2026, 14:07
cfg.set("alarms", "08:00|Standup;bad;09:15")
launch("clock")
check(shell.app() == "clock", "clock launches")
check(drew("14:07") and shows("Tuesday, 3 November 2026"), "clock tab shows time and date")
check(shows("Alarm 08:00 Standup  in 17h 53m"), "clock tab shows the next alarm and how long until it")
key("tab")
check(shows("08:00  Standup") and shows("09:15") and shows("+ New alarm") and shows("Snooze length"),
  "alarms are listed (old format read, bad entry skipped) with New and Snooze rows")
key("space")
check(cfg.get("alarms") == "08:00|Standup|0d;09:15||1d", "Space turns an alarm off (saved with flags)")
key("space")
check(cfg.get("alarms") == "08:00|Standup|1d;09:15||1d", "and on again")
-- new alarm in the editor
key("a")
check(shows("NEW ALARM") and shows("15:00"), "A opens the editor at the next hour")
type_text("0730")
check(shows("07:30"), "typing 0730 sets the time")
key("p")
check(shows("19:30"), "p makes it PM")
key("a")
check(shows("07:30"), "a makes it AM")
key("right")
check(shows("07:31"), "<> moves a minute")
key("left")
key("down"); key("enter"); type_text("Wake up"); key("enter")
check(shows("Wake up"), "the label is typed in a prompt")
key("down"); key("right")
check(shows("Weekdays"), "<> on Repeat changes the days")
key("down"); key("enter")
check(cfg.get("alarms") == "07:30|Wake up|1w;08:00|Standup|1d;09:15||1d", "Add alarm saves it, sorted, with its days")
check(shows("Alarm set for 07:30 (Weekdays)"), "and says so")
key("a"); type_text("2500")
check(shows("Use 24-hour HHMM"), "an impossible time is refused with a hint")
key("esc")
check(not shows("NEW ALARM") and cfg.get("alarms") == "07:30|Wake up|1w;08:00|Standup|1d;09:15||1d", "Esc cancels the editor")
key("a"); type_text("0800"); key("down"); key("enter"); type_text("Standup"); key("enter")
key("down"); key("down"); key("enter")
check(shows("already exists"), "a duplicate is refused")
key("esc")
-- edit, delete
for _ = 1, 5 do key("up") end
key("enter")
check(shows("EDIT ALARM") and shows("07:30"), "Enter edits the selected alarm")
key("left"); key("enter")
check(cfg.get("alarms") == "07:29|Wake up|1w;08:00|Standup|1d;09:15||1d", "Enter on the time saves the change")
key("x")
check(cfg.get("alarms") == "08:00|Standup|1d;09:15||1d", "X deletes the selected alarm")
-- snooze length
for _ = 1, 5 do key("down") end
key("right")
check(cfg.get("snooze") == "2" and shows("2 min"), "<> on Snooze length sets it")
-- an alarm rings at its minute; a weekend one doesn't on a Tuesday
cfg.set("alarms", "14:08|Test|1d;14:08|Weekend|1e")
local real_now = clock.now
clock.now = function() local t = real_now(); t.m = 8; return t end
frames(40)
check(shell.ringing and shell.ringing.title == "14:08" and shell.ringing.label == "Test", "an alarm rings at its time")
shell.ring_end(true)
check(shell.snooze == "+2 min", "snoozing uses the snooze length")
shell.snooze = nil
clock.now = real_now
cfg.set("alarms", nil)
-- timer
launch("clock")
key("tab")
check(drew("05:00"), "timer starts at the 5 minute preset")
key("right")
check(drew("10:00"), "<> picks the next preset")
key("enter")
local before = #shell.timers
check(shell.timers[#shell.timers].total == 600 and shell.timers[#shell.timers].label == "10 min timer",
  "Enter starts it")
type_text("7"); key("enter")
check(#shell.timers == before + 1 and shell.timers[#shell.timers].total == 420, "typed minutes start a 7 minute timer")
frames(10)
check(shows("10 min timer") and shows("7 min timer"), "running timers are listed")
key("space")
check(shell.timers[#shell.timers].paused and shows("(paused)"), "Space pauses the selected timer")
key("space")
check(not shell.timers[#shell.timers].paused, "and resumes it")
key("up"); key("x")
check(#shell.timers == before and shell.timers[#shell.timers].total == 420, "X cancels the selected timer")
shell.timers[#shell.timers].left = 0.01
frames(3)
check(shell.ringing and shell.ringing.title == "7 min timer done", "a finished timer rings")
shell.ring_end(false)
-- stopwatch
key("tab")
check(drew("00:00.00"), "stopwatch starts at zero")
key("enter"); frames(10)
key("l"); frames(5)
key("l"); frames(20)
key("l")
key("enter")
check(shows("Lap 1") and shows("Lap 3"), "laps are listed")
check(not drew("00:00.00"), "stopwatch counted time")
key("r")
check(drew("00:00.00") and not shows("Lap 1"), "R resets")
-- study
key("tab")
check(shows("Start focus") and shows("25 / 5 min") and shows("every 4, 15m"), "study shows its plan")
key("enter")
local pomo
for _, t in ipairs(shell.timers) do if t.pomo then pomo = t end end
check(pomo and pomo.total == 1500 and pomo.pomo == "work" and pomo.every == 4 and pomo.long == 900,
  "Enter starts 25 min of focus with a long break every 4")
frames(3)
check(shows("FOCUS") and drew("25:00") and shows("Session 1 of 4"), "focus shows the phase, time and session")
key("space")
check(pomo.paused and shows("Resume"), "Space pauses the session")
key("space")
key("s"); frames(3)
for _, t in ipairs(shell.timers) do if t.pomo then pomo = t end end
check(pomo.pomo == "break" and pomo.total == 300 and shows("BREAK"), "S skips to the break")
check(cfg.get("study_min") == "25" and cfg.get("study_n") == "1" and shows("Today 25m  1 session"),
  "a finished focus phase counts in today's stats")
for _ = 1, 3 do  -- break, focus, ... until the 4th focus phase ends
  key("s"); frames(2)
  key("s"); frames(2)
end
frames(10)  -- the screen refreshes every 0.25 s
for _, t in ipairs(shell.timers) do if t.pomo then pomo = t end end
check(pomo.pomo == "long" and pomo.total == 900 and shows("LONG BREAK"), "after 4 sessions comes a long break")
check(shows("Today 1h 40m  4 sessions"), "four sessions: 1h 40m")
-- leave the app: the cycle keeps going in the shell
shell.home(); frames(2)
shell.finish_timer(pomo); frames(2)
for _, t in ipairs(shell.timers) do if t.pomo then pomo = t end end
check(pomo.pomo == "work", "with the app closed the long break ends and focus starts again")
launch("clock")
check(shows("FOCUS"), "the clock reopens on the running session")
key("x")
local still = false
for _, t in ipairs(shell.timers) do if t.pomo then still = true end end
check(not still and shows("Start focus"), "X stops the session")
key("down"); key("right")
check(shows("50 / 10 min") and cfg.get("study_plan") == "2", "<> changes the plan")
key("down"); key("down"); key("enter"); type_text("Biology"); key("enter")
check(cfg.get("study_task") == "Biology" and shows("Biology"), "the task is typed in a prompt")
key("down"); key("enter")
check(cfg.get("study_quiet") == "1" and shows("Quiet focus on"), "Quiet focus turns on")
key("enter")
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

-- ================================================================ Settings > Sound
launch("settings")
for _ = 1, 3 do key("down") end
key("enter")
check(shows("Volume") and shows("Headphones") and shows("Headphone max") and shows("50%"), "sound: headphone rows")
key("down"); key("enter")
check(cfg.get("hp") == "1" and shows("Headphones: up to 50%"), "sound: Enter turns headphone mode on")
key("down"); key("right")
check(shows("55%") and tonumber(cfg.get("hp_max")) == 55, "sound: <> sets the headphone maximum")
key("left"); key("up"); key("enter")
check(cfg.get("hp") == "0" and shows("Speaker volume"), "sound: and off again")
no_error("settings")
shell.home(); frames(2)

-- ================================================================ Settings > Backup
-- a fake backup module (the real one is native: src/backup.cpp)
local BK = { list = {}, made = 0, restored = nil, removed = nil }
backup = {
  list = function() return BK.list end,
  make = function()
    BK.made = BK.made + 1
    table.insert(BK.list, 1, { name = "b0001-20261104-1732.plb", date = "2026-11-04 17:32", size = 2100 })
    return "b0001-20261104-1732.plb", 3, 2100
  end,
  restore = function(name) BK.restored = name; return nil, "test" end,
  remove = function(name) BK.removed = name; table.remove(BK.list, 1); return true end,
}
launch("settings")
for _ = 1, 6 do key("down") end
key("enter")
check(shows("Back up now") and shows("never") and shows("No backups yet"), "backup: page shows none yet")
key("enter")
check(BK.made == 1 and shows("Backed up 3 files (3 KB)") and shows("2026-11-04 17:32"), "backup: Back up now makes one and lists it")
key("down"); key("enter")
check(shows("Restore") and shows("Delete"), "backup: a backup offers Restore and Delete")
key("1")
check(shows("Replace settings"), "backup: restore asks first")
key("y")
check(BK.restored == "b0001-20261104-1732.plb" and shows("Restore failed: test"), "backup: yes restores that backup (errors shown)")
key("enter"); key("2"); key("y")
check(BK.removed == "b0001-20261104-1732.plb" and shows("No backups yet"), "backup: delete removes it")
no_error("settings")
shell.home(); frames(2)

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
  for _ = 1, 7 do key("down") end
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
