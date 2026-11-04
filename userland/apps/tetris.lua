-- Blocks: falling-block puzzle. Left/right move, Up or X rotates, Down drops
-- one row, Space drops all the way, P pauses.
local col = ui.col
local app = { title = "Blocks", icon = "blocks", color = "purple", order = 61, category = "games" }

local W, H, CELL = 10, 20, 5
local X0, Y0 = 70, 20                 -- well: 50 x 100 px, y 20-119
-- Pieces in their bounding box (size n); rotation is (x, y) -> (n-1-y, x).
local SHAPES = {
  { 4, 0, 1, 1, 1, 2, 1, 3, 1 },      -- I
  { 2, 0, 0, 1, 0, 0, 1, 1, 1 },      -- O
  { 3, 1, 0, 0, 1, 1, 1, 2, 1 },      -- T
  { 3, 1, 0, 2, 0, 0, 1, 1, 1 },      -- S
  { 3, 0, 0, 1, 0, 1, 1, 2, 1 },      -- Z
  { 3, 0, 0, 0, 1, 1, 1, 2, 1 },      -- J
  { 3, 2, 0, 0, 1, 1, 1, 2, 1 },      -- L
}
local KICKS = { 0, 0, -1, 0, 1, 0, 0, -1, -2, 0, 2, 0 }
local LINE_PTS = { 100, 300, 500, 800 }

local rot          -- rot[p][r] = { x1, y1, ..., x4, y4 }
local board        -- board[y * W + x + 1] = piece number or 0
local bag
local cur, cr, cx, cy, nxt
local score, lines, level, best
local state, acc
local s_score, s_lines, s_level, s_best, s_bestl  -- cached strings for draw()

local function build_rotations()
  rot = {}
  for p, s in ipairs(SHAPES) do
    local n = s[1]
    rot[p] = {}
    local c = { table.unpack(s, 2) }
    for r = 1, 4 do
      rot[p][r] = c
      local nc = {}
      for i = 1, 7, 2 do nc[i], nc[i + 1] = n - 1 - c[i + 1], c[i] end
      c = nc
    end
  end
end

local function texts()
  s_score, s_lines, s_level, s_best = tostring(score), tostring(lines), tostring(level), tostring(best)
  s_bestl = "Best " .. best
end

local function draw_from_bag()
  if #bag == 0 then
    for i = 1, 7 do bag[i] = i end
    for i = 7, 2, -1 do
      local j = math.random(1, i)
      bag[i], bag[j] = bag[j], bag[i]
    end
  end
  return table.remove(bag)
end

local function fits(p, r, x, y)
  local c = rot[p][r]
  for i = 1, 7, 2 do
    local bx, by = x + c[i], y + c[i + 1]
    if bx < 0 or bx >= W or by >= H then return false end
    if by >= 0 and board[by * W + bx + 1] ~= 0 then return false end
  end
  return true
end

local function interval() return math.max(0.08, 0.8 - (level - 1) * 0.07) end

local function spawn()
  cur, nxt = nxt, draw_from_bag()
  cr, cx, cy = 1, 3, 0
  if cur == 1 then cy = -1 end
  acc = 0
  if not fits(cur, cr, cx, cy) then
    state = "over"
    if score > best then best = score; cfg.set("blocks_best", best) end
    texts()
    snd.tone(160, 400)
  end
end

local function reset()
  board, bag = {}, {}
  for i = 1, W * H do board[i] = 0 end
  score, lines, level = 0, 0, 1
  nxt = draw_from_bag()
  state = "play"
  spawn()
  texts()
end

local function clear_lines()
  local n, y = 0, H - 1
  while y >= 0 do
    local full = true
    for x = 0, W - 1 do
      if board[y * W + x + 1] == 0 then full = false; break end
    end
    if full then
      n = n + 1
      for yy = y, 1, -1 do
        for x = 1, W do board[yy * W + x] = board[(yy - 1) * W + x] end
      end
      for x = 1, W do board[x] = 0 end
    else
      y = y - 1
    end
  end
  if n > 0 then
    score = score + LINE_PTS[n] * level
    lines = lines + n
    level = lines // 10 + 1
    snd.tone(660 + n * 110, 80)
  end
end

