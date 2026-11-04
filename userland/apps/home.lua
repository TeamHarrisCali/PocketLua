-- Home screen: apps grouped by category, with type-to-search. It is an ordinary
-- (hidden) app, so it is only in memory while it is on screen.
--   Tab / Shift+Tab  next / previous category    letters  search
--   arrows           move                         Enter    open
--   Ctrl+E           edit the app's source        Ctrl+N   new app
local col = ui.col

local app = { title = "LiveOS", icon = "app", hidden = true }

local CATS = { "all", "system", "tools", "media", "games", "net" }
local LABELS = { "All", "Sys", "Tools", "Media", "Games", "Net" }
local COLS, ROWS = 4, 2
local PER = COLS * ROWS
local CELL_W, CELL_H, GY = 60, 44, 34

local all = {}       -- every app's metadata
local shown = {}     -- what the grid shows now
local cat, sel, query = 1, 1, ""

local TEMPLATE = [[
-- %s: edit me, then press Ctrl+S to save and Ctrl+R to run.
local app = { title = "%s", icon = "app", category = "tools" }

local t = 0

function app.update(dt)
  t = t + dt
end

function app.draw()
  ui.center(52, "Hello from %s", ui.col.text, 1)
  ui.big(68, string.format("%%.1f s", t), ui.col.accent, 2)
  ui.footer({ { "Esc", "Home" } })
end

function app.key(k)
  -- return true when the key is handled; Esc goes home by itself
end

return app
]]

local function resolve_color(c, name)
  if type(c) == "string" then c = ui.accents[c] end
  if type(c) == "number" then return c end
  local h = 0
  for i = 1, #name do h = (h * 31 + name:byte(i)) % 7 end
  return ui.accents[ui.accent_names[h + 1]]
end

-- Titles, icons and categories come from each app's `local app = { ... }`
-- line, read as text: running every app to draw the grid would need all of
-- them in memory at once.
local function read_meta(name)
  local head = sys.read_text("apps/" .. name .. ".lua", 1024)
  local t = head and head:match("local%s+app%s*=%s*(%b{})")
  local meta = { name = name, title = name, icon = "app", order = 100, category = "tools" }
  if t then
    meta.title = t:match('title%s*=%s*"([^"]*)"') or name
    meta.icon = t:match('icon%s*=%s*"([%w_]+)"') or "app"
    meta.color = t:match('color%s*=%s*"([%w_]+)"')
    meta.order = tonumber(t:match("order%s*=%s*(%d+)")) or 100
    meta.category = t:match('category%s*=%s*"(%w+)"') or "tools"
    meta.hidden = t:match("hidden%s*=%s*true") ~= nil
  end
  meta.color = resolve_color(meta.color, name)
  return meta
end

local function filter()
  shown = {}
  local q = query:lower()
  for _, a in ipairs(all) do
    local hit
    if q ~= "" then hit = a.title:lower():find(q, 1, true) ~= nil
    else hit = CATS[cat] == "all" or a.category == CATS[cat] end
    if hit then shown[#shown + 1] = a end
  end
  if q == "" and (CATS[cat] == "all" or CATS[cat] == "tools") then
    shown[#shown + 1] = { new = true, title = "New app", icon = "plus", color = col.surface2 }
  end
  sel = math.max(1, math.min(sel, #shown))
end

local function scan()
  all = {}
  for _, e in ipairs(sys.list("apps")) do
    local name = e.name:match("^(.+)%.lua$")
    if name then
      local meta = read_meta(name)
      if not meta.hidden then all[#all + 1] = meta end
    end
  end
  table.sort(all, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.title:lower() < b.title:lower()
  end)
end

function app.init(args, saved)
  if saved then cat, sel = saved.cat or 1, saved.sel or 1 end
  query = ""
  scan()
  filter()
end

function app.save()
  return { cat = cat, sel = sel }
end

local function new_app()
  shell.prompt("New app name", "", function(name)
    if not name then return end
    name = name:lower():gsub("[^%w_]", "")
    if name == "" then return end
    local path = "apps/" .. name .. ".lua"
    if sys.exists(path) then shell.toast("Already exists: " .. name); return end
    if not sys.write_text(path, string.format(TEMPLATE, name, name, name)) then
      shell.toast("Could not write file")
      return
    end
    shell.edit(path)
  end)
end

function app.draw()
  if query ~= "" then
    gfx.rfill(4, 16, 232, 13, 4, col.surface)
    gfx.text(9, 19, "Search:", col.muted)
    gfx.text(57, 19, query .. ((sys.millis() // 500) % 2 == 0 and "_" or ""), col.text)
  else
    ui.tabs(LABELS, cat, 16)
  end

  local page = (sel - 1) // PER
  local first = page * PER
  for i = 1, PER do
    local a = shown[first + i]
    if not a then break end
    local c, r = (i - 1) % COLS, (i - 1) // COLS
    local cx, cy = c * CELL_W, GY + r * CELL_H
    local on = (first + i) == sel
    if on then ui.card(cx + 3, cy - 2, CELL_W - 6, CELL_H - 1, true) end
    ui.tile(cx + 15, cy + 1, 30, a.icon, a.color)
    local label = ui.fit(a.title, CELL_W - 6)
    ui.text(cx + math.floor((CELL_W - #label * 6) / 2), cy + 33, label, on and col.text or col.muted)
  end
  if #shown == 0 then ui.center(70, "No apps match", col.muted) end

  ui.footer(query ~= "" and { { "Enter", "Open" }, { "Esc", "Clear" } }
    or { { "Tab", "Group" }, { "abc", "Search" }, { "Enter", "Open" }, { "^E", "Edit" } })
  local pages = (#shown - 1) // PER + 1
  if pages > 1 then ui.right(236, 126, (page + 1) .. "/" .. pages, col.muted) end
end

function app.key(k)
  local d = ui.nav(k)
  if k.ctrl and k.text then
    local c = k.text:lower()
    if c == "e" and shown[sel] and not shown[sel].new then shell.edit("apps/" .. shown[sel].name .. ".lua")
    elseif c == "n" then new_app()
    else return false end
    return true
  end
  if k.key == "tab" and query == "" then
    cat = (k.shift and (cat - 2) % #CATS or cat % #CATS) + 1
    sel = 1
    filter()
  elseif k.key == "backspace" and query ~= "" then
    query = query:sub(1, -2); sel = 1; filter()
  elseif k.key == "esc" and query ~= "" then
    query = ""; sel = 1; filter()
  elseif k.key == "enter" then
    local a = shown[sel]
    if not a then return true end
    if a.new then new_app() else shell.launch(a.name) end
  elseif k.key == "left" or (d == "left" and query == "") then sel = math.max(1, sel - 1)
  elseif k.key == "right" or (d == "right" and query == "") then sel = math.min(#shown, sel + 1)
  elseif k.key == "up" or (d == "up" and query == "") then sel = math.max(1, sel - COLS)
  elseif k.key == "down" or (d == "down" and query == "") then sel = math.min(#shown, sel + COLS)
  elseif k.text and k.text:match("^[%w ]$") and not k.fn then
    query = query .. k.text; sel = 1; filter()
  else
    return k.key == "esc"  -- Esc on home does nothing
  end
  return true
end

return app
