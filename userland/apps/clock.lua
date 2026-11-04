-- Clock: time and date, daily alarms, countdown timers, a stopwatch and
-- Pomodoro. Timers and alarms belong to the shell, so they keep running after
-- you leave; this app only shows and changes them.
local col = ui.col
local app = { title = "Clock", icon = "clock", color = "orange", order = 20, category = "tools" }

local TABS = { "Clock", "Alarms", "Timer", "Watch", "Pomo" }
local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
  "October", "November", "December" }
local MAX_ALARMS = 12
local MAX_LAPS = 30
local WORK, REST = 25 * 60, 5 * 60

local tab = 1
local tick = 0           -- seconds until the shown text is rebuilt

-- Clock tab
local time_s, date_s, info_s = "--:--", "", ""

-- Alarms tab: { {h=, m=, label=} }, sorted by time
local alarms, arows, asel, atop = {}, {}, 1, 1

-- Timer tab
local mins, typed = 5, ""
local mins_s, start_s = "", ""
local trows, tlist, tsel, ttop = {}, {}, 1, 1

-- Stopwatch (times in ms from sys.millis())
local sw_run, sw_start, sw_acc = false, 0, 0
local laps, lrows, ltop = {}, {}, 1
local sw_s = "00:00.00"

-- Pomodoro: the running handle lives in shell.timers with fields pomo/count
local pomo, pomo_count = nil, 0
local pomo_s, done_s = "", "Completed: 0"

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

local function show_mins()
  mins_s = mins .. (typed ~= "" and "_" or "") .. " min"
  start_s = "Enter starts a " .. mins .. " min timer"
end

local function sw_elapsed()
  return sw_acc + (sw_run and (sys.millis() - sw_start) or 0)
end

