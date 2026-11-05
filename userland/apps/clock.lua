-- Clock: time and date, alarms (repeat days, on/off, snooze), countdown
-- timers, a stopwatch and Study (Pomodoro with long breaks and daily stats).
-- Timers and alarms belong to the shell: they go off whatever app is open,
-- ring full screen until stopped or snoozed, and wake the device from sleep.
-- This app only shows and changes them.
local col = ui.col
local app = { title = "Clock", icon = "clock", color = "orange", order = 20, category = "tools" }
app.help = {
  { "Tab", "Next tab" },
  { "Enter", "Start / edit / select" },
  { "Space", "On-off / pause" },
  { "<>", "Change value" },
  { "[ ]", "Alarm: hour -/+" },
  { "0-9", "Type time / minutes" },
  { "A", "New alarm" },
  { "X", "Delete / cancel / stop" },
  { "S", "Study: skip phase" },
  { "L", "Watch: lap" },
  { "R", "Watch: reset" },
  { "Esc", "Back / home" },
}

local TABS = { "Clock", "Alarms", "Timer", "Watch", "Study" }
local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
  "October", "November", "December" }
local REPEATS = { d = "Daily", w = "Weekdays", e = "Weekends", o = "Once" }
local REPEAT_ORDER = { "d", "w", "e", "o" }
local REPEAT_BADGE = { d = "D", w = "W", e = "E", o = "1" }
local PRESETS = { 1, 3, 5, 10, 15, 25, 30, 45, 60 }
local PLANS = { { 25, 5 }, { 50, 10 }, { 90, 15 }, { 15, 3 } }       -- focus / break minutes
local LONGS = { { 0, 0 }, { 4, 15 }, { 4, 20 }, { 3, 15 } }          -- long break every n sessions, minutes
local MAX_ALARMS, MAX_LAPS = 12, 30

local tab = 1
local tick = 0           -- seconds until the shown text is rebuilt

-- Clock tab
local time_s, date_s, secs_f, next_s, extra_s = "--:--", "", 0, "", ""

-- Alarms tab: { {h=, m=, label=, on=, rep=} } sorted by time; rows end with "+ New alarm" and Snooze
local alarms, arows, asel, atop = {}, {}, 1, 1
local edit = nil         -- the alarm being edited: {h=, m=, label=, on=, rep=, index=, sel=, typed=}
local erows = {}

-- Timer tab
local preset, typed = 3, ""            -- PRESETS index, or digits being typed
local tlist, trows, tsel, ttop = {}, {}, 1, 1
local tmins_s = ""

-- Stopwatch (times in ms from sys.millis())
local sw_run, sw_start, sw_acc = false, 0, 0
local laps, lrows, ltop = {}, {}, 1
local sw_s = "00:00.00"

-- Study
local plan, long = 1, 2
local srows, ssel = {}, 1
local pomo = nil                       -- the running Pomodoro timer (shell.timers entry)
local st = { minutes = 0, sessions = 0, streak = 0 }
local phase_s, left_s, task_s, round_s, stats_s = "", "", "", "", ""

-- ---------------------------------------------------------------- helpers
local function hms(sec)
  sec = math.max(0, math.ceil(sec))
  local h, m, s = sec // 3600, sec // 60 % 60, sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%02d:%02d", m, s)
end

