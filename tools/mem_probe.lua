-- Lua heap usage of the userland, measured on a desktop Lua 5.4 with the
-- host_test stubs. Desktop Lua uses 64-bit pointers and numbers, so the device
-- (32-bit) needs roughly 55-65% of these numbers; use them to compare changes.
-- Run from the project root:  lua5.4 tools/mem_probe.lua
local src = assert(io.open("tools/host_test.lua")):read("a")
local stubs = assert(src:match("^(.-)%-%- %-+ helpers"), "stub section not found")
assert(load(stubs, "=stubs"))()

local peak = 0
local function sample()
  local c = collectgarbage("count")
  if c > peak then peak = c end
end
debug.sethook(sample, "", 200)

local function live()
  collectgarbage("collect")
  collectgarbage("collect")
  return collectgarbage("count")
end

local say = print
local function report(label)
  say(string.format("%-22s live %6.1f KB   peak %6.1f KB", label, live(), peak))
  peak = 0
end

local function frames(n) for _ = 1, n or 5 do on_frame(0.033); on_draw(); on_draw() end end

local base = live()
peak = 0
dofile("tools/emu/boot.lua")
frames()
report("boot + home")

local names = {}
for _, e in ipairs(sys.list("apps")) do names[#names + 1] = e.name:match("^(.+)%.lua$") end
table.sort(names)
for _, name in ipairs(names) do
  shell.launch(name, name == "edit" and { path = "lib/shell.lua" } or nil)
  frames()
  report("  app " .. name)
  shell.home()
  frames()
end
report("back home")
say(string.format("(empty interpreter: %.1f KB)", base))
