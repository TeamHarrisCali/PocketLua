-- Headless test of the Discord app against a fake `discord` module (the real
-- one is native: src/discord.cpp). Run from the project root:
--   lua5.4 tools/tests/discord.lua
local say = print
local src = assert(io.open("tools/host_test.lua")):read("a")
assert(load(src:match("^(.-)%-%- %-+ helpers"), "=stubs"))()

-- the fake: two servers, two channels, messages that arrive later
local D = { ready = false, list = nil, msgs = {}, sent = {}, opened = {}, status = "ok", err = "", stopped = 0 }
discord = {
  ready = function() return D.ready end,
  guilds = function() D.list = { { id = "g1", name = "Home server" }, { id = "g2", name = "Work" } } end,
  channels = function(id) D.list = { { id = "c1", name = "general" }, { id = "c2", name = "music" } } end,
  list = function() return D.list end,
  open = function(id) D.opened[#D.opened + 1] = id end,
  send = function(t) D.sent[#D.sent + 1] = t end,
  messages = function(after)
    local out = {}
    for _, m in ipairs(D.msgs) do if m.seq > after then out[#out + 1] = m end end
    return out
  end,
  status = function() return D.status, D.err end,
  stop = function() D.stopped = D.stopped + 1 end,
}
__hw_discord = discord

local drawn, capturing = {}, false
local real_text = gfx.text
gfx.text = function(x, y, s, ...) if capturing then drawn[#drawn + 1] = tostring(s) end; return real_text(x, y, s, ...) end
dofile("tools/emu/boot.lua")

local fails = 0
local function check(c, m) if c then say("ok:   " .. m) else fails = fails + 1; say("FAIL: " .. m) end end
local function frames(n) for _ = 1, n or 3 do on_frame(0.1); on_draw(); on_draw(); on_draw() end end
local function key(name)
  local k = { key = name }
  if #name == 1 then k.text = name elseif name == "space" then k.key, k.text = "space", " " end
  on_key(k)
  frames(1)
end
local function screen()
  drawn, capturing = {}, true
  on_draw(); on_draw(); on_draw()
  capturing = false
  return table.concat(drawn, "|")
end
local function has(s, n) return s:find(n, 1, true) ~= nil end
frames(3)

-- no token: setup instructions
cfg.set("discord_channel", nil)
shell.launch("discord"); frames(3)
check(shell.app() == "discord" and has(screen(), "SET UP A DISCORD BOT"), "discord: explains the setup without a token")
key("esc")
check(shell.app() == "home", "discord: Esc goes home from setup")

-- with a token: server, then channel
D.ready = true
shell.launch("discord"); frames(5)
check(has(screen(), "Home server") and has(screen(), "Work"), "discord: lists the servers")
key("enter"); frames(5)
check(has(screen(), "general") and has(screen(), "music"), "discord: lists a server's channels")
key("down"); key("enter")
check(D.opened[#D.opened] == "c2" and has(screen(), "#music"), "discord: opens the chosen channel")
check(cfg.get("discord_channel") == "c2", "discord: remembers the channel")

-- messages arrive, typing and sending
D.msgs = { { seq = 1, author = "Sam", text = "hello there", mine = false } }
frames(6)
check(has(screen(), "Sam: hello there"), "discord: shows new messages")
for c in ("hi Sam"):gmatch(".") do key(c == " " and "space" or c) end
check(has(screen(), "hi Sam"), "discord: typing shows in the input line")
key("enter")
check(D.sent[#D.sent] == "hi Sam" and not has(screen(), "hi Sam_"), "discord: Enter sends and clears the line")
D.msgs[2] = { seq = 2, author = "Bot", text = "hi Sam", mine = true }
frames(6)
check(has(screen(), "> hi Sam"), "discord: the bot's own messages are marked")
key("backspace")
D.status, D.err = "error", "The bot can't send here"
frames(6)
check(has(screen(), "The bot can't send here"), "discord: shows errors")
D.status = "ok"

-- reopens on the saved channel; Esc leaves it; closing stops the module
shell.home(); frames(2)
check(D.stopped >= 1, "discord: closing the app stops the network task")
shell.launch("discord"); frames(5)
check(D.opened[#D.opened] == "c2" and has(screen(), "#music"), "discord: reopens on the saved channel")
key("esc"); frames(5)
check(D.opened[#D.opened] == "" and has(screen(), "Home server"), "discord: Esc stops reading and shows the servers")
key("esc")
check(shell.app() == "home", "discord: Esc from servers goes home")

say(fails .. " failure(s)")
os.exit(fails == 0 and 0 or 1)
