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
      -- the board can't sense the jack, so headphone mode is switched by hand;
      -- it keeps its own volume, which stops at the maximum below
      { label = "Headphones", switch = (snd.headphones()), enter = function()
        local on = snd.headphones(not snd.headphones())
        shell.toast(on and ("Headphones: up to " .. snd.headphone_max() .. "%") or "Speaker volume", 2)
      end },
      { label = "Headphone max", value = snd.headphone_max() .. "%",
        left = function() snd.headphone_max(snd.headphone_max() - 5) end,
        right = function() snd.headphone_max(snd.headphone_max() + 5) end,
        enter = function() snd.headphone_max(snd.headphone_max() + 5) end },
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
