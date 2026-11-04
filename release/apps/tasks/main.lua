-- Task Manager: free memory, the system modules in memory, and the background
-- services, with a way to stop them.
local col = ui.col

local app = { title = "Task Manager", icon = "tasks", color = "red", order = 4, category = "system" }
app.help = {
  { "Up/Dn", "Select" },
  { "Enter", "Free memory / toggle" },
  { "Esc", "Home" },
}

local rows, sel, top = {}, 1, 1
local free, lua_kb, largest, total = 0, 0, 0, 1
local refresh = 0

local STATUS = { off = "off", idle = "on, not connected", connecting = "connecting", connected = "connected", failed = "failed" }

local function build()
  local wst = wifi.status()
  local dev_on = rawget(_G, "dev") and dev.running()
  rows = {
    { label = "Free memory now", badge = "M", badge_color = ui.accents.green, enter = function()
      local before = sys.heap()
      local after = shell.free_memory()
      shell.toast(string.format("Freed %dK", math.max(0, after - before) // 1024))
    end },
    { label = "Wi-Fi", value = STATUS[wst], badge = "W", badge_color = ui.accents.blue, enter = function()
      if wst == "off" then
        if shell.wifi_start(cfg.get("wifi_ssid"), cfg.get("wifi_pass")) then cfg.set("wifi_auto", "1") end
      else
        shell.confirm("Stop Wi-Fi", "Turn Wi-Fi off? It frees about 40-50K.", function(yes)
          if yes then cfg.set("wifi_auto", "0"); shell.wifi_stop() end
        end)
      end
    end },
    { label = "Device sharing", value = dev_on and "running" or "off", badge = "N", badge_color = ui.accents.red,
      enter = function()
        if dev_on then cfg.set("dev_on", "0"); shell.dev_restart(); shell.toast("Device sharing stopped") end
      end },
    { label = "USB console", value = shell.console_running() and "running" or "off", badge = "U",
      badge_color = ui.accents.teal, dim = true },
  }
  for _, m in ipairs(modules()) do
    rows[#rows + 1] = { label = "lib/" .. m.name, value = string.format("%.0fK", m.kb), dim = true }
  end
end

function app.init()
  sel, top, refresh = 1, 1, 0
end

function app.update(dt)
  refresh = refresh - dt
  if refresh <= 0 then
    refresh = 1
    local l
    free, l, largest, total = sys.heap()
    lua_kb = l // 1024
    build()
  end
  sel = math.max(1, math.min(sel, #rows))
end

function app.draw()
  local used = 1 - free / math.max(total, 1)
  ui.text(6, 18, "RAM", col.dim)
  ui.right(234, 18, string.format("%dK free of %dK", free // 1024, total // 1024), col.text)
  ui.bar(6, 29, 228, 6, used, used > 0.85 and col.bad or used > 0.7 and col.warn or col.good)
  ui.text(6, 38, string.format("Lua %dK   largest block %dK", lua_kb, largest // 1024), col.dim)
  top = ui.list(rows, sel, top, 4, 50, 230, 15, 5)
  ui.footer({ { "Enter", "Select" }, { "Esc", "Home" } })
end

function app.key(k)
  local d = ui.nav(k)
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(#rows, sel + 1)
  elseif k.key == "enter" then
    local r = rows[sel]
    if r and r.enter then r.enter(); refresh = 0 end
  else return false end
  return true
end

return app
