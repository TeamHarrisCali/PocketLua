-- Music: play MP3 and WAV files from data/music and your recordings. Opens
-- .mp3 and .wav files from Files too. Enter plays/stops, left/right skip,
-- - and = set the volume. Wi-Fi is off while Music is open (focus mode): the
-- MP3 decoder needs that RAM. It comes back on when Music closes.
local col = ui.col

local app = { title = "Music", icon = "music", color = "pink", order = 41, category = "media" }

local MAX_TRACKS = 120

local tracks, rows = {}, {}   -- full paths; list rows
local sel, top = 1, 1
local cur = nil               -- index of the track that is playing (or last played)
local playing, grace = false, 0
local done, total = 0, 0
local vol = 100
local sd = false

local function mmss(s)
  s = math.floor(s or 0)
  return string.format("%d:%02d", s // 60, s % 60)
end

local function base(p) return p:match("([^/]+)$") or p end

local function add_dir(d, tag)
  local found = {}
  for _, e in ipairs(sys.list(d) or {}) do
    local lower = e.name:lower()
    if not e.dir and (lower:match("%.mp3$") or lower:match("%.wav$")) then found[#found + 1] = e.name end
  end
  table.sort(found)
  for _, n in ipairs(found) do
    if #tracks >= MAX_TRACKS then return end
    tracks[#tracks + 1] = d .. "/" .. n
    rows[#rows + 1] = { label = n, value = tag }
  end
end

local function scan(extra)
  tracks, rows = {}, {}
  sd = sys.storage() == "SD"
  if sd then
    add_dir("data/music", nil)
    add_dir("data/recordings", "rec")
  else
    add_dir("data/recordings", "rec")
  end
  if extra then
    for i, p in ipairs(tracks) do if p == extra then return i end end
    table.insert(tracks, 1, extra)
    table.insert(rows, 1, { label = base(extra), value = "file" })
    return 1
  end
end

local function play(i)
  local p = tracks[i]
  if not p then return end
  playing = false
  audio.stop()
  local ok, why = audio.play(p)
  if not ok then
    cur = nil
    shell.sound("error")
    shell.toast(tostring(why or "Can't play this file"), 3)
    return
  end
  cur, sel, playing, grace, done, total = i, i, true, 1, 0, 0
end

local function stop()
  playing = false
  audio.stop()
end

local function set_volume(v)
  vol = math.max(0, math.min(255, v))
  snd.volume(vol)
  cfg.set("vol", vol)
  shell.toast(string.format("Volume %d%%", math.floor(vol * 100 / 255 + 0.5)), 1)
end

function app.init(args)
  sel, top, cur, playing = 1, 1, nil, false
  shell.focus(true)
  vol = tonumber(cfg.get("vol")) or 100
  local i = scan(args and args.path)
  if i then sel = i; play(i) end
end

function app.update(dt)
  if not playing then return end
  local st, d, t = audio.status()
  done, total = d or 0, t or 0
  grace = grace - dt
  if st == "playing" then grace = 0
  elseif grace <= 0 then
    -- the track ended by itself: go on to the next one
    playing = false
    if cur and cur < #tracks then play(cur + 1)
    else shell.toast("End of list") end
  end
end

function app.draw()
  if #tracks == 0 then
    ui.empty("music", "No music found", sd and "Put MP3 or WAV files in /liveos/data/music" or "Insert an SD card")
    ui.footer({ { "Esc", "Home" } })
    return
  end
  ui.card(4, 16, 232, 28, playing)
  local name = cur and rows[cur] and rows[cur].label or "Not playing"
  ui.text(10, 20, ui.fit(name, 160), playing and col.text or col.muted)
  ui.right(230, 20, string.format("VOL %d%%", math.floor(vol * 100 / 255 + 0.5)), col.muted)
  ui.bar(10, 33, 150, 5, total > 0 and done / total or 0)
  ui.right(230, 32, mmss(done) .. "/" .. mmss(total), col.muted)
  top = ui.list(rows, sel, top, 4, 47, 230, 15, 5)
  ui.footer({ { "Enter", (playing and sel == cur) and "Stop" or "Play" }, { ",/", "Skip" }, { "-=", "Vol" },
    { "Esc", "Home" } })
end

function app.key(k)
  local d = ui.nav(k)
  local n = #tracks
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(math.max(1, n), sel + 1)
  elseif d == "left" and n > 0 then play(((cur or sel) - 2) % n + 1)
  elseif d == "right" and n > 0 then play((cur or sel) % n + 1)
  elseif k.key == "enter" then
    if playing and sel == cur then stop() elseif n > 0 then play(sel) end
  elseif k.text == "=" or k.text == "+" then set_volume(vol + 16)
  elseif k.text == "-" or k.text == "_" then set_volume(vol - 16)
  else return false end
  return true
end

function app.close()
  audio.stop()
  tracks, rows = {}, {}
end

return app
