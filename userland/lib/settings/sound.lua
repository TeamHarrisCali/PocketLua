-- Settings > Sound. Loaded when the page is opened and freed when it is
-- closed (see apps/settings.lua for ctx).
return function(ctx)
local push, pop, cycle, num = ctx.push, ctx.pop, ctx.cycle, ctx.num
local function sound_page()
  local p = { title = "Sound" }
  local function vol(d)
    snd.step(d)  -- one of 20 even steps (2.5 dB)
    snd.tone(880, 80)
  end
  function p.rows()
    return {
      { label = "Volume", value = select(2, snd.level()) .. "%",
        left = function() vol(-1) end, right = function() vol(1) end, enter = function() vol(1) end },
      { label = "System sounds", switch = cfg.get("sounds") ~= "0", enter = function()
        cfg.set("sounds", cfg.get("sounds") == "0" and "1" or "0")
      end },
      { label = "Key click", switch = cfg.get("click") == "1", enter = function()
        cfg.set("click", cfg.get("click") == "1" and "0" or "1")
      end },
    }
  end
  return p
end

return sound_page()
end
