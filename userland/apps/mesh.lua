-- Mesh: a Meshtastic-compatible node on the Cap LoRa-1262. Chat on the public
-- channel, see the nodes around, send private (public-key) messages and share
-- a position. It joins as CLIENT_MUTE: it never relays other nodes' packets.
-- The radio only runs while the app is open. Protocol: lib/meshtastic.lua and
-- docs/MESHTASTIC.md.
local col = ui.col
local app = { title = "Mesh", icon = "antenna", color = "green", order = 52, category = "net" }
app.help = {
  { "Tab", "Next tab" },
  { "Enter", "Send / open / change" },
  { "Up/Dn", "Scroll / pick" },
  { "<>", "Setup: change value" },
  { "Esc", "Clear, then back" },
  { "R", "Retry radio" },
}

local mt = require("meshtastic")
local pb = require("protobuf")
local geo = require("geo_math")

local TABS = { "Chat", "Nodes", "DMs", "Setup" }
local DIR, NODES_FILE = "data/mesh", "data/mesh/nodes.txt"
local MAX_LINES, MAX_NODES, ROWS = 40, 40, 7
local POS_MODES = { "Off", "Approx", "Precise" }  -- precision bits nil / 13 / 32
local NODEINFO_EVERY, POS_EVERY = 3 * 3600, 15 * 60

local tab = 1
local radio_ok, radio_err = false, nil
local me, me_hex, priv, pub = 0, "", nil, nil
local long_name, short_name, preset_i, pos_mode = "", "", 1, 1
local preset, freq, chan_name, chan_key, chan_hash = nil, 0, "", nil, 0
local hist = mt.history(120)
local nodes = {}             -- hex -> { num, long, short, pub, key, rssi, snr, hops, seen, lat, lon, info_at }
local nodes_dirty = false
local chat, dms = {}, {}     -- chat lines; dms[hex] = lines. A line: { text, kind }
local scroll, input, blink = 0, "", true
local peer = nil             -- hex of the node the DMs tab talks to
local queue = {}             -- frames waiting for the radio: { frame, at, tries, id, line }
local waiting = {}           -- our DMs waiting for an ACK: id hex -> { line, tries, frame, at }
local rows, rsel, rtop = {}, 1, 1
local srows, ssel, stop_ = {}, 1, 1
local fix = nil
local now, gps_left, rows_left, info_left, pos_left = 0, 0, 0, 5, 60
local tx, rx, unread = 0, 0, 0

-- ---------------------------------------------------------------- helpers
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function unhex(s) return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)) end

local function clean(s)  -- UTF-8 (emoji) to "?", no control characters
  return (s:gsub("[\xC0-\xFF][\x80-\xBF]*", "?"):gsub("[^\32-\126]", ""))
end

local function name_of(hx)
  local n = nodes[hx]
  if n and n.short and n.short ~= "" then return n.short end
  if n and n.long and n.long ~= "" then return n.long end
  return "!" .. hx:sub(-4)
end

