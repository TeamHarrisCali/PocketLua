-- Type Rain: words fall from the sky; type each one before it lands. Three
-- landings and the game is over. It speeds up as you go; best score and WPM.
local col = ui.col
local app = { title = "Type Rain", icon = "cloud", color = "blue", order = 66, category = "games" }
app.help = {
  { "a-z", "Type a falling word" },
  { "Bksp", "Erase a letter" },
  { "Space", "Clear what you typed" },
  { "Enter", "Start / play again" },
  { "Ctrl+P", "Pause" },
  { "Ctrl+M", "Sound on/off" },
  { "Esc", "Home" },
}

local gk = require("gamekit")

-- Word lists by length, packed with one space after each word so the n-th
-- word of length L starts at (n - 1) * (L + 1) + 1. No table per word.
local WORDS = {
  [3] = "ant arm bag bat bed bee box bus cap car cat cow cup dog ear egg elf fan fig fox fun gem hat hen ice ink jam jar jet key kit leg map mix mud net nut owl pan pen pig pin pot rat red rug sea sky sun tea toy van web wig yak zip ",
  [4] = "acid band bark bean bell bird boat bone book cake calm card cave city clay coal coat corn crab desk door drum duck dust fern fire fish flag foam frog gate gift goat gold harp hill horn iron jazz kite lake lamp leaf lime lion mint moon moss nest note oven palm park pear pine rain road rock rope salt sand ship snow soap sock star tent tide tree wave wind wolf yarn ",
  [5] = "apple beach berry brick brush cabin candy chair chalk cloud coral crane delta dream eagle earth fable field flame flute frost ghost globe grape grass heart honey house jelly juice koala lemon light llama mango maple music ocean olive otter panda paper peach piano pizza plant quilt radio river robot salad shell skate smile spoon steam stone storm sugar table tiger toast torch tulip water whale world zebra ",
  [6] = "anchor banana basket bottle bridge butter camera candle carrot castle cheese cherry cookie copper donkey dragon falcon forest garden ginger guitar hammer island jacket jungle kettle ladder lizard magnet marble meadow mirror monkey orange parrot pencil pepper pickle planet pocket puzzle rabbit rocket saddle silver spider spring squash sunset tomato tunnel turtle violin walnut window winter ",
  [7] = "address balloon blanket cabbage capital chicken compass dolphin diamond feather freedom giraffe harvest hamster jasmine kingdom lantern leopard library machine mammoth mermaid morning octopus panther pelican penguin pyramid rainbow sandals seagull shelter snowman sparrow station sunrise teacher thunder tractor trumpet unicorn volcano weather whisper ",
}
local MAXLEN = 7
local SKY, GROUND = 28, 108   -- words fall from y 28; landing at y 108

local words          -- { { w = "text", x =, y = }, ... }
local buf            -- letters typed so far (always a prefix of some word)
local target         -- the word buf belongs to (the lowest match)
local score, lives, done, chars, level, playtime, spawn
local best, best_wpm, scores
local state          -- "ready", "play", "pause", "over"
local s_score, s_level, s_best, s_wpm, s_buf  -- cached strings for draw()

local function wpm()
  if playtime < 1 then return 0 end
  return math.floor(chars / 5 / (playtime / 60) + 0.5)
end

local function texts()
  s_score, s_level = "Score " .. score, "Level " .. level
  s_best = "Best " .. best .. "  (" .. best_wpm .. " wpm)"
  s_wpm = wpm() .. " wpm"
  s_buf = "> " .. buf
end

