-- Gems: swap two neighbouring gems to line up three or more of a kind. Lines
-- clear, gems fall, chains score more. Classic ends when no swap is left;
-- Timed gives you 90 seconds.
local col = ui.col
local app = { title = "Gems", icon = "pin", color = "pink", order = 73, category = "games" }
app.help = {
  { "Arrows", "Move / swap" },
  { "Enter", "Pick up a gem" },
  { "Space", "Pick up a gem" },
  { "H", "Hint" },
  { "Tab", "Classic / Timed" },
  { "N", "New game" },
  { "M", "Sound on/off" },
  { "Esc", "Home" },
}

local gk = require("gamekit")

local N, CELL, X0, Y0 = 8, 13, 6, 18
local KINDS = 6
local GEMC = { "red", "orange", "green", "teal", "blue", "purple" }
local MODES = { "Classic", "Timed" }
local TIME = 90
local DIRS = { up = -N, down = N, left = -1, right = 1 }

local b, off, hit      -- gem kind per cell (0..63), fall offset in px, cells being cleared
local cx, cy, picked
local mode, state      -- state: "idle", "clear", "fall", "over"
local phase_t, chain, score, left_t, best, scores
local hint_dir
local s_score, s_best, s_mode, s_time, s_chain, s_hint

local function texts()
  s_score, s_mode = tostring(score), MODES[mode]
  s_best = "Best " .. (best[mode] or 0)
  s_time = mode == 2 and string.format("%d s", math.max(0, math.ceil(left_t))) or ""
end

-- Length of the line of `k` through cell i, along a row (dx=1) or column (dx=N).
local function run(i, k, step)
  local x, y = i % N, i // N
  local n = 1
  if step == 1 then
    for xx = x - 1, 0, -1 do if b[y * N + xx] == k then n = n + 1 else break end end
    for xx = x + 1, N - 1 do if b[y * N + xx] == k then n = n + 1 else break end end
  else
    for yy = y - 1, 0, -1 do if b[yy * N + x] == k then n = n + 1 else break end end
    for yy = y + 1, N - 1 do if b[yy * N + x] == k then n = n + 1 else break end end
  end
  return n
end

local function makes_line(i)
  local k = b[i]
  return k ~= 0 and (run(i, k, 1) >= 3 or run(i, k, N) >= 3)
end

local function neighbour(i, d)
  local x, y = i % N, i // N
  if d == "left" and x == 0 or d == "right" and x == N - 1 or d == "up" and y == 0 or d == "down" and y == N - 1 then
    return nil
  end
  return i + DIRS[d]
end

-- Swaps i and j, and says whether that lines anything up (then swaps back).
local function would_match(i, j)
  b[i], b[j] = b[j], b[i]
  local ok = makes_line(i) or makes_line(j)
  b[i], b[j] = b[j], b[i]
  return ok
end

local function find_move()
  for i = 0, N * N - 1 do
    for _, d in ipairs({ "right", "down" }) do
      local j = neighbour(i, d)
      if j and b[i] ~= b[j] and would_match(i, j) then return i, d end
    end
  end
end

local function fill_board()
  for _ = 1, 50 do
    for i = 0, N * N - 1 do
      local x, y = i % N, i // N
      repeat
        b[i] = math.random(1, KINDS)
      until not (x >= 2 and b[i - 1] == b[i] and b[i - 2] == b[i]) and
            not (y >= 2 and b[i - N] == b[i] and b[i - 2 * N] == b[i])
      off[i] = -(N - y) * CELL // 2
    end
    if find_move() then return end
  end
end

-- Marks every cell in a line of three or more; returns how many.
local function mark_runs(first, step, count)
  local n, start, k = 0, 0, nil
  for p = 0, count do
    local v = p < count and b[first + p * step] or -1
    if v ~= k then
      if k and k ~= 0 and p - start >= 3 then
        for q = start, p - 1 do
          local i = first + q * step
          if not hit[i] then hit[i] = true; n = n + 1 end
        end
      end
      start, k = p, v
    end
  end
  return n
end

