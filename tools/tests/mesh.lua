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

say(string.format("%d failure(s)", fails))
os.exit(fails == 0 and 0 or 1)
