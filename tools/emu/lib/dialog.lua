-- Dialog boxes (alert, confirm, prompt, menu). The shell keeps only the small
-- state table of the open dialog; this code loads when a dialog is shown and is
-- dropped again on the next app switch.
local col = ui.col
local dialog = {}

-- Handles a key for dialog m. close() removes the dialog before its callback
-- runs, so a callback can open another one.
function dialog.key(m, k, close)
  if m.kind == "alert" then
    if k.key == "enter" or k.key == "esc" then close(); if m.cb then m.cb() end end
  elseif m.kind == "confirm" then
    if k.key == "enter" or k.text == "y" then close(); m.cb(true)
    elseif k.key == "esc" or k.text == "n" then close(); m.cb(false) end
  elseif m.kind == "prompt" then
    if k.key == "enter" then close(); m.cb(m.text)
    elseif k.key == "esc" then close(); m.cb(nil)
    elseif k.key == "backspace" then m.text = m.text:sub(1, -2)
    elseif k.ctrl and k.text == "v" then
      m.text = (m.text .. (shell.clipboard or ""):gsub("\n.*", "")):sub(1, 64)
    elseif k.ctrl and k.text == "c" then
      shell.clipboard = m.text
    elseif k.text and not k.ctrl and #m.text < 64 then m.text = m.text .. k.text end
  elseif m.kind == "menu" then
    local d = ui.nav(k)
    if d == "up" then m.sel = (m.sel - 2) % #m.items + 1
    elseif d == "down" then m.sel = m.sel % #m.items + 1
    elseif k.key == "enter" then close(); m.cb(m.sel)
    elseif k.key == "esc" then close(); m.cb(nil)
    elseif k.text and k.text:match("^[1-9]$") and tonumber(k.text) <= #m.items then close(); m.cb(tonumber(k.text)) end
  end
end

function dialog.draw(m)
  if m.kind == "alert" or m.kind == "confirm" then
    local lines = ui.wrap(m.msg, 180)
    if #lines > 6 then for i = #lines, 7, -1 do lines[i] = nil end end
    local h = 40 + #lines * 10
    local x, y = 20, math.floor((ui.H - h) / 2)
    ui.box(x, y, 200, h)
    ui.text(x + 8, y + 6, m.title, col.accent)
    for i, l in ipairs(lines) do ui.text(x + 8, y + 20 + (i - 1) * 10, l, col.text) end
    if m.kind == "confirm" then
      ui.text(x + 8, y + h - 14, "Y yes", col.good)
      ui.text(x + 70, y + h - 14, "N no", col.dim)
    else
      ui.text(x + 8, y + h - 14, "Enter ok", col.dim)
    end
  elseif m.kind == "prompt" then
    local x, y = 16, 36
    ui.box(x, y, 208, 62)
    ui.text(x + 8, y + 6, ui.fit(m.title, 190), col.accent)
    gfx.rfill(x + 8, y + 20, 192, 16, 3, col.bg)
    local shown = m.secret and string.rep("*", #m.text) or m.text
    if #shown > 30 then shown = shown:sub(-30) end
    ui.text(x + 12, y + 24, shown .. ((sys.millis() // 500) % 2 == 0 and "_" or ""), col.text)
    ui.text(x + 8, y + 44, "Enter ok   Esc cancel", col.dim)
  elseif m.kind == "menu" then
    local n = #m.items
    local rows = math.min(n, 6)
    local h = 26 + rows * 12
    local x, y = 30, math.floor((ui.H - h) / 2)
    ui.box(x, y, 180, h)
    ui.text(x + 8, y + 6, ui.fit(m.title, 164), col.accent)
    local top = math.max(1, math.min(m.sel - rows + 1, n - rows + 1))
    if m.sel < top then top = m.sel end
    for i = 0, rows - 1 do
      local idx = top + i
      if m.items[idx] then
        local ry = y + 20 + i * 12
        if idx == m.sel then gfx.rfill(x + 4, ry - 1, 172, 11, 3, col.accent) end
        ui.text(x + 8, ry, ui.fit(m.items[idx], 164), idx == m.sel and col.bg or col.text)
      end
    end
  end
end

return dialog
