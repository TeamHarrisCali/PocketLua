-- Settings > Wi-Fi. Loaded when the page is opened and freed when it is
-- closed (see apps/settings.lua for ctx).
return function(ctx)
local push, pop, cycle, num = ctx.push, ctx.pop, ctx.cycle, ctx.num
-- ---------------------------------------------------------------- Wi-Fi
local function connect(ssid, pw)
  cfg.set("wifi_ssid", ssid)
  cfg.set("wifi_pass", pw)
  cfg.set("wifi_auto", "1")
  if shell.wifi_start(ssid, pw) then
    shell.toast("Connecting to " .. ssid)
    pop()
  end
end

local function scan_page()
  local p = { title = "Networks" }
  local nets, scanning, poll = {}, true, 0

  function p.enter()
    nets, poll = {}, 0
    scanning = shell.wifi_start()  -- needs the radio on; reports if memory is short
    if scanning then wifi.scan_start() end
  end

  function p.update(dt)
    if not scanning then return end
    poll = poll + dt
    if poll > 0.4 then
      poll = 0
      local r = wifi.scan_result()
      if r then nets, scanning = r, false end
    end
  end

  function p.rows()
    if scanning then return { { label = "Scanning...", dim = true } } end
    if #nets == 0 then return { { label = "None found. R to rescan", dim = true } } end
    local rows = {}
    for _, n in ipairs(nets) do
      rows[#rows + 1] = {
        label = n.ssid ~= "" and n.ssid or "(hidden)",
        value = (n.secure and "* " or "") .. n.rssi,
        enter = function()
          if n.secure then
            shell.prompt("Password for " .. n.ssid, "", function(pw) if pw then connect(n.ssid, pw) end end, { secret = true })
          else
            connect(n.ssid, "")
          end
        end,
      }
    end
    return rows
  end

  function p.key(k)
    if k.text == "r" then p.enter(); return true end
  end
  return p
end

local STATUS = { off = "Off", idle = "Not connected", connecting = "Connecting...", connected = "Connected", failed = "Failed" }

local function wifi_page()
  local p = { title = "Wi-Fi" }
  function p.rows()
    local st = wifi.status()
    local saved = cfg.get("wifi_ssid")
    local rows = {
      { label = "Wi-Fi", switch = st ~= "off", enter = function()
        if st == "off" then
          cfg.set("wifi_auto", "1")
          shell.wifi_start(saved, cfg.get("wifi_pass"))
        else
          cfg.set("wifi_auto", "0")
          shell.wifi_stop()
        end
      end },
      { label = "Status", value = STATUS[st] .. (st == "connected" and (": " .. wifi.ssid()) or ""), dim = true },
    }
    if st == "connected" then rows[#rows + 1] = { label = "IP address", value = wifi.ip(), dim = true } end
    rows[#rows + 1] = { label = "Find networks", enter = function() push(scan_page()) end }
    if saved then
      rows[#rows + 1] = { label = "Forget " .. saved, enter = function()
        shell.confirm("Forget network", "Remove saved Wi-Fi " .. saved .. "?", function(yes)
          if yes then
            cfg.set("wifi_ssid", nil)
            cfg.set("wifi_pass", nil)
            wifi.disconnect()
          end
        end)
      end }
    end
    return rows
  end
  return p
end

return wifi_page()
end