-- A random word: short ones first, longer ones as the level rises.
local function pick()
  local hi = math.min(MAXLEN, 3 + (level + 1) // 2)
  local lo = math.max(3, hi - 2)
  local len = math.random(lo, hi)
  local list = WORDS[len]
  local n = #list // (len + 1)
  local i = math.random(1, n)
  return list:sub((i - 1) * (len + 1) + 1, (i - 1) * (len + 1) + len)
end

local function speed() return 5 + level * 1.6 end        -- pixels per second
local function gap() return math.max(0.8, 2.8 - level * 0.18) end  -- seconds between words

local function new_game()
  words, buf, target = {}, "", nil
  score, lives, done, chars, level, playtime, spawn = 0, 3, 0, 0, 1, 0, 0
  state = "ready"
  texts()
end

local function add_word()
  local w = pick()
  for _ = 1, 6 do  -- don't start on top of a word that is still near the sky
    local x = math.random(4, 236 - #w * 6)
    local clear = true
    for _, o in ipairs(words) do
      if o.y < SKY + 14 and x < o.x + #o.w * 6 + 6 and o.x < x + #w * 6 + 6 then clear = false; break end
    end
    if clear then words[#words + 1] = { w = w, x = x, y = SKY }; return end
  end
end

-- The lowest word that starts with what has been typed.
local function find(prefix)
  local found
  for _, o in ipairs(words) do
    if o.w:sub(1, #prefix) == prefix and (not found or o.y > found.y) then found = o end
  end
  return found
end

local function game_over()
  state = "over"
  local changed = false
  if score > best then best, changed = score, true end
  if wpm() > best_wpm and score > 0 then best_wpm, changed = wpm(), true end
  if changed then
    scores.best, scores.wpm = best, best_wpm
    gk.save("typerain", scores)
  end
  gk.beep(180, 300)
  texts()
end

local function type_letter(c)
  local o = find(buf .. c)
  if not o then gk.beep(220, 20); return end  -- a wrong letter never goes in
  buf, target = buf .. c, o
  if buf == o.w then
    for i, w in ipairs(words) do if w == o then table.remove(words, i); break end end
    score = score + #o.w * level
    chars, done = chars + #o.w + 1, done + 1
    level = 1 + done // 8
    buf, target = "", nil
    gk.beep(988, 25)
  end
  texts()
end

function app.init()
  math.randomseed(sys.millis())
  scores = gk.load("typerain")
  best, best_wpm = tonumber(scores.best) or 0, tonumber(scores.wpm) or 0
  new_game()
end

function app.update(dt)
  if state ~= "play" then return end
  playtime = playtime + dt
  spawn = spawn - dt
  if spawn <= 0 or #words == 0 then
    add_word()
    spawn = gap()
  end
  local v = speed() * dt
  local i = 1
  while i <= #words do
    local o = words[i]
    o.y = o.y + v
    if o.y >= GROUND then
      table.remove(words, i)
      lives = lives - 1
      gk.beep(300, 80)
      if o == target then buf, target = "", nil end
      if lives <= 0 then game_over(); return end
    else
      i = i + 1
    end
  end
  if target then target = find(buf) end
  if math.floor(playtime) ~= math.floor(playtime - dt) then s_wpm = wpm() .. " wpm" end
end

function app.draw()
  ui.text(4, 17, s_score, col.text)
  ui.center(17, s_level, col.muted)
  for i = 1, 3 do gfx.disc(212 + i * 7, 20, 2, i <= lives and col.bad or col.surface2) end
  gfx.fill(4, GROUND + 1, 232, 1, col.line)
  if state == "play" or state == "pause" then
    for _, o in ipairs(words) do
      local y = math.floor(o.y)
      gfx.text(o.x, y, o.w, o.y > GROUND - 24 and col.warn or col.text)
      if o == target then
        gfx.fill(o.x, y + 9, #buf * 6, 1, col.accent)
        gfx.text(o.x, y, buf, col.accent)
      end
    end
    ui.text(4, 112, s_buf, col.accent)
    ui.right(236, 112, s_wpm, col.muted)
  end
  if state == "ready" then
    ui.center(46, "Type the words", col.text, 2)
    ui.center(66, "before they land.", col.muted)
    ui.center(84, s_best, col.muted)
    ui.footer({ { "Enter", "Start" }, { "Esc", "Home" } })
  elseif state == "pause" then
    ui.box(60, 50, 120, 36)
    ui.center(60, "Paused", col.text, 2)
    ui.footer({ { "Ctrl+P", "Resume" }, { "Esc", "Home" } })
  elseif state == "over" then
    ui.box(40, 34, 160, 74)
    ui.center(40, "Game over", col.muted)
    ui.big(52, tostring(score), col.accent, 3)
    ui.center(80, s_wpm, col.text)
    ui.center(94, s_best, col.muted)
    ui.footer({ { "Enter", "Again" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Space", "Clear" }, { "Ctrl+P", "Pause" }, { "Esc", "Home" } })
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  local c = k.text and k.text:lower()
  if k.ctrl and c == "m" then gk.toggle_sound(); return true end
  if k.ctrl and c == "p" then
    if state == "play" then state = "pause" elseif state == "pause" then state = "play" end
    return true
  end
  if k.ctrl or k.fn then return false end
  if state == "ready" or state == "over" then
    if k.key == "enter" then
      new_game()
      state = "play"
      return true
    end
    return false
  end
  if state ~= "play" then return false end
  if k.key == "backspace" then
    buf = buf:sub(1, -2)
    target = buf ~= "" and find(buf) or nil
  elseif k.key == "enter" or c == " " then
    buf, target = "", nil
  elseif c and c:match("^%l$") then
    type_letter(c)
    return true
  else
    return false
  end
  texts()
  return true
end

function app.close()
  words, scores = nil, nil
end

return app
