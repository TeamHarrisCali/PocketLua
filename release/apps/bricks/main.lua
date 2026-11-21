-- Bricks: bounce the ball off your paddle and break every brick. Grey bricks
-- take more hits. Three balls, five walls that loop faster; best score kept.
local col = ui.col
local app = { title = "Bricks", icon = "pad", color = "orange", order = 67, category = "games" }
app.help = {
  { "<>", "Move the paddle" },
  { "A/D", "Move the paddle" },
  { "Space", "Launch the ball" },
  { "P", "Pause" },
  { "M", "Sound on/off" },
  { "Enter", "Play again" },
  { "Esc", "Home" },
}

local gk = require("gamekit")

-- Walls: 6 rows of 12; the digit is how many hits a brick takes.
local LEVELS = {
  "............" .. "111111111111" .. "111111111111" .. "111111111111" .. "111111111111" .. "............",
  "1..........1" .. "11........11" .. "121......121" .. "1221....1221" .. "122211112221" .. "111111111111",
  "..11....11.." .. ".1221..1221." .. "122221122221" .. ".1221..1221." .. "..11....11.." .. "............",
  "222222222222" .. "1..........1" .. "1.11111111.1" .. "1.12222221.1" .. "1.11111111.1" .. "1..........1",
  "3.1.3.1.3.1." .. ".1.2.1.2.1.2" .. "3.1.3.1.3.1." .. ".1.2.1.2.1.2" .. "1.1.1.1.1.1." .. ".1.1.1.1.1.1",
}
local COLS, ROWS, BW, BH, BX, BY = 12, 6, 19, 7, 6, 32
local TOP, LEFT, RIGHT, BOTTOM = 28, 6, 234, 124
local PY, PW, PSTEP = 114, 32, 10   -- paddle row, width, pixels per key press
local ROWC = { "red", "orange", "green", "teal", "blue", "purple" }

local bricks, left_n          -- bricks[row * COLS + col + 1] = hits left
local px, ptarget             -- paddle left edge (drawn), where it is heading
local bx, by, vx, vy, speed, stuck
local score, lives, level, loop, best, scores
local state                   -- "play", "pause", "clear", "over"
local s_score, s_level, s_best -- cached strings for draw()

local function texts()
  s_score, s_level, s_best = "Score " .. score, "Wall " .. level, "Best " .. best
end

local function load_level()
  bricks, left_n = {}, 0
  local map = LEVELS[level]
  for i = 1, COLS * ROWS do
    local h = tonumber(map:sub(i, i)) or 0
    bricks[i] = h
    if h > 0 then left_n = left_n + 1 end
  end
end

local function serve()
  stuck = true
  speed = 85 + loop * 15 + level * 4
  ptarget = px
end

local function new_game()
  score, lives, level, loop = 0, 3, 1, 0
  px = (LEFT + RIGHT - PW) // 2
  load_level()
  serve()
  state = "play"
  texts()
end

local function launch()
  if not stuck then return end
  stuck = false
  local a = math.random() * 0.8 - 0.4
  vx, vy = speed * math.sin(a), -speed * math.cos(a)
end

local function game_over()
  state = "over"
  if score > best then
    best = score
    scores.best = best
    gk.save("bricks", scores)
  end
  gk.beep(150, 300)
  texts()
end

local function hit(i)
  bricks[i] = bricks[i] - 1
  score = score + 10
  if bricks[i] == 0 then
    left_n = left_n - 1
    gk.beep(880, 15)
    if left_n == 0 then
      state = "clear"
      score = score + 100 * lives
      gk.beep(1319, 120)
    end
  else
    gk.beep(520, 15)
  end
  texts()
end

local function brick_at(x, y)
  if y < BY or y >= BY + ROWS * BH or x < BX or x >= BX + COLS * BW then return nil end
  local c, r = (x - BX) // BW, (y - BY) // BH
  local i = r * COLS + c + 1
  if bricks[i] > 0 then return i end
end

