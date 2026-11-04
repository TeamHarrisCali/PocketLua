-- Music: an MP3/WAV player. Browse the library (Artists, Albums, Genres,
-- built from the tags by tools/music_library.py) or the folders under
-- data/music. Playing a track queues the rest of its album/list. Now Playing
-- shows the song full screen; Esc goes to the lists and after 15 s idle it
-- comes back. Wi-Fi is off while Music is open (focus mode) for the decoder's
-- RAM. Long lists cost nothing: only the rows on screen are read.
local col = ui.col

local app = { title = "Music", icon = "music", color = "pink", order = 41, category = "media" }
app.help = {
  { "Space", "Pause / play" },
  { ",/", "Prev / next track" },
  { "[ ]", "Back / ahead 10 s" },
  { "-=", "Volume" },
  { "S", "Shuffle (Now Playing)" },
  { "R", "Repeat (Now Playing)" },
  { "Enter", "Open / play" },
  { "A-Z", "Jump in a list" },
  { "Esc", "Back / lists" },
}

local ROOT, RECORDINGS = "data/music", "data/recordings"
local ROWS, IDLE_BACK = 4, 15  -- list rows on screen; seconds idle before Now Playing returns

local lib                      -- musiclib.info(), nil without a library
local view = "menu"            -- "menu" | "list" | "playing"
local stack = {}               -- lists opened from the menu, deepest last
local L                        -- the list on screen (stack top)
local win, win_top = {}, 0     -- cached visible rows of L
local menu, msel = {}, 1

-- What plays: q.kind "range" (rows of tracks.dat), "grange" (rows of
-- gtracks.dat) or "dir" (q.names in folder q.dir). q.pos is 1-based.
local q = nil
local np = nil                 -- info on the current track
local state = "stopped"        -- "playing" | "paused" | "ready" (loaded, not started) | "stopped"
local done, total, grace = 0, 0, 0
local shuffle, rpt = false, "off"
local hist = {}                -- shuffle history, for "previous"
local vol = 100
local idle, save_t = 0, 0

