-- Headless test of the media apps (recorder, music, soundlab, beatbox, morse).
-- Run from the project root:  lua5.4 tools/tests/media.lua
local say = print
local src = assert(io.open("tools/host_test.lua")):read("a")
assert(load(src:match("^(.-)%-%- %-+ helpers"), "=stubs"))()

-- ------------------------------------------------------------ richer fakes
-- audio behaves like a small state machine so the apps can see recording,
-- playback and the end of a track.
local A = { state = "idle", done = 0, total = 0, fail = nil, level = 0.2, pitch = 440, mic = true }
local function hw(name, ...) hw_calls[#hw_calls + 1] = { name, ... } end
audio.record = function(p) hw("record", p); A.state, A.done, A.total = "recording", 0, 0; return true end
audio.play = function(p, at)
  hw("play", p, at)
  if A.fail then return false, A.fail end
  A.state, A.done, A.total = "playing", at or 0, 3
  return true
end
audio.pause = function(on) hw("pause", on); A.state = on and "paused" or "playing"; return on end
audio.seek = function(s) hw("seek", s) end
audio.stop = function() hw("stop"); A.state = "idle" end
audio.status = function() return A.state, A.done, A.total end
local analyze_calls = 0
audio.analyze = function()
  analyze_calls = analyze_calls + 1
  if not A.mic then return nil end
  return A.level, A.level * 1.5, A.pitch, { 0.1, 0.2, 0.3, 0.4, 0.3, 0.2, 0.1, 0.05 }
end
local tones = {}
snd.tone = function(f, ms) tones[#tones + 1] = { f, ms }; hw("tone", f, ms) end
snd.stop = function() hw("snd_stop") end
snd.volume = function(v) hw("volume", v) end

-- capture what gets drawn
local drawn, footer_seen, capturing = {}, false, false
local real_text, real_rfill = gfx.text, gfx.rfill
gfx.text = function(x, y, s, ...) if capturing then drawn[#drawn + 1] = tostring(s) end; return real_text(x, y, s, ...) end
gfx.rfill = function(x, y, ...) if capturing and y == 125 then footer_seen = true end; return real_rfill(x, y, ...) end

dofile("tools/emu/boot.lua")

local toasts, sounds = {}, {}
local real_toast, real_sound = shell.toast, shell.sound
shell.toast = function(m, s) toasts[#toasts + 1] = tostring(m); return real_toast(m, s) end
shell.sound = function(k, f) sounds[#sounds + 1] = k; return real_sound(k, f) end

local fails = 0
local function check(c, m) if c then say("ok:   " .. m) else fails = fails + 1; say("FAIL: " .. m) end end

-- one frame: update once, draw three bands. Hardware calls and analyze() must
-- happen in update only, and analyze() at most once per update.
local draw_hw, multi_analyze = 0, 0
local function frames(n)
  for _ = 1, n or 3 do
    local a0 = analyze_calls
    on_frame(0.033)
    if analyze_calls - a0 > 1 then multi_analyze = multi_analyze + 1 end
    local h0, a1 = #hw_calls, analyze_calls
    on_draw(); on_draw(); on_draw()
    draw_hw = draw_hw + (#hw_calls - h0) + (analyze_calls - a1)
  end
end
local function key(name, mods)
  local k = { key = name }
  if #name == 1 or name == "space" then k.text = name == "space" and " " or name end
  for m in pairs(mods or {}) do k[m] = true end
  on_key(k)
  frames(1)
end
local function type_text(s) for c in s:gmatch(".") do key(c) end end
local function screen()
  drawn, footer_seen, capturing = {}, false, true
  on_draw()
  capturing = false
  return table.concat(drawn, "\n"), footer_seen
end
local function count(name, arg)
  local n = 0
  for _, c in ipairs(hw_calls) do if c[1] == name and (arg == nil or c[2] == arg) then n = n + 1 end end
  return n
end
local function last(name)
  for i = #hw_calls, 1, -1 do if hw_calls[i][1] == name then return hw_calls[i] end end
end
local function has(s, needle) return s:find(needle, 1, true) ~= nil end
local function alive(name, what) check(shell.app() == name, name .. ": " .. what) end

frames(3)

-- ------------------------------------------------------------ headers
for _, n in ipairs({ "recorder", "music", "soundlab", "beatbox", "morse" }) do
  local s = assert(io.open("userland/apps/" .. n .. ".lua")):read("a")
  local line = s:match("\n(local app = [^\n]*)")
  local order = line and tonumber(line:match("order = (%d+)"))
  check(line and line:match("^local app = %b{}$") and order and order >= 40 and order <= 49,
    n .. ": one-line header with order 40-49")
end

-- ------------------------------------------------------------ recorder
shell.launch("recorder"); frames(3)
alive("recorder", "launches")
local s, f = screen()
check(has(s, "No recordings yet") and f, "recorder: empty state and footer")
key("enter")
check(last("record") and last("record")[2] == "data/recordings/rec_001.wav", "recorder: records to data/recordings/rec_001.wav")
sys.write_text("data/recordings/rec_001.wav", string.rep("\0", 32044 * 2))  -- what the driver would write
A.done = 2
frames(40)
s = screen()
check(has(s, "REC") and has(s, "0:0"), "recorder: shows the elapsed timer while recording")
check(A.state == "recording", "recorder: keeps recording across frames")
key("enter")
check(A.state == "idle" and count("stop") >= 1, "recorder: Enter stops")
s = screen()
check(has(s, "rec_001.wav") and has(s, "0:02"), "recorder: list shows the new file and its length")
key("space")
check(last("play") and last("play")[2] == "data/recordings/rec_001.wav", "recorder: Space plays the selection")
frames(3)
s = screen()
check(has(s, "PLAY"), "recorder: shows playback progress")
key("space")
check(A.state == "idle", "recorder: Space again stops")
key("enter")
check(last("record")[2] == "data/recordings/rec_002.wav", "recorder: next file number follows the existing ones")
A.state = "idle"; frames(40)  -- the driver stops on its own (card full)
alive("recorder", "survives the driver stopping by itself")
check(has(screen(), "rec_001.wav"), "recorder: back to the list after the driver stopped")
key("x"); frames(1)
key("y"); frames(1)
check(not sys.exists("data/recordings/rec_001.wav"), "recorder: X + confirm deletes the file")
check(has(screen(), "No recordings yet"), "recorder: list is empty again")
key("down"); key("up"); key("space"); key("x")
alive("recorder", "keys on an empty list")
key("enter")
key("esc")
check(shell.app() == "home" and A.state == "idle", "recorder: Esc while recording goes home and stops")
local real_storage = sys.storage
sys.storage = function() return "FLASH", 1000000, 1000 end
shell.launch("recorder"); frames(2)
key("enter")
check(last("record")[2] == "data/recordings/rec_001.wav", "recorder: without SD records to data/recordings")
key("enter")
sys.storage = real_storage
shell.home(); frames(2)

-- ------------------------------------------------------------ music
-- without a library: folders
sys.write_text("data/music/a_song.wav", "RIFF")
sys.write_text("data/music/b_song.wav", "RIFF")
sys.write_text("data/music/notes.txt", "x")
sys.mkdirs("data/music/Artist/Album")
sys.write_text("data/music/Artist/Album/01 First.mp3", "ID3")
sys.write_text("data/music/Artist/Album/02 Second.mp3", "ID3")
cfg.set("music_resume", nil)
shell.launch("music"); frames(3)
alive("music", "launches")
check(shell.focused, "music: turns on focus mode")
s, f = screen()
check(has(s, "Now Playing") and has(s, "Folders") and not has(s, "Artists") and f, "music: menu without a library")
key("down"); key("enter")
s = screen()
check(has(s, "Artist/") and has(s, "a_song") and has(s, "b_song") and not has(s, "notes"), "music: Folders lists folders and tracks")
key("down"); key("enter")
check(last("play")[2] == "data/music/a_song.wav", "music: Enter plays the selection")
s = screen()
check(has(s, "NOW PLAYING") and has(s, "a_song"), "music: playing goes full screen")
key("space")
check(last("pause")[2] == true and has(screen(), "Paused"), "music: Space pauses")
key("space")
check(last("pause")[2] == false and has(screen(), "Playing"), "music: Space resumes")
A.done = 1.5; frames(2)
check(has(screen(), "0:01") and has(screen(), "0:03"), "music: shows time done and total")
key("]")
check(last("seek")[2] == 11.5, "music: ] seeks ahead 10 s")
key("right")
check(last("play")[2] == "data/music/b_song.wav", "music: right skips to the next track")
key("left")
check(last("play")[2] == "data/music/a_song.wav", "music: left goes back")
local plays = count("play")
A.state = "idle"; frames(40)
check(count("play") == plays + 1 and last("play")[2] == "data/music/b_song.wav", "music: advances when a track ends")
key("r"); key("r")
check(has(screen(), "RPT1"), "music: R cycles repeat")
key("r")
key("esc")
check(has(screen(), "a_song") and not has(screen(), "NOW PLAYING"), "music: Esc shows the list")
frames(470)
check(has(screen(), "NOW PLAYING"), "music: idle brings Now Playing back")
key("esc"); key("up"); key("up"); key("enter")
check(has(screen(), "Album"), "music: Enter opens a folder")
key("enter"); key("enter")
check(last("play")[2] == "data/music/Artist/Album/01 First.mp3", "music: plays a track in a subfolder")
A.state = "idle"; frames(40)
check(last("play")[2] == "data/music/Artist/Album/02 Second.mp3", "music: the album plays on in order")
local v0 = tonumber(cfg.get("vol")) or 100
key("=")
check(tonumber(cfg.get("vol")) > v0 and last("volume")[2] == tonumber(cfg.get("vol")), "music: = raises the volume")
key("-"); key("-")
check(tonumber(cfg.get("vol")) < v0, "music: - lowers the volume")
-- resume where it stopped
A.done = 42; frames(2)
shell.home(); frames(2)
check(has(cfg.get("music_resume") or "", "Artist/Album"), "music: remembers the track on close")
shell.launch("music"); frames(3)
s = screen()
check(has(s, "NOW PLAYING") and has(s, "Second") and has(s, "Paused"), "music: reopens on the last track")
key("space")
check(last("play")[2] == "data/music/Artist/Album/02 Second.mp3" and last("play")[3] == 42, "music: Space resumes at the saved time")
A.fail = "only 16-bit PCM WAV is supported"
key("left")
check(toasts[#toasts] == A.fail, "music: a play failure is shown as a toast")
alive("music", "survives a play failure")
A.fail = nil
shell.home(); frames(2)

-- with a library (fake musiclib)
local T = {
  { "data/music/Abba/Gold/01 Dancing Queen.mp3", "Dancing Queen", "ABBA", "Gold", "Pop", "1" },
  { "data/music/Abba/Gold/02 Waterloo.mp3", "Waterloo", "ABBA", "Gold", "Pop", "2" },
  { "data/music/Zed/Z/01 Zeta.mp3", "Zeta", "Zed", "Z", "Rock", "1" },
}
local ART = { { "ABBA", 1, 2 }, { "Zed", 3, 1 } }
local ALB = { { "Gold", "ABBA", 1, 2 }, { "Z", "Zed", 3, 1 } }
local GEN = { { "Pop", 1, 2 }, { "Rock", 3, 1 } }
local G = { 1, 2, 3 }
local saved_lib = musiclib
musiclib = {
  info = function() return { tracks = 3, artists = 2, albums = 2, genres = 2 } end,
  rows = function(kind, first, n)
    local src = kind == "artists" and ART or kind == "albums" and ALB or kind == "genres" and GEN or T
    local out = {}
    for i = first, math.min(first + n - 1, #src) do
      local r = src[i]
      out[#out + 1] = kind == "tracks" and { label = r[2], value = r[3] } or { label = r[1], value = tostring(r[2]) }
    end
    return out
  end,
  item = function(kind, i)
    if kind == "gtracks" then return G[i] end
    local r = (kind == "artists" and ART or kind == "albums" and ALB or kind == "genres" and GEN or T)[i]
    if r then return table.unpack(r) end
  end,
  albums_in = function(first, count) return { { label = "Gold", value = "2", first = first, count = count } } end,
  find = function(kind, row)
    for i, r in ipairs(kind == "artists" and ART or ALB) do
      local first, count = r[#r - 1], r[#r]
      if row >= first and row < first + count then return i end
    end
  end,
}
__hw_musiclib = musiclib
cfg.set("music_resume", nil)
shell.launch("music"); frames(3)
s = screen()
check(has(s, "Artists") and has(s, "Albums") and has(s, "Genres") and has(s, "Shuffle all"), "music: library menu")
key("down"); key("enter")
check(has(screen(), "ABBA") and has(screen(), "Zed"), "music: Artists lists the library")
key("z")
check(has(screen(), "2/2"), "music: a letter jumps in the artist list")
key("a"); key("enter")
check(has(screen(), "Gold"), "music: an artist shows their albums")
key("enter")
check(has(screen(), "Dancing Queen") and has(screen(), "Waterloo"), "music: an album shows its tracks")
key("down"); key("enter")
check(last("play")[2] == "data/music/Abba/Gold/02 Waterloo.mp3", "music: plays a library track")
check(has(screen(), "Waterloo") and has(screen(), "ABBA") and has(screen(), "Gold"), "music: Now Playing shows the tags")
key("tab")
check(not has(screen(), "NOW PLAYING") and has(screen(), "Dancing Queen"), "music: Tab goes from Now Playing to the list")
key("tab")
check(has(screen(), "NOW PLAYING"), "music: Tab comes back to Now Playing")
key("e")
check(audio.eq_now == "warm" and has(screen(), "EQ Warm"), "music: E switches the equalizer preset")
key("e"); key("e")
check(audio.eq_now == "flat" and not has(screen(), "EQ "), "music: E cycles back to Flat")
key("a")
s = screen()
check(has(s, "Gold") and has(s, "2/2") and has(s, "Waterloo"), "music: A opens the song's album at the song")
key("esc")
check(has(screen(), "Albums") and has(screen(), "1/2"), "music: Esc from it goes to Albums at that album")
key("tab"); key("t")
s = screen()
check(has(s, "ABBA") and has(s, "Gold"), "music: T opens the song's artist")
key("esc")
check(has(screen(), "Artists"), "music: Esc from it goes to Artists")
key("enter"); key("enter"); key("tab")  -- Artists > ABBA > Gold, then Now Playing, as the tests below expect
key("esc"); key("esc"); key("esc"); key("esc")
key("down"); key("down"); key("enter")
check(has(screen(), "Pop") and has(screen(), "Rock"), "music: Genres lists the genres")
key("down"); key("enter"); key("enter")
check(last("play")[2] == "data/music/Zed/Z/01 Zeta.mp3", "music: plays from a genre")
local scans = 0
musiclib.scan = function(full) scans = scans + 1; return true end
local scan_state = "reading"
musiclib.scan_status = function() return scan_state, 2, "" end
key("esc"); key("esc"); key("esc")
for _ = 1, 6 do key("down") end
check(has(screen(), "Rescan library"), "music: menu offers a rescan")
key("enter")
check(scans == 1 and has(screen(), "Scanning library") and has(screen(), "Reading 2"), "music: rescan shows progress")
key("esc")
alive("music", "Esc is ignored while scanning")
scan_state = "done"; frames(2)
check(has(screen(), "Artists") and toasts[#toasts] == "Library: 2 tracks", "music: back to the menu when the scan is done")
-- shuffle: back, then forward, plays the same songs again
for _ = 1, 4 do key("down") end
key("enter")  -- Shuffle all
local s1 = last("play")[2]
key("/"); local s2 = last("play")[2]
key("/"); local s3 = last("play")[2]
key(","); key(",")
check(last("play")[2] == s1, "music: shuffle goes back through the songs played")
key("/")
check(last("play")[2] == s2, "music: then forward replays the same next song")
key("/")
check(last("play")[2] == s3, "music: and the one after it")
key("/")
check(last("play")[2] ~= s3, "music: past them, a new song is picked")
key(",")
check(last("play")[2] == s3, "music: back from a new pick returns to the previous song")
shell.home(); frames(2)
musiclib, __hw_musiclib = saved_lib, saved_lib
for _, n in ipairs({ "a_song.wav", "b_song.wav", "notes.txt", "Artist/Album/01 First.mp3", "Artist/Album/02 Second.mp3" }) do
  sys.remove("data/music/" .. n)
end
cfg.set("music_resume", nil)
shell.launch("music"); frames(2)
key("down"); key("enter")
check(has(screen(), "Empty") or has(screen(), "Recordings"), "music: empty folder list")
key("enter"); key("right"); key("space")
alive("music", "keys with nothing to play")
shell.home(); frames(2)

-- ------------------------------------------------------------ sound lab
shell.launch("soundlab"); frames(5)
alive("soundlab", "launches")
local a0 = analyze_calls
frames(10)
check(analyze_calls - a0 == 10, "soundlab: analyze runs once per update")
s, f = screen()
check(has(s, "dBFS") and f, "soundlab: level tab shows dBFS")
A.level = 1.0; frames(5)
check(has(screen(), "0 dBFS"), "soundlab: full-scale level reads 0 dBFS")
A.level = 0; frames(5)
check(has(screen(), "dBFS"), "soundlab: silence does not break the meter")
A.level = 0.2
key("tab")
check(has(screen(), "100 Hz"), "soundlab: spectrum tab")
key("tab"); frames(3)
s = screen()
check(has(s, "A") and has(s, "440.0 Hz") and has(s, "0 cents"), "soundlab: tuner shows A4 at 440 Hz")
A.pitch = 82.41 * 2 ^ (20 / 1200); frames(10)
s = screen()
check(has(s, "E") and has(s, "2") and has(s, "+20 cents"), "soundlab: tuner finds E2, 20 cents sharp")
A.pitch = 0; frames(40)
alive("soundlab", "tuner with no pitch")
key("space")
a0 = analyze_calls
frames(5)
check(analyze_calls == a0, "soundlab: Space pauses listening")
key("space")
key("tab", { shift = true }); key("left"); key("right")
A.mic = false; frames(3)
check(has(screen(), "Microphone not available"), "soundlab: reports a missing microphone")
A.mic = true; frames(3)
key("esc")
check(shell.app() == "home", "soundlab: Esc goes home")
frames(2)

-- ------------------------------------------------------------ beat box
sys.remove("data/beatbox.txt")
shell.launch("beatbox"); frames(3)
alive("beatbox", "launches")
s, f = screen()
check(has(s, "120 BPM") and has(s, "Kick") and f, "beatbox: grid and tempo")
local t0 = #tones
key("p")
frames(30)
check(#tones > t0 and tones[t0 + 1][1] == 60, "beatbox: step 1 plays the kick (kick beats the hat)")
local per_frame_ok = true
for _ = 1, 30 do local n = #tones; frames(1); if #tones - n > 1 then per_frame_ok = false end end
check(per_frame_ok, "beatbox: at most one tone per frame")
local seen = {}
for i = t0 + 1, #tones do seen[tones[i][1]] = true end
check(seen[60] and seen[200] and seen[6000], "beatbox: kick, snare and hat all play")
key("p")
for _ = 1, 30 do key("=") end
check(has(screen(), "200 BPM"), "beatbox: tempo tops out at 200")
key("enter")   -- cursor on Kick step 1: toggle it off
key("s")
local saved = sys.read_text("data/beatbox.txt") or ""
check(has(saved, "bpm=200") and saved:match("K=%.") ~= nil, "beatbox: S saves tempo and pattern")
for _ = 1, 40 do key("-") end
check(has(screen(), "60 BPM"), "beatbox: tempo bottoms out at 60")
key("down"); key("right"); key("space")
key("]"); key("]"); key("[")
for _, k in ipairs({ "up", "left", "left", ".", ";", ",", "/" }) do key(k) end
alive("beatbox", "cursor and bass keys")
shell.home(); frames(2)
shell.launch("beatbox"); frames(2)
check(has(screen(), "200 BPM"), "beatbox: the saved pattern loads on open")
key("c"); key("y"); key("s")
saved = sys.read_text("data/beatbox.txt") or ""
check(not saved:find("x"), "beatbox: C clears the pattern")
t0 = #tones
key("p"); frames(30); key("p")
check(#tones == t0, "beatbox: an empty pattern is silent")
key("esc")
check(shell.app() == "home", "beatbox: Esc goes home")
frames(2)

-- ------------------------------------------------------------ morse
cfg.set("morse_wpm", nil)
shell.launch("morse"); frames(3)
alive("morse", "launches")
s, f = screen()
check(has(s, "Translate") and has(s, "Type a message") and f, "morse: translate tab")
type_text("sos")
check(has(screen(), "... --- ..."), "morse: text is translated as you type")
t0 = #tones
key("enter")
frames(80)
local pat = ""
for i = t0 + 1, #tones do pat = pat .. (tones[i][2] < 100 and "." or "-") end
check(pat == "...---...", "morse: Enter plays SOS (" .. pat .. ")")
key("enter"); key("enter")
check(count("snd_stop") > 0, "morse: Enter while playing stops")
key("up"); key("up")
check(cfg.get("morse_wpm") == "20", "morse: Up raises the speed")
key("down")
check(cfg.get("morse_wpm") == "19", "morse: Down lowers it")
key("backspace"); key("delete")
check(has(screen(), "Type a message"), "morse: Delete clears the text")
type_text("a;b,c./"); key("~")
alive("morse", "punctuation typed in translate")
key("delete")
-- practice: decode what is played and answer it
key("tab")
check(has(screen(), "Listen and type"), "morse: practice tab")
local REV = {}
for ch, c in pairs({ A = ".-", B = "-...", C = "-.-.", D = "-..", E = ".", F = "..-.", G = "--.", H = "....", I = "..",
  J = ".---", K = "-.-", L = ".-..", M = "--", N = "-.", O = "---", P = ".--.", Q = "--.-", R = ".-.",
  S = "...", T = "-", U = "..-", V = "...-", W = ".--", X = "-..-", Y = "-.--", Z = "--.." }) do REV[c] = ch end
local function heard()
  local t1 = #tones
  frames(60)
  local p = ""
  for i = t1 + 1, #tones do p = p .. (tones[i][2] < 100 and "." or "-") end
  return REV[p]
end
local t1 = #tones
key("enter")
frames(60)
local p = ""
for i = t1 + 1, #tones do p = p .. (tones[i][2] < 100 and "." or "-") end
local letter = REV[p]
check(letter ~= nil, "morse: practice plays a letter")
local errs = #sounds
key((letter or "a"):lower())
check(#sounds == errs and has(screen(), "Score 1/1"), "morse: the right answer scores")
local nxt = heard()   -- the next letter starts on its own
check(nxt ~= nil, "morse: next letter plays by itself")
key(nxt == "Q" and "z" or "q")
check(sounds[#sounds] == "error" and has(screen(), "Score 1/2"), "morse: a wrong answer is marked")
frames(70)
key("enter")
alive("morse", "practice replay")
-- key tab: Space = dit, Enter = dah, decoded after a pause
key("tab")
check(has(screen(), "Space = dit"), "morse: key tab")
key("space"); key("enter")
check(has(screen(), ".-"), "morse: shows the symbol being keyed")
frames(40)
check(has(screen(), "A"), "morse: decodes .- to A after a pause")
frames(60)
key("space"); key("space"); key("space"); frames(40)
s = screen()
check(has(s, "A S") or has(s, "AS"), "morse: second letter (" .. s:gsub("\n", "|") .. ")")
key("backspace"); key("enter"); key("enter"); key("backspace"); frames(40); key("delete")
alive("morse", "key tab editing")
key("tab", { shift = true })
check(has(screen(), "Score"), "morse: Shift+Tab goes back a tab")
key("esc")
check(shell.app() == "home", "morse: Esc goes home")

-- ------------------------------------------------------------ cross-app rules
check(draw_hw == 0, "no hardware or analyze() calls from draw()")
check(multi_analyze == 0, "analyze() never runs twice in one update")

say(string.format("\n%d failure(s)", fails))
os.exit(fails == 0 and 0 or 1)
