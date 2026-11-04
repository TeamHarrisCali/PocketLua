-- Discord: read and write one channel through your own Discord bot. Needs
-- Wi-Fi and a bot token in /liveos/data/discord.txt (see docs/DISCORD.md).
-- Pick a server and channel once; it reopens there. The networking runs in
-- the background natively (src/discord.cpp); this only shows it.
local col = ui.col

local app = { title = "Discord", icon = "net", color = "blue", order = 33, category = "net" }
app.help = {
  { "Type", "Write a message" },
  { "Enter", "Send / open" },
  { "Bksp", "Delete a letter" },
  { "Fn;.", "Scroll messages" },
  { ";.", "Move (lists)" },
  { "Esc", "Back / channels" },
}

local view = "setup"         -- "setup" | "guilds" | "channels" | "chat"
local list, sel, top = nil, 1, 1
local guild = nil            -- { id, name } picked
local chan_name = ""
local msgs, last_seq = {}, 0 -- { author, text, mine, lines }
local input, scroll = "", 0
local st, err = "idle", ""
local tick = 0

local function wifi_up() return wifi.status() == "connected" end

local function open_chat(id, name)
  chan_name, msgs, last_seq, scroll, view = name, {}, 0, 0, "chat"
  cfg.set("discord_channel", id)
  cfg.set("discord_channel_name", name)
  discord.open(id)
end

local function show_guilds()
  view, list, sel, top = "guilds", nil, 1, 1
  discord.guilds()
end

function app.init()
  if not discord.ready() then view = "setup"; return end
  local id = cfg.get("discord_channel")
  if id then open_chat(id, cfg.get("discord_channel_name") or "channel") else show_guilds() end
end

function app.update(dt)
  tick = tick + dt
  if tick < 0.4 or view == "setup" then return end
  tick = 0
  st, err = discord.status()
  if (view == "guilds" or view == "channels") and not list then list = discord.list() end
  if view == "chat" then
    for _, m in ipairs(discord.messages(last_seq)) do
      last_seq = m.seq
      m.lines = ui.wrap((m.mine and "> " or (m.author .. ": ")) .. m.text, 226)
      msgs[#msgs + 1] = m
      if #msgs > 30 then table.remove(msgs, 1) end
    end
  end
end

local function draw_list(title)
  ui.text(6, 18, title, col.muted)
  if not list then
    ui.text(8, 50, st == "error" and err or "Loading...", st == "error" and col.bad or col.muted)
  elseif #list == 0 then
    ui.text(8, 50, st == "error" and err or "Nothing here", col.muted)
  else
    local rows = {}
    for i, it in ipairs(list) do rows[i] = it.name end
    top = ui.list(rows, sel, top, 4, 30, 230, 15, 6)
  end
  ui.footer({ { "Enter", "Open" }, { "Esc", view == "guilds" and "Home" or "Back" } })
end

function app.draw()
  if view == "setup" then
    ui.text(6, 18, "SET UP A DISCORD BOT", col.muted)
    local lines = ui.wrap("1. discord.com/developers: New Application > Bot. Turn on Message Content Intent. "
      .. "2. Invite it to your server (Send + Read Messages). 3. Put its token in /liveos/data/discord.txt "
      .. "on the SD card, then reopen this app.", 228)
    for i, l in ipairs(lines) do ui.text(6, 30 + (i - 1) * 11, l, col.text) end
    ui.footer({ { "Esc", "Home" } })
    return
  end
  if view == "guilds" then return draw_list("SERVERS") end
  if view == "channels" then return draw_list(guild and guild.name or "CHANNELS") end
  -- chat: newest at the bottom, the line you are typing below it
  ui.text(6, 17, ui.fit("#" .. chan_name, 150), col.text)
  local s = not wifi_up() and "no Wi-Fi" or st == "error" and "error" or st == "working" and "..." or ""
  ui.right(234, 17, s, st == "error" and col.bad or col.muted)
  local y = 101
  if st == "error" and err ~= "" then
    ui.text(6, y, ui.fit(err, 228), col.bad)
    y = y - 11
  end
  local skip = scroll
  for i = #msgs, 1, -1 do
    local m = msgs[i]
    for j = #m.lines, 1, -1 do
      if skip > 0 then skip = skip - 1
      else
        if y < 28 then break end
        ui.text(6, y, m.lines[j], m.mine and col.accent or (j == 1 and col.text or col.muted))
        y = y - 11
      end
    end
    if y < 28 then break end
  end
  if #msgs == 0 then ui.text(6, 50, st == "error" and "" or "No messages yet", col.muted) end
  ui.box(2, 112, 236, 14)
  local shown = #input > 37 and input:sub(-37) or input
  ui.text(6, 115, shown .. ((math.floor(sys.millis() / 500) % 2 == 0) and "_" or ""), col.text)
end

function app.key(k)
  if view == "setup" then return false end
  local d = ui.nav(k)
  if view == "guilds" or view == "channels" then
    local n = list and #list or 0
    if d == "up" then sel = math.max(1, sel - 1)
    elseif d == "down" then sel = math.min(math.max(1, n), sel + 1)
    elseif k.key == "enter" and n > 0 then
      local it = list[sel]
      if view == "guilds" then
        guild, view, list, sel, top = it, "channels", nil, 1, 1
        discord.channels(it.id)
      else
        open_chat(it.id, it.name)
      end
    elseif k.key == "esc" then
      if view == "guilds" then return false end
      show_guilds()
    else return false end
    return true
  end
  -- chat: typing goes into the message; Fn+; / Fn+. scroll
  if k.key == "esc" then
    discord.open("")  -- stop reading the channel
    if guild then view, list, sel, top = "channels", nil, 1, 1; discord.channels(guild.id) else show_guilds() end
  elseif k.key == "up" then scroll = scroll + 1
  elseif k.key == "down" then scroll = math.max(0, scroll - 1)
  elseif k.key == "enter" then
    if #input > 0 then discord.send(input); input, scroll = "", 0 end
  elseif k.key == "backspace" then input = input:sub(1, -2)
  elseif k.text and not k.ctrl and #input < 300 then input = input .. k.text
  else return false end
  return true
end

function app.close()
  discord.stop()
  msgs, list = {}, nil
end

return app
