-- Headless tests for the Mesh app's protocol libraries.
-- Run from the project root:  lua5.4 tools/tests/mesh.lua
local say = print
local fails = 0
local function check(c, m) if c then say("ok:   " .. m) else fails = fails + 1; say("FAIL: " .. m) end end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- ---------------------------------------------------------------- protobuf
local pb = dofile("userland/lib/protobuf.lua")

check(hex(pb.encode({ { 1, "uint", 150 } })) == "089601", "varint 150 (the protobuf docs' example)")
check(hex(pb.encode({ { 2, "bytes", "testing" } })) == "120774657374696e67", "length-delimited string")
check(hex(pb.encode({ { 1, "int", -1 } })) == "08ffffffffffffffffff01", "negative int32 is ten bytes")
check(hex(pb.encode({ { 1, "int", -2 } })) == "08feffffffffffffffff01", "int32 -2")
check(hex(pb.encode({ { 1, "uint", 0xFFFFFFFF } })) == "08ffffffff0f", "uint32 max is five bytes")
check(hex(pb.encode({ { 1, "fixed32", 0xDEADBEEF } })) == "0defbeadde", "fixed32 little-endian")
check(hex(pb.encode({ { 1, "sfixed32", -1 } })) == "0dffffffff", "sfixed32 -1")
check(pb.encode({ { 1, "bool", false }, { 2, "uint", nil } }) == "", "false bools and nils are not sent")

local t = pb.decode(pb.encode({ { 1, "uint", 3 }, { 2, "bytes", "hi" }, { 3, "int", -100 },
  { 4, "sfixed32", -374000000 }, { 5, "fixed32", 0x9ABCDEF0 } }))
check(t and t[1] == 3 and t[2] == "hi", "round trip: varint and bytes")
check(t and pb.s32(t[3]) == -100, "round trip: negative int32")
check(t and pb.s32(t[4]) == -374000000, "round trip: sfixed32 longitude")
check(t and pb.hex32(t[5]) == "9abcdef0", "round trip: node number above 2^31")

check(pb.decode("\x08") == nil, "truncated varint is rejected")
check(pb.decode("\x12\x05ab") == nil, "length past the end is rejected")
check(pb.decode("\x0b") == nil, "group wire type is rejected")
check(pb.decode("") and next(pb.decode("")) == nil, "empty message decodes to no fields")

-- ---------------------------------------------------------------- meshtastic
-- crypto comes from tools/meshcrypto_host.cpp: the device's src/meshcrypto.cpp
-- and BearSSL built for the PC (once, into .pio/host)
if not io then
  -- The 32-bit runner (lib/lua built like the device, no io): the parts that
  -- depend on the integer size, without crypto.
  require = function(n) return dofile("userland/lib/" .. n .. ".lua") end
  local mt = require("meshtastic")
  check(pb.hex32(mt.djb2("LongFast")) == "07c63403", "32-bit: djb2 of LongFast")
  check(select(2, mt.freq_us(mt.PRESETS[1])) == 20, "32-bit: LongFast slot 20")
  check(math.abs(mt.freq_us(mt.PRESETS[7]) - 902.6875) < 1e-3, "32-bit: LongModerate frequency")
  local hdr = { to = 0xFFFFFFFF, from = 0xa1b2c3d4, id = 0x9abcdef0, hop_limit = 3, hop_start = 3, channel = 8 }
  local back = mt.unpack(mt.pack(hdr, "x"))
  check(mt.same(back.from, 0xa1b2c3d4) and mt.same(back.to, mt.BROADCAST) and mt.id_text(back.id) == "!9abcdef0",
    "32-bit: node numbers above 2^31 survive the header")
  check(mt.last_byte(0xa1b2c300) == 0xFF and mt.last_byte(0xa1b2c3d4) == 0xd4, "32-bit: last byte rule")
  say(string.format("%d failure(s)", fails))
  os.exit(fails == 0 and 0 or 1)
