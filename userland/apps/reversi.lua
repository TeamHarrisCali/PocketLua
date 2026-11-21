-- Reversi: play the computer on an 8x8 board. Place a disc so it traps a line
-- of the other colour; the trapped discs flip. Most discs at the end wins.
local col = ui.col
local app = { title = "Reversi", icon = "radar", color = "green", order = 70, category = "games" }
app.help = {
  { "Arrows", "Move" },
  { "Enter", "Place a disc" },
  { "Tab", "Computer strength" },
  { "U", "Take back a move" },
  { "N", "New game" },
  { "M", "Sound on/off" },
  { "Esc", "Home" },
}

local gk = require("gamekit")

local CELL, X0, Y0 = 13, 6, 18
local DIRS = { -11, -10, -9, -1, 1, 9, 10, 11 }   -- on a 10x10 board with a border
-- Corners are worth most, the squares next to them least.
local WEIGHT = {
  100, -20, 10, 5, 5, 10, -20, 100,
  -20, -40, -2, -2, -2, -2, -40, -20,
  10, -2, 1, 1, 1, 1, -2, 10,
  5, -2, 1, 0, 0, 1, -2, 5,
  5, -2, 1, 0, 0, 1, -2, 5,
  10, -2, 1, 1, 1, 1, -2, 10,
  -20, -40, -2, -2, -2, -2, -40, -20,
  100, -20, 10, 5, 5, 10, -20, 100,
}
local LEVELS = { "Easy", "Normal", "Hard" }

-- Squares are 11..88 (row * 10 + col, both 1-8); 0 empty, 1 you, 2 computer,
-- 3 the border.
local b, hist
local cx, cy, turn, state, level, think
local wins, scores
local mine, theirs, legal
local s_you, s_cpu, s_msg, s_level, s_wins

local function sq(x, y) return (y + 1) * 10 + x + 1 end

local function flips(bd, s, who, apply)
  if bd[s] ~= 0 then return 0 end
  local other, n = 3 - who, 0
  for _, d in ipairs(DIRS) do
    local p, k = s + d, 0
    while bd[p] == other do p, k = p + d, k + 1 end
    if k > 0 and bd[p] == who then
      n = n + k
      if apply then
        local q = s + d
        while q ~= p do bd[q] = who; q = q + d end
      end
    end
  end
  if apply and n > 0 then bd[s] = who end
  return n
end

