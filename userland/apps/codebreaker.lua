-- Codebreaker: find the hidden code in ten guesses. After each guess a filled
-- dot means a right digit in the right place, a ring a right digit elsewhere.
local col = ui.col
local app = { title = "Codebreaker", icon = "remote", color = "pink", order = 71, category = "games" }
app.help = {
  { "1-8", "Type a digit" },
  { "Bksp", "Erase a digit" },
  { "Enter", "Check the guess" },
  { "Tab", "Classic / Hard" },
  { "N", "New code" },
  { "M", "Sound on/off" },
  { "Esc", "Home" },
}

local gk = require("gamekit")

-- Classic: 4 digits from 1-6, all different. Hard: 5 digits from 1-8, repeats allowed.
local MODES = {
  { name = "Classic", len = 4, top = 6, repeats = false },
  { name = "Hard", len = 5, top = 8, repeats = true },
}
local TRIES, ROWH, Y0 = 10, 10, 18
local TILE_C = { "red", "orange", "green", "teal", "blue", "purple", "pink" }
local DIGITS = { "1", "2", "3", "4", "5", "6", "7", "8" }

local mode, m, secret, guesses, marks, cur, state
local scores, best, wins
local s_turn, s_best, s_wins, s_msg, s_digits

local function texts()
  s_turn = "Guess " .. math.min(#guesses + 1, TRIES) .. "/" .. TRIES
  s_best = best[mode] and ("Best " .. best[mode]) or "Best -"
  s_wins = "Wins " .. (wins[mode] or 0)
  s_digits = "Digits 1-" .. m.top
  if state == "won" then s_msg = "Cracked in " .. #guesses .. "!"
  elseif state == "lost" then s_msg = "The code was"
  else s_msg = m.repeats and "Digits may repeat" or "No repeats" end
end

local function new_game()
  m = MODES[mode]
  secret = {}
  local pool = {}
  for d = 1, m.top do pool[d] = d end
  for i = 1, m.len do
    if m.repeats then secret[i] = math.random(1, m.top)
    else secret[i] = table.remove(pool, math.random(1, #pool)) end
  end
  guesses, marks, cur, state = {}, {}, {}, "play"
  texts()
end

-- exact: right digit, right place; near: right digit, wrong place
local function score(g)
  local exact, near, cs, cg = 0, 0, {}, {}
  for i = 1, m.len do
    if g[i] == secret[i] then exact = exact + 1
    else
      cs[secret[i]] = (cs[secret[i]] or 0) + 1
      cg[g[i]] = (cg[g[i]] or 0) + 1
    end
  end
  for d, n in pairs(cg) do near = near + math.min(n, cs[d] or 0) end
  return exact, near
end

local function submit()
  if #cur < m.len then shell.toast("Type " .. m.len .. " digits"); return end
  local e, n = score(cur)
  guesses[#guesses + 1] = cur
  marks[#marks + 1] = { e, n }
  cur = {}
  if e == m.len then
    state = "won"
    wins[mode] = (wins[mode] or 0) + 1
    scores["wins_" .. mode] = wins[mode]
    if not best[mode] or #guesses < best[mode] then
      best[mode] = #guesses
      scores["best_" .. mode] = #guesses
    end
    gk.save("codebreaker", scores)
    gk.beep(1047, 150)
  elseif #guesses >= TRIES then
    state = "lost"
    gk.beep(200, 250)
  else
    gk.beep(600, 15)
  end
  texts()
end

function app.init(_, saved)
  math.randomseed(sys.millis())
  scores = gk.load("codebreaker")
  best, wins = {}, {}
  for i = 1, #MODES do
    best[i], wins[i] = tonumber(scores["best_" .. i]), tonumber(scores["wins_" .. i])
  end
  mode = tonumber(scores.mode) or 1
  if not MODES[mode] then mode = 1 end
  new_game()
  -- carry on with the same code after visiting another app
  if saved and saved.mode == mode and type(saved.s) == "string" and #saved.s == m.len then
    for i = 1, m.len do secret[i] = tonumber(saved.s:sub(i, i)) end
    for gs in tostring(saved.g or ""):gmatch("%d+") do
      if #gs == m.len and #guesses < TRIES then
        local g = {}
        for i = 1, m.len do g[i] = tonumber(gs:sub(i, i)) end
        guesses[#guesses + 1] = g
        marks[#marks + 1] = { score(g) }
      end
    end
    texts()
  end
end

function app.save()
  if state ~= "play" then return nil end
  local gs = {}
  for i, g in ipairs(guesses) do gs[i] = table.concat(g) end
  return { mode = mode, s = table.concat(secret), g = table.concat(gs, ",") }
end

local function tiles(x, y, g, n)
  for i = 1, n do
    local d = g[i]
    local tx = x + (i - 1) * 11
    if d then
      gfx.rfill(tx, y, 10, 9, 2, d <= #TILE_C and ui.accents[TILE_C[d]] or col.muted)
      gfx.text(tx + 2, y + 1, DIGITS[d], col.on_accent)
    else
      gfx.rrect(tx, y, 10, 9, 2, col.line)
    end
  end
end

function app.draw()
  local n = m.len
  for r = 1, TRIES do
    local y = Y0 + (r - 1) * ROWH
    local g = guesses[r]
    if g then
      tiles(6, y, g, n)
      local e, nr = marks[r][1], marks[r][2]
      local px = 6 + n * 11 + 4
      for k = 1, n do
        local dx = px + (k - 1) * 7
        if k <= e then gfx.disc(dx + 3, y + 4, 2, col.text)
        elseif k <= e + nr then gfx.circle(dx + 3, y + 4, 2, col.text)
        else gfx.fill(dx + 2, y + 4, 2, 1, col.line) end
      end
    elseif r == #guesses + 1 and state == "play" then
      tiles(6, y, cur, n)
    else
      for k = 1, n do gfx.fill(6 + (k - 1) * 11 + 4, y + 4, 2, 1, col.line) end
    end
  end
  local x = 130
  ui.text(x, 20, m.name, col.accent)
  ui.right(236, 20, s_turn, col.muted)
  ui.text(x, 34, s_best, col.muted)
  ui.right(236, 34, s_wins, col.muted)
  ui.text(x, 52, s_msg, state == "won" and col.good or (state == "lost" and col.bad or col.muted))
  if state == "lost" then tiles(x, 66, secret, n) end
  if state == "play" then
    ui.text(x, 70, s_digits, col.muted)
    ui.footer({ { "Enter", "Check" }, { "Bksp", "Erase" }, { "Tab", "Mode" } })
  else
    ui.footer({ { "Enter", "New code" }, { "Tab", "Mode" }, { "Esc", "Home" } })
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if c == "m" then gk.toggle_sound(); return true end
  if k.key == "tab" then
    mode = mode % #MODES + 1
    scores.mode = mode
    gk.save("codebreaker", scores)
    new_game()
    return true
  end
  if c == "n" then new_game(); return true end
  if state ~= "play" then
    if k.key == "enter" then new_game(); return true end
    return false
  end
  if k.key == "enter" then submit()
  elseif k.key == "backspace" or k.key == "delete" then table.remove(cur)
  elseif c and c:match("^%d$") then
    local d = tonumber(c)
    if d < 1 or d > m.top then shell.toast("Digits 1 to " .. m.top); return true end
    if #cur < m.len then cur[#cur + 1] = d end
  else return false end
  return true
end

function app.close()
  guesses, marks, secret, scores = nil, nil, nil, nil
end

return app
