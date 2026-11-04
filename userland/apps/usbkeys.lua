-- USB keyboard: type saved snippets into the computer, or use the Cardputer
-- as a live USB keyboard. Snippets live in data/snippets.txt as  label|text
-- (write \n for a new line). Press E to edit them.
local col = ui.col

local app = { title = "USB Keys", icon = "usb", color = "blue", order = 10, category = "net" }

local FILE = "data/snippets.txt"
local DEFAULT = "Hello|Hello, world!\nSign-off|Best regards,\\nThe Cardputer\n"

local items, sel, top = {}, 1, 1
local mode = "menu"
local last = ""

local function load_snippets()
  items = { { label = "Live keyboard", value = "type now", pass = true } }
  local src = sys.read_text(FILE)
  if not src then
    sys.write_text(FILE, DEFAULT)
    src = DEFAULT
  end
  for line in src:gmatch("[^\n]+") do
    local label, text = line:match("^(.-)|(.*)$")
    if label and label ~= "" then
      items[#items + 1] = { label = label, text = (text:gsub("\\n", "\n")), value = ui.fit(text, 80) }
    end
  end
end

function app.init()
  mode, sel, top = "menu", 1, 1
  load_snippets()
end

local function forward(k)
  local mods = (k.ctrl and "ctrl+" or "") .. (k.alt and "alt+" or "")
  if k.text then
    if mods ~= "" then usb.key(mods .. k.text) else usb.type(k.text) end
    last = k.text
  else
    usb.key(mods .. k.key)
    last = k.key
  end
end

function app.draw()
  local st = usb.status()
  if not st.keyboard then
    ui.empty("warn", "USB keyboard is off", "Settings > USB > Keyboard")
    return
  end
  if mode == "pass" then
    ui.center(40, "Typing to computer", col.accent, 2)
    ui.center(70, "Everything you press is sent", col.dim)
    ui.center(84, "last: " .. last, col.text)
    ui.footer({ { "Esc", "Stop" } })
    return
  end
  sel = math.max(1, math.min(sel, #items))
  top = ui.list(items, sel, top, 4, 17, 230, 17, 6)
  ui.footer({ { "Enter", "Type" }, { "E", "Edit snippets" }, { "Esc", "Home" } })
end

function app.key(k)
  local st = usb.status()
  if not st.keyboard then return false end
  if mode == "pass" then
    if k.key == "esc" then mode = "menu"; return true end
    forward(k)
    return true
  end
  local d = ui.nav(k)
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(#items, sel + 1)
  elseif k.key == "enter" then
    local it = items[sel]
    if it.pass then mode = "pass"
    else usb.type(it.text); shell.toast("Typed " .. it.label) end
  elseif k.text == "e" then shell.edit(FILE)
  else return false end
  return true
end

return app
