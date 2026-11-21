-- Hop: a one-key runner. Jump over blocks and pits (press again in the air
-- for a second jump), land on blocks, grab coins. It keeps getting faster.
local col = ui.col
local app = { title = "Hop", icon = "steps", color = "purple", order = 72, category = "games" }
app.help = {
  { "Space", "Jump (twice: higher)" },
  { "Up/W", "Jump" },
  { "P", "Pause" },
  { "M", "Sound on/off" },
  { "Enter", "Start / play again" },
  { "Esc", "Home" },
}

local gk = require("gamekit")

local G, PX, PS = 112, 36, 8      -- ground top, player left edge and size
local GRAV, JUMP, JUMP2 = 640, -215, -180
local MAXN = 16                   -- most things on screen at once

local things        -- { kind = "block"/"pit"/"coin", x =, w =, h = (or y for coins) }
local py, vy, grounded, jumps
local dist, coins, speed, gap, score, best, scores
local state          -- "ready", "play", "pause", "over"
local hills          -- background dots: x positions
local s_score, s_best, s_big

local function texts()
  s_score, s_best, s_big = "Score " .. score, "Best " .. best, tostring(score)
end

local function new_game()
  things, hills = {}, {}
  for i = 1, 8 do hills[i] = i * 30 end
  py, vy, grounded, jumps = G - PS, 0, true, 0
  dist, coins, speed, gap, score = 0, 0, 70, 120, 0
  state = "ready"
  texts()
end

local function add(kind, x, w, h)
  if #things < MAXN then things[#things + 1] = { kind = kind, x = x, w = w, h = h } end
end

-- The next obstacle pattern, starting at x.
local function spawn(x)
  local r = math.random(1, 10)
  local hard = math.min(1, dist / 6000)
  if r <= 4 then
    local h = math.random(8, 14 + math.floor(hard * 8))
    add("block", x, math.random(6, 12), h)
    if math.random(1, 3) == 1 then add("coin", x + 4, 0, G - h - 22) end
  elseif r <= 6 then
    add("pit", x, math.random(14, 22 + math.floor(hard * 10)), 0)
    add("coin", x + 8, 0, G - 34)
  elseif r <= 8 then  -- two blocks close together
    local h = math.random(8, 12)
    add("block", x, 8, h)
    add("block", x + 28 + math.random(0, 10), 8, h + math.random(0, 6))
  else                -- a tall block to land on, or jump twice over
    local h = math.random(18, 24)
    add("block", x, 14, h)
    add("coin", x + 5, 0, G - h - 16)
  end
end

local function jump()
  if grounded then
    vy, grounded, jumps = JUMP, false, 1
    gk.beep(700, 15)
  elseif jumps < 2 then
    vy, jumps = JUMP2, 2
    gk.beep(900, 15)
  end
end

local function game_over()
  state = "over"
  if score > best then
    best = score
    scores.best = best
    gk.save("hop", scores)
  end
  gk.beep(160, 300)
  texts()
end

local function over_pit()
  local cx = PX + PS // 2
  for _, t in ipairs(things) do
    if t.kind == "pit" and cx > t.x + 1 and cx < t.x + t.w - 1 then return true end
  end
  return false
end

function app.init()
  math.randomseed(sys.millis())
  scores = gk.load("hop")
  best = tonumber(scores.best) or 0
  new_game()
end

