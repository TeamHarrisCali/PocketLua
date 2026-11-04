-- Notes: text notes in data/notes (opened in the editor) and a to-do list in
-- data/todo.txt, one item per line as "[ ] text" or "[x] text".
local col = ui.col
local app = { title = "Notes", icon = "note", color = "blue", order = 21, category = "tools" }

local TABS = { "Notes", "To-do" }
local DIR = "data/notes"
local TODO = "data/todo.txt"
local MAX_ITEMS = 100

local tab = 1
local notes, nrows, nsel, ntop = {}, {}, 1, 1   -- notes: file names
local items, trows, tsel, ttop = {}, {}, 1, 1   -- to-do: { {done=, text=} }

local function size_text(n)
  if n < 1024 then return n .. "B" end
  return string.format("%.1fK", n / 1024)
end

-- ---------------------------------------------------------------- notes
local function load_notes()
  notes, nrows = {}, {}
  local ok, list = pcall(sys.list, DIR)
  for _, e in ipairs(ok and list or {}) do
    if not e.dir and e.name:lower():match("%.txt$") then notes[#notes + 1] = e end
  end
  table.sort(notes, function(a, b) return a.name:lower() < b.name:lower() end)
  for i, e in ipairs(notes) do
    nrows[i] = { label = e.name:sub(1, -5), value = size_text(e.size or 0) }
  end
  nsel = math.max(1, math.min(nsel, #nrows))
end

local function new_note()
  shell.prompt("New note title", "", function(title)
    if not title then return end
    local name = title:gsub("[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 28)
    if name == "" then shell.toast("Type a title with letters or digits"); return end
    local path = DIR .. "/" .. name .. ".txt"
    if not sys.exists(path) then
      sys.mkdirs(DIR)
      if not sys.write_text(path, "") then shell.toast("Could not create the note"); return end
    end
    shell.edit(path)
  end)
end

local function open_note()
  local e = notes[nsel]
  if e then shell.edit(DIR .. "/" .. e.name) end
end

local function delete_note()
  local e = notes[nsel]
  if not e then return end
  shell.confirm("Delete note", "Delete \"" .. e.name:sub(1, -5) .. "\"?", function(yes)
    if not yes then return end
    if sys.remove(DIR .. "/" .. e.name) then shell.toast("Note deleted") else shell.toast("Could not delete") end
    load_notes()
  end)
end

-- ---------------------------------------------------------------- to-do
local function build_todo()
  trows = {}
  for i, it in ipairs(items) do
    trows[i] = { label = it.text, badge = it.done and "x" or " ", badge_color = it.done and col.good or col.surface2,
      dim = it.done }
  end
  tsel = math.max(1, math.min(tsel, #trows))
end

local function load_todo()
  items = {}
  for line in (sys.read_text(TODO) or ""):gmatch("[^\n]+") do
    local l = line:gsub("\r$", "")
    local mark, text = l:match("^%[([ xX])%]%s?(.*)$")
    if not mark then mark, text = " ", l end
    if text:match("%S") and #items < MAX_ITEMS then items[#items + 1] = { done = mark ~= " ", text = text } end
  end
  build_todo()
end

local function save_todo()
  local out = {}
  for i, it in ipairs(items) do out[i] = (it.done and "[x] " or "[ ] ") .. it.text .. "\n" end
  sys.mkdirs("data")
  if not sys.write_text(TODO, table.concat(out)) then shell.toast("Could not save the to-do list") end
  build_todo()
end

local function add_item()
  if #items >= MAX_ITEMS then shell.toast("The list is full (" .. MAX_ITEMS .. " items)"); return end
  shell.prompt("New to-do", "", function(text)
    if not text then return end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    items[#items + 1] = { done = false, text = text }
    tsel = #items
    save_todo()
    shell.toast("Added")
  end)
end

local function toggle_item()
  local it = items[tsel]
  if not it then return end
  it.done = not it.done
  save_todo()
end

local function delete_item()
  if not items[tsel] then return end
  table.remove(items, tsel)
  save_todo()
  shell.toast("Item deleted")
end

local function clear_done()
  local n = 0
  for _, it in ipairs(items) do if it.done then n = n + 1 end end
  if n == 0 then shell.toast("Nothing is done yet"); return end
  shell.confirm("Clear done", "Remove " .. n .. (n == 1 and " finished item?" or " finished items?"), function(yes)
    if not yes then return end
    for i = #items, 1, -1 do if items[i].done then table.remove(items, i) end end
    save_todo()
    shell.toast("Cleared " .. n)
  end)
end

-- ---------------------------------------------------------------- lifecycle
function app.init(args, saved)
  tab = saved and saved.tab or 1
  nsel = saved and saved.nsel or 1
  tsel = saved and saved.tsel or 1
  load_notes()
  load_todo()
end

function app.save()
  return { tab = tab, nsel = nsel, tsel = tsel }
end

function app.close()
  notes, nrows, items, trows = {}, {}, {}, {}
end

function app.draw()
  ui.tabs(TABS, tab, 16)
  if tab == 1 then
    if #nrows == 0 then
      ui.empty("note", "No notes yet", "Press N to write one")
    else
      ntop = ui.list(nrows, nsel, ntop, 4, 34, 230, 15, 6)
    end
    ui.footer({ { "Enter", "Open" }, { "N", "New" }, { "X", "Delete" }, { "Tab", "To-do" } })
  else
    if #trows == 0 then
      ui.empty("note", "Nothing to do", "Press A to add an item")
    else
      ttop = ui.list(trows, tsel, ttop, 4, 34, 230, 15, 6)
    end
    ui.footer({ { "A", "Add" }, { "Enter", "Done" }, { "X", "Del" }, { "C", "Clear done" } })
  end
end

function app.key(k)
  if k.key == "tab" then
    tab = tab % #TABS + 1
    if tab == 1 then load_notes() else load_todo() end
    return true
  end
  if k.key == "esc" then return false end
  local d = ui.nav(k)
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if tab == 1 then
    if d == "up" then nsel = math.max(1, nsel - 1)
    elseif d == "down" then nsel = math.min(#nrows, nsel + 1)
    elseif k.key == "enter" then if #notes == 0 then new_note() else open_note() end
    elseif c == "n" then new_note()
    elseif c == "x" then delete_note()
    else return false end
  else
    if d == "up" then tsel = math.max(1, tsel - 1)
    elseif d == "down" then tsel = math.min(#trows, tsel + 1)
    elseif k.key == "enter" or k.key == "space" or c == " " then
      if #items == 0 then add_item() else toggle_item() end
    elseif c == "a" then add_item()
    elseif c == "x" then delete_item()
    elseif c == "c" then clear_done()
    else return false end
  end
  return true
end

return app
