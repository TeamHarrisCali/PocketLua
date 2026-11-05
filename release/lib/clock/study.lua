-- Clock > Study: Pomodoro (focus / break, a long break every few sessions),
-- a task label, quiet focus, and today's minutes, sessions and streak. The
-- phases run in the shell; this tab starts, pauses, skips and stops them.
return function(C, S)
local col = ui.col
local PLANS = { { 25, 5 }, { 50, 10 }, { 90, 15 }, { 15, 3 } }  -- focus / break minutes
local LONGS = { { 0, 0 }, { 4, 15 }, { 4, 20 }, { 3, 15 } }     -- every n sessions, minutes

local plan, long = 1, 2
local srows, ssel = {}, 1
local pomo = nil
local phase_s, left_s, task_s, round_s, stats_s = "", "", "", "", ""

local function find_pomo()
  for _, t in ipairs(shell.timers) do if t.pomo then return t end end
end

local function build_rows()
  local p, l = PLANS[plan], LONGS[long]
  srows = {
    { label = "Start focus", badge = ">", badge_color = ui.accents.green },
    { label = "Focus / break", value = p[1] .. " / " .. p[2] .. " min" },
    { label = "Long break", value = l[1] > 0 and ("every " .. l[1] .. ", " .. l[2] .. "m") or "off" },
    { label = "Task", value = ui.fit(cfg.get("study_task") or "(none)", 110) },
    { label = "Quiet focus", switch = cfg.get("study_quiet") == "1" },
  }
end

local function refresh()
  pomo = find_pomo()
  local st = shell.study or { minutes = 0, sessions = 0, streak = 0 }
  stats_s = "Today " .. C.span(st.minutes) .. "  " .. st.sessions .. (st.sessions == 1 and " session" or " sessions")
    .. (st.streak > 1 and ("  " .. st.streak .. "-day streak") or "")
  if not pomo then return end
  phase_s = pomo.pomo == "work" and "FOCUS" or pomo.pomo == "long" and "LONG BREAK" or "BREAK"
  left_s = C.hms(pomo.left)
  task_s = pomo.pomo == "work" and (cfg.get("study_task") or "") or "Stand up, stretch, drink water"
  local every, n = pomo.every or 0, (pomo.count or 0) + (pomo.pomo == "work" and 1 or 0)
  round_s = every > 0 and ("Session " .. ((n - 1) % every + 1) .. " of " .. every) or ("Session " .. n)
  if pomo.paused then round_s = round_s .. "  - paused" end
end

local tab = { refresh = refresh }

function tab.init()
  plan = math.max(1, math.min(#PLANS, tonumber(cfg.get("study_plan")) or 1))
  long = math.max(1, math.min(#LONGS, tonumber(cfg.get("study_long")) or 2))
  build_rows()
  refresh()
end

function tab.close() srows, pomo = {}, nil end

function tab.draw()
  if pomo then
    local c = pomo.paused and col.muted or pomo.pomo == "work" and col.accent or col.good
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

function tab.key(k, d)
  local c = not k.ctrl and not k.fn and k.text
  if k.key == "esc" then return false end
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
    refresh()
    return true
  end
  if d == "up" then ssel = math.max(1, ssel - 1)
  elseif d == "down" then ssel = math.min(#srows, ssel + 1)
  elseif ssel == 1 and (k.key == "enter" or c == " ") then
    local pl, l = PLANS[plan], LONGS[long]
    shell.start_timer(pl[1] * 60, "Pomodoro work",
      { pomo = "work", count = 0, work = pl[1] * 60, rest = pl[2] * 60, every = l[1], long = l[2] * 60 })
    shell.toast("Focus for " .. pl[1] .. " minutes")
  elseif ssel == 2 and (d == "left" or d == "right" or k.key == "enter") then
    plan = (plan - 1 + (d == "left" and -1 or 1)) % #PLANS + 1
    cfg.set("study_plan", plan)
  elseif ssel == 3 and (d == "left" or d == "right" or k.key == "enter") then
    long = (long - 1 + (d == "left" and -1 or 1)) % #LONGS + 1
    cfg.set("study_long", long)
  elseif ssel == 4 and k.key == "enter" then
    shell.prompt("What are you studying?", cfg.get("study_task") or "", function(s)
      if s then cfg.set("study_task", s ~= "" and s:sub(1, 30) or nil); build_rows() end
    end)
  elseif ssel == 5 and (k.key == "enter" or c == " " or d == "left" or d == "right") then
    local on = cfg.get("study_quiet") ~= "1"
    cfg.set("study_quiet", on and "1" or nil)
    shell.toast(on and "Quiet focus on: no alert sounds" or "Quiet focus off", 2)
  else
    return false
  end
  build_rows()
  refresh()
  return true
end

return tab
end