local function mark()
  hit = {}
  local n = 0
  for r = 0, N - 1 do n = n + mark_runs(r * N, 1, N) + mark_runs(r, N, N) end
  return n
end

local function start_clear()
  local n = mark()
  if n == 0 then return false end
  chain = chain + 1
  score = score + n * 10 * chain
  s_chain = chain > 1 and ("Chain x" .. chain) or ("+" .. n * 10)
  state, phase_t = "clear", 0.18
  gk.beep(600 + chain * 150, 25)
  texts()
  return true
end

-- Gems fall into the gaps and new ones drop in from the top.
local function drop()
  for i in pairs(hit) do b[i] = 0 end
  hit = {}
  for x = 0, N - 1 do
    local w = N - 1
    for y = N - 1, 0, -1 do
      local i = y * N + x
      if b[i] ~= 0 then
        local to = w * N + x
        if to ~= i then b[to], b[i] = b[i], 0; off[to] = (y - w) * CELL end
        w = w - 1
      end
    end
    for y = w, 0, -1 do
      local i = y * N + x
      b[i] = math.random(1, KINDS)
      off[i] = (y - w - 1) * CELL
    end
  end
  state = "fall"
end

-- A best score counts even if you leave a Classic game unfinished.
local function record()
  if score and score > (best[mode] or 0) then
    best[mode] = score
    scores["best_" .. mode] = score
    gk.save("gems", scores)
  end
end

local function finish(why)
  state = "over"
  picked = nil
  record()
  s_chain = why
  gk.beep(220, 250)
  texts()
end

local function settle()
  if start_clear() then return end
  chain = 0
  state = "idle"
  if not find_move() then
    if mode == 1 then finish("No moves left")
    else fill_board(); state = "fall"; shell.toast("No moves: new gems") end
  end
end

local function new_game()
  record()
  b, off, hit = {}, {}, {}
  fill_board()
  cx, cy, picked, hint_dir = 3, 3, nil, nil
  score, chain, left_t = 0, 0, TIME
  s_chain, s_hint = "", ""
  state = "fall"
  texts()
end

local function swap(d)
  local i = picked
  local j = neighbour(i, d)
  picked = nil
  if not j then return end
  hint_dir, s_hint = nil, ""
  if b[i] == b[j] or not would_match(i, j) then
    gk.beep(200, 30)
    s_chain = "No line"
    return
  end
  b[i], b[j] = b[j], b[i]
  cx, cy = j % N, j // N
  chain = 0
  start_clear()
end

function app.init(_, saved)
  math.randomseed(sys.millis())
  scores = gk.load("gems")
  best = { tonumber(scores.best_1), tonumber(scores.best_2) }
  mode = tonumber(scores.mode) == 2 and 2 or 1
  new_game()
  if saved and type(saved.b) == "string" and #saved.b == N * N and saved.mode == mode then
    for i = 0, N * N - 1 do b[i], off[i] = tonumber(saved.b:sub(i + 1, i + 1)) or 1, 0 end
    score, left_t = tonumber(saved.s) or 0, tonumber(saved.t) or TIME
    state = "fall"
    texts()
  end
end

function app.save()
  if state == "over" then return nil end
  local t = {}
  for i = 0, N * N - 1 do t[i + 1] = b[i] == 0 and 1 or b[i] end
  return { b = table.concat(t), s = score, t = left_t, mode = mode }
end

function app.update(dt)
  if state == "over" then return end
  if mode == 2 then
    local before = math.ceil(left_t)
    left_t = left_t - dt
    if math.ceil(left_t) ~= before then texts() end
    if left_t <= 0 and state == "idle" then finish("Time is up"); return end
  end
  if state == "clear" then
    phase_t = phase_t - dt
    if phase_t <= 0 then drop() end
  elseif state == "fall" then
    local moving = false
    local v = 260 * dt
    for i = 0, N * N - 1 do
      local o = off[i]
      if o ~= 0 then
        o = o < 0 and math.min(0, o + v) or math.max(0, o - v)
        off[i] = o
        if o ~= 0 then moving = true end
      end
    end
    if not moving then settle() end
  end
