-- Clock > Timer: presets or typed minutes; running timers with pause and
-- progress. Loaded while the tab is open (see apps/clock.lua for C and S).
return function(C, S)
local col = ui.col
local PRESETS = { 1, 3, 5, 10, 15, 25, 30, 45, 60 }

local typed = ""
local tlist, trows, tsel, ttop = {}, {}, 1, 1
local mins_s = ""

local function mins() return typed ~= "" and tonumber(typed) or PRESETS[S.preset] end

local function refresh()
  tlist, trows = {}, {}
  for _, t in ipairs(shell.timers) do
    if not t.pomo then
      tlist[#tlist + 1] = t
      trows[#trows + 1] = { label = t.label .. (t.paused and " (paused)" or ""), value = C.hms(t.left), dim = t.paused }
    end
  end
  tsel = math.max(1, math.min(tsel, #trows))
  mins_s = C.hms(mins() * 60)
end

local tab = { refresh = refresh }

function tab.init()
  S.preset = math.max(1, math.min(#PRESETS, S.preset or 3))
  refresh()
end

function tab.close() tlist, trows = {}, {} end

function tab.draw()
  ui.big(32, mins_s, typed ~= "" and col.accent or col.text, 3)
  -- presets as chips; typed minutes replace them
  local x = 6
  for i, m in ipairs(PRESETS) do
    local s = tostring(m)
    local w = #s * 6 + 8
    local on = typed == "" and i == S.preset
    gfx.rfill(x, 60, w, 13, 3, on and col.accent or col.surface)
    ui.text(x + 4, 63, s, on and col.on_accent or col.muted)
    x = x + w + 3
  end
  if #trows == 0 then
    ui.center(92, "Pick minutes with <> or type them", col.muted)
  else
    ttop = ui.list(trows, tsel, ttop, 4, 78, 230, 14, 3)
    local t = tlist[tsel]
    if t then ui.bar(8, 120, 224, 2, 1 - t.left / math.max(1, t.total), t.paused and col.muted or col.accent) end
  end
  ui.footer(#trows > 0 and { { "Enter", "Start" }, { "Spc", "Pause" }, { "X", "Cancel" }, { "<>", "Min" } }
    or { { "Enter", "Start" }, { "<>", "Minutes" }, { "Tab", "Watch" }, { "Esc", "Home" } })
end

function tab.key(k, d)
  local c = not k.ctrl and not k.fn and k.text
  if k.key == "esc" then
    if typed == "" then return false end
    typed = ""
  elseif c and c:match("^%d$") then
    if #typed >= 3 then typed = "" end
    typed = typed .. c
    if tonumber(typed) == 0 then typed = "" end
  elseif k.key == "backspace" then typed = typed:sub(1, -2)
  elseif d == "left" or d == "right" then
    typed = ""
    S.preset = math.max(1, math.min(#PRESETS, S.preset + (d == "left" and -1 or 1)))
  elseif d == "up" then tsel = math.max(1, tsel - 1)
  elseif d == "down" then tsel = math.min(#trows, tsel + 1)
  elseif k.key == "enter" then
    local m = mins()
    typed = ""
    shell.start_timer(m * 60, m .. " min timer")
    shell.toast("Timer started: " .. m .. " min")
    refresh()
    tsel = #trows
  elseif c == " " or k.key == "space" then
    local t = tlist[tsel]
    if not t then shell.toast("No timer running"); return true end
    shell.pause_timer(t, not t.paused)
    shell.toast(t.paused and "Resumed" or "Paused")
  elseif c == "x" then
    local t = tlist[tsel]
    if not t then shell.toast("No timer running"); return true end
    shell.cancel_timer(t)
    shell.toast("Cancelled " .. t.label)
  else
    return false
  end
  refresh()
  return true
end

return tab
end
