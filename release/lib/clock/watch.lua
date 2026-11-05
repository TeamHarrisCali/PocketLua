-- Clock > Watch: a stopwatch with laps (fastest and slowest marked). Its
-- times live in S, so it keeps running while other tabs are open.
return function(C, S)
local col = ui.col
local MAX_LAPS = 30
local lrows, ltop = {}, 1
local sw_s = "00:00.00"

local function text(ms)
  local cs = ms // 10
  local h, m, s, c = cs // 360000, cs // 6000 % 60, cs // 100 % 60, cs % 100
  if h > 0 then return string.format("%d:%02d:%02d.%d", h, m, s, c // 10) end
  return string.format("%02d:%02d.%02d", m, s, c)
end

local function elapsed() return S.sw_acc + (S.sw_run and (sys.millis() - S.sw_start) or 0) end

local function build_laps()
  local laps = S.laps
  lrows = {}
  local best, worst  -- fastest and slowest lap, once there are two
  for i = 1, #laps do
    local d = laps[i] - (laps[i - 1] or 0)
    if #laps >= 2 and (not best or d < laps[best] - (laps[best - 1] or 0)) then best = i end
    if #laps >= 2 and (not worst or d > laps[worst] - (laps[worst - 1] or 0)) then worst = i end
  end
  for i = #laps, math.max(1, #laps - MAX_LAPS + 1), -1 do
    local prev = laps[i - 1] or 0
    lrows[#lrows + 1] = { label = "Lap " .. i, value = text(laps[i] - prev) .. "  " .. text(laps[i]),
      badge = i == best and "+" or i == worst and "-" or nil,
      badge_color = i == best and ui.accents.green or i == worst and ui.accents.red or nil }
  end
end

local tab = {}

function tab.init()
  build_laps()
  sw_s = text(elapsed())
end

function tab.close() lrows = {} end

function tab.update() if S.sw_run then sw_s = text(elapsed()) end end

function tab.draw()
  ui.big(36, sw_s, S.sw_run and col.accent or col.text, 3)
  if #lrows == 0 then
    ui.center(84, S.sw_run and "Running - L marks a lap" or (S.sw_acc > 0 and "Stopped" or "Enter starts"), col.muted)
  else
    ltop = ui.list(lrows, 1, ltop, 4, 64, 230, 14, 4)
  end
  ui.footer({ { "Enter", S.sw_run and "Stop" or "Start" }, { "L", "Lap" }, { "R", "Reset" }, { "Tab", "Study" } })
end

function tab.key(k)
  local c = not k.ctrl and not k.fn and k.text
  if k.key == "enter" or k.key == "space" or c == " " then
    if S.sw_run then S.sw_acc = S.sw_acc + sys.millis() - S.sw_start; S.sw_run = false
    else S.sw_start = sys.millis(); S.sw_run = true end
    sw_s = text(elapsed())
  elseif c == "l" then
    if not S.sw_run then shell.toast("Start the stopwatch first"); return true end
    if #S.laps >= MAX_LAPS then table.remove(S.laps, 1) end
    S.laps[#S.laps + 1] = elapsed()
    build_laps()
    ltop = 1
  elseif c == "r" then
    S.sw_run, S.sw_acc, S.laps = false, 0, {}
    build_laps()
    sw_s = text(0)
    shell.toast("Stopwatch reset")
  else
    return false
  end
  return true
end

return tab
end
