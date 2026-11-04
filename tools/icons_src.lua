-- App icons, drawn with primitives. Loaded the first time an icon is drawn
-- (home screen, error screens) and dropped again when an app opens, so apps
-- that never show icons do not pay for them.
-- Each draws centered at (x, y) in fg over a tile of colour bg.
local icons = {}  -- drawing source for tools/gen_icons.lua (not loaded on the device)


function icons.gear(x, y, fg, bg)
  gfx.disc(x, y, 8, fg)
  for i = 0, 7 do
    local a = i * math.pi / 4
    gfx.disc(x + math.floor(math.cos(a) * 9.5 + 0.5), y + math.floor(math.sin(a) * 9.5 + 0.5), 2, fg)
  end
  gfx.disc(x, y, 3, bg)
end

function icons.folder(x, y, fg, bg)
  gfx.fill(x - 11, y - 6, 22, 15, fg)
  gfx.fill(x - 11, y - 9, 10, 4, fg)
  gfx.line(x - 11, y - 3, x + 10, y - 3, bg)
end

function icons.term(x, y, fg, bg)
  gfx.rrect(x - 11, y - 8, 22, 17, 3, fg)
  gfx.line(x - 7, y - 4, x - 3, y, fg)
  gfx.line(x - 3, y, x - 7, y + 4, fg)
  gfx.fill(x, y + 3, 6, 2, fg)
end

function icons.pencil(x, y, fg, bg)
  for d = -1, 1 do gfx.line(x - 7 + d, y + 7, x + 8 + d, y - 8, fg) end
  gfx.line(x - 6, y + 8, x + 9, y - 7, fg)
  gfx.tri(x - 11, y + 11, x - 9, y + 4, x - 4, y + 9, fg)
end

function icons.level(x, y, fg, bg)
  gfx.rrect(x - 11, y - 5, 22, 11, 5, fg)
  gfx.disc(x, y, 3, fg)
  gfx.line(x - 5, y - 4, x - 5, y + 4, fg)
  gfx.line(x + 5, y - 4, x + 5, y + 4, fg)
end

function icons.piano(x, y, fg, bg)
  gfx.fill(x - 11, y - 9, 22, 18, fg)
  for i = -6, 6, 6 do gfx.line(x + i, y, x + i, y + 8, bg) end
  gfx.fill(x - 8, y - 9, 4, 10, bg)
  gfx.fill(x - 2, y - 9, 4, 10, bg)
  gfx.fill(x + 4, y - 9, 4, 10, bg)
end

function icons.wifi(x, y, fg, bg)
  for r = 4, 12, 4 do gfx.arc(x, y + 7, r, r + 2, 225, 315, fg) end
  gfx.disc(x, y + 7, 2, fg)
end

function icons.chip(x, y, fg, bg)
  gfx.fill(x - 6, y - 6, 12, 12, fg)
  for i = -4, 4, 4 do
    gfx.fill(x + i - 1, y - 10, 2, 4, fg)
    gfx.fill(x + i - 1, y + 7, 2, 4, fg)
    gfx.fill(x - 10, y + i - 1, 4, 2, fg)
    gfx.fill(x + 7, y + i - 1, 4, 2, fg)
  end
  gfx.fill(x - 2, y - 2, 4, 4, bg)
end

function icons.net(x, y, fg, bg)
  gfx.line(x - 8, y + 6, x, y - 7, fg)
  gfx.line(x + 8, y + 6, x, y - 7, fg)
  gfx.line(x - 8, y + 6, x + 8, y + 6, fg)
  gfx.disc(x, y - 7, 3, fg)
  gfx.disc(x - 8, y + 6, 3, fg)
  gfx.disc(x + 8, y + 6, 3, fg)
end

function icons.usb(x, y, fg, bg)
  gfx.line(x, y - 9, x, y + 6, fg)
  gfx.tri(x, y - 12, x - 3, y - 7, x + 3, y - 7, fg)
  gfx.disc(x, y + 8, 3, fg)
  gfx.line(x, y + 1, x - 6, y - 3, fg)
  gfx.fill(x - 8, y - 6, 4, 4, fg)
  gfx.line(x, y - 2, x + 6, y - 6, fg)
  gfx.disc(x + 7, y - 6, 2, fg)
