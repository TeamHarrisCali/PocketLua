-- 2048 rules, kept free of drawing so they can be tested on their own.
-- A board is a flat array of 16 exponents (0 = empty, 1 = "2", 11 = "2048"),
-- index = row * 4 + col + 1.
local M = {}

-- Slides one line toward its first cell and merges equal neighbours once.
-- line: array of 4 exponents, changed in place. Returns points, moved, top.
function M.slide(line)
  local out, n, points, top = { 0, 0, 0, 0 }, 0, 0, 0
  local last_merged = false
  for i = 1, 4 do
    local v = line[i]
    if v ~= 0 then
      if n > 0 and out[n] == v and not last_merged then
        out[n] = v + 1
        points = points + (1 << (v + 1))
        last_merged = true
        if v + 1 > top then top = v + 1 end
      else
        n = n + 1
        out[n] = v
        last_merged = false
      end
    end
  end
  local moved = false
  for i = 1, 4 do
    if line[i] ~= out[i] then moved = true end
    line[i] = out[i]
  end
  return points, moved, top
end

-- Start cell and step (in board indices) for each line, per direction.
local STARTS = {
  left  = { 1, 5, 9, 13, 1 },     -- 4 starts, then the step along the line
  right = { 4, 8, 12, 16, -1 },
  up    = { 1, 2, 3, 4, 4 },
  down  = { 13, 14, 15, 16, -4 },
}

-- Moves the whole board. Returns moved, points, highest merged exponent.
function M.move(b, dir)
  local s = STARTS[dir]
  local step = s[5]
  local line = { 0, 0, 0, 0 }
  local any, points, top = false, 0, 0
  for l = 1, 4 do
    local i0 = s[l]
    for i = 1, 4 do line[i] = b[i0 + (i - 1) * step] end
    local p, moved, t = M.slide(line)
    if moved then
      any = true
      for i = 1, 4 do b[i0 + (i - 1) * step] = line[i] end
    end
    points = points + p
    if t > top then top = t end
  end
  return any, points, top
end

function M.can_move(b)
  for i = 1, 16 do
    local v = b[i]
    if v == 0 then return true end
    if i % 4 ~= 0 and b[i + 1] == v then return true end
    if i <= 12 and b[i + 4] == v then return true end
  end
  return false
end

-- Puts a 2 (90%) or a 4 in a random empty cell. Returns its index or nil.
function M.add_tile(b)
  local empty = 0
  for i = 1, 16 do if b[i] == 0 then empty = empty + 1 end end
  if empty == 0 then return nil end
  local n = math.random(1, empty)
  for i = 1, 16 do
    if b[i] == 0 then
      n = n - 1
      if n == 0 then
        b[i] = math.random(1, 10) == 1 and 2 or 1
        return i
      end
    end
  end
end

return M
