-- UI toolkit: the PocketLua look. Every app draws with these pieces so the whole
-- system follows one theme; see docs/UI.md for the rules.
--
-- Screen: 240x135. Status bar y 0-13, content y 16-122, footer y 125-134.
-- Colours come from ui.col, filled from the active theme plus the accent.
local ui = {}
_G.ui = ui

local C = gfx.rgb
ui.W, ui.H = gfx.w, gfx.h
ui.BAR = 14      -- status bar height; apps draw below this
ui.TOP = 16      -- first content row
ui.BOTTOM = 124  -- apps draw above the footer

-- ---------------------------------------------------------------- theme
ui.accents = {
  blue = C(64, 140, 255), teal = C(40, 200, 180), green = C(80, 200, 100),
  orange = C(255, 150, 50), purple = C(170, 110, 255), pink = C(255, 100, 160), red = C(240, 80, 80),
}
ui.accent_names = { "blue", "teal", "green", "orange", "purple", "pink", "red" }

-- Each theme gives the base colours; the accent is chosen separately.
--   bg: screen  surface: cards, bars  surface2: raised/selected  line: dividers
--   text / muted: primary and secondary text
ui.themes = {
  slate    = { bg = { 12, 14, 20 }, surface = { 24, 28, 38 }, surface2 = { 38, 44, 60 }, line = { 54, 62, 82 },
               text = { 232, 236, 244 }, muted = { 130, 138, 156 } },
  midnight = { bg = { 0, 0, 0 }, surface = { 14, 16, 24 }, surface2 = { 30, 34, 48 }, line = { 44, 50, 66 },
               text = { 220, 226, 240 }, muted = { 110, 118, 140 } },
  paper    = { bg = { 236, 234, 226 }, surface = { 250, 249, 244 }, surface2 = { 214, 212, 204 }, line = { 190, 188, 180 },
               text = { 30, 32, 38 }, muted = { 100, 102, 110 } },
  terminal = { bg = { 0, 8, 2 }, surface = { 6, 22, 10 }, surface2 = { 12, 40, 18 }, line = { 20, 70, 30 },
               text = { 160, 255, 170 }, muted = { 70, 150, 90 } },
  sunset   = { bg = { 24, 12, 20 }, surface = { 40, 22, 32 }, surface2 = { 60, 32, 46 }, line = { 84, 46, 62 },
               text = { 255, 232, 220 }, muted = { 186, 140, 140 } },
}
ui.theme_names = { "slate", "midnight", "paper", "terminal", "sunset" }

-- Semantic colours. The old names (panel, panel2, dim, bar) are kept as
-- aliases so older apps keep working; new code uses the new names.
ui.col = { good = C(90, 210, 120), warn = C(255, 190, 60), bad = C(240, 90, 90), white = C(255, 255, 255) }
local col = ui.col

local function apply()
  local t = ui.themes[ui.theme] or ui.themes.slate
  for k, v in pairs(t) do col[k] = C(v[1], v[2], v[3]) end
  col.accent = ui.accents[ui.accent] or ui.accents.blue
  col.on_accent = ui.theme == "paper" and C(255, 255, 255) or col.bg
  col.panel, col.panel2, col.dim, col.bar = col.surface, col.surface2, col.muted, col.surface
end

ui.theme, ui.accent = "slate", "blue"
apply()

function ui.set_theme(name) ui.theme = ui.themes[name] and name or "slate"; apply() end
function ui.set_accent(name) ui.accent = ui.accents[name] and name or "blue"; apply() end

-- Filled in by the shell once a second.
ui.status = { pct = 0, charging = false, wifi = 0, wifi_on = false, time = nil, unread = 0 }

-- ---------------------------------------------------------------- bands
-- The screen is drawn in horizontal bands (draw() runs once per band). Skip
-- anything outside the current one: ui.visible(y, h).
gfx.band_y, gfx.band_h = gfx.band_y or 0, gfx.band_h or ui.H
function ui.visible(y, h)
  local by = gfx.band_y
  return y + h > by and y < by + gfx.band_h
end
local visible = ui.visible

-- ---------------------------------------------------------------- text
function ui.text(x, y, s, c, size)
  size = size or 1
  if visible(y, 8 * size) then gfx.text(x, y, s, c or col.text, size) end
end

