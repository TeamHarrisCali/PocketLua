-- Headless tests for the games (snake, tetris, g2048, marble, adventure).
-- Run from the project root:  lua5.4 tools/tests/games.lua
local say = print
local src = assert(io.open("tools/host_test.lua")):read("a")
assert(load(src:match("^(.-)%-%- %-+ helpers"), "=stubs"))()
dofile("userland/boot.lua")

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
local function type_text(s) for c in s:gmatch(".") do key(c) end end

-- Record the text drawn on one screen so tests can look at it.
local drawn, drawn_at, recording = {}, {}, false
local real_text = gfx.text
gfx.text = function(x, y, s, ...)
  if recording then
    drawn[#drawn + 1] = s
    drawn_at[x .. "," .. y] = s
  end
  return real_text(x, y, s, ...)
end
local function capture(draw)
  drawn, drawn_at, recording = {}, {}, true
  draw()
  recording = false
  return table.concat(drawn, "\n")
end
local function screen() return capture(on_draw) end
local function at(x, y) screen(); return drawn_at[x .. "," .. y] end
local function shows(s) return screen():find(s, 1, true) ~= nil end

local function alive(name, what)
  check(shell.app() == name, name .. ": " .. what)
end

frames(3)

-- ------------------------------------------------------------ snake
shell.launch("snake"); frames(3)
alive("snake", "opens")
check(shows("Arrows to start"), "snake: waits for a first arrow")
key("right")
frames(5)
check(not shows("Game over"), "snake: playing after the first arrow")
key("p")
frames(20)
check(shows("Paused"), "snake: P pauses")
key("p")
key("w"); key("d"); key("s"); key("a")  -- W/A/S/D steer too (a reverse turn is ignored)
local over = false
for _ = 1, 400 do frames(1); if shows("Game over") then over = true; break end end
check(over, "snake: running into a wall ends the game")
check(cfg.get("snake_best") == nil or tonumber(cfg.get("snake_best")) >= 0, "snake: best score stored as a number")
key("enter")
check(shows("Arrows to start"), "snake: Enter restarts")
key("up"); key("left")
for _ = 1, 300 do key(({ "up", "right", "down", "left" })[math.random(1, 4)]) end
alive("snake", "survives 300 random turns")
key("esc")
check(shell.app() == "home", "snake: Esc goes home")

-- ------------------------------------------------------------ tetris
shell.launch("tetris"); frames(3)
alive("tetris", "opens")
for _, k in ipairs({ "left", "left", "x", "up", "right", "down", "down" }) do key(k) end
frames(60)
check(tonumber(at(132, 70)) ~= nil, "tetris: score is drawn on the right")
key("space")
check(tonumber(at(132, 70)) > 0, "tetris: hard drop scores points")
key("p"); frames(10)
check(shows("Paused"), "tetris: P pauses")
key("p")
over = false
for i = 1, 200 do
  key(({ "left", "right", "up", "x", "space", "space" })[i % 6 + 1])
  if shows("Game over") then over = true; break end
end
check(over, "tetris: stacking to the top ends the game")
check(tonumber(cfg.get("blocks_best") or "0") > 0, "tetris: best score saved")
key("enter")
check(not shows("Game over"), "tetris: Enter starts a new game")
frames(400)
alive("tetris", "survives 400 frames of gravity")
-- rotation against the walls (kicks) must not crash
for _ = 1, 6 do key("left") end
for _ = 1, 4 do key("up") end
for _ = 1, 8 do key("right") end
for _ = 1, 4 do key("x") end
alive("tetris", "wall kicks")
key("esc")

-- ------------------------------------------------------------ 2048 rules
local R = require("games_2048")
local function line(t) local l = { table.unpack(t) }; local p, m = R.slide(l); return table.concat(l, ","), p, m end
local s, p, m = line({ 1, 1, 1, 1 })
check(s == "2,2,0,0" and p == 8 and m, "2048: 2 2 2 2 -> 4 4")
s, p = line({ 1, 1, 2, 0 })
check(s == "2,2,0,0" and p == 4, "2048: 2 2 4 -> 4 4 (no chain merge)")
s, p, m = line({ 0, 0, 0, 1 })
check(s == "1,0,0,0" and p == 0 and m, "2048: slide without merge")
s, p, m = line({ 1, 2, 3, 4 })
check(s == "1,2,3,4" and not m, "2048: blocked line does not move")
s, p = line({ 3, 0, 3, 3 })
check(s == "4,3,0,0" and p == 16, "2048: gap then merge")
local b = { 1, 0, 0, 1,  0, 0, 0, 0,  2, 0, 0, 0,  2, 0, 0, 0 }
local moved, pts = R.move(b, "right")
check(moved and pts == 4 and b[4] == 2 and b[12] == 2 and b[16] == 2, "2048: move right merges the top row")
moved, pts = R.move(b, "down")
check(moved and pts == 8 and b[16] == 3, "2048: move down merges a column")
check(R.can_move({ 1, 2, 1, 2, 2, 1, 2, 1, 1, 2, 1, 2, 2, 1, 2, 1 }) == false, "2048: full checkerboard is stuck")
check(R.can_move({ 1, 2, 1, 2, 2, 1, 2, 1, 1, 2, 1, 2, 2, 1, 2, 2 }) == true, "2048: an equal pair can move")
local full = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0 }
check(R.add_tile(full) == 16 and (full[16] == 1 or full[16] == 2), "2048: new tile lands in the only gap")
check(R.add_tile(full) == nil, "2048: no tile on a full board")

