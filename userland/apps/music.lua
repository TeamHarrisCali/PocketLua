-- Music: play MP3 and WAV files from data/music, sorted in folders (for
-- example Artist/Album/track.mp3), and your recordings. Enter opens a folder or
-- plays a track; the rest of that folder plays after it. Esc goes up a folder.
-- Left/right skip, - and = set the volume. Opens .mp3 and .wav files from Files
-- too. Wi-Fi is off while Music is open (focus mode): the MP3 decoder needs
-- that RAM. It comes back on when Music closes.
local col = ui.col

local app = { title = "Music", icon = "music", color = "pink", order = 41, category = "media" }

local ROOT, RECORDINGS = "data/music", "data/recordings"
local MAX_ENTRIES = 150       -- per folder; only the folder on screen is in memory

local dir = ROOT              -- folder on screen
local entries, rows = {}, {}  -- entries: { path, dir = bool }
local sel, top = 1, 1
local queue, cur = {}, nil    -- tracks of the folder playback started in; index playing
local playing, grace = false, 0
local done, total = 0, 0
local vol = 100

local function mmss(s)
  s = math.floor(s or 0)
  return string.format("%d:%02d", s // 60, s % 60)
end

local function base(p) return p:match("([^/]+)$") or p end
local function parent(p) return p:match("^(.*)/[^/]+$") or ROOT end
local function is_track(name)
  local lower = name:lower()
  return lower:match("%.mp3$") or lower:match("%.wav$")
end
local function title(p) return (base(p):gsub("%.[^.]+$", "")) end

-- Lists one folder: subfolders first, then tracks, each sorted by name. The
-- top level also gets the recordings folder at the end.
local function open_dir(d, select_path)
  dir, entries, rows, sel, top = d, {}, {}, 1, 1
  local folders, tracks = {}, {}
  for _, e in ipairs(sys.list(d) or {}) do
    if e.dir then folders[#folders + 1] = e.name
    elseif is_track(e.name) then tracks[#tracks + 1] = e.name end
  end
  table.sort(folders, function(a, b) return a:lower() < b:lower() end)
  table.sort(tracks, function(a, b) return a:lower() < b:lower() end)
  for _, n in ipairs(folders) do
    if #entries >= MAX_ENTRIES then break end
    entries[#entries + 1] = { path = d .. "/" .. n, dir = true }
    rows[#rows + 1] = { label = n, badge = "D", badge_color = ui.accents.orange }
  end
  for _, n in ipairs(tracks) do
    if #entries >= MAX_ENTRIES then break end
    entries[#entries + 1] = { path = d .. "/" .. n }
    rows[#rows + 1] = { label = title(n) }
  end
  if d == ROOT and #(sys.list(RECORDINGS) or {}) > 0 then
    entries[#entries + 1] = { path = RECORDINGS, dir = true }
    rows[#rows + 1] = { label = "Recordings", badge = "R", badge_color = ui.accents.red }
  end
  for i, e in ipairs(entries) do
    if e.path == select_path then sel = i end
  end
end

local function play_at(i)
  local p = queue[i]
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
  cur, playing, grace, done, total = i, true, 1, 0, 0
  for j, e in ipairs(entries) do  -- the selection follows playback in the folder on screen
    if e.path == p then sel = j end
  end
end

-- Plays the selected track and queues the tracks of the folder on screen.
local function play_selected()
  local chosen = entries[sel]
  if not chosen or chosen.dir then return end
  queue = {}
  local start = 1
  for _, e in ipairs(entries) do
    if not e.dir then
      queue[#queue + 1] = e.path
      if e.path == chosen.path then start = #queue end
    end
  end
  play_at(start)
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

local function now_playing() return cur and queue[cur] end

function app.init(args)
  queue, cur, playing = {}, nil, false
  shell.focus(true)
  vol = tonumber(cfg.get("vol")) or 100
  local path = args and args.path
  if path then
    open_dir(parent(path), path)
    if not (entries[sel] and entries[sel].path == path) then
      -- the folder could not be listed: play the file on its own
      entries, rows, sel = { { path = path } }, { { label = title(path) } }, 1
    end
    play_selected()
  else
    open_dir(ROOT)
  end
end

function app.update(dt)
  if not playing then return end
  local st, d, t = audio.status()
  done, total = d or 0, t or 0
  grace = grace - dt
  if st == "playing" then grace = 0
  elseif grace <= 0 then
    -- the track ended by itself: go on to the next one in its folder
    playing = false
    if cur and cur < #queue then play_at(cur + 1)
    else shell.toast("End of album") end
  end
end

function app.draw()
  if #entries == 0 and dir == ROOT then
    ui.empty("music", "No music found", "Put MP3 or WAV files in /liveos/data/music")
    ui.footer({ { "Esc", "Home" } })
    return
  end
  ui.card(4, 16, 232, 28, playing)
  local np = now_playing()
  ui.text(10, 20, ui.fit(np and title(np) or "Not playing", 160), playing and col.text or col.muted)
  ui.right(230, 20, string.format("VOL %d%%", math.floor(vol * 100 / 255 + 0.5)), col.muted)
  ui.bar(10, 33, 150, 5, total > 0 and done / total or 0)
  ui.right(230, 32, mmss(done) .. "/" .. mmss(total), col.muted)
  local where = dir == ROOT and "Music" or dir == RECORDINGS and "Recordings"
    or (dir:sub(1, #ROOT + 1) == ROOT .. "/" and dir:sub(#ROOT + 2) or dir):gsub("/", " / ")
  ui.text(8, 48, ui.fit(where, 224), col.muted)
  if #entries == 0 then
    ui.text(8, 64, "Empty folder", col.muted)
  else
    top = ui.list(rows, sel, top, 4, 59, 230, 15, 4)
  end
  local e = entries[sel]
  local enter = e and e.dir and "Open" or ((playing and e and e.path == np) and "Stop" or "Play")
  ui.footer({ { "Enter", enter }, { ",/", "Skip" }, { "-=", "Vol" }, { "Esc", dir == ROOT and "Home" or "Up" } })
end

function app.key(k)
  local d = ui.nav(k)
  local n = #entries
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(math.max(1, n), sel + 1)
  elseif d == "left" and #queue > 0 then play_at(((cur or 1) - 2) % #queue + 1)
  elseif d == "right" and #queue > 0 then play_at((cur or 0) % #queue + 1)
  elseif k.key == "enter" then
    local e = entries[sel]
    if not e then return true end
    if e.dir then open_dir(e.path)
    elseif playing and e.path == now_playing() then stop()
    else play_selected() end
  elseif k.key == "esc" or k.key == "backspace" then
    if dir == ROOT then return false end
    local inside = dir:sub(1, #ROOT + 1) == ROOT .. "/"
    open_dir(inside and parent(dir) or ROOT, dir)  -- recordings, or a folder opened from Files
  elseif k.text == "=" or k.text == "+" then set_volume(vol + 16)
  elseif k.text == "-" or k.text == "_" then set_volume(vol - 16)
  else return false end
  return true
end

function app.close()
  audio.stop()
  entries, rows, queue = {}, {}, {}
end

return app
