-- Sound Lab: the microphone as a level meter, a spectrum and a tuner.
-- audio.analyze() listens for ~32 ms, so it runs at most once per update().
local col = ui.col

local app = { title = "Sound Lab", icon = "wave", color = "teal", order = 42, category = "media" }
app.help = {
  { "Tab", "Next mode" },
  { "<>", "Prev / next mode" },
  { "Space", "Pause / resume" },
  { "Esc", "Home" },
}

local TABS = { "Level", "Spectrum", "Tuner" }
local NOTES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local FLOOR_DB = -60

local tab = 1
local paused, failed = false, false
local level, sm, db = 0, 0, FLOOR_DB
local hold, hold_t = 0, 0
local bands, caps = { 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0, 0 }
local scale = 0.05
-- tuner
local note, octave, cents, freq, fresh = nil, 0, 0, 0, false
local needle, note_age = 0, 99
local db_text, freq_text, cents_text = "", "", ""

local function to_db(v)
  if not v or v <= 0.00001 then return -100 end
  return 20 * math.log(v, 10)
end

local function db_frac(d) return math.max(0, math.min(1, (d - FLOOR_DB) / -FLOOR_DB)) end

local function analyze(dt)
  local ok, l, pk, pitch, b = pcall(audio.analyze)
  if not ok or not l then failed = true; return end
  failed = false
  level = l
  -- level: fast attack, slow release; the peak marker holds for 1.5 s
  local k = l > sm and 0.6 or math.min(1, dt * 4)
  sm = sm + (l - sm) * k
  db = to_db(sm)
  db_text = db <= FLOOR_DB and "-inf dBFS" or string.format("%d dBFS", math.floor(db + 0.5))
  pk = pk or l
  if pk >= hold then hold, hold_t = pk, 1.5
  else
    hold_t = hold_t - dt
    if hold_t <= 0 then hold = math.max(0, hold - dt * 0.5) end
  end
  -- spectrum: smoothed bars, falling caps, slowly adapting scale
  if type(b) == "table" then
    local mx = 0
    for i = 1, 8 do
      local v = b[i] or 0
      if v > mx then mx = v end
      bands[i] = v > bands[i] and v or bands[i] + (v - bands[i]) * math.min(1, dt * 6)
    end
    scale = math.max(0.05, mx, scale - dt * scale * 0.3)
    for i = 1, 8 do
      local f = math.min(1, bands[i] / scale)
      caps[i] = f > caps[i] and f or math.max(0, caps[i] - dt * 0.6)
    end
  end
  -- tuner: nearest equal-tempered note, A4 = 440 Hz
  note_age = note_age + dt
  if pitch and pitch > 25 and pitch < 5000 and l > 0.01 then
    local m = 69 + 12 * math.log(pitch / 440, 2)
    local nearest = math.floor(m + 0.5)
    note = NOTES[nearest % 12 + 1]
    octave = nearest // 12 - 1
    cents = (m - nearest) * 100
    freq, fresh, note_age = pitch, true, 0
    needle = needle + (cents - needle) * 0.5
    freq_text = string.format("%.1f Hz", freq)
    local c = math.floor(cents + 0.5)
    cents_text = (c > 0 and "+" or "") .. c .. " cents"
  else
    fresh = note_age < 1
  end
end

function app.init(args, saved)
  tab = saved and saved.tab or 1
  paused, failed = false, false
  sm, hold, hold_t, note, note_age, needle = 0, 0, 0, nil, 99, 0
end

function app.update(dt)
  if not paused then analyze(dt) end
end