local function add(list, text, kind)
  for _, l in ipairs(ui.wrap(text, 228)) do list[#list + 1] = { l, kind } end
  while #list > MAX_LINES do table.remove(list, 1) end
  scroll = 0
  return list[#list]
end

local function kind_col(kind)
  if kind == "me" then return col.accent elseif kind == "sys" then return col.muted
  elseif kind == "fail" then return col.warn end
  return col.text
end

-- ---------------------------------------------------------------- node list
local function save_nodes()
  if not nodes_dirty then return end
  local out = {}
  for hx, n in pairs(nodes) do
    out[#out + 1] = table.concat({ hx, (n.long or ""):gsub("[|\n]", " "), (n.short or ""):gsub("[|\n]", " "),
      n.pub and hex(n.pub) or "" }, "|") .. "\n"
  end
  sys.mkdirs(DIR)
  sys.write_text(NODES_FILE, table.concat(out))
  nodes_dirty = false
end

local function load_nodes()
  for line in (sys.read_text(NODES_FILE) or ""):gmatch("[^\n]+") do
    local hx, l, s, k = line:match("^(%x+)|([^|]*)|([^|]*)|(%x*)$")
    if hx then
      nodes[hx] = { num = tonumber(hx, 16), long = l, short = s, pub = #k == 64 and unhex(k) or nil }
    end
  end
end

local function node(num)
  local hx = mt.u32(num) == mt.u32(me) and me_hex or pb.hex32(num)
  local n = nodes[hx]
  if not n then
    local count, old, old_seen = 0, nil, math.huge
    for k, v in pairs(nodes) do
      count = count + 1
      if (v.seen or -1) < old_seen and k ~= peer then old, old_seen = k, v.seen or -1 end
    end
    if count >= MAX_NODES and old then nodes[old] = nil end
    n = { num = num }
    nodes[hx] = n
  end
  return n, hx
end

-- ---------------------------------------------------------------- sending
local function header(to, want_ack, hop_limit, channel)
  return { to = to, from = me, id = mt.new_id(), hop_limit = hop_limit or 3, hop_start = hop_limit or 3,
    want_ack = want_ack, channel = channel, relay = mt.last_byte(me) }
end

local function enqueue(h, payload, extra)
  hist.check(me, h.id)
  local q = extra or {}
  q.frame, q.at, q.id = mt.pack(h, payload), now + 0.05 + math.random() * 0.25, h.id
  queue[#queue + 1] = q
  return q
end

-- on the channel key (broadcasts, NodeInfo, positions, ACKs)
local function send_channel(to, data, want_ack, hop_limit)
  local h = header(to, want_ack and to ~= mt.BROADCAST, hop_limit, chan_hash)
  return enqueue(h, mt.channel_crypt(chan_key, me, h.id, mt.encode_data(data))), h.id
end

local function my_user()
  return mt.encode_user({ id = mt.id_text(me), long_name = long_name, short_name = short_name,
    hw_model = mt.HW_PRIVATE, role = mt.ROLE_CLIENT_MUTE, public_key = pub })
end

local function send_nodeinfo(to, want_response)
  send_channel(to or mt.BROADCAST, { portnum = mt.PORT.NODEINFO, payload = my_user(), want_response = want_response })
end

local function send_position()  -- false when there is nothing to send yet
  if pos_mode == 1 or not fix then return false end
  local t = clock and clock.now and clock.now()
  send_channel(mt.BROADCAST, { portnum = mt.PORT.POSITION, payload = mt.encode_position({
    lat = fix.lat, lon = fix.lon, alt = tonumber(fix.alt), precision = pos_mode == 2 and 13 or nil,
    time = t and t.valid and t.unix or nil }) })
  return true
end

local function send_ack(h, request_id)
  local hops = h.hop_start > 0 and (h.hop_start - h.hop_limit) or 0
  local limit = h.hop_start == 0 and 0 or math.min(3, hops + 2)
  send_channel(h.from, { portnum = mt.PORT.ROUTING, payload = mt.ACK_PAYLOAD, request_id = request_id }, false, limit)
end

local function send_dm(hx, text)
  local n = nodes[hx]
  dms[hx] = dms[hx] or {}
  local line = add(dms[hx], "me: " .. text .. "  ...", "me")
  if not (n and n.pub) then
    line[1], line[2] = "me: " .. text .. "  (no key yet)", "fail"
    send_nodeinfo(n and n.num or tonumber(hx, 16), true)
    shell.toast("Asked for their key: try again shortly")
    return
  end
  n.key = n.key or mt.pki_key(priv, n.pub)
  if not n.key then line[1], line[2] = "me: " .. text .. "  (bad key)", "fail"; return end
  local h = header(n.num, true)
  h.channel = 0
  local plain = mt.encode_data({ portnum = mt.PORT.TEXT, payload = text })
  local q = enqueue(h, mt.pki_encrypt(n.key, me, h.id, plain))
  waiting[pb.hex32(h.id)] = { line = line, text = text, tries = 1, frame = q.frame, at = now + 15 }
end

-- ---------------------------------------------------------------- receiving
local function on_data(h, d, n, hx, pki)
  local to_me = mt.same(h.to, me)
  local bcast = mt.same(h.to, mt.BROADCAST)
  local p = d.portnum
  if p == mt.PORT.TEXT then
    local text = clean(d.payload):sub(1, 230)
    if bcast then
      add(chat, name_of(hx) .. ": " .. text, "them")
      if tab ~= 1 then unread = unread + 1 end
      shell.sound("notify")
    elseif to_me then
      dms[hx] = dms[hx] or {}
      add(dms[hx], name_of(hx) .. ": " .. text, "them")
      if not (tab == 3 and peer == hx) then unread = unread + 1 end
      shell.sound("notify")
      if not pki then add(dms[hx], "* (sent without encryption)", "sys") end
    end
    if to_me and h.want_ack then send_ack(h, h.id) end
  elseif p == mt.PORT.NODEINFO then
    local u = mt.decode_user(d.payload)
    if u then
      n.long, n.short = clean(u.long_name or ""):sub(1, 39), clean(u.short_name or ""):sub(1, 4)
      if u.public_key and not n.pub then n.pub, n.key = u.public_key, nil end
      nodes_dirty = true
      if d.want_response and (to_me or bcast) and now - (n.info_at or -1e9) > 600 then
        n.info_at = now
        send_nodeinfo(h.from, false)
      end
    end
  elseif p == mt.PORT.POSITION then
    local pos = mt.decode_position(d.payload)
    if pos and math.abs(pos.lat) <= 90 and math.abs(pos.lon) <= 180 and (pos.lat ~= 0 or pos.lon ~= 0) then
      n.lat, n.lon = pos.lat, pos.lon
    end
  elseif p == mt.PORT.ROUTING and to_me and d.request_id then
    local w = waiting[pb.hex32(d.request_id)]
    local r = mt.decode_routing(d.payload)
    if w and r then
      waiting[pb.hex32(d.request_id)] = nil
      if r.error == 0 then
        w.line[1] = "me: " .. w.text .. "  ok"
      else
        w.line[1], w.line[2] = "me: " .. w.text .. "  (failed, " .. r.error .. ")", "fail"
        if r.error == 35 then send_nodeinfo(h.from, false) end  -- they don't have our key yet
      end
    end
    if h.want_ack and h.hop_start - h.hop_limit == 0 then send_ack(h, h.id) end
  end
end

local function on_packet(pk)
  local h, payload = mt.unpack(tostring(pk.data or ""))
  if not h then return end
  if mt.same(h.from, me) then  -- a relay of ours: counts as delivered to the mesh
    local w = waiting[pb.hex32(h.id)]
    if w then w.relayed = true end
    return
  end
  if not hist.check(h.from, h.id) then return end
  local plain, pki
  if h.channel == chan_hash then
    plain = mt.channel_crypt(chan_key, h.from, h.id, payload)
  elseif h.channel == 0 and mt.same(h.to, me) then
    local n0 = nodes[pb.hex32(h.from)]
    if n0 and n0.pub then
      n0.key = n0.key or mt.pki_key(priv, n0.pub)
      plain, pki = n0.key and mt.pki_decrypt(n0.key, h.from, h.id, payload), true
    end
  end
  local d = plain and mt.decode_data(plain)
  if not d then  -- another channel, or a key we don't have
    print(string.format("mesh: heard %s ch %02x, can't read it", mt.id_text(h.from), h.channel))
    return
  end
  rx = rx + 1
  print(string.format("mesh: %s port %d%s %d dBm hops %s", mt.id_text(h.from), d.portnum, pki and " pki" or "",
    math.floor(tonumber(pk.rssi) or 0), h.hop_start > 0 and (h.hop_start - h.hop_limit) or "?"))
  local n, hx = node(h.from)
  local first = not n.long and not n.short
  n.rssi, n.snr, n.seen = tonumber(pk.rssi) or 0, tonumber(pk.snr) or 0, now
  n.hops = h.hop_start > 0 and (h.hop_start - h.hop_limit) or nil
  on_data(h, d, n, hx, pki)
  if first and d.portnum ~= mt.PORT.NODEINFO and now - (n.info_at or -1e9) > 600 then
    n.info_at = now
    send_nodeinfo(h.from, true)  -- swap names and keys with a node we haven't met
  end
  rows_left = 0
end

-- ---------------------------------------------------------------- radio
local function start_radio()
  preset = mt.PRESETS[preset_i]
  local slot
  freq, slot = mt.freq_us(preset, chan_name ~= "" and chan_name or nil)
  chan_key = mt.expand_psk("\1")
  chan_hash = mt.channel_hash(chan_name ~= "" and chan_name or preset.name, chan_key)
  if not lora then radio_ok, radio_err = false, "No LoRa support in this firmware"; return end
  local ok, r, e = pcall(lora.begin, { freq = freq, bw = preset.bw, sf = preset.sf, cr = preset.cr,
    sync = 0x2B, preamble = 16, power = 22, tcxo = 1.8 })
  radio_ok = ok and r == true
  radio_err = not radio_ok and tostring(ok and (e or "LoRa radio not found") or r) or nil
  if radio_ok then
    add(chat, string.format("* %s on %.3f MHz (slot %d) as %s", preset.name, freq, slot, mt.id_text(me)), "sys")
    info_left = 5
  end
end

local function build_setup()
  srows = {
    { label = "Name", value = ui.fit(long_name, 120) },
    { label = "Short name", value = short_name },
    { label = "Preset", value = preset and preset.name or "?" },
    { label = "Share position", value = POS_MODES[pos_mode] },
    { label = "Node", value = mt.id_text(me), dim = true },
    { label = "Packets", value = "TX " .. tx .. "  RX " .. rx, dim = true },
  }
end

local function build_nodes()
  rows = {}
  local list = {}
  for hx, n in pairs(nodes) do if hx ~= me_hex then list[#list + 1] = { hx, n } end end
  table.sort(list, function(a, b) return (a[2].seen or -1) > (b[2].seen or -1) end)
  for i, e in ipairs(list) do
    local hx, n = e[1], e[2]
    local where = ""
    if n.lat and fix then
      where = " " .. geo.fmt_dist(geo.dist(fix.lat, fix.lon, n.lat, n.lon)) .. " "
        .. geo.compass(geo.bearing(fix.lat, fix.lon, n.lat, n.lon))
    end
    local heard = n.seen and (n.hops and n.hops > 0 and (n.hops .. " hop") or string.format("%d dBm", n.rssi or 0))
      or "saved"
    rows[i] = { label = ui.fit(name_of(hx) .. " " .. (n.long or "") .. where, 150), value = heard,
      dim = not n.seen, hex = hx, badge = n.pub and "K" or nil }
  end
  rsel = math.max(1, math.min(rsel, #rows))
end

-- ---------------------------------------------------------------- lifecycle
function app.init()
  load_nodes()
  local p = cfg.get("mesh_priv")
  if not p or #p ~= 64 then
    p = hex(crypto.random(32))
    cfg.set("mesh_priv", p)
  end
  priv = unhex(p)
  pub = crypto.public(priv)
  local mac = (net and net.mac and net.mac() or "000000000000"):gsub("[^%x]", "")
  me = tonumber(mac:sub(-8), 16) or 0x50430001
  if mt.u32(me) < 4 or mt.same(me, mt.BROADCAST) then me = 0x50430001 end
  me_hex = pb.hex32(me)
  long_name = cfg.get("mesh_long") or ("PocketLua " .. me_hex:sub(-4))
  short_name = cfg.get("mesh_short") or me_hex:sub(-4)
  preset_i = math.max(1, math.min(#mt.PRESETS, tonumber(cfg.get("mesh_preset")) or 1))
  pos_mode = math.max(1, math.min(3, tonumber(cfg.get("mesh_pos")) or 1))
  start_radio()
  if gps then pcall(gps.start) end
  add(chat, "* Enter sends to everyone on " .. (preset and preset.name or "?") .. ". Tab: Nodes, DMs", "sys")
  build_setup()
end

function app.update(dt)
  now = now + dt
  blink = (now % 1) < 0.5

  gps_left = gps_left - dt
  if gps_left <= 0 and gps then
    gps_left = 2
    local ok, g = pcall(gps.read)
    fix = ok and g and g.valid and g or nil
  end
  if not radio_ok then return end

  for _ = 1, 4 do  -- recv() also finishes a transmit, so it runs every frame
    local ok, pk = pcall(lora.recv)
    if not ok or not pk then break end
    on_packet(pk)
  end

  info_left, pos_left = info_left - dt, pos_left - dt
  if info_left <= 0 then info_left = NODEINFO_EVERY; send_nodeinfo(nil, false) end
  if pos_left <= 0 then pos_left = send_position() and POS_EVERY or 30 end

  -- resend DMs that got no ACK and weren't heard relayed: three tries
  for k, w in pairs(waiting) do
    if now >= w.at then
      if w.tries >= 3 then
        waiting[k] = nil
        if w.relayed then w.line[1] = "me: " .. w.text .. "  (sent, no receipt)"
        else w.line[1], w.line[2] = "me: " .. w.text .. "  (not delivered)", "fail" end
      else
        w.tries, w.at = w.tries + 1, now + 15
        queue[#queue + 1] = { frame = w.frame, at = now }
      end
    end
  end

  if #queue > 0 and not lora.busy() and now >= queue[1].at then
    local q = table.remove(queue, 1)
    local ok, r = pcall(lora.send, q.frame)
    if ok and r ~= false then tx = tx + 1 end
  end

  rows_left = rows_left - dt
  if rows_left <= 0 then
    rows_left = 1
    if tab == 2 then build_nodes() elseif tab == 4 then build_setup() end
    if nodes_dirty and math.floor(now) % 30 == 0 then save_nodes() end
  end
  if tab == 1 or (tab == 3 and peer) then unread = 0 end
  local label = unread > 0 and ("Chat " .. unread) or "Chat"
  if TABS[1] ~= label then TABS[1] = label end
end

local function draw_lines(list)
  local last = #list - scroll
  for i = 0, ROWS - 1 do
    local l = list[last - ROWS + 1 + i]
    if l then ui.text(4, 33 + i * 10, l[1], kind_col(l[2])) end
  end
  if scroll > 0 then ui.right(236, 33, "^" .. scroll, col.muted) end
  gfx.line(4, 107, 236, 107, col.line)
  local shown = #input > 36 and input:sub(-36) or input
  ui.text(4, 112, "> " .. shown .. (blink and "_" or ""), col.text)
end

function app.draw()
  ui.tabs(TABS, tab, 16)
  if tab == 4 then
    stop_ = ui.list(srows, ssel, stop_, 4, 33, 229, 15, 5)
    ui.text(4, 112, "Enter or </> changes", col.muted)
    ui.footer({ { "Enter", "Change" }, { "Tab", "Chat" }, { "Esc", "Back" } })
    return
  end
  if not radio_ok then
    ui.empty("antenna", ui.fit(tostring(radio_err), 228), "Attach the Cap LoRa-1262")
    ui.footer({ { "R", "Retry" }, { "Tab", "Setup" }, { "Esc", "Back" } })
    return
  end
  if tab == 1 then
    draw_lines(chat)
    ui.footer({ { "Enter", "Send all" }, { "Tab", "Nodes" }, { "Esc", "Back" } })
  elseif tab == 2 then
    if #rows == 0 then ui.empty("antenna", "No nodes heard yet", "They appear as they send")
    else rtop = ui.list(rows, rsel, rtop, 4, 33, 229, 15, 6) end
    ui.footer({ { "Enter", "Message" }, { "Tab", "DMs" }, { "Esc", "Back" } })
  else
    if not peer then
      ui.empty("antenna", "No conversation open", "Pick a node in Nodes, Enter")
    else
      draw_lines(dms[peer] or {})
      ui.right(236, 112, name_of(peer), col.muted)
    end
    ui.footer({ { "Enter", "Send" }, { "Tab", "Setup" }, { "Esc", "Back" } })
  end
end

local function change(i, d)
  if i == 1 or i == 2 then
    shell.prompt(i == 1 and "Name (up to 39)" or "Short name (up to 4)", i == 1 and long_name or short_name, function(t)
      t = t and clean(t):match("^%s*(.-)%s*$")
      if not t or t == "" then return end
      if i == 1 then long_name = t:sub(1, 39); cfg.set("mesh_long", long_name)
      else short_name = t:sub(1, 4); cfg.set("mesh_short", short_name) end
      info_left = 2  -- tell the mesh
      build_setup()
    end)
    return
  elseif i == 3 then
    preset_i = (preset_i - 1 + d) % #mt.PRESETS + 1
    cfg.set("mesh_preset", tostring(preset_i))
    start_radio()
    shell.toast(radio_ok and string.format("%s %.3f MHz", preset.name, freq) or ("Radio: " .. tostring(radio_err)))
  elseif i == 4 then
    pos_mode = (pos_mode - 1 + d) % #POS_MODES + 1
    cfg.set("mesh_pos", tostring(pos_mode))
    pos_left = 3
    shell.toast(pos_mode == 1 and "Position not shared" or pos_mode == 2 and "Sharing an approximate position (~5 km)"
      or "Sharing your exact position", 2)
  else
    return
  end
  build_setup()
end

local function type_key(k, on_send)
  if k.key == "enter" then
    local t = clean(input):match("^%s*(.-)%s*$")
    if t ~= "" then on_send(t:sub(1, 200)) end
    input = ""
  elseif k.key == "backspace" then input = input:sub(1, -2)
  elseif k.key == "esc" then
    if input == "" then return false end
    input = ""
  elseif k.key == "up" then scroll = scroll + 1
  elseif k.key == "down" then scroll = math.max(0, scroll - 1)
  elseif k.text and not k.ctrl and not k.fn then
    if #input < 200 then input = input .. k.text end
  else
    return false
  end
  return true
end

function app.key(k)
  if k.key == "tab" then
    tab = k.shift and (tab - 2) % #TABS + 1 or tab % #TABS + 1
    rows_left, scroll = 0, 0
    return true
  end
  if tab == 4 then
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
    if d == "up" then rsel = math.max(1, rsel - 1)
    elseif d == "down" then rsel = math.min(#rows, rsel + 1)
    elseif k.key == "enter" and rows[rsel] then
      peer, tab, scroll = rows[rsel].hex, 3, 0
    else return k.key ~= "esc" end
    return true
  end
  if tab == 3 then
    if not peer then return k.key ~= "esc" end
    return type_key(k, function(t) send_dm(peer, t) end)
  end
  return type_key(k, function(t)
    send_channel(mt.BROADCAST, { portnum = mt.PORT.TEXT, payload = t })
    add(chat, "me: " .. t, "me")
  end)
end

function app.close()
  save_nodes()
  if lora then pcall(lora.stop) end
  if gps then pcall(gps.stop) end
  chat, dms, nodes, rows, queue, waiting = {}, {}, {}, {}, {}, {}
  unload("meshtastic")
  unload("protobuf")
  unload("geo_math")
end

return app
