-- Recorder: record WAV voice notes to the SD card (or internal storage) and
-- play them back. Enter records / stops, Space plays, X deletes.
local col = ui.col

local app = { title = "Recorder", icon = "mic", color = "red", order = 40, category = "media" }

local BYTES_PER_SEC = 32000  -- audio.record default: 16 kHz, 16-bit mono

local dir = "data/recordings"
local on_sd = false
local names, rows = {}, {}
local sel, top = 1, 1
local next_n = 1
local recording, rec_name, rec_t0, elapsed = false, nil, 0, 0
local playing, play_grace, done, total = nil, 0, 0, 0
local grace = 0
local blink = true

local function mmss(s)
  s = math.floor(s or 0)
  return string.format("%d:%02d", s // 60, s % 60)
end

local function path_of(name) return dir .. "/" .. name end

-- Reads the folder once; called on open and after every change.
local function scan(select_name)
  names, rows = {}, {}
  local sizes = {}
  next_n = 1
  for _, e in ipairs(sys.list(dir) or {}) do
    if not e.dir and e.name:lower():match("%.wav$") then
      names[#names + 1] = e.name
      sizes[e.name] = e.size or 0
      local n = tonumber(e.name:match("^rec_(%d+)%.wav$"))
      if n and n >= next_n then next_n = n + 1 end
    end
  end
  table.sort(names, function(a, b) return a > b end)  -- newest first
  for i, n in ipairs(names) do
    rows[i] = { label = n, value = mmss(math.max(0, sizes[n] - 44) / BYTES_PER_SEC) }
    if n == select_name then sel = i end
  end
  sel = math.max(1, math.min(sel, #names))
end

local function stop_playing()
  if playing then audio.stop() end
  playing = nil
end

local function start_recording()
  stop_playing()
  local name = string.format("rec_%03d.wav", next_n)
  local ok, why = audio.record(path_of(name))
  if not ok then
    shell.sound("error")
    shell.toast("Can't record: " .. tostring(why or "microphone busy"), 3)
    return
  end
  recording, rec_name, rec_t0, elapsed, grace = true, name, sys.millis(), 0, 1
end

local function stop_recording(msg)
  audio.stop()
  recording = false
  scan(rec_name)
  shell.toast(msg or ("Saved " .. tostring(rec_name)))
end

local function play_selected()
  local name = names[sel]
  if not name then shell.toast("Nothing to play"); return end
  local ok, why = audio.play(path_of(name))
  if not ok then
    shell.toast("Can't play: " .. tostring(why or "unknown error"), 3)
    return
  end
  playing, play_grace, done, total = name, 1, 0, 0
end

local function delete_selected()
  local name = names[sel]
  if not name then return end
  shell.confirm("Delete", "Delete " .. name .. "?", function(yes)
    if not yes then return end
    if playing == name then stop_playing() end
    if sys.remove(path_of(name)) then shell.toast("Deleted " .. name) else shell.toast("Could not delete " .. name) end
    scan()
  end)
end

function app.init()
  on_sd = sys.storage() == "SD"
  dir = "data/recordings"
  sys.mkdirs(dir)
  sel, top = 1, 1
  recording, playing = false, nil
  scan()
end

function app.update(dt)
  local st, d, t = audio.status()
  if recording then
    grace = grace - dt
    elapsed = math.max(d or 0, (sys.millis() - rec_t0) / 1000)
    blink = (math.floor(elapsed * 2) % 2) == 0
    -- the driver stopped on its own (card full, error): keep what was written
    if st ~= "recording" and grace <= 0 then stop_recording("Recording stopped: " .. tostring(rec_name)) end
  elseif playing then
    play_grace = play_grace - dt
    done, total = d or 0, t or 0
    if st == "playing" then play_grace = 0
    elseif play_grace <= 0 then playing = nil end
  end
end

function app.draw()
  if recording then
    gfx.disc(20, 26, 5, blink and col.bad or col.surface2)
    ui.text(30, 22, "REC", col.bad)
    ui.right(236, 22, rec_name or "", col.muted)
    ui.big(48, mmss(elapsed), col.text, 4)
    ui.center(92, on_sd and "Recording to the SD card" or "Recording to internal storage", col.muted)
    ui.footer({ { "Enter", "Stop" } })
    return
  end
  if #names == 0 then
    ui.empty("mic", "No recordings yet", "Enter starts recording")
    ui.footer({ { "Enter", "Record" }, { "Esc", "Home" } })
    return
  end
  if playing then
    ui.text(4, 19, "PLAY", col.accent)
    ui.bar(34, 20, 150, 6, total > 0 and done / total or 0)
    ui.right(236, 19, mmss(done) .. "/" .. mmss(total), col.muted)
  else
    ui.title(4, 19, "RECORDINGS")
    ui.right(236, 19, #names .. (on_sd and " on SD" or " on flash"), col.muted)
  end
  top = ui.list(rows, sel, top, 4, 31, 230, 15, 6)
  ui.footer({ { "Enter", "Record" }, { "Space", playing and "Stop" or "Play" }, { "X", "Del" }, { "Esc", "Home" } })
end

function app.key(k)
  if k.key == "enter" then
    if recording then stop_recording() else start_recording() end
    return true
  end
  if recording then
    if k.key == "esc" then return false end  -- close() stops and keeps the file
    return true
  end
  local d = ui.nav(k)
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(math.max(1, #names), sel + 1)
  elseif k.key == "space" or k.text == " " then
    if playing then stop_playing() else play_selected() end
  elseif k.text == "x" or k.key == "delete" then delete_selected()
  else return false end
  return true
end

function app.close()
  audio.stop()
  names, rows = {}, {}
end

return app
