-- Notification center (Fn+N): everything shell.notify() posted, newest first.
local col = ui.col
local ov = {}
local sel, top = 1, 1
shell.mark_read()

function ov.draw()
  gfx.fill(0, ui.BAR, ui.W, ui.H - ui.BAR, col.bg)
  ui.title(6, 17, "NOTIFICATIONS")
  local notes = shell.notes
  if #notes == 0 then
    ui.center(64, "Nothing new", col.muted)
  else
    local rows = {}
    for i, n in ipairs(notes) do rows[i] = { label = n.title, value = n.time } end
    sel = math.max(1, math.min(sel, #rows))
    top = ui.list(rows, sel, top, 4, 28, 230, 16, 6)
  end
  ui.footer({ { "Enter", "Read" }, { "C", "Clear all" }, { "Esc", "Close" } })
end

function ov.key(k)
  local d = ui.nav(k)
  local notes = shell.notes
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(#notes, sel + 1)
  elseif k.key == "enter" and notes[sel] then
    local n = notes[sel]
    shell.alert(n.title, n.body ~= "" and n.body or "(no details)")
  elseif k.text == "c" then
    for i = #notes, 1, -1 do notes[i] = nil end
  elseif k.key == "esc" then shell.close_overlay() end
end

return ov
