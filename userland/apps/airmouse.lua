-- Air Mouse: turn the Cardputer to move the computer's pointer (USB mouse).
-- Hold it flat like a remote, IR window forward: turning left/right moves the
-- pointer sideways, tilting the front up/down moves it up/down.
-- The gyro axes relative to the case are unverified: A picks the axis pair,
-- S swaps them, X / Y invert them. These choices are remembered.
local col = ui.col

local app = { title = "Air Mouse", icon = "mouse", color = "purple", order = 34, category = "net" }
app.help = {
  { "Enter", "Left click" },
  { "R", "Right click" },
  { "Tab", "Drag on / off" },
  { ";.", "Scroll wheel" },
  { "-=", "Sensitivity" },
  { "C", "Recalibrate" },
  { "P", "Pause" },
  { "A", "Cycle axes" },
  { "S", "Swap axes" },
  { "X/Y", "Invert X / Y" },
}

local AXES = { { "gz", "gx" }, { "gz", "gy" }, { "gx", "gy" } }  -- { sideways, up/down }
local DEAD = 3        -- deg/s ignored (hand tremor and drift)
local GAIN = 0.6      -- pixels per degree at speed 1

local mouse_on, usb_up, status_t = false, true, 0
local sens, axes, swap, inv_x, inv_y = 5, 1, false, false, false
local bias = { gx = 0, gy = 0, gz = 0 }
local calib           -- { t, n, gx, gy, gz } while calibrating
local paused, drag = false, false
local acc_x, acc_y, vx, vy = 0, 0, 0, 0
local axis_s, sens_s = "", ""

local function texts()
  local a = AXES[axes]
  local h, v = a[1], a[2]
  if swap then h, v = v, h end
  axis_s = string.format("X %s%s   Y %s%s", inv_x and "+" or "-", h, inv_y and "+" or "-", v)
  sens_s = tostring(sens)
end

local function save()
  cfg.set("am_sens", sens)
  cfg.set("am_axes", axes)
  cfg.set("am_flags", (swap and "s" or "") .. (inv_x and "x" or "") .. (inv_y and "y" or ""))
  texts()
end

local function recalibrate()
  calib = { t = 0, n = 0, gx = 0, gy = 0, gz = 0 }
  acc_x, acc_y = 0, 0
end

function app.init()
  sens = math.max(1, math.min(10, tonumber(cfg.get("am_sens")) or 5))
  axes = tonumber(cfg.get("am_axes")) or 1
  if not AXES[axes] then axes = 1 end
  local f = cfg.get("am_flags") or ""
  swap, inv_x, inv_y = f:find("s") ~= nil, f:find("x") ~= nil, f:find("y") ~= nil
  paused, drag, status_t = false, false, 0
  texts()
  recalibrate()
end

-- Rate past the dead zone, so slow turns still start smoothly from zero.
local function dz(r)
  if r > DEAD then return r - DEAD elseif r < -DEAD then return r + DEAD end
  return 0
end

local function whole(a)
  local n = a >= 0 and math.floor(a) or -math.floor(-a)
  return math.max(-127, math.min(127, n))
end

function app.update(dt)
  status_t = status_t - dt
  if status_t <= 0 then
    status_t = 1
    local st = usb.status()
    mouse_on, usb_up = st.mouse and true or false, st.connected ~= false
  end
  if not mouse_on then return end
  local g = imu.read()
  if not g then return end
  vx, vy = 0, 0
  if calib then
    calib.t, calib.n = calib.t + dt, calib.n + 1
    calib.gx, calib.gy, calib.gz = calib.gx + g.gx, calib.gy + g.gy, calib.gz + g.gz
    if calib.t >= 1 then
      bias = { gx = calib.gx / calib.n, gy = calib.gy / calib.n, gz = calib.gz / calib.n }
      calib = nil
      shell.toast("Calibrated")
    end
    return
  end
  if paused then return end
  local a = AXES[axes]
  local h, v = g[a[1]] - bias[a[1]], g[a[2]] - bias[a[2]]
  if swap then h, v = v, h end
  -- Right-hand rule: turning right and tilting up give negative rates.
  if not inv_x then h = -h end
  if not inv_y then v = -v end
  local gain = sens * GAIN * dt
  acc_x, acc_y = acc_x + dz(h) * gain, acc_y + dz(v) * gain
  local mx, my = whole(acc_x), whole(acc_y)
  acc_x, acc_y = acc_x - mx, acc_y - my
  vx, vy = mx, my
  if mx ~= 0 or my ~= 0 then usb.mouse_move(mx, my) end
end

function app.draw()
  if not mouse_on then
    ui.empty("mouse", "USB mouse is off", "Settings > USB > Mouse, then reboot")
    ui.footer({ { "Esc", "Home" } })
    return
  end
  local s, c = "Active", col.good
  if calib then s, c = "Hold still...", col.warn
  elseif paused then s, c = "Paused", col.muted
  elseif not usb_up then s, c = "USB not connected", col.warn end
  ui.big(18, s, c, 2)
  ui.title(6, 42, "SPEED")
  ui.bar(48, 43, 110, 6, sens / 10)
  ui.text(164, 42, sens_s, col.text)
  ui.title(6, 56, "DRAG")
  ui.switch(48, 55, drag)
  ui.title(6, 70, "AXES")
  ui.text(48, 70, axis_s, col.text)
  -- live movement
  gfx.rrect(196, 38, 36, 36, 4, col.line)
  local dx, dy = math.max(-15, math.min(15, vx)), math.max(-15, math.min(15, vy))
  gfx.disc(214 + dx, 56 + dy, 3, col.accent)
  ui.center(88, "Arrows scroll  C recalibrate  P pause", col.muted)
  ui.center(100, "+/- speed  A axes  S swap  X/Y invert", col.muted)
  ui.footer({ { "Enter", "Click" }, { "R", "Right" }, { "Tab", "Drag" }, { "Esc", "Home" } })
end

function app.key(k)
  if not mouse_on then return false end
  local d = ui.nav(k)
  local c = not k.ctrl and not k.fn and k.text
  if k.key == "enter" or k.key == "space" then usb.mouse_click("left")
  elseif c == "r" then usb.mouse_click("right")
  elseif k.key == "tab" then
    drag = not drag
    usb.mouse_press("left", drag)
    shell.toast(drag and "Dragging (Tab releases)" or "Released")
  elseif d == "up" then usb.mouse_move(0, 0, 1)
  elseif d == "down" then usb.mouse_move(0, 0, -1)
  elseif c == "=" or c == "+" then sens = math.min(10, sens + 1); save()
  elseif c == "-" then sens = math.max(1, sens - 1); save()
  elseif c == "c" then recalibrate()
  elseif c == "p" then paused = not paused; acc_x, acc_y = 0, 0
  elseif c == "a" then axes = axes % #AXES + 1; save(); shell.toast("Axes " .. axis_s)
  elseif c == "s" then swap = not swap; save()
  elseif c == "x" then inv_x = not inv_x; save()
  elseif c == "y" then inv_y = not inv_y; save()
  else return false end
  return true
end

function app.close()
  if drag then usb.mouse_press("left", false) end
  drag, calib = false, nil
end

return app