-- One small move of the ball (at most ~2 px), with bounces.
local function step(h)
  local nx, ny = bx + vx * h, by + vy * h
  if nx < LEFT then nx, vx = LEFT, math.abs(vx) end
  if nx > RIGHT then nx, vx = RIGHT, -math.abs(vx) end
  if ny < TOP then ny, vy = TOP, math.abs(vy) end
  local i = brick_at(nx, ny)
  if i then
    local cross_x = brick_at(nx, by)
    local cross_y = brick_at(bx, ny)
    if cross_y or not cross_x then vy = -vy; ny = by end
    if cross_x and not cross_y then vx = -vx; nx = bx end
    hit(i)
  end
  if vy > 0 and by <= PY - 2 and ny >= PY - 2 and nx >= px - 2 and nx <= px + PW + 2 then
    local off = math.max(-1, math.min(1, (nx - (px + PW / 2)) / (PW / 2)))
    speed = math.min(speed + 1.5, 190)
    local a = off * 1.05
    vx, vy = speed * math.sin(a), -speed * math.cos(a)
    ny = PY - 2
    gk.beep(660, 10)
  end
  bx, by = nx, ny
  if by > BOTTOM then
    lives = lives - 1
    gk.beep(200, 150)
    texts()
    if lives <= 0 then game_over() else serve() end
  end
end

function app.init()
  math.randomseed(sys.millis())
  scores = gk.load("bricks")
  best = tonumber(scores.best) or 0
  new_game()
end

function app.update(dt)
  if state ~= "play" then return end
  if px ~= ptarget then  -- glide towards where the keys sent the paddle
    local d = math.min(math.abs(ptarget - px), 400 * dt)
    px = px + (ptarget > px and d or -d)
  end
  if stuck then
    bx, by = px + PW / 2, PY - 3
    return
  end
  local n = math.max(1, math.ceil(speed * dt / 2))
  for _ = 1, n do
    step(dt / n)
    if stuck or state ~= "play" then break end
  end
end

function app.draw()
  ui.text(4, 17, s_score, col.text)
  ui.center(17, s_level, col.muted)
  for i = 1, 3 do gfx.disc(212 + i * 7, 20, 2, i <= lives and col.accent or col.surface2) end
  gfx.fill(LEFT - 3, TOP - 2, RIGHT - LEFT + 7, 1, col.line)
  for r = 0, ROWS - 1 do
    local c = ui.accents[ROWC[r + 1]]
    for k = 0, COLS - 1 do
      local h = bricks[r * COLS + k + 1]
      if h > 0 then
        gfx.fill(BX + k * BW, BY + r * BH, BW - 1, BH - 1, h == 1 and c or (h == 2 and col.muted or col.text))
      end
    end
  end
  gfx.rfill(math.floor(px), PY, PW, 4, 2, col.accent)
  if state ~= "over" then gfx.disc(math.floor(bx), math.floor(by), 2, col.text) end
  if state == "pause" then
    ui.box(60, 70, 120, 36)
    ui.center(80, "Paused", col.text, 2)
    ui.footer({ { "P", "Resume" }, { "Esc", "Home" } })
  elseif state == "clear" then
    ui.box(50, 70, 140, 40)
    ui.center(76, "Wall cleared!", col.good)
    ui.center(92, "Enter: next wall", col.muted)
    ui.footer({ { "Enter", "Next" }, { "Esc", "Home" } })
  elseif state == "over" then
    ui.box(50, 66, 140, 50)
    ui.center(72, "Game over", col.muted)
    ui.center(86, s_score, col.accent)
    ui.center(100, score >= best and score > 0 and "New best!" or s_best, score >= best and col.good or col.muted)
    ui.footer({ { "Enter", "Again" }, { "Esc", "Home" } })
  elseif stuck then
    ui.footer({ { "Space", "Launch" }, { "<>", "Move" }, { "P", "Pause" }, { "Esc", "Home" } })
  else
    ui.footer({ { "<>", "Move" }, { "P", "Pause" }, { "Esc", "Home" } })
  end
end

local MOVE = { a = "left", d = "right" }

function app.key(k)
  if k.key == "esc" then return false end
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if c == "m" then gk.toggle_sound(); return true end
  if state == "over" then
    if k.key == "enter" then new_game(); return true end
    return false
  end
  if state == "clear" then
    if k.key == "enter" or c == " " then
      level = level + 1
      if level > #LEVELS then level, loop = 1, loop + 1 end
      load_level()
      serve()
      state = "play"
      texts()
      return true
    end
    return false
  end
  if c == "p" then
    state = state == "pause" and "play" or "pause"
    return true
  end
  if state ~= "play" then return false end
  local d = ui.nav(k) or MOVE[c or ""]
  if d == "left" then ptarget = math.max(LEFT - 2, ptarget - PSTEP)
  elseif d == "right" then ptarget = math.min(RIGHT + 2 - PW, ptarget + PSTEP)
  elseif c == " " or k.key == "enter" or d == "up" then launch()
  else return d ~= nil end
  return true
end

function app.close()
  bricks, scores = nil, nil
end

return app
