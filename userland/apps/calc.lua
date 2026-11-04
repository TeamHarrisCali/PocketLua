-- Calculator: type an expression and press Enter, or convert units. The
-- expression is read by a small parser here; typed text is never run as Lua.
local col = ui.col
local app = { title = "Calculator", icon = "calc", color = "purple", order = 22, category = "tools" }

local TABS = { "Calc", "Units" }
local MAX_INPUT = 60
local MAX_HIST = 6

local tab = 1

-- ---------------------------------------------------------------- calculator state
local input = ""
local ans = 0.0
local deg = false
local hist = {}          -- { {e=expr, r=result text} }, newest first
local hpos = 0           -- history entry recalled with Up/Down (0 = none)
local last_s, res_s, res_size, res_err = "", "0", 3, false
local hist_s = {}        -- history lines shown under the result

-- ---------------------------------------------------------------- parser
-- expr  := term { (+|-) term }
-- term  := unary { (*|/|%) unary | implicit product }
-- unary := (-|+) unary | power
-- power := atom [ ^ unary ]            (right associative, -2^2 = -4)
-- atom  := number | ( expr ) | const | func atom
local src, pos, depth

local function fail(msg) error(msg, 0) end

local function rad(x) return deg and x * math.pi / 180 or x end
local function unrad(x) return deg and x * 180 / math.pi or x end
local function tidy(x) if math.abs(x) < 1e-6 then return 0.0 end return x end

local FUNCS = {
  sqrt = function(x) if x < 0 then fail("sqrt of a negative number") end return math.sqrt(x) end,
  sin = function(x) return tidy(math.sin(rad(x))) end,
  cos = function(x) return tidy(math.cos(rad(x))) end,
  tan = function(x) return tidy(math.tan(rad(x))) end,
  asin = function(x) return unrad(math.asin(x)) end,
  acos = function(x) return unrad(math.acos(x)) end,
  atan = function(x) return unrad(math.atan(x)) end,
  log = function(x) if x <= 0 then fail("log needs a positive number") end return math.log(x, 10) end,
  ln = function(x) if x <= 0 then fail("ln needs a positive number") end return math.log(x) end,
  abs = function(x) return math.abs(x) end,
  exp = function(x) return math.exp(x) end,
}

