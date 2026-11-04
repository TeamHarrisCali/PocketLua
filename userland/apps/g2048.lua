-- 2048: slide the tiles, merge equal numbers, reach 2048. N starts over.
local col = ui.col
local app = { title = "2048", icon = "grid", color = "orange", order = 62, category = "games" }

local rules = require("games_2048")
local WASD = { w = "up", a = "left", s = "down", d = "right" }
local ACC = { "orange", "red", "pink", "purple", "blue", "teal", "green" }  -- tiles 16 .. 1024
local TILE, GAP, BX, BY = 24, 2, 6, 18

local board, score, best, won
local state        -- "play", "won" (2048 just reached), "over"
local fills, fgs   -- tile colours by exponent, from the current theme
local labels = {}  -- "2", "4", ... by exponent
local s_score, s_best
local theme_t, theme_a  -- theme the palette was made for

for e = 1, 17 do labels[e] = tostring(1 << e) end

local function blend(a, b, t)
  return gfx.rgb(math.floor(a[1] + (b[1] - a[1]) * t), math.floor(a[2] + (b[2] - a[2]) * t),
    math.floor(a[3] + (b[3] - a[3]) * t))
end

-- Small tiles are shades between the theme's surface and muted colours; bigger
-- ones walk through the accent colours; 2048 and up use the user's accent.
local function make_palette()
  theme_t, theme_a = ui.theme, ui.accent
  local t = ui.themes[ui.theme] or ui.themes.slate
  fills, fgs = {}, {}
  fills[1], fills[2], fills[3] = col.surface2, blend(t.surface2, t.muted, 0.35), blend(t.surface2, t.muted, 0.7)
  for e = 1, 3 do fgs[e] = col.text end
  for i, name in ipairs(ACC) do fills[i + 3], fgs[i + 3] = ui.accents[name], col.on_accent end
  for e = 11, 17 do fills[e], fgs[e] = col.accent, col.on_accent end
end

local function texts()
  s_score, s_best = tostring(score), tostring(best)
end

local function new_game()
  board = {}
  for i = 1, 16 do board[i] = 0 end
  score, won, state = 0, false, "play"
  rules.add_tile(board)
  rules.add_tile(board)
  texts()
end

local function slide(dir)
  local moved, points, top = rules.move(board, dir)
  if not moved then return end
  score = score + points
  if score > best then best = score; cfg.set("2048_best", best) end
  rules.add_tile(board)
  if points > 0 then snd.tone(440 + top * 60, 40) end
  if top >= 11 and not won then
    won, state = true, "won"
    snd.tone(1320, 200)
  elseif not rules.can_move(board) then
    state = "over"
    snd.tone(180, 300)
  end
  texts()
end

function app.init(args, saved)
  math.randomseed(sys.millis())
  best = tonumber(cfg.get("2048_best")) or 0
  make_palette()
  if saved and saved.b then
    board = {}
    for v in saved.b:gmatch("%d+") do board[#board + 1] = tonumber(v) end
    if #board == 16 then
      score, won = saved.s or 0, saved.w or false
      state = rules.can_move(board) and "play" or "over"
      texts()
      return
    end
  end
  new_game()
end

function app.update()
  if theme_t ~= ui.theme or theme_a ~= ui.accent then make_palette() end
end

function app.draw()
  gfx.rfill(BX - 2, BY - 2, 4 * TILE + 5 * GAP, 4 * TILE + 5 * GAP, 4, col.surface)
  for i = 1, 16 do
    local e = board[i]
    local x = BX + ((i - 1) % 4) * (TILE + GAP)
    local y = BY + ((i - 1) // 4) * (TILE + GAP)
    if e == 0 then
      gfx.rfill(x, y, TILE, TILE, 3, col.bg)
    else
      gfx.rfill(x, y, TILE, TILE, 3, fills[e] or col.accent)
      local s = labels[e]
      local size = #s == 1 and 2 or 1
      gfx.text(x + (TILE - #s * 6 * size) // 2 + 1, y + (TILE - 8 * size) // 2 + 1, s, fgs[e] or col.on_accent, size)
    end
  end
  ui.title(124, 20, "SCORE")
  gfx.text(124, 30, s_score, col.accent, 2)
  ui.title(124, 54, "BEST")
  gfx.text(124, 64, s_best, col.text, 2)
  ui.text(124, 92, won and "Keep going!" or "Reach 2048", col.muted)
  if state == "won" then
    ui.box(20, 36, 200, 70)
    ui.big(44, "2048!", col.accent, 3)
    ui.center(76, "You win. Keep playing?", col.text)
    ui.footer({ { "Enter", "Continue" }, { "N", "New" }, { "Esc", "Home" } })
  elseif state == "over" then
    ui.box(30, 34, 180, 74)
    ui.center(40, "No more moves", col.muted)
    ui.big(54, s_score, col.accent, 3)
    ui.center(88, score >= best and score > 0 and "New best!" or "Game over", col.text)
    ui.footer({ { "Enter", "New game" }, { "Esc", "Home" } })
  else
    ui.footer({ { "Arrows", "Slide" }, { "N", "New" }, { "Esc", "Home" } })
  end
end

function app.key(k)
  if k.key == "esc" then return false end
  local t = not k.ctrl and not k.fn and k.text and k.text:lower()
  if state == "won" then
    if k.key == "enter" then state = "play" elseif t == "n" then new_game() end
    return true
  elseif state == "over" then
    if k.key == "enter" or t == "n" then new_game() end
    return true
  end
  if t == "n" then
    shell.confirm("New game?", "This game will be lost.", function(yes) if yes then new_game() end end)
    return true
  end
  local d = ui.nav(k) or (t and WASD[t])
  if d then slide(d); return true end
  return false
end

function app.save()
  if not board then return nil end
  return { b = table.concat(board, ","), s = score, w = won }
end

function app.close()
  board, fills, fgs = nil, nil, nil
  unload("games_2048")
end

return app
