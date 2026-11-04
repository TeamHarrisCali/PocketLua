-- Files: browse LiveOS scripts and the whole SD card, open anything in the editor.
local col = ui.col

local app = { title = "Files", icon = "folder", color = "teal", order = 2, category = "system" }

local MAX_EDIT = 32 * 1024  -- matches the editor's limit

local path = nil  -- nil shows the place chooser
local entries, rows = {}, {}
local sel, top = 1, 1

local function join(a, b)
  if a == "" then return b end
  if a == "sd:" then return "sd:/" .. b end
  return a .. "/" .. b
end

-- Parent directory, or nil when the next step up is the place chooser.
local function parent(p)
  if p == "" or p == "sd:" then return nil end
  local up = p:match("^(.*)/[^/]*$")
  if up == nil then return "" end
  return up
end

local function size_text(n)
  if n < 1024 then return n .. "B" end
  return string.format("%.1fK", n / 1024)
end

local function refresh()
  entries, rows = {}, {}
  if path == nil then
    local kind = sys.storage()
    entries = { { root = "" }, { root = "sd:", off = kind ~= "SD" } }
    rows = {
      { label = "LiveOS", value = "apps, lib, data", badge = "L", badge_color = ui.accents.purple },
      { label = "SD card", value = kind == "SD" and "all files" or "not found", badge = "S",
        badge_color = ui.accents.teal, dim = kind ~= "SD" },
    }
    app.title = "Files"
    return
  end
  local raw = path:sub(1, 3) == "sd:"
  entries[1] = { up = true }
  rows[1] = { label = "..", badge = "<", badge_color = col.panel2 }
  for _, e in ipairs(sys.list(path)) do
    entries[#entries + 1] = e
    local value
    if e.dir then value = nil
    elseif not raw and e.stored and e.emb then value = "edited"
    elseif not raw and e.emb then value = "built-in"
    else value = size_text(e.size) end
    local badge, bc = "F", col.panel2
    if e.dir then badge, bc = "D", ui.accents.orange
    elseif e.name:match("%.lua$") then badge, bc = "L", ui.accents.purple end
    rows[#rows + 1] = { label = e.name .. (e.dir and "/" or ""), value = value, badge = badge, badge_color = bc }
  end
  app.title = path == "" and "Files: LiveOS" or ("Files: " .. path)
end

local function go(p)
  path, sel, top = p, 1, 1
  refresh()
end

function app.init()
  go(nil)
end

local function current()
  return entries[sel]
end

local function open_entry()
  local e = current()
  if not e then return end
  if path == nil then
    if e.off then shell.toast("No SD card inserted"); return end
    go(e.root)
  elseif e.up then
    go(parent(path))
  elseif e.dir then
    go(join(path, e.name))
  else
    local full = join(path, e.name)
    local ext = (e.name:match("%.([%w]+)$") or ""):lower()
    if (shell.handlers[ext] == "edit" or ext == "") and e.size > MAX_EDIT then
      shell.toast("File too large to edit")
    elseif ext == "" then
      shell.edit(full)
    else
      shell.open_file(full)
    end
  end
end

local function remove_entry()
  local e = current()
  if not e or e.up or not path then return end
  local full = join(path, e.name)
  if not e.stored then shell.toast("Built-in file, nothing to remove"); return end
  local msg = (e.emb and "Revert " or "Delete ") .. e.name .. (e.emb and " to the built-in version?" or "?")
  shell.confirm(e.emb and "Revert" or "Delete", msg, function(yes)
    if not yes then return end
    if sys.remove(full) then shell.toast(e.emb and "Reverted" or "Deleted") else shell.toast("Could not remove") end
    refresh()
    sel = math.min(sel, #entries)
  end)
end

local function new_file()
  if not path then return end
  shell.prompt("New file name", "", function(name)
    if name and name ~= "" then shell.edit(join(path, name)) end
  end)
end

function app.draw()
  sel = math.max(1, math.min(sel, #rows))
  top = ui.list(rows, sel, top, 4, 17, 230, 17, 6)
  ui.footer(path and { { "Enter", "Open" }, { "X", "Remove" }, { "N", "New" }, { "Esc", "Up" } } or { { "Enter", "Open" }, { "Esc", "Home" } })
end

function app.key(k)
  local d = ui.nav(k)
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(#rows, sel + 1)
  elseif k.key == "enter" or d == "right" then open_entry()
  elseif d == "left" then if path then go(parent(path)) end
  elseif k.text == "x" then remove_entry()
  elseif k.text == "n" then new_file()
  elseif k.key == "esc" then
    if path == nil then return false end
    go(parent(path))
  else
    return false
  end
  return true
end

return app
