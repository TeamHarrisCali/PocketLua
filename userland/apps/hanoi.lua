-- Hanoi: move the whole tower to the right-hand peg, one disc at a time,
-- never putting a disc on a smaller one. 3 to 8 discs; H shows the best move.
local col = ui.col
local app = { title = "Hanoi", icon = "tasks", color = "blue", order = 75, category = "games" }
app.help = {
  { "<>", "Choose a peg" },
  { "Enter", "Lift / drop a disc" },
  { "1-3", "Lift from / drop on" },
  { "H", "Hint" },
  { "U", "Undo" },
  { "Tab", "Number of discs" },
  { "R", "Restart" },
  { "Esc", "Drop / home" },
}

local gk = require("gamekit")

local PEGX = { 40, 120, 200 }
local BASE, DH = 116, 8         -- base line y, disc height
local COLORS = { "red", "orange", "green", "teal", "blue", "purple", "pink", "red" }

local n, pegs, sel, lifted, moves, hist, state
local best, scores, hint
local s_moves, s_least, s_best

local function least() return (1 << n) - 1 end

local function texts()
  s_moves = "Moves " .. moves
  s_least = "Fewest " .. least()
  s_best = best[n] and ("Best " .. best[n]) or ""
end

local function new_game()
  pegs = { {}, {}, {} }
  for d = n, 1, -1 do pegs[1][#pegs[1] + 1] = d end   -- bottom first, discs 1 (small) .. n
  sel, lifted, moves, hist, state, hint = 1, nil, 0, {}, "play", nil
  texts()
end

-- The best next move from any position: { from, to }.
local function best_move()
  local where = {}
  for p = 1, 3 do for _, d in ipairs(pegs[p]) do where[d] = p end end
  local target = 3
  local mv
  for d = n, 1, -1 do
    if where[d] ~= target then
      mv = { where[d], target }       -- disc d must go to target; smaller ones get out of the way
      target = 6 - where[d] - target
    end
  end
  -- the last (smallest) disc that needs moving is the one to move now
  return mv
end

local function do_move(from, to)
  local a, b = pegs[from], pegs[to]
  local d = a[#a]
  if not d or from == to then return false end
  if b[#b] and b[#b] < d then
    gk.beep(200, 30)
    shell.toast("A disc can't go on a smaller one")
    return false
  end
  hist[#hist + 1] = from * 10 + to
  table.remove(a)
  b[#b + 1] = d
  moves = moves + 1
  hint = nil
  gk.beep(500 + d * 60, 15)
  if #pegs[3] == n then
    state = "won"
    if not best[n] or moves < best[n] then
      best[n] = moves
      scores["best_" .. n] = moves
      gk.save("hanoi", scores)
    end
    gk.beep(1047, 200)
  end
  texts()
  return true
end

function app.init(_, saved)
  scores = gk.load("hanoi")
  best = {}
  for k = 3, 8 do best[k] = tonumber(scores["best_" .. k]) end
  n = tonumber(scores.discs) or 4
  if n < 3 or n > 8 then n = 4 end
  new_game()
  if saved and saved.n == n and type(saved.h) == "string" then
    for a, b in saved.h:gmatch("(%d)(%d)") do do_move(tonumber(a), tonumber(b)) end
  end
end

function app.save()
  if state ~= "play" then return nil end
  local h = {}
  for i, m in ipairs(hist) do h[i] = tostring(m) end
  return { n = n, h = table.concat(h) }
end

function app.draw()
  ui.text(4, 17, s_moves, col.text)
  ui.center(17, s_least, col.muted)
  ui.right(236, 17, s_best, col.muted)
  gfx.fill(4, BASE, 232, 3, col.line)
  local maxw = 72
  for p = 1, 3 do
    local x = PEGX[p]
    gfx.fill(x - 1, BASE - (n + 1) * DH - 4, 3, (n + 1) * DH + 4, p == sel and col.accent or col.line)
    local pile = pegs[p]
    for k, d in ipairs(pile) do
      local w = 14 + (maxw - 14) * (d - 1) // (n - 1)
      local y = BASE - k * DH
      if lifted == p and k == #pile then y = 30 end
      gfx.rfill(x - w // 2, y, w, DH - 1, 3, ui.accents[COLORS[d]])
    end
  end
  if hint then
    local a, b = PEGX[hint[1]], PEGX[hint[2]]
    gfx.line(a, 26, b, 26, col.warn)
    gfx.tri(b, 26, b + (b > a and -5 or 5), 23, b + (b > a and -5 or 5), 29, col.warn)
  end
  if state == "won" then
    ui.box(50, 40, 140, 40)
    ui.center(46, s_moves, col.good)
    ui.center(62, moves == least() and "The fewest possible!" or s_least, col.muted)
    ui.footer({ { "Enter", "Again" }, { "Tab", "Discs" }, { "Esc", "Home" } })
  elseif lifted then
    ui.footer({ { "<>", "Peg" }, { "Enter", "Drop" }, { "Esc", "Cancel" } })
  else
    ui.footer({ { "<>", "Peg" }, { "Enter", "Lift" }, { "H", "Hint" }, { "U", "Undo" } })
  end
end

local function lift_or_drop(p)
  if lifted then
    local from = lifted
    lifted = nil
    if from ~= p then do_move(from, p) end
  elseif #pegs[p] > 0 then
    lifted = p
  end
end

function app.key(k)
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if k.key == "esc" then
    if lifted then lifted = nil; return true end
    return false
  end
  if c == "m" then gk.toggle_sound(); return true end
  if k.key == "tab" then
    n = k.shift and ((n - 4) % 6 + 3) or (n - 2) % 6 + 3
    scores.discs = n
    gk.save("hanoi", scores)
    new_game()
    shell.toast(n .. " discs")
    return true
  end
  if c == "r" or (state == "won" and k.key == "enter") then new_game(); return true end
  if state ~= "play" then return false end
  local d = ui.nav(k)
  if d == "left" then sel = (sel - 2) % 3 + 1
  elseif d == "right" then sel = sel % 3 + 1
  elseif k.key == "enter" or c == " " then lift_or_drop(sel)
  elseif c and c:match("^[123]$") then sel = tonumber(c); lift_or_drop(sel)
  elseif c == "h" then hint = best_move(); lifted = nil
  elseif c == "u" then
    local m = table.remove(hist)
    if m then
      local from, to = m // 10, m % 10
      table.insert(pegs[from], table.remove(pegs[to]))
      moves = moves + 1
      lifted, hint = nil, nil
      texts()
    end
  else return d ~= nil end
  return true
end

function app.close()
  pegs, hist, scores = nil, nil, nil
end

return app
