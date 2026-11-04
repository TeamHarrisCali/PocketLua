-- Settings > Display. Loaded when the page is opened and freed when it is
-- closed (see apps/settings.lua for ctx).
return function(ctx)
local push, pop, cycle, num = ctx.push, ctx.pop, ctx.cycle, ctx.num
local function display_page()
  local p = { title = "Display" }
  local function bright(d)
    local v = math.max(16, math.min(255, num("bright", 160) + d * 16))
    cfg.set("bright", v)
    gfx.brightness(v)
  end
  local function accent(d)
    local cur = cfg.get("accent") or "blue"
    local idx = 1
    for i, n in ipairs(ui.accent_names) do if n == cur then idx = i end end
    local name = ui.accent_names[cycle(idx, #ui.accent_names, d)]
    cfg.set("accent", name)
    ui.set_accent(name)
  end
  local SLEEP = { { 0, "Never" }, { 30, "30 s" }, { 60, "1 min" }, { 120, "2 min" }, { 300, "5 min" }, { 600, "10 min" } }
  local function sleep_i()
    for i, o in ipairs(SLEEP) do if o[1] == shell.sleep_after() then return i end end
    return 3
  end
  local function sleep_step(d)
    cfg.set("sleep", SLEEP[cycle(sleep_i(), #SLEEP, d)][1])
  end
  local function theme(d)
    local idx = 1
    for i, n in ipairs(ui.theme_names) do if n == ui.theme then idx = i end end
    local name = ui.theme_names[cycle(idx, #ui.theme_names, d)]
    cfg.set("theme", name)
    ui.set_theme(name)
  end
  function p.rows()
    return {
      { label = "Theme", value = ui.theme, left = function() theme(-1) end, right = function() theme(1) end,
        enter = function() theme(1) end },
      { label = "Lock screen", switch = cfg.get("lock") ~= "0", enter = function()
        cfg.set("lock", cfg.get("lock") == "0" and "1" or "0")
      end },
      { label = "Sleep after", value = SLEEP[sleep_i()][2],
        left = function() sleep_step(-1) end, right = function() sleep_step(1) end, enter = function() sleep_step(1) end },
      { label = "Brightness", value = math.floor(num("bright", 160) * 100 / 255) .. "%",
        left = function() bright(-1) end, right = function() bright(1) end, enter = function() bright(1) end },
      { label = "Accent colour", value = cfg.get("accent") or "blue",
        left = function() accent(-1) end, right = function() accent(1) end, enter = function() accent(1) end },
    }
  end
  return p
end

return display_page()
end
