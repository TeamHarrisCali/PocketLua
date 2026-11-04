-- Headless tests for the net/sensor apps: irremote, weather, network, sensors,
-- airmouse. Run from the project root:  lua5.4 tools/tests/net.lua
local say = print
local src = assert(io.open("tools/host_test.lua")):read("a")
assert(load(src:match("^(.-)%-%- %-+ helpers"), "=stubs"))()
dofile("tools/emu/boot.lua")

local fails = 0
local function check(c, m) if c then say("ok:   " .. m) else fails = fails + 1; say("FAIL: " .. m) end end
local function frames(n) for _ = 1, n or 3 do on_frame(0.033); on_draw(); on_draw(); on_draw() end end
local function key(name, mods)
  local k = { key = name }
  if #name == 1 then k.text = name elseif name == "space" then k.text = " " end
  for m in pairs(mods or {}) do k[m] = true end
  on_key(k)
  frames(1)
end
local function type_text(s) for c in s:gmatch(".") do key(c) end end
local function calls(name)
  local out = {}
  for _, c in ipairs(hw_calls) do if c[1] == name then out[#out + 1] = c end end
  return out
end
local function last(name) local c = calls(name); return c[#c] end
local function reset() for i = #hw_calls, 1, -1 do hw_calls[i] = nil end end
local function open(name)
  shell.home(); frames(2)
  shell.launch(name); frames(3)
  check(shell.app() == name, name .. " opens")
end
local function alive(name) check(shell.app() == name, name .. " still running (no error screen)") end

frames(3)

-- ------------------------------------------------------------ IR remote
cfg.set("ir_brand", nil)
open("irremote")
reset()
key("enter")                               -- Power, Samsung
local c = last("ir")
check(c and c[2] == "samsung" and c[3] == 0x07 and c[4] == 0x02, "Samsung power is sent")
key("=")
c = last("ir")
check(c and c[4] == 0x07, "= sends Samsung Vol+")
key("a")                                   -- 16-bit Samsung address
key("m")
c = last("ir")
check(c and c[3] == 0x0707 and c[4] == 0x0F, "A switches the Samsung address to 0x0707")
key("a")
key("tab")                                 -- LG
check(cfg.get("ir_brand") == "lg", "brand is remembered")
key("]")
c = last("ir")
check(c and c[2] == "nec" and c[3] == 0x04 and c[4] == 0x00, "LG Ch+ is NEC 0x04/0x00")
key("tab")                                 -- Sony
key("i")
c = last("ir")
check(c and c[2] == "sony" and c[3] == 0x01 and c[4] == 0x25 and c[5] == 2 and c[6] == 12, "Sony input: 12 bits, 2 repeats")
key("left"); key("down"); key("enter")     -- Input -> Ch+ -> Ch- (row 2)
c = last("ir")
check(c and c[4] == 0x11, "arrows move through the grid (Sony Ch-)")
key("b")
check(cfg.get("ir_brand") == "samsung", "B / Brand cell cycles the brand")
for _, k in ipairs({ "p", "-", "[", "left", "up", "space" }) do key(k) end
alive("irremote")
key("esc")
check(shell.app() == "home", "Esc leaves IR Remote")

-- ------------------------------------------------------------ Weather
local real_get = http.get
local urls = {}
http.get = function(url) urls[#urls + 1] = url
  return "Boston, Massachusetts|+18\xC2\xB0F|Partly cloudy |65%|\xE2\x86\x935mph|0.0in\n", 200 end
cfg.set("wx_last", nil); cfg.set("wx_loc", nil); cfg.set("wx_units", nil)
open("weather")
frames(4)
check(urls[1] == "http://wttr.in/?format=%l|%t|%C|%h|%w|%p&u", "fetches wttr.in with auto location, US units")
check(cfg.get("wx_last") and cfg.get("wx_last"):find("Partly cloudy", 1, true), "reply is cached")
check(cfg.get("wx_time") ~= nil, "fetch time is cached")
key("u"); frames(3)
check(urls[#urls]:sub(-2) == "&m" and cfg.get("wx_units") == "m", "U switches to metric and refetches")
key("l"); frames(1)
type_text("New York"); key("enter"); frames(3)
check(cfg.get("wx_loc") == "New York" and urls[#urls]:find("wttr.in/New+York?", 1, true), "L sets the location (URL-encoded)")
local n = #urls
key("r"); frames(3)
check(#urls == n + 1, "R refreshes")
http.get = function() return "Unknown location; please try ~40.7,-74.0", 404 end
key("r"); frames(3)
alive("weather")
-- offline: cached data shows, Enter asks to connect
http.get = real_get
wifi.status = function() return "idle" end
cfg.set("wifi_ssid", "Home"); cfg.set("wifi_pass", "pw")
open("weather")
frames(2)
local conn = 0
local real_connect = wifi.connect
wifi.connect = function() conn = conn + 1 end
key("enter")
check(conn == 1, "Enter connects to the saved Wi-Fi when offline")
wifi.connect = real_connect
-- no cache, offline: empty state
cfg.set("wx_last", nil)
open("weather")
frames(2)
alive("weather")
wifi.status = function() return "connected" end
frames(4)
alive("weather")
cfg.set("wifi_ssid", nil); cfg.set("wifi_pass", nil)
key("esc")
check(shell.app() == "home", "Esc leaves Weather")

-- ------------------------------------------------------------ Network
local real_result = wifi.scan_result
local scans = 0
local real_scan = wifi.scan_start
wifi.scan_start = function() scans = scans + 1 end
wifi.scan_result = function()
  local r = {}
  for i = 1, 30 do r[i] = { ssid = "Net" .. i, rssi = -30 - i * 2, secure = i % 2 == 0, channel = (i % 13) + 1, bssid = "aa:bb" } end
  r[31] = { ssid = "", rssi = -90, secure = false }   -- no channel
  return r
end
open("network")
frames(20)
check(scans == 1, "Scan tab starts a scan")
for _ = 1, 25 do key("down") end
alive("network")
key("enter")
key("r"); frames(20)
check(scans == 2, "R rescans")
key("tab"); frames(3)                    -- Info
alive("network")
key("enter")
key("tab")                               -- Tools
key("enter"); frames(1)                  -- DNS lookup...
for _ = 1, 11 do key("backspace") end
type_text("example.org"); key("enter"); frames(3)
key("up"); key("enter"); frames(1)       -- TCP ping... (DNS result row was selected)
type_text(":443"); key("enter"); frames(3)
alive("network")
check(shell.app() == "network", "tools run DNS and ping without errors")
key("x")
key("tab", { shift = true })             -- back to Info
key("tab", { shift = true })             -- Scan (reopens there)
key("esc")
check(shell.app() == "home", "Esc leaves Network")
wifi.scan_start, wifi.scan_result = real_scan, real_result

-- check the tool results via a fresh run with spies
local dns_q, ping_q
local real_dns, real_ping = http.dns, http.ping
http.dns = function(h) dns_q = h; return "1.2.3.4" end
http.ping = function(h, p) ping_q = h .. ":" .. tostring(p); return nil, "timeout" end
open("network")
key("tab"); key("tab")
key("enter"); frames(1)
for _ = 1, 11 do key("backspace") end
type_text("lan.test"); key("enter"); frames(3)
check(dns_q == "lan.test", "DNS lookup queries the typed host")
key("up"); key("up"); key("down"); key("enter"); frames(1)
for _ = 1, 8 do key("backspace") end
type_text("10.0.0.1:22"); key("enter"); frames(3)
check(ping_q == "10.0.0.1:22", "TCP ping uses host:port")
alive("network")
http.dns, http.ping = real_dns, real_ping
shell.home(); frames(2)

-- ------------------------------------------------------------ Sensors
local function sht_frame(t_raw, h_raw)
  local function crc(a, b)
    local c = 0xFF
    for _, v in ipairs({ a, b }) do
      c = c ~ v
      for _ = 1, 8 do if c & 0x80 ~= 0 then c = ((c << 1) ~ 0x31) & 0xFF else c = (c << 1) & 0xFF end end
    end
    return c
  end
  local t1, t2, h1, h2 = t_raw >> 8, t_raw & 0xFF, h_raw >> 8, h_raw & 0xFF
  return string.char(t1, t2, crc(t1, t2), h1, h2, crc(h1, h2))
end
check(sht_frame(0xBEEF, 0)  :byte(3) == 0x92, "test CRC helper matches the Sensirion example (0xBEEF -> 0x92)")
local real_read, real_scan2, real_rreg = i2c.read, i2c.scan, i2c.read_reg
i2c.scan = function() return { 0x23, 0x38, 0x44, 0x76 } end
local serial_ok = true
i2c.read = function(addr, n)
  if addr == 0x44 then
    if serial_ok then serial_ok = false; return sht_frame(0x1234, 0x5678) end  -- SHT4x serial reply
    return sht_frame(26214, 32768)    -- 25.0 C
  elseif addr == 0x23 then return string.char(0x01, 0x2C)   -- 300 / 1.2 = 250 lux
  elseif addr == 0x38 then return string.char(0x1C, 0x80, 0x00, 0x05, 0x99, 0x9A) end
  return string.rep("\0", n)
end
local regreads = 0
i2c.read_reg = function(_, _, n) regreads = regreads + 1; return string.char(0xAB):rep(n) end
reset()
open("sensors")
frames(80)
local w = calls("i2c_write")
local sent = {}
for _, x in ipairs(w) do sent[string.format("%02X:%s", x[2], x[3]:gsub(".", function(ch) return string.format("%02X", ch:byte()) end))] = true end
check(sent["23:10"], "BH1750 is put in continuous mode")
check(sent["38:BE0800"] and sent["38:AC3300"], "AHT20 is initialised and measured")
check(sent["44:89"] and sent["44:FD"], "SHT detected as SHT4x and measured with 0xFD")
key("down"); key("down")                 -- 0x44
key("enter"); frames(40)
alive("sensors")
key("t"); frames(40)
local w2 = calls("i2c_write")
check(w2[#w2][3] == "\x2C\x06", "T switches the sensor to SHT3x commands")
key("esc")
key("down"); key("enter")                -- 0x76 -> register view
check(regreads == 16, "unknown device shows 16 registers")
key("r")
check(regreads == 32, "R rereads the registers")
key("esc"); key("up"); key("up"); key("up"); key("enter"); frames(40)  -- BH1750 live
alive("sensors")
key("esc")
i2c.scan = function() return {} end
key("r"); frames(5)
alive("sensors")
key("esc")
check(shell.app() == "home", "Esc leaves Sensors")
i2c.read, i2c.scan, i2c.read_reg = real_read, real_scan2, real_rreg

-- ------------------------------------------------------------ Air Mouse
-- host_test's usb stub has no mouse: the app shows the disabled state
open("airmouse")
key("enter")
check(#calls("mouse_click") == 0, "mouse off: no clicks are sent")
alive("airmouse")
local real_status, real_imu = usb.status, imu.read
usb.status = function() return { keyboard = true, mouse = true, connected = true } end
local gz = 0.5
imu.read = function() return { ax = 0, ay = 0, az = 1, gx = 0.2, gy = 0.1, gz = gz } end
cfg.set("am_sens", nil); cfg.set("am_axes", nil); cfg.set("am_flags", nil)
open("airmouse")
reset()
frames(40)                               -- ~1.3 s: calibration finishes
check(#calls("mouse_move") == 0, "no movement while calibrating or still")
gz = 60
frames(5)
local mv = calls("mouse_move")
check(#mv > 0 and mv[1][2] < 0 and mv[1][3] == 0, "yaw moves the pointer sideways")
key("x"); reset(); frames(3)
mv = calls("mouse_move")
check(#mv > 0 and mv[1][2] > 0, "X inverts the horizontal axis")
check(cfg.get("am_flags") == "x", "axis choice is remembered")
key("s"); reset(); frames(3)
mv = calls("mouse_move")
check(#mv > 0 and mv[1][2] == 0 and mv[1][3] ~= 0, "S swaps the axes")
key("s"); key("x")
gz = 0.5                                 -- hold still again
key("="); key("=")
check(cfg.get("am_sens") == "7", "+ raises sensitivity")
reset()
key("enter"); key("space"); key("r")
local clicks = calls("mouse_click")
check(#clicks == 3 and clicks[1][2] == "left" and clicks[3][2] == "right", "Enter/Space left click, R right click")
key("tab")
check(last("mouse_press")[2] == "left" and last("mouse_press")[3] == true, "Tab starts a drag")
key("up")
local wheel = calls("mouse_move")
check(wheel[#wheel][4] == 1, "Up scrolls")
gz = 60
key("p"); reset(); frames(5)
check(#calls("mouse_move") == 0, "P pauses")
key("p")
key("c"); reset(); frames(10)
check(#calls("mouse_move") == 0, "C recalibrates (no movement meanwhile)")
key("a")
check(cfg.get("am_axes") == "2", "A cycles axis pairs")
key("esc")
check(shell.app() == "home", "Esc leaves Air Mouse")
check(last("mouse_press")[3] == false, "leaving releases the drag")
usb.status, imu.read = real_status, real_imu

say(string.format("\n%d failure(s)", fails))
os.exit(fails == 0 and 0 or 1)
