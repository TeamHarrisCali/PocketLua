-- Mines: clear the field without digging up a mine. Numbers count the mines
-- next to a square; flag the ones you are sure of. Three sizes, best times.
local col = ui.col
local app = { title = "Mines", icon = "warn", color = "red", order = 65, category = "games" }
app.help = {
  { "Arrows", "Move" },
  { "Enter", "Dig / open around" },
  { "F", "Flag" },
  { "Space", "Flag" },
  { "Tab", "Board size" },
  { "N", "New game" },
  { "M", "Sound on/off" },
  { "Esc", "Home" },
}

local gk = require("gamekit")

local SIZES = {   -- columns, rows, mines
  { 9, 8, 10 }, { 14, 8, 22 }, { 20, 8, 36 },
}
local TABS = { "Small", "Medium", "Large" }
local KEYS = { "small", "medium", "large" }
local CELL, Y0, ROWS = 11, 33, 8
local NUMC = { "blue", "green", "red", "purple", "orange", "teal", "pink" }
local DIG = { "1", "2", "3", "4", "5", "6", "7", "8" }

local size, W, H, N, X0
local mine, adj, st    -- per cell (index y * W + x + 1): bool, count, 0 hidden / 1 open / 2 flag
local cx, cy
local state            -- "ready" (no mines yet), "play", "won", "lost"
local opened, flags, t, best
local s_info, s_time, s_best  -- cached strings for draw()
local scores

local function texts()
  s_time = string.format("%d s", math.floor(t))
  s_info = (N - flags) .. " left  " .. s_time
  local b = best[size]
  s_best = b and ("Best " .. b .. " s") or "No best time yet"
end

local function new_game()
  W, H, N = SIZES[size][1], SIZES[size][2], SIZES[size][3]
  X0 = (240 - W * CELL) // 2
  mine, adj, st = {}, {}, {}
  for i = 1, W * H do mine[i], adj[i], st[i] = false, 0, 0 end
  cx, cy = W // 2, H // 2
  state, opened, flags, t = "ready", 0, 0, 0
  texts()
end

local function each_near(x, y, fn)
  for dy = -1, 1 do
    for dx = -1, 1 do
      local nx, ny = x + dx, y + dy
      if (dx ~= 0 or dy ~= 0) and nx >= 0 and nx < W and ny >= 0 and ny < H then fn(nx, ny, ny * W + nx + 1) end
    end
  end
end

