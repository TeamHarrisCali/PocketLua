-- Adventure: a small text game. Type commands (help lists them) and press
-- Enter; Fn+; and Fn+. scroll. Progress is saved to data/adventure.sav.
local col = ui.col
local app = { title = "Adventure", icon = "book", color = "blue", order = 64, category = "games" }

local FILE = "data/adventure.sav"
local ROWS, LH, MAXLINES, MAXIN = 9, 10, 80, 36

local ROOMS = {
  beach = { "Beach", "Cold pebbles crunch underfoot. A wrecked rowing boat lies on its side. " ..
    "The lighthouse on the headland is dark tonight. A path climbs north into the dunes.", { n = "dunes" } },
  dunes = { "Dunes", "Marram grass hisses in the wind. The path runs north to a cottage and south " ..
    "to the beach. East, the ground rises toward a cliff.", { n = "cottage", s = "beach", e = "cliff" } },
  cottage = { "Keeper's cottage", "The keeper's cottage, long empty. A ladder goes up to a loft and a trapdoor " ..
    "opens on steps down. The door is south; a back door leads east.",
    { s = "dunes", u = "loft", d = "cellar", e = "garden" } },
  loft = { "Loft", "A cramped loft under the thatch. Old fishing nets hang from the beams.", { d = "cottage" } },
  cellar = { "Cellar", "A damp cellar that smells of salt and rust. Empty shelves line the walls.", { u = "cottage" } },
  garden = { "Garden", "An overgrown garden. A tumbledown shed stands to the north; the cottage is west.",
    { w = "cottage", n = "shed" } },
  shed = { "Shed", "Rakes, broken pots and cobwebs. Something rattles on a shelf.", { s = "garden" } },
  cliff = { "Cliff top", "Wind tears at your coat. The lighthouse rises to the north; its iron door is " ..
    "set in the rock. The dunes are west.", { w = "dunes", n = "hall" } },
  hall = { "Lighthouse hall", "A round stone room. Iron stairs spiral upward. The door is south.",
    { s = "cliff", u = "stairs" } },
  stairs = { "Spiral stairs", "The stairs wind up and up. The wind moans through a narrow window.",
    { d = "hall", u = "lamp" } },
  lamp = { "Lamp room", "Glass on every side and the black sea below. The great lamp sits in the middle, " ..
    "its brass fuel well empty and its wick dry.", { d = "stairs" } },
}
local ITEMS = {
  lamp = { "cottage", "a hand lamp", "A brass hand lamp with a good wick." },
  matches = { "shed", "a box of matches", "A dry box of matches. Lucky." },
  key = { "cellar", "an iron key", "A heavy iron key, stamped LIGHT." },
  oil = { "loft", "a can of oil", "Lamp oil, nearly full." },
  shell = { "beach", "a spiral shell", "A pale spiral shell. You can hear the sea in it." },
}
local ITEM_ORDER = { "lamp", "matches", "key", "oil", "shell" }
local DIRS = { n = "n", north = "n", s = "s", south = "s", e = "e", east = "e", w = "w", west = "w",
  u = "u", up = "u", d = "d", down = "d" }
local DIR_NAMES = { n = "north", s = "south", e = "east", w = "west", u = "up", d = "down" }
local DIR_ORDER = { "n", "s", "e", "w", "u", "d" }
local FLAGS = { "lit", "open", "fuel", "won" }

local room, loc, flags, moves     -- game state
local out, scroll                 -- wrapped output lines; lines scrolled up from the bottom
local input, s_input, s_scroll, blink, blink_t
local last_saved

-- ------------------------------------------------------------ state
local function new_state()
  room, loc, flags, moves = "beach", {}, {}, 0
  for name, it in pairs(ITEMS) do loc[name] = it[1] end
end

