-- Sensors: devices on the Grove I2C port, with live readings for common
-- temperature, humidity and light sensors and a register view for the rest.
-- SHT3x and SHT4x share addresses 0x44/0x45: the type is guessed by asking for
-- an SHT4x serial number; press T in a sensor's view to switch it. Sensors
-- with a driver get no register view: their "registers" are commands (writing
-- 0x00-0x0F to a BH1750 would power it down or reset it).
local col = ui.col

local app = { title = "Sensors", icon = "chip", color = "orange", order = 33, category = "tools" }

local NAMES = {
  [0x23] = "BH1750 light", [0x5C] = "BH1750 light", [0x29] = "VL53L0X distance", [0x38] = "AHT20 temp/hum",
  [0x3C] = "OLED display", [0x40] = "INA219 / HDC1080", [0x44] = "SHT3x/4x temp/hum", [0x45] = "SHT3x/4x temp/hum",
  [0x48] = "ADS1115 ADC", [0x68] = "MPU6886 / RTC", [0x70] = "QMP6988 pressure", [0x76] = "BMP280 / BME280",
  [0x77] = "BMP280 / BME280",
}
local KIND = { [0x23] = "bh1750", [0x5C] = "bh1750", [0x38] = "aht20", [0x44] = "sht", [0x45] = "sht" }
local MAX_DEVS = 16

local devs = {}            -- { addr, name, kind, label, value, big, hum, h, err }
local sel, top = 1, 1
local view = "list"        -- "list", "live" or "regs"
local regs = {}            -- register view lines
local tick, phase = 1, "start"

-- Sensirion CRC-8 (poly 0x31, init 0xFF) over bytes i, i+1; the CRC is byte i+2.
local function crc_ok(s, i)
  local c = 0xFF
  for j = i, i + 1 do
    c = c ~ s:byte(j)
    for _ = 1, 8 do
      if c & 0x80 ~= 0 then c = ((c << 1) ~ 0x31) & 0xFF else c = (c << 1) & 0xFF end
    end
  end
  return c == s:byte(i + 2)
end

local function u16(s, i) return (s:byte(i) << 8) | s:byte(i + 1) end

local function sht_read(d, rh_a, rh_b)
  local s = i2c.read(d.addr, 6)
  if not s or #s < 6 then return "no data" end
  if not (crc_ok(s, 1) and crc_ok(s, 4)) then return "CRC error" end
  d.t = -45 + 175 * u16(s, 1) / 65535
  d.h = math.max(0, math.min(100, rh_a + rh_b * u16(s, 4) / 65535))
end

