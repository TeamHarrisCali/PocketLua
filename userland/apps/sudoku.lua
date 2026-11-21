-- Sudoku: fill the grid so every row, column and 3x3 box has 1 to 9 once.
-- Three levels, pencil notes, undo; a game in progress is kept when you leave.
local col = ui.col
local app = { title = "Sudoku", icon = "grid", color = "blue", order = 69, category = "games" }
app.help = {
  { "Arrows", "Move" },
  { "1-9", "Write a number" },
  { "0/Bksp", "Erase" },
  { "N", "Notes on/off" },
  { "U", "Undo" },
  { "Enter", "Start a game" },
  { "Esc", "Menu / home" },
}

local gk = require("gamekit")

-- Puzzles with one solution each (made with a solver). Every game shuffles
-- digits, rows and columns, so the same puzzle rarely looks the same twice.
local PUZZLES = {
  { ".5..317.2.637...8...146.39..849...57.9...5..3..2..7........351.1...9..36.3..149.8",
    ".4..5..76....17.4.17..24..952.74..9.4....13...195.67..23..6....89.....5..5.439..8",
    "78.4..1..21..38..4...5..38..7.39...83.2...4798.1..753.437....6.9.6.2..41.....4...",
    "34....16..1846.2......35.8....38.5..5...4.8278.9.5.......79..38..6...972.3.6.841.",
    "5...39.7474...5.86..3..7.5..96.5.827..8....1..3...6.95..2...5.9.7..62..8.6..937..",
    "12694..5....13...4348..5.19..3419..72............7..38754.6.981.8..9....9..7..6.." },
  { "6....9.87......9..5.7..2..1.1..46..935.9...1..7.....6..48.....5...81...4.3.294...",
    "3867...2.1.....7....4.9..8.9..6.52.7......81...8.3...6..34.9.7.......6.3.19..3...",
    "4238.....7.9.3.4..8..2..6.3..6.4.....3.6.8...1.4..3.6.9...............27...4823.1",
    "1.....843...438.6.......7..47...6.9..8.1......9....126...54.....3.6..4....4389..5",
    ".49....2.8.2.793..3.....46.578.2.......7..5......6.9.293..48.......97..4....1...3",
    "..5.....3..362.74..9...8.5194.1.3......47.....87.9....67..5...2..92...3.....6.1.." },
  { "..9.6.5.8.6..917......5.......4.6.21.8...3....2..15..65......8...7....9.4....9..7",
    "....13...1.9.....4.4825..3...3...4...9......5654...........1.9.92..8.1.....7...8.",
    "6....9.87......9..5.7..2..1.1..46..93......1..7.....6...8.....5...81...4.3.29....",
    "...92....2.....9.4.8......287.....9...98.6.....5..1....541.73.......47...3.....8.",
    ".867...2.1.....7....4.9..8.9..6..2........81...8.3...6..34...7.......6.3.19..3...",
    ".2.8.....7.9.3.4..8.....6.3..6.4.....3.6.8...1.4..3.6.9...............27...4823.1" },
}
local TIERS = { "Easy", "Medium", "Hard" }
local KEYS = { "easy", "medium", "hard" }
local FILE = "data/sudoku/current.txt"
local CELL, X0, Y0 = 11, 4, 18
local DIGITS = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }

local screen          -- "menu" or "play"
local sel, rows
local scores, best
local tier, given, val, notes, bad, undo_stack
local cx, cy, pencil, t, solved
local left           -- left[d] = how many d are still to place
local s_time, s_tier, s_best