local function draw_level(y)
  ui.big(y + 8, db_text, db > -6 and col.bad or db > -18 and col.warn or col.text, 3)
  local bx, by, bw = 10, y + 44, 220
  ui.bar(bx, by, bw, 12, db_frac(db), db > -6 and col.bad or db > -18 and col.warn or col.accent)
  local hx = bx + math.floor(bw * db_frac(to_db(hold)))
  gfx.fill(math.min(bx + bw - 2, hx), by - 2, 2, 16, col.text)
  for _, t in ipairs({ -60, -40, -20, -6, 0 }) do
    local x = bx + math.floor(bw * db_frac(t))
    gfx.fill(x, by + 15, 1, 3, col.line)
  end
  ui.text(bx, by + 20, "-60", col.muted)
  ui.right(bx + bw, by + 20, "0 dB", col.muted)
  ui.center(by + 20, string.format("peak %.0f", math.max(FLOOR_DB, to_db(hold))), col.muted)
end

local function draw_spectrum(y)
  local x0, bw, gap, h = 12, 24, 4, 70
  local base_y = y + h + 2
  for i = 1, 8 do
    local x = x0 + (i - 1) * (bw + gap)
    local f = math.min(1, bands[i] / scale)
    gfx.fill(x, y + 2, bw, h, col.surface)
    local bh = math.floor(h * f)
    if bh > 0 then gfx.fill(x, base_y - bh, bw, bh, col.accent) end
    local cy = base_y - math.floor(h * caps[i]) - 2
    gfx.fill(x, math.max(y + 2, cy), bw, 2, col.text)
  end
  ui.text(x0, base_y + 4, "100 Hz", col.muted)
  ui.right(x0 + 8 * (bw + gap) - gap, base_y + 4, "4 kHz", col.muted)
end

local function draw_tuner(y)
  if not note then
    ui.empty("wave", "Play or sing a note", "A4 = 440 Hz")
    return
  end
  local good = math.abs(cents) < 5
  local nc = not fresh and col.muted or good and col.good or col.text
  local w = #note * 24 + 12
  local x = math.floor((ui.W - w) / 2)
  ui.text(x, y + 2, note, nc, 4)
  ui.text(x + #note * 24, y + 18, tostring(octave), nc, 2)
  -- cents scale: -50 .. +50
  local sx, sw, sy = 20, 200, y + 46
  gfx.fill(sx, sy, sw, 2, col.line)
  for c = -50, 50, 25 do
    local tx = sx + math.floor((c + 50) * sw / 100)
    gfx.fill(tx, sy - (c == 0 and 6 or 3), 1, c == 0 and 14 or 8, c == 0 and col.text or col.line)
  end
  local nx = sx + math.floor((math.max(-50, math.min(50, needle)) + 50) * sw / 100)
  gfx.tri(nx - 4, sy - 9, nx + 4, sy - 9, nx, sy - 2, fresh and (good and col.good or col.accent) or col.muted)
  gfx.fill(nx - 1, sy - 2, 3, 8, fresh and (good and col.good or col.accent) or col.muted)
  ui.text(sx, sy + 12, "flat", col.muted)
  ui.right(sx + sw, sy + 12, "sharp", col.muted)
  ui.text(sx, sy + 24, cents_text, col.text)
  ui.right(sx + sw, sy + 24, freq_text, col.text)
end

function app.draw()
  local y = ui.tabs(TABS, tab, 16)
  if failed then
    ui.empty("mic", "Microphone not available", "Stop playback or recording first")
  elseif tab == 1 then draw_level(y)
  elseif tab == 2 then draw_spectrum(y)
  else draw_tuner(y) end
  ui.footer({ { "Tab", "Mode" }, { "Space", paused and "Resume" or "Pause" }, { "Esc", "Home" } })
end

function app.key(k)
  local d = ui.nav(k)
  if k.key == "tab" then
    tab = k.shift and (tab - 2) % #TABS + 1 or tab % #TABS + 1
  elseif d == "right" then tab = math.min(#TABS, tab + 1)
  elseif d == "left" then tab = math.max(1, tab - 1)
  elseif k.key == "space" or k.text == " " then paused = not paused
  else return false end
  return true
end

function app.save() return { tab = tab } end

function app.close()
  audio.stop()
end

return app