-- Mines go down on the first dig, never on or next to that square.
local function lay(sx, sy)
  local free = {}
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      if math.abs(x - sx) > 1 or math.abs(y - sy) > 1 then free[#free + 1] = y * W + x + 1 end
    end
  end
  for _ = 1, N do
    local j = math.random(1, #free)
    local i = free[j]
    free[j] = free[#free]
    free[#free] = nil
    mine[i] = true
    each_near((i - 1) % W, (i - 1) // W, function(_, _, k) adj[k] = adj[k] + 1 end)
  end
end

local function finish(won)
  state = won and "won" or "lost"
  if won then
    local secs = math.max(1, math.floor(t))
    if not best[size] or secs < best[size] then
      best[size] = secs
      scores[KEYS[size]] = secs
      gk.save("mines", scores)
    end
    gk.beep(1047, 120)
  else
    gk.beep(150, 300)
  end
  texts()
end

-- Opens one square; blank squares open their neighbours too.
local function open(x, y)
  local i = y * W + x + 1
  if st[i] ~= 0 then return end
  if mine[i] then st[i] = 1; finish(false); return end
  local stack = { i }
  while #stack > 0 do
    local k = table.remove(stack)
    if st[k] == 0 then
      st[k] = 1
      opened = opened + 1
      if adj[k] == 0 then
        each_near((k - 1) % W, (k - 1) // W, function(_, _, n)
          if st[n] == 0 and not mine[n] then stack[#stack + 1] = n end
        end)
      end
    end
  end
  if opened == W * H - N then finish(true) end
end

local function dig()
  local i = cy * W + cx + 1
  if state == "ready" then lay(cx, cy); state = "play" end
  if st[i] == 0 then
    open(cx, cy)
    gk.beep(660, 15)
  elseif st[i] == 1 and adj[i] > 0 then
    -- an open number with as many flags around it opens the rest
    local f = 0
    each_near(cx, cy, function(_, _, k) if st[k] == 2 then f = f + 1 end end)
    if f == adj[i] then
      each_near(cx, cy, function(x, y) if state == "play" then open(x, y) end end)
    end
  end
end

local function flag()
  local i = cy * W + cx + 1
  if st[i] == 1 then return end
  if st[i] == 2 then st[i], flags = 0, flags - 1 else st[i], flags = 2, flags + 1 end
  gk.beep(440, 15)
  texts()
end

function app.init()
  math.randomseed(sys.millis())
  scores = gk.load("mines")
  best = {}
  for i, k in ipairs(KEYS) do best[i] = tonumber(scores[k]) end
  size = 1
  new_game()
end

function app.update(dt)
  if state == "play" then
    local before = math.floor(t)
    t = t + dt
    if math.floor(t) ~= before then texts() end
  end
end

function app.draw()
  ui.tabs(TABS, size, 16)
  local over = state == "won" or state == "lost"
  for y = 0, H - 1 do
    local py = Y0 + y * CELL
    for x = 0, W - 1 do
      local px = X0 + x * CELL
      local i = y * W + x + 1
      local s = st[i]
      if s == 1 then
        gfx.fill(px, py, CELL - 1, CELL - 1, mine[i] and col.bad or col.surface)
        if mine[i] then
          gfx.disc(px + 5, py + 5, 3, col.text)
        elseif adj[i] > 0 then
          gfx.text(px + 3, py + 2, DIG[adj[i]], NUMC[adj[i]] and ui.accents[NUMC[adj[i]]] or col.text)
        end
      else
        gfx.fill(px, py, CELL - 1, CELL - 1, col.surface2)
        if over and mine[i] and s ~= 2 then
          gfx.disc(px + 5, py + 5, 3, col.muted)
        elseif s == 2 then
          gfx.fill(px + 3, py + 2, 1, 7, col.text)
          gfx.tri(px + 4, py + 2, px + 8, py + 4, px + 4, py + 6, over and not mine[i] and col.muted or col.bad)
        end
      end
    end
  end
  if not over then
    gfx.rect(X0 + cx * CELL - 1, Y0 + cy * CELL - 1, CELL + 1, CELL + 1, col.accent)
  end
  if state == "won" then
    ui.box(60, 50, 120, 46)
    ui.center(56, "Cleared in " .. s_time, col.good)
    ui.center(70, s_best, col.muted)
    ui.center(82, "Enter: play again", col.muted)
  elseif state == "lost" then
    ui.box(60, 50, 120, 34)
    ui.center(56, "Boom!", col.bad)
    ui.center(70, "Enter: play again", col.muted)
  end
  if over then
    ui.footer({ { "Enter", "Again" }, { "Tab", "Size" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Enter", "Dig" }, { "F", "Flag" } })
    ui.right(236, 126, s_info, col.muted)
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  if k.key == "tab" then
    size = k.shift and (size + 1) % 3 + 1 or size % 3 + 1
    new_game()
    return true
  end
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if c == "m" then gk.toggle_sound(); return true end
  if c == "n" then new_game(); return true end
  if state == "won" or state == "lost" then
    if k.key == "enter" then new_game(); return true end
    return ui.nav(k) ~= nil
  end
  local d = ui.nav(k)
  if d == "up" then cy = (cy - 1) % H
  elseif d == "down" then cy = (cy + 1) % H
  elseif d == "left" then cx = (cx - 1) % W
  elseif d == "right" then cx = (cx + 1) % W
  elseif k.key == "enter" then dig()
  elseif c == "f" or c == " " then flag()
  else return false end
  return true
end

function app.close()
  mine, adj, st, scores = nil, nil, nil, nil
end

return app
