-- LiveOS boot: module loader, then hand over to the shell.
-- Editing this file only takes effect after a reload (Ctrl+R in the editor).
-- Hardware driver tables (audio, ir, i2c, http, lora, gps, disp) are made on
-- first use; the shell drops them again when an app closes.
local HW = { audio = true, ir = true, i2c = true, http = true, lora = true, gps = true, disp = true }
setmetatable(_G, { __index = function(t, k)
  if HW[k] then
    local lib = sys.hwlib(k)
    rawset(t, k, lib)
    return lib
  end
end })
function release_hw()
  for k in pairs(HW) do rawset(_G, k, nil) end
end

local loaded = {}
local sizes = {}    -- approximate KB each module holds, for Task Manager
_G.boot_notes = {}  -- shown to the user by the shell

-- The ESP32-S3 has no PSRAM: collect as soon as a cycle ends instead of letting
-- the heap double first (Lua's default), so garbage never piles up.
collectgarbage("incremental", 100, 400)

-- sys.loadfile compiles straight from flash or SD, so the source text is never
-- copied into the Lua heap. Built-in system code is loaded without debug info
-- (~20% less RAM); edited copies keep line numbers, and cfg debug_sys = 1 keeps
-- them for built-in code too.
local strip_builtin = cfg.get("debug_sys") ~= "1"
local function run(path, builtin, name)
  local strip = strip_builtin and (builtin or not sys.in_storage(path) or sys.safe_mode)
  local fn, err = sys.loadfile(path, builtin, strip)
  if not fn then return nil, err or ("not found: " .. path) end
  local ok, mod = pcall(fn, name)
  if not ok then return nil, mod end
  if mod == nil then mod = true end
  return mod
end

-- A saved (edited) copy of a system module wins over the built-in one, but if it
-- fails to load the built-in copy is used instead so the system always boots.
function require(name)
  if loaded[name] then return loaded[name] end
  local path = "lib/" .. name .. ".lua"
  if not sys.exists(path) then error("module not found: " .. name, 2) end
  local stored = sys.in_storage(path) and not sys.safe_mode
  sys.log(string.format("load %s from %s", path, stored and "storage" or "built-in"))
  collectgarbage("collect")
  local before = collectgarbage("count")
  local mod, err = run(path, false, name)
  if mod == nil and stored and sys.is_embedded(path) then
    local why = tostring(err)
    sys.log("fallback to built-in " .. path .. ": " .. why)
    mod, err = run(path, true, name)
    if mod ~= nil then
      boot_notes[#boot_notes + 1] = path .. " failed to load, using the built-in copy. " .. why
    end
  end
  if mod == nil then error(err, 0) end
  loaded[name] = mod
  collectgarbage("collect")
  sizes[name] = math.max(0, collectgarbage("count") - before)
  return mod
end

-- Loaded modules and their approximate size: { {name=, kb=}, ... }
function modules()
  local out = {}
  for name in pairs(loaded) do out[#out + 1] = { name = name, kb = sizes[name] or 0 } end
  table.sort(out, function(a, b) return a.kb > b.kb end)
  return out
end

-- Drop a module so its memory can be reclaimed; the next require reloads it.
function unload(name)
  loaded[name] = nil
  sizes[name] = nil
end

require("shell")
