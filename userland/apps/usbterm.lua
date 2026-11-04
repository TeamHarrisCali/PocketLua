-- USB serial terminal: text from the computer appears here, and what you type
-- is sent back. Open the Cardputer's serial port on the computer to use it.
local col = ui.col

local app = { title = "USB Serial", icon = "term", color = "teal", order = 11, category = "net" }

local log, input, partial = {}, "", ""

local function add(line)
  for _, l in ipairs(ui.wrap(line, 228)) do log[#log + 1] = l end
  while #log > 60 do table.remove(log, 1) end
end

function app.update()
  if cfg.get("usb_console") == "1" then return end  -- the console owns the port
  local s = usb.read()
  if not s then return end
  partial = partial .. s:gsub("\r", "")
  while true do
    local nl = partial:find("\n", 1, true)
    if not nl then break end
    add(partial:sub(1, nl - 1))
    partial = partial:sub(nl + 1)
  end
end

function app.draw()
  local st = usb.status()
  if not st.serial then
    ui.empty("warn", "USB serial is off", "Settings > USB > Serial port")
    return
  end
  if cfg.get("usb_console") == "1" then
    ui.center(60, "The Lua console is using", col.text)
    ui.center(72, "the serial port.", col.text)
    ui.center(88, "Turn it off in Settings > USB", col.dim)
    return
  end
  for i = 0, 8 do
    local l = log[#log - 8 + i]
    if l then ui.text(4, 17 + i * 10, l, l:sub(1, 2) == "> " and col.accent or col.text) end
  end
  gfx.line(0, 109, ui.W, 109, col.panel2)
  ui.text(4, 113, "> " .. input:sub(-36) .. "_", col.warn)
  ui.footer({ { "Enter", "Send" } })
  ui.right(236, 126, st.connected and "connected" or "waiting", st.connected and col.good or col.muted)
end

function app.key(k)
  if not usb.status().serial or cfg.get("usb_console") == "1" then return false end
  if k.key == "enter" then
    usb.write(input .. "\n")
    add("> " .. input)
    input = ""
  elseif k.key == "backspace" then input = input:sub(1, -2)
  elseif k.text and not k.ctrl then input = input .. k.text
  else return false end
  return true
end

return app