local function lock()
  local c = rot[cur][cr]
  for i = 1, 7, 2 do
    local by = cy + c[i + 1]
    if by >= 0 then board[by * W + cx + c[i] + 1] = cur end
  end
  clear_lines()
  texts()
  spawn()
end

local function move(dx)
  if fits(cur, cr, cx + dx, cy) then cx = cx + dx end
end

local function rotate()
  local r = cr % 4 + 1
  for i = 1, #KICKS, 2 do
    if fits(cur, r, cx + KICKS[i], cy + KICKS[i + 1]) then
      cr, cx, cy = r, cx + KICKS[i], cy + KICKS[i + 1]
      return
    end
  end
end

local function soft_drop()
  if fits(cur, cr, cx, cy + 1) then
    cy = cy + 1
    score = score + 1
    texts()
  else
    lock()
  end
  acc = 0
end

local function hard_drop()
  while fits(cur, cr, cx, cy + 1) do
    cy = cy + 1
    score = score + 2
  end
  snd.tone(220, 30)
  lock()
end

function app.init()
  math.randomseed(sys.millis())
  best = tonumber(cfg.get("blocks_best")) or 0
  build_rotations()
  reset()
end

function app.update(dt)
  if state ~= "play" then return end
  acc = acc + dt
  local iv = interval()
  if acc >= iv then
    acc = 0
    if fits(cur, cr, cx, cy + 1) then cy = cy + 1 else lock() end
  end
end

local function cell(x, y, p, size)
  gfx.fill(x, y, size - 1, size - 1, ui.accents[ui.accent_names[p]])
end

function app.draw()
  -- well
  gfx.fill(X0 - 1, Y0 - 1, W * CELL + 2, H * CELL + 2, col.line)
  gfx.fill(X0, Y0, W * CELL, H * CELL, col.surface)
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      local p = board[y * W + x + 1]
      if p ~= 0 then cell(X0 + x * CELL, Y0 + y * CELL, p, CELL) end
    end
  end
  if state ~= "over" then
    local c = rot[cur][cr]
    for i = 1, 7, 2 do
      local by = cy + c[i + 1]
      if by >= 0 then cell(X0 + (cx + c[i]) * CELL, Y0 + by * CELL, cur, CELL) end
    end
  end
  -- left panel
  ui.title(6, 20, "LEVEL")
  gfx.text(6, 30, s_level, col.text, 2)
  ui.title(6, 52, "LINES")
  gfx.text(6, 62, s_lines, col.text, 2)
  ui.title(6, 84, "BEST")
  gfx.text(6, 94, s_best, col.muted)
  -- right panel
  ui.title(132, 20, "NEXT")
  gfx.rfill(132, 30, 34, 22, 3, col.surface)
  local c = rot[nxt][1]
  local ox = nxt == 1 and 137 or (nxt == 2 and 143 or 140)
  for i = 1, 7, 2 do cell(ox + c[i] * 6, 35 + c[i + 1] * 6 - (nxt == 1 and 3 or 0), nxt, 6) end
  ui.title(132, 60, "SCORE")
  gfx.text(132, 70, s_score, col.accent, 2)
  if state == "pause" then
    ui.box(56, 50, 128, 36)
    ui.center(61, "Paused", col.text, 2)
    ui.footer({ { "P", "Resume" }, { "Esc", "Home" } })
  elseif state == "over" then
    ui.box(40, 36, 160, 70)
    ui.center(42, "Game over", col.muted)
    ui.big(54, s_score, col.accent, 3)
    ui.center(88, s_bestl, col.muted)
    ui.footer({ { "Enter", "Again" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Up", "Turn" }, { "Spc", "Drop" }, { "P", "Pause" }, { "Esc", "Home" } })
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  if state == "over" then
    if k.key == "enter" then reset() end
    return true
  end
  local t = not k.ctrl and not k.fn and k.text and k.text:lower()
  if t == "p" then
    state = state == "pause" and "play" or "pause"
    return true
  end
  if state ~= "play" then return true end
  local d = ui.nav(k)
  if d == "left" then move(-1)
  elseif d == "right" then move(1)
  elseif d == "up" or t == "x" then rotate()
  elseif d == "down" then soft_drop()
  elseif k.key == "space" or t == " " then hard_drop()
  else return false end
  return true
end

function app.close()
  board, rot, bag = nil, nil, nil
end

return app
