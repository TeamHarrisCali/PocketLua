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
audio.play = function(p)
  hw("play", p)
  if A.fail then return false, A.fail end
  A.state, A.done, A.total = "playing", 0, 3
  return true
end
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

dofile("userland/boot.lua")

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
sys.write_text("data/music/a_song.wav", "RIFF")
sys.write_text("data/music/b_song.wav", "RIFF")
sys.write_text("data/music/notes.txt", "x")
shell.launch("music"); frames(3)
alive("music", "launches")
s, f = screen()
check(has(s, "a_song.wav") and has(s, "b_song.wav") and not has(s, "notes.txt") and f, "music: lists WAV files only")
key("enter")
check(last("play")[2] == "data/music/a_song.wav", "music: Enter plays the selection")
key("right")
check(last("play")[2] == "data/music/b_song.wav", "music: right skips to the next track")
key("left")
check(last("play")[2] == "data/music/a_song.wav", "music: left goes back")
A.done = 1.5; frames(2)
check(has(screen(), "0:01/0:03"), "music: shows time done / total")
local plays = count("play")
A.state = "idle"; frames(40)
check(count("play") == plays + 1 and last("play")[2] == "data/music/b_song.wav", "music: advances when a track ends")
key("enter")
check(A.state == "idle", "music: Enter stops the playing track")
local v0 = tonumber(cfg.get("vol")) or 100
key("=")
check(tonumber(cfg.get("vol")) > v0 and last("volume")[2] == tonumber(cfg.get("vol")), "music: = raises the volume")
key("-"); key("-")
check(tonumber(cfg.get("vol")) < v0, "music: - lowers the volume")
A.fail = "not a 16-bit PCM WAV"
key("enter")
check(toasts[#toasts] == "not a 16-bit PCM WAV", "music: a play failure is shown as a toast")
alive("music", "survives a play failure")
A.fail = nil
for _, k in ipairs({ "down", "down", "up", "esc" }) do key(k) end
check(shell.app() == "home", "music: Esc goes home")
shell.open_file("sd:/other/song.wav"); frames(2)
check(shell.app() == "music" and last("play")[2] == "sd:/other/song.wav", "music: open_file plays the file at once")
check(has(screen(), "song.wav"), "music: the opened file is in the list")
shell.home(); frames(2)
sys.remove("data/music/a_song.wav"); sys.remove("data/music/b_song.wav")
sys.storage = function() return "FLASH", 1000000, 1000 end
shell.launch("music"); frames(2)
s, f = screen()
check(has(s, "No music found") and f, "music: empty state without files")
key("enter"); key("right")
alive("music", "keys with no tracks")
sys.storage = real_storage
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
