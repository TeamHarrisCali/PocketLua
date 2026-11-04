-- Steps: a pedometer from the IMU. It counts only while this app is open.
-- Each frame: acceleration magnitude -> low-pass (smooth) minus a slow
-- gravity estimate (high-pass) -> a step is a rise above the threshold at
-- least 0.3 s after the last one. Today's count is kept in cfg.
local col = ui.col
local app = { title = "Steps", icon = "steps", color = "teal", order = 53, category = "tools" }
app.help = {
  { "-=", "Goal -/+ 500" },
  { "S", "Sensitivity" },
  { "R", "Reset count" },
  { "Esc", "Back" },
}

local MIN_GAP = 0.3                       -- seconds between steps (max ~3.3 steps/s)
local SENS = { { "Low", 0.20 }, { "Med", 0.13 }, { "High", 0.08 } }  -- threshold in g

local n, day, goal, stride = 0, nil, 6000, 0.75
local sens = 2
local lp, grav = 1, 1                     -- filtered magnitude, gravity baseline
local armed, since = true, 1              -- since: seconds since the last step
local dirty, save_left, day_left = false, 15, 0
local shown = { n = "0", pct = "0%", dist = "0.00 km", goal = "" }
local frac = 0

local function today()
  local t = clock.now()
  if not t or not t.valid then return nil end
  return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

local function persist()
  if day then cfg.set("steps_day", day) end
  cfg.set("steps_n", tostring(n))
  dirty = false
end

local function refresh()
  frac = goal > 0 and n / goal or 0
  shown.n = tostring(n)
  shown.pct = string.format("%d%% of %d", math.floor(frac * 100), goal)
  shown.dist = string.format("%.2f km", n * stride / 1000)
  shown.goal = "Sens " .. SENS[sens][1] .. "  Stride " .. string.format("%.2f m", stride)
end

-- Starts a new count when the date has changed.
local function check_day()
  local d = today()
  if d and d ~= day then
    day, n = d, 0               -- yesterday's count is simply replaced
    persist()
    refresh()
  end
end

function app.init()
  goal = math.max(500, math.floor(tonumber(cfg.get("steps_goal")) or 6000))
  stride = tonumber(cfg.get("steps_stride")) or 0.75
  sens = math.max(1, math.min(#SENS, math.floor(tonumber(cfg.get("steps_sens")) or 2)))
  day = cfg.get("steps_day")
  n = math.floor(tonumber(cfg.get("steps_n")) or 0)
  check_day()
  lp, grav, armed, since = 1, 1, true, 1
  refresh()
end

function app.update(dt)
  since = since + dt
  local ok, v = pcall(imu.read)
  if ok and v then
    local m = math.sqrt(v.ax * v.ax + v.ay * v.ay + v.az * v.az)
    lp = lp + (m - lp) * math.min(1, dt / 0.06)       -- smooth out jitter (~2.6 Hz)
    grav = grav + (m - grav) * math.min(1, dt / 1.0)  -- gravity and slow tilt
    local s = lp - grav
    local th = SENS[sens][2]
    if armed and s > th and since >= MIN_GAP then
      n, since, armed, dirty = n + 1, 0, false, true
      if n == goal then shell.notify("Step goal reached", n .. " steps today") end
      refresh()
    elseif not armed and s < th * 0.3 then
      armed = true
    end
  end
  save_left = save_left - dt
  if save_left <= 0 then
    save_left = 15
    if dirty then persist() end
  end
  day_left = day_left - dt
  if day_left <= 0 then day_left = 10; check_day() end
end

function app.draw()
  ui.center(18, "Counting while open", col.muted)
  ui.big(32, shown.n, col.accent, 4)
  ui.bar(20, 70, 200, 8, frac, frac >= 1 and col.good or col.accent)
  ui.text(20, 84, shown.pct, col.text)
  ui.right(220, 84, shown.dist, col.text)
  ui.center(104, shown.goal, col.muted)
  ui.footer({ { "+/-", "Goal" }, { "S", "Sens" }, { "R", "Reset" }, { "Esc", "Back" } })
end

function app.key(k)
  local c = not k.fn and not k.ctrl and k.text and k.text:lower()
  if c == "+" or c == "=" then
    goal = math.min(50000, goal + 500)
    cfg.set("steps_goal", tostring(goal))
    shell.toast("Goal " .. goal)
  elseif c == "-" or c == "_" then
    goal = math.max(500, goal - 500)
    cfg.set("steps_goal", tostring(goal))
    shell.toast("Goal " .. goal)
  elseif c == "s" then
    sens = sens % #SENS + 1
    cfg.set("steps_sens", tostring(sens))
    shell.toast("Sensitivity " .. SENS[sens][1])
  elseif c == "r" then
    shell.confirm("Reset steps", "Set today's count back to 0?", function(yes)
      if not yes then return end
      n = 0
      persist()
      refresh()
      shell.toast("Steps reset")
    end)
  else
    return k.key ~= "esc"
  end
  refresh()
  return true
end

function app.close()
  persist()
end

return app
