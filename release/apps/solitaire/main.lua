-- Solitaire: build the four suits up from Ace to King. In the seven columns,
-- stack cards down in alternating colours; only a King goes in an empty one.
local col = ui.col
local app = { title = "Solitaire", icon = "note", color = "red", order = 74, category = "games" }
app.help = {
  { "Arrows", "Move / pick deeper" },
  { "Enter", "Pick up / put down" },
  { "Space", "Turn the deck" },
  { "F", "Send to a suit pile" },
  { "A", "All you can to suits" },
  { "U", "Undo" },
  { "Tab", "Draw 1 / draw 3" },
  { "N", "New deal" },
  { "Esc", "Drop / home" },
}

local gk = require("gamekit")

-- Cards are 0-51: rank = c % 13 + 1 (1 Ace .. 13 King), suit = c // 13
-- (0 spades, 1 hearts, 2 diamonds, 3 clubs; hearts and diamonds are red).
local CW, CH, GAP = 30, 22, 4
local TOP_Y, TAB_Y, MAX_Y = 16, 42, 122
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local FACE, INK, RED = gfx.rgb(236, 236, 228), gfx.rgb(25, 25, 30), gfx.rgb(200, 40, 40)

local stock, waste, found, tab, down
local draw3, moves, t, state, wins, best, scores
local cx, row, depth     -- cursor: column 0-6, row "top"/"tab", cards picked from a column
local held               -- { from = "waste"/"found"/"tab", i = column or suit, n = count }
local undo
local s_moves, s_time, s_mcount, s_won

local function rank(c) return c % 13 + 1 end
local function suit(c) return c // 13 end
local function red(c) local s = c // 13; return s == 1 or s == 2 end
local function colx(i) return 2 + i * (CW + GAP) end

