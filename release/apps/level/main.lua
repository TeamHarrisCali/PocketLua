-- Bubble level using the IMU. C zeroes it where the device sits now.
-- The IMU axis directions relative to the screen are unverified: if the
-- bubble moves the wrong way, press F (flip X), G (flip Y) or R (swap axes).
local col = ui.col

local app = { title = "Level", icon = "level", color = "green", order = 20, category = "tools" }
app.help = {
  { "C", "Zero here" },
  { "F/G", "Flip X / Y" },
  { "R", "Swap axes" },
}

local off_x, off_y = 0, 0
local flip_x, flip_y, swap = 1, 1, false
local sx, sy = 0, 0  -- smoothed tilt in degrees

local function tilt()
  local v = imu.read()
  local a, b = v.ax, v.ay
  if swap then a, b = b, a end
  -- small-angle tilt from gravity, degrees
  return math.deg(math.asin(math.max(-1, math.min(1, a)))) * flip_x,
         math.deg(math.asin(math.max(-1, math.min(1, b)))) * flip_y
end

function app.update(dt)
  local tx, ty = tilt()
  local k = math.min(1, dt * 8)
  sx = sx + ((tx - off_x) - sx) * k
  sy = sy + ((ty - off_y) - sy) * k
end

function app.draw()
  local cx, cy, r = 120, 70, 42
  gfx.circle(cx, cy, r, col.panel2)
  gfx.circle(cx, cy, r // 2, col.panel2)
  gfx.line(cx - r, cy, cx + r, cy, col.panel2)
  gfx.line(cx, cy - r, cx, cy + r, col.panel2)
  local bx = math.max(-r, math.min(r, sx * 3))
  local by = math.max(-r, math.min(r, sy * 3))
  local level = math.abs(sx) < 1 and math.abs(sy) < 1
  gfx.disc(cx + bx, cy + by, 7, level and col.good or col.accent)
  ui.text(6, 20, string.format("X %+5.1f", sx), col.text)
  ui.text(6, 32, string.format("Y %+5.1f", sy), col.text)
  if level then ui.center(20, "LEVEL", col.good, 2) end
  ui.footer({ { "C", "Zero" }, { "F/G", "Flip" }, { "R", "Swap" } })
end

function app.key(k)
  if k.text == "c" then
    local tx, ty = tilt()
    off_x, off_y = tx, ty
  elseif k.text == "f" then flip_x = -flip_x
  elseif k.text == "g" then flip_y = -flip_y
  elseif k.text == "r" then swap = not swap
  else return false end
  return true
end

return app
