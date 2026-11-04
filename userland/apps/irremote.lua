-- IR Remote: power, volume, channel and input for Samsung, LG and Sony TVs.
-- The codes are the common ones for each brand; some models use others.
-- Samsung: the IRremote library sends the address as 16 bits. Most Samsung
-- TVs want 0x0707 on the wire; if 0x07 does nothing, press A to switch.
local col = ui.col

local app = { title = "IR Remote", icon = "remote", color = "red", order = 30, category = "net" }

local BRANDS = {
  { id = "samsung", name = "Samsung", proto = "samsung", addr = 0x07,
    codes = { power = 0x02, volup = 0x07, voldn = 0x0B, mute = 0x0F, chup = 0x12, chdn = 0x10, input = 0x01 } },
  { id = "lg", name = "LG", proto = "nec", addr = 0x04,
    codes = { power = 0x08, volup = 0x02, voldn = 0x03, mute = 0x09, chup = 0x00, chdn = 0x01, input = 0x0B } },
  { id = "sony", name = "Sony", proto = "sony", addr = 0x01, bits = 12, repeats = 2,
    codes = { power = 0x15, volup = 0x12, voldn = 0x13, mute = 0x14, chup = 0x10, chdn = 0x11, input = 0x25 } },
}
local LABELS = { "Samsung", "LG", "Sony" }

-- label, code name, direct key (the 8th cell switches brand)
local BTN = {
  { "Power", "power", "p" }, { "Vol+", "volup", "=" }, { "Ch+", "chup", "]" }, { "Input", "input", "i" },
  { "Mute", "mute", "m" }, { "Vol-", "voldn", "-" }, { "Ch-", "chdn", "[" }, { "Brand", nil, "b" },
}
local DIRECT = { p = 1, ["="] = 2, ["+"] = 2, ["]"] = 3, i = 4, m = 5, ["-"] = 6, ["["] = 7, b = 8 }

local brand, sel = 1, 1
local saddr16 = false   -- Samsung: send 0x0707 instead of 0x07
local flash, flash_i, msg = 0, 0, ""
local info = ""

local function brand_info()
  local b = BRANDS[brand]
  local addr = (b.proto == "samsung" and saddr16) and 0x0707 or b.addr
  info = string.format("%s  %s  addr 0x%02X", b.name, b.proto:upper(), addr)
  if b.proto == "samsung" then info = info .. "  A: addr" end
end

local function set_brand(i)
  brand = (i - 1) % #BRANDS + 1
  cfg.set("ir_brand", BRANDS[brand].id)
  brand_info()
end

function app.init()
  brand, sel, flash = 1, 1, 0
  local id = cfg.get("ir_brand")
  for i, b in ipairs(BRANDS) do if b.id == id then brand = i end end
  saddr16 = cfg.get("ir_saddr") == "16"
  brand_info()
end

local function send(i)
  sel = i
  local name = BTN[i][2]
  if not name then set_brand(brand + 1); shell.toast("Brand: " .. BRANDS[brand].name); return end
  local b = BRANDS[brand]
  local addr = (b.proto == "samsung" and saddr16) and 0x0707 or b.addr
  local ok, err
  if b.bits then ok, err = pcall(ir.send, b.proto, addr, b.codes[name], b.repeats or 0, b.bits)
  else ok, err = pcall(ir.send, b.proto, addr, b.codes[name], b.repeats or 0) end
  if not ok then shell.toast("IR failed: " .. tostring(err)); return end
  flash, flash_i, msg = 0.35, i, "Sent " .. BTN[i][1] .. " (" .. b.name .. ")"
end

function app.update(dt)
  if flash > 0 then flash = flash - dt end
end

function app.draw()
  local y0 = ui.tabs(LABELS, brand, ui.TOP) + 2
  for i, b in ipairs(BTN) do
    local c, r = (i - 1) % 4, (i - 1) // 4
    local x, y = 4 + c * 58, y0 + r * 29
    local hot = flash > 0 and flash_i == i
    if hot then gfx.rfill(x, y, 56, 26, 5, col.accent) else ui.card(x, y, 56, 26, i == sel) end
    local fg = hot and col.on_accent or (b[2] and col.text or col.muted)
    gfx.text(x + (56 - #b[1] * 6) // 2, y + 5, b[1], fg)
    gfx.text(x + 25, y + 15, b[3], hot and col.on_accent or col.muted)
  end
  if flash > 0 then ui.center(96, msg, col.good) else ui.center(96, info, col.muted) end
  ui.center(110, "Codes may not match every model", col.muted)
  ui.footer({ { "Enter", "Send" }, { "Tab", "Brand" }, { "Esc", "Home" } })
end

function app.key(k)
  local d = ui.nav(k)
  local row, c = (sel - 1) // 4, (sel - 1) % 4
  if d == "left" then sel = row * 4 + (c + 3) % 4 + 1
  elseif d == "right" then sel = row * 4 + (c + 1) % 4 + 1
  elseif d == "up" or d == "down" then sel = (sel + 3) % 8 + 1
  elseif k.key == "enter" or k.key == "space" then send(sel)
  elseif k.key == "tab" then set_brand(brand + (k.shift and -1 or 1))
  elseif k.text == "a" and not k.ctrl and BRANDS[brand].proto == "samsung" then
    saddr16 = not saddr16
    cfg.set("ir_saddr", saddr16 and "16" or nil)
    brand_info()
    shell.toast(saddr16 and "Samsung address 0x0707" or "Samsung address 0x07")
  elseif k.text and not k.ctrl and not k.fn and DIRECT[k.text] then send(DIRECT[k.text])
  else return false end
  return true
end

return app
