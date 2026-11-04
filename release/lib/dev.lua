-- Networked devices: use another LiveOS device's hardware as if it were yours.
--   local d = dev.mount("kitchen")      -- a nearby device, by name
--   d.snd.tone(880, 300)                -- plays a tone on that device
--   d.imu.read(function(r, err) ... end) -- results arrive in a callback
-- Devices find each other with beacons; calls travel as encrypted ESP-NOW
-- packets, so both devices need the same network key (Settings > Devices).
-- Only the functions listed in dev.exports can be called remotely. Add your
-- own with dev.export("name", fn).
local dev = {}
_G.dev = dev

local PEER_TTL = 12000   -- ms without a beacon before a device drops off
local CALL_TIMEOUT = 2500
local BEACON_EVERY = 3000

dev.name = cfg.get("dev_name") or ("liveos-" .. net.mac():sub(-4))
dev.peers_by_mac = {}
dev.exports = {}

local running = false
local pending, next_id, last_beacon = {}, 1, -BEACON_EVERY
local my_mac = ""

-- ---------------------------------------------------------------- serialization
local function ser(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    return tostring(v)
  end
  if t == "string" then return string.format("%q", v) end
  if t == "table" and depth < 4 then
    local parts = {}
    for k, val in pairs(v) do parts[#parts + 1] = "[" .. ser(k, depth + 1) .. "]=" .. ser(val, depth + 1) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

-- Packets are authenticated by the shared key, and the empty environment keeps
-- the data inert anyway: only literals can be evaluated.
local function deser(s)
  local fn = load("return " .. s, "=net", "t", {})
  if not fn then return nil end
  local ok, v = pcall(fn)
  if ok then return v end
end

dev.serialize, dev.deserialize = ser, deser

-- ---------------------------------------------------------------- exports
function dev.export(name, fn) dev.exports[name] = fn end

dev.export("sys.ping", function() return sys.millis() end)
dev.export("sys.battery", function() local p, c = sys.battery(); return { pct = p, charging = c } end)
dev.export("sys.heap", function() local f, l = sys.heap(); return { free = f, lua = l } end)
dev.export("imu.read", function() return imu.read() end)
dev.export("snd.tone", function(f, ms) snd.tone(tonumber(f) or 440, math.min(tonumber(ms) or 200, 2000)) end)
dev.export("snd.stop", function() snd.stop() end)
dev.export("shell.toast", function(msg) shell.toast("> " .. tostring(msg):sub(1, 60), 4) end)
dev.export("clock.now", function() return clock.now() end)

-- ---------------------------------------------------------------- peers
local function clean(s) return (tostring(s):gsub("[^%w%s%-_%.]", ""):sub(1, 16)) end

function dev.peers()
  local out, now = {}, sys.millis()
  for mac, p in pairs(dev.peers_by_mac) do
    if now - p.seen > PEER_TTL then dev.peers_by_mac[mac] = nil
    else out[#out + 1] = { name = p.name, mac = mac, rssi = p.rssi, age = (now - p.seen) // 1000 } end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function resolve(target)
  for _, p in ipairs(dev.peers()) do
    if p.name == target or p.mac == target then return p end
  end
end

-- ---------------------------------------------------------------- calling
-- cb(result, err) is called when the answer arrives or the call times out.
function dev.call(target, op, args, cb)
  local peer = resolve(target)
  if not peer then
    if cb then cb(nil, "no such device: " .. tostring(target)) end
    return
  end
  local id = next_id
  next_id = next_id % 9999 + 1
  local pkt = "Q" .. id .. "|" .. op .. "|" .. ser(args or {})
  if not net.send(peer.mac, pkt) then
    if cb then cb(nil, "send failed") end
    return
  end
  pending[id] = { cb = cb, deadline = sys.millis() + CALL_TIMEOUT }
end

-- d = dev.mount("name"); d.imu.read(cb); d.snd.tone(880, 200)
function dev.mount(target)
  return setmetatable({}, { __index = function(_, ns)
    return setmetatable({}, { __index = function(_, fn)
      return function(...)
        local args = table.pack(...)
        local cb
        if type(args[args.n]) == "function" then
          cb = args[args.n]
          args[args.n] = nil
          args.n = args.n - 1
        end
        dev.call(target, ns .. "." .. fn, { table.unpack(args, 1, args.n) }, cb)
      end
    end })
  end })
end

-- ---------------------------------------------------------------- receiving
local function reply(mac, text)
  if #text > 240 then text = "X" .. text:match("^.(%d+)") .. "|result too large" end
  net.send(mac, text)
end

local function on_request(p)
  local id, op, rest = p.data:match("^Q(%d+)|([%w_%.]+)|(.*)$")
  if not id then return end
  local fn = dev.exports[op]
  if not fn then reply(p.from, "X" .. id .. "|not exported: " .. op); return end
  local args = deser(rest)
  if type(args) ~= "table" then args = {} end
  local ok, res = pcall(fn, table.unpack(args))
  if ok then reply(p.from, "R" .. id .. "|" .. ser(res))
  else reply(p.from, "X" .. id .. "|" .. tostring(res):sub(1, 100)) end
end

local function on_response(p)
  local kind, id, body = p.data:match("^([RX])(%d+)|(.*)$")
  local req = id and pending[tonumber(id)]
  if not req then return end
  pending[tonumber(id)] = nil
  if not req.cb then return end
  local ok, err
  if kind == "R" then ok, err = pcall(req.cb, deser(body), nil)
  else ok, err = pcall(req.cb, nil, body) end
  if not ok then sys.log("dev callback: " .. tostring(err)) end
end

local function handle(p)
  local kind = p.data:sub(1, 1)
  if kind == "B" then
    local mac = p.from
    if mac == my_mac then return end
    local known = dev.peers_by_mac[mac]
    dev.peers_by_mac[mac] = { name = clean(p.data:sub(2)), rssi = p.rssi, seen = sys.millis() }
    if not known then net.add_peer(mac) end
  elseif not p.bcast then
    if kind == "Q" then on_request(p)
    elseif kind == "R" or kind == "X" then on_response(p) end
  end
end

-- Call every frame.
function dev.poll()
  if not running then return end
  local now = sys.millis()
  if now - last_beacon >= BEACON_EVERY then
    last_beacon = now
    net.broadcast("B" .. dev.name)
  end
  for _ = 1, 8 do
    local p = net.recv()
    if not p then break end
    handle(p)
  end
  for id, req in pairs(pending) do
    if now > req.deadline then
      pending[id] = nil
      if req.cb then pcall(req.cb, nil, "timeout") end
    end
  end
end

-- ---------------------------------------------------------------- lifecycle
function dev.start()
  local key = cfg.get("dev_key")
  if not key or key == "" then return false, "set a network key first" end
  if not net.start(key) then return false, "radio failed to start" end
  my_mac = net.mac()
  dev.name = clean(cfg.get("dev_name") or ("liveos-" .. my_mac:sub(-4)))
  running = true
  last_beacon = -BEACON_EVERY
  return true
end

function dev.stop()
  running = false
  net.stop()
  dev.peers_by_mac, pending = {}, {}
end

function dev.running() return running end

return dev