function ui.center(y, s, c, size)
  size = size or 1
  if visible(y, 8 * size) then gfx.text(math.floor((ui.W - #s * 6 * size) / 2), y, s, c or col.text, size) end
end

function ui.right(x, y, s, c, size)
  size = size or 1
  if visible(y, 8 * size) then gfx.text(x - #s * 6 * size, y, s, c or col.text, size) end
end

function ui.fit(s, maxw, size)
  local n = math.floor(maxw / (6 * (size or 1)))
  if #s > n then return s:sub(1, math.max(n - 2, 0)) .. ".." end
  return s
end

function ui.wrap(s, maxw, size)
  local cols = math.max(1, math.floor(maxw / (6 * (size or 1))))
  local out = {}
  for para in (tostring(s) .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for w in para:gmatch("%S+") do
      local word = w
      while #word > cols do
        if #line > 0 then out[#out + 1] = line; line = "" end
        out[#out + 1] = word:sub(1, cols)
        word = word:sub(cols + 1)
      end
      if #line == 0 then line = word
      elseif #line + 1 + #word <= cols then line = line .. " " .. word
      else out[#out + 1] = line; line = word end
    end
    out[#out + 1] = line
  end
  return out
end

-- Section heading inside the content area.
function ui.title(x, y, s) gfx.text(x, y, s, col.muted, 1) end

-- Large centred text, e.g. a clock or a result. size 2-4.
function ui.big(y, s, c, size) ui.center(y, s, c or col.text, size or 3) end

-- ---------------------------------------------------------------- footer
-- Footer with keycap hints: ui.footer({ {"Enter", "Open"}, {"Esc", "Back"} }).
function ui.footer(hints)
  if not visible(124, 11) then return end
  gfx.fill(0, 124, ui.W, 11, col.bg)
  local x = 3
  for _, h in ipairs(hints) do
    local k, label = h[1], h[2]
    local kw = #k * 6 + 4
    if x + kw + #label * 6 + 4 > ui.W then break end
    gfx.rfill(x, 125, kw, 10, 2, col.surface2)
    gfx.text(x + 2, 126, k, col.text)
    gfx.text(x + kw + 3, 126, label, col.muted)
    x = x + kw + #label * 6 + 10
  end
end

-- Plain one-line footer (older apps).
function ui.hint(s)
  if not visible(124, 11) then return end
  gfx.fill(0, 124, ui.W, 11, col.bg)
  gfx.text(4, 126, s, col.muted)
end

-- ---------------------------------------------------------------- input
local NAV = { [";"] = "up", ["."] = "down", [","] = "left", ["/"] = "right" }
-- Direction for arrow keys, also accepting the bare ; . , / keys. Use only
-- where the screen does not take typed text.
function ui.nav(k)
  if k.key == "up" or k.key == "down" or k.key == "left" or k.key == "right" then return k.key end
  if k.text and not k.ctrl and not k.fn then return NAV[k.text] end
end

-- ---------------------------------------------------------------- shapes
function ui.box(x, y, w, h)
  gfx.rfill(x, y, w, h, 6, col.surface)
  gfx.rrect(x, y, w, h, 6, col.accent)
end

-- A card: surface panel; selected cards get an accent outline.
function ui.card(x, y, w, h, selected)
  gfx.rfill(x, y, w, h, 5, selected and col.surface2 or col.surface)
  if selected then gfx.rrect(x, y, w, h, 5, col.accent) end
end

function ui.badge(x, y, size, letter, color)
  gfx.rfill(x, y, size, size, 3, color)
  gfx.text(x + math.floor((size - 6) / 2), y + math.floor((size - 8) / 2), letter, col.white)
end

function ui.switch(x, y, on)
  gfx.rfill(x, y, 22, 10, 5, on and col.accent or col.surface2)
  gfx.disc(on and x + 17 or x + 5, y + 5, 3, on and col.on_accent or col.muted)
end

function ui.bar(x, y, w, h, frac, color)
  frac = math.max(0, math.min(1, frac))
  gfx.rfill(x, y, w, h, math.floor(h / 2), col.surface2)
  if frac > 0 then gfx.rfill(x, y, math.max(h, math.floor(w * frac)), h, math.floor(h / 2), color or col.accent) end
end

function ui.button(x, y, label, focused)
  local w = #label * 6 + 12
  gfx.rfill(x, y, w, 14, 4, focused and col.accent or col.surface2)
  gfx.text(x + 6, y + 3, label, focused and col.on_accent or col.text)
  return w
end

-- Segmented tabs across the content top: returns the y below them.
function ui.tabs(labels, active, y)
  y = y or ui.TOP
  local n = #labels
  local w = math.floor((ui.W - 8) / n)
  gfx.rfill(4, y, w * n, 13, 4, col.surface)
  for i, l in ipairs(labels) do
    local x = 4 + (i - 1) * w
    if i == active then gfx.rfill(x + 1, y + 1, w - 2, 11, 3, col.accent) end
    local s = ui.fit(l, w - 4)
    gfx.text(x + math.floor((w - #s * 6) / 2), y + 3, s, i == active and col.on_accent or col.muted)
  end
  return y + 16
end

-- Empty / disabled state: an icon and two lines, centred.
function ui.empty(icon, line1, line2)
  ui.icon(icon or "warn", 120, 50, col.muted, col.bg)
  ui.center(68, line1 or "", col.text)
  if line2 then ui.center(80, line2, col.muted) end
end

-- ---------------------------------------------------------------- status bar
function ui.statusbar(title)
  if not visible(0, ui.BAR) then return end
  local S = ui.status
  gfx.fill(0, 0, ui.W, ui.BAR, col.surface)

  local bx = 216
  local pct = S.pct or 0
  local bc = S.charging and col.good or (pct <= 15 and col.bad or col.text)
  gfx.rrect(bx, 3, 19, 8, 2, bc)
  gfx.fill(bx + 19, 5, 2, 4, bc)
  gfx.fill(bx + 2, 5, math.floor(15 * pct / 100), 4, bc)
  if S.charging then gfx.tri(bx + 10, 2, bx + 6, 8, bx + 11, 8, col.warn) end
  local pt = pct .. "%"
  local px = bx - 3 - #pt * 6
  gfx.text(px, 3, pt, col.muted)

  local tt = S.time or "--:--"
  local tx = px - 7 - #tt * 6
  gfx.text(tx, 3, tt, col.text)

  local left = tx - 4
  if S.wifi_on then
    local wx = tx - 6 - 11
    for i = 1, 4 do
      local h = i * 2
      gfx.fill(wx + (i - 1) * 3, 11 - h, 2, h, i <= (S.wifi or 0) and col.text or col.surface2)
    end
    left = wx - 4
  end
  if (S.unread or 0) > 0 then
    gfx.disc(left - 3, 7, 3, col.accent)
    left = left - 10
  end
  gfx.disc(6, 7, 2, col.accent)
  gfx.text(12, 3, ui.fit(title or "", left - 12), col.text)
end

-- ---------------------------------------------------------------- icons
-- Icons live in lib/icons.lua and load on first use.
function ui.icon(name, x, y, fg, bg)
  local ok, icons = pcall(require, "icons")
  if not ok then return end  -- e.g. out of memory: skip the picture, keep the screen
  icons.draw(name, x, y, fg or col.white, bg)
end

-- A rounded app tile with its icon, `size` pixels square, top-left at (x, y).
function ui.tile(x, y, size, name, color)
  if not visible(y, size) then return end
  gfx.rfill(x, y, size, size, math.floor(size / 4), color)
  ui.icon(name, x + math.floor(size / 2), y + math.floor(size / 2), col.white, color)
end

-- ---------------------------------------------------------------- lists
-- rows: { {label=, value=, badge=letter, badge_color=, dim=bool, switch=bool|nil}, ... }
-- The selected row is raised with an accent bar. Returns the (possibly adjusted)
-- top row so the caller can keep scrolling state.
function ui.list(rows, sel, top, x, y, w, rowh, nrows)
  if sel < top then top = sel elseif sel > top + nrows - 1 then top = sel - nrows + 1 end
  top = math.max(1, top)
  for i = 0, nrows - 1 do
    local r = rows[top + i]
    if not r then break end
    if type(r) == "string" then r = { label = r } end  -- plain-string rows, as in uikit.cpp
    local ry = y + i * rowh
    if not visible(ry, rowh) then goto continue end
    local on = (top + i) == sel
    if on then
      gfx.rfill(x, ry, w, rowh - 1, 4, col.surface2)
      gfx.rfill(x, ry + 2, 3, rowh - 5, 1, col.accent)
    end
    local fg = r.dim and col.muted or col.text
    local tx = x + 7
    if r.badge then
      ui.badge(x + 6, ry + math.floor((rowh - 13) / 2), 13, r.badge, r.badge_color or col.surface2)
      tx = x + 24
    end
    local ty = ry + math.floor((rowh - 9) / 2)
    local right_w = 0
    if r.switch ~= nil then
      ui.switch(x + w - 28, ry + math.floor((rowh - 11) / 2), r.switch)
      right_w = 30
    elseif r.value then
      local v = ui.fit(tostring(r.value), math.floor(w * 0.45))
      gfx.text(x + w - 6 - #v * 6, ty, v, on and col.accent or col.muted)
      right_w = #v * 6 + 10
    end
    gfx.text(tx, ty, ui.fit(r.label, w - (tx - x) - right_w - 2), fg)
    ::continue::
  end
  if #rows > nrows then
    local bh = math.max(6, math.floor((nrows * rowh) * nrows / #rows))
    local by = y + math.floor((nrows * rowh - bh) * (top - 1) / math.max(1, #rows - nrows))
    gfx.fill(x + w + 1, by, 2, bh, col.line)
  end
  return top
end

return ui
