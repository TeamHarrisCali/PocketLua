-- Minimal protobuf wire format for the Mesh app: varints (uint32, enum, bool,
-- int32), fixed32 / sfixed32 and length-delimited fields (bytes, strings,
-- nested messages). Integers are 32-bit on the device (LUA_32BITS) and 64-bit
-- on the PC; every value is kept to its low 32 bits, so a node number above
-- 2^31 is negative on the device and positive on the PC, and both encode the
-- same bytes.
local pb = {}

local M32 = 0xFFFFFFFF  -- wraps to -1 on the device: masking is then a no-op
local char, byte = string.char, string.byte

-- ---------------------------------------------------------------- encoding
local function varint(out, v)
  v = v & M32
  while (v & ~0x7F) ~= 0 do
    out[#out + 1] = char((v & 0x7F) | 0x80)
    v = v >> 7  -- logical shift: works for the device's negative values too
  end
  out[#out + 1] = char(v)
end

-- A negative int32 goes out as its 64-bit sign extension: ten bytes.
local function varint_neg(out, v)
  for _ = 1, 4 do
    out[#out + 1] = char((v & 0x7F) | 0x80)
    v = v >> 7
  end
  out[#out + 1] = char(((v & 0x0F) | 0x70) | 0x80)
  for _ = 1, 4 do out[#out + 1] = "\xFF" end
  out[#out + 1] = "\x01"
end

local function key(out, num, wire) varint(out, (num << 3) | wire) end

-- fields: a list of { num, type, value }; nil values are skipped. Types:
-- "uint" (uint32 / enum), "bool", "int" (int32), "fixed32", "sfixed32",
-- "bytes" (strings and nested messages, already encoded).
function pb.encode(fields)
  local out = {}
  for _, f in ipairs(fields) do
    local num, t, v = f[1], f[2], f[3]
    if v ~= nil then
      if t == "uint" then key(out, num, 0); varint(out, v)
      elseif t == "bool" then
        if v then key(out, num, 0); out[#out + 1] = "\x01" end  -- false is the default: not sent
      elseif t == "int" then
        key(out, num, 0)
        if v < 0 then varint_neg(out, v) else varint(out, v) end
      elseif t == "fixed32" or t == "sfixed32" then
        key(out, num, 5); out[#out + 1] = string.pack("<I4", v & M32)
      elseif t == "bytes" then
        key(out, num, 2); varint(out, #v); out[#out + 1] = v
      else
        error("protobuf: unknown type " .. tostring(t))
      end
    end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------- decoding
-- Returns a table: field number -> value (varints and fixed32 as their low
-- 32 bits, length-delimited fields as strings). A repeated field keeps its
-- last value. Returns nil for malformed input.
function pb.decode(s)
  if type(s) ~= "string" then return nil end
  local t, i, n = {}, 1, #s
  local function rv()
    local v, shift = 0, 0
    while true do
      if i > n or shift > 63 then return nil end
      local b = byte(s, i)
      i = i + 1
      if shift < 32 then v = v | ((b & 0x7F) << shift) end
      if b < 0x80 then return v & M32 end
      shift = shift + 7
    end
  end
  while i <= n do
    local k = rv()
    if not k then return nil end
    local num, wire = k >> 3, k & 7
    if num == 0 then return nil end
    if wire == 0 then
      local v = rv()
      if not v then return nil end
      t[num] = v
    elseif wire == 5 then
      if i + 3 > n then return nil end
      t[num] = string.unpack("<I4", s, i) & M32
      i = i + 4
    elseif wire == 1 then  -- 64-bit: kept as its low 32 bits
      if i + 7 > n then return nil end
      t[num] = string.unpack("<I4", s, i) & M32
      i = i + 8
    elseif wire == 2 then
      local len = rv()
      if not len or len < 0 or i + len - 1 > n then return nil end
      t[num] = s:sub(i, i + len - 1)
      i = i + len
    else
      return nil  -- groups (3, 4) are not used by Meshtastic
    end
  end
  return t
end

-- ---------------------------------------------------------------- values
-- A decoded 32-bit value read as signed (int32, sfixed32).
function pb.s32(v)
  if v == nil then return nil end
  v = v & M32
  if v > 0x7FFFFFFF then v = v - 0x100000000 end  -- PC only: on the device it is signed already
  return v
end

-- A 32-bit value as 8 hex digits, the way Meshtastic writes node ids.
function pb.hex32(v) return string.format("%08x", v & M32) end

return pb
