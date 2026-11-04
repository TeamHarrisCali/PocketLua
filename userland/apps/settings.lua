-- Settings. Each page lives in lib/settings/<name>.lua and is loaded only while
-- it is open, so Settings never holds more than the page you are looking at.
local col = ui.col

local app = { title = "Settings", icon = "gear", color = "orange", order = 1, category = "system" }

local stack, page, sel, top = {}, nil, 1, 1
local rows = {}

local function push(p)
  stack[#stack + 1] = { page = page, sel = sel, top = top }
  page, sel, top = p, 1, 1
  if p.enter then p.enter() end
end

local function pop()
  if page.leave then page.leave() end
  local s = table.remove(stack)
  page, sel, top = s.page, s.sel, s.top
  collectgarbage("collect")  -- the closed page's code is garbage now
end

local ctx = {
  push = push,
  pop = pop,
  cycle = function(i, n, d) return (i - 1 + d) % n + 1 end,
  num = function(key, default) return tonumber(cfg.get(key)) or default end,
}

local function report(err)
  err = tostring(err)
  if err:find("not enough memory", 1, true) then
    shell.toast("Not enough memory - stop Wi-Fi in Task Manager", 4)
  else
    shell.toast(err, 4)
  end
end

local function open(name)
  local fn, err = sys.loadfile("lib/settings/" .. name .. ".lua")
  if not fn then report(err or ("missing page " .. name)); return end
  local ok, make = pcall(fn)
  if not ok then report(make); return end
  local ok2, p = pcall(make, ctx)
  if not ok2 then report(p); return end
  push(p)
end

local STATUS = { off = "Off", idle = "Not connected", connecting = "Connecting...", connected = "Connected", failed = "Failed" }

local function main_page()
  local p = { title = "Settings" }
  local A = ui.accents
  local function item(label, name, badge, colour, value)
    return { label = label, value = value, badge = badge, badge_color = colour, enter = function() open(name) end }
  end
  function p.rows()
    return {
      item("Wi-Fi", "wifi", "W", A.blue, STATUS[wifi.status()]),
      item("Date & Time", "time", "T", A.teal),
      item("Display", "display", "D", A.orange),
      item("Sound", "sound", "S", A.pink),
      item("Devices", "devices", "N", A.red),
      item("USB", "usb", "U", A.green),
      item("About", "about", "i", A.purple),
    }
  end
  return p
end

function app.init()
  stack = {}
  page, sel, top = main_page(), 1, 1
end

function app.close()
  if page and page.leave then page.leave() end
end

-- Rows are built once per frame here; draw() runs once per screen band and
-- only reads them.
function app.update(dt)
  if page.update then page.update(dt) end
  rows = page.rows()
  sel = math.max(1, math.min(sel, #rows))
  app.title = #stack > 0 and ("Settings > " .. page.title) or "Settings"
end

function app.draw()
  top = ui.list(rows, sel, top, 4, 17, 230, 17, 6)
  ui.footer(#stack > 0 and { { "Enter", "Select" }, { "<>", "Change" }, { "Esc", "Back" } } or { { "Enter", "Open" }, { "Esc", "Home" } })
end

function app.key(k)
  if page.key and page.key(k) then return true end
  local d = ui.nav(k)
  local r = rows[sel]
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(#rows, sel + 1)
  elseif d == "left" then if r and r.left then r.left() end
  elseif d == "right" then if r and r.right then r.right() end
  elseif k.key == "enter" then if r and r.enter then r.enter() end
  elseif k.key == "esc" then
    if #stack > 0 then pop(); return true end
    return false
  else
    return false
  end
  rows = page.rows()  -- reflect the change immediately
  return true
end

return app