-- ------------------------------------------------------------ 2048 app
shell.launch("g2048"); frames(3)
alive("g2048", "opens")
local dirs = { "up", "left", "down", "right", "w", "a", "s", "d" }
for i = 1, 300 do
  key(dirs[i % 8 + 1])
  if shows("No more moves") then break end
end
alive("g2048", "survives 300 moves")
check(tonumber(cfg.get("2048_best") or "0") > 0, "2048: best score saved")
shell.home(); frames(2)
shell.launch("g2048"); frames(2)
check(tonumber(at(124, 30)) > 0, "2048: the game resumes after leaving")
-- win at 2048, then continue
local g = shell.load_app("g2048")
g.init(nil, { b = "10,10,0,0,0,0,0,0,0,0,0,0,0,0,0,1", s = 100 })
g.key({ key = "left" })
check(capture(g.draw):find("2048!", 1, true) and g.save().b:match("^11,"), "2048: merging two 1024s wins")
g.key({ key = "enter" })
check(capture(g.draw):find("Keep going!", 1, true), "2048: Enter keeps playing after the win")
g.init(nil, { b = "1,2,1,2,2,1,2,1,1,2,1,2,2,1,2,1", s = 50 })
check(capture(g.draw):find("No more moves", 1, true), "2048: a stuck board is game over")
g.key({ key = "enter" })
local n0 = 0
for v in g.save().b:gmatch("%d+") do if v ~= "0" then n0 = n0 + 1 end end
check(n0 == 2, "2048: Enter on game over starts a fresh board")
g.close()
shell.home(); frames(2)

-- ------------------------------------------------------------ marble
local real_imu = imu.read
local tx, ty = 0, 0
imu.read = function() return { ax = tx, ay = ty, az = 1, gx = 0, gy = 0, gz = 0 } end
cfg.set("marble_axes", "1,1,0")   -- screen x = ax, screen y = ay for these tests
cfg.set("marble_cal", nil)
local function tilt(x, y, n) tx, ty = x, y; frames(n or 90) end
local function route(steps)
  for _, st in ipairs(steps) do
    tilt(st[1], st[2])
    if shows("Level clear") then return true end
  end
  return shows("Level clear")