-- ---------------------------------------------------------------- alarms
local function load_alarms()
  alarms = {}
  for item in (cfg.get("alarms") or ""):gmatch("[^;]+") do
    local h, m, label = item:match("^(%d%d):(%d%d)|?(.*)$")
    h, m = tonumber(h), tonumber(m)
    if h and h < 24 and m < 60 then alarms[#alarms + 1] = { h = h, m = m, label = label } end
  end
end

local function build_alarm_rows()
  arows = {}
  for i, a in ipairs(alarms) do
    arows[i] = { label = shell.format_time(a), value = a.label ~= "" and a.label or nil }
  end
  asel = math.max(1, math.min(asel, #arows))
end

local function save_alarms()
  table.sort(alarms, function(a, b) return a.h * 60 + a.m < b.h * 60 + b.m end)
  local parts = {}
  for i, a in ipairs(alarms) do parts[i] = string.format("%02d:%02d|%s", a.h, a.m, a.label) end
  cfg.set("alarms", #parts > 0 and table.concat(parts, ";") or nil)
  build_alarm_rows()
end

-- "7:30 Wake up", "07:30", "6:05pm Gym", "6:05 PM". Returns h, m, label or nil.
local function parse_alarm(s)
  local h, m, rest = (s or ""):match("^%s*(%d%d?):(%d%d)%s*(.-)%s*$")
  h, m = tonumber(h), tonumber(m)
  if not h then return nil end
  local ap, tail = rest:match("^([aApP])%.?[mM]%.?$")
  if not ap then ap, tail = rest:match("^([aApP])%.?[mM]%.?%s+(.*)$") end
  if ap then
    if h < 1 or h > 12 then return nil end
    h = h % 12 + ((ap == "p" or ap == "P") and 12 or 0)
    rest = tail or ""
  end
  if h > 23 or m > 59 then return nil end
  rest = rest:gsub("[;|]", " "):sub(1, 24)
  return h, m, rest
end

local function add_alarm()
  if #alarms >= MAX_ALARMS then shell.toast("At most " .. MAX_ALARMS .. " alarms"); return end
  shell.prompt("Alarm: HH:MM label", "", function(s)
    if not s or s:match("^%s*$") then return end
    local h, m, label = parse_alarm(s)
    if not h then shell.toast("Use HH:MM, e.g. 07:30 Wake up", 3); return end
    for _, a in ipairs(alarms) do
      if a.h == h and a.m == m and a.label == label then shell.toast("That alarm already exists"); return end
    end
    alarms[#alarms + 1] = { h = h, m = m, label = label }
    save_alarms()
    for i, a in ipairs(alarms) do if a.h == h and a.m == m and a.label == label then asel = i end end
    shell.toast("Alarm set for " .. shell.format_time({ h = h, m = m }))
  end)
end

local function delete_alarm()
  local a = alarms[asel]
  if not a then return end
  table.remove(alarms, asel)
  save_alarms()
  shell.toast("Alarm deleted")
end

-- ---------------------------------------------------------------- pomodoro
-- Starts one phase. The done callback starts the next one even when this app
-- is closed, so it only uses its own arguments and the shell.
local function pomo_phase(phase, count)
  local work = phase == "work"
  local h = shell.start_timer(work and WORK or REST, work and "Pomodoro work" or "Pomodoro break")
  h.pomo, h.count = phase, count
  h.done = function() pomo_phase(work and "break" or "work", work and count + 1 or count) end
  return h
end

local function find_pomo()
  for _, t in ipairs(shell.timers) do if t.pomo then return t end end
end

-- ---------------------------------------------------------------- refresh
local function refresh_clock()
  local t = clock.now()
  if t.valid then
    time_s = shell.format_time(t)
    date_s = string.format("%s, %d %s %d", DAYS[(t.wday or 0) % 7 + 1], t.day, MONTHS[t.month] or "?", t.year)
    local nowm, best, bestd = t.h * 60 + t.m, nil, 1e9
    for _, a in ipairs(alarms) do
      local d = (a.h * 60 + a.m - nowm - 1) % 1440
      if d < bestd then best, bestd = a, d end
    end
    info_s = best and ("Next alarm " .. shell.format_time(best) .. (best.label ~= "" and (" " .. best.label) or "")) or ""
  else
    time_s, date_s, info_s = "--:--", "Time not set", "Connect to Wi-Fi to set the clock"
  end
  local n = #shell.timers
  if n > 0 and t.valid then info_s = (info_s ~= "" and (info_s .. "  ") or "") .. n .. (n == 1 and " timer" or " timers") end
end

local function refresh_timers()
  tlist, trows = {}, {}
  for _, t in ipairs(shell.timers) do
    tlist[#tlist + 1] = t
    trows[#trows + 1] = { label = t.label, value = hms(t.left) }
  end
  tsel = math.max(1, math.min(tsel, #trows))
end

local function refresh_pomo()
  pomo = find_pomo()
  if pomo then
    pomo_count = pomo.count or 0
    pomo_s = hms(pomo.left)
  end
  done_s = "Completed: " .. pomo_count
end

local function build_laps()
  lrows = {}
  for i = #laps, math.max(1, #laps - MAX_LAPS + 1), -1 do
    local prev = laps[i - 1] or 0
    lrows[#lrows + 1] = { label = "Lap " .. i, value = sw_text(laps[i] - prev) .. "  " .. sw_text(laps[i]) }
  end
end

local function refresh()
  if tab == 1 then refresh_clock()
  elseif tab == 3 then refresh_timers()
  elseif tab == 5 then refresh_pomo() end
end

-- ---------------------------------------------------------------- lifecycle
function app.init(args, saved)
  if saved then
    tab = saved.tab or 1
    mins = saved.mins or 5
    sw_run, sw_start, sw_acc = saved.sw_run or false, saved.sw_start or 0, saved.sw_acc or 0
    laps = saved.laps or {}
    pomo_count = saved.pomo_count or 0
  end
  load_alarms()
  build_alarm_rows()
  build_laps()
  sw_s = sw_text(sw_elapsed())
  typed = ""
  show_mins()
  tick = 0
  refresh_pomo()
  refresh()
end

function app.save()
  return { tab = tab, mins = mins, sw_run = sw_run, sw_start = sw_start, sw_acc = sw_acc, laps = laps,
    pomo_count = pomo_count }
end

function app.close()
  alarms, arows, trows, tlist, lrows = {}, {}, {}, {}, {}
  pomo = nil
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
  ui.big(44, time_s, col.text, #time_s > 6 and 3 or 4)
  ui.center(84, date_s, col.text)
  if info_s ~= "" then ui.center(100, ui.fit(info_s, 228), col.muted) end
  ui.footer({ { "Tab", "Alarms" }, { "Esc", "Home" } })
end

local function draw_alarms()
  if #arows == 0 then
    ui.empty("clock", "No alarms", "Press A to add one")
  else
    atop = ui.list(arows, asel, atop, 4, 34, 230, 15, 6)
  end
  ui.footer({ { "A", "Add" }, { "X", "Delete" }, { "Tab", "Mode" }, { "Esc", "Home" } })
end

local function draw_timer()
  ui.big(38, mins_s, typed ~= "" and col.accent or col.text, 3)
  gfx.text(16, 42, "<", col.muted, 2)
  gfx.text(212, 42, ">", col.muted, 2)
  if #trows == 0 then
    ui.center(84, "No timers running", col.muted)
    ui.center(96, start_s, col.muted)
  else
    ttop = ui.list(trows, tsel, ttop, 4, 64, 230, 15, 4)
  end
  ui.footer({ { "Enter", "Start" }, { "<>", "Min" }, { "X", "Cancel" }, { "Esc", "Home" } })
end

local function draw_watch()
  ui.big(38, sw_s, sw_run and col.accent or col.text, 3)
  if #lrows == 0 then
    ui.center(84, sw_run and "Running" or (sw_acc > 0 and "Stopped" or "Ready"), col.muted)
  else
    ltop = ui.list(lrows, 1, ltop, 4, 64, 230, 15, 4)
  end
  ui.footer({ { "Enter", sw_run and "Stop" or "Start" }, { "L", "Lap" }, { "R", "Reset" }, { "Esc", "Home" } })
end

local function draw_pomo()
  if pomo then
    local work = pomo.pomo == "work"
    ui.center(36, work and "FOCUS" or "BREAK", work and col.accent or col.good)
    ui.big(50, pomo_s, col.text, 3)
    ui.bar(20, 82, 200, 6, 1 - pomo.left / math.max(1, pomo.total), work and col.accent or col.good)
    ui.center(96, done_s, col.muted)
    ui.footer({ { "X", "Stop" }, { "Tab", "Mode" }, { "Esc", "Home" } })
  else
    ui.empty("clock", "Pomodoro", "25 min focus, 5 min break")
    ui.center(96, done_s, col.muted)
    ui.footer({ { "Enter", "Start" }, { "Tab", "Mode" }, { "Esc", "Home" } })
  end
end

function app.draw()
  ui.tabs(TABS, tab, 16)
  if tab == 1 then draw_clock()
  elseif tab == 2 then draw_alarms()
  elseif tab == 3 then draw_timer()
  elseif tab == 4 then draw_watch()
  else draw_pomo() end
end

-- ---------------------------------------------------------------- keys
local function key_timer(k, d)
  local c = k.text
  if c and c:match("^%d$") and not k.ctrl and not k.fn then
    if #typed >= 3 then typed = "" end
    typed = typed .. c
    mins = math.max(1, math.min(999, tonumber(typed)))
  elseif k.key == "backspace" then
    typed = typed:sub(1, -2)
    mins = math.max(1, tonumber(typed) or 1)
  elseif d == "left" then typed = ""; mins = math.max(1, mins - 1)
  elseif d == "right" then typed = ""; mins = math.min(999, mins + 1)
  elseif d == "up" then tsel = math.max(1, tsel - 1)
  elseif d == "down" then tsel = math.min(#trows, tsel + 1)
  elseif k.key == "enter" then
    typed = ""
    shell.start_timer(mins * 60, "Timer")
    shell.toast("Timer started: " .. mins .. " min")
    refresh_timers()
    tsel = #trows
  elseif c == "x" then
    local t = tlist[tsel]
    if not t then shell.toast("No timer selected"); return true end
    shell.cancel_timer(t)
    shell.toast("Cancelled " .. t.label)
    refresh_timers()
  else
    return false
  end
  show_mins()
  return true
end

local function key_watch(k)
  local c = k.text
  if k.key == "enter" or k.key == "space" or c == " " then
    if sw_run then
      sw_acc = sw_acc + sys.millis() - sw_start
      sw_run = false
    else
      sw_start = sys.millis()
      sw_run = true
    end
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

local function key_pomo(k)
  if k.key == "enter" then
    if find_pomo() then shell.toast("Already running - X stops it"); return true end
    pomo_phase("work", pomo_count)
    shell.toast("Focus for 25 minutes")
  elseif k.text == "x" then
    local p = find_pomo()
    if not p then shell.toast("Pomodoro is not running"); return true end
    shell.cancel_timer(p)
    shell.toast("Pomodoro stopped")
  else
    return false
  end
  refresh_pomo()
  if not find_pomo() then pomo = nil end
  return true
end

function app.key(k)
  if k.key == "tab" then
    tab = k.shift and (tab - 2) % #TABS + 1 or tab % #TABS + 1
    typed = ""
    show_mins()
    tick = 0
    refresh()
    return true
  end
  if k.key == "esc" then
    if tab == 3 and typed ~= "" then typed = ""; show_mins(); return true end
    return false
  end
  local d = ui.nav(k)
  if tab == 2 then
    if d == "up" then asel = math.max(1, asel - 1)
    elseif d == "down" then asel = math.min(#arows, asel + 1)
    elseif k.text == "a" or (k.key == "enter" and #alarms == 0) then add_alarm()
    elseif k.text == "x" then delete_alarm()
    else return false end
    return true
  elseif tab == 3 then return key_timer(k, d)
  elseif tab == 4 then return key_watch(k)
  elseif tab == 5 then return key_pomo(k)
  end
  return false
end

return app
