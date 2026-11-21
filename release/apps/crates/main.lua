-- Crates: push every crate onto a goal. You can push but never pull, and only
-- one crate at a time. Ten levels; undo, restart, fewest moves remembered.
local col = ui.col
local app = { title = "Crates", icon = "store", color = "teal", order = 68, category = "games" }
app.help = {
  { "Arrows", "Walk / push" },
  { "WASD", "Walk / push" },
  { "U", "Undo a move" },
  { "R", "Restart the level" },
  { "Enter", "Play / next level" },
  { "M", "Sound on/off" },
  { "Esc", "Levels / home" },
}

local gk = require("gamekit")

local CELL, MAXH = 11, 8
local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local WASD = { w = "up", a = "left", s = "down", d = "right" }
local LETTER = { up = "u", down = "d", left = "l", right = "r" }
local BACK = { u = "down", d = "up", l = "right", r = "left" }
local NAME = { u = "up", d = "down", l = "left", r = "right" }

local count          -- number of levels
local scores         -- data/crates/scores.txt: l<n> = fewest moves
local screen         -- "list" or "play"
local sel, top, rows
local lv, W, H, X0, Y0
local wall, goal, box, px, py, todo
local hist, moves    -- moves so far: lower case walk, upper case push
local solved
local s_level, s_moves, s_best, s_solved

local function best(n) return tonumber(scores["l" .. n]) end

local function build_rows()
  rows = {}
  for n = 1, count do
    local b = best(n)
    rows[n] = { label = "Level " .. n, value = b and (b .. " moves") or "", badge = b and "+" or nil,
      badge_color = ui.col.good }
  end
end

local function texts()
  s_level = "Level " .. lv .. "/" .. count
  s_moves = "Moves " .. moves
  s_solved = "Solved in " .. moves .. " moves"
  local b = best(lv)
  s_best = b and ("Best " .. b .. " moves") or "First solve!"
end

local function load_level(n)
  local levels = require("crates_levels")
  local map = levels[n]
  lv = n
  wall, goal, box, todo = {}, {}, {}, 0
  local y = 0
  W = 0
  for line in (map .. "|"):gmatch("([^|]*)|") do
    if #line > W then W = #line end
    for x = 1, #line do
      local c = line:sub(x, x)
      local i = y * 32 + x
      if c == "#" then wall[i] = true end
      if c == "." or c == "*" or c == "+" then goal[i] = true end
      if c == "$" or c == "*" then box[i] = true end
      if c == "$" then todo = todo + 1 end
      if c == "@" or c == "+" then px, py = x, y end
    end
    y = y + 1
  end
  H = y
  X0 = (240 - W * CELL) // 2 - CELL
  Y0 = 28 + (MAXH - H) * CELL // 2
  hist, moves, solved = {}, 0, false
  texts()
end

local function finish()
  solved = true
  local b = best(lv)
  texts()
  if not b or moves < b then
    scores["l" .. lv] = moves
    gk.save("crates", scores)
  end
  gk.beep(1047, 150)
end

local function move(d)
  local v = DIRS[d]
  local nx, ny = px + v[1], py + v[2]
  local i = ny * 32 + nx
  if wall[i] then return end
  local pushed = false
  if box[i] then
    local j = (ny + v[2]) * 32 + nx + v[1]
    if wall[j] or box[j] then gk.beep(200, 20); return end
    box[i], box[j] = nil, true
    if goal[i] then todo = todo + 1 end
    if goal[j] then todo = todo - 1 end
    pushed = true
  end
  px, py = nx, ny
  local l = LETTER[d]
  hist[#hist + 1] = pushed and l:upper() or l
  moves = moves + 1
  if pushed then gk.beep(330, 10) end
  if #hist > 600 then table.remove(hist, 1) end
  texts()
  if todo == 0 then finish() end
end

local function undo()
  local m = table.remove(hist)
  if not m then return end
  local l = m:lower()
  local v = DIRS[BACK[l]]          -- the way back
  local bx, by = px - v[1], py - v[2]  -- where a pushed crate now sits
  if m ~= l then
    local i, j = by * 32 + bx, py * 32 + px
    box[i], box[j] = nil, true
    if goal[i] then todo = todo + 1 end
    if goal[j] then todo = todo - 1 end
  end
  px, py = px + v[1], py + v[2]
  moves = moves - 1
  texts()
end

local function play(n)
  load_level(n)
  screen = "play"
end

function app.init(_, saved)
  local levels = require("crates_levels")
  count = #levels
  scores = gk.load("crates")
  sel, top, screen = 1, 1, "list"
  for n = 1, count do  -- start on the first unsolved level
    if not best(n) then sel = n; break end
  end
  build_rows()
  if saved and saved.lv and saved.lv <= count then
    play(saved.lv)
    for m in tostring(saved.h or ""):gmatch("[udlrUDLR]") do move(NAME[m:lower()]) end
  end
end

function app.save()
  if screen == "play" and not solved then return { lv = lv, h = table.concat(hist) } end
end

function app.draw()
  if screen == "list" then
    top = ui.list(rows, sel, top, 4, 17, 232, 15, 7)
    ui.footer({ { "Enter", "Play" }, { "Esc", "Home" } })
    return
  end
  ui.text(4, 17, s_level, col.text)
  ui.right(236, 17, s_moves, col.muted)
  for y = 0, H - 1 do
    local sy = Y0 + y * CELL
    for x = 1, W do
      local i = y * 32 + x
      local sx = X0 + x * CELL
      if wall[i] then
        gfx.fill(sx, sy, CELL, CELL, col.surface2)
      elseif box[i] then
        local c = goal[i] and col.good or col.warn
        gfx.rfill(sx + 1, sy + 1, CELL - 2, CELL - 2, 2, c)
        gfx.rect(sx + 3, sy + 3, CELL - 6, CELL - 6, col.bg)
      elseif goal[i] then
        gfx.circle(sx + 5, sy + 5, 2, col.accent)
      end
    end
  end
  gfx.disc(X0 + px * CELL + 5, Y0 + py * CELL + 5, 4, col.accent)
  if solved then
    ui.box(50, 50, 140, 46)
    ui.center(56, s_solved, col.good)
    ui.center(70, s_best, col.muted)
    ui.center(82, lv < count and "Enter: next level" or "All levels done!", col.muted)
    ui.footer({ { "Enter", "Next" }, { "U", "Undo" }, { "Esc", "Levels" } })
  else
    ui.footer({ { "U", "Undo" }, { "R", "Restart" }, { "Esc", "Levels" } })
  end
end

function app.key(k)
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if c == "m" then gk.toggle_sound(); return true end
  if screen == "list" then
    if k.key == "esc" then return false end
    local d = ui.nav(k)
    if d == "up" then sel = math.max(1, sel - 1)
    elseif d == "down" then sel = math.min(count, sel + 1)
    elseif k.key == "enter" then play(sel)
    else return d ~= nil end
    return true
  end
  if k.key == "esc" then
    screen = "list"
    sel = lv
    build_rows()
    return true
  end
  if c == "u" then undo(); solved = false; texts(); return true end
  if c == "r" then load_level(lv); return true end
  if solved then
    if k.key == "enter" then
      if lv < count then play(lv + 1) else screen, sel = "list", lv; build_rows() end
      return true
    end
    return false
  end
  local d = ui.nav(k) or WASD[c or ""]
  if d then move(d); return true end
  return false
end

function app.close()
  wall, goal, box, hist, rows, scores = nil, nil, nil, nil, nil, nil
end

return app
