-- Mesh: a Meshtastic-compatible node on the Cap LoRa-1262. Chat on the public
-- channel and private channels, see the nodes around (battery, position,
-- traceroute), send private (public-key) messages and share a position.
-- It joins as CLIENT_MUTE: it never relays other nodes' packets. The radio only
-- runs while the app is open, and Wi-Fi is off meanwhile (focus mode) for the
-- memory. Chats are kept in data/mesh. The Nodes and Setup
-- tabs live in lib/mesh/ and load while open (all of it at once doesn't fit).
-- Protocol: lib/meshtastic.lua and docs/MESHTASTIC.md.
local col = ui.col
local app = { title = "Mesh", icon = "antenna", color = "green", order = 52, category = "net" }
app.help = {
  { "Tab", "Next tab" },
  { "Enter", "Send / open / change" },
  { "<>", "Chat: channel" },
  { "Up/Dn", "Scroll / pick" },
  { "T", "Node: traceroute" },
  { "X", "DMs: remove contact" },
  { "M", "DMs: quiet contact" },
  { "R", "Nodes: radar" },
  { "Esc", "Clear, then back" },
}

local mt = require("meshtastic")
local pb = require("protobuf")

local TABS = { "Chat", "Nodes", "DMs", "Setup" }
local DIR = "data/mesh"
local MAX_LINES, MAX_NODES, KEEP, ROWS = 40, 40, 40, 7
local NODEINFO_EVERY, POS_EVERY = 3 * 3600, 15 * 60

-- S is what the tab modules share with the core
local S = { mt = mt, pb = pb, nodes = {}, channels = {}, chat = {}, dms = {}, unread = {}, contacts = {}, chan_sel = 1,
  now = 0, tx = 0, rx = 0, pos_mode = 1, preset_i = 1, radio_ok = false }
local tab, tabmod = 1, nil
local hist = mt.history(120)
local nodes_dirty = false
local scroll, input, blink = 0, "", true
local queue, waiting, traces = {}, {}, {}
local crows, csel, ctop = {}, 1, 1  -- the DMs tab's contact list
local gps_left, info_left, pos_left, save_left = 0, 5, 60, 30

-- ---------------------------------------------------------------- helpers
function S.hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
function S.unhex(s) return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)) end
function S.clean(s)  -- UTF-8 (emoji) to "?", no control characters
  return (s:gsub("[\xC0-\xFF][\x80-\xBF]*", "?"):gsub("[^\32-\126]", ""))
end

function S.name_of(hx)
  local n = S.nodes[hx]
  if n and n.short and n.short ~= "" then return n.short end
  if n and n.long and n.long ~= "" then return n.long end
  return "!" .. hx:sub(-4)
end

function S.chan_name(i)
  local c = S.channels[i]
  return c and (c.name ~= "" and c.name or (S.preset and S.preset.name or "?")) or "?"
end

-- ---------------------------------------------------------------- history
-- One file per conversation, a line per message: kind TAB text.
local function chat_file(i) return DIR .. "/ch_" .. S.chan_name(i):gsub("[^%w%-_]", "_") .. ".txt" end
local function dm_file(hx) return DIR .. "/dm_" .. hx .. ".txt" end