local function serialize()
  local f, i = {}, {}
  for _, k in ipairs(FLAGS) do if flags[k] then f[#f + 1] = k end end
  for _, name in ipairs(ITEM_ORDER) do i[#i + 1] = name .. ":" .. loc[name] end
  return "r=" .. room .. "\nm=" .. moves .. "\nf=" .. table.concat(f, ",") .. "\ni=" .. table.concat(i, ",") .. "\n"
end

local function deserialize(s)
  if type(s) ~= "string" then return false end
  local r = s:match("r=(%w+)")
  if not r or not ROOMS[r] then return false end
  new_state()
  room = r
  moves = tonumber(s:match("m=(%d+)")) or 0
  for k in (s:match("f=([%w,]*)") or ""):gmatch("%w+") do flags[k] = true end
  for name, where in (s:match("i=([%w:,]*)") or ""):gmatch("(%w+):(%w+)") do
    if ITEMS[name] and (ROOMS[where] or where == "inv" or where == "gone") then loc[name] = where end
  end
  return true
end

local function persist()
  local s = serialize()
  if s ~= last_saved then
    if sys.write_text(FILE, s) then last_saved = s end
  end
end

-- ------------------------------------------------------------ output
local function say(s)
  for _, l in ipairs(ui.wrap(s, 228)) do out[#out + 1] = l end
  while #out > MAXLINES do table.remove(out, 1) end
  scroll = 0
  s_scroll = nil
end

local function have(name) return loc[name] == "inv" end

local function describe()
  local r = ROOMS[room]
  say("[" .. r[1] .. "]")
  if room == "lamp" and flags.fuel then
    say("Glass on every side and the black sea below. The great lamp's fuel well is full of oil.")
  else
    say(r[2])
  end
  if room == "cliff" then say(flags.open and "The iron door stands open." or "The iron door is locked.") end
  local seen = {}
  for _, name in ipairs(ITEM_ORDER) do
    if loc[name] == room then seen[#seen + 1] = ITEMS[name][2] end
  end
  if #seen > 0 then say("You see " .. table.concat(seen, ", ") .. ".") end
  local ex = {}
  for _, d in ipairs(DIR_ORDER) do if r[3][d] then ex[#ex + 1] = DIR_NAMES[d] end end
  say("Exits: " .. table.concat(ex, ", ") .. ".")
end

-- ------------------------------------------------------------ verbs
local function go(d)
  local to = ROOMS[room][3][d]
  if not to then say("You can't go that way."); return end
  if to == "hall" and not flags.open then say("The iron door is locked."); return end
  if to == "cellar" and not (have("lamp") and flags.lit) then
    say("The steps vanish into blackness. You need a light first."); return
  end
  room = to
  moves = moves + 1
  describe()
end

local function take(name)
  if name == "" then say("Take what?"); return end
  if not ITEMS[name] then say("You see no " .. name .. " here."); return end
  if have(name) then say("You already have it."); return end
  if loc[name] ~= room then say("You see no " .. name .. " here."); return end
  loc[name] = "inv"
  moves = moves + 1
  say("Taken: " .. ITEMS[name][2] .. ".")
end

local function drop(name)
  if name == "" then say("Drop what?"); return end
  if not have(name) then say("You don't have that."); return end
  loc[name] = room
  moves = moves + 1
  say("Dropped.")
end

local function win()
  flags.won = true
  say("The wick catches. Light blooms in the great lens and sweeps out over the water. " ..
    "Far out, a fishing boat turns for home, guided by your beam.")
  say("*** You have won in " .. moves .. " moves! ***")
  say("Type restart to play again.")
end

local function use(name)
  if name == "" then say("Use what?"); return end
  if not ITEMS[name] then say("You don't have a " .. name .. "."); return end
  if not have(name) then say("You don't have the " .. name .. "."); return end
  moves = moves + 1
  if name == "matches" then
    if room == "lamp" then
      if flags.fuel then win() else say("You hold a match to the great wick. It is bone dry and won't catch.") end
    elseif have("lamp") and not flags.lit then
      flags.lit = true
      say("You strike a match and light the hand lamp. It glows warmly.")
    else
      say("You strike a match. It flares and dies.")
    end
  elseif name == "oil" then
    if room == "lamp" then
      flags.fuel = true
      loc.oil = "gone"
      say("You pour the oil into the great lamp's fuel well. The wick drinks it up.")
    else
      say("Better save it for something that needs fuel.")
    end
  elseif name == "key" then
    if room == "cliff" and not flags.open then
      flags.open = true
      say("The key turns with a groan and the iron door swings open.")
    else
      say("There is nothing to unlock here.")
    end
  elseif name == "lamp" then
    say(flags.lit and "The lamp is already lit." or "You need something to light it with.")
  else
    say(ITEMS[name][3])
  end
end

local function inventory()
  local t = {}
  for _, name in ipairs(ITEM_ORDER) do if have(name) then t[#t + 1] = ITEMS[name][2] end end
  if #t == 0 then say("You are carrying nothing.") else say("You carry " .. table.concat(t, ", ") .. ".") end
  if have("lamp") and flags.lit then say("The lamp is lit.") end
end

local function help()
  say("Commands: look, go <dir> (or n s e w u d), take <item>, drop <item>, use <item>, " ..
    "examine <item>, inventory (i), restart. Up/down arrows scroll.")
end

local function restart()
  new_state()
  say("--- A new game ---")
  say("The lighthouse has gone dark and a storm is coming in. Somebody has to light it.")
  describe()
end

local function run(line)
  say("> " .. line)
  local verb, rest = line:lower():match("^%s*(%S+)%s*(.-)%s*$")
  if not verb then return end
  rest = rest:gsub("^the%s+", "")
  if verb == "restart" then restart()
  elseif verb == "help" or verb == "?" then help()
  elseif verb == "look" or verb == "l" then describe()
  elseif verb == "inventory" or verb == "i" or verb == "inv" then inventory()
  elseif flags.won then say("The light is burning. Type restart to play again.")
  elseif DIRS[verb] then go(DIRS[verb])
  elseif verb == "go" or verb == "walk" then
    if DIRS[rest] then go(DIRS[rest]) else say("Go where? Try north, south, east, west, up or down.") end
  elseif verb == "take" or verb == "get" then take(rest)
  elseif verb == "drop" then drop(rest)
  elseif verb == "use" or verb == "light" then use(rest)
  elseif verb == "examine" or verb == "x" then
    if ITEMS[rest] and (have(rest) or loc[rest] == room) then say(ITEMS[rest][3]) else say("You see nothing special.") end
  else
    say("I don't understand \"" .. verb .. "\". Type help.")
  end
  persist()
end

local function refresh_input()
  local shown = input
  if #shown > MAXIN then shown = shown:sub(-MAXIN) end
  s_input = "> " .. shown .. (blink and "_" or "")
  s_scroll = "^" .. scroll
end

-- ------------------------------------------------------------ app
function app.init(args, saved)
  out, scroll, input, blink, blink_t = {}, 0, "", true, 0
  sys.mkdirs("data")
  local file = sys.read_text(FILE, 2048)
  last_saved = file
  if deserialize(saved and saved.s) or deserialize(file) then
    say("Welcome back.")
    describe()
  else
    restart()
  end
  persist()
  refresh_input()
end

function app.update(dt)
  blink_t = blink_t + dt
  if blink_t >= 0.5 then
    blink_t, blink = 0, not blink
    refresh_input()
  end
end

function app.draw()
  local first = #out - ROWS + 1 - scroll
  for i = 0, ROWS - 1 do
    local l = out[first + i]
    if l then ui.text(4, 17 + i * LH, l, l:byte(1) == 62 and col.accent or col.text) end
  end
  if scroll > 0 then ui.right(236, 17, s_scroll, col.muted) end
  gfx.line(0, 109, ui.W, 109, col.line)
  ui.text(4, 113, s_input, col.warn)
  ui.footer({ { "Enter", "Do it" }, { "Up/Dn", "Scroll" }, { "Esc", "Home" } })
end

function app.key(k)
  if k.key == "esc" then return false end
  if k.key == "enter" then
    if input:match("%S") then run(input) end
    input = ""
  elseif k.key == "backspace" then input = input:sub(1, -2)
  elseif k.key == "up" then scroll = math.min(math.max(0, #out - ROWS), scroll + 3)
  elseif k.key == "down" then scroll = math.max(0, scroll - 3)
  elseif k.text and not k.ctrl and not k.fn then
    if #input < 60 then input = input .. k.text end
  else
    return false
  end
  refresh_input()
  return true
end

function app.save()
  if room then return { s = serialize() } end
end

function app.close()
  if room then persist() end
  out = nil
end

return app
