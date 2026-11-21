-- Wordy: find the hidden five-letter word in six tries. Under each letter, a
-- full bar means right letter in the right spot, a short mark means the word
-- has that letter somewhere else. Works offline: the words ship with the app.
local col = ui.col
local app = { title = "Wordy", icon = "book", color = "green", order = 76, category = "games" }
app.help = {
  { "a-z", "Type a letter" },
  { "Bksp", "Erase a letter" },
  { "Enter", "Try the word" },
  { "Ctrl+N", "Give up / new word" },
  { "Ctrl+M", "Sound on/off" },
  { "Esc", "Home" },
}

local gk = require("gamekit")
-- The store installs these with the app (each holds the words for one letter).
-- They are read with sys.loadfile below so only one is in memory at a time.
local _ = false and {
  require("words5/answers"), require("words5/a"), require("words5/b"), require("words5/c"),
  require("words5/d"), require("words5/e"), require("words5/f"), require("words5/g"),
  require("words5/h"), require("words5/i"), require("words5/j"), require("words5/k"),
  require("words5/l"), require("words5/m"), require("words5/n"), require("words5/o"),
  require("words5/p"), require("words5/q"), require("words5/r"), require("words5/s"),
  require("words5/t"), require("words5/u"), require("words5/v"), require("words5/w"),
  require("words5/x"), require("words5/y"), require("words5/z"),
}

local TRIES, LEN = 6, 5
local Y0, ROWH, LX = 17, 17, 8
local ALPHA = "abcdefghijklmnopqrstuvwxyz"

local answer, guesses, marks, cur, state, letter_state
local scores, stats
local s_turn, s_stats, s_msg, s_answer

-- Loads one word list file as a string (or nil), without keeping it cached.
local function words(name)
  local fn = sys.loadfile("lib/words5/" .. name .. ".lua", false, true)
  if not fn then return nil end
  local ok, s = pcall(fn)
  if ok and type(s) == "string" then return s end
end

-- Binary search in a sorted run of five-letter words with no separators.
local function has(list, w)
  local lo, hi = 1, #list // LEN
  while lo <= hi do
    local mid = (lo + hi) // 2
    local v = list:sub((mid - 1) * LEN + 1, mid * LEN)
    if v == w then return true elseif v < w then lo = mid + 1 else hi = mid - 1 end
  end
  return false
end

