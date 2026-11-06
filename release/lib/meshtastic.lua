-- Meshtastic wire protocol for the Mesh app: presets and frequencies, the
-- 16-byte packet header, channel (AES-CTR) and direct-message (X25519 +
-- AES-256-CCM) encryption, and the Data / User / Position / Routing messages.
-- See docs/MESHTASTIC.md for the facts and their sources. Numbers are 32-bit
-- on the device: node numbers above 2^31 are negative there, so they are
-- compared and printed through pb.hex32 and masked, never with < or >.
local pb = require("protobuf")
local M = {}

local M32 = 0xFFFFFFFF
M.BROADCAST = M32
M.PORT = { TEXT = 1, POSITION = 3, NODEINFO = 4, ROUTING = 5, TELEMETRY = 67, TRACEROUTE = 70 }
M.ROLE_CLIENT_MUTE = 1
M.HW_PRIVATE = 255
M.MAX_PAYLOAD = 233  -- Data.payload
M.PKI_OVERHEAD = 12

-- name hashed for the frequency and channel hash, bandwidth kHz, SF, CR
M.PRESETS = {
  { name = "LongFast", bw = 250, sf = 11, cr = 5 },
  { name = "MediumFast", bw = 250, sf = 9, cr = 5 },
  { name = "MediumSlow", bw = 250, sf = 10, cr = 5 },
  { name = "ShortFast", bw = 250, sf = 7, cr = 5 },
  { name = "ShortSlow", bw = 250, sf = 8, cr = 5 },
  { name = "LongSlow", bw = 125, sf = 12, cr = 8 },
  { name = "LongMod", bw = 125, sf = 11, cr = 8 },
}

M.DEFAULT_KEY = "\xd4\xf1\xbb\x3a\x20\x29\x07\x59\xf0\xbc\xff\xab\xcf\x4e\x69\x01"

-- ---------------------------------------------------------------- numbers
local function u32(v) return v & M32 end
M.u32 = u32

-- unsigned v % n for small n, also for the device's negative 32-bit values
local function umod(v, n) return ((v >> 1) % n * 2 + (v & 1)) % n end

function M.same(a, b) return a ~= nil and b ~= nil and u32(a) == u32(b) end
function M.id_text(n) return "!" .. pb.hex32(n) end
function M.last_byte(n) local b = n & 0xFF; return b ~= 0 and b or 0xFF end

-- ---------------------------------------------------------------- radio
function M.djb2(s)
  local h = 5381
  for i = 1, #s do h = u32(h * 33 + s:byte(i)) end
  return h
end

-- US 902-928 MHz. slot: 1-based channel_num, or nil to hash the name.
function M.freq_us(preset, name, slot)
  local bw = preset.bw / 1000
  local n = math.floor(26 / bw)
  local s0 = slot and (slot - 1) % n or umod(M.djb2(name or preset.name), n)
  return 902.0 + bw / 2 + s0 * bw, s0 + 1
end

-- ---------------------------------------------------------------- channels
-- psk bytes as stored in a channel: "" (no encryption), one byte 1-10 (the
-- default key variants), or a raw 16/32-byte key (shorter keys are padded).
function M.expand_psk(psk)
  if psk == nil or psk == "\1" then return M.DEFAULT_KEY end
  if #psk == 0 or psk == "\0" then return nil end
  if #psk == 1 then
    return M.DEFAULT_KEY:sub(1, 15) .. string.char((0x01 + psk:byte() - 1) & 0xFF)
  end
  if #psk < 16 then return psk .. string.rep("\0", 16 - #psk) end
  if #psk < 32 and #psk ~= 16 then return psk .. string.rep("\0", 32 - #psk) end
  return psk:sub(1, 32)
end

function M.channel_hash(name, key)
  local h = 0
  for i = 1, #name do h = h ~ name:byte(i) end
  for i = 1, #(key or "") do h = h ~ key:byte(i) end
  return h & 0xFF
end

-- ---------------------------------------------------------------- header
function M.pack(h, payload)
  local flags = (h.hop_limit & 7) | (h.want_ack and 0x08 or 0) | ((h.hop_start & 7) << 5)
  return string.pack("<I4I4I4BBBB", u32(h.to), u32(h.from), u32(h.id), flags, h.channel or 0,
    h.next_hop or 0, h.relay or 0) .. payload
end

function M.unpack(frame)
  if #frame < 16 then return nil end
  local to, from, id, flags, ch, nh, relay = string.unpack("<I4I4I4BBBB", frame)
  return { to = u32(to), from = u32(from), id = u32(id), hop_limit = flags & 7,
    want_ack = flags & 0x08 ~= 0, via_mqtt = flags & 0x10 ~= 0, hop_start = (flags >> 5) & 7,
    channel = ch, next_hop = nh, relay = relay }, frame:sub(17)
end

-- A non-zero packet id: random high bits, a running counter low.
local counter = nil
function M.new_id()
  local r = string.unpack("<I4", crypto.random(4))
  counter = ((counter or r) + 1) & 0x3FF
  local id = u32((r & ~0x3FF) | counter)
  if id == 0 then id = 1 end
  return id
end

-- ---------------------------------------------------------------- encryption
local function ctr_block(id, from) return string.pack("<I4I4I4I4", u32(id), 0, u32(from), 0) end

function M.channel_crypt(key, from, id, data)
  if not key then return data end
  return crypto.aes_ctr(key, ctr_block(id, from), data)
end

local function pki_nonce(id, from, extra) return string.pack("<I4", u32(id)) .. extra .. string.pack("<I4", u32(from)) .. "\0" end

