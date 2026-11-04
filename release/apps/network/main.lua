-- Network: nearby Wi-Fi networks with a channel chart, the connection details,
-- and DNS lookup / TCP ping tools. Tab switches between them.
local col = ui.col

local app = { title = "Network", icon = "radar", color = "teal", order = 32, category = "net" }
app.help = {
  { "Tab", "Next tab" },
  { "<>", "Prev / next tab" },
  { "Up/Dn", "Select" },
  { "Enter", "Info / connect / run" },
  { "R", "Rescan / refresh" },
  { "X", "Tools: clear results" },
}

local TABS = { "Scan", "Info", "Tools" }
local MAX_NETS, MAX_RESULTS = 20, 12
local tab, sel, top = 1, 1, 1

-- Scan
local nets, chan, chan_max = {}, {}, 1
local scanning, radio_ok, poll, scan_t = false, true, 0, 0
local started_radio = false  -- we turned the radio on, so turn it off again on close

-- Info
local STATUS = { off = "Off", idle = "Not connected", connecting = "Connecting", connected = "Connected", failed = "Failed" }
local info, info_t, sig, sig_col, connected = {}, 0, 0, nil, false

-- Tools
local tools = {}     -- two action rows, then results (newest first)
local job            -- { kind, host, port, wait }
local last_host = "example.com"

local function bars(rssi) return rssi > -55 and 4 or rssi > -65 and 3 or rssi > -75 and 2 or 1 end

local function start_scan()
  nets, chan, chan_max, sel, top, poll, scan_t = {}, {}, 1, 1, 1, 0, 0
  for i = 1, 13 do chan[i] = 0 end
  local was_off = wifi.status() == "off"
  radio_ok = shell.wifi_start() and true or false
  if radio_ok and was_off then started_radio = true end
  scanning = radio_ok
  if radio_ok then wifi.scan_start() end
end

