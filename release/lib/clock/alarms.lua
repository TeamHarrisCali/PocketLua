-- Clock > Alarms: the list (on/off, repeat days), the editor and the snooze
-- length. Loaded while the tab is open (see apps/clock.lua for C and S).
return function(C, S)
local col = ui.col
local REPEATS = C.REPEATS
local REPEAT_ORDER = { "d", "w", "e", "o" }
local REPEAT_BADGE = { d = "D", w = "W", e = "E", o = "1" }
local SNOOZES = { 1, 2, 3, 5, 10, 15 }
local MAX_ALARMS = 12

local alarms, arows, asel, atop = {}, {}, 1, 1
local edit = nil  -- the alarm being edited: {h=, m=, label=, rep=, index=, sel=, typed=}
local erows = {}

local function snooze_min() return math.max(1, math.min(60, tonumber(cfg.get("snooze")) or 1)) end

local function build_rows()
  arows = {}
  for i, a in ipairs(alarms) do
    arows[i] = { label = ui.fit(shell.format_time(a) .. "  " .. a.label, 150), switch = a.on, dim = not a.on,
      badge = REPEAT_BADGE[a.rep], badge_color = a.on and ui.accents.orange or nil }
  end
  arows[#arows + 1] = { label = "+ New alarm" }
  arows[#arows + 1] = { label = "Snooze length", value = snooze_min() .. " min" }
  asel = math.max(1, math.min(asel, #arows))
end

local function save()
  table.sort(alarms, function(a, b) return a.h * 60 + a.m < b.h * 60 + b.m end)
  local parts = {}
  for i, a in ipairs(alarms) do
    parts[i] = string.format("%02d:%02d|%s|%s%s", a.h, a.m, (a.label:gsub("[;|]", " ")), a.on and "1" or "0", a.rep)
  end
  cfg.set("alarms", #parts > 0 and table.concat(parts, ";") or nil)
  build_rows()
end

-- ---------------------------------------------------------------- editor
local function build_edit_rows()
  local e = edit
  local time = e.typed ~= "" and (e.typed .. string.rep("_", 4 - #e.typed)):gsub("^(..)(..)$", "%1:%2")
    or shell.format_time(e)
  erows = {
    { label = "Time", value = time },
    { label = "Label", value = e.label ~= "" and e.label or "(none)" },
    { label = "Repeat", value = REPEATS[e.rep] },
    { label = e.index and "Save changes" or "Add alarm" },
  }
end

local function open_editor(i)
  local a = alarms[i]
  if not a and #alarms >= MAX_ALARMS then shell.toast("At most " .. MAX_ALARMS .. " alarms"); return end
  local t = clock.now()
  edit = a and { h = a.h, m = a.m, label = a.label, rep = a.rep, index = i }
    or { h = t.valid and (t.h + 1) % 24 or 7, m = 0, label = "", rep = "d" }
  edit.sel, edit.typed = 1, ""
  build_edit_rows()
end

local function save_edit()
  local e = edit
  for i, a in ipairs(alarms) do
    if i ~= e.index and a.h == e.h and a.m == e.m and a.label == e.label then
      shell.toast("That alarm already exists"); return
    end
  end
  local a = { h = e.h, m = e.m, label = e.label, on = true, rep = e.rep }
  if e.index then alarms[e.index] = a else alarms[#alarms + 1] = a end
  edit = nil
  save()
  for i, x in ipairs(alarms) do if x == a then asel = i end end
  shell.toast("Alarm set for " .. shell.format_time(a) .. (a.rep ~= "d" and (" (" .. REPEATS[a.rep] .. ")") or ""))
end

local function edit_minutes(d)  -- +/- minutes, wrapping round the day
  local t = (edit.h * 60 + edit.m + d) % 1440
  edit.h, edit.m, edit.typed = t // 60, t % 60, ""
end

local function key_edit(k, d)
  local e, c = edit, not k.ctrl and not k.fn and k.text
  if k.key == "esc" then edit = nil; build_rows(); return true end
  if d == "up" then e.sel = math.max(1, e.sel - 1)
  elseif d == "down" then e.sel = math.min(#erows, e.sel + 1)
  elseif e.sel == 1 and (d == "left" or d == "right") then edit_minutes(d == "left" and -1 or 1)
  elseif e.sel == 1 and (c == "[" or c == "]") then edit_minutes(c == "[" and -60 or 60)
  elseif e.sel == 1 and c and c:match("^%d$") then
    e.typed = (#e.typed >= 4 and "" or e.typed) .. c
    if #e.typed == 4 then
      local h, m = tonumber(e.typed:sub(1, 2)), tonumber(e.typed:sub(3, 4))
      if h < 24 and m < 60 then e.h, e.m = h, m else shell.toast("Use 24-hour HHMM, e.g. 0730") end
      e.typed = ""
    end
  elseif e.sel == 1 and (c == "a" or c == "p") then  -- AM / PM
    e.h = e.h % 12 + (c == "p" and 12 or 0)
  elseif e.sel == 1 and k.key == "backspace" then e.typed = e.typed:sub(1, -2)
  elseif e.sel == 3 and (d == "left" or d == "right" or k.key == "enter") then
    local k2 = 1
    for i, r in ipairs(REPEAT_ORDER) do if r == e.rep then k2 = i end end
    e.rep = REPEAT_ORDER[(k2 - 1 + (d == "left" and -1 or 1)) % #REPEAT_ORDER + 1]
  elseif e.sel == 2 and k.key == "enter" then
    shell.prompt("Alarm label", e.label, function(s)
      if s and edit then edit.label = s:gsub("[;|]", " "):sub(1, 24); build_edit_rows() end
    end)
  elseif k.key == "enter" then save_edit(); return true
  else return false end
  if edit then build_edit_rows() end
  return true
end

-- ---------------------------------------------------------------- tab
local tab = {}

function tab.init()
  alarms = C.load_alarms()
  build_rows()
end

function tab.close() alarms, arows, erows, edit = {}, {}, {}, nil end

function tab.busy() return edit ~= nil end  -- Tab doesn't leave the editor

function tab.draw()
  if edit then
    ui.text(8, 33, edit.index and "EDIT ALARM" or "NEW ALARM", col.muted)
    ui.list(erows, edit.sel, 1, 4, 44, 230, 15, 4)
    local hint = edit.sel == 1 and "<> min  [ ] hour  type 0730  a/p" or edit.sel == 3 and "<> to change"
      or edit.sel == 2 and "Enter to type a label" or "Enter to save"
    ui.center(108, hint, col.muted)
    ui.footer({ { "Enter", edit.sel == 4 and "Save" or "Select" }, { "Up/Dn", "Field" }, { "Esc", "Cancel" } })
    return
  end
  atop = ui.list(arows, asel, atop, 4, 33, 230, 15, 6)
  ui.footer(alarms[asel] and { { "Enter", "Edit" }, { "Spc", "On/off" }, { "X", "Delete" }, { "A", "New" } }
    or asel == #arows and { { "<>", "Snooze" }, { "A", "New alarm" }, { "Tab", "Timer" } }
    or { { "Enter", "New alarm" }, { "Tab", "Timer" }, { "Esc", "Home" } })
end

function tab.key(k, d)
  if edit then return key_edit(k, d) end
  local c = not k.ctrl and not k.fn and k.text
  local a = alarms[asel]
  if d == "up" then asel = math.max(1, asel - 1)
  elseif d == "down" then asel = math.min(#arows, asel + 1)
  elseif c == "a" then open_editor(nil)
  elseif asel == #arows and (d == "left" or d == "right") then  -- snooze length
    local k2 = 1
    for i, m in ipairs(SNOOZES) do if m == snooze_min() then k2 = i end end
    cfg.set("snooze", SNOOZES[math.max(1, math.min(#SNOOZES, k2 + (d == "left" and -1 or 1)))])
    build_rows()
  elseif k.key == "enter" then
    if a then open_editor(asel) elseif asel == #arows - 1 then open_editor(nil) end
  elseif a and (c == " " or k.key == "space") then
    a.on = not a.on
    save()
    shell.toast(shell.format_time(a) .. (a.on and " on" or " off"))
  elseif a and c == "x" then
    table.remove(alarms, asel)
    save()
    shell.toast("Alarm deleted")
  else
    return false
  end
  return true
end

return tab
end