end
local HOST = ".pio/host/meshcrypto_host"
if not io.open(HOST) then
  assert(os.execute([[sh -c 'P=$PWD; mkdir -p .pio/host/obj && cd .pio/host/obj &&
    gcc -O2 -w -c -I$P/lib/bearssl/src $(ls $P/lib/bearssl/src/*.c | grep -v -E "x86ni|pwr8") && cd $P &&
    g++ -O2 -w -Ilib/bearssl/src -o .pio/host/meshcrypto_host tools/meshcrypto_host.cpp src/meshcrypto.cpp .pio/host/obj/*.o']]),
    "could not build " .. HOST)
end
local function unhex(s) return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)) end
local function host(...)
  local args = {}
  for i, a in ipairs({ ... }) do args[i] = "'" .. a .. "'" end
  local p = io.popen(HOST .. " " .. table.concat(args, " "))
  local out = p:read("l")
  p:close()
  return out
end
local rnd = 0
crypto = {
  aes_ctr = function(k, iv, d) return unhex(host("ctr", hex(k), hex(iv), hex(d))) end,
  ccm_encrypt = function(k, n, d)
    local out = unhex(host("ccm-enc", hex(k), hex(n), hex(d)))
    return out:sub(1, -9), out:sub(-8)
  end,
  ccm_decrypt = function(k, n, d, tag)
    local out = host("ccm-dec", hex(k), hex(n), hex(d), hex(tag))
    if out == "FAIL" then return nil end
    return unhex(out)
  end,
  public = function(priv) return unhex(host("pub", hex(priv))) end,
  shared = function(priv, pub)
    local out = host("shared", hex(priv), hex(pub))
    return out ~= "FAIL" and unhex(out) or nil
  end,
  sha256 = function(d) return unhex(host("sha256", hex(d))) end,
  random = function(n) rnd = rnd + 1; return string.rep(string.char(rnd & 0xFF), n) end,
}
check(host("selftest"):find("^ok") ~= nil, "crypto vectors on the PC build (meshcrypto_host selftest)")

package.path = "userland/lib/?.lua;" .. package.path
local mt = require("meshtastic")

check(mt.djb2("LongFast") == 0x07C63403, "djb2 of LongFast")
local f, slot = mt.freq_us(mt.PRESETS[1])
check(math.abs(f - 906.875) < 1e-6 and slot == 20, "US LongFast is 906.875 MHz, slot 20")
check(math.abs(mt.freq_us(mt.PRESETS[2]) - 913.125) < 1e-6, "US MediumFast is 913.125 MHz")
check(math.abs(mt.freq_us(mt.PRESETS[7]) - 902.6875) < 1e-6, "US LongModerate hashes \"LongMod\"")
check(math.abs(mt.freq_us(mt.PRESETS[1], nil, 1) - 902.125) < 1e-6, "channel_num 1 is the first slot")
check(mt.channel_hash("LongFast", mt.DEFAULT_KEY) == 0x08, "LongFast channel hash 0x08")
check(mt.channel_hash("MediumFast", mt.DEFAULT_KEY) == 0x1F, "MediumFast channel hash 0x1F")
check(mt.expand_psk("\2"):byte(16) == 0x02 and mt.expand_psk("\1") == mt.DEFAULT_KEY, "PSK index 2 ends in 0x02")
check(mt.expand_psk("") == nil and #mt.expand_psk("abc") == 16 and #mt.expand_psk(string.rep("k", 20)) == 32,
  "PSK: none, padded to 16, padded to 32")

-- the firmware's PKI test packet, end to end
local frame = unhex("8c646d7a2909000062d6b2136b00000040df24abfcc30a17a3d9046726099e796a1c036a792b")
local h, payload = mt.unpack(frame)
check(h and h.to == 0x7a6d648c and h.from == 0x929 and h.id == 0x13b2d662, "header: to, from, id")
check(h and h.hop_limit == 3 and h.hop_start == 3 and h.want_ack and h.channel == 0, "header: flags 0x6b, channel 0")
check(mt.pack(h, payload) == frame, "header packs back to the same bytes")
local priv = unhex("a00330633e63522f8a4d81ec6d9d1e6617f6c8ffd3a4c698229537d44e522277")
local pub = unhex("db18fc50eea47f00251cb784819a3cf5fc361882597f589f0d7ff820e8064457")
local key = mt.pki_key(priv, pub)
check(key and hex(key):sub(1, 16) == "777b1545c9d6f9a2", "PKI key")
local plain = key and mt.pki_decrypt(key, h.from, h.id, payload)
local d = plain and mt.decode_data(plain)
check(d and d.portnum == mt.PORT.TEXT and d.payload == "test", "PKI direct message decrypts to \"test\"")
check(mt.encode_data({ portnum = 1, payload = "test" }) == unhex("08011204746573744800"),
  "Data encodes as the firmware's (bitfield always sent)")
local wrapped = mt.pki_encrypt(key, 0x929, 0x13b2d662, "hello mesh")
check(#wrapped == 10 + 12 and mt.pki_decrypt(key, 0x929, 0x13b2d662, wrapped) == "hello mesh", "PKI round trip")
check(mt.pki_decrypt(key, 0x92a, 0x13b2d662, wrapped) == nil, "PKI from the wrong node fails the tag")

-- channel encryption with the default key
local ct = mt.channel_crypt(mt.DEFAULT_KEY, 0x929, 0x13b2d662, unhex("08011204746573744800"))
check(hex(ct) == "46f2ecd0b02ac4cf2be5", "default-key channel packet")
check(mt.channel_crypt(mt.DEFAULT_KEY, 0x929, 0x13b2d662, ct) == unhex("08011204746573744800"), "and back")
check(mt.decode_data(mt.channel_crypt(mt.expand_psk("\2"), 0x929, 0x13b2d662, ct)) == nil,
  "the wrong key doesn't decode as Data")

-- messages
local u = mt.decode_user(mt.encode_user({ id = "!a1b2c3d4", long_name = "Cardputer", short_name = "CP",
  hw_model = mt.HW_PRIVATE, role = mt.ROLE_CLIENT_MUTE, public_key = pub }))
check(u and u.long_name == "Cardputer" and u.short_name == "CP" and u.role == 1 and u.hw_model == 255
  and u.public_key == pub, "User round trip")
local p = mt.decode_position(mt.encode_position({ lat = 37.7749295, lon = -122.4194155, alt = -12, time = 1790000000 }))
check(p and math.abs(p.lat - 37.7749295) < 1e-6 and math.abs(p.lon + 122.4194155) < 1e-6 and p.alt == -12,
  "Position round trip (negative longitude and altitude)")
local pc = mt.decode_position(mt.encode_position({ lat = 37.7749295, lon = -122.4194155, precision = 13 }))
check(pc and pc.precision == 13 and math.abs(pc.lon + 122.4194155) < 0.03 and math.abs(pc.lon + 122.4194155) > 1e-3,
  "Position at 13 bits is blurred to a ~5 km cell")
check(mt.decode_routing(mt.ACK_PAYLOAD).error == 0, "ACK is Routing error NONE")
local f32 = function(x) return string.unpack("<I4", string.pack("<f", x)) end
local tel = mt.decode_telemetry(pb.encode({ { 1, "fixed32", 1790000000 }, { 2, "bytes", pb.encode({
  { 1, "uint", 87 }, { 2, "fixed32", f32(4.05) }, { 3, "fixed32", f32(12.5) }, { 5, "uint", 3600 } }) } }))
check(tel and tel.battery == 87 and math.abs(tel.voltage - 4.05) < 1e-4 and tel.uptime == 3600
  and math.abs(tel.util - 12.5) < 1e-4, "Telemetry: battery, voltage, utilisation, uptime")
local env = mt.decode_telemetry(pb.encode({ { 3, "bytes", pb.encode({ { 1, "fixed32", f32(21.5) } }) } }))
check(env and math.abs(env.temp - 21.5) < 1e-4 and env.battery == nil, "Telemetry: environment temperature")
local snr = pb.encode({ { 1, "int", -24 } }):sub(2) .. pb.encode({ { 1, "int", 40 } }):sub(2)
local rt = mt.decode_route(pb.encode({ { 1, "bytes", string.pack("<I4I4", 0x11, 0xa1b2c3d4) }, { 2, "bytes", snr },
  { 3, "bytes", string.pack("<I4", 0x22) } }))
check(rt and #rt.route == 2 and pb.hex32(rt.route[2]) == "a1b2c3d4" and rt.route_back[1] == 0x22,
  "RouteDiscovery: packed node numbers")
check(rt and rt.snr_towards[1] == -6 and rt.snr_towards[2] == 10, "RouteDiscovery: packed SNR (x4, negative)")
local hist = mt.history(3)
check(hist.check(1, 5) and not hist.check(1, 5) and hist.check(2, 5), "history: duplicates by (from, id)")
hist.check(3, 1); hist.check(4, 1)
check(hist.check(1, 5), "history forgets the oldest")
check(mt.id_text(0xa1b2c3d4) == "!a1b2c3d4" and mt.last_byte(0x1200) == 0xFF, "id text, last byte rule")
local id1, id2 = mt.new_id(), mt.new_id()
check(id1 ~= 0 and id2 ~= id1, "packet ids are non-zero and change")

say(string.format("%d failure(s)", fails))
os.exit(fails == 0 and 0 or 1)