local function push(list, text, kind)
  for _, l in ipairs(ui.wrap(text, 220)) do list[#list + 1] = { l, kind } end  -- room for a delivery mark
  while #list > MAX_LINES do table.remove(list, 1) end
  return list[#list]
end

local function load_history(file)
  local entries = {}
  for line in (sys.read_text(file) or ""):gmatch("[^\n]+") do entries[#entries + 1] = line end
  local list = {}
  for i = math.max(1, #entries - KEEP + 1), #entries do
    local kind, text = entries[i]:match("^(%a+)\t(.*)$")
    if kind then push(list, text, kind) end
  end
  if #entries > KEEP + 20 then  -- keep the file short
    sys.write_text(file, table.concat(entries, "\n", #entries - KEEP + 1) .. "\n")
  end
  return list
end

-- add a message to a conversation (and its file); returns its last line
local function add(list, file, text, kind)
  if file and kind ~= "sys" then
    sys.mkdirs(DIR)
    sys.append_text(file, kind .. "\t" .. text .. "\n")
  end
  scroll = 0
  return push(list, text, kind)
end

function S.chat_lines(i)
  if not S.chat[i] then S.chat[i] = load_history(chat_file(i)) end
  return S.chat[i]
end
function S.dm_lines(hx)
  if not S.dms[hx] then S.dms[hx] = load_history(dm_file(hx)) end
  return S.dms[hx]
end

-- ---------------------------------------------------------------- contacts
-- Everyone we've had a DM with, most recent first (data/mesh/contacts.txt).
-- They stay in the node list (and keep their keys) however many nodes pass.
local function save_contacts()
  sys.mkdirs(DIR)
  sys.write_text(DIR .. "/contacts.txt", table.concat(S.contacts, "\n") .. "\n")
end

local function touch(hx)
  for i, c in ipairs(S.contacts) do if c == hx then table.remove(S.contacts, i); break end end
  table.insert(S.contacts, 1, hx)
  save_contacts()
end

function S.is_contact(hx)
  for _, c in ipairs(S.contacts) do if c == hx then return true end end
  return false
end

-- ---------------------------------------------------------------- quiet
-- cfg mesh_mute_ch (channel names) and mesh_mute_dm (node hexes) are comma
-- lists; mesh_dm_new = "0" keeps DMs from people not in the list quiet. The
-- background listener (meshsvc.cpp) reads the same settings.
function S.listed(key, item) return ("," .. (cfg.get(key) or "") .. ","):find("," .. item .. ",", 1, true) ~= nil end
function S.toggle(key, item)
  local out, found = {}, false
  for v in (cfg.get(key) or ""):gmatch("[^,]+") do
    if v == item then found = true else out[#out + 1] = v end
  end
  if not found then out[#out + 1] = item end
  cfg.set(key, #out > 0 and table.concat(out, ",") or nil)
  return not found
end
local function dm_quiet(hx)
  return S.listed("mesh_mute_dm", hx) or (not S.is_contact(hx) and cfg.get("mesh_dm_new") == "0")
end
local importing = false
local function ding(quiet) if not quiet and not importing then shell.sound("notify") end end

local function build_contacts()
  crows = {}
  for i, hx in ipairs(S.contacts) do
    local n = S.nodes[hx]
    local quiet = S.listed("mesh_mute_dm", hx)
    crows[i] = { label = ui.fit(S.name_of(hx) .. "  " .. (n and n.long or ""), 140), dim = not (n and n.seen),
      value = (quiet and "quiet " or "") .. (n and n.seen and "nearby" or ""),
      badge = S.unread[hx] and tostring(S.unread[hx]) or nil, badge_color = ui.accents.orange }
  end
  csel = math.max(1, math.min(csel, #crows))
end

-- ---------------------------------------------------------------- nodes
local function save_nodes()
  if not nodes_dirty then return end
  local out = {}
  for hx, n in pairs(S.nodes) do
    out[#out + 1] = table.concat({ hx, (n.long or ""):gsub("[|\n]", " "), (n.short or ""):gsub("[|\n]", " "),
      n.pub and S.hex(n.pub) or "" }, "|") .. "\n"
  end
  sys.mkdirs(DIR)
  sys.write_text(DIR .. "/nodes.txt", table.concat(out))
  nodes_dirty = false
end

local function load_nodes()
  for line in (sys.read_text(DIR .. "/nodes.txt") or ""):gmatch("[^\n]+") do
    local hx, l, s, k = line:match("^(%x+)|([^|]*)|([^|]*)|(%x*)$")
    if hx then S.nodes[hx] = { num = tonumber(hx, 16), long = l, short = s, pub = #k == 64 and S.unhex(k) or nil } end
  end
end

local function node(num)
  local hx = pb.hex32(num)
  local n = S.nodes[hx]
  if not n then
    local count, old, old_seen = 0, nil, math.huge
    for k, v in pairs(S.nodes) do
      count = count + 1
      if (v.seen or -1) < old_seen and k ~= S.peer and not S.is_contact(k) then old, old_seen = k, v.seen or -1 end
    end
    if count >= MAX_NODES and old then S.nodes[old] = nil end
    n = { num = num }
    S.nodes[hx] = n
  end
  return n, hx
end

-- ---------------------------------------------------------------- channels
-- channel 1 is the preset's public channel; the rest are private, saved as
-- name|hex key in data/mesh/channels.txt
local function set_channel(i, name, psk)
  local key = mt.expand_psk(psk)
  S.channels[i] = { name = name, psk = psk, key = key,
    hash = mt.channel_hash(name ~= "" and name or S.preset.name, key) }
end

function S.save_channels()
  local out = {}
  for i = 2, #S.channels do out[#out + 1] = S.channels[i].name .. "|" .. S.hex(S.channels[i].psk) .. "\n" end
  sys.mkdirs(DIR)
  sys.write_text(DIR .. "/channels.txt", table.concat(out))
end

function S.add_channel(name, psk)
  set_channel(#S.channels + 1, name, psk)
  S.save_channels()
end

function S.remove_channel(i)
  if i < 2 or i > #S.channels then return end
  table.remove(S.channels, i)
  table.remove(S.chat, i)
  S.chan_sel = math.min(S.chan_sel, #S.channels)
  S.save_channels()
end

local function load_channels()
  set_channel(1, "", "\1")
  for line in (sys.read_text(DIR .. "/channels.txt") or ""):gmatch("[^\n]+") do
    local name, k = line:match("^([^|]+)|(%x+)$")
    if name and #S.channels < 8 then set_channel(#S.channels + 1, name, S.unhex(k)) end
  end
end

-- ---------------------------------------------------------------- sending
local function header(to, want_ack, hop_limit, channel)
  return { to = to, from = S.me, id = mt.new_id(), hop_limit = hop_limit or 3, hop_start = hop_limit or 3,
    want_ack = want_ack, channel = channel, relay = mt.last_byte(S.me) }
end

local function enqueue(h, payload)
  hist.check(S.me, h.id)
  local q = { frame = mt.pack(h, payload), at = S.now + 0.05 + math.random() * 0.25 }
  queue[#queue + 1] = q
  return q
end

-- on channel ci's key (1 = public): broadcasts, NodeInfo, positions, ACKs
function S.send_channel(ci, to, data, want_ack, hop_limit)
  local c = S.channels[ci or 1]
  local h = header(to, want_ack and not mt.same(to, mt.BROADCAST), hop_limit, c.hash)
  enqueue(h, mt.channel_crypt(c.key, S.me, h.id, mt.encode_data(data)))
  return h.id
end

local function my_user()
  return mt.encode_user({ id = mt.id_text(S.me), long_name = S.long_name, short_name = S.short_name,
    hw_model = mt.HW_PRIVATE, role = mt.ROLE_CLIENT_MUTE, public_key = S.pub })
end

function S.send_nodeinfo(to, want_response)
  S.send_channel(1, to or mt.BROADCAST, { portnum = mt.PORT.NODEINFO, payload = my_user(), want_response = want_response })
end
function S.announce() info_left = 2 end
function S.position_soon() pos_left = 3 end

local function send_position()  -- false when there is nothing to send yet
  if S.pos_mode == 1 or not S.fix then return false end
  local t = clock and clock.now and clock.now()
  S.send_channel(1, mt.BROADCAST, { portnum = mt.PORT.POSITION, payload = mt.encode_position({
    lat = S.fix.lat, lon = S.fix.lon, alt = tonumber(S.fix.alt), precision = S.pos_mode == 2 and 13 or nil,
    time = t and t.valid and t.unix or nil }) })
  return true
end

local function send_ack(h, ci, request_id)
  local hops = h.hop_start > 0 and (h.hop_start - h.hop_limit) or 0
  local limit = h.hop_start == 0 and 0 or math.min(3, hops + 2)
  S.send_channel(ci, h.from, { portnum = mt.PORT.ROUTING, payload = mt.ACK_PAYLOAD, request_id = request_id }, false, limit)
end

function S.send_dm(hx, text)
  local n = S.nodes[hx]
  local list = S.dm_lines(hx)
  if not (n and n.pub) then
    push(list, "me: " .. text .. "  (no key yet)", "fail")
    S.send_nodeinfo(n and n.num or tonumber(hx, 16), true)
    shell.toast("Asked for their key: try again shortly")
    return
  end
  n.key = n.key or mt.pki_key(S.priv, n.pub)
  if not n.key then push(list, "me: " .. text .. "  (bad key)", "fail"); return end
  touch(hx)
  local line = add(list, dm_file(hx), "me: " .. text, "me")
  line.status = "wait"
  local h = header(n.num, true)
  h.channel = 0
  local q = enqueue(h, mt.pki_encrypt(n.key, S.me, h.id, mt.encode_data({ portnum = mt.PORT.TEXT, payload = text })))
  waiting[pb.hex32(h.id)] = { line = line, tries = 1, frame = q.frame, at = S.now + 15 }
end

function S.traceroute(hx)
  local n = S.nodes[hx]
  if not n then return end
  if traces[hx] and S.now - traces[hx].at < 30 then shell.toast("Wait 30 s between traceroutes"); return end
  local id = S.send_channel(1, n.num, { portnum = mt.PORT.TRACEROUTE, payload = "", want_response = true })
  traces[hx] = { id = id, at = S.now }
  n.trace = "waiting for a reply..."
  shell.toast("Traceroute sent")
end

-- ---------------------------------------------------------------- receiving
local function route_text(r, from_hx)
  local parts = { "me" }
  for _, v in ipairs(r.route) do parts[#parts + 1] = S.name_of(pb.hex32(v)) end
  parts[#parts + 1] = S.name_of(from_hx)
  local s = table.concat(parts, " > ")
  if #r.route_back > 0 then
    local back = { S.name_of(from_hx) }
    for _, v in ipairs(r.route_back) do back[#back + 1] = S.name_of(pb.hex32(v)) end
    back[#back + 1] = "me"
    s = s .. "; back " .. table.concat(back, " > ")
  end
  return s
end

local function on_data(h, d, n, hx, ci)
  local to_me, bcast = mt.same(h.to, S.me), mt.same(h.to, mt.BROADCAST)
  local p = d.portnum
  if p == mt.PORT.TEXT then
    local text = S.clean(d.payload):sub(1, 230)
    if bcast and ci then
      add(S.chat_lines(ci), chat_file(ci), S.name_of(hx) .. ": " .. text, "them")
      if not (tab == 1 and S.chan_sel == ci) then S.unread_chat = (S.unread_chat or 0) + 1 end
      ding(S.listed("mesh_mute_ch", S.chan_name(ci)))
    elseif to_me then
      local quiet = dm_quiet(hx)
      touch(hx)
      add(S.dm_lines(hx), dm_file(hx), S.name_of(hx) .. ": " .. text, "them")
      if not (tab == 3 and S.peer == hx) then S.unread[hx] = (S.unread[hx] or 0) + 1 end
      ding(quiet)
    end
    if to_me and h.want_ack then send_ack(h, ci or 1, h.id) end
  elseif p == mt.PORT.NODEINFO then
    local u = mt.decode_user(d.payload)
    if u then
      n.long, n.short = S.clean(u.long_name or ""):sub(1, 39), S.clean(u.short_name or ""):sub(1, 4)
      if u.public_key and not n.pub then n.pub, n.key = u.public_key, nil end
      nodes_dirty = true
      if d.want_response and (to_me or bcast) and S.now - (n.info_at or -1e9) > 600 then
        n.info_at = S.now
        S.send_nodeinfo(h.from, false)
      end
    end
  elseif p == mt.PORT.POSITION then
    local pos = mt.decode_position(d.payload)
    if pos and math.abs(pos.lat) <= 90 and math.abs(pos.lon) <= 180 and (pos.lat ~= 0 or pos.lon ~= 0) then
      n.lat, n.lon, n.alt, n.pos_at = pos.lat, pos.lon, pos.alt, S.now
    end
  elseif p == mt.PORT.TELEMETRY then
    local t = mt.decode_telemetry(d.payload)
    if t then for k, v in pairs(t) do n[k] = v end end
  elseif p == mt.PORT.TRACEROUTE and to_me and d.request_id then
    local tr = traces[hx]
    local r = mt.decode_route(d.payload)
    if tr and r and mt.same(tr.id, d.request_id) then
      n.trace = route_text(r, hx)
      traces[hx] = nil
      shell.toast("Traceroute: " .. #r.route .. " hop(s) between")
    end
  elseif p == mt.PORT.ROUTING and to_me and d.request_id then
    local k = pb.hex32(d.request_id)
    local w, r = waiting[k], mt.decode_routing(d.payload)
    if w and r then
      waiting[k] = nil
      if r.error == 0 then w.line.status = "ok"
      else
        w.line.status, w.line[2] = "fail", "fail"
        if r.error == 35 then S.send_nodeinfo(h.from, false) end  -- they don't have our key yet
      end
    end
    if h.want_ack and h.hop_start - h.hop_limit == 0 then send_ack(h, ci or 1, h.id) end
  end
end

local function on_packet(pk)
  local h, payload = mt.unpack(tostring(pk.data or ""))
  if not h then return end
  if mt.same(h.from, S.me) then  -- a relay of ours: it reached the mesh
    local w = waiting[pb.hex32(h.id)]
    if w then w.relayed = true end
    return
  end
  if not hist.check(h.from, h.id) then return end
  local d, ci
  if h.channel == 0 and mt.same(h.to, S.me) then
    local n0 = S.nodes[pb.hex32(h.from)]
    if n0 and n0.pub then
      n0.key = n0.key or mt.pki_key(S.priv, n0.pub)
      local plain = n0.key and mt.pki_decrypt(n0.key, h.from, h.id, payload)
      d = plain and mt.decode_data(plain)
    end
  end
  for i, c in ipairs(S.channels) do
    if d then break end
    if c.hash == h.channel then
      d = mt.decode_data(mt.channel_crypt(c.key, h.from, h.id, payload))
      if d then ci = i end
    end
  end
  if not d then
    print(string.format("mesh: heard %s ch %02x, can't read it", mt.id_text(h.from), h.channel))
    return
  end
  S.rx = S.rx + 1
  local n, hx = node(h.from)
  print(string.format("mesh: %s port %d ch %s %d dBm hops %s", mt.id_text(h.from), d.portnum, ci or "pki",
    math.floor(tonumber(pk.rssi) or 0), h.hop_start > 0 and (h.hop_start - h.hop_limit) or "?"))
  local first = not n.long and not n.short
  n.rssi, n.snr, n.seen = tonumber(pk.rssi) or 0, tonumber(pk.snr) or 0, S.now
  n.hops = h.hop_start > 0 and (h.hop_start - h.hop_limit) or nil
  on_data(h, d, n, hx, ci)
  if first and d.portnum ~= mt.PORT.NODEINFO and S.now - (n.info_at or -1e9) > 600 then
    n.info_at = S.now
    S.send_nodeinfo(h.from, true)  -- swap names and keys with a node we haven't met
  end
end

-- ---------------------------------------------------------------- radio
function S.start_radio()
  S.preset = mt.PRESETS[S.preset_i]
  local p = S.preset
  local slot
  S.freq, slot = mt.freq_us(p)
  set_channel(1, "", "\1")
  for i = 2, #S.channels do set_channel(i, S.channels[i].name, S.channels[i].psk) end
  if not lora then S.radio_ok, S.radio_err = false, "No LoRa support in this firmware"; return end
  local ok, r, e = pcall(lora.begin, { freq = S.freq, bw = p.bw, sf = p.sf, cr = p.cr,
    sync = 0x2B, preamble = 16, power = 22, tcxo = 1.8 })
  S.radio_ok = ok and r == true
  S.radio_err = not S.radio_ok and tostring(ok and (e or "LoRa radio not found") or r) or nil
  if S.radio_ok then
    push(S.chat_lines(1), string.format("* %s %.3f MHz (slot %d) as %s", p.name, S.freq, slot, mt.id_text(S.me)), "sys")
    info_left = 5
  end
end

-- ---------------------------------------------------------------- tabs
local function load_tab(i)  -- literal requires, so tools/release.py ships them
  if i == 2 then return require("mesh/nodes") elseif i == 4 then return require("mesh/setup") end
end
local MODS = { nil, "mesh/nodes", nil, "mesh/setup" }

function S.set_tab(i)
  if i == 3 then build_contacts() end
  if tabmod then
    if tabmod.close then tabmod.close() end
    unload(MODS[tab])
    tabmod = nil
    collectgarbage("collect")
  end
  tab, scroll = i, 0
  if MODS[i] then
    tabmod = load_tab(i)(S)
    if tabmod.init then tabmod.init() end
  end
end

function S.open_dm(hx)
  S.peer = hx
  S.unread[hx] = nil
  cfg.set("mesh_peer", hx)
  S.set_tab(3)
end

-- ---------------------------------------------------------------- lifecycle
function app.init()
  shell.focus(true)  -- Wi-Fi off while Mesh is open: its ~36 KB lets Mesh fit
  load_nodes()
  local p = cfg.get("mesh_priv")
  if not p or #p ~= 64 then
    p = S.hex(crypto.random(32))
    cfg.set("mesh_priv", p)
  end
  S.priv = S.unhex(p)
  S.pub = crypto.public(S.priv)
  local mac = (net and net.mac and net.mac() or "000000000000"):gsub("[^%x]", "")
  S.me = tonumber(mac:sub(-8), 16) or 0x50430001
  if mt.u32(S.me) < 4 or mt.same(S.me, mt.BROADCAST) then S.me = 0x50430001 end
  S.me_hex = pb.hex32(S.me)
  S.long_name = cfg.get("mesh_long") or ("PocketLua " .. S.me_hex:sub(-4))
  S.short_name = cfg.get("mesh_short") or S.me_hex:sub(-4)
  S.preset_i = math.max(1, math.min(#mt.PRESETS, tonumber(cfg.get("mesh_preset")) or 1))
  S.pos_mode = math.max(1, math.min(3, tonumber(cfg.get("mesh_pos")) or 1))
  S.preset = mt.PRESETS[S.preset_i]
  load_channels()
  for hx in (sys.read_text(DIR .. "/contacts.txt") or ""):gmatch("%x+") do S.contacts[#S.contacts + 1] = hx end
  local last = cfg.get("mesh_peer")
  if last and S.is_contact(last) then S.peer = last end  -- the DMs tab opens where you left it
  S.start_radio()
  if gps then pcall(gps.start) end
  -- what the background listener kept while Mesh was closed (meshsvc.cpp)
  local inbox = sys.read_text(DIR .. "/inbox.txt")
  if inbox and inbox ~= "" then
    sys.write_text(DIR .. "/inbox.txt", "")
    importing = true
    for rssi, snr, hx in inbox:gmatch("(%-?%d+) (%-?[%d.]+) (%x+)") do
      on_packet({ data = S.unhex(hx), rssi = tonumber(rssi), snr = tonumber(snr) })
    end
    importing = false
  end
end

function app.update(dt)
  S.now = S.now + dt
  blink = (S.now % 1) < 0.5
  gps_left = gps_left - dt
  if gps_left <= 0 and gps then
    gps_left = 2
    local ok, g = pcall(gps.read)
    S.fix = ok and g and g.valid and g or nil
  end
  if tabmod and tabmod.update then tabmod.update(dt) end
  if not S.radio_ok then return end

  for _ = 1, 4 do  -- recv() also finishes a transmit, so it runs every frame
    local ok, pk = pcall(lora.recv)
    if not ok or not pk then break end
    on_packet(pk)
  end

  info_left, pos_left, save_left = info_left - dt, pos_left - dt, save_left - dt
  if info_left <= 0 then info_left = NODEINFO_EVERY; S.send_nodeinfo(nil, false) end
  if pos_left <= 0 then pos_left = send_position() and POS_EVERY or 30 end
  if save_left <= 0 then save_left = 30; save_nodes() end

  for k, w in pairs(waiting) do  -- three tries for a DM without an ACK
    if S.now >= w.at then
      if w.tries >= 3 then
        waiting[k] = nil
        if w.relayed then w.line.status = "relay"
        else w.line.status, w.line[2] = "fail", "fail" end
      else
        w.tries, w.at = w.tries + 1, S.now + 15
        queue[#queue + 1] = { frame = w.frame, at = S.now }
      end
    end
  end

  if #queue > 0 and not lora.busy() and S.now >= queue[1].at then
    local q = table.remove(queue, 1)
    local ok, r = pcall(lora.send, q.frame)
    if ok and r ~= false then S.tx = S.tx + 1 end
  end

  if tab == 1 then S.unread_chat = nil end
  if tab == 3 and not S.peer and math.floor(S.now) ~= math.floor(S.now - dt) then build_contacts() end
  local dm = 0
  for _, c in pairs(S.unread) do dm = dm + c end
  TABS[1] = S.unread_chat and ("Chat " .. S.unread_chat) or "Chat"
  TABS[3] = dm > 0 and ("DMs " .. dm) or "DMs"
end

local function kind_col(kind)
  if kind == "me" then return col.accent elseif kind == "sys" then return col.muted
  elseif kind == "fail" then return col.warn end
  return col.text
end

local function draw_lines(list, label)
  local last = #list - scroll
  for i = 0, ROWS - 1 do
    local l = list[last - ROWS + 1 + i]
    if l then
      local y = 33 + i * 10
      ui.text(4, y, l[1], kind_col(l[2]))
      local st = l.status
      if st == "wait" then ui.text(228, y, "..", col.muted)
      elseif st == "fail" then ui.text(231, y, "!", col.warn)
      elseif st then  -- a tick when the mesh relayed it, two when they confirmed
        local c = st == "ok" and col.good or col.muted
        gfx.line(227, y + 4, 229, y + 6, c); gfx.line(229, y + 6, 233, y + 1, c)
        if st == "ok" then gfx.line(232, y + 6, 236, y + 1, c) end
      end
    end
  end
  if scroll > 0 then ui.right(236, 33, "^" .. scroll, col.muted) end
  gfx.line(4, 107, 236, 107, col.line)
  local shown = #input > 26 and input:sub(-26) or input
  ui.text(4, 112, "> " .. shown .. (blink and "_" or ""), col.text)
  ui.right(236, 112, ui.fit(label, 70), col.muted)
end

function app.draw()
  ui.tabs(TABS, tab, 16)
  if tabmod then tabmod.draw(); return end
  if not S.radio_ok then
    ui.empty("antenna", ui.fit(tostring(S.radio_err), 228), "Attach the Cap LoRa-1262")
    ui.footer({ { "R", "Retry" }, { "Tab", "Next" }, { "Esc", "Back" } })
    return
  end
  if tab == 1 then
    draw_lines(S.chat_lines(S.chan_sel), S.chan_name(S.chan_sel))
    ui.footer(#S.channels > 1 and { { "Enter", "Send" }, { "<>", "Channel" }, { "Tab", "Nodes" } }
      or { { "Enter", "Send all" }, { "Tab", "Nodes" }, { "Esc", "Back" } })
  elseif not S.peer then
    if #crows == 0 then ui.empty("antenna", "No conversations yet", "Pick a node in Nodes, Enter")
    else ctop = ui.list(crows, csel, ctop, 4, 33, 229, 15, 6) end
    ui.footer(#crows > 0 and { { "Enter", "Open" }, { "M", "Quiet" }, { "X", "Remove" } }
      or { { "Tab", "Setup" }, { "Esc", "Back" } })
  else
    draw_lines(S.dm_lines(S.peer), S.name_of(S.peer))
    ui.footer({ { "Enter", "Send" }, { "Esc", "Contacts" }, { "Tab", "Setup" } })
  end
end

local function type_key(k, d, on_send)
  if k.key == "enter" then
    local t = S.clean(input):match("^%s*(.-)%s*$")
    if t ~= "" then on_send(t:sub(1, 200)) end
    input = ""
  elseif k.key == "backspace" then input = input:sub(1, -2)
  elseif k.key == "esc" then
    if input == "" then return false end
    input = ""
  elseif d == "up" then scroll = scroll + 1
  elseif d == "down" then scroll = math.max(0, scroll - 1)
  elseif k.text and not k.ctrl and not k.fn then
    if #input < 200 then input = input .. k.text end
  else
    return false
  end
  return true
end

function app.key(k)
  if k.key == "tab" then
    S.set_tab(k.shift and (tab - 2) % #TABS + 1 or tab % #TABS + 1)
    return true
  end
  local d = ui.nav(k)
  if tabmod then return tabmod.key(k, d) end
  if not S.radio_ok then
    if k.text and k.text:lower() == "r" and not k.fn and tab ~= 2 then
      S.start_radio()
      shell.toast(S.radio_ok and "Radio ready" or tostring(S.radio_err))
      return true
    end
    return k.key ~= "esc"
  end
  if tab == 3 then
    if not S.peer then
      local c = not k.ctrl and not k.fn and k.text and k.text:lower()
      local hx = S.contacts[csel]
      if d == "up" then csel = math.max(1, csel - 1)
      elseif d == "down" then csel = math.min(#crows, csel + 1)
      elseif k.key == "enter" and hx then S.open_dm(hx)
      elseif c == "m" and hx then
        shell.toast(S.name_of(hx) .. (S.toggle("mesh_mute_dm", hx) and ": quiet" or ": sound on"))
        build_contacts()
      elseif c == "x" and hx then
        shell.confirm("Remove " .. S.name_of(hx) .. "?", "From the list; the messages stay on the card.", function(yes)
          if yes then table.remove(S.contacts, csel); save_contacts(); build_contacts() end
        end)
      else return k.key ~= "esc" end
      return true
    end
    S.unread[S.peer] = nil
    if k.key == "esc" and input == "" then  -- back to the contact list
      S.peer = nil
      cfg.set("mesh_peer", nil)
      build_contacts()
      return true
    end
    return type_key(k, d, function(t) S.send_dm(S.peer, t) end)
  end
  if (d == "left" or d == "right") and #S.channels > 1 then
    S.chan_sel = (S.chan_sel - 1 + (d == "left" and -1 or 1)) % #S.channels + 1
    scroll = 0
    return true
  end
  return type_key(k, d, function(t)
    S.send_channel(S.chan_sel, mt.BROADCAST, { portnum = mt.PORT.TEXT, payload = t })
    add(S.chat_lines(S.chan_sel), chat_file(S.chan_sel), "me: " .. t, "me")
  end)
end

function app.close()
  if tabmod and tabmod.close then tabmod.close() end
  tabmod = nil
  save_nodes()
  if lora then pcall(lora.stop) end
  if gps then pcall(gps.stop) end
  S.chat, S.dms, S.nodes, queue, waiting = {}, {}, {}, {}, {}
  unload("meshtastic")
  unload("protobuf")
end

return app
