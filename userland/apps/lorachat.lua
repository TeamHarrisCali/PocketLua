-- LoRa Chat: off-grid text chat and position beacons over the Cap LoRa-1262.
-- Packets: "M|call|text" for messages, "P|call|lat|lon|alt" for beacons.
-- Tab switches Chat / Peers / Setup. The radio only runs while the app is open.
local col = ui.col
local app = { title = "LoRa Chat", icon = "antenna", color = "orange", order = 51, category = "net" }

local geo = require("geo_math")

local TABS = { "Chat", "Peers", "Setup" }
local FREQS = { 868.0, 915.0 }
local BEACONS = { 30, 60, 120 }
local MAX_LINES, MAX_PEERS, ROWS = 40, 16, 7

local tab = 1
local radio_ok, radio_err = false, nil
local call, freq, sf, beacon_s = "", 915.0, 9, 60
local lines, kinds = {}, {}       -- wrapped chat lines and their colour kind
local scroll = 0                  -- lines scrolled up from the bottom
local input, blink = "", true
local pending = nil               -- message waiting for the radio
local peers = {}                  -- { call, lat, lon, alt, rssi, snr, seen }
local rows, psel, ptop = {}, 1, 1
local srows, ssel, stop_ = {}, 1, 1
local fix = nil                   -- last valid GPS fix
local fix_note = "Our GPS: no fix yet"
local now, gps_left, beacon_left, rows_left = 0, 0, 3, 0
local tx, rx, unread = 0, 0, 0