local function sw_text(ms)
  local cs = ms // 10
  local h, m, s, c = cs // 360000, cs // 6000 % 60, cs // 100 % 60, cs % 100
  if h > 0 then return string.format("%d:%02d:%02d.%d", h, m, s, c // 10) end
  return string.format("%02d:%02d.%02d", m, s, c)
end

local function span(mins)  -- "7h 12m", "45m"
  if mins >= 60 then return string.format("%dh %dm", mins // 60, mins % 60) end
  return mins .. "m"
end

local function sw_elapsed() return sw_acc + (sw_run and (sys.millis() - sw_start) or 0) end

local function snooze_min() return math.max(1, math.min(60, tonumber(cfg.get("snooze")) or 1)) end

-- ---------------------------------------------------------------- alarms
local function load_alarms()
  alarms = {}
  for item in (cfg.get("alarms") or ""):gmatch("[^;]+") do
    local h, m, label, flags = item:match("^(%d%d):(%d%d)|?([^|]*)|?(.*)$")
    h, m = tonumber(h), tonumber(m)
    if h and h < 24 and m < 60 then
      local rep = flags:sub(2, 2)
      alarms[#alarms + 1] = { h = h, m = m, label = label or "", on = flags:sub(1, 1) ~= "0",
        rep = REPEATS[rep] and rep or "d" }
    end
  end
end

local function build_alarm_rows()
  arows = {}
  for i, a in ipairs(alarms) do
    arows[i] = { label = ui.fit(shell.format_time(a) .. "  " .. a.label, 150), switch = a.on, dim = not a.on,
      badge = REPEAT_BADGE[a.rep], badge_color = a.on and ui.accents.orange or nil }
  end
  arows[#arows + 1] = { label = "+ New alarm" }
  arows[#arows + 1] = { label = "Snooze length", value = snooze_min() .. " min" }
  asel = math.max(1, math.min(asel, #arows))
end

local function save_alarms()
  table.sort(alarms, function(a, b) return a.h * 60 + a.m < b.h * 60 + b.m end)
  local parts = {}
  for i, a in ipairs(alarms) do
    parts[i] = string.format("%02d:%02d|%s|%s%s", a.h, a.m, (a.label:gsub("[;|]", " ")), a.on and "1" or "0", a.rep)
  end
  cfg.set("alarms", #parts > 0 and table.concat(parts, ";") or nil)
  build_alarm_rows()
end

-- Minutes from now (h, m, weekday) until alarm a next goes off, or nil.
local function minutes_until(a, t)
  for d = 0, 7 do
    local wd = ((t.wday or 0) + d) % 7
    local ok = a.rep == "w" and wd >= 1 and wd <= 5 or a.rep == "e" and (wd == 0 or wd == 6)
      or a.rep == "d" or a.rep == "o"
    local mins = d * 1440 + a.h * 60 + a.m - (t.h * 60 + t.m)
    if ok and mins > 0 then return mins end
  end
end

-- the alarm editor
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
  edit = a and { h = a.h, m = a.m, label = a.label, on = a.on, rep = a.rep, index = i }
    or { h = t.valid and (t.h + 1) % 24 or 7, m = 0, label = "", on = true, rep = "d" }
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
  save_alarms()
  for i, x in ipairs(alarms) do if x == a then asel = i end end
  shell.toast("Alarm set for " .. shell.format_time(a) .. (a.rep ~= "d" and (" (" .. REPEATS[a.rep] .. ")") or ""))
end

local function edit_minutes(d)  -- +/- minutes, wrapping round the day
  local t = (edit.h * 60 + edit.m + d) % 1440
  edit.h, edit.m, edit.typed = t // 60, t % 60, ""
end

local function key_edit(k, d)
  local e, c = edit, not k.ctrl and not k.fn and k.text
  if k.key == "esc" then edit = nil; build_alarm_rows(); return true end
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

-- ---------------------------------------------------------------- timers
local function tmins() return typed ~= "" and tonumber(typed) or PRESETS[preset] end

local function refresh_timers()
  tlist, trows = {}, {}
  for _, t in ipairs(shell.timers) do
    if not t.pomo then
      tlist[#tlist + 1] = t
      trows[#trows + 1] = { label = t.label .. (t.paused and " (paused)" or ""), value = hms(t.left), dim = t.paused }
    end
  end
  tsel = math.max(1, math.min(tsel, #trows))
  tmins_s = hms(tmins() * 60)
end

-- ---------------------------------------------------------------- study
local function find_pomo()
  for _, t in ipairs(shell.timers) do if t.pomo then return t end end
end

local function build_study_rows()
  local p, l = PLANS[plan], LONGS[long]
  srows = {
    { label = "Start focus", badge = ">", badge_color = ui.accents.green },
    { label = "Focus / break", value = p[1] .. " / " .. p[2] .. " min" },
    { label = "Long break", value = l[1] > 0 and ("every " .. l[1] .. ", " .. l[2] .. "m") or "off" },
    { label = "Task", value = ui.fit(cfg.get("study_task") or "(none)", 110) },
    { label = "Quiet focus", switch = cfg.get("study_quiet") == "1" },
  }
end

local function refresh_study()
  pomo = find_pomo()
  st = shell.study or st
  stats_s = "Today " .. span(st.minutes) .. "  " .. st.sessions .. (st.sessions == 1 and " session" or " sessions")
    .. (st.streak > 1 and ("  " .. st.streak .. "-day streak") or "")
  if pomo then
    phase_s = pomo.pomo == "work" and "FOCUS" or pomo.pomo == "long" and "LONG BREAK" or "BREAK"
    left_s = hms(pomo.left)
    task_s = pomo.pomo == "work" and (cfg.get("study_task") or "") or "Stand up, stretch, drink water"
    local every = pomo.every or 0
    round_s = every > 0 and ("Session " .. ((pomo.count or 0) % every + (pomo.pomo == "work" and 1 or 0)) .. " of " .. every)
      or ("Session " .. ((pomo.count or 0) + (pomo.pomo == "work" and 1 or 0)))
    if pomo.paused then round_s = round_s .. "  - paused" end
  end
end

local function start_study()
  local p, l = PLANS[plan], LONGS[long]
  shell.start_timer(p[1] * 60, "Pomodoro work",
    { pomo = "work", count = 0, work = p[1] * 60, rest = p[2] * 60, every = l[1], long = l[2] * 60 })
  shell.toast("Focus for " .. p[1] .. " minutes")
end

-- ---------------------------------------------------------------- refresh
local function refresh_clock()
  local t = clock.now()
  if not t.valid then
    time_s, date_s, next_s, extra_s, secs_f = "--:--", "Time not set", "Connect to Wi-Fi to set the clock", "", 0
    return
  end
  time_s = shell.format_time(t)
  secs_f = (t.s or 0) / 60
  date_s = string.format("%s, %d %s %d", DAYS[(t.wday or 0) % 7 + 1], t.day, MONTHS[t.month] or "?", t.year)
  local best, bestm
  for _, a in ipairs(alarms) do
    local m = a.on and minutes_until(a, t)
    if m and (not bestm or m < bestm) then best, bestm = a, m end
  end
  next_s = best and ("Alarm " .. shell.format_time(best) .. (best.label ~= "" and (" " .. best.label) or "")
    .. "  in " .. span(bestm)) or "No alarms on"
  local parts = {}
  if shell.snooze then parts[#parts + 1] = "Snoozed until " .. shell.snooze end
  for _, x in ipairs(shell.timers) do
    parts[#parts + 1] = (x.pomo == "work" and "Focus" or x.pomo and "Break" or x.label) .. " " .. hms(x.left)
    if #parts >= 2 then break end
  end
  extra_s = table.concat(parts, "  ")
end

local function build_laps()
  lrows = {}
  local best, worst  -- fastest and slowest lap, once there are two
  for i = 1, #laps do
    local d = laps[i] - (laps[i - 1] or 0)
    if #laps >= 2 and (not best or d < laps[best] - (laps[best - 1] or 0)) then best = i end
    if #laps >= 2 and (not worst or d > laps[worst] - (laps[worst - 1] or 0)) then worst = i end
  end
  for i = #laps, math.max(1, #laps - MAX_LAPS + 1), -1 do
    local prev = laps[i - 1] or 0
    lrows[#lrows + 1] = { label = "Lap " .. i, value = sw_text(laps[i] - prev) .. "  " .. sw_text(laps[i]),
      badge = i == best and "+" or i == worst and "-" or nil,
      badge_color = i == best and ui.accents.green or i == worst and ui.accents.red or nil }
  end
end

local function refresh()
  if tab == 1 then refresh_clock()
  elseif tab == 3 then refresh_timers()
  elseif tab == 5 then refresh_study() end
end

-- ---------------------------------------------------------------- lifecycle
function app.init(args, saved)
  if saved then
    tab = saved.tab or 1
    preset = saved.preset or 3
    sw_run, sw_start, sw_acc = saved.sw_run or false, saved.sw_start or 0, saved.sw_acc or 0
    laps = saved.laps or {}
  end
  plan = math.max(1, math.min(#PLANS, tonumber(cfg.get("study_plan")) or 1))
  long = math.max(1, math.min(#LONGS, tonumber(cfg.get("study_long")) or 2))
  if find_pomo() and not saved then tab = 5 end  -- straight to a running session
  load_alarms()
  build_alarm_rows()
  build_laps()
  build_study_rows()
  sw_s = sw_text(sw_elapsed())
  typed, edit, tick = "", nil, 0
  refresh_study()
  refresh()
end

function app.save()
  return { tab = tab, preset = preset, sw_run = sw_run, sw_start = sw_start, sw_acc = sw_acc, laps = laps }
end

function app.close()
  alarms, arows, erows, trows, tlist, lrows, srows = {}, {}, {}, {}, {}, {}, {}
  edit, pomo = nil, nil
end

function app.update(dt)
  if tab == 4 and sw_run then sw_s = sw_text(sw_elapsed()) end
  tick = tick - dt
  if tick <= 0 then
    tick = 0.25
    refresh()
  end
end

-- ---------------------------------------------------------------- drawing
local function draw_clock()
  ui.big(32, time_s, col.text, #time_s > 6 and 3 or 4)
  ui.bar(60, 66, 120, 2, secs_f, col.accent)
  ui.center(74, date_s, col.text)
  ui.card(4, 86, 232, 34, false)
  ui.center(91, ui.fit(next_s, 224), next_s:sub(1, 5) == "Alarm" and col.accent or col.muted)
  if extra_s ~= "" then ui.center(105, ui.fit(extra_s, 224), col.muted) end
  ui.footer({ { "Tab", "Alarms" }, { "Esc", "Home" } })
end

local function draw_alarms()
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
  local on_alarm = alarms[asel] ~= nil
  ui.footer(on_alarm and { { "Enter", "Edit" }, { "Spc", "On/off" }, { "X", "Delete" }, { "A", "New" } }
    or asel == #arows and { { "<>", "Snooze" }, { "A", "New alarm" }, { "Tab", "Timer" } }
    or { { "Enter", "New alarm" }, { "Tab", "Timer" }, { "Esc", "Home" } })
end

local function draw_timer()
  ui.big(32, tmins_s, typed ~= "" and col.accent or col.text, 3)
  -- presets as chips; typed minutes replace them
  local x = 6
  for i, m in ipairs(PRESETS) do
    local s = tostring(m)
    local w = #s * 6 + 8
    local on = typed == "" and i == preset
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

local function draw_watch()
  ui.big(36, sw_s, sw_run and col.accent or col.text, 3)
  if #lrows == 0 then
    ui.center(84, sw_run and "Running - L marks a lap" or (sw_acc > 0 and "Stopped" or "Enter starts"), col.muted)
  else
    ltop = ui.list(lrows, 1, ltop, 4, 64, 230, 14, 4)
  end
  ui.footer({ { "Enter", sw_run and "Stop" or "Start" }, { "L", "Lap" }, { "R", "Reset" }, { "Tab", "Study" } })
end

local function draw_study()
  if pomo then
    local work = pomo.pomo == "work"
    local c = pomo.paused and col.muted or work and col.accent or col.good
    ui.center(33, phase_s, c)
    if task_s ~= "" then ui.center(45, ui.fit(task_s, 220), col.muted) end
    ui.big(57, left_s, col.text, 3)
    ui.bar(20, 84, 200, 6, 1 - pomo.left / math.max(1, pomo.total), c)
    ui.center(95, round_s, col.muted)
    ui.center(108, ui.fit(stats_s, 228), col.muted)
    ui.footer({ { "Spc", pomo.paused and "Resume" or "Pause" }, { "S", "Skip" }, { "X", "Stop" }, { "Tab", "Clock" } })
    return
  end
  ui.list(srows, ssel, 1, 4, 33, 230, 15, 5)
  ui.center(112, ui.fit(stats_s, 228), col.muted)
  ui.footer(ssel == 1 and { { "Enter", "Start" }, { "Up/Dn", "Setting" }, { "Tab", "Clock" } }
    or { { "<>", "Change" }, { "Enter", "Edit" }, { "Up/Dn", "Setting" } })
end

function app.draw()
  ui.tabs(TABS, tab, 16)
  if tab == 1 then draw_clock()
  elseif tab == 2 then draw_alarms()
  elseif tab == 3 then draw_timer()
  elseif tab == 4 then draw_watch()
  else draw_study() end
end

-- ---------------------------------------------------------------- keys
local function key_alarms(k, d)
  local c = not k.ctrl and not k.fn and k.text
  if edit then return key_edit(k, d) end
  local a = alarms[asel]
  if d == "up" then asel = math.max(1, asel - 1)
  elseif d == "down" then asel = math.min(#arows, asel + 1)
  elseif c == "a" then open_editor(nil)
  elseif asel == #arows and (d == "left" or d == "right") then  -- snooze length
    local steps = { 1, 2, 3, 5, 10, 15 }
    local k2 = 1
    for i, m in ipairs(steps) do if m == snooze_min() then k2 = i end end
    cfg.set("snooze", steps[math.max(1, math.min(#steps, k2 + (d == "left" and -1 or 1)))])
    build_alarm_rows()
  elseif k.key == "enter" then
    if a then open_editor(asel) elseif asel == #arows - 1 then open_editor(nil) end
  elseif a and (c == " " or k.key == "space") then
    a.on = not a.on
    save_alarms()
    shell.toast(shell.format_time(a) .. (a.on and " on" or " off"))
  elseif a and c == "x" then
    table.remove(alarms, asel)
    save_alarms()
    shell.toast("Alarm deleted")
  else
    return false
  end
  return true
end

local function key_timer(k, d)
  local c = not k.ctrl and not k.fn and k.text
  if c and c:match("^%d$") then
    if #typed >= 3 then typed = "" end
    typed = typed .. c
    if tonumber(typed) == 0 then typed = "" end
  elseif k.key == "backspace" then typed = typed:sub(1, -2)
  elseif d == "left" or d == "right" then
    typed = ""
    preset = math.max(1, math.min(#PRESETS, preset + (d == "left" and -1 or 1)))
  elseif d == "up" then tsel = math.max(1, tsel - 1)
  elseif d == "down" then tsel = math.min(#trows, tsel + 1)
  elseif k.key == "enter" then
    local m = tmins()
    typed = ""
    shell.start_timer(m * 60, m .. " min timer")
    shell.toast("Timer started: " .. m .. " min")
    refresh_timers()
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
  refresh_timers()
  return true
end

local function key_watch(k)
  local c = not k.ctrl and not k.fn and k.text
  if k.key == "enter" or k.key == "space" or c == " " then
    if sw_run then sw_acc = sw_acc + sys.millis() - sw_start; sw_run = false
    else sw_start = sys.millis(); sw_run = true end
    sw_s = sw_text(sw_elapsed())
  elseif c == "l" then
    if not sw_run then shell.toast("Start the stopwatch first"); return true end
    if #laps >= MAX_LAPS then table.remove(laps, 1) end
    laps[#laps + 1] = sw_elapsed()
    build_laps()
    ltop = 1
  elseif c == "r" then
    sw_run, sw_acc, laps = false, 0, {}
    build_laps()
    sw_s = sw_text(0)
    shell.toast("Stopwatch reset")
  else
    return false
  end
  return true
end

local function key_study(k, d)
  local c = not k.ctrl and not k.fn and k.text
  local p = find_pomo()
  if p then
    if c == " " or k.key == "space" then
      shell.pause_timer(p, not p.paused)
      shell.toast(p.paused and "Resumed" or "Paused")
    elseif c == "s" then
      shell.finish_timer(p)
      shell.toast("Skipping to the next phase")
    elseif c == "x" then
      shell.cancel_timer(p)
      shell.toast("Study session stopped")
    else
      return false
    end
    refresh_study()
    return true
  end
  if d == "up" then ssel = math.max(1, ssel - 1)
  elseif d == "down" then ssel = math.min(#srows, ssel + 1)
  elseif ssel == 1 and (k.key == "enter" or c == " ") then start_study()
  elseif ssel == 2 and (d == "left" or d == "right" or k.key == "enter") then
    plan = (plan - 1 + (d == "left" and -1 or 1)) % #PLANS + 1
    cfg.set("study_plan", plan)
  elseif ssel == 3 and (d == "left" or d == "right" or k.key == "enter") then
    long = (long - 1 + (d == "left" and -1 or 1)) % #LONGS + 1
    cfg.set("study_long", long)
  elseif ssel == 4 and k.key == "enter" then
    shell.prompt("What are you studying?", cfg.get("study_task") or "", function(s)
      if s then cfg.set("study_task", s ~= "" and s:sub(1, 30) or nil); build_study_rows() end
    end)
  elseif ssel == 5 and (k.key == "enter" or c == " " or d == "left" or d == "right") then
    local on = cfg.get("study_quiet") ~= "1"
    cfg.set("study_quiet", on and "1" or nil)
    shell.toast(on and "Quiet focus on: no alert sounds" or "Quiet focus off", 2)
  else
    return false
  end
  build_study_rows()
  refresh_study()
  return true
end

function app.key(k)
  if k.key == "tab" and not edit then
    tab = k.shift and (tab - 2) % #TABS + 1 or tab % #TABS + 1
    typed, tick = "", 0
    refresh()
    return true
  end
  local d = ui.nav(k)
  if tab == 2 then return key_alarms(k, d) end
  if k.key == "esc" then
    if tab == 3 and typed ~= "" then typed = ""; refresh_timers(); return true end
    return false
  end
  if tab == 3 then return key_timer(k, d)
  elseif tab == 4 then return key_watch(k)
  elseif tab == 5 then return key_study(k, d) end
  return false
end

return app