local function texts()
  s_moves = "Moves " .. moves
  s_time = string.format("%d:%02d", math.floor(t) // 60, math.floor(t) % 60)
  s_mcount = tostring(moves)
  s_won = s_moves .. " in " .. s_time .. "  Wins " .. (wins[draw3 and 3 or 1] or 0)
end

-- The whole game as a short string, for undo and for coming back later.
local function enc(list)
  local s = {}
  for i, c in ipairs(list) do s[i] = string.char(65 + c) end
  return table.concat(s)
end
local function dec(s)
  local list = {}
  for i = 1, #s do list[i] = s:byte(i) - 65 end
  return list
end
local function snapshot()
  local parts = { enc(stock), enc(waste), table.concat(found, ",") }
  for i = 0, 6 do parts[#parts + 1] = down[i] .. ":" .. enc(tab[i]) end
  return table.concat(parts, "|")
end
local function restore(s)
  local parts = {}
  for p in (s .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = p end
  if #parts ~= 10 then return false end
  stock, waste = dec(parts[1]), dec(parts[2])
  found = {}
  for v in parts[3]:gmatch("%d+") do found[#found + 1] = tonumber(v) end
  if #found ~= 4 then return false end
  tab, down = {}, {}
  for i = 0, 6 do
    local d, cards = parts[4 + i]:match("^(%d+):(.*)$")
    if not d then return false end
    down[i], tab[i] = tonumber(d), dec(cards)
  end
  return true
end

local function push_undo()
  undo[#undo + 1] = snapshot()
  if #undo > 40 then table.remove(undo, 1) end
end

local function deal()
  local deck = {}
  for c = 0, 51 do deck[c + 1] = c end
  for i = 52, 2, -1 do local j = math.random(1, i); deck[i], deck[j] = deck[j], deck[i] end
  tab, down = {}, {}
  for i = 0, 6 do
    tab[i] = {}
    for _ = 0, i do tab[i][#tab[i] + 1] = table.remove(deck) end
    down[i] = i
  end
  stock, waste, found = deck, {}, { 0, 0, 0, 0 }
  moves, t, state, held, undo = 0, 0, "play", nil, {}
  cx, row, depth = 0, "top", 1
  texts()
end

local function flip(i)
  if #tab[i] > 0 and down[i] >= #tab[i] then down[i] = #tab[i] - 1 end
end

local function won()
  for s = 1, 4 do if found[s] < 13 then return false end end
  return true
end

local function after_move()
  moves = moves + 1
  for i = 0, 6 do flip(i) end
  if won() then
    state = "won"
    local k = draw3 and 3 or 1
    wins[k] = (wins[k] or 0) + 1
    scores["wins_" .. k] = wins[k]
    local secs = math.max(1, math.floor(t))
    if not best[k] or secs < best[k] then best[k] = secs; scores["best_" .. k] = secs end
    gk.save("solitaire", scores)
    gk.beep(1047, 200)
  end
  texts()
end

local function turn_deck()
  push_undo()
  if #stock == 0 then
    if #waste == 0 then table.remove(undo); return end
    for i = #waste, 1, -1 do stock[#stock + 1] = waste[i] end
    waste = {}
  else
    for _ = 1, draw3 and 3 or 1 do
      if #stock == 0 then break end
      waste[#waste + 1] = table.remove(stock)
    end
  end
  gk.beep(500, 10)
  after_move()
end

-- The cards a pick-up would take: the list they sit in, the first index, count.
local function source(h)
  if h.from == "waste" then return waste, #waste, 1 end
  if h.from == "found" then return nil end
  local list = tab[h.i]
  return list, #list - h.n + 1, h.n
end

local function first_held()
  if held.from == "found" then return (held.i - 1) * 13 + found[held.i] - 1 end
  local list, k = source(held)
  return list[k]
end

local function can_tab(c, i)
  local list = tab[i]
  local top = list[#list]
  if not top then return rank(c) == 13 end
  return red(c) ~= red(top) and rank(top) == rank(c) + 1
end

local function can_found(c) return found[suit(c) + 1] == rank(c) - 1 end

-- Takes the held cards off their pile and returns them in order.
local function take()
  if held.from == "found" then
    local s = held.i
    found[s] = found[s] - 1
    return { (s - 1) * 13 + found[s] }
  end
  local list, k, n = source(held)
  local out = {}
  for j = k, k + n - 1 do out[#out + 1] = list[j] end
  for _ = 1, n do table.remove(list) end
  return out
end

local function drop_on_tab(i)
  local c = first_held()
  if held.from == "tab" and held.i == i then held = nil; return true end
  if not can_tab(c, i) then return false end
  push_undo()
  for _, card in ipairs(take()) do tab[i][#tab[i] + 1] = card end
  held = nil
  gk.beep(700, 10)
  after_move()
  return true
end

local function drop_on_found()
  if held.from == "found" then held = nil; return true end
  if held.n ~= 1 then return false end
  local c = first_held()
  if not can_found(c) then return false end
  push_undo()
  take()
  found[suit(c) + 1] = rank(c)
  held = nil
  gk.beep(900, 15)
  after_move()
  return true
end

-- F: the card under the cursor (or the one picked up) goes to its suit pile.
local function send_up()
  if held then return drop_on_found() end
  if row == "top" and cx == 1 and #waste > 0 then held = { from = "waste", n = 1 }
  elseif row == "tab" and #tab[cx] > 0 then held = { from = "tab", i = cx, n = 1 }
  else return false end
  if drop_on_found() then return true end
  held = nil
  return false
end

local function auto()
  local any = true
  local n = 0
  while any and state == "play" do
    any = false
    if #waste > 0 and can_found(waste[#waste]) then
      held = { from = "waste", n = 1 }; drop_on_found(); any = true; n = n + 1
    end
    for i = 0, 6 do
      local list = tab[i]
      if #list > 0 and can_found(list[#list]) then
        held = { from = "tab", i = i, n = 1 }; drop_on_found(); any = true; n = n + 1
      end
    end
  end
  if n == 0 then shell.toast("Nothing can go up yet") end
end

local function pick()
  if row == "top" then
    if cx == 0 then turn_deck()
    elseif cx == 1 then
      if #waste > 0 then held = { from = "waste", n = 1 } end
    elseif cx >= 3 then
      local s = cx - 2
      if found[s] > 0 then held = { from = "found", i = s, n = 1 } end
    end
  else
    local face_up = #tab[cx] - down[cx]
    if face_up > 0 then held = { from = "tab", i = cx, n = math.min(depth, face_up) } end
  end
end

local function put()
  local ok
  if row == "tab" then ok = drop_on_tab(cx)
  elseif cx >= 3 then ok = drop_on_found()
  elseif cx == 1 and held.from == "waste" then held, ok = nil, true
  else ok = false end
  if not ok then gk.beep(200, 30); shell.toast("Can't go there") end
end

function app.init(_, saved)
  math.randomseed(sys.millis())
  scores = gk.load("solitaire")
  draw3 = scores.draw == "3"
  wins = { [1] = tonumber(scores.wins_1), [3] = tonumber(scores.wins_3) }
  best = { [1] = tonumber(scores.best_1), [3] = tonumber(scores.best_3) }
  deal()
  if saved and type(saved.g) == "string" then
    if restore(saved.g) then
      moves, t = tonumber(saved.m) or 0, tonumber(saved.t) or 0
      texts()
    else
      deal()
    end
  end
end

function app.save()
  if state == "play" then return { g = snapshot(), m = moves, t = t } end
end

function app.update(dt)
  if state ~= "play" then return end
  local before = math.floor(t)
  t = t + dt
  if math.floor(t) ~= before then texts() end
end

-- ---------------------------------------------------------------- drawing
local function pip(s, x, y, c)
  if s == 2 then  -- diamond
    gfx.tri(x + 3, y, x, y + 3, x + 6, y + 3, c); gfx.tri(x, y + 3, x + 6, y + 3, x + 3, y + 6, c)
  elseif s == 1 then  -- heart
    gfx.disc(x + 1, y + 2, 1, c); gfx.disc(x + 5, y + 2, 1, c); gfx.tri(x - 1, y + 2, x + 7, y + 2, x + 3, y + 6, c)
    gfx.fill(x + 1, y + 1, 5, 2, c)
  elseif s == 0 then  -- spade
    gfx.tri(x + 3, y, x - 1, y + 4, x + 7, y + 4, c); gfx.disc(x + 1, y + 4, 1, c); gfx.disc(x + 5, y + 4, 1, c)
    gfx.fill(x + 3, y + 4, 1, 3, c)
  else  -- club
    gfx.disc(x + 3, y + 1, 1, c); gfx.disc(x + 1, y + 4, 1, c); gfx.disc(x + 5, y + 4, 1, c)
    gfx.fill(x + 2, y + 2, 3, 3, c); gfx.fill(x + 3, y + 4, 1, 3, c)
  end
end

local function card(c, x, y, h)
  gfx.rfill(x, y, CW, h, 2, FACE)
  gfx.rrect(x, y, CW, h, 2, col.line)
  local ink = red(c) and RED or INK
  local r = RANKS[rank(c)]
  gfx.text(x + 2, y + 1, r, ink)
  pip(suit(c), x + 3 + #r * 6, y + 1, ink)
end

local function back(x, y, h)
  gfx.rfill(x, y, CW, h, 2, col.accent)
  gfx.rrect(x, y, CW, h, 2, col.line)
end

local function slot(x, y)
  gfx.rrect(x, y, CW, CH, 2, col.line)
end

-- Where the cards of column i sit: y of each card, from the bottom up.
local function layout(i)
  local list, d = tab[i], down[i]
  local up = #list - d
  local room = MAX_Y - TAB_Y - CH - d * 3
  local step = up > 1 and math.max(3, math.min(10, room // (up - 1))) or 10
  return d, step
end

local function is_held(from, i, k, n)
  if not held or held.from ~= from or held.i ~= i then return false end
  return k > n - held.n
end

function app.draw()
  -- stock, waste, suit piles
  local y = TOP_Y
  if #stock > 0 then back(colx(0), y, CH) else slot(colx(0), y) end
  if #waste > 0 then
    local c = waste[#waste]
    card(c, colx(1), y, CH)
    if held and held.from == "waste" then gfx.rrect(colx(1), y, CW, CH, 2, col.warn) end
  else slot(colx(1), y) end
  for s = 1, 4 do
    local x = colx(s + 2)
    if found[s] > 0 then card((s - 1) * 13 + found[s] - 1, x, y, CH)
    else slot(x, y); pip(s - 1, x + 12, y + 8, col.line) end
    if held and held.from == "found" and held.i == s then gfx.rrect(x, y, CW, CH, 2, col.warn) end
  end
  -- the seven columns; later cards overlap the ones under them
  for i = 0, 6 do
    local x, list = colx(i), tab[i]
    local d, step = layout(i)
    if #list == 0 then slot(x, TAB_Y) end
    local cy = TAB_Y
    for k = 1, #list do
      if k <= d then
        back(x, cy, CH)
        cy = cy + 3
      else
        card(list[k], x, cy, CH)
        if is_held("tab", i, k, #list) then gfx.rrect(x, cy, CW, CH, 2, col.warn) end
        cy = cy + step
      end
    end
  end
  -- cursor: around the cards that Enter would pick up
  local x = colx(cx)
  if row == "top" then
    gfx.rect(x - 1, TOP_Y - 1, CW + 2, CH + 2, col.accent)
  else
    local n = #tab[cx]
    local d, step = layout(cx)
    local y0, y1 = TAB_Y, TAB_Y + CH
    if n > 0 then
      local k = math.max(d + 1, n - depth + 1)
      y0 = TAB_Y + d * 3 + (k - 1 - d) * step
      y1 = TAB_Y + d * 3 + (n - 1 - d) * step + CH
    end
    gfx.rect(x - 1, y0 - 1, CW + 2, y1 - y0 + 2, col.accent)
  end
  ui.text(colx(2) + 1, TOP_Y + 1, s_time, col.muted)
  ui.text(colx(2) + 1, TOP_Y + 12, s_mcount, col.muted)
  if state == "won" then
    ui.box(40, 60, 160, 40)
    ui.center(66, "You won!", col.good, 1)
    ui.center(80, s_won, col.muted)
    ui.footer({ { "N", "New deal" }, { "Tab", "Draw 1/3" }, { "Esc", "Home" } })
  elseif held then
    ui.footer({ { "Enter", "Put down" }, { "F", "Up" }, { "Esc", "Cancel" } })
  else
    ui.footer({ { "Enter", "Pick" }, { "Spc", "Deck" }, { "F", "Up" }, { "U", "Undo" } })
  end
end

-- ---------------------------------------------------------------- keys
local function move_x(dx)
  cx = (cx + dx) % 7
  if row == "top" and cx == 2 then cx = (cx + dx) % 7 end
  depth = 1
end

function app.key(k)
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if k.key == "esc" then
    if held then held = nil; return true end
    return false
  end
  if c == "m" then gk.toggle_sound(); return true end
  if k.key == "tab" or c == "n" then
    local function go()
      if k.key == "tab" then
        draw3 = not draw3
        scores.draw = draw3 and "3" or "1"
        gk.save("solitaire", scores)
      end
      deal()
      shell.toast(draw3 and "New deal: draw 3" or "New deal: draw 1")
    end
    if state == "play" and moves > 0 then
      shell.confirm(k.key == "tab" and (draw3 and "Draw 1" or "Draw 3") or "New deal", "Start a new deal?", function(yes) if yes and scores then go() end end)
    else go() end
    return true
  end
  if state ~= "play" then return false end
  local d = ui.nav(k)
  if d == "left" then move_x(-1)
  elseif d == "right" then move_x(1)
  elseif d == "up" then
    if row == "tab" and not held and depth < #tab[cx] - down[cx] then depth = depth + 1
    else row, depth = "top", 1; if cx == 2 then cx = 1 end end
  elseif d == "down" then
    if row == "top" then row, depth = "tab", 1
    elseif depth > 1 then depth = depth - 1 end
  elseif k.key == "enter" then
    if held then put() else pick() end
  elseif c == " " then
    if not held then turn_deck() end
  elseif c == "f" then
    if not send_up() then gk.beep(200, 30) end
  elseif c == "a" then
    held = nil
    auto()
  elseif c == "u" then
    local s = table.remove(undo)
    if s then restore(s); held = nil; moves = moves + 1; texts() end
  else return false end
  return true
end

function app.close()
  stock, waste, tab, undo, scores = nil, nil, nil, nil, nil
end

return app
