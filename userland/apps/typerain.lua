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
  [3] = "add age air ant ape arm art ash bag bat bay bed bee bin bow box boy bud bug bun bus cab can cap car cat cod cot cow cub cup dam day den dew dig dog dot dry dye ear eel egg elf elk end eye fan fig fin fly fog fox fun fur gap gas gem gum gym hat hay hen hip hog hop hug hum hut ice ink ion ivy jam jar jaw jet jog joy key kid kit lab lap law leg lid lip log lot low map mat mix mop mud mug nap net nod nut oak oar oat odd oil one orb ore owl pad pan paw pea pen pet pie pig pin pit pod pop pot pub pun rag ram rat ray red rib rim rip rod row rub rug run sap saw sea set sew shy sip six ski sky sly sob sod son sow soy spa spy sum sun tab tag tan tap tar tea tin tip toe ton top tow toy tub tug two urn van vet vow wax way web wet wig win wok yak yam yes zip zoo ",
  [4] = "acid aunt baby back bake ball band bank bark barn base bath beam bean bear beef bell bike bill bird blue boat bone book boot bowl bulb bush cafe cage cake calf calm camp cape card cart cash cave chef chin chip city clam clay clip club coal coat coin comb cone cook cord corn crab crow cube curl dart dawn deer desk dice dime dish dive dock doll dome door dove draw drip drum duck duke dune dust echo edge exit face farm fawn feet fern film fire fish fist flag flea foam foot fork fort frog fuel game gate gear germ gift glow glue goat gold golf gown grin gull hand hare harp hawk heel herb hike hill hive hole home hood hook hope horn hose hunt idea inch iron jade jazz jeep joke jump kelp kick kite kiwi knee knot lace lady lake lamb lamp lane lava lawn leaf leek lens lily lime link lion list loaf lock loop mail mall mask maze meal melt mice milk mill mint mole moon moss mule nail neck nest news nose note oath oval oven pack page pail pain palm pals park path peak pear pier pine pole pond pony pool puma pump quiz raft rain rake ramp reef ring road robe rock roof root rope rose ruby rule sail salt sand seal seed ship shoe silk sink slug snow soap sock soup spin star step stew swan tail tank taxi team tent tide tile toad tofu tool town toys tram trap tree tuba tuna vase vest vine wall wand warm wasp wave well whip wind wing wish wolf wood worm yard yarn yoga zone ",
  [5] = "acorn adult alarm alien amber angel ankle apple apron arrow attic award bacon badge bagel baker beach bench berry bingo blade blank blaze bloom board bonus brave bread brick bride broom brush buggy cabin cable camel candy canoe cargo cedar chain chair chalk charm cheek chess chest chick child chili choir cider clock cloud clown cobra cocoa comet coral couch crane crate crown crumb crust daisy dance delta diary diner disco dough dozen dream drink drive eagle earth easel elbow ember fable fairy feast fence ferry field flame flock flour flute frost fudge ghost giant glass globe glove grain grape graph grass gravy grill guard guest habit hatch heart hedge hippo honey hotel house igloo image ivory jeans jelly jewel joker juice kayak knife koala label ladle laser latch lemon lever light llama lunch magic mango maple medal melon metal minty motel mouse movie music nacho noble north novel nurse oasis ocean olive onion orbit otter paint panda paper patio peach pearl pedal penny phone photo piano pilot pinch pizza plant plaza plume poppy pouch prize puppy quail queen quest quiet quilt radio raven relay rider ridge river roast robin robot rodeo royal ruler saint salad sauce scarf scoop scout seven shark sheep shelf shell shirt shrub skate skunk slope smile snack sneak solar sound spice spike spoon spray squid stamp steam stone stork storm straw sugar sweet syrup table teeth thorn thumb tiger toast token topaz torch tower track trail train trout truck tulip tunic tutor umbra uncle unity usher valve vapor video villa vinyl viola vowel wagon waist watch water whale wheat wheel witch woman world yacht yeast youth zebra ",
  [6] = "acorns admire advice almond anchor animal anthem archer artist author autumn badger ballet bamboo banana banner barrel basket beaver beetle bishop blouse bonnet border bottle bounce branch breeze bridge bright bubble bucket buckle butter button cactus camera candle canyon carpet carrot castle cattle cellar cement cereal chapel cheese cherry cinema circle cobweb coffee collar comedy cookie copper cousin coyote crayon credit cruise cymbal dancer desert detail dinner doctor domino donkey doodle dragon effort emblem empire engine escape fabric falcon family farmer fiddle finger flight flower forest frozen gadget galaxy garden ginger goblet gopher gravel grocer guitar hamlet hammer harbor helmet hiking hockey hoodie hunter insect island jacket jigsaw jogger juggle jungle kettle kitten knight ladder laptop lemony letter lizard lounge magnet mallet marble meadow meteor mirror mitten monkey muffin museum napkin nectar needle noodle number orange oyster paddle palace parade parrot pastry pebble pencil pepper pickle pigeon pillow planet plenty pocket poetry potato powder prince puppet puzzle quiver rabbit radish raisin ribbon riddle rocket saddle salmon school silver sketch sleeve slogan smooth soccer spider spirit sponge spring squash statue stream studio summer sunset symbol tablet teapot temple thread ticket timber toffee tomato travel trophy tundra tunnel turkey turtle valley velvet violin voyage waffle walnut walrus wander window winter wizard yogurt zipper ",
  [7] = "acrobat address airport ancient antenna apricot article balcony balloon bandage banquet battery biscuit blanket blossom bracket buffalo cabbage cabinet capital caramel cartoon catfish ceiling century chamber cheetah chicken chimney circuit clarity climber cobbler coconut collect comfort compass concert cottage courage cracker crystal cupcake curtain cushion dancing default dessert diamond dolphin doorway drawing eclipse emerald explore factory fantasy fashion feather fiction firefly fishing flowers fortune fossils freedom freight gallery garnish gateway genuine giraffe glacier gondola grammar granite gravity habitat hamster harmony harvest helping highway history holiday horizon iceberg imagine jackpot jasmine journey justice ketchup kingdom kitchen lantern lecture leisure leopard lettuce library lobster luggage machine mailbox mammoth mansion marshal meadows mermaid message migrate minimum mission mixture monster morning mustard mystery network notepad nursery oatmeal octopus officer orchard orchids outline pajamas pancake panther paradox partner pasture patient pattern payment peacock pelican penguin pianist picture pilgrim plaster popcorn portion poultry printer problem pudding pumpkin pyramid quarter rainbow reading recital reptile rooster sailing sandals sapling sardine scholar science scissor seagull seaside secrets serpent shelter shimmer sixteen skyline snowman soldier sparrow spinach sponsor stadium station stomach student subject sunrise surface surgeon sweater tadpole tangent teacher texture thistle thunder tornado tourism tractor treetop trellis triumph trumpet unicorn uniform utensil vampire vanilla verdict village vintage vitamin volcano walnuts warrior weather wetland whisper whistle wildcat wrestle yelling ",
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
