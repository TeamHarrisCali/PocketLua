-- Clock: time and date, alarms (repeat days, on/off, snooze), countdown
-- timers, a stopwatch and Study (Pomodoro with long breaks and daily stats).
-- Timers and alarms belong to the shell: they go off whatever app is open,
-- ring full screen until stopped or snoozed, and wake the device from sleep.
-- This app only shows and changes them. Each tab but the clock face lives in
-- lib/clock/ and is loaded while it is open (all of it at once did not fit).
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

-- What the tabs share and what is kept while the app is closed (app.save).
local S = { tab = 1, preset = 3, sw_run = false, sw_start = 0, sw_acc = 0, laps = {} }
local C = {}  -- helpers for the tab modules
local tabmod = nil  -- the open tab's module (tabs 2-5)
local tick = 0
local time_s, date_s, secs_f, next_s, extra_s = "--:--", "", 0, "", ""

-- ---------------------------------------------------------------- shared helpers
function C.hms(sec)
  sec = math.max(0, math.ceil(sec))
  local h, m, s = sec // 3600, sec // 60 % 60, sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%02d:%02d", m, s)
end

function C.span(mins)  -- "7h 12m", "45m"
  if mins >= 60 then return string.format("%dh %dm", mins // 60, mins % 60) end
  return mins .. "m"
end

C.REPEATS = { d = "Daily", w = "Weekdays", e = "Weekends", o = "Once" }

-- cfg "alarms": "HH:MM|label|flags;..." (flags: "1"/"0" on, then d/w/e/o)
function C.load_alarms()
  local out = {}
  for item in (cfg.get("alarms") or ""):gmatch("[^;]+") do
    local h, m, label, flags = item:match("^(%d%d):(%d%d)|?([^|]*)|?(.*)$")
    h, m = tonumber(h), tonumber(m)
    if h and h < 24 and m < 60 then
      local rep = flags:sub(2, 2)
      out[#out + 1] = { h = h, m = m, label = label or "", on = flags:sub(1, 1) ~= "0",
        rep = C.REPEATS[rep] and rep or "d" }
    end
  end
  return out
end

-- Minutes from now (h, m, weekday) until alarm a next goes off, or nil.
function C.minutes_until(a, t)
  for d = 0, 7 do
    local wd = ((t.wday or 0) + d) % 7
    local ok = a.rep == "w" and wd >= 1 and wd <= 5 or a.rep == "e" and (wd == 0 or wd == 6)
      or a.rep == "d" or a.rep == "o"
    local mins = d * 1440 + a.h * 60 + a.m - (t.h * 60 + t.m)
    if ok and mins > 0 then return mins end
  end
end

-- ---------------------------------------------------------------- tabs
-- Literal requires, so tools/release.py lists these libraries with the app.
local function load_tab(i)
  if i == 2 then return require("clock/alarms")
  elseif i == 3 then return require("clock/timer")
  elseif i == 4 then return require("clock/watch")
  elseif i == 5 then return require("clock/study") end
end
local NAMES = { nil, "clock/alarms", "clock/timer", "clock/watch", "clock/study" }

local function open_tab(i)
  if tabmod then
    if tabmod.close then tabmod.close() end
    unload(NAMES[S.tab])
    tabmod = nil
    collectgarbage("collect")  -- the old tab's code is garbage now
  end
  S.tab = i
  if i > 1 then
    tabmod = load_tab(i)(C, S)
    if tabmod.init then tabmod.init() end
  end
  tick = 0
end

-- ---------------------------------------------------------------- clock face
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
  for _, a in ipairs(C.load_alarms()) do
    local m = a.on and C.minutes_until(a, t)
    if m and (not bestm or m < bestm) then best, bestm = a, m end
  end
  next_s = best and ("Alarm " .. shell.format_time(best) .. (best.label ~= "" and (" " .. best.label) or "")
    .. "  in " .. C.span(bestm)) or "No alarms on"
  local parts = {}
  if shell.snooze then parts[#parts + 1] = "Snoozed until " .. shell.snooze end
  for _, x in ipairs(shell.timers) do
    parts[#parts + 1] = (x.pomo == "work" and "Focus" or x.pomo and "Break" or x.label) .. " " .. C.hms(x.left)
    if #parts >= 2 then break end
  end
  extra_s = table.concat(parts, "  ")
end

local function draw_clock()
  ui.big(32, time_s, col.text, #time_s > 6 and 3 or 4)
  ui.bar(60, 66, 120, 2, secs_f, col.accent)
  ui.center(74, date_s, col.text)
  ui.card(4, 86, 232, 34, false)
  ui.center(91, ui.fit(next_s, 224), next_s:sub(1, 5) == "Alarm" and col.accent or col.muted)
  if extra_s ~= "" then ui.center(105, ui.fit(extra_s, 224), col.muted) end
  ui.footer({ { "Tab", "Alarms" }, { "Esc", "Home" } })
end

-- ---------------------------------------------------------------- lifecycle
function app.init(args, saved)
  if saved then
    for k, v in pairs(saved) do S[k] = v end
  end
  local tab = S.tab
  if not saved then
    tab = 1
    for _, t in ipairs(shell.timers) do if t.pomo then tab = 5 end end  -- straight to a running session
  end
  S.tab = 1
  open_tab(tab)
  refresh_clock()
end

function app.save()
  return { tab = S.tab, preset = S.preset, sw_run = S.sw_run, sw_start = S.sw_start, sw_acc = S.sw_acc, laps = S.laps }
end

function app.close()
  if tabmod and tabmod.close then tabmod.close() end
  tabmod = nil
end

function app.update(dt)
  if tabmod and tabmod.update then tabmod.update(dt) end
  tick = tick - dt
  if tick <= 0 then
    tick = 0.25
    if tabmod then
      if tabmod.refresh then tabmod.refresh() end
    else
      refresh_clock()
    end
  end
end

function app.draw()
  ui.tabs(TABS, S.tab, 16)
  if tabmod then tabmod.draw() else draw_clock() end
end

function app.key(k)
  if k.key == "tab" and not (tabmod and tabmod.busy and tabmod.busy()) then
    open_tab(k.shift and (S.tab - 2) % #TABS + 1 or S.tab % #TABS + 1)
    return true
  end
  if tabmod then return tabmod.key(k, ui.nav(k)) end
  return false
end

return app
