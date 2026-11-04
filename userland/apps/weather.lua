-- Weather from wttr.in over plain HTTP. L sets the place (blank = found from
-- your IP address), U switches US / metric units, R refreshes. The last reply
-- is kept in settings so it still shows when offline.
local col = ui.col

local app = { title = "Weather", icon = "cloud", color = "blue", order = 31, category = "net" }

-- wttr.in wind arrows (UTF-8) as screen directions; they point where the wind blows.
local ARROWS = {
  ["\xE2\x86\x90"] = { -1, 0 }, ["\xE2\x86\x91"] = { 0, -1 }, ["\xE2\x86\x92"] = { 1, 0 }, ["\xE2\x86\x93"] = { 0, 1 },
  ["\xE2\x86\x96"] = { -1, -1 }, ["\xE2\x86\x97"] = { 1, -1 }, ["\xE2\x86\x98"] = { 1, 1 }, ["\xE2\x86\x99"] = { -1, 1 },
}

local loc, units = "", "u"
local wx          -- parsed reply: place, temp, unit, cond, hum, wind, dir, rain
local stamp = ""  -- when wx was fetched
local err         -- last error text
local want        -- frames to wait before fetching, so "Updating" is drawn first
local auto = false -- fetch as soon as Wi-Fi connects
local wst = "off"

-- Printable ASCII only (the font has no degree sign or arrows), trimmed.
local function clean(s)
  return (s:gsub("[\128-\255%c]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function enc(s)
  return (s:gsub("[^%w%-%.,_~]", function(c) return c == " " and "+" or string.format("%%%02X", c:byte()) end))
end

local function parse(body)
  local f = {}
  for p in (body .. "|"):gmatch("([^|]*)|") do f[#f + 1] = p end
  if #f < 6 then return nil end
  local num, unit = clean(f[2]):match("^([%+%-]?%d+)%s*(%a?)")
  if not num then return nil end
  return {
    place = ui.fit(clean(f[1]), 232), temp = (num:gsub("^%+", "")), unit = unit,
    cond = ui.fit(clean(f[3]), 232), hum = ui.fit(clean(f[4]), 66),
    wind = ui.fit(clean(f[5]), 52), dir = ARROWS[f[5]:match("\xE2\x86[\x90-\x99]") or ""],
    rain = ui.fit(clean(f[6]), 66),
  }
end

local function fetch()
  want = nil
  local url = "http://wttr.in/" .. enc(loc) .. "?format=%l|%t|%C|%h|%w|%p&" .. units
  local body, st = http.get(url, 512)
  local w = body and parse(body)
  if not w then
    local line = body and clean(body:match("[^\n]*")) or ""
    err = ui.fit(not body and ("No reply: " .. tostring(st)) or (line ~= "" and line or ("HTTP " .. tostring(st))), 228)
    if wx then shell.toast(err, 3) end
    return
  end
  wx, err = w, nil
  local t = clock.now()
  stamp = t.valid and string.format("%d/%d %s", t.month, t.day, shell.format_time(t)) or ""
  cfg.set("wx_last", (body:gsub("%s+$", "")))
  cfg.set("wx_time", stamp)
end

local function request()
  if wst == "connected" then want = 1 else auto = true end
end

local function connect()
  local ssid = cfg.get("wifi_ssid")
  if wst == "connecting" then shell.toast("Connecting to Wi-Fi...")
  elseif not ssid then shell.toast("Set up Wi-Fi in Settings > Wi-Fi", 3)
  elseif shell.wifi_start(ssid, cfg.get("wifi_pass")) then
    shell.toast("Connecting to " .. ssid)
    auto = true
  end
end

function app.init()
  loc, units = cfg.get("wx_loc") or "", cfg.get("wx_units") == "m" and "m" or "u"
  wx, err, want, stamp = nil, nil, nil, ""
  local last = cfg.get("wx_last")
  if last then wx = parse(last); stamp = cfg.get("wx_time") or "" end
  auto = true  -- refresh on open, or once Wi-Fi is up
end

function app.update(dt)
  wst = wifi.status()
  if auto and wst == "connected" then auto = false; want = 1 end
  if want then
    if wst ~= "connected" then want = nil; auto = true
    elseif want > 0 then want = want - 1
    else fetch() end
  end
end

local function card(x, title, value)
  ui.card(x, 78, 74, 30)
  ui.title(x + 5, 82, title)
  gfx.text(x + 5, 95, value, col.text)
end

function app.draw()
  local online = wst == "connected"
  if not wx then
    if not online then
      ui.empty("cloud", wst == "connecting" and "Connecting to Wi-Fi..." or "Wi-Fi is not connected",
        cfg.get("wifi_ssid") and "Enter connects" or "Set it up in Settings > Wi-Fi")
    elseif want or not err then
      ui.empty("cloud", "Getting the weather...", loc ~= "" and ui.fit(loc, 228) or "Location from your IP")
    else
      ui.empty("warn", err, "R retries, L sets the location")
    end
  else
    ui.center(18, wx.place, col.muted)
    local s = wx.temp
    local tw = #s * 24 + (wx.unit ~= "" and 22 or 0)
    local x = (ui.W - tw) // 2
    gfx.text(x, 30, s, col.text, 4)
    if wx.unit ~= "" then
      gfx.circle(x + #s * 24 + 4, 33, 2, col.text)
      gfx.text(x + #s * 24 + 9, 30, wx.unit, col.text, 2)
    end
    ui.center(65, wx.cond, col.accent)
    card(4, "HUMIDITY", wx.hum)
    ui.card(81, 78, 74, 30)
    ui.title(86, 82, "WIND")
    local d = wx.dir
    if d then
      local cx, cy = 91, 98
      gfx.line(cx - d[1] * 5, cy - d[2] * 5, cx + d[1] * 5, cy + d[2] * 5, col.accent)
      gfx.disc(cx + d[1] * 4, cy + d[2] * 4, 2, col.accent)
      gfx.text(100, 95, wx.wind, col.text)
    else
      gfx.text(86, 95, wx.wind, col.text)
    end
    card(158, "RAIN", wx.rain)
    local note = want and "Updating..." or (online and "Updated " or "Offline, from ") .. stamp
    ui.center(113, note, online and col.muted or col.warn)
  end
  if online then
    ui.footer({ { "R", "Refresh" }, { "L", "Place" }, { "U", "Units" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Enter", "Wi-Fi" }, { "L", "Place" }, { "U", "Units" }, { "Esc", "Home" } })
  end
end

function app.key(k)
  local c = not k.ctrl and not k.fn and k.text
  if k.key == "enter" then
    if wst == "connected" then want = 1 else connect() end
  elseif c == "r" then
    if wst == "connected" then want = 1 else shell.toast("Connect to Wi-Fi first (Enter)"); auto = true end
  elseif c == "l" then
    shell.prompt("Location (blank = auto)", loc, function(s)
      if not s then return end
      s = trim(s)
      if s == loc then return end
      loc = s
      cfg.set("wx_loc", s ~= "" and s or nil)
      cfg.set("wx_last", nil)
      wx, err = nil, nil
      request()
    end)
  elseif c == "u" then
    units = units == "u" and "m" or "u"
    cfg.set("wx_units", units)
    shell.toast(units == "u" and "US units" or "Metric units")
    request()
  else return false end
  return true
end

function app.close()
  wx, err = nil, nil
end

return app
