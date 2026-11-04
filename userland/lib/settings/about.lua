-- Settings > About. Loaded when the page is opened and freed when it is
-- closed (see apps/settings.lua for ctx).
return function(ctx)
local push, pop, cycle, num = ctx.push, ctx.pop, ctx.cycle, ctx.num
-- ---------------------------------------------------------------- About
local function about_page()
  local p = { title = "About" }
  function p.rows()
    local kind, total, used = sys.storage()
    local heap, lmem, largest = sys.heap()
    local up = sys.millis() // 1000
    return {
      { label = "LiveOS", value = "v" .. sys.version, dim = true },
      { label = "Mode", value = sys.safe_mode and "Safe" or "Normal", dim = true },
      { label = "Storage", value = string.format("%s %dM free", kind, (total - used) // 1024), dim = true },
      { label = "Memory", value = string.format("%dK free (%dK blk)", heap // 1024, largest // 1024), dim = true },
      { label = "Lua heap", value = string.format("%dK", lmem // 1024), dim = true },
      { label = "Uptime", value = string.format("%dm %ds", up // 60, up % 60), dim = true },
      { label = "Task Manager", enter = function() shell.launch("tasks") end },
      { label = "Reload system", enter = function() sys.reload() end },
      { label = "Reboot", enter = function()
        shell.confirm("Reboot", "Restart the device?", function(yes) if yes then sys.reboot() end end)
      end },
    }
  end
  return p
end

return about_page()
end