local function pos(c) return c * CELL + (c // 3) * 2 end

local function fmt(secs)
  secs = math.floor(secs)
  return string.format("%d:%02d", secs // 60, secs % 60)
end

local function build_rows()
  rows = {}
  if tier and not solved then rows[1] = { label = "Continue", value = TIERS[tier] .. "  " .. fmt(t) } end
  for i = 1, 3 do
    rows[#rows + 1] = { label = "New " .. TIERS[i], value = best[i] and ("Best " .. fmt(best[i])) or "" }
  end
end

local function texts()
  s_time, s_tier = fmt(t), TIERS[tier]
  s_best = best[tier] and ("Best " .. fmt(best[tier])) or ""
end

-- Marks every number that repeats in its row, column or box.
local function check()
  bad = {}
  left = { 9, 9, 9, 9, 9, 9, 9, 9, 9 }
  local full = true
  for i = 0, 80 do
    local v = val[i]
    if v == 0 then full = false
    else
      left[v] = left[v] - 1
      local r, c = i // 9, i % 9
      for k = 0, 8 do
        local a, b = r * 9 + k, k * 9 + c
        local bx = (r // 3 * 3 + k // 3) * 9 + c // 3 * 3 + k % 3
        if (a ~= i and val[a] == v) or (b ~= i and val[b] == v) or (bx ~= i and val[bx] == v) then bad[i] = true end
      end
    end
  end
  return full and next(bad) == nil
end

-- A random relabelling of digits, rows (within bands, and bands) and columns.
local function shuffled3()
  local a = { 0, 1, 2 }
  for i = 3, 2, -1 do local j = math.random(1, i); a[i], a[j] = a[j], a[i] end
  return a
end
local function line_order()
  local bands, out = shuffled3(), {}
  for b = 1, 3 do
    local inner = shuffled3()
    for k = 1, 3 do out[#out + 1] = bands[b] * 3 + inner[k] end
  end
  return out
end

local function new_game(n)
  tier = n
  local list = PUZZLES[n]
  local p = list[math.random(1, #list)]
  local digit = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
  for i = 9, 2, -1 do local j = math.random(1, i); digit[i], digit[j] = digit[j], digit[i] end
  local ro, co, flip = line_order(), line_order(), math.random(0, 1) == 1
  given, val, notes, undo_stack = {}, {}, {}, {}
  for r = 0, 8 do
    for c = 0, 8 do
      local sr, sc = ro[r + 1], co[c + 1]
      if flip then sr, sc = sc, sr end
      local ch = p:sub(sr * 9 + sc + 1, sr * 9 + sc + 1)
      local i = r * 9 + c
      val[i] = ch == "." and 0 or digit[tonumber(ch)]
      given[i], notes[i] = val[i] ~= 0, 0
    end
  end
  cx, cy, pencil, t, solved = 4, 4, false, 0, false
  check()
  texts()
end

local function save_game()
  if not tier or solved then sys.remove(FILE); return end
  local v, g, n = {}, {}, {}
  for i = 0, 80 do
    v[i + 1] = tostring(val[i])
    g[i + 1] = given[i] and "1" or "0"
    n[i + 1] = string.format("%03x", notes[i])
  end
  sys.mkdirs("data/sudoku")
  sys.write_text(FILE, table.concat({ tier, math.floor(t), table.concat(v), table.concat(g), table.concat(n) }, "\n") .. "\n")
end

local function load_game()
  local s = sys.read_text(FILE, 1024)
  if not s then return end
  local tr, ts, v, g, n = s:match("^(%d)\n(%d+)\n(%d+)\n([01]+)\n(%x+)")
  if not tr or #v ~= 81 or #g ~= 81 or #n ~= 243 then return end
  tier, t = tonumber(tr), tonumber(ts)
  if not PUZZLES[tier] then tier = nil; return end
  given, val, notes, undo_stack = {}, {}, {}, {}
  for i = 0, 80 do
    val[i] = tonumber(v:sub(i + 1, i + 1))
    given[i] = g:sub(i + 1, i + 1) == "1"
    notes[i] = tonumber(n:sub(i * 3 + 1, i * 3 + 3), 16)
  end
  cx, cy, pencil, solved = 4, 4, false, false
  check()
  texts()
end

local function set(i, v, nmask)
  undo_stack[#undo_stack + 1] = { i, val[i], notes[i] }
  if #undo_stack > 200 then table.remove(undo_stack, 1) end
  val[i], notes[i] = v, nmask
  if check() then
    solved = true
    local secs = math.max(1, math.floor(t))
    if not best[tier] or secs < best[tier] then
      best[tier] = secs
      scores[KEYS[tier]] = secs
      gk.save("sudoku", scores)
    end
    sys.remove(FILE)
    gk.beep(1047, 150)
  end
  texts()
end

local function write(d)
  local i = cy * 9 + cx
  if given[i] or solved then return end
  if pencil and d > 0 then
    if val[i] == 0 then set(i, 0, notes[i] ~ (1 << (d - 1))) end
  else
    set(i, val[i] == d and 0 or d, 0)
    gk.beep(660, 10)
  end
end

local function undo()
  local u = table.remove(undo_stack)
  if not u then return end
  val[u[1]], notes[u[1]] = u[2], u[3]
  cx, cy = u[1] % 9, u[1] // 9
  solved = false
  check()
  texts()
end

function app.init()
  math.randomseed(sys.millis())
  scores = gk.load("sudoku")
  best = {}
  for i, k in ipairs(KEYS) do best[i] = tonumber(scores[k]) end
  load_game()
  screen, sel = "menu", 1
  build_rows()
end

function app.update(dt)
  if screen == "play" and not solved then
    local before = math.floor(t)
    t = t + dt
    if math.floor(t) ~= before then s_time = fmt(t) end
  end
end

local function draw_board()
  local cur = val[cy * 9 + cx]
  gfx.fill(X0 - 1, Y0 - 1, pos(9) - 1, pos(9) - 1, col.line)
  for r = 0, 8 do
    local py = Y0 + pos(r)
    for c = 0, 8 do
      local px = X0 + pos(c)
      local i = r * 9 + c
      local v = val[i]
      gfx.fill(px, py, CELL - 1, CELL - 1, (v ~= 0 and v == cur) and col.surface2 or col.bg)
      if v ~= 0 then
        gfx.text(px + 3, py + 2, DIGITS[v], bad[i] and col.bad or (given[i] and col.text or col.accent))
      elseif notes[i] ~= 0 then
        local m = notes[i]
        for d = 0, 8 do
          if m & (1 << d) ~= 0 then gfx.fill(px + 1 + (d % 3) * 3, py + 1 + (d // 3) * 3, 2, 2, col.muted) end
        end
      end
    end
  end
  gfx.rect(X0 + pos(cx) - 1, Y0 + pos(cy) - 1, CELL + 1, CELL + 1, pencil and col.warn or col.accent)
end

function app.draw()
  if screen == "menu" then
    ui.list(rows, sel, 1, 4, 17, 232, 16, #rows)
    ui.footer({ { "Enter", "Play" }, { "Esc", "Home" } })
    return
  end
  draw_board()
  local x = 116
  ui.text(x, 20, s_tier, col.text)
  ui.right(236, 20, s_time, col.muted)
  ui.text(x, 34, pencil and "Notes" or "Pen", pencil and col.warn or col.accent)
  ui.right(236, 34, s_best, col.muted)
  for d = 1, 9 do  -- numbers still to place
    local bx, by = x + (d - 1) * 13, 52
    gfx.rfill(bx, by, 11, 13, 2, left[d] > 0 and col.surface2 or col.surface)
    gfx.text(bx + 3, by + 3, DIGITS[d], left[d] > 0 and col.text or col.muted)
  end
  if solved then
    ui.box(118, 74, 118, 38)
    gfx.text(130, 80, "Solved!", col.good)
    gfx.text(130, 94, s_time, col.text)
    ui.footer({ { "Enter", "Menu" }, { "Esc", "Menu" } })
  else
    ui.footer({ { "1-9", "Write" }, { "N", "Notes" }, { "U", "Undo" }, { "Esc", "Menu" } })
  end
end

function app.key(k)
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if c == "m" then gk.toggle_sound(); return true end
  if screen == "menu" then
    if k.key == "esc" then return false end
    local d = ui.nav(k)
    if d == "up" then sel = math.max(1, sel - 1)
    elseif d == "down" then sel = math.min(#rows, sel + 1)
    elseif k.key == "enter" then
      local cont = tier and not solved
      if cont and sel == 1 then screen = "play"
      else new_game(sel - (cont and 1 or 0)); screen = "play" end
    else return d ~= nil end
    return true
  end
  if k.key == "esc" or (solved and k.key == "enter") then
    save_game()
    screen, sel = "menu", 1
    build_rows()
    return true
  end
  local d = ui.nav(k)
  if d == "up" then cy = (cy - 1) % 9
  elseif d == "down" then cy = (cy + 1) % 9
  elseif d == "left" then cx = (cx - 1) % 9
  elseif d == "right" then cx = (cx + 1) % 9
  elseif c and c:match("^[1-9]$") then write(tonumber(c))
  elseif c == "0" or c == " " or k.key == "backspace" or k.key == "delete" then
    local i = cy * 9 + cx
    if not given[i] and not solved and (val[i] ~= 0 or notes[i] ~= 0) then set(i, 0, 0) end
  elseif c == "n" then pencil = not pencil
  elseif c == "u" then undo()
  else return false end
  return true
end

function app.close()
  if screen == "play" or tier then save_game() end
  given, val, notes, bad, undo_stack, rows, scores = nil, nil, nil, nil, nil, nil, nil
end

return app
