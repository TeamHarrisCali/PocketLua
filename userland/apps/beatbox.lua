-- Beat Box: a 16-step drum machine. Arrows move, Space toggles a step, P plays.
-- The speaker plays one tone at a time, so on a busy step the highest-priority
-- sound wins: kick > snare > bass > hat.
local col = ui.col

local app = { title = "Beat Box", icon = "drum", color = "orange", order = 43, category = "media" }
app.help = {
  { "Arrows", "Move cursor" },
  { "Space", "Toggle step" },
  { "P", "Play / stop" },
  { "-=", "Tempo" },
  { "[ ]", "Bass pitch" },
  { "S", "Save" },
  { "C", "Clear pattern" },
}

local FILE = "data/beatbox.txt"
local NAMES = { "Kick", "Snare", "Hat", "Bass" }
local CODE = { "K", "S", "H", "B" }
local PRIORITY = { 1, 2, 4, 3 }   -- rows in the order they win a step
local NOTE = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local STEPS = 16

local pat = { 0, 0, 0, 0 }       -- one 16-bit mask per row; bit s-1 = step s
local bpm, bass = 120, 0         -- bass: semitones above A1 (55 Hz), 0..24
local cr, cs = 1, 1              -- cursor row, step
local playing, step, acc = false, 0, 0
local dirty = false
local bass_label = ""

local function on(r, s) return (pat[r] >> (s - 1)) & 1 == 1 end

local function bass_hz() return 55 * 2 ^ (bass / 12) end

local function relabel()
  local n = bass + 9   -- A is 9 semitones above C
  bass_label = NOTE[n % 12 + 1] .. (n // 12 + 1)
end

local function sound(r)
  if r == 1 then snd.tone(60, 60)
  elseif r == 2 then snd.tone(200, 40)
  elseif r == 3 then snd.tone(6000, 15)
  else snd.tone(math.floor(bass_hz() + 0.5), 90) end
end

local function trigger(s)
  for _, r in ipairs(PRIORITY) do
    if on(r, s) then sound(r); return end
  end
end

local function serialize()
  local out = { "bpm=" .. bpm, "bass=" .. bass }
  for r = 1, 4 do
    local cells = {}
    for s = 1, STEPS do cells[s] = on(r, s) and "x" or "." end
    out[#out + 1] = CODE[r] .. "=" .. table.concat(cells)
  end
  return table.concat(out, "\n") .. "\n"
end

local function load_pattern()
  local txt = sys.read_text(FILE, 1024)
  if not txt then
    -- a starter beat
    pat = { 0x0581, 0x1010, 0x5555, 0x4400 }
    return false
  end
  pat = { 0, 0, 0, 0 }
  bpm = math.max(60, math.min(200, tonumber(txt:match("bpm=(%d+)")) or 120))
  bass = math.max(0, math.min(24, tonumber(txt:match("bass=(%d+)")) or 0))
  for r = 1, 4 do
    local cells = txt:match(CODE[r] .. "=([x%.]+)")
    if cells then
      for s = 1, math.min(STEPS, #cells) do
        if cells:sub(s, s) == "x" then pat[r] = pat[r] | (1 << (s - 1)) end
      end
    end
  end
  return true
end

local function save()
  if sys.write_text(FILE, serialize()) then
    dirty = false
    shell.toast("Pattern saved")
  else
    shell.toast("Could not save the pattern", 3)
  end
end

local function step_len() return 15 / bpm end  -- seconds per 16th note

function app.init()
  cr, cs, playing, step, acc, dirty = 1, 1, false, 0, 0, false
  load_pattern()
  relabel()
end

function app.update(dt)
  if not playing then return end
  acc = acc + dt
  local len = step_len()
  if acc >= len then
    acc = acc - len
    if acc > len then acc = 0 end  -- a long frame: drop the missed steps
    step = step % STEPS + 1
    trigger(step)
  end
end

function app.draw()
  ui.text(4, 19, bpm .. " BPM", col.text)
  ui.text(64, 19, playing and "Playing" or "Stopped", playing and col.accent or col.muted)
  ui.right(236, 19, "Bass " .. bass_label .. (dirty and " *" or ""), col.muted)
  local x0, cw, y0, rh = 40, 12, 30, 20
  if playing and step > 0 then gfx.fill(x0 + (step - 1) * cw, y0 - 2, cw, 4 * rh + 1, col.surface2) end
  for r = 1, 4 do
    local y = y0 + (r - 1) * rh
    ui.text(4, y + 5, NAMES[r], r == cr and col.text or col.muted)
    for s = 1, STEPS do
      local x = x0 + (s - 1) * cw
      local hit = on(r, s)
      local c
      if hit then c = (playing and s == step) and col.text or col.accent
      else c = (s - 1) % 4 == 0 and col.line or col.surface end
      gfx.rfill(x + 1, y + 1, cw - 2, rh - 4, 2, c)
      if r == cr and s == cs then gfx.rrect(x, y, cw, rh - 2, 3, col.text) end
    end
  end
  for b = 0, 3 do ui.text(x0 + b * 4 * cw + 3, y0 + 4 * rh + 1, tostring(b + 1), col.muted) end
  ui.footer({ { "Space", "Toggle" }, { "P", playing and "Pause" or "Play" }, { "-=", "Tempo" }, { "S", "Save" } })
end

function app.key(k)
  local d = ui.nav(k)
  local t = k.text
  if d == "up" then cr = (cr - 2) % 4 + 1
  elseif d == "down" then cr = cr % 4 + 1
  elseif d == "left" then cs = (cs - 2) % STEPS + 1
  elseif d == "right" then cs = cs % STEPS + 1
  elseif k.key == "space" or k.key == "enter" or t == " " then
    pat[cr] = pat[cr] ~ (1 << (cs - 1))
    dirty = true
    if on(cr, cs) then sound(cr) end
  elseif t == "p" then
    playing = not playing
    if playing then step, acc = 0, step_len() else snd.stop() end
  elseif t == "=" or t == "+" then bpm = math.min(200, bpm + 5); dirty = true
  elseif t == "-" or t == "_" then bpm = math.max(60, bpm - 5); dirty = true
  elseif t == "]" then bass = math.min(24, bass + 1); relabel(); dirty = true; sound(4)
  elseif t == "[" then bass = math.max(0, bass - 1); relabel(); dirty = true; sound(4)
  elseif t == "s" then save()
  elseif t == "c" then
    shell.confirm("Clear", "Clear the whole pattern?", function(yes)
      if yes then pat = { 0, 0, 0, 0 }; dirty = true end
    end)
  else return false end
  return true
end

function app.close()
  snd.stop()
end

return app
