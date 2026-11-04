-- Marble: tilt the Cardputer to roll the ball to the flag; holes restart the
-- level. The IMU axis directions are unverified: F / G flip X / Y, R swaps the
-- axes, C makes the current position "flat". Settings are remembered.
local col = ui.col
local app = { title = "Marble", icon = "ball", color = "teal", order = 63, category = "games" }

local CELL, MW, MH = 8, 28, 12
local X0, Y0 = 8, 26                  -- maze 224 x 96 px, y 26-121
local R = 3                           -- ball radius
local GRAV, FRICTION, VMAX, BOUNCE = 240, 0.9, 150, 0.3
local WALL, HOLE, GOAL = 35, 79, 71   -- '#', 'O', 'G'

local LEVELS = {
  {
    "############################",
    "#S.........................#",
    "#..........................#",
    "#######################....#",
    "#..........................#",
    "#..........................#",
    "#....#######################",
    "#..........................#",
    "#..........................#",
    "#######################....#",
    "#G.........................#",
    "############################",
  },
  {
    "############################",
    "#S....#..............#.G...#",
    "#.....#..............#.....#",
    "#.....#....O.........#.....#",
    "#.....#.......#......#.....#",
    "#.....#.......#......####..#",
    "#.............#............#",
    "#.............#.....O......#",
    "#######.......#............#",
    "#.....O.......#######......#",
    "#..........................#",
    "############################",
  },
  {
    "############################",
    "#S.........................#",
    "#.........O........O.......#",
    "########################...#",
    "#..........................#",
    "#....O.........O...........#",
    "#...########################",
    "#..........................#",
    "#...........O.........O....#",
    "########################...#",
    "#G.........................#",
    "############################",
  },
  {
    "############################",
    "#S....O........#.......O...#",
    "#.......O......#...O.......#",
    "#..O......O....#......O....#",
    "#.....O.....O..#..O....O...#",
    "#..O.....O...........O...O.#",
    "#......O....O..#.....O.....#",
    "#...O......O...#...O.....O.#",
    "#......O.......#......O....#",
    "#..O.....O.....#.O......O..#",
    "#.......O......#.......O..G#",
    "############################",
  },
}

local lv, rows                -- level number, its map rows
local runs, holes             -- wall rectangles {x, y, w, ...}, hole centres {x, y, ...}
local sx, sy, gx, gy          -- start and goal cells
local bx, by, vx, vy          -- ball position (maze px) and velocity
local t, state, msg_t         -- level time; "play", "pause", "fell", "clear", "done"
local fx, fy, swap = -1, 1, false
local off_a, off_b = 0, 0
local s_time, s_best, s_level, tenth = "0.0s", "", "", -1

local function load_settings()
  local a = cfg.get("marble_axes")
  if a then
    local p, q, s = a:match("^(%-?%d),(%-?%d),(%d)$")
    if p then fx, fy, swap = tonumber(p), tonumber(q), s == "1" end
  end
  local c = cfg.get("marble_cal")
  if c then
    local p, q = c:match("^(%S+),(%S+)$")
    off_a, off_b = tonumber(p) or 0, tonumber(q) or 0
  end
end

local function save_axes()
  cfg.set("marble_axes", string.format("%d,%d,%d", fx, fy, swap and 1 or 0))
end

