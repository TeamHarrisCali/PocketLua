-- Morse: translate text to Morse and hear it, practise reading it by ear,
-- and key it yourself (Space = dit, Enter = dah).
local col = ui.col

local app = { title = "Morse", icon = "morse", color = "green", order = 44, category = "tools" }

local MORSE = {
  A = ".-", B = "-...", C = "-.-.", D = "-..", E = ".", F = "..-.", G = "--.", H = "....", I = "..",
  J = ".---", K = "-.-", L = ".-..", M = "--", N = "-.", O = "---", P = ".--.", Q = "--.-", R = ".-.",
  S = "...", T = "-", U = "..-", V = "...-", W = ".--", X = "-..-", Y = "-.--", Z = "--..",
  ["0"] = "-----", ["1"] = ".----", ["2"] = "..---", ["3"] = "...--", ["4"] = "....-",
  ["5"] = ".....", ["6"] = "-....", ["7"] = "--...", ["8"] = "---..", ["9"] = "----.",
  ["."] = ".-.-.-", [","] = "--..--", ["?"] = "..--..", ["/"] = "-..-.", ["="] = "-...-",
  ["-"] = "-....-", ["!"] = "-.-.--", ["'"] = ".----.", [":"] = "---...", ["+"] = ".-.-.",
  ["@"] = ".--.-.",
}
local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local TABS = { "Translate", "Practice", "Key" }
local FREQ = 700
local MAX_TEXT = 32

local rev = nil       -- code -> character, built in init
local tab = 1
local wpm = 18
local wpm_text = ""
-- playback queue: a code string stepped through in update()
local qs, qi, qwait = nil, 0, 0
-- translate
local text, code, code_lines = "", "", {}
-- practice
local target, result, next_t = nil, nil, 0
local score, tries, streak, best, best_dirty = 0, 0, 0, 0, false
local score_text = ""
-- key
local sym, out, out_lines, idle, spaced = "", "", {}, 0, true

local function unit() return 1.2 / wpm end   -- seconds per dit (PARIS standard)

local function ms(n) return math.floor(n * unit() * 1000 + 0.5) end

local function play(s)
  if not s or s == "" then return end
  qs, qi, qwait = s, 0, 0
end

local function stop_play()
  qs = nil
  snd.stop()
end

