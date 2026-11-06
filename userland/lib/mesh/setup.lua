-- Mesh > Setup: names, preset, position sharing and private channels (add
-- with a new or pasted key, show the key to share, remove). Loaded while the
-- tab is open (see apps/mesh.lua for S).
return function(S)
local col = ui.col
local POS_MODES = { "Off", "Approx", "Precise" }
local rows, sel, top = {}, 1, 1
local refresh = 0

-- ---------------------------------------------------------------- base64
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    for j = 0, 3 do
      if j <= 1 or (j == 2 and b) or (j == 3 and c) then
        local v = (n >> (18 - j * 6)) & 63
        out[#out + 1] = B64:sub(v + 1, v + 1)
      else
        out[#out + 1] = "="
      end
    end
  end
  return table.concat(out)
end

local function b64decode(s)  -- nil if it isn't base64 (URL-safe - and _ accepted)
  s = s:gsub("%s", ""):gsub("-", "+"):gsub("_", "/"):gsub("=+$", "")
  if s:find("[^%w%+/]") then return nil end
  local out, n, bits = {}, 0, 0
  for i = 1, #s do
    n, bits = (n << 6) | (B64:find(s:sub(i, i), 1, true) - 1), bits + 6
    if bits >= 8 then
      bits = bits - 8
      out[#out + 1] = string.char((n >> bits) & 0xFF)
    end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------- rows
local function build()
  rows = {
    { label = "Name", value = ui.fit(S.long_name, 120) },
    { label = "Short name", value = S.short_name },
    { label = "Preset", value = S.preset and S.preset.name or "?" },
    { label = "Share position", value = POS_MODES[S.pos_mode] },
  }
  for i = 1, #S.channels do
    rows[#rows + 1] = { label = "Channel " .. i, value = S.chan_name(i) .. (i == 1 and " (public)" or ""), ch = i }
  end
  if #S.channels < 8 then rows[#rows + 1] = { label = "+ Add private channel", add = true } end
  rows[#rows + 1] = { label = "Node", value = S.mt.id_text(S.me), dim = true }
  rows[#rows + 1] = { label = "Packets", value = "TX " .. S.tx .. "  RX " .. S.rx, dim = true }
  sel = math.max(1, math.min(sel, #rows))
end

local function add_channel()
  shell.prompt("Channel name (up to 11)", "", function(name)
    name = name and S.clean(name):gsub("[|%s]", "")
    if not name or name == "" then return end
    name = name:sub(1, 11)
    shell.prompt("Key in base64 (blank: make a new one)", "", function(k)
      if k == nil then return end
      local psk = k:match("^%s*$") and crypto.random(32) or b64decode(k)
      if not psk or (#psk ~= 16 and #psk ~= 32 and #psk ~= 1) then
        shell.alert("Not a key", "A channel key is 16 or 32 bytes of base64, as the Meshtastic app shows it.")
        return
      end
      S.add_channel(name, psk)
      build()
      shell.alert(name, "Added. To join from another device, add a channel named " .. name
        .. " with this key: " .. b64encode(psk))
    end)
  end)
end

local function channel_menu(i)
  if i == 1 then shell.toast("The public channel: Preset changes it"); return end
  local c = S.channels[i]
  shell.menu(c.name, { "Show key", "Remove" }, function(a)
    if a == 1 then
      shell.alert(c.name, "Key: " .. b64encode(c.psk) .. "  (name " .. c.name .. ")")
    elseif a == 2 then
      shell.confirm("Remove " .. c.name .. "?", "Its chat history stays on the card.", function(yes)
        if yes then S.remove_channel(i); build() end
      end)
    end
  end)
end

local function change(r, d)
  if sel == 1 or sel == 2 then
    local long = sel == 1
    shell.prompt(long and "Name (up to 39)" or "Short name (up to 4)", long and S.long_name or S.short_name, function(t)
      t = t and S.clean(t):match("^%s*(.-)%s*$")
      if not t or t == "" then return end
      if long then S.long_name = t:sub(1, 39); cfg.set("mesh_long", S.long_name)
      else S.short_name = t:sub(1, 4); cfg.set("mesh_short", S.short_name) end
      S.announce()
      build()
    end)
  elseif sel == 3 then
    S.preset_i = (S.preset_i - 1 + d) % #S.mt.PRESETS + 1
    cfg.set("mesh_preset", tostring(S.preset_i))
    S.chat = {}  -- the public channel's history follows the preset's name
    S.start_radio()
    shell.toast(S.radio_ok and string.format("%s %.3f MHz", S.preset.name, S.freq) or ("Radio: " .. tostring(S.radio_err)))
  elseif sel == 4 then
    S.pos_mode = (S.pos_mode - 1 + d) % #POS_MODES + 1
    cfg.set("mesh_pos", tostring(S.pos_mode))
    S.position_soon()
    shell.toast(S.pos_mode == 1 and "Position not shared" or S.pos_mode == 2 and "Sharing an approximate position (~5 km)"
      or "Sharing your exact position", 2)
  elseif r.ch then channel_menu(r.ch)
  elseif r.add then add_channel()
  end
  build()
end

local tab = {}

function tab.init() build() end
function tab.close() rows = {} end

function tab.update(dt)
  refresh = refresh - dt
  if refresh <= 0 then refresh = 1; build() end
end

function tab.draw()
  top = ui.list(rows, sel, top, 4, 33, 229, 15, 5)
  ui.text(4, 112, "Enter or </> changes", col.muted)
  ui.footer({ { "Enter", "Change" }, { "Tab", "Chat" }, { "Esc", "Back" } })
end

function tab.key(k, d)
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(#rows, sel + 1)
  elseif (k.key == "enter" or d == "right") and rows[sel] then change(rows[sel], 1)
  elseif d == "left" and sel <= 4 then change(rows[sel], -1)
  else return false end
  return true
end

return tab
end
