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
hw_calls = {}
hear(0x77778888, { portnum = mt.PORT.POSITION, payload = mt.encode_position({ lat = 37.7, lon = -122.4 }) })
secs(1)
local asked
for _, c in ipairs(calls("lora_send")) do
  local h2, p2 = mt.unpack(c[2])
  local d2 = mt.decode_data(p2)
  if d2 and d2.portnum == mt.PORT.NODEINFO and mt.same(h2.to, 0x77778888) and d2.want_response then asked = true end
end
check(asked, "a node heard without a key is sent our NodeInfo asking for theirs")

secs(6)
local info
for _, s in ipairs(sent()) do
  local d = mt.decode_data(s.payload)
  if d and d.portnum == mt.PORT.NODEINFO and mt.same(s.h.to, mt.BROADCAST) then info = mt.decode_user(d.payload) end
end
check(info and info.role == mt.ROLE_CLIENT_MUTE and info.hw_model == mt.HW_PRIVATE and info.public_key
  and #info.public_key == 32, "announces itself: NodeInfo with role, hardware and public key")

hear(ALICE, { portnum = mt.PORT.POSITION, payload = mt.encode_position({ lat = 37.78, lon = -122.41 }) }, { hops = 1 })
key("tab"); frames(2)
check(shows("ALB"), "Nodes lists Alice")
key("enter"); frames(2)
check(shows("1.4km NE"), "node page shows distance and direction from their position")
check(not shows("Battery"), "no telemetry is kept")
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
type_text("ok "); key("e", { ctrl = true }); key("enter"); frames(1)
check(shows("> ok \xF0\x9F\x91\x8D"), "Ctrl+E adds an emoji to the message")
check(shows("^7/221$"), "the counter shows bytes used of a DM's 221 (an emoji is 4)")
key("backspace"); frames(1)
check(shows("^3/221$"), "backspace removes the whole emoji")
key("backspace"); key("backspace"); key("backspace"); frames(1)
check(not shows("ok$"), "no status text after the message")
local ticks = 0
local line0 = gfx.line
gfx.line = function(x1, y1, x2, y2, c, ...) if c == ui.col.good and x1 >= 227 then ticks = ticks + 1 end; return line0(x1, y1, x2, y2, c, ...) end
hear(ALICE, { portnum = mt.PORT.ROUTING, payload = mt.ACK_PAYLOAD, request_id = dm and dm.h.id }, { to = ME })
ticks = 0; frames(1)
check(ticks >= 3, "a delivery receipt draws the green double tick")
gfx.line = line0

key("esc"); frames(2)
check(shows("ALB") and shows("Contacts") == nil, "Esc in a conversation goes back to the contact list")
key("enter"); frames(2)
check(shows("hi alice"), "Enter on a contact reopens the conversation")
key("tab"); frames(2)
check(shows("Listen when closed"), "Setup has the background listener switch")
for _ = 1, 6 do key("down") end
frames(1)
check(shows("DMs from new people"), "Setup has the DM sound row")
check(shows("Channel 1") and shows("public"), "Setup lists the public channel")

shell.launch("calc"); frames(3)
shell.launch("mesh"); frames(3)
check(shows("ALB: hello mesh"), "chat history is back after reopening")
key("tab"); key("tab"); frames(2)
check(shows("hi alice"), "the DMs tab reopens the last conversation")
local ME2 = ME

-- quiet: M in the contact list silences a contact
key("esc"); frames(2)
local snd0, dings = shell.sound, 0
shell.sound = function(k, ...) if k == "notify" then dings = dings + 1 end return snd0(k, ...) end
local function dm_from(from, text)  -- PKI with the stand-in crypto: Data, tag, extra nonce
  local h = { to = ME2, from = from, id = mt.new_id(), hop_limit = 3, hop_start = 3, channel = 0 }
  queue[#queue + 1] = { data = mt.pack(h, mt.encode_data({ portnum = 1, payload = text }) .. string.rep("\0", 12)),
    rssi = -70, snr = 6 }
  frames(2)
end
key("m"); frames(2)
check(shows("quiet"), "M marks the contact quiet")
dings = 0
dm_from(ALICE, "psst")
check(dings == 0, "a quiet contact's DM makes no sound")
key("m"); frames(1)
dm_from(ALICE, "again")
check(dings == 1, "with sound back on it dings")
shell.sound = snd0

-- the background listener's inbox is filed when Mesh opens
shell.launch("calc"); frames(3)
local function hx(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local h = { to = ME2, from = 0x0badf00d, id = 0x1234, hop_limit = 3, hop_start = 3, channel = 0x08 }
sys.mkdirs("data/mesh")
sys.write_text("data/mesh/inbox.txt", "-90 4.5 " .. hx(mt.pack(h, mt.encode_data({ portnum = 1, payload = "while you were out" }))) .. "\n")
shell.launch("mesh"); frames(3)
check(sys.read_text("data/mesh/inbox.txt") == "", "the inbox is emptied when Mesh opens")
key("tab"); key("tab"); frames(2)
check(shows("!f00d"), "a DM kept while closed shows in the contact list")
shell.launch("calc"); frames(3)

say(string.format("%d failure(s)", fails))
os.exit(fails == 0 and 0 or 1)
