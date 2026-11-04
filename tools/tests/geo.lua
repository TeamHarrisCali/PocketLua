-- Headless tests for the LoRa Chat, GPS and Steps apps.
-- Run from the project root:  lua5.4 tools/tests/geo.lua
local say = print
local src = assert(io.open("tools/host_test.lua")):read("a")
assert(load(src:match("^(.-)%-%- %-+ helpers"), "=stubs"))()
dofile("userland/boot.lua")
local fails = 0
local function check(c, m) if c then say("ok:   " .. m) else fails = fails + 1; say("FAIL: " .. m) end end
local function frames(n) for _ = 1, n or 3 do on_frame(0.033); on_draw(); on_draw(); on_draw() end end
local function key(name, mods)
  local k = { key = name }
  if #name == 1 then k.text = name end
  for m in pairs(mods or {}) do k[m] = true end
  on_key(k); frames(1)
end
local function type_text(s) for c in s:gmatch(".") do key(c) end end
local function secs(s) frames(math.ceil(s / 0.033)) end

-- record the text drawn in the last frame
local screen = {}
local text0 = gfx.text
gfx.text = function(x, y, s, c, size) screen[#screen + 1] = tostring(s); return text0(x, y, s, c, size) end
local function shows(pat)
  screen = {}
  frames(1)
  for _, s in ipairs(screen) do if s:find(pat) then return s end end
end
local tones = {}
snd.tone = function(f) tones[#tones + 1] = f end

local function calls(name)
  local out = {}
  for _, c in ipairs(hw_calls) do if c[1] == name then out[#out + 1] = c end end
  return out
end
local function sent(pat)
  for _, c in ipairs(calls("lora_send")) do if tostring(c[2]):find(pat) then return c[2] end end
end

frames(3)

-- ------------------------------------------------------------ geo math
local geo = require("geo_math")
local d = geo.dist(37.77, -122.42, 37.78, -122.41)
check(d > 1380 and d < 1450, string.format("haversine 37.77,-122.42 -> 37.78,-122.41 = %.0f m", d))
local b = geo.bearing(37.77, -122.42, 37.78, -122.41)
check(b > 35 and b < 45 and geo.compass(b) == "NE", string.format("bearing %.1f deg %s", b, geo.compass(b)))
check(math.abs(geo.bearing(0, 0, -1, 0) - 180) < 0.01 and geo.compass(270) == "W", "bearing south, compass west")
check(geo.fmt_dist(850) == "850m" and geo.fmt_dist(1414) == "1.4km" and geo.fmt_dist(23000) == "23km", "distance labels")
unload("geo_math")

-- ------------------------------------------------------------ LoRa Chat
local queue = {}
lora.recv = function() return table.remove(queue, 1) end
local busy = false
lora.busy = function() return busy end
cfg.set("lora_beacon", nil)
hw_calls = {}
shell.launch("lorachat"); frames(3)
check(shell.app() == "lorachat", "lorachat opens")
local lb = calls("lora_begin")[1]
check(lb and lb[2] == 915.0 and lb[3] == 9, "lora.begin(915, 9) from defaults")
check(#calls("gps_start") == 1, "lorachat starts the GPS")

type_text("hello|there"); key("enter"); frames(2)
check(sent("^M|CP%-AAAA|hellothere$"), "Enter sends M|CP-AAAA|hellothere ('|' stripped)")
check(shows("me: hellothere"), "own message shown in the log")

busy = true
type_text("wait"); key("enter"); frames(5)
check(not sent("|wait$"), "nothing is sent while lora.busy()")
busy = false; frames(2)
check(sent("^M|CP%-AAAA|wait$"), "queued message goes out when the radio is free")

local ntones = #tones
queue[#queue + 1] = { data = "M|bob|hi there", rssi = -60, snr = 7 }
queue[#queue + 1] = { data = "P|bob|37.78|-122.41|10", rssi = -61, snr = 6.5 }
queue[#queue + 1] = { data = "M|CP-AAAA|echo of myself", rssi = -40, snr = 9 }
frames(10)
check(shows("bob: hi there"), "received message appears in the log")
check(not shows("echo of myself"), "own callsign is ignored")
check(#tones > ntones and tones[ntones + 1] == 1319, "incoming message plays the notify sound")

secs(4)
check(sent("^P|CP%-AAAA|37%.77000|%-122%.42000|12$"), "position beacon P|call|lat|lon|alt sent with a fix")

key("tab"); frames(40)
local row = shows("^bob")
check(row and row:find("1%.4km NE"), "peer bob has distance and bearing: " .. tostring(row))
check(shows("^%-6[01] %d+s$"), "peer row shows RSSI and age")
key("enter"); frames(1)
check(shows("SNR 6%.5"), "Enter on a peer shows its details")
key("esc")

key("tab"); frames(3)
check(shows("^Spreading factor$"), "Setup tab lists settings")
hw_calls = {}
key("down"); key("down"); key("enter"); frames(2)
lb = calls("lora_begin")[1]
check(lb and lb[3] == 10 and cfg.get("lora_sf") == "10", "changing SF re-runs lora.begin with SF10")
hw_calls = {}
key("up"); key("enter"); frames(2)
lb = calls("lora_begin")[1]
check(lb and lb[2] == 868.0 and cfg.get("lora_freq") == "868.0", "frequency switches to 868")
key("down"); key("down"); key("enter"); frames(2)
check(cfg.get("lora_beacon") == "120", "beacon interval cycles 60 -> 120")
key("up"); key("up"); key("up"); key("enter"); frames(2)
for _ = 1, 7 do key("backspace") end
type_text("ZED|1"); key("enter"); frames(2)
check(cfg.get("lora_call") == "ZED1", "callsign set via prompt ('|' stripped)")

hw_calls = {}
shell.home(); frames(2)
check(#calls("lora_stop") == 1 and #calls("gps_stop") == 1, "close() stops the radio and the GPS")
local still_loaded = false
for _, mod in ipairs(modules()) do if mod.name == "geo_math" then still_loaded = true end end
check(not still_loaded, "geo_math is unloaded on close")

-- radio failure: empty state instead of an error
local real_begin = lora.begin
lora.begin = function() return false, "LoRa cap not found" end
shell.launch("lorachat"); frames(3)
check(shell.app() == "lorachat", "lora.begin failure does not crash")
check(shows("LoRa cap not found") and shows("Attach the Cap LoRa%-1262"), "failure shows ui.empty with the reason")
key("tab"); key("tab")
check(shows("^Frequency$"), "Setup still reachable without the radio")
key("esc")
check(shell.app() == "home", "Esc goes home")
lora.begin = function() error("boom") end
shell.launch("lorachat"); frames(3)
check(shell.app() == "lorachat" and shows("boom"), "an erroring lora.begin is shown too")
shell.home(); frames(2)
lora.begin = real_begin
cfg.set("lora_call", nil); cfg.set("lora_sf", nil); cfg.set("lora_freq", nil); cfg.set("lora_beacon", nil)

-- ------------------------------------------------------------ GPS
local pos = { valid = true, lat = 37.77, lon = -122.42, chars = 500, speed = 12.3, course = 47 }
gps.read = function()
  return { valid = pos.valid, lat = pos.lat, lon = pos.lon, alt = 12, sats = 7, hdop = 1.1, speed = pos.speed,
    course = pos.course, time = "12:00:00", date = "2026-11-03", chars = pos.chars }
end
cfg.set("gps_units", nil)
hw_calls = {}
shell.launch("gps"); frames(20)
check(shell.app() == "gps" and #calls("gps_start") == 1, "gps opens and starts the GPS")
check(shows("^37%.770000$") and shows("^%-122%.420000$"), "Fix tab shows lat/lon to 6 decimals")
check(shows("12:00:00 UTC") and shows("^7$"), "Fix tab shows UTC time and satellites")

key("tab")
check(shows("^12%.3$") and shows("km/h") and shows("Course 47 NE"), "Speed tab: 12.3 km/h, course NE")
key("u")
check(cfg.get("gps_units") == "mph" and shows("^7%.6$") and shows("^mph$"), "U switches to mph")
key("u")

key("tab"); key("r"); frames(20)
check(shows("^0 m$"), "trip starts at 0 m")
for _ = 1, 10 do pos.lat = pos.lat + 0.0001; frames(20) end
local t = shows("^%d+ m$")
local m = t and tonumber(t:match("%d+"))
check(m and m >= 100 and m <= 125, "trip distance grows with movement: " .. tostring(t))
for i = 1, 20 do pos.lat = pos.lat + (i % 2 == 0 and 0.00002 or -0.00002); frames(20) end
local t2 = shows("^%d+ m$")
check(t2 == t, "GPS jitter under 5 m is ignored: " .. tostring(t2))
check(shows("km/h") , "trip shows an average speed")

key("l")
local logname = shows("track_%d+%.csv")
check(logname, "L starts logging: " .. tostring(logname))
secs(11)
local f = sys.read_text("data/gps/track_001.csv")
check(f and f:find("^time,lat,lon,alt,speed\n") and select(2, f:gsub("\n", "")) >= 3, "CSV has a header and lines")
check(f and f:find("2026%-11%-03T12:00:00Z,37%.77%d+,%-122%.42%d+,12%.0,12%.3\n"), "CSV line format")
key("l")
check(shows("every 5 s"), "L stops logging")

key("r"); frames(2)
check(shows("^0 m$"), "R resets the trip")

pos.valid, pos.chars = false, 0
key("tab"); secs(6)
check(shows("No GPS data %- is the Cap attached%?"), "no NMEA for 5 s shows the no-data state")
pos.chars = 300; secs(1)
check(shows("Waiting for fix %- go outside"), "NMEA but no fix shows the waiting state")
hw_calls = {}
shell.home(); frames(2)
check(#calls("gps_stop") == 1, "gps close() stops the GPS")

-- ------------------------------------------------------------ Steps
local it, still = 0, false
imu.read = function()
  it = it + 0.033
  if still then return { ax = 0.01 * math.sin(it * 37), ay = 0.01, az = 1 + 0.015 * math.sin(it * 53), gx = 0, gy = 0, gz = 0 } end
  local w = math.sin(2 * math.pi * 2 * it)  -- 2 steps per second
  return { ax = 0.05, ay = 0.1 * w, az = 1 + 0.35 * w, gx = 0, gy = 0, gz = 0 }
end
cfg.set("steps_day", "2026-11-02"); cfg.set("steps_n", "999"); cfg.set("steps_goal", nil)
still = true
shell.launch("steps"); frames(3)
check(shell.app() == "steps" and cfg.get("steps_day") == "2026-11-03" and cfg.get("steps_n") == "0",
  "a new day starts at 0 steps")
check(shows("Counting while open"), "UI says it counts while open")
secs(5)
check(shows("^0$"), "no steps while still")
still = false
secs(10)
local n = tonumber(shows("^%d+$"))
check(n and n >= 18 and n <= 21, "10 s of walking at 2 steps/s counts ~20: " .. tostring(n))
check(shows("km$"), "distance estimate shown")
key("+")
check(cfg.get("steps_goal") == "6500" and shows("of 6500"), "+ raises the goal to 6500")
key("-"); key("-")
check(cfg.get("steps_goal") == "5500", "- lowers the goal")
shell.home(); frames(2)
check(cfg.get("steps_n") == tostring(n), "count persisted on close")
shell.launch("steps"); frames(2)
check(shows("^" .. n .. "$"), "count restored on reopen")
still = true
key("r"); key("y"); frames(2)
check(shows("^0$") and cfg.get("steps_n") == "0", "R resets today")
-- fast vibration must not exceed the minimum step interval
local fast = 0
imu.read = function()
  fast = fast + 0.033
  return { ax = 0, ay = 0, az = 1 + 0.5 * math.sin(2 * math.pi * 6 * fast), gx = 0, gy = 0, gz = 0 }
end
secs(3)
local nf = tonumber(shows("^%d+$"))
check(nf and nf <= 11, "minimum step interval caps the rate: " .. tostring(nf) .. " in 3 s")
shell.home(); frames(2)

say(fails == 0 and "all passed" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
