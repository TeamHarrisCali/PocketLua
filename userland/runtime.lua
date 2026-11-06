-- App runtime: runs in each app's Lua VM before the app itself. The OS is
-- native code; this only provides require/modules, print and the tables that
-- are created on first use.
collectgarbage("incremental", 100, 400)

-- Driver tables, the APIs few apps use and the standard libraries other than
-- string are created on first use, so an app only pays for what it touches.
local LAZY = { audio = true, ir = true, i2c = true, http = true, lora = true, gps = true, disp = true,
  musiclib = true, appstore = true, gfx = true, snd = true, imu = true, wifi = true, usb = true, net = true,
  clock = true, math = true, table = true, utf8 = true, coroutine = true, backup = true, crypto = true }
setmetatable(_G, { __index = function(t, k)
  if LAZY[k] then
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
  -- an App Store copy (with bytecode) runs stripped; one edited on the device
  -- keeps its debug info, so its errors show lines
  local edited = stored and not sys.in_storage(path .. "c")
  collectgarbage("collect")
  local before = collectgarbage("count")
  local fn, err = sys.loadfile(path, false, strip and not edited)
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

-- app.save() tables are kept as text while the app is closed: __ser and
-- __deser are native (bindings.cpp).

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