function app.update(dt)
  if state ~= "play" then return end
  if dt > 0.05 then dt = 0.05 end
  local dx = speed * dt
  dist = dist + dx
  speed = math.min(170, 70 + dist / 70)
  -- move the world
  local last = 0
  local i = 1
  while i <= #things do
    local t = things[i]
    t.x = t.x - dx
    if t.x + t.w < 0 and t.kind ~= "coin" or t.kind == "coin" and t.x < -6 then
      table.remove(things, i)
    else
      if t.x + t.w > last then last = t.x + t.w end
      i = i + 1
    end
  end
  for k = 1, #hills do
    hills[k] = hills[k] - dx * 0.3
    if hills[k] < 0 then hills[k] = hills[k] + 240 end
  end
  if last < 240 - gap then
    spawn(244)
    gap = math.random(70, 130) + math.floor(speed * 0.4)
  end
  -- move the player
  local feet0 = py + PS
  vy = vy + GRAV * dt
  py = py + vy * dt
  local feet = py + PS
  grounded = false
  if feet >= G and feet0 <= G + 1 and not over_pit() then
    py, vy, grounded, jumps = G - PS, 0, true, 0
  end
  for _, t in ipairs(things) do
    if t.kind == "block" and PX + PS > t.x and PX < t.x + t.w then
      local top = G - t.h
      if feet > top then
        if vy >= 0 and feet0 <= top + 2 then
          py, vy, grounded, jumps = top - PS, 0, true, 0   -- landed on it
        else
          game_over()
          return
        end
      end
    end
  end
  for k = #things, 1, -1 do
    local t = things[k]
    if t.kind == "coin" and math.abs(t.x + 2 - (PX + 4)) < 7 and math.abs(t.h - (py + 4)) < 8 then
      table.remove(things, k)
      coins = coins + 1
      gk.beep(1319, 20)
    end
  end
  if py > G + 10 then game_over(); return end
  local s = math.floor(dist / 10) + coins * 10
  if s ~= score then score = s; texts() end
end

function app.draw()
  ui.text(4, 17, s_score, col.text)
  ui.right(236, 17, s_best, col.muted)
  for k = 1, #hills do gfx.fill(math.floor(hills[k]), 60 + (k * 7) % 20, 2, 2, col.line) end
  -- ground, with the pits cut out (things are kept in order of x)
  local x = 0
  for _, p in ipairs(things) do
    if p.kind == "pit" then
      local px = math.floor(p.x)
      if px > x then gfx.fill(x, G, px - x, 2, col.muted) end
      x = math.max(x, px + p.w)
    end
  end
  if x < 240 then gfx.fill(x, G, 240 - x, 2, col.muted) end
  for _, t in ipairs(things) do
    local tx = math.floor(t.x)
    if t.kind == "block" then
      gfx.fill(tx, G - t.h, t.w, t.h, col.surface2)
      gfx.fill(tx, G - t.h, t.w, 2, col.warn)
    elseif t.kind == "coin" then
      gfx.disc(tx + 2, t.h, 2, col.warn)
    end
  end
  local y = math.floor(py)
  gfx.fill(PX, y, PS, PS, col.accent)
  gfx.fill(PX + 5, y + 2, 2, 2, col.bg)
  if state == "ready" then
    ui.center(44, "Space to jump", col.text, 2)
    ui.center(64, "Press again in the air", col.muted)
    ui.center(74, "for a second jump", col.muted)
    ui.footer({ { "Space", "Start" }, { "Esc", "Home" } })
  elseif state == "pause" then
    ui.box(60, 44, 120, 36)
    ui.center(54, "Paused", col.text, 2)
    ui.footer({ { "P", "Resume" }, { "Esc", "Home" } })
  elseif state == "over" then
    ui.box(50, 30, 140, 64)
    ui.center(36, "Game over", col.muted)
    ui.big(48, s_big, col.accent, 3)
    ui.center(78, score >= best and score > 0 and "New best!" or s_best, score >= best and col.good or col.muted)
    ui.footer({ { "Enter", "Again" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Space", "Jump" }, { "P", "Pause" }, { "Esc", "Home" } })
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  local c = k.text and not k.ctrl and not k.fn and k.text:lower()
  if c == "m" then gk.toggle_sound(); return true end
  local up = c == " " or c == "w" or ui.nav(k) == "up"
  if state == "over" then
    if k.key == "enter" then new_game(); return true end
    return false
  end
  if c == "p" and (state == "play" or state == "pause") then
    state = state == "play" and "pause" or "play"
    return true
  end
  if state == "ready" and (up or k.key == "enter") then
    state = "play"
    jump()
    return true
  end
  if state == "play" and (up or k.key == "enter") then jump(); return true end
  return up
end

function app.close()
  things, hills, scores = nil, nil, nil
end

return app