local function add(s, kind)
  for _, l in ipairs(ui.wrap(s, 228)) do
    lines[#lines + 1], kinds[#kinds + 1] = l, kind
  end
  while #lines > MAX_LINES do table.remove(lines, 1); table.remove(kinds, 1) end
  scroll = 0
end

local function kind_col(kind)
  if kind == "me" then return col.accent elseif kind == "sys" then return col.muted end
  return col.text
end

local function start_radio()
  if not lora then radio_ok, radio_err = false, "No LoRa support in this firmware"; return end
  local ok, r, e = pcall(lora.begin, freq, sf, 14)
  radio_ok = ok and r == true
  radio_err = not radio_ok and tostring(ok and (e or "LoRa radio not found") or r) or nil
  if radio_ok then
    add(string.format("* Radio on %.0f MHz SF%d as %s", freq, sf, call), "sys")
  end
end

local function build_setup()
  srows = {
    { label = "Callsign", value = call },
    { label = "Frequency", value = string.format("%.0f MHz", freq) },
    { label = "Spreading factor", value = "SF" .. sf },
    { label = "Beacon every", value = beacon_s .. " s" },
    { label = "Packets", value = "TX " .. tx .. "  RX " .. rx, dim = true },
  }
end

local function build_peers()
  rows = {}
  for i, p in ipairs(peers) do
    local where = "no position"
    if p.lat and fix then
      local d = geo.dist(fix.lat, fix.lon, p.lat, p.lon)
      where = geo.fmt_dist(d) .. " " .. geo.compass(geo.bearing(fix.lat, fix.lon, p.lat, p.lon))
    elseif p.lat then
      where = "? (no fix)"
    end
    rows[i] = { label = p.call .. "  " .. where,
      value = string.format("%d %ds", math.floor(p.rssi + 0.5), math.floor(now - p.seen)) }
  end
  psel = math.max(1, math.min(psel, #rows))
end

local function peer(name, rssi, snr)
  for _, p in ipairs(peers) do
    if p.call == name then p.rssi, p.snr, p.seen = rssi, snr, now; return p end
  end
  if #peers >= MAX_PEERS then
    local old = 1
    for i, p in ipairs(peers) do if p.seen < peers[old].seen then old = i end end
    table.remove(peers, old)
  end
  local p = { call = name, rssi = rssi, snr = snr, seen = now }
  peers[#peers + 1] = p
  return p
end

local function on_packet(pk)
  local data = tostring(pk.data or "")
  local t, who, rest = data:match("^([MP])|([^|]+)|(.*)$")
  if not t or who == call then return end
  who = who:gsub("[^%w%-_%.]", ""):sub(1, 12)
  if who == "" then return end
  rx = rx + 1
  local p = peer(who, tonumber(pk.rssi) or 0, tonumber(pk.snr) or 0)
  if t == "M" then
    add(who .. ": " .. rest:gsub("[^\32-\126]", "?"):sub(1, 200), "them")
    if tab ~= 1 then unread = unread + 1 end
    shell.sound("notify")
  else
    local la, lo, al = rest:match("^(-?[%d.]+)|(-?[%d.]+)|?(-?[%d.]*)")
    la, lo = tonumber(la), tonumber(lo)
    if la and lo and math.abs(la) <= 90 and math.abs(lo) <= 180 then
      p.lat, p.lon, p.alt = la, lo, tonumber(al) or 0
    end
  end
  rows_left = 0
end

local function send(s)
  local ok, r = pcall(lora.send, s)
  if ok and r ~= false then tx = tx + 1; return true end
  return false
end

local function cycle(list, v, d)
  local i = 1
  for j, x in ipairs(list) do if x == v then i = j end end
  return list[(i - 1 + d) % #list + 1]
end

local function change(i, d)
  if i == 1 then
    shell.prompt("Callsign", call, function(t)
      t = t and t:gsub("[^%w%-_%.]", ""):sub(1, 10)
      if not t or t == "" then return end
      call = t
      cfg.set("lora_call", call)
      build_setup()
      shell.toast("Callsign " .. call)
    end)
    return
  elseif i == 2 then
    freq = cycle(FREQS, freq, d)
    cfg.set("lora_freq", string.format("%.1f", freq))
    start_radio()
  elseif i == 3 then
    sf = (sf - 7 + d) % 6 + 7
    cfg.set("lora_sf", tostring(sf))
    start_radio()
  elseif i == 4 then
    beacon_s = cycle(BEACONS, beacon_s, d)
    cfg.set("lora_beacon", tostring(beacon_s))
    beacon_left = math.min(beacon_left, beacon_s)
    shell.toast("Beacon every " .. beacon_s .. " s")
  else
    return
  end
  if i == 2 or i == 3 then
    shell.toast(radio_ok and string.format("Radio %.0f MHz SF%d", freq, sf) or ("Radio: " .. tostring(radio_err)))
  end
  build_setup()
end

function app.init()
  call = cfg.get("lora_call") or ("CP-" .. (net and net.mac and net.mac() or "0000"):sub(-4):upper())
  freq = tonumber(cfg.get("lora_freq")) or 915.0
  sf = math.max(7, math.min(12, math.floor(tonumber(cfg.get("lora_sf")) or 9)))
  beacon_s = tonumber(cfg.get("lora_beacon")) or 60
  start_radio()
  if gps then pcall(gps.start) end
  add("* Enter sends, Fn+;/. scrolls, Tab: Peers, Setup", "sys")
  build_setup()
end

function app.update(dt)
  now = now + dt
  blink = (now % 1) < 0.5

  -- position, about once a second
  gps_left = gps_left - dt
  if gps_left <= 0 and gps then
    gps_left = 1
    local ok, g = pcall(gps.read)
    if ok and g and g.valid then
      fix = g
      fix_note = string.format("Our GPS: fix, %d sats", math.floor(tonumber(g.sats) or 0))
    else
      fix = nil
      fix_note = "Our GPS: no fix - distances unknown"
    end
  end

  if not radio_ok then return end

  -- recv() also finishes a transmit, so it runs every frame
  for _ = 1, 4 do
    local ok, pk = pcall(lora.recv)
    if not ok or not pk then break end
    on_packet(pk)
  end

  beacon_left = beacon_left - dt
  if not lora.busy() then
    if pending then
      if send(pending) then add("me: " .. pending:match("^M|[^|]*|(.*)$"), "me")
      else add("* Send failed", "sys") end
      pending = nil
    elseif beacon_left <= 0 then
      if fix then
        send(string.format("P|%s|%.5f|%.5f|%d", call, fix.lat, fix.lon, math.floor((tonumber(fix.alt) or 0) + 0.5)))
        beacon_left = beacon_s
      else
        beacon_left = 1  -- try again once we have a fix
      end
    end
  end

  rows_left = rows_left - dt
  if rows_left <= 0 then
    rows_left = 1
    if tab == 2 then build_peers() elseif tab == 3 then build_setup() end
  end
  if tab == 1 then unread = 0 end
  local label = unread > 0 and ("Chat " .. unread) or "Chat"
  if TABS[1] ~= label then TABS[1] = label end
end

local function draw_chat()
  local last = #lines - scroll
  for i = 0, ROWS - 1 do
    local n = last - ROWS + 1 + i
    if lines[n] then ui.text(4, 33 + i * 10, lines[n], kind_col(kinds[n])) end
  end
  if scroll > 0 then ui.right(236, 33, "^" .. scroll, col.muted) end
  gfx.line(4, 107, 236, 107, col.line)
  local shown = input
  if #shown > 36 then shown = shown:sub(-36) end
  ui.text(4, 112, "> " .. shown .. (blink and "_" or ""), pending and col.muted or col.text)
  ui.footer({ { "Enter", "Send" }, { "Tab", "Peers" }, { "Esc", "Back" } })
end

local function draw_peers()
  ui.text(4, 33, ui.fit(fix_note, 232), fix and col.muted or col.warn)
  if #rows == 0 then
    ui.empty("antenna", "No peers heard yet", "They appear when they send")
  else
    ptop = ui.list(rows, psel, ptop, 4, 44, 229, 15, 5)
  end
  ui.footer({ { "Enter", "Info" }, { "Tab", "Setup" }, { "Esc", "Back" } })
end

local function draw_setup()
  stop_ = ui.list(srows, ssel, stop_, 4, 33, 229, 15, 5)
  ui.text(4, 112, "Enter or </> changes; radio restarts", col.muted)
  ui.footer({ { "Enter", "Change" }, { "Tab", "Chat" }, { "Esc", "Back" } })
end

function app.draw()
  ui.tabs(TABS, tab, 16)
  if tab == 3 then draw_setup(); return end
  if not radio_ok then
    ui.empty("antenna", ui.fit(tostring(radio_err), 228), "Attach the Cap LoRa-1262")
    ui.footer({ { "R", "Retry" }, { "Tab", "Setup" }, { "Esc", "Back" } })
    return
  end
  if tab == 1 then draw_chat() else draw_peers() end
end

local function peer_info(p)
  local s = string.format("RSSI %d dBm, SNR %.1f dB, heard %ds ago.", math.floor(p.rssi + 0.5), p.snr,
    math.floor(now - p.seen))
  if p.lat then
    s = s .. string.format(" At %.5f, %.5f, %d m.", p.lat, p.lon, math.floor(p.alt + 0.5))
  end
  shell.alert(p.call, s)
end

function app.key(k)
  if k.key == "tab" then
    tab = k.shift and (tab - 2) % #TABS + 1 or tab % #TABS + 1
    rows_left = 0
    return true
  end
  if tab == 3 then
    local d = ui.nav(k)
    if d == "up" then ssel = math.max(1, ssel - 1)
    elseif d == "down" then ssel = math.min(#srows, ssel + 1)
    elseif k.key == "enter" or d == "right" then change(ssel, 1)
    elseif d == "left" then change(ssel, -1)
    else return k.key ~= "esc" end
    return true
  end
  if not radio_ok then
    if k.text and k.text:lower() == "r" and not k.fn then
      start_radio()
      shell.toast(radio_ok and "Radio ready" or tostring(radio_err))
      return true
    end
    return k.key ~= "esc"
  end
  if tab == 2 then
    local d = ui.nav(k)
    if d == "up" then psel = math.max(1, psel - 1)
    elseif d == "down" then psel = math.min(#rows, psel + 1)
    elseif k.key == "enter" and peers[psel] then peer_info(peers[psel])
    else return k.key ~= "esc" end
    return true
  end
  -- Chat
  if k.key == "enter" then
    local t = input:gsub("|", ""):match("^%s*(.-)%s*$")
    if t == "" then return true end
    if pending then shell.toast("Still sending..."); return true end
    pending = "M|" .. call .. "|" .. t:sub(1, 200)
    input = ""
  elseif k.key == "backspace" then input = input:sub(1, -2)
  elseif k.key == "esc" then
    if input == "" then return false end
    input = ""
  elseif k.key == "up" then scroll = math.min(math.max(0, #lines - ROWS), scroll + 1)
  elseif k.key == "down" then scroll = math.max(0, scroll - 1)
  elseif k.text and not k.ctrl and not k.fn then
    if k.text ~= "|" and #input < 200 then input = input .. k.text end
  else
    return false
  end
  return true
end

function app.close()
  if lora then pcall(lora.stop) end
  if gps then pcall(gps.stop) end
  lines, kinds, peers, rows = {}, {}, {}, {}
  unload("geo_math")
end

return app