local function mmss(s)
  s = math.floor(s or 0)
  return string.format("%d:%02d", s // 60, s % 60)
end
local function base(p) return p:match("([^/]+)$") or p end
local function parent(p) return p:match("^(.*)/[^/]+$") or ROOT end
local function title(p) return (base(p):gsub("%.[^.]+$", "")) end

-- ---------------------------------------------------------------- queue
local function qcount() return q and (q.names and #q.names or q.count) or 0 end

-- Path and info of queue position k.
local function qtrack(k)
  if not q then return nil end
  if q.kind == "dir" then
    local n = q.names[k]
    if not n then return nil end
    local p = q.dir .. "/" .. n
    local t = audio.tags(p) or {}
    return p, { title = t.title or title(p), artist = t.artist or (q.dir == RECORDINGS and "Recording" or base(parent(q.dir))),
      album = t.album or base(q.dir), track = t.track }
  end
  local row = q.first + k - 1
  if q.kind == "grange" then row = musiclib.item("gtracks", row) end
  local p, t, ar, al, g, tr = musiclib.item("tracks", row)
  if not p then return nil end
  return p, { title = t, artist = ar, album = al, genre = g, track = tr }
end

local function save_resume()
  if not q or not np then return end
  local where = q.kind == "dir" and ("dir|" .. q.dir) or (q.kind .. "|" .. q.first .. "|" .. q.count)
  cfg.set("music_resume", where .. "|" .. q.pos .. "|" .. math.floor(done))
end

local function play_pos(k, at)
  local p, info = qtrack(k)
  if not p then state = "stopped"; return end
  q.pos, np = k, info
  local ok, why = audio.play(p, at)
  if not ok then
    state = "stopped"
    shell.sound("error")
    shell.toast(tostring(why or "Can't play this file"), 3)
    return
  end
  state, grace, done, total = "playing", 1, at or 0, 0
end

local function step(dir)  -- next (+1) or previous (-1) track
  local n = qcount()
  if n == 0 then return end
  if shuffle and n > 1 then
    if dir < 0 and #hist > 0 then return play_pos(table.remove(hist)) end
    hist[#hist + 1] = q.pos
    if #hist > 30 then table.remove(hist, 1) end
    local k
    repeat k = math.random(n) until k ~= q.pos
    return play_pos(k)
  end
  local k = q.pos + dir
  if k < 1 then k = rpt == "all" and n or 1 end
  if k > n then
    if rpt ~= "all" then state = "stopped"; audio.stop(); shell.toast("End of list"); return end
    k = 1
  end
  play_pos(k)
end

local function toggle_pause()
  if state == "playing" then audio.pause(true); state = "paused"; save_resume()
  elseif state == "paused" then audio.pause(false); state = "playing"
  elseif state == "ready" then play_pos(q.pos, done) end
end

-- ---------------------------------------------------------------- lists
-- A list has: name, count, and either all (rows in memory) or rows(first, n)
-- (read on demand), plus what Enter does (see enter()).
local function lib_list(kind, name)
  return { name = name, kind = kind, count = lib[kind] or 0,
    rows = function(first, n) return musiclib.rows(kind, first, n) end }
end

local function track_list(name, kind, first, count)
  local l = { name = name, count = count, play = { kind = kind, first = first, count = count } }
  function l.rows(f, n)
    if kind == "range" then return musiclib.rows("tracks", first + f - 1, math.min(n, count - f + 1)) end
    local out = {}
    for i = f, math.min(f + n - 1, count) do
      out[#out + 1] = musiclib.rows("tracks", musiclib.item("gtracks", first + i - 1), 1)[1]
    end
    return out
  end
  return l
end

local function table_list(name, rows) return { name = name, count = #rows, all = rows } end

local function dir_list(d)
  local names = sys.list_names(d, "mp3,wav", 300) or {}
  local rows = {}
  for i, n in ipairs(names) do rows[i] = n:sub(-1) == "/" and n or title(n) end
  if d == ROOT and #(sys.list_names(RECORDINGS, "wav", 1) or {}) > 0 then
    names[#names + 1] = "Recordings/"
    rows[#rows + 1] = "Recordings/"
  end
  local l = table_list(d == ROOT and "Folders" or d == RECORDINGS and "Recordings" or base(d), rows)
  l.dir, l.names = d, names
  return l
end

local function open_list(l)
  l.sel = l.sel or 1
  stack[#stack + 1] = l
  L, win_top, view = l, 0, "list"
  collectgarbage()
end

local function back()
  stack[#stack] = nil
  L, win_top = stack[#stack], 0
  if not L then view = "menu" end
  collectgarbage()
end

local function visible()
  local top = math.max(1, math.min(L.sel - 1, L.count - ROWS + 1))
  if L.all then return L.all, top end
  if top ~= win_top then win, win_top = L.rows(top, ROWS), top end
  return win, top
end

-- Starts the list on screen at row i, queueing its tracks.
local function play_list(i)
  hist = {}
  if L.names then
    local files, k = {}, 1
    for j, n in ipairs(L.names) do
      if n:sub(-1) ~= "/" then
        files[#files + 1] = n
        if j == i then k = #files end
      end
    end
    q = { kind = "dir", dir = L.dir, names = files, pos = 1 }
    play_pos(k)
  else
    q = { kind = L.play.kind, first = L.play.first, count = L.play.count, pos = 1 }
    play_pos(i)
  end
  if state == "playing" then view = "playing" end
end

local function enter(i)
  if L.kind == "artists" then
    local name, first, count = musiclib.item("artists", i)
    open_list(table_list(name, musiclib.albums_in(first, count)))
    L.albums = true
  elseif L.kind == "albums" then
    local album, _, first, count = musiclib.item("albums", i)
    open_list(track_list(album, "range", first, count))
  elseif L.kind == "genres" then
    local name, first, count = musiclib.item("genres", i)
    open_list(track_list(name, "grange", first, count))
  elseif L.albums then  -- one artist's albums
    local a = L.all[i]
    open_list(track_list(a.label, "range", a.first, a.count))
  elseif L.names then
    local n = L.names[i]
    if n and n:sub(-1) == "/" then
      open_list(dir_list((n == "Recordings/" and L.dir == ROOT) and RECORDINGS or (L.dir .. "/" .. n:sub(1, -2))))
    elseif n then play_list(i) end
  elseif L.play then
    play_list(i)
  end
end

-- Type a letter: the first row starting with it. The library lists are
-- sorted, so they are searched by halving (a few reads for hundreds of rows).
local function jump(ch)
  local function first_char(i)
    local r = L.all and L.all[i] or L.rows(i, 1)[1]
    r = type(r) == "table" and r.label or r or ""
    return r:sub(1, 1):lower()
  end
  if L.kind then
    local lo, hi = 1, L.count
    while lo < hi do
      local mid = (lo + hi) // 2
      if first_char(mid) < ch then lo = mid + 1 else hi = mid end
    end
    L.sel = lo
    return
  end
  for s = 1, L.count do
    local i = (L.sel + s - 1) % L.count + 1
    if first_char(i) == ch then L.sel = i; return end
  end
end

local function build_menu()
  menu = { { "Now Playing", "playing" } }
  if lib then
    menu[#menu + 1] = { "Artists", "artists", lib.artists }
    menu[#menu + 1] = { "Albums", "albums", lib.albums }
    menu[#menu + 1] = { "Genres", "genres", lib.genres }
    menu[#menu + 1] = { "Shuffle all", "shuffle", lib.tracks }
  end
  menu[#menu + 1] = { "Folders", "folders" }
  menu[#menu + 1] = { lib and "Rescan library" or "Build library", "scan" }
end

-- Rebuilds the library index on the device (new and removed music). It runs
-- natively in the background; playback stops because it needs that RAM.
local function start_scan()
  audio.stop()
  state, stack, L = "stopped", {}, nil
  local ok, why = musiclib.scan(not lib)
  if not ok then shell.toast("Can't scan: " .. tostring(why), 3); return end
  view = "scan"
end

local function menu_enter(id)
  if id == "playing" then view = "playing"
  elseif id == "scan" then start_scan()
  elseif id == "folders" then open_list(dir_list(ROOT))
  elseif id == "shuffle" then
    shuffle, hist = true, {}
    q = { kind = "range", first = 1, count = lib.tracks, pos = 1 }
    play_pos(math.random(lib.tracks))
    view = "playing"
  else open_list(lib_list(id, ({ artists = "Artists", albums = "Albums", genres = "Genres" })[id])) end
end

-- ---------------------------------------------------------------- app
local function set_volume(v)
  vol = math.max(0, math.min(255, v))
  snd.volume(vol)
  cfg.set("vol", vol)
end

-- Picks up where the last session stopped: same list, track and position.
local function resume()
  local f = {}
  for part in ((cfg.get("music_resume") or "") .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
  if f[1] == "dir" then
    local names = {}
    for _, n in ipairs(sys.list_names(f[2], "mp3,wav", 300) or {}) do
      if n:sub(-1) ~= "/" then names[#names + 1] = n end
    end
    q = { kind = "dir", dir = f[2], names = names, pos = tonumber(f[3]) or 1 }
    done = tonumber(f[4]) or 0
  elseif lib and (f[1] == "range" or f[1] == "grange") then
    q = { kind = f[1], first = tonumber(f[2]) or 1, count = tonumber(f[3]) or 0, pos = tonumber(f[4]) or 1 }
    done = tonumber(f[5]) or 0
  end
  if q and q.pos <= qcount() then
    local p
    p, np = qtrack(q.pos)
    if p then state, view = "ready", "playing" return end
  end
  q, np, done = nil, nil, 0
end

function app.init(args)
  shell.focus(true)
  math.randomseed(sys.millis())
  vol = tonumber(cfg.get("vol")) or 100
  shuffle = cfg.get("music_shuffle") == "1"
  rpt = cfg.get("music_repeat") or "off"
  lib = musiclib.info()
  build_menu()
  local path = args and args.path
  if path then  -- opened from Files
    open_list(dir_list(parent(path)))
    for i, n in ipairs(L.names) do
      if n == base(path) then L.sel = i end
    end
    play_list(L.sel)
  else
    resume()
  end
end

function app.update(dt)
  if view == "scan" then
    local st, n, msg = musiclib.scan_status()
    if st == "done" or st == "failed" then
      lib = musiclib.info()
      build_menu()
      view, msel = "menu", 1
      if q and q.kind ~= "dir" then q, np = nil, nil; cfg.set("music_resume", nil) end  -- rows moved
      shell.toast(st == "done" and ("Library: " .. n .. " tracks") or ("Scan failed: " .. tostring(msg)), 4)
    end
    return
  end
  idle = idle + dt
  if view ~= "playing" and state == "playing" and idle >= IDLE_BACK then view = "playing" end
  if state ~= "playing" then return end
  local st, d, t = audio.status()
  done, total = d or 0, t or 0
  save_t = save_t + dt
  if save_t >= 15 then save_t = 0; save_resume() end
  grace = grace - dt
  if st == "playing" or st == "paused" then grace = 0
  elseif grace <= 0 then  -- the track ended by itself
    if rpt == "one" then play_pos(q.pos) else step(1) end
  end
end

local function draw_playing()
  if not np then
    ui.empty("music", "Nothing playing", lib and "Pick something from the lists" or "Put MP3s in /pocketlua/data/music")
    ui.footer({ { "Esc", "Lists" } })
    return
  end
  local flags = (shuffle and "SHUF " or "") .. (rpt == "one" and "RPT1 " or rpt == "all" and "RPT " or "")
  ui.text(6, 18, "NOW PLAYING", col.muted)
  ui.right(234, 18, flags .. q.pos .. "/" .. qcount(), col.muted)
  ui.text(6, 31, ui.fit(np.title or "", 228, 2), col.text, 2)
  ui.text(6, 52, ui.fit(np.artist or "", 228), col.accent)
  ui.text(6, 64, ui.fit(np.album or "", 228), col.muted)
  ui.bar(6, 82, 228, 6, total > 0 and done / total or 0)
  ui.text(6, 92, mmss(done), col.muted)
  ui.right(234, 92, total > 0 and mmss(total) or "", col.muted)
  ui.text(6, 106, state == "playing" and "Playing" or state == "stopped" and "Stopped" or "Paused",
    state == "playing" and col.good or col.muted)
  ui.right(234, 106, string.format("VOL %d%%", math.floor(vol * 100 / 255 + 0.5)), col.muted)
  ui.footer({ { "Spc", state == "playing" and "Pause" or "Play" }, { ",/", "Skip" }, { "[]", "Seek" }, { "Esc", "Lists" } })
end

function app.draw()
  if view == "playing" then return draw_playing() end
  if view == "scan" then
    local st, n = musiclib.scan_status()
    ui.empty("music", "Scanning library", (st == "reading" and "Reading " or st == "sorting" and "Sorting " or "Writing ") ..
      n .. " tracks")
    ui.footer({ { "", "Please wait" } })
    return
  end
  -- the current track as a strip above the lists
  ui.card(4, 16, 232, 22, state == "playing")
  ui.text(10, 19, ui.fit(np and np.title or "Not playing", 168), state == "playing" and col.text or col.muted)
  ui.right(230, 19, total > 0 and (mmss(done) .. "/" .. mmss(total)) or "", col.muted)
  ui.bar(10, 31, 220, 3, total > 0 and done / total or 0)
  if view == "menu" then
    local rows = {}
    for i, m in ipairs(menu) do rows[i] = { label = m[1], value = m[3] and tostring(m[3]) or nil } end
    ui.list(rows, msel, 1, 4, 42, 230, 15, 5)
    if not lib then ui.text(8, 80, "No library yet: tools/music_library.py", col.muted) end
    ui.footer({ { "Enter", "Open" }, { "Spc", "Pause" }, { "Esc", "Home" } })
    return
  end
  ui.text(8, 42, ui.fit(L.name or "", 180), col.muted)
  ui.right(232, 42, L.count > 0 and (L.sel .. "/" .. L.count) or "", col.muted)
  if L.count == 0 then
    ui.text(8, 64, "Empty", col.muted)
  else
    local rows, top = visible()
    if L.all then ui.list(rows, L.sel, top, 4, 54, 230, 15, ROWS)
    else ui.list(rows, L.sel - top + 1, 1, 4, 54, 230, 15, ROWS) end
  end
  ui.footer({ { "Enter", "Play" }, { "A-Z", "Find" }, { "Spc", "Pause" }, { "Esc", "Back" } })
end

function app.key(k)
  idle = 0
  if view == "scan" then return true end  -- leaving would bring Wi-Fi back mid-scan
  local d = ui.nav(k)
  local c = not k.ctrl and not k.fn and k.text and k.text:lower()
  -- the same everywhere
  if c == " " or k.key == "space" then toggle_pause(); return true end
  if d == "left" then step(-1); return true end
  if d == "right" then step(1); return true end
  if c == "[" or c == "]" then
    if state == "playing" or state == "paused" then audio.seek(math.max(0, done + (c == "]" and 10 or -10))) end
    return true
  end
  if c == "=" or c == "+" then set_volume(vol + 16); return true end
  if c == "-" or c == "_" then set_volume(vol - 16); return true end
  if view == "playing" then
    if k.key == "enter" then toggle_pause()
    elseif d == "up" then set_volume(vol + 16)
    elseif d == "down" then set_volume(vol - 16)
    elseif c == "s" then shuffle, hist = not shuffle, {}; cfg.set("music_shuffle", shuffle and "1" or "0")
    elseif c == "r" then
      rpt = rpt == "off" and "all" or rpt == "all" and "one" or "off"
      cfg.set("music_repeat", rpt)
    elseif k.key == "esc" or k.key == "backspace" then view = L and "list" or "menu"
    else return false end
    return true
  end
  if view == "menu" then
    if d == "up" then msel = math.max(1, msel - 1)
    elseif d == "down" then msel = math.min(#menu, msel + 1)
    elseif k.key == "enter" then menu_enter(menu[msel][2])
    else return false end
    return true
  end
  if d == "up" then L.sel = math.max(1, L.sel - 1)
  elseif d == "down" then L.sel = math.min(math.max(1, L.count), L.sel + 1)
  elseif k.key == "enter" then if L.count > 0 then enter(L.sel) end
  elseif k.key == "esc" or k.key == "backspace" then back()
  elseif c and c:match("^%w$") and L.count > 0 then jump(c)
  else return false end
  return true
end

function app.close()
  save_resume()
  audio.stop()
  stack, L, win, q = {}, nil, {}, nil
end

return app