-- key32 = sha256(x25519(my_priv, their_pub)); M.pki_key caches nothing.
function M.pki_key(priv, pub)
  local s = crypto.shared(priv, pub)
  return s and crypto.sha256(s)
end

function M.pki_encrypt(key, from, id, data)
  local extra = crypto.random(4)
  local ct, tag = crypto.ccm_encrypt(key, pki_nonce(id, from, extra), data)
  return ct .. tag .. extra
end

function M.pki_decrypt(key, from, id, payload)
  if #payload <= M.PKI_OVERHEAD then return nil end
  local n = #payload - M.PKI_OVERHEAD
  local ct, tag, extra = payload:sub(1, n), payload:sub(n + 1, n + 8), payload:sub(n + 9, n + 12)
  return crypto.ccm_decrypt(key, pki_nonce(id, from, extra), ct, tag)
end

-- ---------------------------------------------------------------- messages
function M.encode_data(d)
  return pb.encode({ { 1, "uint", d.portnum }, { 2, "bytes", d.payload or "" },
    { 3, "bool", d.want_response }, { 6, "fixed32", d.request_id }, { 7, "fixed32", d.reply_id },
    { 8, "fixed32", d.emoji }, { 9, "uint", (d.want_response and 2 or 0) } })
end

-- nil when it isn't a Data message (the wrong key decrypts to garbage)
function M.decode_data(s)
  local t = pb.decode(s)
  if not t or not t[1] or t[1] == 0 or (t[2] ~= nil and type(t[2]) ~= "string") then return nil end
  return { portnum = t[1], payload = t[2] or "", want_response = (t[3] or 0) ~= 0,
    request_id = t[6], reply_id = t[7], emoji = t[8], bitfield = t[9] }
end

function M.encode_user(u)
  return pb.encode({ { 1, "bytes", u.id }, { 2, "bytes", u.long_name }, { 3, "bytes", u.short_name },
    { 5, "uint", u.hw_model }, { 7, "uint", u.role }, { 8, "bytes", u.public_key } })
end

function M.decode_user(s)
  local t = pb.decode(s)
  if not t then return nil end
  local key = t[8]
  return { id = t[1], long_name = t[2], short_name = t[3], hw_model = t[5], role = t[7],
    public_key = (type(key) == "string" and #key == 32) and key or nil }
end

-- lat/lon in degrees (floats), alt in metres; precision bits as the channel's
function M.encode_position(p)
  local function trunc(v, bits)
    local i = math.floor(v * 1e7 + 0.5)
    if not bits or bits >= 32 then return i end
    return (i & (M32 << (32 - bits))) + (1 << (31 - bits))
  end
  return pb.encode({ { 1, "sfixed32", trunc(p.lat, p.precision) }, { 2, "sfixed32", trunc(p.lon, p.precision) },
    { 3, "int", p.alt and math.floor(p.alt + 0.5) }, { 4, "fixed32", p.time },
    { 5, "uint", p.source or 3 }, { 23, "uint", p.precision } })
end

function M.decode_position(s)
  local t = pb.decode(s)
  if not t or not t[1] or not t[2] then return nil end
  return { lat = pb.s32(t[1]) * 1e-7, lon = pb.s32(t[2]) * 1e-7, alt = t[3] and pb.s32(t[3]),
    time = t[4], precision = t[23] }
end

-- Telemetry: time 1, device_metrics 2 { battery_level 1, voltage 2 (float),
-- channel_utilization 3, air_util_tx 4, uptime_seconds 5 }, environment_metrics
-- 3 { temperature 1, relative_humidity 2, barometric_pressure 3 } (floats).
function M.decode_telemetry(s)
  local t = pb.decode(s)
  if not t then return nil end
  local out = {}
  local dm = t[2] and pb.decode(t[2])
  if dm then
    out.battery, out.voltage, out.uptime = dm[1], pb.float(dm[2]), dm[5]
    out.util = pb.float(dm[3])
  end
  local em = t[3] and pb.decode(t[3])
  if em then out.temp, out.humidity, out.pressure = pb.float(em[1]), pb.float(em[2]), pb.float(em[3]) end
  return out
end

-- RouteDiscovery: route 1 (node numbers towards the target), snr_towards 2
-- (dB x4), route_back 3, snr_back 4; all packed.
function M.decode_route(s)
  local t = pb.decode(s)
  if not t then return nil end
  local function snrs(f)
    local l = pb.packed(f)
    for i, v in ipairs(l) do l[i] = pb.s32(v) / 4 end
    return l
  end
  return { route = pb.packed(t[1], "fixed32"), snr_towards = snrs(t[2]),
    route_back = pb.packed(t[3], "fixed32"), snr_back = snrs(t[4]) }
end

M.ACK_PAYLOAD = "\x18\x00"  -- Routing { error_reason = NONE }

function M.decode_routing(s)
  local t = pb.decode(s)
  if not t then return nil end
  return { error = t[3] or 0 }
end

-- ---------------------------------------------------------------- duplicates
-- Remembers (from, id) of the last n packets, ours included.
function M.history(n)
  local seen, ring, at = {}, {}, 0
  local h = {}
  function h.check(from, id)  -- true if new (and records it)
    local k = string.pack("<I4I4", from & M32, id & M32)
    if seen[k] then return false end
    at = at % n + 1
    if ring[at] then seen[ring[at]] = nil end
    ring[at], seen[k] = k, true
    return true
  end
  return h
end

return M
