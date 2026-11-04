-- Nearby: other LiveOS devices that share your network key. Pick one to ping
-- it, play a sound on it, read its battery, message it, or watch its tilt.
local col = ui.col
local dev = require("dev")

local app = { title = "Nearby", icon = "net", color = "teal", order = 12, category = "net" }

local sel, top = 1, 1
local peers = {}
local watching, tilt, poll = nil, nil, 0

local function d(name) return dev.mount(name) end

local ACTIONS = { "Ping", "Play a tone", "Battery", "Send a message", "Watch its tilt" }

local function act(peer, i)
  local remote = d(peer.name)
  if i == 1 then
    local t0 = sys.millis()
    remote.sys.ping(function(_, err)
      shell.toast(err and ("No reply: " .. err) or string.format("%s replied in %d ms", peer.name, sys.millis() - t0))
    end)
  elseif i == 2 then
    remote.snd.tone(880, 300, function(_, err) if err then shell.toast(err) end end)
  elseif i == 3 then
    remote.sys.battery(function(r, err)
      shell.toast(err and err or string.format("%s: %d%%%s", peer.name, r.pct, r.charging and " (charging)" or ""))
    end)
  elseif i == 4 then
    shell.prompt("Message to " .. peer.name, "", function(text)
      if text and text ~= "" then remote.shell.toast(text) end
    end)
  elseif i == 5 then
    watching, tilt, poll = peer, nil, 0
  end
end

function app.init()
  sel, top, watching = 1, 1, nil
  if cfg.get("dev_on") == "1" and not dev.running() then dev.start() end
end

function app.close()
  if dev.running() then dev.stop() end
end

function app.update(dt)
  if not dev.running() then return end
  dev.poll()
  peers = dev.peers()
  if watching then
    poll = poll - dt
    if poll <= 0 then
      poll = 0.2
      d(watching.name).imu.read(function(r) if r then tilt = r end end)
    end
  end
end

function app.draw()
  if not dev.running() then
    ui.empty("warn", "Device sharing is off", "Settings > Devices")
    return
  end
  if watching then
    local cx, cy, r = 120, 72, 40
    gfx.circle(cx, cy, r, col.panel2)
    gfx.line(cx - r, cy, cx + r, cy, col.panel2)
    gfx.line(cx, cy - r, cx, cy + r, col.panel2)
    ui.text(6, 18, watching.name .. " tilt", col.accent)
    if tilt then
      local bx = math.max(-r, math.min(r, -tilt.ay * 90))
      local by = math.max(-r, math.min(r, tilt.ax * 90))
      gfx.disc(cx + bx, cy + by, 6, col.good)
    else
      ui.center(70, "waiting...", col.dim)
    end
    ui.footer({ { "Esc", "Stop watching" } })
    return
  end
  local rows = {}
  for _, p in ipairs(peers) do
    rows[#rows + 1] = { label = p.name, value = p.rssi .. " dBm", badge = "D", badge_color = ui.accents.teal }
  end
  if #rows == 0 then
    ui.center(60, "Looking for devices...", col.dim)
    ui.center(74, "They need the same key.", col.dim)
  else
    sel = math.max(1, math.min(sel, #rows))
    top = ui.list(rows, sel, top, 4, 17, 230, 17, 6)
  end
  ui.footer({ { "Enter", "Actions" }, { "Esc", "Home" } })
  ui.right(236, 126, dev.name, col.muted)
end

function app.key(k)
  if watching then
    if k.key == "esc" then watching = nil; return true end
    return false
  end
  local d_ = ui.nav(k)
  if d_ == "up" then sel = math.max(1, sel - 1)
  elseif d_ == "down" then sel = math.min(#peers, sel + 1)
  elseif k.key == "enter" and peers[sel] then
    local peer = peers[sel]
    shell.menu(peer.name, ACTIONS, function(i) if i then act(peer, i) end end)
  else return false end
  return true
end

return app
