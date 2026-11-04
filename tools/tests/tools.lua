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

dofile("userland/boot.lua")

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
sys.write_text("sd:/screenshots/shot_001.bmp", "BM")
sys.write_text("sd:/screenshots/shot_002.bmp", "BM")
sys.write_text("sd:/images/cat.jpg", "\255\216")
launch("images")
frames(120)  -- let earlier toasts expire: the shell lifts the hold while one is showing
check(shows("shot_002.bmp") and shows("shot_001.bmp") and shows("cat.jpg"), "images from both folders are listed")
hw_calls = {}
key("enter")
local function last_image()
  for i = #hw_calls, 1, -1 do if hw_calls[i][1] == "image" then return hw_calls[i][2], hw_calls[i] end end
end
check(held and last_image() == "sd:/screenshots/shot_002.bmp", "Enter holds the display and draws the newest screenshot")
local n = #hw_calls
frames(5)
check(#hw_calls == n, "no redraw while the picture is unchanged")
key("right")
check(last_image() == "sd:/screenshots/shot_001.bmp", "right shows the next image")
key("right")
check(last_image() == "sd:/images/cat.jpg", "and the next folder")
key("right")
check(last_image() == "sd:/screenshots/shot_002.bmp", "wraps around")
key("left")
check(last_image() == "sd:/images/cat.jpg", "left goes back")
local caption = false
for _, c in ipairs(hw_calls) do if c[1] == "dtext" and tostring(c[4]):find("cat.jpg") then caption = true end end
check(caption, "caption bar names the image")
key("esc")
check(not held and shell.app() == "images", "Esc returns to the list and releases the display")
key("enter"); frames(120)
check(held, "viewing again holds the display")
shell.home(); frames(2)
check(not held, "closing the app releases the display")
shell.open_file("sd:/screenshots/shot_001.bmp"); frames(120)
check(shell.app() == "images" and held and last_image() == "sd:/screenshots/shot_001.bmp", "open_file shows the image")
key("esc")
check(not held, "Esc leaves the viewer")
key("down"); key("down"); key("x"); key("y")
check(not sys.exists("sd:/images/cat.jpg") and not shows("cat.jpg"), "X deletes an image")
no_error("images")
key("esc")
check(shell.app() == "home", "Esc goes home from images")

-- ================================================================ App Store
local DEMO = 'local app = { title = "Demo", icon = "app", category = "tools" }\n' ..
  'function app.draw() ui.center(60, "demo") ui.footer({ { "Esc", "Home" } }) end\nreturn app\n'
sys.write_text("sd:/liveos-apps/demo.lua", DEMO)
sys.write_text("sd:/liveos-apps/bad.lua", "print('hi')\n")
sys.write_text("sd:/liveos-apps/split.lua", "local app = {\n  title = \"Split\" }\nreturn app\n")
launch("store")
check(shell.app() == "store", "store launches")
check(shows("Demo") and shows("bad.lua"), "SD apps are listed by title")
-- rows are sorted by title: bad.lua, Demo, split.lua
key("enter")
check(shows("Not a LiveOS app") and not sys.exists("apps/bad.lua"), "a file without a header is refused")
key("down"); key("down"); key("enter")
check(not sys.exists("apps/split.lua"), "a header split over lines is refused")
key("up"); key("enter")
check(shows("is installed"), "install asks to open the app")
key("n")
check(shows("installed"), "the SD list marks the app installed")
check(sys.read_text("apps/demo.lua") == DEMO, "Enter installs the app into apps/demo.lua")
key("enter")
check(shows("Replace app"), "installing again asks before overwriting")
key("y")
check(shows("is installed"), "overwrite confirmed")
key("y"); frames(2)
check(shell.app() == "demo", "the installed app opens")
launch("store")
-- web
key("tab")
check(shows("Wi-Fi connected"), "web tab shows Wi-Fi state")
key("enter"); for _ = 1, 7 do key("backspace") end
local plain_dl = http.download
http.download = function(url, path) sys.write_text(path, "Sunny +18C"); return 10, 200 end  -- not an app
type_text("x/forecast.lua"); key("enter"); frames(3)
http.download = plain_dl
check(shows("Not a LiveOS app"), "a download without a header is refused")
local got_url, got_max
local real_dl = http.download
local function serve(body, code)  -- fake server: http.download writes the body to the file
  http.download = function(url, path, max)
    got_url, got_max = url, max
    if not body then return nil, code end
    sys.write_text(path, body)
    return #body, code
  end
end
serve('local app = { title = "Web App", icon = "app" }\nreturn { title = "Web App" }\n', 200)
key("enter"); for _ = 1, 40 do key("backspace") end
type_text("example.com/apps/webapp.lua"); key("enter"); frames(3)
check(got_url == "http://example.com/apps/webapp.lua" and got_max == 32768, "http.download gets the URL with a 32K limit")
check(cfg.get("store_url") == "http://example.com/apps/webapp.lua", "last URL is remembered")
check(shows("Save Web App as") and shows("webapp"), "name prompt offers the file name")
key("enter")
check(sys.exists("apps/webapp.lua"), "web app is saved")
key("n")
serve(nil, "connection refused")
key("enter"); key("enter"); frames(3)
check(shows("Download failed"), "download errors are shown")
serve("<html>404</html>", 404)
key("enter"); key("enter"); frames(3)
check(shows("Server replied 404"), "HTTP status errors are shown")
serve('local app = { title = "Home" }\n', 200)
key("enter"); key("enter"); frames(2)
for _ = 1, 10 do key("backspace") end
type_text("home"); key("enter")
check(shows("Built-in name"), "a built-in app name is refused")
key("esc")
http.download = real_dl
wifi.status = function() return "off" end
cfg.set("wifi_ssid", nil)
key("enter")
check(shows("Settings > Wi-Fi"), "without Wi-Fi it explains what to do")
wifi.status = function() return "connected" end
-- installed
key("tab")
check(shows("Demo") and shows("Web App"), "installed apps are listed")
check(not shows("Calculator") and not shows("Task Manager"), "built-in apps are not listed")
for _ = 1, 3 do key("up") end
key("x")
check(shows("Uninstall"), "X asks before removing")
key("y")
check(not sys.exists("apps/demo.lua"), "X removes the app")
key("x"); key("y")
check(not sys.exists("apps/webapp.lua") and shows("No apps installed"), "all installed apps removed")
no_error("store")
key("esc")
check(shell.app() ~= "store" and shell.app() ~= "error", "Esc leaves the store (back to the previous app or home)")

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