-- init (once), start (ask for a measurement) and read (~0.1 s later), every second.
local DRV = {
  sht3x = { name = "SHT3x temp/hum",
    start = function(d) return i2c.write(d.addr, "\x2C\x06") end,
    read = function(d) return sht_read(d, 0, 100) end },
  sht4x = { name = "SHT4x temp/hum",
    start = function(d) return i2c.write(d.addr, "\xFD") end,
    read = function(d) return sht_read(d, -6, 125) end },
  -- Not yet known: ask for an SHT4x serial number; a valid reply means SHT4x.
  sht = { init = function(d) i2c.write(d.addr, "\x89") end,
    read = function(d)
      local s = i2c.read(d.addr, 6)
      d.kind = (s and #s == 6 and crc_ok(s, 1) and crc_ok(s, 4)) and "sht4x" or "sht3x"
      return "detecting"
    end },
  bh1750 = { name = "BH1750 light",
    init = function(d) i2c.write(d.addr, "\x10") end,
    read = function(d)
      local s = i2c.read(d.addr, 2)
      if not s or #s < 2 then return "no data" end
      d.lux = u16(s, 1) / 1.2
    end },
  aht20 = { name = "AHT20 temp/hum",
    init = function(d) i2c.write(d.addr, "\xBE\x08\x00") end,
    start = function(d) return i2c.write(d.addr, "\xAC\x33\x00") end,
    read = function(d)
      local s = i2c.read(d.addr, 6)
      if not s or #s < 6 then return "no data" end
      local b = { s:byte(1, 6) }
      if b[1] & 0x80 ~= 0 then return "busy" end
      d.h = ((b[2] << 12) | (b[3] << 4) | (b[4] >> 4)) * 100 / 1048576
      d.t = (((b[4] & 0x0F) << 16) | (b[5] << 8) | b[6]) * 200 / 1048576 - 50
    end },
}

local function label(d)
  local drv = DRV[d.kind]
  d.name = drv and drv.name or NAMES[d.addr] or "Unknown device"
  d.label = string.format("0x%02X  %s", d.addr, d.name)
end

-- Display strings, computed after each reading (never in draw).
local function format(d)
  if d.err then d.value, d.big, d.hum = d.err, nil, nil
  elseif d.lux then d.value = string.format("%.0f lux", d.lux); d.big = d.value
  elseif d.t then
    d.value = string.format("%.1fC %.0f%%", d.t, d.h)
    d.big = string.format("%.1f C", d.t)
    d.hum = string.format("%.0f%%", d.h)
  end
end

local function scan()
  devs, sel, top, view = {}, 1, 1, "list"
  local found = i2c.scan() or {}
  for i = 1, math.min(#found, MAX_DEVS) do
    local a = found[i]
    local d = { addr = a, kind = KIND[a] }
    label(d)
    d.value = d.kind and "..." or "regs"
    devs[#devs + 1] = d
    local drv = DRV[d.kind]
    if drv and drv.init then drv.init(d) end
  end
  tick, phase = 0.9, "start"   -- first reading right away
end

local function read_regs(d)
  local v = {}
  for r = 0, 15 do
    local s = i2c.read_reg(d.addr, r, 1)
    v[r + 1] = s and string.format("%02X", s:byte(1)) or "--"
  end
  regs = {
    string.format("0x%02X  %s", d.addr, d.name),
    "     +0 +1 +2 +3 +4 +5 +6 +7",
    "00:  " .. table.concat(v, " ", 1, 8),
    "08:  " .. table.concat(v, " ", 9, 16),
  }
end

function app.init()
  scan()
end

function app.update(dt)
  tick = tick + dt
  if phase == "start" and tick >= 1 then
    tick, phase = 0, "read"
    for _, d in ipairs(devs) do
      local drv = DRV[d.kind]
      d.waiting = false
      if drv and drv.read then
        d.waiting = true
        if drv.start and not drv.start(d) then d.err, d.waiting = "no reply", false; format(d) end
      end
    end
  elseif phase == "read" and tick >= 0.1 then
    phase = "start"
    for _, d in ipairs(devs) do
      local drv = DRV[d.kind]
      if d.waiting and drv then
        local was = d.kind
        d.err = drv.read(d)
        if d.kind ~= was then label(d) end
        format(d)
      end
    end
  end
end

function app.draw()
  if view == "regs" then
    ui.center(20, regs[1] or "", col.muted)
    ui.text(36, 40, regs[2] or "", col.muted)
    ui.text(36, 56, regs[3] or "", col.text)
    ui.text(36, 70, regs[4] or "", col.text)
    ui.center(92, "One byte per register, 0x00-0x0F", col.muted)
    ui.footer({ { "R", "Reload" }, { "Esc", "Back" } })
    return
  end
  if view == "live" then
    local d = devs[sel]
    ui.center(20, d.label, col.muted)
    ui.big(38, d.big or (d.err or "..."), d.big and col.accent or col.warn, 3)
    if d.hum then
      ui.title(10, 72, "HUMIDITY")
      ui.right(230, 72, d.hum, col.text)
      ui.bar(10, 84, 220, 8, (d.h or 0) / 100)
    end
    if d.err and d.big then ui.center(104, d.err, col.warn) end
    if d.kind == "sht3x" or d.kind == "sht4x" then
      ui.footer({ { "T", "SHT3x/4x" }, { "Esc", "Back" } })
    else
      ui.footer({ { "Esc", "Back" } })
    end
    return
  end
  if #devs == 0 then
    ui.empty("chip", "No I2C devices found", "Plug one into Grove, then press R")
    ui.footer({ { "R", "Rescan" }, { "Esc", "Home" } })
    return
  end
  ui.title(6, 18, "GROVE I2C")
  ui.right(234, 18, #devs == 1 and "1 device" or (#devs .. " devices"), col.muted)
  top = ui.list(devs, sel, top, 4, 29, 228, 17, 5)
  ui.footer({ { "Enter", "Open" }, { "R", "Rescan" }, { "Esc", "Home" } })
end

function app.key(k)
  local d = ui.nav(k)
  local c = not k.ctrl and not k.fn and k.text
  if view ~= "list" then
    local dev = devs[sel]
    if k.key == "esc" then view = "list"
    elseif c == "r" and view == "regs" then read_regs(dev); shell.toast("Registers read")
    elseif c == "t" and view == "live" and (dev.kind == "sht3x" or dev.kind == "sht4x") then
      dev.kind = dev.kind == "sht3x" and "sht4x" or "sht3x"
      dev.t, dev.h, dev.err = nil, nil, nil
      label(dev)
      dev.value, dev.big, dev.hum = "...", nil, nil
      shell.toast("Reading as " .. dev.name)
    else return false end
    return true
  end
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.max(1, math.min(#devs, sel + 1))
  elseif c == "r" then scan(); shell.toast(#devs == 1 and "1 device" or (#devs .. " devices"))
  elseif k.key == "enter" and devs[sel] then
    local dev = devs[sel]
    if dev.kind and DRV[dev.kind] then view = "live" else read_regs(dev); view = "regs" end
  else return false end
  return true
end

function app.close()
  devs, regs = {}, {}
end

return app
