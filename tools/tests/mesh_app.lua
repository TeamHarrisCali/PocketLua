-- Headless tests for the Mesh app (fake crypto: real crypto is in mesh.lua).
-- Run from the project root:  lua5.4 tools/tests/mesh_app.lua
local say = print
local src = assert(io.open("tools/host_test.lua")):read("a")
assert(load(src:match("^(.-)%-%- %-+ helpers"), "=stubs"))()
dofile("tools/emu/boot.lua")
local fails = 0
local function check(c, m) if c then say("ok:   " .. m) else fails = fails + 1; say("FAIL: " .. m) end end
local function frames(n) for _ = 1, n or 3 do on_frame(0.033); on_draw(); on_draw(); on_draw() end end
local function key(name, mods)
  local k = { key = name }
  if #name == 1 then k.text = name end
  for m in pairs(mods or {}) do k[m] = true end
  on_key(k); frames(1)
end
local function type_text(s) for c in s:gmatch(".") do key(c) end end
local function secs(s) frames(math.ceil(s / 0.033)) end

-- record the text drawn in the last frame
local screen = {}
local text0 = gfx.text
gfx.text = function(x, y, s, c, size) screen[#screen + 1] = tostring(s); return text0(x, y, s, c, size) end
local function shows(pat)
  screen = {}
  frames(1)
  for _, s in ipairs(screen) do if s:find(pat) then return s end end
end
local tones = {}
snd.tone = function(f) tones[#tones + 1] = f end

local function calls(name)
  local out = {}
  for _, c in ipairs(hw_calls) do if c[1] == name then out[#out + 1] = c end end
  return out
end
local function sent(pat)
  for _, c in ipairs(calls("lora_send")) do if tostring(c[2]):find(pat) then return c[2] end end
end

frames(3)

local mt = require("meshtastic")
local pb = require("protobuf")
local queue = {}
lora.recv = function() return table.remove(queue, 1) end
lora.busy = function() return false end
-- host_test's crypto passes data through, so a frame's payload is its Data
local function hear(from, data, opts)
  opts = opts or {}
  local h = { to = opts.to or mt.BROADCAST, from = from, id = mt.new_id(), hop_limit = 3 - (opts.hops or 0),
    hop_start = 3, channel = opts.ch or 0x08 }
  queue[#queue + 1] = { data = mt.pack(h, mt.encode_data(data)), rssi = -80, snr = 5.5 }
  frames(2)
end
local function sent()
  local out = {}
  for _, c in ipairs(calls("lora_send")) do
    local h, p = mt.unpack(c[2])
    out[#out + 1] = { h = h, payload = p }
  end
  return out
end

local ALICE = 0x11223344
hw_calls = {}
shell.launch("mesh"); frames(3)
check(shell.app() == "mesh", "mesh opens")
local b = calls("lora_begin")[1]
check(b and type(b[2]) == "table" and math.abs(b[2].freq - 906.875) < 1e-3 and b[2].sync == 0x2B and b[2].sf == 11,
  "radio starts on LongFast 906.875 MHz, sync 0x2B, SF11")
check(shows("LongFast 906.875"), "chat says which preset and frequency")

hear(ALICE, { portnum = mt.PORT.NODEINFO, payload = mt.encode_user({ id = "!11223344", long_name = "Alice Base",
  short_name = "ALB", public_key = string.rep("\9", 32) }) })
hear(ALICE, { portnum = mt.PORT.TEXT, payload = "hello mesh" })
check(shows("ALB: hello mesh"), "a public message shows with the sender's short name")
hear(0x55667788, { portnum = mt.PORT.TEXT, payload = "other channel" }, { ch = 0x3d })
check(not shows("other channel"), "a channel we don't have is ignored")

secs(6)
local info
for _, s in ipairs(sent()) do
  local d = mt.decode_data(s.payload)
  if d and d.portnum == mt.PORT.NODEINFO and mt.same(s.h.to, mt.BROADCAST) then info = mt.decode_user(d.payload) end
end
check(info and info.role == mt.ROLE_CLIENT_MUTE and info.hw_model == mt.HW_PRIVATE and info.public_key
  and #info.public_key == 32, "announces itself: NodeInfo with role, hardware and public key")

local t = pb.encode({ { 2, "bytes", pb.encode({ { 1, "uint", 87 }, { 5, "uint", 7200 } }) } })
hear(ALICE, { portnum = mt.PORT.TELEMETRY, payload = t }, { hops = 1 })
key("tab"); frames(2)
check(shows("ALB"), "Nodes lists Alice")
key("enter"); frames(2)
check(shows("Battery 87%%"), "node page shows battery from telemetry")
check(shows("1 hop"), "node page shows hops")
hw_calls = {}
key("t"); secs(1)
local tr
for _, s in ipairs(sent()) do
  local d = mt.decode_data(s.payload)
  if d and d.portnum == mt.PORT.TRACEROUTE then tr = { s = s, d = d } end
end
check(tr and mt.same(tr.s.h.to, ALICE) and tr.d.want_response, "T sends a traceroute to the node")
local reply = pb.encode({ { 1, "bytes", string.pack("<I4", 0x99887766) } })
local ME = tonumber(info.id:sub(2), 16)
hear(ALICE, { portnum = mt.PORT.TRACEROUTE, payload = reply, request_id = tr and tr.s.h.id }, { to = ME })
secs(1.2)
check(shows("Route: me > !7766 > ALB"), "the traceroute reply shows the route")

key("enter"); frames(2)
hw_calls = {}
type_text("hi alice"); key("enter"); secs(1)
local dm
for _, s in ipairs(sent()) do if mt.same(s.h.to, ALICE) and s.h.channel == 0 then dm = s end end
check(dm and dm.h.want_ack and #dm.payload == #mt.encode_data({ portnum = 1, payload = "hi alice" }) + 12,
  "a DM goes out PKI-encrypted (channel 0, want_ack, tag + nonce)")
check(shows("hi alice"), "the DM shows in the conversation")

key("tab"); frames(2)
check(shows("Channel 1") and shows("public"), "Setup lists the public channel")

shell.launch("calc"); frames(3)
shell.launch("mesh"); frames(3)
check(shows("ALB: hello mesh"), "chat history is back after reopening")
shell.launch("calc"); frames(3)

say(string.format("%d failure(s)", fails))
os.exit(fails == 0 and 0 or 1)
