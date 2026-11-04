-- Snake: eat, grow, don't bite yourself. Arrows or W/A/S/D steer, P pauses.
local col = ui.col
local app = { title = "Snake", icon = "snake", color = "green", order = 60, category = "games" }
app.help = {
  { "Arrows", "Steer (starts game)" },
  { "WASD", "Steer" },
  { "P", "Pause" },
  { "Enter", "Play again" },
  { "Esc", "Home" },
}

local GW, GH, CELL = 38, 16, 6        -- grid 228 x 96 px
local X0, Y0 = 6, 26                  -- grid origin (content y 26-121)
local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local WASD = { w = "up", a = "left", s = "down", d = "right" }

local body, occ          -- body[1] is the head; cells are y * GW + x
local dir, queue         -- current direction, up to 2 buffered turns
local food, score, best
local state              -- "ready", "play", "pause", "over"
local acc, step
local score_s, best_s, big_s  -- cached strings so draw() builds none

local function texts()
  score_s, big_s = "Score " .. score, tostring(score)
  best_s = "Best " .. best
end

local function place_food()
  local free = GW * GH - #body
  if free <= 0 then food = nil; return end
  for _ = 1, 50 do
    local c = math.random(0, GW * GH - 1)
    if not occ[c] then food = c; return end
  end
  local n = math.random(1, free)  -- crowded board: pick the n-th free cell
  for c = 0, GW * GH - 1 do
    if not occ[c] then
      n = n - 1
      if n == 0 then food = c; return end
    end
  end
end

local function reset()
  body, occ = {}, {}
  local y = GH // 2
  for i = 0, 3 do
    local c = y * GW + (8 - i)
    body[#body + 1] = c
    occ[c] = true
  end
  dir, queue = "right", {}
  score, acc, step = 0, 0, 0.15
  state = "ready"
  place_food()
  texts()
end

local function opposite(a, b)
  local da, db = DIRS[a], DIRS[b]
  return da[1] == -db[1] and da[2] == -db[2]
end

local function turn(d)
  local last = queue[#queue] or dir
  if d == last or opposite(d, last) or #queue >= 2 then return end
  queue[#queue + 1] = d
end

local function game_over()
  state = "over"
  if score > best then
    best = score
    cfg.set("snake_best", best)
    texts()
  end
  snd.tone(180, 300)
end

local function advance()
  if #queue > 0 then dir = table.remove(queue, 1) end
  local head = body[1]
  local hx, hy = head % GW, head // GW
  local d = DIRS[dir]
  local nx, ny = hx + d[1], hy + d[2]
  if nx < 0 or nx >= GW or ny < 0 or ny >= GH then game_over(); return end
  local c = ny * GW + nx
  local grow = c == food
  if not grow then
    local tail = table.remove(body)
    occ[tail] = nil
  end
  if occ[c] then game_over(); return end
  table.insert(body, 1, c)
  occ[c] = true
  if grow then
    score = score + 1
    texts()
    snd.tone(880, 30)
    step = math.max(0.05, 0.15 - score * 0.003)
    place_food()
    if not food then game_over() end
  end
end

function app.init()
  math.randomseed(sys.millis())
  best = tonumber(cfg.get("snake_best")) or 0
  reset()
end

function app.update(dt)
  if state ~= "play" then return end
  acc = acc + dt
  if acc >= step then
    acc = acc - step
    if acc > step then acc = 0 end  -- don't run several steps after a stall
    advance()
  end
end

function app.draw()
  ui.text(4, 17, score_s, col.text)
  ui.right(236, 17, best_s, col.muted)
  gfx.fill(X0 - 1, Y0 - 1, GW * CELL + 2, GH * CELL + 2, col.surface)
  if food then
    gfx.fill(X0 + (food % GW) * CELL + 1, Y0 + (food // GW) * CELL + 1, CELL - 2, CELL - 2, col.warn)
  end
  local c = col.accent
  for i = #body, 1, -1 do
    local b = body[i]
    gfx.fill(X0 + (b % GW) * CELL, Y0 + (b // GW) * CELL, CELL - 1, CELL - 1, i == 1 and col.text or c)
  end
  if state == "ready" then
    ui.center(60, "Arrows to start", col.text)
    ui.footer({ { "Arrows", "Start" }, { "Esc", "Home" } })
  elseif state == "pause" then
    ui.box(60, 50, 120, 40)
    ui.center(64, "Paused", col.text, 2)
    ui.footer({ { "P", "Resume" }, { "Esc", "Home" } })
  elseif state == "over" then
    ui.box(50, 34, 140, 76)
    ui.center(40, "Game over", col.muted)
    ui.big(52, big_s, col.accent, 3)
    if score >= best and score > 0 then ui.center(80, "New best!", col.good) end
    ui.center(94, best_s, col.muted)
    ui.footer({ { "Enter", "Again" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Arrows", "Steer" }, { "P", "Pause" }, { "Esc", "Home" } })
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  local d = ui.nav(k) or (k.text and not k.ctrl and not k.fn and WASD[k.text:lower()])
  if state == "over" then
    if k.key == "enter" then reset() return true end
    return d ~= nil
  end
  if (k.text == "p" or k.text == "P") and not k.fn then
    if state == "play" then state = "pause" elseif state == "pause" then state = "play" end
    return true
  end
  if d then
    if state == "ready" then
      state = "play"
      if not opposite(d, dir) then turn(d) end
    elseif state == "play" then
      turn(d)
    end
    return true
  end
  return false
end

function app.close()
  body, occ, queue = nil, nil, nil
end

return app
