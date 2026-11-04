-- Settings > Devices. Loaded when the page is opened and freed when it is
-- closed (see apps/settings.lua for ctx).
return function(ctx)
local push, pop, cycle, num = ctx.push, ctx.pop, ctx.cycle, ctx.num
-- ---------------------------------------------------------------- Devices
local function devices_page()
  -- Only Nearby needs the device-sharing module; this page just edits settings.
  local p = { title = "Devices" }
  local function name() return cfg.get("dev_name") or ("liveos-" .. net.mac():sub(-4)) end
  local function ask(title, key, secret)
    shell.prompt(title, secret and "" or (cfg.get(key) or ""), function(text)
      if text and text ~= "" then cfg.set(key, text); shell.dev_restart() end
    end, { secret = secret })
  end
  function p.rows()
    local key_set = (cfg.get("dev_key") or "") ~= ""
    return {
      { label = "Share devices", switch = cfg.get("dev_on") == "1", enter = function()
        if cfg.get("dev_on") == "1" then cfg.set("dev_on", "0")
        elseif not key_set then shell.toast("Set a network key first"); return
        else cfg.set("dev_on", "1") end
        shell.dev_restart()
      end },
      { label = "Device name", value = name(), enter = function() ask("Device name", "dev_name", false) end },
      { label = "Network key", value = key_set and "set" or "not set", enter = function() ask("Network key (same on all devices)", "dev_key", true) end },
      { label = "Nearby devices", enter = function() shell.launch("nearby") end },
    }
  end
  return p
end

return devices_page()
end