end

function icons.app(x, y, fg, bg)
  gfx.rrect(x - 9, y - 9, 18, 18, 4, fg)
  gfx.disc(x, y, 3, fg)
end

function icons.plus(x, y, fg, bg)
  gfx.fill(x - 9, y - 2, 18, 4, fg)
  gfx.fill(x - 2, y - 9, 4, 18, fg)
end

function icons.warn(x, y, fg, bg)
  gfx.tri(x, y - 10, x - 11, y + 9, x + 11, y + 9, fg)
  gfx.fill(x - 1, y - 3, 3, 8, bg)
  gfx.fill(x - 1, y + 6, 3, 2, bg)
end

function icons.tasks(x, y, fg, bg)
  gfx.fill(x - 10, y + 2, 5, 8, fg)
  gfx.fill(x - 3, y - 4, 5, 14, fg)
  gfx.fill(x + 4, y - 9, 5, 19, fg)
end

function icons.clock(x, y, fg, bg)
  gfx.circle(x, y, 10, fg); gfx.circle(x, y, 9, fg)
  gfx.line(x, y, x, y - 6, fg); gfx.line(x, y, x + 5, y + 2, fg)
end

function icons.mic(x, y, fg, bg)
  gfx.rfill(x - 4, y - 10, 8, 13, 4, fg)
  gfx.arc(x, y - 1, 7, 8, 0, 180, fg)
  gfx.line(x, y + 7, x, y + 10, fg); gfx.line(x - 4, y + 10, x + 4, y + 10, fg)
end

function icons.music(x, y, fg, bg)
  gfx.disc(x - 5, y + 6, 4, fg); gfx.disc(x + 6, y + 4, 4, fg)
  gfx.fill(x - 2, y - 9, 2, 15, fg); gfx.fill(x + 9, y - 11, 2, 15, fg)
  gfx.tri(x - 2, y - 9, x + 11, y - 12, x + 11, y - 7, fg); gfx.tri(x - 2, y - 9, x - 2, y - 5, x + 11, y - 7, fg)
end

function icons.wave(x, y, fg, bg)
  local h = { 4, 9, 6, 11, 5, 8, 3 }
  for i, v in ipairs(h) do gfx.fill(x - 11 + (i - 1) * 3 + i, y - v, 2, v * 2, fg) end
end

function icons.drum(x, y, fg, bg)
  gfx.rfill(x - 9, y - 4, 18, 11, 3, fg); gfx.fill(x - 9, y - 6, 18, 3, fg)
  gfx.line(x - 6, y - 12, x - 1, y - 7, fg); gfx.line(x + 6, y - 12, x + 1, y - 7, fg)
end

function icons.morse(x, y, fg, bg)
  gfx.disc(x - 8, y, 2, fg); gfx.fill(x - 4, y - 1, 8, 3, fg); gfx.disc(x + 8, y, 2, fg)
  gfx.fill(x - 10, y + 6, 8, 3, fg); gfx.disc(x + 1, y + 7, 2, fg); gfx.fill(x + 5, y + 6, 6, 3, fg)
end

function icons.remote(x, y, fg, bg)
  gfx.rfill(x - 5, y - 10, 10, 21, 3, fg)
  gfx.disc(x, y - 6, 2, bg); gfx.fill(x - 2, y - 1, 4, 2, bg); gfx.fill(x - 2, y + 3, 4, 2, bg)
end

function icons.steps(x, y, fg, bg)
  gfx.disc(x - 4, y + 4, 4, fg); gfx.disc(x - 4, y - 3, 3, fg)
  gfx.disc(x + 5, y - 1, 4, fg); gfx.disc(x + 5, y - 8, 3, fg)
end

function icons.mouse(x, y, fg, bg)
  gfx.rfill(x - 7, y - 10, 14, 21, 7, fg); gfx.line(x, y - 10, x, y - 3, bg); gfx.line(x - 7, y - 3, x + 7, y - 3, bg)
end