local function peek()
  pos = src:find("[^ ]", pos) or (#src + 1)
  return src:sub(pos, pos)
end

local expr, unary

local function atom()
  local c = peek()
  if c:match("[%d%.]") then
    local s = src:match("^%d*%.?%d*", pos)
    local ex = src:match("^[eE][%+%-]?%d+", pos + #s)
    if ex then s = s .. ex end
    local v = tonumber(s)
    if not v then fail("bad number '" .. s .. "'") end
    pos = pos + #s
    return v + 0.0
  elseif c == "(" then
    depth = depth + 1
    if depth > 24 then fail("too many brackets") end
    pos = pos + 1
    local v = expr()
    if peek() ~= ")" then fail("missing )") end
    pos = pos + 1
    depth = depth - 1
    return v
  elseif c:match("%a") then
    local name = src:match("^%a+", pos)
    pos = pos + #name
    local n = name:lower()
    if n == "pi" then return math.pi end
    if n == "e" then return math.exp(1) end
    if n == "ans" then return ans end
    local f = FUNCS[n]
    if not f then fail("unknown name '" .. name .. "'") end
    if peek() == "" then fail(n .. " needs a value") end
    return f(atom())
  elseif c == "" then
    fail("incomplete expression")
  end
  fail("unexpected '" .. c .. "'")
end

local function power()
  local v = atom()
  if peek() == "^" then
    pos = pos + 1
    v = v ^ unary()
  end
  return v
end

function unary()
  local c = peek()
  if c == "-" then pos = pos + 1; return -unary() end
  if c == "+" then pos = pos + 1; return unary() end
  return power()
end

local function term()
  local v = unary()
  while true do
    local c = peek()
    if c == "*" then pos = pos + 1; v = v * unary()
    elseif c == "/" or c == "%" then
      pos = pos + 1
      local r = unary()
      if r == 0 then fail("divide by zero") end
      if c == "/" then v = v / r else v = v - math.floor(v / r) * r end
    elseif c == "(" or c:match("^%a$") then v = v * power()   -- 2pi, 3(4+1)
    else return v end
  end
end

function expr()
  local v = term()
  while true do
    local c = peek()
    if c == "+" then pos = pos + 1; v = v + term()
    elseif c == "-" then pos = pos + 1; v = v - term()
    else return v end
  end
end

-- Evaluates s. Returns the number, or nil and an error message.
local function evaluate(s)
  src, pos, depth = s, 1, 0
  local ok, v = pcall(function()
    local r = expr()
    if peek() ~= "" then fail("unexpected '" .. src:sub(pos, pos) .. "'") end
    return r
  end)
  src = nil
  if not ok then return nil, tostring(v) end
  if v ~= v then return nil, "not a number" end
  if v == math.huge or v == -math.huge then return nil, "number too large" end
  return v
end

local function fmt(v)
  if v == 0 then return "0" end
  return (string.format("%.7g", v))
end

-- ---------------------------------------------------------------- calculator view
local function build_calc()
  hist_s = {}
  for i = 2, math.min(#hist, 4) do hist_s[#hist_s + 1] = ui.fit(hist[i].e .. " = " .. hist[i].r, 228) end
  if res_err then res_size = 1
  else res_size = #res_s <= 12 and 3 or (#res_s <= 18 and 2 or 1) end
end

local function calculate()
  local s = input:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return end
  local v, err = evaluate(s)
  hpos = 0
  if not v then
    last_s, res_s, res_err = ui.fit(s .. " =", 228), "Error: " .. err, true
    shell.sound("error")
  else
    ans = v
    last_s, res_s, res_err = ui.fit(s .. " =", 228), fmt(v), false
    table.insert(hist, 1, { e = s, r = res_s })
    if #hist > MAX_HIST then hist[#hist] = nil end
    input = ""
  end
  build_calc()
end

local function key_calc(k)
  local c = k.text
  if k.ctrl and c and c:lower() == "d" then
    deg = not deg
    shell.toast(deg and "Angles in degrees" or "Angles in radians")
  elseif k.key == "enter" then calculate()
  elseif k.key == "backspace" then input = input:sub(1, -2); hpos = 0
  elseif k.key == "up" or k.key == "down" then
    if #hist == 0 then return true end
    hpos = math.max(0, math.min(#hist, hpos + (k.key == "up" and 1 or -1)))
    input = hpos > 0 and hist[hpos].e or ""
  elseif c and not k.ctrl and not k.fn and c:match("^[%w%+%-%*/%^%%%(%)%. ]$") then
    if #input >= MAX_INPUT then shell.toast("Expression too long"); return true end
    if input == "" and #hist > 0 and c:match("^[%+%*/%^%%]$") then input = "ans" end
    input = input .. c
    hpos = 0
  else
    return false
  end
  return true
end

-- ---------------------------------------------------------------- units
local CATS = {
  { name = "Length", u = { "mm", "cm", "m", "km", "in", "ft", "yd", "mi", "nmi" },
    f = { 0.001, 0.01, 1, 1000, 0.0254, 0.3048, 0.9144, 1609.344, 1852 }, from = 4, to = 8 },
  { name = "Mass", u = { "mg", "g", "kg", "t", "oz", "lb", "st" },
    f = { 0.001, 1, 1000, 1000000, 28.349523, 453.59237, 6350.2932 }, from = 3, to = 6 },
  { name = "Temperature", u = { "C", "F", "K" }, from = 1, to = 2 },
  { name = "Volume", u = { "mL", "L", "m3", "tsp", "tbsp", "fl oz", "cup", "pt", "qt", "gal" },
    f = { 0.001, 1, 1000, 0.00492892, 0.0147868, 0.0295735, 0.236588, 0.473176, 0.946353, 3.785412 }, from = 2, to = 10 },
  { name = "Speed", u = { "m/s", "km/h", "mph", "kn", "ft/s" },
    f = { 1, 1 / 3.6, 0.44704, 0.5144444, 0.3048 }, from = 2, to = 3 },
  { name = "Data", u = { "bit", "B", "KB", "MB", "GB", "KiB", "MiB", "GiB" },
    f = { 0.125, 1, 1000, 1000000, 1000000000.0, 1024, 1048576, 1073741824.0 }, from = 4, to = 7 },
}

local ucat, ufield, uval = 1, 1, ""
local urows, ures_s, unit_s = {}, "", ""

local function to_kelvin(v, u)
  if u == "C" then return v + 273.15 elseif u == "F" then return (v - 32) * 5 / 9 + 273.15 end
  return v
end
local function from_kelvin(v, u)
  if u == "C" then return v - 273.15 elseif u == "F" then return (v - 273.15) * 9 / 5 + 32 end
  return v
end

local function build_units()
  local c = CATS[ucat]
  urows = {
    { label = "Category", value = c.name },
    { label = "From", value = c.u[c.from] },
    { label = "To", value = c.u[c.to] },
  }
  unit_s = c.u[c.from]
  local v = tonumber(uval)
  if not v then ures_s = uval == "" and "Type a value" or "--"; return end
  local r
  if c.f then r = v * c.f[c.from] / c.f[c.to]
  else r = from_kelvin(to_kelvin(v, c.u[c.from]), c.u[c.to]) end
  ures_s = "= " .. fmt(r) .. " " .. c.u[c.to]
end

local function key_units(k)
  local c = CATS[ucat]
  local kk, t = k.key, k.text
  if kk == "up" then ufield = math.max(1, ufield - 1); return true
  elseif kk == "down" then ufield = math.min(3, ufield + 1); return true
  elseif kk == "left" or kk == "right" then
    local d = kk == "left" and -1 or 1
    if ufield == 1 then
      ucat = (ucat - 1 + d) % #CATS + 1
    elseif ufield == 2 then
      c.from = (c.from - 1 + d) % #c.u + 1
    else
      c.to = (c.to - 1 + d) % #c.u + 1
    end
  elseif kk == "backspace" then uval = uval:sub(1, -2)
  elseif t and not k.ctrl and not k.fn and t:match("^[%d%.]$") then
    if #uval < 14 then uval = uval .. t end
  elseif t == "-" then
    uval = uval:sub(1, 1) == "-" and uval:sub(2) or ("-" .. uval)
  elseif t == "s" then
    c.from, c.to = c.to, c.from
    if tonumber(uval) and ures_s ~= "" then shell.toast("Swapped") end
  else
    return false
  end
  build_units()
  return true
end

-- ---------------------------------------------------------------- lifecycle
function app.init(args, saved)
  if saved then
    tab, deg, ans = saved.tab or 1, saved.deg or false, saved.ans or 0.0
    hist = saved.hist or {}
    ucat = saved.ucat or 1
    if saved.units then
      for i, p in ipairs(saved.units) do
        local c = CATS[i]
        if c and c.u[p[1]] and c.u[p[2]] then c.from, c.to = p[1], p[2] end
      end
    end
  end
  input, uval, hpos, res_err = "", "", 0, false
  if hist[1] then last_s, res_s = ui.fit(hist[1].e .. " =", 228), hist[1].r else last_s, res_s = "", "0" end
  build_calc()
  build_units()
end

function app.save()
  local units = {}
  for i, c in ipairs(CATS) do units[i] = { c.from, c.to } end
  return { tab = tab, deg = deg, ans = ans, hist = hist, ucat = ucat, units = units }
end

function app.close()
  hist_s, urows = {}, {}
end

local function draw_calc()
  ui.card(4, 33, 232, 18, true)
  local shown = #input > 33 and input:sub(-33) or input
  ui.text(9, 38, shown, col.text)
  if (sys.millis() // 500) % 2 == 0 then gfx.fill(9 + #shown * 6, 45, 6, 2, col.accent) end
  ui.right(232, 38, deg and "DEG" or "RAD", col.muted)
  ui.right(232, 56, last_s, col.muted)
  if res_err then
    ui.right(232, 72, ui.fit(res_s, 228), col.bad)
  else
    ui.right(232, res_size == 3 and 66 or 70, res_s, col.accent, res_size)
  end
  for i, s in ipairs(hist_s) do ui.text(8, 86 + i * 10, s, col.muted) end
  ui.footer({ { "Enter", "=" }, { "^D", "Deg/Rad" }, { "Tab", "Units" }, { "Esc", input ~= "" and "Clear" or "Home" } })
end

local function draw_units()
  local sel = ufield
  ui.list(urows, sel, 1, 4, 33, 230, 14, 3)
  ui.card(4, 78, 232, 16, false)
  local shown = uval
  ui.text(9, 82, shown, col.text)
  if (sys.millis() // 500) % 2 == 0 then gfx.fill(9 + #shown * 6, 89, 6, 2, col.accent) end
  ui.right(230, 82, unit_s, col.muted)
  ui.center(100, ures_s, tonumber(uval) and col.accent or col.muted, #ures_s <= 19 and 2 or 1)
  ui.footer({ { "Up/Dn", "Field" }, { "<>", "Change" }, { "S", "Swap" }, { "Tab", "Calc" } })
end

function app.draw()
  ui.tabs(TABS, tab, 16)
  if tab == 1 then draw_calc() else draw_units() end
end

function app.key(k)
  if k.key == "tab" then tab = tab % #TABS + 1; return true end
  if k.key == "esc" then
    if tab == 1 and input ~= "" then input = ""; hpos = 0; return true end
    if tab == 2 and uval ~= "" then uval = ""; build_units(); return true end
    return false
  end
  if tab == 1 then return key_calc(k) end
  return key_units(k)
end

return app
