-- Settings > USB. Loaded when the page is opened and freed when it is
-- closed (see apps/settings.lua for ctx).
return function(ctx)
local push, pop, cycle, num = ctx.push, ctx.pop, ctx.cycle, ctx.num
-- ---------------------------------------------------------------- USB
-- The mix of USB functions is fixed at boot, so changes need a reboot.
local function share_page()
  local p = { title = "Share SD" }
  function p.enter() usb.share(true) end
  function p.leave() usb.share(false) end
  function p.rows()
    return {
      { label = "SD card is shared", dim = true },
      { label = "Eject it on the computer,", dim = true },
      { label = "then press Esc here.", dim = true },
    }
  end
  return p
end

local function usb_page()
  local p = { title = "USB" }
  local function flag(key, default)
    local v = cfg.get(key)
    if v == nil then return default or false end
    return v == "1"
  end
  local function toggle(key, default) cfg.set(key, flag(key, default) and "0" or "1") end
  function p.rows()
    local st = usb.status()
    local pending = flag("usb_kbd") ~= st.keyboard or flag("usb_serial", true) ~= st.serial or flag("usb_drive") ~= st.drive
      or flag("usb_mouse") ~= (st.mouse or false)
    local rows = {
      { label = "Keyboard", switch = flag("usb_kbd"), enter = function() toggle("usb_kbd") end },
      { label = "Serial + log", switch = flag("usb_serial", true), enter = function() toggle("usb_serial", true) end },
      { label = "Mouse", switch = flag("usb_mouse"), enter = function() toggle("usb_mouse") end },
      { label = "Drive (SD card)", switch = flag("usb_drive"), enter = function() toggle("usb_drive") end },
      { label = "Lua console", switch = flag("usb_console"), enter = function() toggle("usb_console") end },
    }
    if st.drive then
      rows[#rows + 1] = { label = "Share SD with computer", enter = function() push(share_page()) end }
    end
    rows[#rows + 1] = {
      label = pending and "Apply (reboots)" or "Up to date", dim = not pending,
      enter = function()
        if pending then
          shell.confirm("Reboot", "Restart to apply USB changes?", function(yes) if yes then sys.reboot() end end)
        end
      end,
    }
    return rows
  end
  return p
end

return usb_page()
end