function icons.ball(x, y, fg, bg)
  gfx.rrect(x - 11, y - 10, 22, 21, 3, fg)
  gfx.line(x - 4, y - 10, x - 4, y + 2, fg); gfx.line(x + 4, y - 2, x + 4, y + 10, fg)
  gfx.disc(x + 7, y - 6, 3, fg)
end

function icons.note(x, y, fg, bg)
  gfx.fill(x - 8, y - 10, 16, 21, fg)
  for i = -5, 5, 5 do gfx.line(x - 5, y + i, x + 5, y + i, bg) end
end

function icons.calc(x, y, fg, bg)
  gfx.rfill(x - 8, y - 10, 16, 21, 2, fg); gfx.fill(x - 5, y - 7, 10, 4, bg)
  for r = 0, 2 do for c = 0, 2 do gfx.fill(x - 5 + c * 4, y - 1 + r * 4, 2, 2, bg) end end
end

function icons.pad(x, y, fg, bg)
  gfx.rfill(x - 11, y - 6, 22, 13, 6, fg)
  gfx.fill(x - 8, y - 1, 6, 2, bg); gfx.fill(x - 6, y - 3, 2, 6, bg)
  gfx.disc(x + 5, y - 1, 1, bg); gfx.disc(x + 8, y + 2, 1, bg)
end

function icons.snake(x, y, fg, bg)
  gfx.fill(x - 10, y + 4, 14, 4, fg); gfx.fill(x, y - 6, 4, 14, fg); gfx.fill(x, y - 6, 10, 4, fg)
  gfx.disc(x - 9, y - 6, 2, fg)
end

function icons.blocks(x, y, fg, bg)
  gfx.fill(x - 9, y + 2, 6, 6, fg); gfx.fill(x - 2, y + 2, 6, 6, fg); gfx.fill(x + 5, y + 2, 6, 6, fg)
  gfx.fill(x - 2, y - 5, 6, 6, fg)
end

function icons.grid(x, y, fg, bg)
  for r = 0, 1 do for c = 0, 1 do gfx.rfill(x - 10 + c * 11, y - 10 + r * 11, 9, 9, 2, fg) end end
end

function icons.book(x, y, fg, bg)
  gfx.fill(x - 10, y - 8, 9, 17, fg); gfx.fill(x + 1, y - 8, 9, 17, fg); gfx.line(x, y - 8, x, y + 9, bg)
end

function icons.cloud(x, y, fg, bg)
  gfx.disc(x - 5, y + 2, 5, fg); gfx.disc(x + 2, y - 2, 7, fg); gfx.disc(x + 8, y + 3, 4, fg)
  gfx.fill(x - 5, y + 2, 13, 6, fg)
end

function icons.radar(x, y, fg, bg)
  gfx.circle(x, y, 10, fg); gfx.circle(x, y, 5, fg); gfx.line(x, y, x + 7, y - 7, fg); gfx.disc(x - 4, y + 4, 2, fg)
end

function icons.antenna(x, y, fg, bg)
  gfx.fill(x - 1, y - 6, 3, 17, fg); gfx.tri(x, y - 11, x - 4, y - 5, x + 4, y - 5, fg)
  gfx.arc(x, y - 6, 7, 8, 200, 340, fg)
end

function icons.pin(x, y, fg, bg)
  gfx.disc(x, y - 3, 7, fg); gfx.tri(x - 6, y, x + 6, y, x, y + 11, fg); gfx.disc(x, y - 3, 3, bg)
end

function icons.image(x, y, fg, bg)
  gfx.rrect(x - 11, y - 9, 22, 18, 2, fg)
  gfx.tri(x - 8, y + 6, x - 2, y - 2, x + 3, y + 6, fg); gfx.disc(x + 5, y - 4, 2, fg)
end

function icons.store(x, y, fg, bg)
  gfx.rfill(x - 9, y - 5, 18, 15, 2, fg); gfx.arc(x, y - 5, 4, 6, 180, 360, fg)
  gfx.tri(x, y + 7, x - 4, y + 2, x + 4, y + 2, bg); gfx.fill(x - 1, y - 2, 3, 5, bg)
end

return icons
