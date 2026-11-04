-- App runtime: runs in each app's Lua VM before the app itself. The OS is
-- native code; this only provides require/modules, print, lazily created
-- hardware tables, and the serializer behind app.save().
collectgarbage("incremental", 100, 400)

-- Hardware driver tables are created on first use.
local HW = { audio = true, ir = true, i2c = true, http = true, lora = true, gps = true, disp = true,
  musiclib = true }
setmetatable(_G, { __index = function(t, k)
  if HW[k] then
    local lib = sys.hwlib(k)
    rawset(t, k, lib)
    return lib
  end
end })

-- Libraries in lib/. Built-in copies load without debug info; an edited copy
-- that fails to load falls back to the built-in one.
local loaded, sizes = {}, {}
local strip = cfg.get("debug_sys") ~= "1"
function require(name)
  if loaded[name] then return loaded[name] end
  local path = "lib/" .. name .. ".lua"
  if not sys.exists(path) then error("module not found: " .. name, 2) end
  local stored = sys.in_storage(path) and not sys.safe_mode
  collectgarbage("collect")
  local before = collectgarbage("count")
  local fn, err = sys.loadfile(path, false, strip and not stored)
  if not fn and stored then
    fn = sys.loadfile(path, true, strip)
    if fn then shell.toast(path .. " has an error - using the built-in copy", 3) end
  end
  if not fn then error(err or ("cannot load " .. path), 2) end
  local mod = fn(name)
  if mod == nil then mod = true end
  loaded[name] = mod
  collectgarbage("collect")
  sizes[name] = math.max(0, collectgarbage("count") - before)
  return mod
end

function unload(name) loaded[name], sizes[name] = nil, nil end

function modules()
  local out = {}
  for name in pairs(loaded) do out[#out + 1] = { name = name, kb = sizes[name] or 0 } end
  table.sort(out, function(a, b) return a.kb > b.kb end)
  return out
end

function print(...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
  shell.log_line(table.concat(t, "\t"))
end

-- app.save() tables are kept as text while the app is closed.
local function ser(v, depth)
  local t = type(v)
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "table" and depth < 6 then
    local parts = {}
    for k, val in pairs(v) do parts[#parts + 1] = "[" .. ser(k, depth + 1) .. "]=" .. ser(val, depth + 1) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end
function __ser(v) return ser(v, 0) end
function __deser(s)
  local fn = load("return " .. s, "=saved", "t", {})
  if fn then
    local ok, v = pcall(fn)
    if ok then return v end
  end
end

-- Device sharing runs while an app that uses it is open (Nearby).
function shell.dev_restart()
  local d = rawget(_G, "dev")
  if cfg.get("dev_on") == "1" then
    d = d or require("dev")
    if d.running() then d.stop() end
    local ok, e = d.start()
    if not ok then shell.toast("Devices: " .. tostring(e), 3) end
  elseif d and d.running() then
    d.stop()
  end
end
