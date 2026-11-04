-- Settings > About. Loaded when the page is opened and freed when it is
-- closed (see apps/settings.lua for ctx).
return function(ctx)
local push, pop, cycle, num = ctx.push, ctx.pop, ctx.cycle, ctx.num
-- ---------------------------------------------------------------- Updates
-- Release (the main branch) or Beta, each after a Y/N question; leaving
-- Beta warns that Beta apps and their data may not work on the older Release. Either way the App Store does the switch natively: it reads
-- the other channel, installs its firmware and app versions, and restarts.
local function channel_row()
  local as = appstore
  if not as then return nil end
  local cur = as.channel()
  local function switch()
    sys.log("updates: change asked on " .. cur)
    if cur == "main" then
      shell.confirm("Join Beta", "Test builds of the firmware and apps arrive first. Installs Beta now and restarts. Going back later means older versions.",
        function(yes)
          sys.log("updates: join beta " .. (yes and "yes" or "no"))
          if yes then as.run("switch", "beta") end
        end)
      return
    end
    shell.confirm("Leave Beta", "Go back to Release? It reinstalls the older firmware and apps; Beta data may not work there.",
      function(yes)
        sys.log("updates: leave beta " .. (yes and "yes" or "no"))
        if yes then as.run("switch", "main") end
      end)
  end
  -- Enter or <> (the footer's "Change") start the same, guarded, switch
  return { label = "Updates", value = cur == "main" and "Release" or "Beta", enter = switch, left = switch, right = switch }
end

-- ---------------------------------------------------------------- About
local function about_page()
  local p = { title = "About" }
  function p.rows()
    local kind, total, used = sys.storage()
    local heap, lmem, largest = sys.heap()
    local up = sys.millis() // 1000
    return {
      { label = "PocketLua", value = "v" .. sys.version .. " " .. (sys.build or ""), dim = true },
      channel_row() or { label = "Updates", value = "-", dim = true },
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
