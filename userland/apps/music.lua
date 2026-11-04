-- Music: play MP3 and WAV files from data/music, sorted in folders (for
-- example Artist/Album/track.mp3), and your recordings. Enter opens a folder or
-- plays a track; the rest of that folder plays after it. Esc goes up a folder.
-- Left/right skip, - and = set the volume, a letter jumps to the next name
-- starting with it. Opens .mp3 and .wav files from Files too. Wi-Fi is off
-- while Music is open (focus mode): the MP3 decoder needs that RAM. It comes
-- back on when Music closes.
local col = ui.col

local app = { title = "Music", icon = "music", color = "pink", order = 41, category = "media" }

local ROOT, RECORDINGS = "data/music", "data/recordings"

-- Only the folder on screen is in memory, as plain strings: a library with
-- hundreds of artists stays small. names[i] ends in "/" for a folder.
local dir = ROOT
local names, rows = {}, {}    -- names as listed; what the list shows
local rec_row = nil           -- row of the recordings folder (top level only)
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
local function title(p) return (base(p):gsub("%.[^.]+$", "")) end
local function is_dir(i) return i == rec_row or (names[i] or ""):sub(-1) == "/" end
local function path_of(i)
  if i == rec_row then return RECORDINGS end
  local n = names[i]
  return n and (dir .. "/" .. (n:gsub("/$", ""))) or nil
end

-- Lists one folder (subfolders first, then tracks) and selects select_path.
local function open_dir(d, select_path)
  dir, sel, top, rec_row = d, 1, 1, nil
  names = sys.list_names(d, "mp3,wav") or {}
  rows = {}
  for i, n in ipairs(names) do rows[i] = n:sub(-1) == "/" and n or title(n) end
  if d == ROOT and #(sys.list_names(RECORDINGS, "wav") or {}) > 0 then
    names[#names + 1] = "Recordings/"
    rows[#rows + 1] = "Recordings/"
    rec_row = #names
  end
  for i = 1, #names do
    if path_of(i) == select_path then sel = i end
  end
end

-- Type a letter to jump to the next entry starting with it.
local function jump(ch)
  ch = ch:lower()
  for step = 1, #rows do
    local i = (sel + step - 1) % #rows + 1
    if rows[i]:sub(1, 1):lower() == ch then sel = i; return true end
  end
  return false
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
  for j = 1, #names do  -- the selection follows playback in the folder on screen
    if path_of(j) == p then sel = j end
  end
end

-- Plays the selected track and queues the tracks of the folder on screen.
local function play_selected()
  if not names[sel] or is_dir(sel) then return end
  queue = {}
  local start = 1
  for i = 1, #names do
    if not is_dir(i) then
      queue[#queue + 1] = path_of(i)
      if i == sel then start = #queue end
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
    if path_of(sel) ~= path then
      -- the folder could not be listed: play the file on its own
      dir, names, rows, sel, rec_row = parent(path), { base(path) }, { title(path) }, 1, nil
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
  if #names == 0 and dir == ROOT then
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
  if #names == 0 then
    ui.text(8, 64, "Empty folder", col.muted)
  else
    top = ui.list(rows, sel, top, 4, 59, 230, 15, 4)
  end
  local enter = is_dir(sel) and "Open" or ((playing and path_of(sel) == np) and "Stop" or "Play")
  ui.footer({ { "Enter", enter }, { ",/", "Skip" }, { "A-Z", "Find" }, { "Esc", dir == ROOT and "Home" or "Up" } })
end

function app.key(k)
  local d = ui.nav(k)
  local n = #names
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(math.max(1, n), sel + 1)
  elseif d == "left" and #queue > 0 then play_at(((cur or 1) - 2) % #queue + 1)
  elseif d == "right" and #queue > 0 then play_at((cur or 0) % #queue + 1)
  elseif k.key == "enter" then
    if not names[sel] then return true end
    if is_dir(sel) then open_dir(path_of(sel))
    elseif playing and path_of(sel) == now_playing() then stop()
    else play_selected() end
  elseif k.key == "esc" or k.key == "backspace" then
    if dir == ROOT then return false end
    local inside = dir:sub(1, #ROOT + 1) == ROOT .. "/"
    open_dir(inside and parent(dir) or ROOT, dir)  -- recordings, or a folder opened from Files
  elseif k.text == "=" or k.text == "+" then set_volume(vol + 16)
  elseif k.text == "-" or k.text == "_" then set_volume(vol - 16)
  elseif k.text and k.text:match("^%w$") and n > 0 then jump(k.text)
  else return false end
  return true
end

function app.close()
  audio.stop()
  names, rows, queue = {}, {}, {}
end

return app
