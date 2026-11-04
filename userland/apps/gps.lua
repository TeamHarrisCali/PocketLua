-- GPS: position, speed and a trip meter from the Cap LoRa-1262 GNSS.
-- Tab switches Fix / Speed / Trip. On Trip, R resets and L logs a CSV track
-- to sd:/gps (or data/gps without a card). The GPS only runs while open.
local col = ui.col
local app = { title = "GPS", icon = "pin", color = "green", order = 52, category = "net" }

local geo = require("geo_math")

local TABS = { "Fix", "Speed", "Trip" }
local JITTER_M = 5          -- ignore moves smaller than this (GPS wander)
local LOG_EVERY = 5         -- seconds between CSV lines
local LOG_MAX = 200000      -- bytes per CSV file before starting the next (appends are cheap)

local tab = 1
local g = nil               -- last gps.read()
local now, poll, nodata = 0, 0, 0
local mph = false
local fx = {}               -- Fix tab strings, built when a reading arrives
local spd_s, crs_s, max_s = "--", "Course --", ""
local maxspd = 0
local dist, elapsed = 0, 0  -- trip
local alat, alon = nil, nil -- trip anchor: last counted point
local trip = { d = "0 m", e = "0:00:00", a = "--" }
local logging, log_path, log_size, log_lines, log_left = false, nil, 0, 0, 0

local function unit() return mph and "mph" or "km/h" end
local function conv(kmh) return mph and kmh * 0.621371 or kmh end

