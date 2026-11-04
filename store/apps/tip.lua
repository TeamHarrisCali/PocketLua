-- Tip & Split: works out the tip, the total and each person's share of a
-- bill, and can round the total or each share up to a whole dollar.
local col = ui.col
local app = { title = "Tip & Split", icon = "calc", color = "green", order = 25, category = "tools" }
app.help = {
  { "0-9 .", "Type in the field" },
  { "Up/Dn", "Choose a field" },
  { "<>", "Change tip, people" },
  { "Enter", "Next field" },
  { "Bksp", "Delete" },
  { "Esc", "Clear bill, then home" },
}

local ROUNDS = { "Off", "Each up", "Total up" }
local MAX_PEOPLE = 99
local FIELDS = 4

local field = 1         -- 1 bill, 2 tip, 3 people, 4 round
local bill = ""         -- as typed, e.g. "48.5"
local tip, people, round = 20, 2, 1
local fresh = true      -- the next digit starts a new tip / people number
local rows = {}
local line_s, each_s, each_good = "", "", false

local function money(c) return string.format("$%d.%02d", c // 100, c % 100) end

-- Everything in whole cents, so the shares add up.
local function build()
  rows = {
    { label = "Bill", value = "$" .. (bill ~= "" and bill or "0") },
    { label = "Tip", value = tip .. "%" },
    { label = "People", value = tostring(people) },
    { label = "Round", value = ROUNDS[round] },
  }
  local b = tonumber(bill)
  if not b or b <= 0 then
    line_s, each_s, each_good = "Type the bill amount", "", false
    return
  end
  local bill_c = math.floor(b * 100 + 0.5)
  local tip_c = (bill_c * tip + 50) // 100
  local total_c = bill_c + tip_c
  if round == 3 then
    total_c = (total_c + 99) // 100 * 100
    tip_c = total_c - bill_c
  end
  local each_c = (total_c + people - 1) // people  -- up to the cent: nobody pays short
  if round == 2 then
    each_c = (each_c + 99) // 100 * 100
    total_c = each_c * people
    tip_c = total_c - bill_c
  end
  local pct = round > 1 and string.format(" (%.1f%%)", tip_c * 100 / bill_c) or ""
  line_s = "Tip " .. money(tip_c) .. pct .. "  Total " .. money(total_c)
  each_s = people > 1 and (money(each_c) .. " each") or money(total_c)
  each_good = true
end

local function set_number(which, v)
  if which == 2 then tip = math.max(0, math.min(100, v))
  else people = math.max(1, math.min(MAX_PEOPLE, v)) end
end

local function key_digit(c)
  if field == 1 then
    if c == "." and bill:find(".", 1, true) then return end
    local int, dec = bill:match("^(%d*)%.?(%d*)$")
    if bill:find(".", 1, true) then
      if #dec >= 2 then shell.toast("Cents: two digits"); return end
    elseif c ~= "." and #int >= 6 then
      shell.toast("Bill too large"); return
    end
    bill = (bill == "" and c == ".") and "0." or bill .. c
  elseif field == 2 or field == 3 then
    if c == "." then return end
    local cur = field == 2 and tip or people
    set_number(field, fresh and tonumber(c) or cur * 10 + tonumber(c))
    fresh = false
  end
end

local function change(d)
  if field == 2 then set_number(2, tip + d)
  elseif field == 3 then set_number(3, people + d)
  elseif field == 4 then round = (round - 1 + d) % #ROUNDS + 1
  end
  fresh = true
end

function app.init(args, saved)
  if saved then
    bill = saved.bill or ""
    tip, people, round = saved.tip or 20, saved.people or 2, saved.round or 1
  end
  field, fresh = 1, true
  build()
end

function app.save() return { bill = bill, tip = tip, people = people, round = round } end

function app.close() rows = {} end

function app.draw()
  ui.list(rows, field, 1, 4, 18, 230, 14, FIELDS)
  ui.card(4, 78, 232, 42, false)
  ui.center(84, ui.fit(line_s, 224), each_good and col.text or col.muted)
  if each_s ~= "" then ui.center(100, each_s, col.accent, #each_s <= 18 and 2 or 1) end
  ui.footer({ { "Up/Dn", "Field" }, { "<>", "Change" }, { "Enter", "Next" }, { "Esc", bill ~= "" and "Clear" or "Home" } })
end

function app.key(k)
  local kk, t = k.key, k.text
  if kk == "up" then field = math.max(1, field - 1); fresh = true
  elseif kk == "down" then field = math.min(FIELDS, field + 1); fresh = true
  elseif kk == "enter" then field = field % FIELDS + 1; fresh = true
  elseif kk == "left" then change(-1)
  elseif kk == "right" then change(1)
  elseif kk == "backspace" then
    if field == 1 then bill = bill:sub(1, -2)
    elseif field == 2 then tip = tip // 10
    elseif field == 3 then people = math.max(1, people // 10) end
    fresh = false
  elseif kk == "esc" then
    if bill == "" then return false end
    bill = ""
    shell.toast("Bill cleared")
  elseif t and not k.ctrl and not k.fn and t:match("^[%d%.]$") then
    key_digit(t)
  else
    return false
  end
  build()
  return true
end

return app
