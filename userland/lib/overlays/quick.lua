-- Quick settings (Fn+Q from anywhere): brightness, volume, Wi-Fi, theme,
-- display sleep, notifications, screenshot, Task Manager.
local col = ui.col
local ov = {}
local sel = 1

local SLEEP = { 0, 30, 60, 120, 300, 600 }
local SLEEP_LABEL = { [0] = "Never", [30] = "30 s", [60] = "1 min", [120] = "2 min", [300] = "5 min", [600] = "10 min" }

local function num(k, d) return tonumber(cfg.get(k)) or d end
local function step(list, cur, d)
  local i = 1
  for j, v in ipairs(list) do if v == cur then i = j end end
  return list[(i - 1 + d) % #list + 1]
end

local items = {
  { "Brightness", function() return math.floor(num("bright", 160) * 100 / 255) .. "%" end, function(d)
    local v = math.max(16, math.min(255, num("bright", 160) + d * 32)); cfg.set("bright", v); gfx.brightness(v) end },
  { "Volume", function() return math.floor(num("vol", 100) * 100 / 255) .. "%" end, function(d)
    local v = math.max(0, math.min(255, num("vol", 100) + d * 32)); cfg.set("vol", v); snd.volume(v); snd.tone(880, 60) end },
  { "Wi-Fi", function() return wifi.status() == "off" and "Off" or "On" end, function()
    if wifi.status() == "off" then
      cfg.set("wifi_auto", "1"); shell.wifi_start(cfg.get("wifi_ssid"), cfg.get("wifi_pass"))
    else cfg.set("wifi_auto", "0"); shell.wifi_stop() end end },
  { "Theme", function() return ui.theme end, function(d)
    local name = step(ui.theme_names, ui.theme, d); cfg.set("theme", name); ui.set_theme(name) end },
  { "Sleep after", function() return SLEEP_LABEL[shell.sleep_after()] or "?" end, function(d)
    cfg.set("sleep", step(SLEEP, shell.sleep_after(), d)) end },
  { "Notifications", function() return (ui.status.unread or 0) .. " new" end, function()
    shell.overlay("notifications") end, true },
  { "Screenshot", function() return "Fn+P" end, function() shell.close_overlay(); shell.screenshot() end, true },
  { "Task Manager", function() return "" end, function() shell.close_overlay(); shell.launch("tasks") end, true },
}

function ov.draw()
  local x, y, w, rowh = 30, 18, 180, 13
  ui.box(x, y, w, 12 + #items * rowh)
  for i, it in ipairs(items) do
    local ry = y + 5 + (i - 1) * rowh
    if i == sel then gfx.rfill(x + 3, ry, w - 6, rowh - 1, 3, col.surface2) end
    ui.text(x + 8, ry + 2, it[1], i == sel and col.accent or col.text)
    ui.right(x + w - 8, ry + 2, it[2](), col.muted)
  end
  ui.footer({ { "<>", "Change" }, { "Enter", "Open" }, { "Esc", "Close" } })
end

function ov.key(k)
  local d = ui.nav(k)
  local it = items[sel]
  if d == "up" then sel = (sel - 2) % #items + 1
  elseif d == "down" then sel = sel % #items + 1
  elseif d == "left" and not it[4] then it[3](-1)
  elseif d == "right" and not it[4] then it[3](1)
  elseif k.key == "enter" then it[3](1)
  elseif k.key == "esc" then shell.close_overlay() end
end

return ov
