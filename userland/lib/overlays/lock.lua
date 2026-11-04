-- Lock screen: shown when the display wakes. Big clock, date, battery and the
-- latest notification. Any key unlocks.
local col = ui.col
local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local ov = {}
local t = clock.now()

function ov.update()
  t = clock.now()
end

function ov.draw()
  gfx.fill(0, ui.BAR, ui.W, ui.H - ui.BAR, col.bg)
  if t.valid then
    local s = shell.format_time(t)
    local hm, ampm = s:match("^(%S+)%s*(%a*)$")
    ui.big(34, hm, col.text, 4)
    if ampm ~= "" then ui.center(70, ampm, col.muted) end
    ui.center(82, string.format("%s, %s %d", DAYS[t.wday + 1], MONTHS[t.month], t.day), col.muted)
  else
    ui.big(40, "LiveOS", col.accent, 3)
    ui.center(72, "Clock not set", col.muted)
  end
  local n = shell.notes[1]
  if n and (ui.status.unread or 0) > 0 then
    ui.card(20, 96, 200, 16, false)
    ui.text(26, 100, ui.fit(n.title, 150), col.text)
    ui.right(214, 100, ui.status.unread .. " new", col.accent)
  end
  ui.footer({ { "any key", "Unlock" } })
end

function ov.key()
  shell.close_overlay()
end

return ov