local function hms(s)
  s = math.floor(s)
  return string.format("%d:%02d:%02d", s // 3600, s // 60 % 60, s % 60)
end

local function build()
  local v = g and g.valid
  if v then
    fx[1] = string.format("%.6f", g.lat)
    fx[2] = string.format("%.6f", g.lon)
    fx[3] = string.format("%.1f m", tonumber(g.alt) or 0)
  end
  fx[4] = tostring(g and g.sats or 0)
  fx[5] = string.format("%.1f", g and tonumber(g.hdop) or 0)
  fx[6] = (g and g.time ~= "" and g.time or "--:--:--") .. " UTC"
  fx[7] = g and g.date ~= "" and g.date or "----------"
  fx[8] = tostring(g and g.chars or 0)
  local kmh = v and (tonumber(g.speed) or 0) or 0
  if kmh < 0.8 then kmh = 0 end
  spd_s = v and string.format("%.1f", conv(kmh)) or "--"
  crs_s = (v and kmh >= 2) and string.format("Course %d %s", math.floor((tonumber(g.course) or 0) + 0.5),
    geo.compass(tonumber(g.course) or 0)) or "Course --"
  max_s = string.format("Max %.1f %s", conv(maxspd), unit())
  trip.d = dist >= 1000 and string.format("%.2f km", dist / 1000) or string.format("%d m", math.floor(dist + 0.5))
  if mph then trip.d = string.format("%.2f mi", dist / 1609.344) end
  trip.e = hms(elapsed)
  trip.a = elapsed >= 1 and string.format("%.1f %s", conv(dist / elapsed * 3.6), unit()) or "--"
end

local function reset_trip()
  dist, elapsed, alat, alon, maxspd = 0, 0, nil, nil, 0
  build()
end

-- Counts movement from the last counted point once it is JITTER_M away.
local function track(lat, lon)
  if not alat then alat, alon = lat, lon; return end
  local d = geo.dist(alat, alon, lat, lon)
  if d >= JITTER_M and d < 2000 then
    dist = dist + d
    alat, alon = lat, lon
  elseif d >= 2000 then
    alat, alon = lat, lon  -- a jump (lost fix, teleport): restart from here
  end
end

local function log_dir() return sys.storage() == "SD" and "sd:/gps" or "data/gps" end

local function next_file()
  local dir = log_dir()
  sys.mkdirs(dir)
  local n = tonumber(cfg.get("gps_log_n")) or 0
  for _ = 1, 999 do
    n = n % 999 + 1
    local p = string.format("%s/track_%03d.csv", dir, n)
    if not sys.exists(p) then
      cfg.set("gps_log_n", tostring(n))
      log_path, log_size = p, 0
      return true
    end
  end
  return false
end

local function log_line()
  local stamp = g.time ~= "" and ((g.date ~= "" and g.date .. "T" or "") .. g.time .. "Z") or ""
  local line = string.format("%s,%.6f,%.6f,%.1f,%.1f\n", stamp, g.lat, g.lon, tonumber(g.alt) or 0,
    tonumber(g.speed) or 0)
  if log_size + #line > LOG_MAX and not next_file() then return false end
  -- No append call exists, so read the file back and rewrite it (kept small).
  -- append only: the file is never read back, so logging costs no extra RAM
  if log_size == 0 and not sys.append_text(log_path, "time,lat,lon,alt,speed\n") then return false end
  if not sys.append_text(log_path, line) then return false end
  log_size = log_size + #line + (log_size == 0 and 23 or 0)
  log_lines = log_lines + 1
  return true
end

local function toggle_log()
  if logging then
    logging = false
    shell.toast(string.format("Log stopped: %d lines", log_lines))
    return
  end
  if not next_file() then shell.toast("No free log file name"); return end
  logging, log_lines, log_left = true, 0, 0
  shell.toast("Logging to " .. log_path:match("[^/]+$"))
end

function app.init(_, saved)
  mph = cfg.get("gps_units") == "mph"
  if saved then dist, elapsed, maxspd = saved.dist or 0, saved.el or 0, saved.max or 0 end
  if gps then pcall(gps.start) end
  build()
end

function app.update(dt)
  now = now + dt
  elapsed = elapsed + dt
  poll = poll - dt
  if poll > 0 or not gps then return end
  poll = 0.5
  local ok, r = pcall(gps.read)
  g = ok and r or nil
  if g and (tonumber(g.chars) or 0) > 0 then nodata = 0 else nodata = nodata + 0.5 end
  if g and g.valid then
    local kmh = tonumber(g.speed) or 0
    if kmh > maxspd and (tonumber(g.hdop) or 99) < 5 then maxspd = kmh end
    track(g.lat, g.lon)
    if logging then
      log_left = log_left - 0.5
      if log_left <= 0 then
        log_left = LOG_EVERY
        if not log_line() then logging = false; shell.toast("Log write failed - logging off") end
      end
    end
  end
  build()
end

local function label(x, y, l, v)
  ui.text(x, y, l, col.muted)
  ui.text(x + 36, y, v, col.text)
end

local function draw_state()
  if not gps then
    ui.empty("pin", "No GPS support in this firmware", nil)
  elseif nodata >= 5 then
    ui.empty("pin", "No GPS data - is the Cap attached?", "Needs the Cap LoRa-1262")
  else
    ui.empty("pin", "Waiting for fix - go outside", "Sats " .. fx[4] .. "  NMEA chars " .. fx[8])
  end
end

local function draw_fix()
  if not (g and g.valid) then draw_state(); return end
  ui.card(4, 33, 232, 30)
  label(10, 37, "Lat", fx[1])
  label(10, 49, "Lon", fx[2])
  label(4, 70, "Alt", fx[3])
  label(124, 70, "Sats", fx[4])
  label(124, 82, "HDOP", fx[5])
  label(4, 82, "UTC", fx[6])
  label(4, 94, "Date", fx[7])
  label(4, 106, "NMEA", fx[8] .. " chars")
end

local function draw_speed()
  local v = g and g.valid
  ui.big(36, spd_s, v and col.accent or col.muted, 4)
  ui.center(72, unit(), col.muted)
  ui.center(88, v and crs_s or "No fix", col.text)
  ui.center(104, max_s, col.muted)
end

local function draw_trip()
  ui.big(34, trip.d, col.accent, 3)
  label(4, 64, "Time", trip.e)
  label(124, 64, "Avg", trip.a)
  ui.text(4, 80, "Log", col.muted)
  ui.switch(40, 79, logging)
  if logging then
    ui.text(68, 80, ui.fit(log_path:match("[^/]+$") .. " " .. log_lines .. " lines", 168), col.text)
  else
    ui.text(68, 80, "every 5 s to CSV", col.muted)
  end
  if not (g and g.valid) then ui.text(4, 100, "No fix - distance paused", col.warn) end
end

function app.draw()
  ui.tabs(TABS, tab, 16)
  if tab == 1 then
    draw_fix()
    ui.footer({ { "Tab", "Speed" }, { "Esc", "Back" } })
  elseif tab == 2 then
    draw_speed()
    ui.footer({ { "U", "Units" }, { "R", "Reset max" }, { "Tab", "Trip" }, { "Esc", "Back" } })
  else
    draw_trip()
    ui.footer({ { "R", "Reset" }, { "L", logging and "Stop log" or "Log" }, { "Tab", "Fix" }, { "Esc", "Back" } })
  end
end

function app.key(k)
  if k.key == "tab" then
    tab = k.shift and (tab - 2) % #TABS + 1 or tab % #TABS + 1
    return true
  end
  local c = not k.fn and not k.ctrl and k.text and k.text:lower()
  if c == "u" then
    mph = not mph
    cfg.set("gps_units", mph and "mph" or "kmh")
    shell.toast("Units: " .. unit())
  elseif c == "r" and tab == 2 then
    maxspd = 0
    shell.toast("Max speed reset")
  elseif c == "r" and tab == 3 then
    reset_trip()
    shell.toast("Trip reset")
  elseif c == "l" and tab == 3 then
    toggle_log()
  else
    return k.key ~= "esc"
  end
  build()
  return true
end

function app.save() return { dist = dist, el = elapsed, max = maxspd } end

function app.close()
  if gps then pcall(gps.stop) end
  logging = false
  unload("geo_math")
end

return app