local function retranslate()
  local parts = {}
  for c in text:upper():gmatch(".") do
    if c == " " then
      if #parts > 0 and parts[#parts] ~= "/" then parts[#parts + 1] = "/" end
    elseif MORSE[c] then parts[#parts + 1] = MORSE[c] end
  end
  code = table.concat(parts, " ")
  code_lines = ui.wrap(code, 228)
  if #code_lines > 6 then
    code_lines[6] = code_lines[6]:sub(1, 34) .. " ..."
    for i = #code_lines, 7, -1 do code_lines[i] = nil end
  end
end

local function rescore()
  score_text = string.format("Score %d/%d   Streak %d   Best %d", score, tries, streak, best)
end

local function new_letter()
  local i = math.random(1, #LETTERS)
  target, result, next_t = LETTERS:sub(i, i), nil, 0
  play(MORSE[target])
end

local function answer(c)
  if not target or result then return end
  tries = tries + 1
  if c == target then
    score, streak, result, next_t = score + 1, streak + 1, "right", 0.9
    if streak > best then best, best_dirty = streak, true end
  else
    streak, result, next_t = 0, "wrong", 1.8
    shell.sound("error")
  end
  rescore()
end

local function rewrap() out_lines = ui.wrap(out, 220) end

local function key_element(s)
  if #sym >= 7 then return end
  sym = sym .. s
  idle = 0
  snd.tone(FREQ, ms(s == "." and 1 or 3))
end

function app.init(args, saved)
  rev = {}
  for ch, c in pairs(MORSE) do rev[c] = ch end
  tab = saved and saved.tab or 1
  wpm = math.max(5, math.min(30, tonumber(cfg.get("morse_wpm")) or 18))
  wpm_text = wpm .. " WPM"
  best = tonumber(cfg.get("morse_best")) or 0
  text, qs = "", nil
  target, result, score, tries, streak = nil, nil, 0, 0, 0
  sym, out, idle, spaced = "", "", 0, true
  retranslate()
  rewrap()
  rescore()
end

function app.update(dt)
  -- sound queue
  if qs then
    qwait = qwait - dt
    if qwait <= 0 then
      if qwait < -unit() then qwait = 0 end  -- a long frame: don't rush to catch up
      qi = qi + 1
      local c = qs:sub(qi, qi)
      local u = unit()
      if c == "" then qs = nil
      elseif c == "." then snd.tone(FREQ, ms(1)); qwait = qwait + 2 * u
      elseif c == "-" then snd.tone(FREQ, ms(3)); qwait = qwait + 4 * u
      else qwait = qwait + 2 * u end   -- " " letter gap, "/" adds the word gap
    end
  end
  -- practice: next letter after showing the answer
  if tab == 2 and result then
    next_t = next_t - dt
    if next_t <= 0 then new_letter() end
  end
  -- key: decode after a pause
  if tab == 3 then
    idle = idle + dt
    if sym ~= "" then
      if idle >= math.max(0.8, 7 * unit()) then
        out = (out .. (rev[sym] or "?")):sub(-MAX_TEXT * 3)
        sym, idle, spaced = "", 0, false
        rewrap()
      end
    elseif not spaced and idle >= 1.6 then
      out, spaced = out .. " ", true
      rewrap()
    end
  end
end

local function draw_translate(y)
  ui.card(4, y, 232, 16, true)
  if text == "" then ui.text(10, y + 4, "Type a message", col.muted)
  else ui.text(10, y + 4, #text > 30 and text:sub(-30) or text, col.text) end
  ui.right(230, y + 4, wpm_text, col.muted)
  for i = 1, #code_lines do ui.text(6, y + 21 + (i - 1) * 10, code_lines[i], col.accent) end
  if qs then ui.bar(6, 116, 228, 4, qi / #qs) end
  ui.footer({ { "Enter", qs and "Stop" or "Play" }, { "Up/Dn", "Speed" }, { "Tab", "Mode" } })
end

local function draw_practice(y)
  if not target then
    ui.empty("morse", "Listen and type the letter", wpm_text)
  else
    local c = result == "right" and col.good or result == "wrong" and col.bad or col.text
    ui.big(y + 6, result and target or "?", c, 4)
    if result then ui.center(y + 44, MORSE[target], col.accent, 2)
    else ui.center(y + 48, qs and "listen..." or "type the letter", col.muted) end
    ui.center(112, score_text, col.muted)
  end
  ui.footer({ { "Enter", target and "Replay" or "Start" }, { "A-Z", "Answer" }, { "Tab", "Mode" } })
end

local function draw_key(y)
  ui.big(y + 6, sym == "" and " " or sym, col.accent, 3)
  ui.center(y + 32, sym == "" and "Space = dit   Enter = dah" or ("= " .. (rev[sym] or "?")), col.muted)
  ui.card(4, y + 44, 232, 44, false)
  if #out_lines == 0 or out == "" then
    ui.text(10, y + 50, "Decoded text appears here", col.muted)
  else
    local first = math.max(1, #out_lines - 3)
    for i = first, #out_lines do ui.text(10, y + 49 + (i - first) * 10, out_lines[i], col.text) end
  end
  ui.footer({ { "Space", "Dit" }, { "Enter", "Dah" }, { "Bksp", "Undo" }, { "Tab", "Mode" } })
end

function app.draw()
  local y = ui.tabs(TABS, tab, 16)
  if tab == 1 then draw_translate(y)
  elseif tab == 2 then draw_practice(y)
  else draw_key(y) end
end

local function set_wpm(d)
  wpm = math.max(5, math.min(30, wpm + d))
  cfg.set("morse_wpm", wpm)
  wpm_text = wpm .. " WPM"
  shell.toast(wpm_text, 1)
end

function app.key(k)
  local name, t = k.key, k.text
  if name == "tab" then
    tab = k.shift and (tab - 2) % #TABS + 1 or tab % #TABS + 1
    sym, idle = "", 0
    return true
  end
  if name == "esc" then return false end
  if name == "up" then set_wpm(1); return true end
  if name == "down" then set_wpm(-1); return true end
  if tab == 1 then
    if name == "enter" then
      if qs then stop_play()
      elseif code == "" then shell.toast("Type something first")
      else play(code) end
    elseif name == "backspace" then text = text:sub(1, -2); retranslate()
    elseif name == "delete" then text = ""; retranslate()
    elseif t and not k.ctrl and not k.fn and #text < MAX_TEXT then
      if t == " " or MORSE[t:upper()] then text = text .. t; retranslate()
      else shell.toast("No Morse code for " .. t) end
    else return false end
  elseif tab == 2 then
    if name == "enter" then
      if target and not result then play(MORSE[target]) else new_letter() end
    elseif t and t:match("^%w$") and not k.ctrl and not k.fn then answer(t:upper())
    else return false end
  else
    if name == "space" or t == " " then key_element(".")
    elseif name == "enter" then key_element("-")
    elseif name == "backspace" then
      if sym ~= "" then sym = sym:sub(1, -2) else out = out:sub(1, -2); rewrap() end
      idle = 0
    elseif name == "delete" then sym, out = "", ""; rewrap()
    else return false end
  end
  return true
end

function app.save() return { tab = tab } end

function app.close()
  snd.stop()
  if best_dirty then cfg.set("morse_best", best) end
  rev, code_lines, out_lines = nil, {}, {}
end

return app