local function best_text()
  local b = tonumber(cfg.get("marble_b" .. lv))
  s_best = b and string.format("Best %d.%ds", b // 10, b % 10) or "Best --"
end

local function load_level(n)
  lv = n
  rows = LEVELS[n]
  runs, holes = {}, {}
  for y = 0, MH - 1 do
    local row = rows[y + 1]
    local x = 0
    while x < MW do
      local c = row:byte(x + 1)
      if c == WALL then
        local x1 = x
        while x + 1 < MW and row:byte(x + 2) == WALL do x = x + 1 end
        runs[#runs + 1] = X0 + x1 * CELL
        runs[#runs + 1] = Y0 + y * CELL
        runs[#runs + 1] = (x - x1 + 1) * CELL
      elseif c == HOLE then
        holes[#holes + 1] = X0 + x * CELL + 4
        holes[#holes + 1] = Y0 + y * CELL + 4
      elseif c == GOAL then gx, gy = x, y
      elseif c == 83 then sx, sy = x, y   -- 'S'
      end
      x = x + 1
    end
  end
  bx, by = sx * CELL + 4, sy * CELL + 4
  vx, vy, t, tenth = 0, 0, 0, -1
  state = "play"
  s_time = "0.0s"
  s_level = "Level " .. n .. "/" .. #LEVELS
  best_text()
end

local function cell(x, y)
  if x < 0 or y < 0 or x >= MW or y >= MH then return WALL end
  return rows[y + 1]:byte(x + 1)
end

-- Does a ball centred at (x, y) overlap a wall?
local function blocked(x, y)
  local x0, x1 = math.floor((x - R) / CELL), math.floor((x + R - 0.01) / CELL)
  local y0, y1 = math.floor((y - R) / CELL), math.floor((y + R - 0.01) / CELL)
  for cy = y0, y1 do
    for cx = x0, x1 do
      if cell(cx, cy) == WALL then return true end
    end
  end
  return false
end

local function tilt()
  local v = imu.read()
  local a, b = (v.ax or 0) - off_a, (v.ay or 0) - off_b
  if swap then a, b = b, a end
  return math.max(-1, math.min(1, a * fx)), math.max(-1, math.min(1, b * fy))
end

local function physics(dt)
  local ax, ay = tilt()
  vx = vx + ax * GRAV * dt
  vy = vy + ay * GRAV * dt
  local f = math.max(0, 1 - FRICTION * dt)
  vx, vy = vx * f, vy * f
  vx = math.max(-VMAX, math.min(VMAX, vx))
  vy = math.max(-VMAX, math.min(VMAX, vy))
  local n = math.max(1, math.ceil(math.max(math.abs(vx), math.abs(vy)) * dt))
  local sdt = dt / n
  for _ = 1, n do
    local nx = bx + vx * sdt
    if blocked(nx, by) then vx = -vx * BOUNCE else bx = nx end
    local ny = by + vy * sdt
    if blocked(bx, ny) then vy = -vy * BOUNCE else by = ny end
  end
end

local function check_cells()
  local cx, cy = math.floor(bx / CELL), math.floor(by / CELL)
  local c = cell(cx, cy)
  if c == GOAL then
    state, msg_t = "clear", 0
    local tenths = math.floor(t * 10)
    local key = "marble_b" .. lv
    local b = tonumber(cfg.get(key))
    if not b or tenths < b then cfg.set(key, tenths) end
    best_text()
    snd.tone(1046, 150)
  elseif c == HOLE and math.abs(bx - cx * CELL - 4) < 3.5 and math.abs(by - cy * CELL - 4) < 3.5 then
    state, msg_t = "fell", 0
    snd.tone(150, 250)
  end
end

function app.init(args, saved)
  load_settings()
  load_level(saved and LEVELS[saved.lv or 0] and saved.lv or 1)
end

function app.update(dt)
  if state == "play" then
    t = t + dt
    local tn = math.floor(t * 10)
    if tn ~= tenth then
      tenth = tn
      s_time = string.format("%d.%ds", tn // 10, tn % 10)
    end
    physics(dt)
    check_cells()
  elseif state == "fell" then
    msg_t = msg_t + dt
    if msg_t > 1.2 then load_level(lv) end
  end
end

function app.draw()
  ui.text(4, 17, s_level, col.text)
  ui.center(17, s_time, col.accent)
  ui.right(236, 17, s_best, col.muted)
  gfx.fill(X0, Y0, MW * CELL, MH * CELL, col.surface)
  for i = 1, #runs, 3 do gfx.fill(runs[i], runs[i + 1], runs[i + 2], CELL, col.line) end
  gfx.rfill(X0 + gx * CELL, Y0 + gy * CELL, CELL, CELL, 2, col.good)
  for i = 1, #holes, 2 do
    gfx.disc(holes[i], holes[i + 1], 3, col.bg)
    gfx.circle(holes[i], holes[i + 1], 3, col.muted)
  end
  if state ~= "fell" then
    gfx.disc(X0 + math.floor(bx), Y0 + math.floor(by), R, col.accent)
  end
  if state == "pause" then
    ui.box(60, 50, 120, 36)
    ui.center(61, "Paused", col.text, 2)
    ui.footer({ { "P", "Resume" }, { "C", "Zero" }, { "Esc", "Home" } })
  elseif state == "fell" then
    ui.box(60, 50, 120, 36)
    ui.center(64, "Fell in! Again...", col.text)
    ui.footer({ { "Esc", "Home" } })
  elseif state == "clear" then
    ui.box(40, 38, 160, 64)
    ui.center(44, "Level clear", col.muted)
    ui.big(56, s_time, col.good, 3)
    ui.center(86, s_best, col.muted)
    ui.footer({ { "Enter", lv < #LEVELS and "Next" or "Finish" }, { "R", "Retry" }, { "Esc", "Home" } })
  elseif state == "done" then
    ui.box(30, 40, 180, 56)
    ui.big(48, "All done!", col.good, 2)
    ui.center(76, "Every maze cleared", col.muted)
    ui.footer({ { "Enter", "Play again" }, { "Esc", "Home" } })
  else
    ui.footer({ { "C", "Zero" }, { "F/G", "Flip" }, { "R", "Swap" }, { "P", "Pause" } })
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  local c = not k.ctrl and not k.fn and k.text and k.text:lower()
  if state == "clear" then
    if k.key == "enter" then
      if lv < #LEVELS then load_level(lv + 1) else state = "done" end
    elseif c == "r" then load_level(lv) end
    return true
  elseif state == "done" then
    if k.key == "enter" then load_level(1) end
    return true
  end
  if c == "p" then
    if state == "play" then state = "pause" elseif state == "pause" then state = "play" end
  elseif c == "c" then
    local v = imu.read()
    off_a, off_b = v.ax or 0, v.ay or 0
    cfg.set("marble_cal", string.format("%.3f,%.3f", off_a, off_b))
    shell.toast("Zeroed: this is flat now")
  elseif c == "f" then fx = -fx; save_axes(); shell.toast("X flipped")
  elseif c == "g" then fy = -fy; save_axes(); shell.toast("Y flipped")
  elseif c == "r" then swap = not swap; save_axes(); shell.toast(swap and "Axes swapped" or "Axes normal")
  else
    -- arrows nudge the ball, for play without tilting
    local d = state == "play" and ui.nav(k)
    if not d then return false end
    if d == "left" then vx = vx - 40 elseif d == "right" then vx = vx + 40
    elseif d == "up" then vy = vy - 40 else vy = vy + 40 end
  end
  return true
end

function app.save()
  return { lv = lv }
end

function app.close()
  runs, holes = nil, nil
end

return app
