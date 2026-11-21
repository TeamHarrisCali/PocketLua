-- Headless tests for the second batch of games (mines, typerain, bricks, crates).
-- Run from the project root:  lua5.4 tools/tests/games2.lua
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
gfx.rfill = function(x, y, w, h, ...)
  if recording then rfills[#rfills + 1] = { x, y, w, h } end
  return real_rfill(x, y, w, h, ...)
end
gfx.text = function(x, y, s, ...)
  if recording then drawn[#drawn + 1] = s end
  return real_text(x, y, s, ...)
end
gfx.disc = function(x, y, r, c, ...)
  if recording then discs[#discs + 1] = { x, y, r, c } end
  return real_disc(x, y, r, c, ...)
end
local function screen()
  drawn, discs, rfills, recording = {}, {}, {}, true
  on_draw()
  recording = false
  return table.concat(drawn, "\n")
end
local function shows(s) return screen():find(s, 1, true) ~= nil end
local function alive(name, what) check(shell.app() == name, name .. ": " .. what) end

-- A random sequence the tests can replay, so a mine field can be laid twice.
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

-- ------------------------------------------------------------ mines
sys.remove("data/mines/scores.txt")
shell.launch("mines"); frames(3)
alive("mines", "opens")
check(shows("Small") and shows("Large") and shows("10 left"), "mines: tabs and mine count")
-- board 9x8 at x 70, y 33, cells 11 px; the cursor starts at (4, 4)
local X0, Y0, CELL = 70, 33, 11
local cur_x, cur_y = 4, 4
local function go(x, y)
  while cur_x < x do key("right"); cur_x = cur_x + 1 end
  while cur_x > x do key("left"); cur_x = cur_x - 1 end
  while cur_y < y do key("down"); cur_y = cur_y + 1 end
  while cur_y > y do key("up"); cur_y = cur_y - 1 end
end
replay(4242)
key("enter")
check(not shows("Boom"), "mines: the first dig is always safe")
-- keep digging until a mine goes off, then read where the mines were
local lost = false
for y = 0, 7 do
  for x = 0, 8 do
    if not lost then
      go(x, y); key("enter")
      lost = shows("Boom!")
    end
  end
end
check(lost, "mines: digging a mine loses")
local mines = {}
local n = 0
for _, d in ipairs(discs) do
  local mx, my = (d[1] - 5 - X0) // CELL, (d[2] - 5 - Y0) // CELL
  local inside = mx >= 0 and mx < 9 and my >= 0 and my < 8 and (d[1] - 5 - X0) % CELL == 0
  if inside and not mines[my * 9 + mx] then mines[my * 9 + mx] = true; n = n + 1 end
end
check(n == 10, "mines: all 10 mines are shown after losing (" .. n .. ")")
-- same seed and first dig: the same field, so dig every safe square and win
key("n")
cur_x, cur_y = 4, 4
replay(4242)
key("enter")
local mx, my
for c in pairs(mines) do mx, my = c % 9, c // 9; break end
go(mx, my); key("f")
check(shows("9 left"), "mines: F plants a flag")
key("f")
check(shows("10 left"), "mines: F again removes it")
for y = 0, 7 do
  for x = 0, 8 do
    if not mines[y * 9 + x] then go(x, y); key("enter") end
  end
end
unreplay()
check(shows("Cleared in"), "mines: opening every safe square wins")
local saved = sys.read_text("data/mines/scores.txt")
check(saved and saved:match("small=%d+"), "mines: best time saved in data/mines/scores.txt")
key("enter")
check(shows("10 left"), "mines: Enter starts again")
key("tab")
check(shows("22 left"), "mines: Tab picks the medium board")
key("tab", { shift = true })
check(shows("10 left"), "mines: Shift+Tab goes back")
key("tab"); key("tab")
for i = 1, 200 do
  key(({ "up", "right", "enter", "f", "down", "left", "enter", "." })[i % 8 + 1])
  if shows("Boom") or shows("Cleared") then key("enter") end
end
alive("mines", "survives 200 random keys on the large board")
check(quiet == 0, "mines: silent unless sound is turned on")
key("m")
check(cfg.get("game_sound") == "1", "mines: M turns game sound on")
key("m")
check(cfg.get("game_sound") == "0", "mines: M turns it off again")
key("esc")
check(shell.app() == "home", "mines: Esc goes home")

-- ------------------------------------------------------------ typerain
do
  local tsrc = assert(io.open("userland/apps/typerain.lua")):read("a")
  local okl = true
  for len, list in tsrc:gmatch('%[(%d)%] = "([^"]*)"') do
    len = tonumber(len)
    for w in list:gmatch("%S+") do if #w ~= len or not w:match("^%l+$") then okl = false end end
    if #list % (len + 1) ~= 0 then okl = false end
  end
  check(okl, "typerain: word lists are packed at a fixed width")
end
sys.remove("data/typerain/scores.txt")
shell.launch("typerain"); frames(3)
alive("typerain", "opens")
check(shows("Type the words"), "typerain: waits on a start screen")
key("enter")
frames(10)
local function falling()
  screen()
  local out = {}
  for _, s in ipairs(drawn) do if s:match("^%l%l%l+$") then out[#out + 1] = s end end
  return out
end
check(#falling() >= 1, "typerain: a word falls after Enter")
local typed = 0
for _ = 1, 25 do
  local w = falling()[1]
  if w then
    for c in w:gmatch(".") do key(c) end
    typed = typed + 1
  end
  frames(30)
end
check(typed >= 20 and shows("Score ") and not shows("Score 0"), "typerain: typing words scores (" .. typed .. " words)")
local lives = 0
screen()
for _, d in ipairs(discs) do if d[2] == 20 and d[4] == ui.col.bad then lives = lives + 1 end end
check(lives == 3, "typerain: no word landed while typing them all")
key("space"); key("q"); key("q"); key("x")
check(not shows("> qqx") and not shows("> qq"), "typerain: wrong letters are not typed in")
key("p", { ctrl = true }); frames(30)
check(shows("Paused"), "typerain: Ctrl+P pauses")
key("p", { ctrl = true })
local over = false
for _ = 1, 3000 do frames(1); if shows("Game over") then over = true; break end end
check(over, "typerain: three landed words end the game")
local ts = sys.read_text("data/typerain/scores.txt")
check(ts and tonumber(ts:match("best=(%d+)") or "0") > 0 and ts:match("wpm=%d+"), "typerain: best score and wpm saved")
key("enter"); frames(5)
check(not shows("Game over") and #falling() >= 1, "typerain: Enter plays again")
for i = 1, 200 do key(string.char(96 + i % 26 + 1)); if i % 17 == 0 then key("backspace") end end
alive("typerain", "survives 200 typed letters")
key("m", { ctrl = true })
check(cfg.get("game_sound") == "1", "typerain: Ctrl+M turns sound on")
key("m", { ctrl = true })
key("esc")
check(shell.app() == "home", "typerain: Esc goes home")

-- ------------------------------------------------------------ bricks
sys.remove("data/bricks/scores.txt")
shell.launch("bricks"); frames(3)
alive("bricks", "opens")
check(shows("Wall 1") and shows("Launch"), "bricks: starts with the ball on the paddle")
local function paddle_ball()
  local txt = screen()
  local p, b
  for _, r in ipairs(rfills) do if r[2] == 114 and r[3] == 32 then p = r[1] + 16 end end
  for _, d in ipairs(discs) do if d[2] > 24 then b = d end end
  return p, b, txt
end
local p0 = paddle_ball()
key("left"); key("left"); frames(10)
local p1 = paddle_ball()
check(p0 and p1 and p1 == p0 - 20, "bricks: two presses move the paddle 20 px")
key("d"); key("d"); frames(10)
check(paddle_ball() == p0, "bricks: D moves it back")
key("space")
frames(20)
local _, b1 = paddle_ball()
check(b1 and b1[2] < 105, "bricks: Space launches the ball")
-- autopilot: keep the paddle under the ball, aiming a little off-centre
local cleared, aim, iters = false, 0, 0
for i = 1, 40000 do
  iters = i
  local p, b, txt = paddle_ball()
  if txt:find("Wall cleared!", 1, true) then cleared = true; break end
  if txt:find("Game over", 1, true) then break end
  if txt:find("Launch", 1, true) then key("space") end
  if i % 50 == 0 then aim = math.random(-12, 12) end
  if p and b then
    local want = b[1] + aim
    if p < want - 6 then key("right") elseif p > want + 6 then key("left") else frames(1) end
  else
    frames(1)
  end
end
check(cleared, "bricks: the autopilot clears wall 1 (" .. iters .. " steps)")
check(shows("Score ") and not shows("Score 0"), "bricks: breaking bricks scores")
key("enter")
check(shows("Wall 2"), "bricks: Enter goes to wall 2")
key("space"); key("p"); frames(10)
check(shows("Paused"), "bricks: P pauses")
key("p")
local over = false
for _ = 1, 6000 do
  frames(1)
  local txt = screen()
  if txt:find("Launch", 1, true) then key("space") end
  if txt:find("Game over", 1, true) then over = true; break end
end
check(over, "bricks: missing three balls ends the game")
local bs = sys.read_text("data/bricks/scores.txt")
check(bs and tonumber(bs:match("best=(%d+)") or "0") > 0, "bricks: best score saved")
key("enter")
check(shows("Wall 1") and shows("Launch"), "bricks: Enter starts again")
key("esc")
check(shell.app() == "home", "bricks: Esc goes home")

-- ------------------------------------------------------------ crates
-- Shortest solutions found by a breadth-first solver when the levels were made.
local SOLUTIONS = {
  "rrrr", "luurdrurdldl", "urrrlldrrllldrrr", "luluddrrruulllrul",
  "rulurddrruuuullddrllddruluruurrdd", "llluululddduurrddlrrrruulllluld",
  "lluluurddlddrrulrrdrdrulururull", "dlluuuurlddddrruulrrrruurrddllll",
  "rluuulrddllddrrdrruudrrrruulldurrddll", "rrurrdrrllddruluulluurrddduurrrddrddluuu",
}
local KEYSETS = {
  { u = "up", d = "down", l = "left", r = "right" },
  { u = "w", d = "s", l = "a", r = "d" },
  { u = ";", d = ".", l = ",", r = "/" },
}
sys.remove("data/crates/scores.txt")
check(#require("crates_levels") == #SOLUTIONS, "crates: a solution for every level")
shell.launch("crates"); frames(3)
alive("crates", "opens")
check(shows("Level 1") and shows("Level 7"), "crates: lists the levels")
key("enter")
check(shows("Level 1/10") and shows("Moves 0"), "crates: Enter plays level 1")
key("left")
check(shows("Moves 0"), "crates: walking into a wall is not a move")
for n, sol in ipairs(SOLUTIONS) do
  local ks = KEYSETS[n % 3 + 1]
  for c in sol:gmatch(".") do key(ks[c]) end
  check(shows("Solved in " .. #sol .. " moves"), "crates: level " .. n .. " solved in " .. #sol .. " moves")
  if n == 2 then
    key("u")
    check(shows("Moves " .. (#sol - 1)) and not shows("Solved in"), "crates: U undoes the last push")
    key("u"); key("u")
    key("r")
    check(shows("Moves 0") and shows("Level 2/10"), "crates: R restarts the level")
    for c in sol:gmatch(".") do key(ks[c]) end
    check(shows("Solved in"), "crates: level 2 solved again")
  end
  key("enter")
end
local cs = sys.read_text("data/crates/scores.txt") or ""
check(cs:match("l1=4") and cs:match("l10=40"), "crates: fewest moves saved per level")
check(shows("Level 10") and shows("40 moves"), "crates: after the last level the list shows the scores")
key("up"); key("up"); key("enter")
check(shows("Level 8/10"), "crates: pick a level from the list")
key("down"); key("left"); key("left")
shell.home(); frames(2)
shell.launch("crates"); frames(2)
check(shows("Level 8/10") and shows("Moves 3"), "crates: resumes the level after leaving")
key("esc")
check(shows("Level 8") and not shows("Moves") and not shows("/10"), "crates: Esc goes back to the level list")
key("esc")
check(shell.app() == "home", "crates: Esc on the list goes home")

-- ------------------------------------------------------------ never an error screen
for _, name in ipairs({ "mines", "typerain", "bricks", "crates" }) do
  shell.launch(name); frames(5)
  for _, k in ipairs({ "down", "up", "enter", "left", "right", "space", "p", "p", "a", "s", "d", "x", "tab", "u", "r" }) do key(k) end
  frames(30)
  check(shell.app() == name, name .. ": stays open under random keys")
  shell.home(); frames(2)
end
check(quiet == 0, "no game made a sound with game sound off")

say(string.format("%d ok, %d failure(s)", oks, fails))
os.exit(fails == 0 and 0 or 1)
