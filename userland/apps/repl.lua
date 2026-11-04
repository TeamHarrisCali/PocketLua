-- Lua console: poke at the running system (sys, gfx, snd, imu, wifi, shell, ...).
local col = ui.col

local app = { title = "Lua REPL", icon = "term", color = "green", order = 3, category = "tools" }
app.help = {
  { "Enter", "Run Lua" },
  { "Fn+;/.", "History back / fwd" },
  { "Bksp", "Delete char" },
  { "Esc", "Home" },
}

local input, history, hpos = "", {}, 0
local out = {}

local function push(s)
  for _, l in ipairs(ui.wrap(s, 228)) do out[#out + 1] = l end
  while #out > 60 do table.remove(out, 1) end
end

local function fmt(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts, n = {}, 0
  for key, val in pairs(v) do
    n = n + 1
    if n > 8 then parts[#parts + 1] = "..."; break end
    parts[#parts + 1] = tostring(key) .. "=" .. (type(val) == "table" and "{..}" or tostring(val))
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function run(code)
  push("> " .. code)
  local logged = #shell.log
  local fn, err = load("return " .. code, "=repl")
  if not fn then fn, err = load(code, "=repl") end
  if not fn then push(err); return end
  local res = table.pack(pcall(fn))
  for i = logged + 1, #shell.log do push(shell.log[i]) end
  if not res[1] then push(tostring(res[2])); return end
  for i = 2, res.n do push(fmt(res[i])) end
end

function app.init()
  if #out == 0 then push("Type Lua. Try: sys.heap()") end
end

function app.draw()
  local rows = 9
  for i = 0, rows - 1 do
    local l = out[#out - rows + 1 + i]
    if l then ui.text(4, 17 + i * 10, l, l:sub(1, 2) == "> " and col.accent or col.text) end
  end
  gfx.line(0, 109, ui.W, 109, col.panel2)
  local shown = input
  if #shown > 36 then shown = shown:sub(-36) end
  ui.text(4, 113, "> " .. shown .. ((sys.millis() // 500) % 2 == 0 and "_" or ""), col.warn)
  ui.footer({ { "Enter", "Run" }, { "Fn+;/.", "History" } })
end

function app.key(k)
  if k.key == "enter" then
    if input ~= "" then
      history[#history + 1] = input
      run(input)
    end
    input, hpos = "", 0
  elseif k.key == "backspace" then input = input:sub(1, -2)
  elseif k.key == "up" then
    if #history > 0 then hpos = math.min(#history, hpos + 1); input = history[#history - hpos + 1] end
  elseif k.key == "down" then
    hpos = math.max(0, hpos - 1)
    input = hpos > 0 and history[#history - hpos + 1] or ""
  elseif k.text and not k.ctrl then input = input .. k.text
  else return false end
  return true
end

return app
