-- Settings > Backup. Loaded when the page is opened and freed when it is
-- closed (see apps/settings.lua for ctx). The work is native (backup.cpp):
-- settings, notes, app data and scripts made on the device go into one file
-- in /pocketlua/backups; the 5 newest are kept.
return function(ctx)
local function backup_page()
  local p = { title = "Backup" }
  local list = {}  -- backup.list(), read when the page opens and after changes

  local function refresh() list = backup.list() end
  p.enter = refresh

  local function kb(n) return string.format("%d KB", (n + 1023) // 1024) end

  local function make()
    shell.toast("Backing up...", 1)
    local name, files, bytes = backup.make()
    if name then
      shell.toast(string.format("Backed up %d files (%s)", files, kb(bytes)), 3)
    else
      shell.toast("Backup failed: " .. tostring(files), 4)
    end
    refresh()
  end

  local function choose(b)
    local when = b.date ~= "" and b.date or b.name
    shell.menu(when, { "Restore", "Delete" }, function(i)
      if i == 1 then
        shell.confirm("Restore", "Replace settings, notes and app data with this backup? The Cardputer restarts.",
          function(yes)
            if not yes then return end
            local ok, err = backup.restore(b.name)  -- restarts when it works
            if not ok then shell.toast("Restore failed: " .. tostring(err), 4) end
          end)
      elseif i == 2 then
        shell.confirm("Delete", "Delete the backup from " .. when .. "?", function(yes)
          if yes then
            backup.remove(b.name)
            refresh()
            shell.toast("Backup deleted")
          end
        end)
      end
    end)
  end

  function p.rows()
    local rows = {
      { label = "Back up now", value = list[1] and (list[1].date ~= "" and list[1].date or "done") or "never",
        enter = make },
    }
    if #list == 0 then
      rows[2] = { label = "No backups yet", dim = true }
    end
    for _, b in ipairs(list) do
      rows[#rows + 1] = { label = b.date ~= "" and b.date or b.name, value = kb(b.size),
        enter = function() choose(b) end }
    end
    return rows
  end
  return p
end

return backup_page()
end
