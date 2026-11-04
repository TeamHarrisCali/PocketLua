-- A tiny example app. Press Esc, then E on this app's icon to edit it, change
-- something, press Ctrl+S then Ctrl+R: the change is running immediately.
local app = { title = "Hello", icon = "chip", color = "pink", order = 50, category = "tools" }
app.help = {
  { "Any", "Beep, count presses" },
  { "Esc", "Home" },
}

local col = ui.col
local x, y, vx, vy = 40, 40, 60, 45
local presses = 0

function app.update(dt)
  x, y = x + vx * dt, y + vy * dt
  if x < 4 or x > 232 then vx = -vx end
  if y < 18 or y > 112 then vy = -vy end
end

function app.draw()
  ui.center(48, "Hello, PocketLua!", col.text, 2)
  ui.center(72, "keys pressed: " .. presses, col.dim, 1)
  gfx.disc(x, y, 5, col.accent)
end

function app.key(k)
  presses = presses + 1
  if k.text then snd.tone(400 + (k.text:byte() % 24) * 40, 60) end
  return false
end

return app