end
shell.launch("marble"); frames(3)
alive("marble", "opens")
check(route({ { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, 1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }), "marble: level 1 can be solved by tilting")
check(cfg.get("marble_b1") ~= nil, "marble: level 1 best time saved")
key("enter")
check(shows("Level 2/4"), "marble: Enter goes to level 2")
check(route({ { 0, 1 }, { 1, 0 }, { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }), "marble: level 2 solved")
key("enter")
check(route({ { 1, -0.3 }, { 0, 1 }, { -1, -0.3 }, { 0, 1 }, { 1, -0.3 }, { 0, 1 }, { -1, 0 } }), "marble: level 3 solved around the holes")
key("enter")
check(shows("Level 4/4"), "marble: level 4")
tilt(1, 0, 1)
local fell = false
for _ = 1, 90 do frames(1); if shows("Fell in") then fell = true; break end end
check(fell, "marble: rolling into a hole loses the ball")
tilt(0, 0, 60)
check(not shows("Fell in") and shows("Level 4/4"), "marble: the level restarts after a fall")
key("p"); frames(5)
check(shows("Paused"), "marble: P pauses")
key("p")
key("f"); key("g"); key("r")
check(cfg.get("marble_axes") == "-1,-1,1", "marble: F/G/R flip and swap are remembered")
tx, ty = 0.1, -0.05
key("c")
check(cfg.get("marble_cal") ~= nil, "marble: C calibrates")
key("left"); key("up")
frames(100)
alive("marble", "survives nudges and recalibration")
shell.home(); frames(2)
shell.launch("marble"); frames(2)
check(shows("Level 4/4"), "marble: resumes on the same level")
cfg.set("marble_axes", nil); cfg.set("marble_cal", nil)
imu.read = real_imu
shell.home(); frames(2)

-- ------------------------------------------------------------ adventure
sys.remove("data/adventure.sav")
shell.launch("adventure"); frames(3)
alive("adventure", "opens")
check(shows("[Beach]"), "adventure: starts on the beach")
local function cmd(s) type_text(s); key("enter") end
cmd("xyzzy")
check(shows("I don't understand"), "adventure: unknown words are explained")
cmd("help")
cmd("go north")
check(shows("[Dunes]"), "adventure: go north")
cmd("n")
cmd("take lamp")
cmd("d")
check(shows("need a light"), "adventure: the cellar is too dark without a light")
cmd("e"); cmd("n"); cmd("take matches"); cmd("i")
check(shows("box of matches"), "adventure: inventory lists items")
cmd("use matches")
check(shows("glows warmly"), "adventure: matches light the lamp")
cmd("s"); cmd("w"); cmd("u"); cmd("take oil"); cmd("d"); cmd("d")
check(shows("[Cellar]"), "adventure: the lit lamp opens the cellar")
cmd("take key"); cmd("u"); cmd("s"); cmd("e")
cmd("n")
check(shows("door is locked"), "adventure: the lighthouse door is locked")
cmd("drop shell"); cmd("use key"); cmd("n")
check(shows("[Lighthouse hall]"), "adventure: the key opens the door")
local sav = sys.read_text("data/adventure.sav")
check(sav and sav:find("r=hall", 1, true) and sav:find("open", 1, true), "adventure: progress is written to data/adventure.sav")
shell.home(); frames(2)
shell.launch("adventure"); frames(2)
check(shows("Welcome back") and shows("[Lighthouse hall]"), "adventure: resumes where you left off")
cmd("u"); cmd("u")
cmd("use matches")
check(shows("bone dry"), "adventure: the great lamp needs oil first")
cmd("use oil"); cmd("use matches")
check(shows("You have won"), "adventure: lighting the lamp wins")
sav = sys.read_text("data/adventure.sav")
check(sav and sav:find("won", 1, true), "adventure: the win is saved")
for _ = 1, 10 do key("up") end
check(shows("^"), "adventure: up scrolls back")
key("down"); key("down"); key("down"); key("down")
cmd("n")
check(shows("Type restart"), "adventure: after winning, only restart moves on")
cmd("restart")
check(shows("A new game") or shows("[Beach]"), "adventure: restart")
-- resume from the file when the in-memory state is gone
shell.home(); frames(2)
local a = shell.load_app("adventure")
sys.write_text("data/adventure.sav", "r=shed\nm=3\nf=lit\ni=lamp:inv,matches:shed,key:cellar,oil:loft,shell:beach\n")
a.init(nil, nil)
check(capture(a.draw):find("[Shed]", 1, true), "adventure: loads data/adventure.sav")
a.close()
a = nil
shell.launch("adventure"); frames(2)
key("esc")
check(shell.app() == "home", "adventure: Esc goes home")

-- ------------------------------------------------------------ never an error screen
for _, name in ipairs({ "snake", "tetris", "g2048", "marble", "adventure" }) do
  shell.launch(name); frames(5)
  for _, k in ipairs({ "down", "up", "enter", "left", "right", "space", "p", "p", "a", "s", "d", "x" }) do key(k) end
  frames(30)
  check(shell.app() == name, name .. ": stays open under random keys")
  shell.home(); frames(2)
end

say(string.format("%d ok, %d failure(s)", oks, fails))
os.exit(fails == 0 and 0 or 1)
