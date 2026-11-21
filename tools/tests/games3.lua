-- Headless tests for the third batch of games (sudoku, reversi, codebreaker, hop, gems, solitaire, hanoi, wordy).
-- Run from the project root:  lua5.4 tools/tests/games3.lua
local say = print
local src = assert(io.open("tools/host_test.lua")):read("a")
assert(load(src:match("^(.-)%-%- %-+ helpers"), "=stubs"))()
dofile("tools/emu/boot.lua")

local fails, oks = 0, 0
local function check(c, m)
  if c then oks = oks + 1; say("ok:   " .. m) else fails = fails + 1; say("FAIL: " .. m) end
end
local function frames(n) for _ = 1, n or 3 do on_frame(0.033); on_draw(); on_draw(); on_draw() end end
local function key(name, mods)
  local k = { key = name }
  if #name == 1 or name == "space" then k.text = name == "space" and " " or name end
  for m in pairs(mods or {}) do k[m] = true end
  on_key(k)
  frames(1)
end

-- Record what one screen draws: text, and the discs (mines, balls).
local drawn, discs, recording = {}, {}, false
local rfills = {}
local real_text, real_disc, real_rfill = gfx.text, gfx.disc, gfx.rfill
gfx.rfill = function(x, y, w, h, rad, c, ...)
  if recording then rfills[#rfills + 1] = { x, y, w, h, c } end
  return real_rfill(x, y, w, h, rad, c, ...)
end
local texts_at = {}
gfx.text = function(x, y, s, c, ...)
  if recording then drawn[#drawn + 1] = s; texts_at[#texts_at + 1] = { x, y, s, c } end
  return real_text(x, y, s, c, ...)
end
gfx.disc = function(x, y, r, c, ...)
  if recording then discs[#discs + 1] = { x, y, r, c } end
  return real_disc(x, y, r, c, ...)
end
local fills = {}
local real_fill = gfx.fill
gfx.fill = function(x, y, w, h, c, ...)
  if recording then fills[#fills + 1] = { x, y, w, h, c } end
  return real_fill(x, y, w, h, c, ...)
end
local lines = {}
local real_line = gfx.line
gfx.line = function(x1, y1, x2, y2, ...)
  if recording then lines[#lines + 1] = { x1, y1, x2, y2 } end
  return real_line(x1, y1, x2, y2, ...)
end
local circles = {}
local real_circle = gfx.circle
gfx.circle = function(x, y, r, ...)
  if recording then circles[#circles + 1] = { x, y, r } end
  return real_circle(x, y, r, ...)
end
local function screen()
  drawn, discs, rfills, texts_at, circles, fills, lines, recording = {}, {}, {}, {}, {}, {}, {}, true
  on_draw()
  recording = false
  return table.concat(drawn, "\n")
end
local function capture(draw)
  drawn, discs, rfills, texts_at, circles, fills, lines, recording = {}, {}, {}, {}, {}, {}, {}, true
  draw()
  recording = false
  return table.concat(drawn, "\n")
end
local function shows(s) return screen():find(s, 1, true) ~= nil end
local function alive(name, what) check(shell.app() == name, name .. ": " .. what) end

-- A random sequence the tests can replay.
local real_random, real_seed = math.random, math.randomseed
local rng = 1
local function fake_random(a, b)
  rng = (rng * 1103515245 + 12345) % 2147483648
  if not a then return rng / 2147483648 end
  if not b then a, b = 1, a end
  return a + rng % (b - a + 1)
end
local function replay(seed) rng = seed; math.random, math.randomseed = fake_random, function() end end
local function unreplay() math.random, math.randomseed = real_random, real_seed end

frames(30)  -- let the boot sound finish
local quiet = 0
local real_tone = snd.tone
snd.tone = function(...) quiet = quiet + 1; return real_tone(...) end

-- ------------------------------------------------------------ sudoku
sys.remove("data/sudoku/current.txt"); sys.remove("data/sudoku/scores.txt")
local POS = {}  -- screen x (or y) of a digit -> column (or row)
for c = 0, 8 do POS[4 + c * 11 + (c // 3) * 2 + 3] = c end
local function board()
  screen()
  local g, colour = {}, {}
  for i = 0, 80 do g[i] = 0 end
  for _, t in ipairs(texts_at) do
    local c, r = POS[t[1]], POS[t[2] - 13]
    if c and r and t[3]:match("^%d$") then g[r * 9 + c] = tonumber(t[3]); colour[r * 9 + c] = t[4] end
  end
  return g, colour
end
local function ok_at(g, i, v)
  local r, c = i // 9, i % 9
  for k = 0, 8 do
    if g[r * 9 + k] == v or g[k * 9 + c] == v then return false end
    if g[(r // 3 * 3 + k // 3) * 9 + c // 3 * 3 + k % 3] == v then return false end
  end
  return true
end
local function solve(g)
  for i = 0, 80 do
    if g[i] == 0 then
      for v = 1, 9 do
        if ok_at(g, i, v) then g[i] = v; if solve(g) then return true end; g[i] = 0 end
      end
      return false
    end
  end
  return true
end
local sx, sy = 4, 4
local function go(x, y)
  while sx < x do key("right"); sx = sx + 1 end
  while sx > x do key("left"); sx = sx - 1 end
  while sy < y do key("down"); sy = sy + 1 end
  while sy > y do key("up"); sy = sy - 1 end
end
shell.launch("sudoku"); frames(3)
alive("sudoku", "opens")
check(shows("New Easy") and shows("New Hard") and not shows("Continue"), "sudoku: menu lists the levels")
key("enter")
local g0 = board()
local givens = 0
for i = 0, 80 do if g0[i] ~= 0 then givens = givens + 1 end end
check(givens >= 30 and givens <= 40, "sudoku: an easy puzzle has " .. givens .. " numbers")
local sol = {}
for i = 0, 80 do sol[i] = g0[i] end
check(solve(sol), "sudoku: the puzzle can be solved")
-- an empty cell, and a number that clashes with its row
local empty
for i = 0, 80 do if g0[i] == 0 then empty = i; break end end
local clash
for c = 0, 8 do local v = g0[(empty // 9) * 9 + c]; if v ~= 0 then clash = v; break end end
go(empty % 9, empty // 9)
key(tostring(clash))
local g1, cl = board()
check(g1[empty] == clash and cl[empty] == ui.col.bad, "sudoku: a clashing number shows in red")
key("backspace")
check(board()[empty] == 0, "sudoku: Backspace erases")
key("n"); key("1"); key("5")
check(shows("Notes"), "sudoku: N switches to notes")
check(board()[empty] == 0, "sudoku: notes do not fill the cell")
key("n")
key(tostring(sol[empty]))
key("u")
check(board()[empty] == 0, "sudoku: U undoes")
key(tostring(sol[empty]))
key("esc")
check(shows("Continue"), "sudoku: Esc goes to the menu with Continue")
shell.home(); frames(2)
check(sys.read_text("data/sudoku/current.txt") ~= nil, "sudoku: the game is written to data/sudoku")
shell.launch("sudoku"); frames(2)
key("enter")
sx, sy = 4, 4
local g2 = board()
local same = true
for i = 0, 80 do if g2[i] ~= (i == empty and sol[empty] or g0[i]) then same = false end end
check(same, "sudoku: Continue brings back the same board")
for i = 0, 80 do
  if g2[i] == 0 then go(i % 9, i // 9); key(tostring(sol[i])) end
end
check(shows("Solved!"), "sudoku: filling the grid correctly solves it")
local ss = sys.read_text("data/sudoku/scores.txt")
check(ss and ss:match("easy=%d+"), "sudoku: best time saved")
check(sys.read_text("data/sudoku/current.txt") == nil, "sudoku: a solved game is not kept")
key("enter")
check(shows("New Easy") and not shows("Continue") and shows("Best "), "sudoku: back on the menu with a best time")
key("down"); key("down"); key("enter")
local gh = board()
local hg = 0
for i = 0, 80 do if gh[i] ~= 0 then hg = hg + 1 end end
check(hg >= 20 and hg <= 27, "sudoku: a hard puzzle has " .. hg .. " numbers")
for i = 1, 150 do key(({ "up", "1", "right", "n", "2", "down", "u", "0", "/", "9" })[i % 10 + 1]) end
alive("sudoku", "survives 150 random keys")
key("esc"); key("esc")
check(shell.app() == "home", "sudoku: Esc from the menu goes home")

-- ------------------------------------------------------------ reversi
sys.remove("data/reversi/scores.txt")
local RX, RY, RC = 6, 18, 13
local function rboard()
  local txt = screen()
  local you, cpu, legal = 0, 0, {}
  for _, d in ipairs(discs) do
    local x, y = (d[1] - 6 - RX) // RC, (d[2] - 6 - RY) // RC
    if d[1] < 115 and (d[1] - 6 - RX) % RC == 0 then
      if d[3] == 1 then legal[#legal + 1] = { x, y }
      elseif d[4] == ui.col.accent then you = you + 1
      else cpu = cpu + 1 end
    end
  end
  return you, cpu, legal, txt
end
shell.launch("reversi"); frames(3)
alive("reversi", "opens")
local you, cpu, legal = rboard()
check(you == 2 and cpu == 2 and #legal == 4, "reversi: starts with 2 + 2 discs and 4 moves")
local rx, ry = 3, 2
local function rgo(x, y)
  while rx < x do key("right"); rx = rx + 1 end
  while rx > x do key("left"); rx = rx - 1 end
  while ry < y do key("down"); ry = ry + 1 end
  while ry > y do key("up"); ry = ry - 1 end
end
rgo(0, 0); key("enter")
you, cpu = rboard()
check(you == 2 and cpu == 2, "reversi: a square that flips nothing is refused")
rgo(3, 2); key("enter")
you, cpu = rboard()
check(you == 4 and cpu == 1, "reversi: your move flips a disc")
frames(30)
you, cpu = rboard()
check(you + cpu == 6, "reversi: the computer replies")
key("u")
you, cpu = rboard()
check(you == 2 and cpu == 2, "reversi: U takes your move back")
key("tab")
check(shows("Hard"), "reversi: Tab sets the computer to Hard")
key("tab"); key("tab")
check(shows("Normal"), "reversi: and around to Normal")
check((sys.read_text("data/reversi/scores.txt") or ""):match("level=2"), "reversi: the level is remembered")
key("tab", { shift = true })
check(shows("Easy"), "reversi: Shift+Tab goes back to Easy")
-- play whole games, always taking the first legal square
local function play_out()
  for _ = 1, 400 do
    local _, _, lg, txt = rboard()
    if txt:find("You win", 1, true) or txt:find("Computer wins", 1, true) or txt:find("A draw", 1, true) then return txt end
    if txt:find("Your move", 1, true) and #lg > 0 then
      local m = lg[math.random(1, #lg)]
      rgo(m[1], m[2]); key("enter")
    else
      frames(20)
    end
  end
end
local endtxt = play_out()
check(endtxt ~= nil, "reversi: a game against Easy plays to the end")
you, cpu = rboard()
check(you + cpu <= 64 and you + cpu > 10, "reversi: final count " .. you .. " - " .. cpu)
key("enter")
rx, ry = 3, 2
you, cpu = rboard()
check(you == 2 and cpu == 2, "reversi: Enter starts a new game")
key("tab"); key("tab")
check(shows("Hard"), "reversi: Hard")
check(play_out() ~= nil, "reversi: a game against Hard plays to the end")
key("n")
rx, ry = 3, 2
rgo(3, 2); key("enter"); frames(30)
you, cpu = rboard()
shell.home(); frames(2)
shell.launch("reversi"); frames(2)
local y2, c2 = rboard()
check(y2 == you and c2 == cpu, "reversi: the game resumes after leaving")
key("esc")
check(shell.app() == "home", "reversi: Esc goes home")

-- ------------------------------------------------------------ codebreaker
sys.remove("data/codebreaker/scores.txt")
-- Plays by always guessing a code that fits every answer so far. Codes are
-- kept as plain numbers (12345): thousands of strings would make the
-- emulator's eager garbage collector crawl.
local function all_codes(len, top, repeats, keep)
  local out = {}
  local function rec(v, n, used)
    if n == len then if keep(v) then out[#out + 1] = v end; return end
    for d = 1, top do
      if repeats or not used[d] then
        used[d] = true
        rec(v * 10 + d, n + 1, used)
        used[d] = nil
      end
    end
  end
  rec(0, 0, {})
  return out
end
local ca, cb = {}, {}
local function marks_of(a, b, len)
  local e, n = 0, 0
  for d = 0, 9 do ca[d], cb[d] = 0, 0 end
  for _ = 1, len do
    local x, y = a % 10, b % 10
    a, b = a // 10, b // 10
    if x == y then e = e + 1 else ca[x] = ca[x] + 1; cb[y] = cb[y] + 1 end
  end
  for d = 1, 9 do n = n + math.min(ca[d], cb[d]) end
  return e, n
end
local function row_marks(r, len)
  screen()
  local y, x0 = 18 + (r - 1) * 10 + 4, 6 + len * 11 + 4
  local e, n = 0, 0
  for _, d in ipairs(discs) do if d[2] == y and d[1] >= x0 and d[1] < 120 then e = e + 1 end end
  for _, c in ipairs(circles) do if c[2] == y and c[1] >= x0 and c[1] < 120 then n = n + 1 end end
  return e, n
end
local function crack(len, top, repeats)
  local first = repeats and 11223 or 1234
  local said = {}  -- { guess, exact, near }
  local function fits(c)
    for _, a in ipairs(said) do
      local e, n = marks_of(c, a[1], len)
      if e ~= a[2] or n ~= a[3] then return false end
    end
    return true
  end
  local cands
  for r = 1, 10 do
    local g = r == 1 and first or cands[math.random(1, #cands)]
    for ch in tostring(g):gmatch(".") do key(ch) end
    key("enter")
    local e, n = row_marks(r, len)
    if e == len then return r end
    said[#said + 1] = { g, e, n }
    if r == 1 then cands = all_codes(len, top, repeats, fits)
    else
      local keep = {}
      for _, c in ipairs(cands) do if fits(c) then keep[#keep + 1] = c end end
      cands = keep
    end
    if #cands == 0 then return nil end
  end
end
shell.launch("codebreaker"); frames(3)
alive("codebreaker", "opens")
check(shows("Classic") and shows("Guess 1/10"), "codebreaker: Classic mode, guess 1")
key("1"); key("2"); key("enter")
check(shows("Guess 1/10"), "codebreaker: a short guess is not checked")
key("backspace"); key("backspace"); key("9")
check(not shows("9"), "codebreaker: digits above 6 are refused")
local wins_c, tries = 0, {}
for _ = 1, 5 do
  local r = crack(4, 6, false)
  tries[#tries + 1] = tostring(r)
  if r and shows("Cracked in " .. r .. "!") then wins_c = wins_c + 1 end
  key("enter")
end
check(wins_c == 5, "codebreaker: Classic codes cracked in " .. table.concat(tries, ","))
local cb = sys.read_text("data/codebreaker/scores.txt") or ""
check(cb:match("wins_1=5") and cb:match("best_1=%d"), "codebreaker: wins and best saved")
key("tab")
check(shows("Hard") and shows("Digits may repeat"), "codebreaker: Tab switches to Hard")
local r = crack(5, 8, true)
check(r ~= nil, "codebreaker: a Hard code cracked in " .. tostring(r))
key("enter")
-- losing: ten wrong guesses show the code
for _ = 1, 10 do for _ = 1, 5 do key("9") end; for _ = 1, 5 do key("backspace") end; for ch in ("11111"):gmatch(".") do key(ch) end; key("enter"); if shows("Cracked") then break end end
check(shows("The code was") or shows("Cracked"), "codebreaker: after ten guesses the code is shown")
key("n")
key("1"); key("2"); key("3"); key("4"); key("5"); key("enter")
shell.home(); frames(2)
shell.launch("codebreaker"); frames(2)
check(shows("Guess 2/10"), "codebreaker: the code and guesses survive leaving the app")
key("tab")
check(shows("Classic"), "codebreaker: Tab back to Classic")
key("esc")
check(shell.app() == "home", "codebreaker: Esc goes home")

-- ------------------------------------------------------------ hop
sys.remove("data/hop/scores.txt")
local HG, HPX = 112, 36
-- What is on screen: the player's y, and hazards ahead as { left, right, top }.
local function hop_view()
  local txt = screen()
  local y, hz = nil, {}
  local ground = {}
  for _, f in ipairs(fills) do
    if f[1] == HPX and f[3] == 8 and f[4] == 8 and f[5] == ui.col.accent then y = f[2]
    elseif f[5] == ui.col.surface2 and f[2] + f[4] == HG then hz[#hz + 1] = { f[1], f[1] + f[3], f[2] }
    elseif f[2] == HG and f[4] == 2 then ground[#ground + 1] = { f[1], f[1] + f[3] } end
  end
  table.sort(ground, function(a, b) return a[1] < b[1] end)
  for k = 2, #ground do hz[#hz + 1] = { ground[k - 1][2], ground[k][1], HG, pit = true } end
  if #ground > 0 and ground[1][1] > 0 then hz[#hz + 1] = { 0, ground[1][1], HG, pit = true } end
  if #ground > 0 and ground[#ground][2] < 240 then hz[#hz + 1] = { ground[#ground][2], 240, HG, pit = true } end
  table.sort(hz, function(a, b) return a[1] < b[1] end)
  return y, hz, txt
end
shell.launch("hop"); frames(3)
alive("hop", "opens")
check(shows("Space to jump"), "hop: waits for Space")
local y0 = hop_view()
key("space"); frames(5)
local y1 = hop_view()
check(y0 == 104 and y1 and y1 < 104, "hop: Space starts and jumps")
frames(40)
check(hop_view() == 104, "hop: lands back on the ground")
key("p"); frames(5)
check(shows("Paused"), "hop: P pauses")
key("p")
-- with no jumping the first obstacle ends the run
local over = false
for _ = 1, 600 do frames(1); if shows("Game over") then over = true; break end end
check(over, "hop: running into something ends the run")
local hs = sys.read_text("data/hop/scores.txt") or ""
check(hs:match("best=%d+"), "hop: best score saved")
key("enter")
check(shows("Space to jump"), "hop: Enter gets ready again")
-- autopilot: jump a little before each hazard, jump again if it is tall
local best_run, runs = 0, 0
for _ = 1, 3 do
  key("space")
  runs = runs + 1
  local prev_y, air, survived = 104, 0, 0
  for i = 1, 3000 do
    local y, hz, txt = hop_view()
    if txt:find("Game over", 1, true) then break end
    if i % 50 == 0 and (tonumber(txt:match("Score (%d+)")) or 0) >= 250 then break end
    survived = i
    local ahead
    for _, h in ipairs(hz) do if h[2] > HPX - 2 then ahead = h; break end end
    local on_ground = y and y == prev_y and (y == 104 or air == 0)
    if y and ahead then
      local d = ahead[1] - (HPX + 8)
      local tall = not ahead.pit and ahead[3] < HG - 17
      if on_ground and d < 16 and d > -4 then key("space"); air = 1
      elseif air == 1 and tall and y > prev_y and y + 8 > ahead[3] - 6 and d < 10 then key("space"); air = 2
      else frames(1) end
    else
      frames(1)
    end
    if y == 104 or (y and y == prev_y) then air = 0 end
    prev_y = y
  end
  local sc = tonumber(screen():match("Score (%d+)")) or 0
  if sc > best_run then best_run = sc end
  if not shows("Game over") then break end
  key("enter")
end
check(best_run >= 250, "hop: the autopilot gets past many obstacles (score " .. best_run .. ")")
key("esc")
check(shell.app() == "home", "hop: Esc goes home")

-- ------------------------------------------------------------ gems
sys.remove("data/gems/scores.txt")
local function gscore()
  screen()
  for _, t in ipairs(texts_at) do if t[2] == 32 and t[3]:match("^%d+$") then return tonumber(t[3]) end end
end
shell.launch("gems"); frames(60)
alive("gems", "opens")
check(shows("Classic") and gscore() == 0, "gems: Classic mode, score 0")
local gx, gy = 3, 3
local nolines = false
for i = 0, 6 do
  key("enter"); key("right"); frames(30)
  if shows("No line") then nolines = true; break end
  key("down")
end
check(nolines, "gems: a swap that lines nothing up is refused")
frames(60)
key("h")
local hint = screen():match("Hint: swap (%a+)")
check(hint == "right" or hint == "down", "gems: H shows a hint")
local before = gscore()
key(hint); frames(90)
check(gscore() > before, "gems: the hinted swap scores (" .. gscore() .. ")")
local moved = 0
for _ = 1, 25 do
  key("h")
  local h = screen():match("Hint: swap (%a+)")
  if not h then break end
  key(h); frames(60); moved = moved + 1
end
check(moved >= 20 or shows("No moves left"), "gems: plays on with hints (" .. moved .. " swaps)")
local sc = gscore()
shell.home(); frames(2)
shell.launch("gems"); frames(60)
check(gscore() >= sc, "gems: the game resumes after leaving")
key("n"); frames(60)
check(gscore() == 0, "gems: N starts over")
key("tab"); frames(60)
check(shows("Timed") and screen():match("\n%d+ s\n"), "gems: Tab switches to Timed")
key("h"); local h = screen():match("Hint: swap (%a+)"); if h then key(h) end
frames(3000)
check(shows("Time is up"), "gems: the clock runs out")
local gs = sys.read_text("data/gems/scores.txt") or ""
check(gs:match("best_1=%d+") and gs:match("mode=2"), "gems: best score and mode saved")
key("x"); key("x")  -- 100 s without a key: the first wakes the screen, the next unlocks
key("enter"); frames(60)
check(not shows("Time is up") and screen():match("\n8%d s\n"), "gems: Enter starts a new timed game")
key("tab"); frames(10)
key("esc")
check(shell.app() == "home", "gems: Esc goes home")

-- ------------------------------------------------------------ solitaire
sys.remove("data/solitaire/scores.txt")
local SFACE = gfx.rgb(236, 236, 228)
local function faces()
  screen()
  local up, backs = 0, 0
  for _, r in ipairs(rfills) do
    if r[3] == 30 and r[4] == 22 then
      if r[5] == SFACE then up = up + 1 elseif r[5] == ui.col.accent then backs = backs + 1 end
    end
  end
  return up, backs
end
shell.launch("solitaire"); frames(3)
alive("solitaire", "opens")
local up, backs = faces()
check(up == 7 and backs == 22, "solitaire: deals 7 face-up cards, 21 face-down and the deck (" .. up .. ", " .. backs .. ")")
key("space")
up = faces()
check(up == 8 and shows("1\n"), "solitaire: Space turns a card onto the waste")
key("u")
check(faces() == 7, "solitaire: U undoes it")
for _ = 1, 30 do key("space") end
check(faces() == 7 or faces() == 8, "solitaire: turning the whole deck goes round again")
-- crafted positions, through the app's own save format: card char = 65 + card
local S = shell.load_app("solitaire")
local function ch(c) return string.char(65 + c) end
local function pos_(stock, waste, found, cols)
  local p = { stock, waste, found }
  for i = 1, 7 do p[#p + 1] = cols[i] or "0:" end
  return { g = table.concat(p, "|"), m = 1, t = 0 }
end
local function sk(name, text) S.key({ key = name, text = text }) end
local KS, QH, AS, JS = 12, 24, 0, 10
S.init(nil, pos_("", "", "0,0,0,0", { "0:" .. ch(KS), "0:" .. ch(QH) }))
sk("down"); sk("right"); sk("enter"); sk("left"); sk("enter")
check(S.save().g:match("|0:" .. ch(KS) .. ch(QH) .. "|0:|"), "solitaire: a red Queen goes on a black King")
sk("enter"); sk("right"); sk("enter")
check(capture(S.draw):find("Can't go there", 1, true) == nil and S.save().g:match("|0:" .. ch(KS) .. ch(QH) .. "|"), "solitaire: Enter on an empty column refuses a Queen")
sk("esc")
sk("left"); sk("up"); sk("enter"); sk("right"); sk("enter")
check(S.save().g:match("|0:|0:" .. ch(KS) .. ch(QH) .. "|"), "solitaire: King and Queen move together to an empty column")
S.init(nil, pos_("", "", "0,0,0,0", { "0:" .. ch(JS), "0:" .. ch(AS) }))
sk("down"); sk("right"); sk("f", "f")
check(S.save().g:match("|1,0,0,0|"), "solitaire: F sends an Ace to its suit pile")
sk("left"); sk("f", "f")
check(S.save().g:match("|1,0,0,0|"), "solitaire: F refuses a Jack on an empty suit pile")
S.init(nil, pos_("", ch(13 * 1 + 12), "12,12,12,12", { "0:" .. ch(12), "0:" .. ch(38), "0:" .. ch(51) }))
sk("a", "a")
check(S.save() == nil and capture(S.draw):find("You won!", 1, true), "solitaire: A finishes a won game")
local sc3 = sys.read_text("data/solitaire/scores.txt") or ""
check(sc3:match("wins_1=1") and sc3:match("best_1=%d"), "solitaire: wins and best time saved")
S.close()
key("tab")
frames(3)
if shows("Start a new deal?") then key("enter") end
check((sys.read_text("data/solitaire/scores.txt") or ""):match("draw=3"), "solitaire: Tab switches to draw 3")
key("space")
local u3 = faces()
check(u3 == 8, "solitaire: draw 3 shows the top waste card")
for i = 1, 300 do key(({ "up", "left", "enter", "down", "right", "enter", "f", "space", "u", "a" })[i % 10 + 1]) end
alive("solitaire", "survives 300 random keys")
shell.home(); frames(2)
shell.launch("solitaire"); frames(2)
alive("solitaire", "resumes")
key("esc"); key("esc")
check(shell.app() == "home", "solitaire: Esc goes home")

-- ------------------------------------------------------------ hanoi
sys.remove("data/hanoi/scores.txt")
local function hanoi_moves(k, a, b, c, out)
  if k == 0 then return out end
  hanoi_moves(k - 1, a, c, b, out)
  out[#out + 1] = a .. b
  hanoi_moves(k - 1, c, b, a, out)
  return out
end
shell.launch("hanoi"); frames(3)
alive("hanoi", "opens")
check(shows("Fewest 15") and shows("Moves 0"), "hanoi: 4 discs to start, 15 moves at best")
key("1"); key("2")
check(shows("Moves 1"), "hanoi: 1 then 2 moves a disc")
key("1"); key("2")
check(shows("Moves 1"), "hanoi: a bigger disc can't go on a smaller one")
key("u")
check(shows("Moves 2"), "hanoi: U undoes (and counts as a move)")
key("r")
check(shows("Moves 0"), "hanoi: R restarts")
for _, m in ipairs(hanoi_moves(4, 1, 3, 2, {})) do key(m:sub(1, 1)); key(m:sub(2, 2)) end
check(shows("The fewest possible!"), "hanoi: the 15-move solution wins with the fewest moves")
check((sys.read_text("data/hanoi/scores.txt") or ""):match("best_4=15"), "hanoi: best saved for 4 discs")
key("enter")
check(shows("Moves 0"), "hanoi: Enter plays again")
key("tab")
check(shows("Fewest 31"), "hanoi: Tab sets 5 discs")
-- follow the hints, starting from a muddled position
key("1"); key("2"); key("1"); key("3")
local hinted = 0
for _ = 1, 60 do
  key("h")
  screen()
  local mv
  for _, l in ipairs(lines) do if l[2] == 26 then mv = l end end
  if not mv then break end
  local from, to = (mv[1] + 40) // 80, (mv[3] + 40) // 80
  key(tostring(from)); key(tostring(to))
  hinted = hinted + 1
  if shows("Moves") and not shows("Fewest 31\n") then end
  if shows("Again") then break end
end
check(shows("Again") and hinted > 20, "hanoi: following the hints solves 5 discs (" .. hinted .. " hints)")
key("enter")
key(","); key("/"); key("enter"); key("/"); key("enter")
check(shows("Moves 1"), "hanoi: arrows and Enter lift and drop")
shell.home(); frames(2)
shell.launch("hanoi"); frames(2)
check(shows("Moves 1") and shows("Fewest 31"), "hanoi: resumes after leaving")
key("tab", { shift = true })
check(shows("Fewest 15"), "hanoi: Shift+Tab goes back to 4 discs")
key("esc")
check(shell.app() == "home", "hanoi: Esc goes home")

-- ------------------------------------------------------------ wordy
sys.remove("data/wordy/scores.txt")
local function wlist(name) return dofile("userland/lib/words5/" .. name .. ".lua") end
local ANSWERS = {}
do
  local a = wlist("answers")
  for i = 1, #a // 5 do ANSWERS[i] = a:sub(i * 5 - 4, i * 5) end
  local ok_all, lists = true, {}
  for _, w in ipairs(ANSWERS) do
    local c = w:sub(1, 1)
    lists[c] = lists[c] or wlist(c)
    local found_w, at = false, 1
    while true do
      local p = lists[c]:find(w, at, true)
      if not p then break end
      if (p - 1) % 5 == 0 then found_w = true; break end
      at = p + 1
    end
    if not found_w then ok_all = false end
  end
  check(#ANSWERS > 800 and ok_all, "wordy: " .. #ANSWERS .. " answers, all in the guess lists")
  local total = 0
  for c in ("abcdefghijklmnopqrstuvwxyz"):gmatch(".") do total = total + #wlist(c) // 5 end
  check(total > 5000, "wordy: " .. total .. " words accepted as guesses")
end
local function wmarks(g, ans)
  local m, left = {}, {}
  for i = 1, 5 do
    local a, b = ans:sub(i, i), g:sub(i, i)
    if a == b then m[i] = 2 else m[i] = 0; left[a] = (left[a] or 0) + 1 end
  end
  for i = 1, 5 do
    local b = g:sub(i, i)
    if m[i] == 0 and (left[b] or 0) > 0 then m[i] = 1; left[b] = left[b] - 1 end
  end
  return table.concat(m)
end
local function row_feedback(r)
  screen()
  local y = 17 + (r - 1) * 17 + 15
  local m = { 0, 0, 0, 0, 0 }
  for _, f in ipairs(fills) do
    if f[2] == y and f[4] == 2 then
      if f[5] == ui.col.good then m[(f[1] + 1 - 8) // 16 + 1] = 2
      elseif f[5] == ui.col.warn then m[(f[1] - 3 - 8) // 16 + 1] = 1 end
    end
  end
  return table.concat(m)
end
local function wtype(w) for ch in w:gmatch(".") do key(ch) end end
local function wsolve()
  local cands = {}
  for i, w in ipairs(ANSWERS) do cands[i] = w end
  for r = 1, 6 do
    local g = r == 1 and "crane" or cands[math.random(1, #cands)]
    wtype(g); key("enter")
    local fb = row_feedback(r)
    if fb == "22222" then return r end
    local keep = {}
    for _, w in ipairs(cands) do if wmarks(g, w) == fb then keep[#keep + 1] = w end end
    cands = keep
    if #cands == 0 then return nil end
  end
end
shell.launch("wordy"); frames(3)
alive("wordy", "opens")
check(shows("Try 1/6"), "wordy: six tries")
wtype("abc"); key("enter")
check(shows("Type 5 letters"), "wordy: a short word is not tried")
wtype("zz"); key("enter")
check(shows("Not in the word list") and shows("Try 1/6"), "wordy: an unknown word does not use a try")
for _ = 1, 5 do key("backspace") end
local won_games, tries_w = 0, {}
for _ = 1, 4 do
  local r = wsolve()
  tries_w[#tries_w + 1] = tostring(r)
  if r and shows("Won ") then won_games = won_games + 1 end
  key("enter")
end
check(won_games >= 3, "wordy: words found in " .. table.concat(tries_w, ","))
local ws = sys.read_text("data/wordy/scores.txt") or ""
check(ws:match("played=4") and ws:match("wins=%d"), "wordy: games and wins saved")
wtype("crane"); key("enter")
key("n", { ctrl = true })
check(shows("The word was"), "wordy: Ctrl+N gives up and shows the word")
key("enter")
wtype("house"); key("enter"); wtype("pl")
shell.home(); frames(2)
shell.launch("wordy"); frames(2)
check(shows("H") and shows("Try 2/6"), "wordy: the game resumes after leaving")
key("m", { ctrl = true })
check(cfg.get("game_sound") == "1", "wordy: Ctrl+M turns sound on")
key("m", { ctrl = true })
key("esc")
check(shell.app() == "home", "wordy: Esc goes home")

-- ------------------------------------------------------------ never an error screen
for _, name in ipairs({ "sudoku", "reversi", "codebreaker", "hop", "gems", "solitaire", "hanoi", "wordy" }) do
  shell.launch(name); frames(5)
  for _, k in ipairs({ "down", "up", "enter", "left", "right", "space", "p", "p", "a", "s", "d", "x", "tab", "u", "r" }) do key(k) end
  frames(30)
  check(shell.app() == name, name .. ": stays open under random keys")
  shell.home(); frames(2)
end
check(quiet == 0, "no game made a sound with game sound off")

say(string.format("%d ok, %d failure(s)", oks, fails))
os.exit(fails == 0 and 0 or 1)
