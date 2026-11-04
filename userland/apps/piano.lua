-- A little piano. Home row plays white keys, the row above plays sharps.
-- , and . change octave.
local col = ui.col

local app = { title = "Piano", icon = "piano", color = "purple", order = 30, category = "media" }

-- key -> semitones above C
local WHITE = { a = 0, s = 2, d = 4, f = 5, g = 7, h = 9, j = 11, k = 12, l = 14, [";"] = 16 }
local BLACK = { w = 1, e = 3, t = 6, y = 8, u = 10, o = 13, p = 15 }
local order = { "a", "s", "d", "f", "g", "h", "j", "k", "l", ";" }
local black_after = { a = "w", s = "e", f = "t", g = "y", h = "u", k = "o", l = "p" }

local octave = 0
local lit, lit_t = nil, 0

local function play(key, semis)
  local f = 261.63 * 2 ^ ((semis + octave * 12) / 12)
  snd.tone(f, 250)
  lit, lit_t = key, 0.25
end

function app.update(dt)
  if lit then
    lit_t = lit_t - dt
    if lit_t <= 0 then lit = nil end
  end
end

function app.draw()
  local w, top, h = 22, 40, 70
  for i, key in ipairs(order) do
    local x = (i - 1) * w + 6
    gfx.rfill(x, top, w - 2, h, 3, lit == key and col.accent or col.text)
    ui.text(x + 8, top + h - 12, key, col.bg)
  end
  for i, key in ipairs(order) do
    local b = black_after[key]
    if b then
      local x = (i - 1) * w + 6 + w - 7
      gfx.rfill(x, top, 14, 40, 2, lit == b and col.accent or col.bg)
      gfx.rect(x, top, 14, 40, col.panel2)
    end
  end
  ui.text(6, 20, "Octave " .. (octave >= 0 and "+" or "") .. octave, col.dim)
  ui.footer({ { ",/.", "Octave" }, { "Esc", "Home" } })
end

function app.key(k)
  local t = k.text
  if not t or k.ctrl then return false end
  if WHITE[t] then play(t, WHITE[t])
  elseif BLACK[t] then play(t, BLACK[t])
  elseif t == "," then octave = math.max(-2, octave - 1)
  elseif t == "." then octave = math.min(2, octave + 1)
  else return false end
  return true
end

return app