local function take(r)
  for _, n in ipairs(r) do
    local c = n.channel or 0
    if c >= 1 and c <= 13 then chan[c] = chan[c] + 1; chan_max = math.max(chan_max, chan[c]) end
  end
  table.sort(r, function(a, b) return (a.rssi or -100) > (b.rssi or -100) end)
  for i = 1, math.min(#r, MAX_NETS) do
    local n = r[i]
    local rssi = n.rssi or -100
    nets[i] = {
      label = "    " .. ((n.ssid and n.ssid ~= "") and n.ssid or "(hidden)"),
      value = string.format("%sch%-2s %d", n.secure and "* " or "", tostring(n.channel or "?"), rssi),
      bars = bars(rssi),
      note = (n.bssid or "") .. (n.secure and "  secured" or "  open"),
    }
  end
end

local function build_info()
  local st = wifi.status()
  connected = st == "connected"
  local r = connected and wifi.rssi() or nil
  info = {
    { label = "Status", value = STATUS[st] or tostring(st) },
    { label = connected and "Network" or "Saved network", value = connected and wifi.ssid() or (cfg.get("wifi_ssid") or "none") },
    { label = "IP address", value = connected and wifi.ip() or "-" },
    { label = "Signal", value = r and (r .. " dBm") or "-" },
  }
  sig = r and math.max(0, math.min(1, (r + 95) / 60)) or 0
  sig_col = not r and col.muted or r > -65 and col.good or r > -75 and col.warn or col.bad
end

local function build_tools(res)
  local rows = { { label = "DNS lookup...", badge = "D", badge_color = ui.accents.blue },
                 { label = "TCP ping...", badge = "P", badge_color = ui.accents.teal } }
  for _, r in ipairs(res or {}) do rows[#rows + 1] = r end
  tools = rows
end

local function results()
  local out = {}
  for i = 3, #tools do out[#out + 1] = tools[i] end
  return out
end

local function add_result(row)
  local res = results()
  table.insert(res, 1, row)
  while #res > MAX_RESULTS do table.remove(res) end
  build_tools(res)
end

local function run_job()
  local j = job
  job = nil
  if wifi.status() ~= "connected" then shell.toast("Connect to Wi-Fi first"); return end
  if j.kind == "dns" then
    local ip, e = http.dns(j.host)
    add_result({ label = j.host, value = ip or "failed", badge = "D", badge_color = ui.accents.blue, kind = "dns", host = j.host })
    if not ip then shell.toast("DNS failed" .. (e and (": " .. tostring(e)) or ""), 3) end
  else
    local ms, e = http.ping(j.host, j.port)
    add_result({ label = j.host .. ":" .. j.port, value = ms and (ms .. " ms") or "failed", badge = "P",
      badge_color = ui.accents.teal, kind = "ping", host = j.host, port = j.port })
    if not ms then shell.toast("No connection" .. (e and (": " .. tostring(e)) or ""), 3) end
  end
  sel, top = 3, 1
end

local function queue(kind, host, port)
  if wifi.status() ~= "connected" then shell.toast("Connect to Wi-Fi first"); return end
  job = { kind = kind, host = host, port = port, wait = 1 }
  shell.toast(kind == "dns" and ("Looking up " .. host) or ("Connecting to " .. host .. ":" .. port))
end

local function ask(kind)
  local title = kind == "dns" and "Host name" or "Host[:port] (port 80)"
  shell.prompt(title, last_host, function(s)
    if not s then return end
    s = s:gsub("%s", "")
    local host, port = s:match("^([^:]+):?(%d*)$")
    if not host then shell.toast("Enter a host name"); return end
    last_host = host
    queue(kind, host, tonumber(port) or 80)
  end)
end

local function show(i)
  tab, sel, top = i, 1, 1
  if tab == 1 and #nets == 0 and not scanning then start_scan() end
  if tab == 2 then info_t = 0 end
end

function app.init(_, saved)
  nets, tools, job, started_radio, scanning = {}, {}, nil, false, false
  build_tools()
  build_info()
  show(saved and saved.tab or 1)
end

function app.save() return { tab = tab } end

function app.update(dt)
  if tab == 1 and scanning then
    poll, scan_t = poll + dt, scan_t + dt
    if poll >= 0.5 then
      poll = 0
      local r = wifi.scan_result()
      if r then take(r); scanning = false
      elseif scan_t > 15 then scanning = false end
    end
  end
  if tab == 2 then
    info_t = info_t - dt
    if info_t <= 0 then info_t = 1; build_info() end
  end
  if job then
    if job.wait > 0 then job.wait = job.wait - 1 else run_job() end
  end
end

local function draw_scan(y)
  if not radio_ok then
    ui.empty("wifi", "Wi-Fi could not start", "Free memory in Task Manager, R")
  elseif #nets == 0 then
    ui.empty("radar", scanning and "Scanning..." or "No networks found", scanning and "This takes a few seconds" or "R scans again")
  else
    top = ui.list(nets, sel, top, 4, y, 228, 15, 4)
    for i = 0, 3 do
      local r = nets[top + i]
      if not r then break end
      local by = y + i * 15 + 12
      for b = 1, 4 do
        gfx.fill(12 + (b - 1) * 4, by - b * 2 - 1, 3, b * 2 + 1, b <= r.bars and col.accent or col.line)
      end
    end
  end
  -- channel usage, 1-13
  for c = 1, 13 do
    local x = 8 + (c - 1) * 17
    local n = chan[c] or 0
    local h = n > 0 and math.max(2, n * 15 // chan_max) or 1
    gfx.fill(x + 2, 110 - h, 13, h, n == chan_max and n > 0 and col.accent or (n > 0 and col.muted or col.line))
    local s = tostring(c)
    gfx.text(x + (17 - #s * 6) // 2, 113, s, col.muted)
  end
  ui.footer({ { "R", "Rescan" }, { "Enter", "Info" }, { "Tab", "Next" }, { "Esc", "Home" } })
end

local function draw_info(y)
  ui.list(info, 0, 1, 4, y, 228, 15, 4)
  ui.title(10, y + 66, "SIGNAL")
  ui.bar(56, y + 67, 170, 6, sig, sig_col)
  if not connected then ui.center(y + 80, "Enter connects to the saved network", col.muted) end
  ui.footer({ { "Enter", "Connect" }, { "Tab", "Next" }, { "Esc", "Home" } })
end

local function draw_tools(y)
  top = ui.list(tools, sel, top, 4, y, 228, 15, 6)
  ui.footer({ { "Enter", "Run" }, { "X", "Clear" }, { "Tab", "Next" }, { "Esc", "Home" } })
end

function app.draw()
  local y = ui.tabs(TABS, tab, ui.TOP)
  if tab == 1 then draw_scan(y) elseif tab == 2 then draw_info(y) else draw_tools(y) end
end

local function enter()
  if tab == 1 then
    local n = nets[sel]
    if n then shell.toast(n.note, 3) end
  elseif tab == 2 then
    local ssid = cfg.get("wifi_ssid")
    if wifi.status() == "connected" then shell.toast("Already connected")
    elseif not ssid then shell.toast("Set up Wi-Fi in Settings > Wi-Fi", 3)
    elseif shell.wifi_start(ssid, cfg.get("wifi_pass")) then shell.toast("Connecting to " .. ssid); info_t = 0 end
  else
    local r = tools[sel]
    if sel == 1 then ask("dns")
    elseif sel == 2 then ask("ping")
    elseif r then queue(r.kind, r.host, r.port) end
  end
end

function app.key(k)
  local n = tab == 1 and #nets or tab == 3 and #tools or 0
  local d = ui.nav(k)
  local c = not k.ctrl and not k.fn and k.text
  if k.key == "tab" then show((tab - 1 + (k.shift and -1 or 1)) % #TABS + 1)
  elseif d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.max(1, math.min(n, sel + 1))
  elseif d == "left" or d == "right" then show((tab - 1 + (d == "left" and -1 or 1)) % #TABS + 1)
  elseif k.key == "enter" then enter()
  elseif c == "r" then
    if tab == 1 then start_scan() elseif tab == 2 then info_t = 0; shell.toast("Refreshed") else return false end
  elseif c == "x" and tab == 3 then build_tools(); sel, top = 1, 1; shell.toast("Results cleared")
  else return false end
  return true
end

function app.close()
  if started_radio and wifi.status() == "idle" then shell.wifi_stop() end
  nets, chan, info, tools, job = {}, {}, {}, {}, nil
end

return app