local function texts()
  s_turn = "Try " .. math.min(#guesses + 1, TRIES) .. "/" .. TRIES
  s_stats = "Won " .. (stats.wins or 0) .. "/" .. (stats.played or 0) .. "  Streak " .. (stats.streak or 0)
  s_answer = answer and answer:upper() or ""
end

-- 2 = right spot, 1 = elsewhere in the word, 0 = not in it.
local function score(g)
  local m, left = {}, {}
  for i = 1, LEN do
    local a, b = answer:sub(i, i), g:sub(i, i)
    if a == b then m[i] = 2 else m[i] = 0; left[a] = (left[a] or 0) + 1 end
  end
  for i = 1, LEN do
    local b = g:sub(i, i)
    if m[i] == 0 and (left[b] or 0) > 0 then m[i] = 1; left[b] = left[b] - 1 end
  end
  return m
end

local function learn(g, m)
  for i = 1, LEN do
    local ch = g:sub(i, i)
    if m[i] > (letter_state[ch] or -1) then letter_state[ch] = m[i] end
  end
end

local function new_word()
  local list = words("answers")
  if not list then
    answer, state = nil, "missing"
    s_msg = "Word list missing"
    return
  end
  local n = #list // LEN
  local i = math.random(1, n)
  answer = list:sub((i - 1) * LEN + 1, i * LEN)
  guesses, marks, cur, letter_state = {}, {}, "", {}
  state, s_msg = "play", ""
  texts()
end

local function save_stats() gk.save("wordy", stats) end

local function finish(won)
  state = won and "won" or "lost"
  stats.played = (tonumber(stats.played) or 0) + 1
  if won then
    stats.wins = (tonumber(stats.wins) or 0) + 1
    stats.streak = (tonumber(stats.streak) or 0) + 1
    if stats.streak > (tonumber(stats.best_streak) or 0) then stats.best_streak = stats.streak end
    local k = "in_" .. #guesses
    stats[k] = (tonumber(stats[k]) or 0) + 1
    s_msg = ({ "Genius!", "Brilliant!", "Great!", "Nice!", "Good!", "Phew!" })[#guesses]
    gk.beep(1047, 150)
  else
    stats.streak = 0
    s_msg = "The word was"
    gk.beep(200, 250)
  end
  save_stats()
  texts()
end

local function submit()
  if #cur < LEN then s_msg = "Type 5 letters"; return end
  local list = words(cur:sub(1, 1))   -- every answer is in these lists too
  if not list then s_msg = "Word list missing"; return end
  local known = has(list, cur)
  list = nil
  if not known then
    s_msg = "Not in the word list"
    gk.beep(200, 40)
    return
  end
  local m = score(cur)
  local won = cur == answer
  guesses[#guesses + 1], marks[#marks + 1] = cur, m
  learn(cur, m)
  cur, s_msg = "", ""
  if won then finish(true)
  elseif #guesses >= TRIES then finish(false)
  else gk.beep(600, 15); texts() end
end

function app.init(_, saved)
  math.randomseed(sys.millis())
  stats = gk.load("wordy")
  for k, v in pairs(stats) do stats[k] = tonumber(v) or v end
  new_word()
  if state == "play" and saved and type(saved.a) == "string" and #saved.a == LEN then
    answer = saved.a
    for g in tostring(saved.g or ""):gmatch("%a+") do
      if #g == LEN and #guesses < TRIES then
        local m = score(g)
        guesses[#guesses + 1], marks[#marks + 1] = g, m
        learn(g, m)
      end
    end
    texts()
  end
end

function app.save()
  if state ~= "play" then return nil end
  return { a = answer, g = table.concat(guesses, ",") }
end

local UPPER = {}
for i = 1, 26 do local ch = ALPHA:sub(i, i); UPPER[ch] = ch:upper() end

function app.draw()
  for r = 1, TRIES do
    local y = Y0 + (r - 1) * ROWH
    local g = guesses[r] or (r == #guesses + 1 and state == "play" and cur) or nil
    local m = marks[r]
    for i = 1, LEN do
      local x = LX + (i - 1) * 16
      local ch = g and g:sub(i, i) or ""
      if ch ~= "" then
        local c = col.text
        if m then c = m[i] == 2 and col.good or (m[i] == 1 and col.warn or col.muted) end
        gfx.text(x, y, UPPER[ch], c, 2)
      end
      if m and m[i] == 2 then gfx.fill(x - 1, y + 15, 13, 2, col.good)
      elseif m and m[i] == 1 then gfx.fill(x + 3, y + 15, 5, 2, col.warn)
      else gfx.fill(x, y + 15, 11, 1, (r == #guesses + 1 and state == "play") and col.accent or col.line) end
    end
  end
  -- letters seen so far
  local ax = 100
  for i = 1, 26 do
    local ch = ALPHA:sub(i, i)
    local s = letter_state and letter_state[ch]
    local c = s == 2 and col.good or (s == 1 and col.warn or (s == 0 and col.line or col.text))
    gfx.text(ax + ((i - 1) % 13) * 10, 20 + ((i - 1) // 13) * 12, UPPER[ch], c)
  end
  ui.text(ax, 50, s_turn, col.muted)
  ui.text(ax, 62, s_stats, col.muted)
  local mc = (state == "won" and col.good) or (state == "lost" and col.bad) or col.warn
  ui.text(ax, 80, s_msg, mc)
  if state == "lost" then ui.text(ax, 94, s_answer, col.text, 2) end
  if state == "play" then
    ui.footer({ { "Enter", "Try" }, { "Bksp", "Erase" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Enter", "New word" }, { "Esc", "Home" } })
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  local c = k.text and k.text:lower()
  if k.ctrl and c == "m" then gk.toggle_sound(); return true end
  if k.ctrl and c == "n" then
    if state == "play" and #guesses > 0 then finish(false) else new_word() end
    return true
  end
  if k.ctrl or k.fn then return false end
  if state ~= "play" then
    if k.key == "enter" then new_word(); return true end
    return false
  end
  if k.key == "enter" then submit()
  elseif k.key == "backspace" then cur = cur:sub(1, -2); s_msg = ""
  elseif c and c:match("^%l$") then
    if #cur < LEN then cur = cur .. c end
  else return false end
  return true
end

function app.close()
  guesses, marks, letter_state, stats = nil, nil, nil, nil
end

return app
