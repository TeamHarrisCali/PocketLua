-- Mesh > Nodes: who's around (newest first) and a page per node with signal,
-- hops, battery and telemetry, position and distance, and a traceroute.
-- Loaded while the tab is open (see apps/mesh.lua for S).
return function(S)
local col = ui.col
local geo = require("geo_math")
local rows, sel, top = {}, 1, 1
local detail, lines = nil, {}  -- the node shown (hex) and its wrapped text
local refresh = 0

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
    if detail then build_detail() else build_list() end
  end
end

function tab.draw()
  if detail then
    for i = 1, math.min(#lines, 8) do ui.text(4, 23 + i * 10, lines[i], i == 1 and col.text or col.muted) end
    ui.footer({ { "Enter", "Message" }, { "T", "Traceroute" }, { "Esc", "Back" } })
    return
  end
  if #rows == 0 then ui.empty("antenna", "No nodes heard yet", "They appear as they send")
  else top = ui.list(rows, sel, top, 4, 33, 229, 15, 6) end
  ui.footer({ { "Enter", "Details" }, { "Tab", "DMs" }, { "Esc", "Back" } })
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
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(#rows, sel + 1)
  elseif k.key == "enter" and rows[sel] then detail = rows[sel].hex; build_detail()
  else return false end
  return true
end

return tab
end
