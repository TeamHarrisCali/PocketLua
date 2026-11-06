-- Mesh > Nodes: who's around (newest first) or a radar of them around our GPS
-- position, and a page per node with signal, hops, battery and telemetry,
-- position and distance, and a traceroute.
-- Loaded while the tab is open (see apps/mesh.lua for S).
return function(S)
local col = ui.col
local geo = require("geo_math")
local rows, sel, top = {}, 1, 1
local detail, lines = nil, {}  -- the node shown (hex) and its wrapped text
local refresh = 0
local radar, plots, psel = false, {}, 1  -- radar view: { hx, dist, bearing }, the picked one

local NICE = { 1, 2, 5 }
local function nice_range(d)  -- the smallest 1/2/5 x 10^n metres at or above d
  local p = 100
  while true do
    for _, m in ipairs(NICE) do if m * p >= d then return m * p end end
    p = p * 10
  end
end

local function build_radar()
  plots = {}
  if not S.fix then return end
  for hx, n in pairs(S.nodes) do
    if n.lat and hx ~= S.me_hex then
      plots[#plots + 1] = { hx, geo.dist(S.fix.lat, S.fix.lon, n.lat, n.lon), geo.bearing(S.fix.lat, S.fix.lon, n.lat, n.lon) }
    end
  end
  table.sort(plots, function(a, b) return a[2] < b[2] end)
  psel = math.max(1, math.min(psel, #plots))
end

local function draw_radar()
  if not S.fix then
    ui.empty("antenna", "The radar needs a GPS fix", "Cap attached, sky in view")
    ui.footer({ { "R", "List" }, { "Tab", "DMs" }, { "Esc", "Back" } })
    return
  end
  local cx, cy, R = 120, 70, 36
  local far = 0
  for _, p in ipairs(plots) do far = math.max(far, p[2]) end
  local range = nice_range(math.max(far, 100))
  gfx.circle(cx, cy, R, col.line)
  gfx.circle(cx, cy, R // 2, col.line)
  gfx.line(cx, cy - R - 2, cx, cy + R + 2, col.line)
  gfx.line(cx - R - 2, cy, cx + R + 2, cy, col.line)
  ui.text(cx - 2, cy - R - 11, "N", col.muted)
  ui.text(cx + R + 4, cy - 4, geo.fmt_dist(range), col.muted)
  gfx.disc(cx, cy, 2, col.accent)
  for i, p in ipairs(plots) do
    local r, b = p[2] / range * R, math.rad(p[3])
    local x, y = math.floor(cx + r * math.sin(b) + 0.5), math.floor(cy - r * math.cos(b) + 0.5)
    local pick = i == psel
    gfx.disc(x, y, pick and 3 or 2, pick and col.accent or col.text)
    ui.text(x + 4, y - 3, S.name_of(p[1]), pick and col.accent or col.muted)
  end
  local p = plots[psel]
  if p then
    ui.text(4, 33, ui.fit(S.name_of(p[1]) .. " " .. geo.fmt_dist(p[2]) .. " " .. geo.compass(p[3]), 80), col.text)
  else
    ui.text(4, 33, "No positions yet", col.muted)
  end
  ui.footer({ { "<>", "Pick" }, { "Enter", "Details" }, { "R", "List" } })
end

local function ago(t)
  local s = math.floor(S.now - t)
  if s < 60 then return s .. "s" elseif s < 3600 then return (s // 60) .. "m" end
  return (s // 3600) .. "h"
end

local function span(s)
  if s >= 86400 then return (s // 86400) .. "d " .. (s % 86400 // 3600) .. "h" end
  return (s // 3600) .. "h " .. (s % 3600 // 60) .. "m"
end

local function build_list()
  rows = {}
  local list = {}
  for hx, n in pairs(S.nodes) do if hx ~= S.me_hex then list[#list + 1] = { hx, n } end end
  table.sort(list, function(a, b) return (a[2].seen or -1) > (b[2].seen or -1) end)
  for i, e in ipairs(list) do
    local hx, n = e[1], e[2]
    local heard = "saved"
    if n.seen then heard = n.hops and n.hops > 0 and (n.hops .. "hop " .. ago(n.seen)) or ((n.rssi or 0) .. "dBm") end
    local unread = S.unread[hx]
    rows[i] = { label = ui.fit(S.name_of(hx) .. "  " .. (n.long or ""), 140), value = heard, dim = not n.seen,
      hex = hx, badge = unread and tostring(unread) or (n.pub and "K" or nil),
      badge_color = unread and ui.accents.orange or nil }
  end
  sel = math.max(1, math.min(sel, #rows))
end

local function build_detail()
  local n = S.nodes[detail]
  if not n then detail = nil; return end
  local t = {}
  t[#t + 1] = (n.long and n.long ~= "" and n.long or S.name_of(detail)) .. "  " .. S.mt.id_text(n.num)
  if n.seen then
    t[#t + 1] = string.format("Heard %s ago%s, %d dBm, SNR %.1f", ago(n.seen),
      n.hops and (", " .. n.hops .. (n.hops == 1 and " hop" or " hops")) or "", n.rssi or 0, n.snr or 0)
  else
    t[#t + 1] = "Not heard since Mesh opened"
  end
  if n.battery or n.voltage then
    t[#t + 1] = "Battery " .. (n.battery and (n.battery > 100 and "on power" or n.battery .. "%") or "?")
      .. (n.voltage and string.format(", %.2f V", n.voltage) or "") .. (n.uptime and (", up " .. span(n.uptime)) or "")
  end
  if n.temp then t[#t + 1] = string.format("Temp %.1f C%s", n.temp, n.humidity and string.format(", %d%% RH", math.floor(n.humidity + 0.5)) or "") end
  if n.lat then
    local where = string.format("At %.4f, %.4f", n.lat, n.lon)
    if S.fix then
      where = where .. ": " .. geo.fmt_dist(geo.dist(S.fix.lat, S.fix.lon, n.lat, n.lon)) .. " "
        .. geo.compass(geo.bearing(S.fix.lat, S.fix.lon, n.lat, n.lon))
    end
    t[#t + 1] = where
  end
  t[#t + 1] = n.pub and "Key known: DMs are encrypted" or "No key yet: DMs ask for it first"
  if n.trace then t[#t + 1] = "Route: " .. n.trace end
  lines = {}
  for _, s in ipairs(t) do
    for _, l in ipairs(ui.wrap(s, 228)) do lines[#lines + 1] = l end
  end
end

local tab = {}

function tab.init() build_list() end
function tab.close() rows, lines = {}, {}; unload("geo_math") end

function tab.update(dt)
  refresh = refresh - dt
  if refresh <= 0 then
    refresh = 1
    if detail then build_detail() elseif radar then build_radar() else build_list() end
  end
end

function tab.draw()
  if detail then
    for i = 1, math.min(#lines, 8) do ui.text(4, 23 + i * 10, lines[i], i == 1 and col.text or col.muted) end
    ui.footer({ { "Enter", "Message" }, { "T", "Traceroute" }, { "Esc", "Back" } })
    return
  end
  if radar then draw_radar(); return end
  if #rows == 0 then ui.empty("antenna", "No nodes heard yet", "They appear as they send")
  else top = ui.list(rows, sel, top, 4, 33, 229, 15, 6) end
  ui.footer({ { "Enter", "Details" }, { "R", "Radar" }, { "Tab", "DMs" } })
end

function tab.key(k, d)
  local c = not k.ctrl and not k.fn and k.text and k.text:lower()
  if detail then
    if k.key == "esc" then detail = nil; build_list()
    elseif k.key == "enter" then S.open_dm(detail)
    elseif c == "t" then S.traceroute(detail); build_detail()
    else return false end
    return true
  end
  if c == "r" then
    radar = not radar
    if radar then build_radar() else build_list() end
    return true
  end
  if radar then
    if d == "left" or d == "up" then psel = math.max(1, psel - 1)
    elseif d == "right" or d == "down" then psel = math.min(math.max(1, #plots), psel + 1)
    elseif k.key == "enter" and plots[psel] then detail = plots[psel][1]; build_detail()
    elseif k.key == "esc" then radar = false; build_list()
    else return false end
    return true
  end
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(#rows, sel + 1)
  elseif k.key == "enter" and rows[sel] then detail = rows[sel].hex; build_detail()
  else return false end
  return true
end

return tab
end