local function moves(bd, who)
  local out = {}
  for y = 1, 8 do
    for x = 1, 8 do
      local s = y * 10 + x
      if bd[s] == 0 and flips(bd, s, who) > 0 then out[#out + 1] = s end
    end
  end
  return out
end

local function count()
  mine, theirs = 0, 0
  for y = 1, 8 do
    for x = 1, 8 do
      local v = b[y * 10 + x]
      if v == 1 then mine = mine + 1 elseif v == 2 then theirs = theirs + 1 end
    end
  end
end

local function texts()
  count()
  s_you, s_cpu = tostring(mine), tostring(theirs)
  s_level = LEVELS[level]
  s_wins = "Wins " .. (wins[level] or 0)
  if state == "over" then
    s_msg = mine > theirs and "You win!" or (mine < theirs and "Computer wins" or "A draw")
  elseif turn == 1 then
    s_msg = "Your move"
  else
    s_msg = "Thinking..."
  end
end

local function refresh_legal()
  legal = {}
  if turn == 1 and state == "play" then
    for _, s in ipairs(moves(b, 1)) do legal[s] = true end
  end
end

local function new_game()
  b = {}
  for i = 0, 99 do
    local x, y = i % 10, i // 10
    b[i] = (x == 0 or x == 9 or y == 0 or y == 9) and 3 or 0
  end
  b[44], b[55], b[45], b[54] = 2, 2, 1, 1
  hist = {}
  cx, cy, turn, state, think = 3, 2, 1, "play", 0
  refresh_legal()
  texts()
end

local function copy(bd)
  local c = {}
  for i = 0, 99 do c[i] = bd[i] end
  return c
end

-- Take-back history is kept as 64-character strings, not board tables.
local function snap(bd)
  local t = {}
  for y = 1, 8 do for x = 1, 8 do t[#t + 1] = bd[y * 10 + x] end end
  return table.concat(t)
end

local function unsnap(str)
  local bd = {}
  for i = 0, 99 do
    local x, y = i % 10, i // 10
    bd[i] = (x == 0 or x == 9 or y == 0 or y == 9) and 3 or tonumber(str:sub((y - 1) * 8 + x, (y - 1) * 8 + x))
  end
  return bd
end

local function score(bd)
  local s = 0
  for y = 1, 8 do
    for x = 1, 8 do
      local v = bd[y * 10 + x]
      if v == 2 then s = s + WEIGHT[(y - 1) * 8 + x] elseif v == 1 then s = s - WEIGHT[(y - 1) * 8 + x] end
    end
  end
  return s + (#moves(bd, 2) - #moves(bd, 1)) * 3
end

-- Easy: random with a liking for corners. Normal: best square now. Hard: also
-- looks at your best reply.
local function cpu_pick()
  local list = moves(b, 2)
  if #list == 0 then return nil end
  if level == 1 then
    for _, s in ipairs(list) do if s == 11 or s == 18 or s == 81 or s == 88 then return s end end
    return list[math.random(1, #list)]
  end
  local best_s, best_v = list[1], -1e9
  for _, s in ipairs(list) do
    local nb = copy(b)
    flips(nb, s, 2, true)
    local v
    if level == 2 then
      v = score(nb)
    else
      v = 1e9
      local replies = moves(nb, 1)
      if #replies == 0 then v = score(nb) + 50 end
      for _, r in ipairs(replies) do
        local rb = copy(nb)
        flips(rb, r, 1, true)
        local rv = score(rb)
        if rv < v then v = rv end
      end
    end
    v = v + math.random() * 0.5
    if v > best_v then best_s, best_v = s, v end
  end
  return best_s
end

local function finish()
  state = "over"
  count()
  if mine > theirs then
    wins[level] = (wins[level] or 0) + 1
    scores["wins_" .. level] = wins[level]
    gk.save("reversi", scores)
    gk.beep(1047, 150)
  else
    gk.beep(220, 200)
  end
end

-- Hands the turn to whoever can move next (a player with no move passes).
local function next_turn(from)
  local other = 3 - from
  if #moves(b, other) > 0 then
    turn = other
  elseif #moves(b, from) > 0 then
    turn = from
    if from == 1 then shell.toast("Computer passes") end
  else
    finish()
  end
  if turn == 2 and state == "play" then think = 0.5 end
  refresh_legal()
  texts()
end

local function play_at(s, who)
  if who == 1 then
    hist[#hist + 1] = snap(b)
    if #hist > 30 then table.remove(hist, 1) end
  end
  flips(b, s, who, true)
  gk.beep(who == 1 and 700 or 500, 15)
  next_turn(who)
end

function app.save()
  if state == "play" then return { b = snap(b), t = turn } end
end

function app.init(_, saved)
  math.randomseed(sys.millis())
  scores = gk.load("reversi")
  level = tonumber(scores.level) or 2
  if level < 1 or level > 3 then level = 2 end
  wins = {}
  for i = 1, 3 do wins[i] = tonumber(scores["wins_" .. i]) end
  new_game()
  if saved and type(saved.b) == "string" and #saved.b == 64 then
    b = unsnap(saved.b)
    turn = saved.t == 2 and 2 or 1
    if turn == 2 then think = 0.5 end
    refresh_legal()
    texts()
  end
end

function app.update(dt)
  if state ~= "play" or turn ~= 2 then return end
  think = think - dt
  if think > 0 then return end
  local s = cpu_pick()
  if s then play_at(s, 2) else next_turn(2) end
end

function app.draw()
  gfx.fill(X0 - 1, Y0 - 1, 8 * CELL + 1, 8 * CELL + 1, col.line)
  for y = 0, 7 do
    for x = 0, 7 do
      local px, py = X0 + x * CELL, Y0 + y * CELL
      local s = sq(x, y)
      gfx.fill(px, py, CELL - 1, CELL - 1, col.surface)
      local v = b[s]
      if v == 1 then gfx.disc(px + 6, py + 6, 5, col.accent)
      elseif v == 2 then gfx.disc(px + 6, py + 6, 5, col.text)
      elseif legal[s] then gfx.disc(px + 6, py + 6, 1, col.muted) end
    end
  end
  gfx.rect(X0 + cx * CELL - 1, Y0 + cy * CELL - 1, CELL + 1, CELL + 1, col.warn)
  local x = 120
  gfx.disc(x + 5, 24, 5, col.accent)
  ui.text(x + 14, 21, "You", col.text)
  ui.right(236, 21, s_you, col.text, 1)
  gfx.disc(x + 5, 40, 5, col.text)
  ui.text(x + 14, 37, "Computer", col.text)
  ui.right(236, 37, s_cpu, col.text, 1)
  ui.text(x, 56, s_level, col.muted)
  ui.right(236, 56, s_wins, col.muted)
  ui.text(x, 76, s_msg, state == "over" and col.good or col.accent)
  if state == "over" then
    ui.footer({ { "Enter", "Again" }, { "Tab", "Level" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Enter", "Place" }, { "U", "Undo" }, { "Tab", "Level" }, { "Esc", "Home" } })
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if c == "m" then gk.toggle_sound(); return true end
  if k.key == "tab" then
    level = k.shift and (level + 1) % 3 + 1 or level % 3 + 1
    scores.level = level
    gk.save("reversi", scores)
    shell.toast("Computer: " .. LEVELS[level])
    texts()
    return true
  end
  if c == "n" or (state == "over" and k.key == "enter") then new_game(); return true end
  if c == "u" then  -- back to just before your last move
    local prev = table.remove(hist)
    if not prev then shell.toast("Nothing to take back"); return true end
    b, state, turn = unsnap(prev), "play", 1
    refresh_legal()
    texts()
    return true
  end
  local d = ui.nav(k)
  if d == "up" then cy = (cy - 1) % 8
  elseif d == "down" then cy = (cy + 1) % 8
  elseif d == "left" then cx = (cx - 1) % 8
  elseif d == "right" then cx = (cx + 1) % 8
  elseif k.key == "enter" or c == " " then
    local s = sq(cx, cy)
    if state == "play" and turn == 1 then
      if legal[s] then play_at(s, 1) else gk.beep(200, 20); shell.toast("That move flips nothing") end
    end
  else return false end
  return true
end

function app.close()
  b, hist, legal, scores = nil, nil, nil, nil
end

return app
