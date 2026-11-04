-- App Store: get apps from the PocketLua repository on GitHub, update them,
-- and uninstall the ones you don't want. Nothing updates by itself: C checks,
-- then you choose. Downloads run with this app closed (the shell does them
-- natively, see src/appstore.cpp) and the store reopens when they are done.
local col = ui.col
local app = { title = "App Store", icon = "store", color = "green", order = 24, category = "system" }
app.help = {
  { "C", "Check for updates" },
  { "Tab", "Switch tab" },
  { "Enter", "Install, update, open" },
  { "Space", "Mark several" },
  { "A-Z", "Search (Browse)" },
  { "X", "Uninstall (Installed)" },
  { "Esc", "Clear search / home" },
}

local TABS = { "Updates", "Browse", "Installed" }
local tab = 1
local cat = nil            -- appstore.list(): { firmware = {...}, apps = {...} }, nil before a check
local rows, items = {}, {} -- what the current tab shows; items[i] is the app (or "firmware")
local sel, top = 1, 1
local marked = {}          -- name -> true
local query = ""
local note = ""            -- result of the last check or install

local function size_text(n)
  return n >= 1024 * 1024 and string.format("%.1f MB", n / 1048576) or string.format("%d KB", (n + 1023) // 1024)
end

-- Builds rows/items for the current tab from the catalog.
local function build()
  rows, items = {}, {}
  if not cat then return end
  local q = query:lower()
  if tab == 1 and cat.firmware.status == "update" then
    items[#items + 1] = "firmware"
    rows[#rows + 1] = { label = "Firmware " .. cat.firmware.build, value = size_text(cat.firmware.size), badge = "F",
      badge_color = ui.accents.orange }
  end
  for _, a in ipairs(cat.apps) do
    local show = (tab == 1 and a.status == "update")
      or (tab == 2 and a.status == "available" and (q == "" or a.title:lower():find(q, 1, true)))
      or (tab == 3 and a.status ~= "available")
    if show and a.name ~= "edit" then  -- the editor is part of the system
      items[#items + 1] = a
      rows[#rows + 1] = { label = (marked[a.name] and "* " or "") .. a.title,
        value = tab == 3 and (a.status == "update" and "update" or (a.core and "system" or "")) or size_text(a.size) }
    end
  end
  if tab == 1 and marked.firmware and rows[1] and items[1] == "firmware" then rows[1].label = "* " .. rows[1].label end
  sel = math.max(1, math.min(sel, #rows))
end

local function load()
  cat = appstore.list()
  build()
end

-- Starts a download/removal: the shell closes this app and reopens it after.
local function apply(ops)
  if #ops == 0 then return end
  appstore.run("apply", table.concat(ops, ","))
end

local function chosen(verb)
  local ops = {}
  for name in pairs(marked) do ops[#ops + 1] = name == "firmware" and "firmware" or (verb .. ":" .. name) end
  if #ops == 0 then
    local it = items[sel]
    if it == "firmware" then ops[1] = "firmware" elseif it then ops[1] = verb .. ":" .. it.name end
  end
  return ops
end

function app.init(args, saved)
  tab = saved and saved.tab or 1
  local r = appstore.result()
  if r ~= "" then note = r end
  load()
  if not cat and note == "" then note = "Press C to check GitHub for apps" end
end

function app.save() return { tab = tab } end

function app.close() cat, rows, items, marked = nil, {}, {}, {} end

function app.draw()
  ui.tabs(TABS, tab)
  local info = items[sel]
  if not cat then
    ui.empty("store", "No catalog yet", "C checks GitHub (Wi-Fi needed)")
  elseif #rows == 0 then
    ui.empty("store", tab == 1 and "Everything is up to date" or tab == 2 and (query ~= "" and "No match" or "You have every app")
      or "No apps installed", tab == 2 and "Search: type a name" or "C checks again")
  else
    top = ui.list(rows, sel, top, 4, 31, 230, 15, 4)
    if type(info) == "table" then
      ui.text(6, 93, ui.fit(info.desc ~= "" and info.desc or info.category, 228), col.muted)
    elseif info == "firmware" then
      ui.text(6, 93, ui.fit("Restarts when done; a build that fails to start is undone", 228), col.muted)
    end
  end
  local status = query ~= "" and ("Search: " .. query) or note
  ui.text(6, 108, ui.fit(status, 228), note:sub(1, 6) == "error:" and query == "" and col.bad or col.muted)
  local enter = tab == 3 and "Open" or tab == 2 and "Install" or "Update"
  ui.footer({ { "Enter", enter }, { "C", "Check" }, { "Tab", "Tabs" }, { "Esc", query ~= "" and "Clear" or "Home" } })
end

function app.key(k)
  local d = ui.nav(k)
  local c = not k.ctrl and not k.fn and k.text and k.text:lower()
  if k.key == "tab" then
    tab, sel, top, query, marked = tab % 3 + 1, 1, 1, "", {}
    build()
  elseif d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(math.max(1, #rows), sel + 1)
  elseif k.key == "esc" and query ~= "" then query = ""; build()
  elseif k.key == "backspace" and query ~= "" then query = query:sub(1, -2); build()
  elseif c == " " or k.key == "space" then
    local it = items[sel]
    local key = it == "firmware" and "firmware" or (it and it.name)
    if key and tab ~= 3 then marked[key] = not marked[key] or nil; build() end
  elseif k.key == "enter" then
    local it = items[sel]
    if tab == 3 then
      if type(it) == "table" then shell.launch(it.name) end
    elseif it then
      local ops = chosen("install")
      local fw = false
      for _, o in ipairs(ops) do fw = fw or o == "firmware" end
      if fw then
        shell.confirm("Firmware", "Install build " .. cat.firmware.build .. "? The Cardputer restarts.", function(yes)
          if yes then apply(ops) end
        end)
      else
        apply(ops)
      end
    end
  elseif tab == 2 and c and c:match("^[%w]$") and c ~= "c" or (tab == 2 and query ~= "" and c and c:match("^[%w ]$")) then
    query = query .. c
    sel, top = 1, 1
    build()
  elseif c == "c" then
    note = "Checking..."
    appstore.run("check")
  elseif tab == 3 and c == "x" then
    local it = items[sel]
    if type(it) == "table" and not it.core then
      shell.confirm("Uninstall", "Remove " .. it.title .. "?", function(yes)
        if yes then apply({ "remove:" .. it.name }) end
      end)
    elseif type(it) == "table" then
      shell.toast("System apps stay installed", 2)
    end
  else
    return false
  end
  return true
end

return app
