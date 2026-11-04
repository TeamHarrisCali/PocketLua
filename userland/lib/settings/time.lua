-- Settings > Date & Time. Loaded when the page is opened and freed when it is
-- closed (see apps/settings.lua for ctx).
return function(ctx)
local push, pop, cycle, num = ctx.push, ctx.pop, ctx.cycle, ctx.num
local ZONES = {
  { "Pacific", "PST8PDT,M3.2.0,M11.1.0" },
  { "Mountain", "MST7MDT,M3.2.0,M11.1.0" },
  { "Arizona", "MST7" },
  { "Central", "CST6CDT,M3.2.0,M11.1.0" },
  { "Eastern", "EST5EDT,M3.2.0,M11.1.0" },
  { "UTC", "UTC0" },
}
local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function time_page()
  local p = { title = "Date & Time" }
  local function zone_i()
    for i, z in ipairs(ZONES) do if z[2] == shell.tz() then return i end end
    return 1
  end
  local function step(d)
    local z = ZONES[cycle(zone_i(), #ZONES, d)]
    cfg.set("tz", z[2])
    clock.set_tz(z[2])
    if wifi.status() == "connected" then clock.sync(z[2]) end
  end
  function p.rows()
    local t = clock.now()
    local now = t.valid and string.format("%s %04d-%02d-%02d  %s", DAYS[t.wday + 1], t.year, t.month, t.day,
      shell.format_time(t)) or "Not set (needs Wi-Fi)"
    return {
      { label = "Now", value = now, dim = true },
      { label = "Time zone", value = ZONES[zone_i()][1], enter = function() step(1) end,
        left = function() step(-1) end, right = function() step(1) end },
      { label = "12-hour clock", switch = cfg.get("clock12") == "1", enter = function()
        cfg.set("clock12", cfg.get("clock12") == "1" and "0" or "1")
      end },
      { label = "Sync now", enter = function()
        if wifi.status() == "connected" then clock.sync(shell.tz()); shell.toast("Syncing...")
        else shell.toast("Connect to Wi-Fi first") end
      end },
    }
  end
  return p
end

return time_page()
end