end

local function gem(k, x, y, c)
  if k == 1 then gfx.disc(x + 6, y + 6, 5, c)
  elseif k == 2 then gfx.rfill(x + 1, y + 1, 11, 11, 2, c)
  elseif k == 3 then
    gfx.tri(x + 6, y, x, y + 6, x + 12, y + 6, c)
    gfx.tri(x, y + 6, x + 12, y + 6, x + 6, y + 12, c)
  elseif k == 4 then gfx.tri(x + 6, y + 1, x, y + 11, x + 12, y + 11, c)
  elseif k == 5 then gfx.disc(x + 6, y + 6, 5, c); gfx.disc(x + 6, y + 6, 2, col.surface)
  elseif k == 6 then gfx.fill(x + 4, y, 4, 12, c); gfx.fill(x, y + 4, 12, 4, c) end
end

function app.draw()
  gfx.fill(X0 - 1, Y0 - 1, N * CELL + 1, N * CELL + 1, col.surface)
  gfx.clip(X0 - 1, Y0 - 1, N * CELL + 1, N * CELL + 1)
  local flash = state == "clear" and phase_t % 0.1 < 0.05
  for i = 0, N * N - 1 do
    local k = b[i]
    if k ~= 0 and not (hit[i] and flash) then
      local x, y = X0 + (i % N) * CELL, Y0 + (i // N) * CELL + math.floor(off[i])
      gem(k, x, y, hit[i] and col.text or ui.accents[GEMC[k]])
    end
  end
  gfx.noclip()
  if state ~= "over" then
    local x, y = X0 + cx * CELL - 1, Y0 + cy * CELL - 1
    gfx.rect(x, y, CELL + 1, CELL + 1, picked and col.text or col.accent)
    if picked then gfx.rect(x + 1, y + 1, CELL - 1, CELL - 1, col.text) end
  end
  local px = 122
  ui.text(px, 20, s_mode, col.accent)
  ui.right(236, 20, s_time, state ~= "over" and left_t < 10 and col.warn or col.muted)
  ui.text(px, 36, "Score", col.muted)
  ui.right(236, 32, s_score, col.text, 2)
  ui.text(px, 54, s_best, col.muted)
  ui.text(px, 72, s_chain, state == "over" and col.bad or col.good)
  ui.text(px, 86, s_hint, col.warn)
  if state == "over" then
    ui.text(px, 100, "Enter: new game", col.muted)
    ui.footer({ { "Enter", "Again" }, { "Tab", "Mode" }, { "Esc", "Home" } })
  elseif picked then
    ui.footer({ { "Arrows", "Swap" }, { "Enter", "Drop" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Enter", "Pick" }, { "H", "Hint" }, { "Tab", "Mode" }, { "Esc", "Home" } })
  end
end

local HINT = { right = "Hint: swap right", down = "Hint: swap down" }

function app.key(k)
  if k.key == "esc" then return false end
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if c == "m" then gk.toggle_sound(); return true end
  if k.key == "tab" then
    record()
    mode = mode % 2 + 1
    scores.mode = mode
    gk.save("gems", scores)
    new_game()
    return true
  end
  if c == "n" or (state == "over" and k.key == "enter") then new_game(); return true end
  if state == "over" then return ui.nav(k) ~= nil end
  local d = ui.nav(k)
  if picked and d then
    if state == "idle" then swap(d) end
    return true
  end
  if d == "up" then cy = (cy - 1) % N
  elseif d == "down" then cy = (cy + 1) % N
  elseif d == "left" then cx = (cx - 1) % N
  elseif d == "right" then cx = (cx + 1) % N
  elseif k.key == "enter" or c == " " then
    if picked then picked = nil else picked = cy * N + cx end
  elseif c == "h" then
    if state == "idle" then
      local i, dir = find_move()
      if i then
        cx, cy, picked, hint_dir, s_hint = i % N, i // N, i, dir, HINT[dir]
      end
    end
  else return false end
  return true
end

function app.close()
  if state ~= "over" then record() end
  b, off, hit, scores = nil, nil, nil, nil
end

return app
