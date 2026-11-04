-- App Store: install apps from sd:/liveos-apps or from a plain http:// link,
-- and remove apps you installed. An app is one .lua file whose first lines
-- contain the one-line header `local app = { title = "...", ... }`.
local col = ui.col
local app = { title = "App Store", icon = "store", color = "green", order = 24, category = "system" }
app.help = {
  { "Tab", "SD / Web / Installed" },
  { "Up/Dn", "Select" },
  { "Enter", "Install/get/open" },
  { "X", "Uninstall (Installed)" },
  { "Esc", "Home" },
}

local TABS = { "SD card", "Web", "Installed" }
local SD_DIR = "data/install"  -- copy .lua apps to /liveos/data/install on the card
local MAX_APP = 32 * 1024   -- the editor's limit too
local MAX_LIST = 50

local tab = 1
local sd_ok = false
local sd, sd_rows, sd_sel, sd_top = {}, {}, 1, 1        -- { {file=, name=, title=} }
local inst, inst_rows, in_sel, in_top = {}, {}, 1, 1    -- { {name=, title=} }
local last_url = ""
local pending, wait = nil, 0                              -- URL to download after a frame is shown
local wifi_s, wifi_c, url_s, refresh = "", nil, "", 0

-- ---------------------------------------------------------------- helpers
local function clean_name(s)
  return ((s or ""):lower():gsub("%.lua$", ""):gsub("[^%w_]", ""):sub(1, 24))
end

-- The app's title from its one-line header in the first 1 KB (where the home
-- screen looks for it), or nil when the text is not a LiveOS app.
local function header_title(src)
  local t = src and src:sub(1, 1024):match("local%s+app%s*=%s*(%b{})")
  if not t or t:find("\n") then return nil end
  return t:match('title%s*=%s*"([^"]+)"')
end

local function size_text(n)
  if n < 1024 then return n .. "B" end
  return string.format("%.1fK", n / 1024)
end

local function scan_sd()
  sd, sd_rows = {}, {}
  sd_ok = sys.storage() == "SD"
  if not sd_ok then return end
  local ok, list = pcall(sys.list, SD_DIR)
  for _, e in ipairs(ok and list or {}) do
    if not e.dir and e.name:lower():match("%.lua$") and #sd < MAX_LIST then
      local name = clean_name(e.name)
      local title = header_title(sys.read_text(SD_DIR .. "/" .. e.name, 1024))
      sd[#sd + 1] = { file = e.name, name = name, title = title, size = e.size or 0 }
    end
  end
  table.sort(sd, function(a, b) return (a.title or a.file):lower() < (b.title or b.file):lower() end)
  for i, a in ipairs(sd) do
    sd_rows[i] = { label = a.title or a.file, dim = a.title == nil,
      value = sys.exists("apps/" .. a.name .. ".lua") and "installed" or size_text(a.size) }
  end
  sd_sel = math.max(1, math.min(sd_sel, #sd))
end

local function scan_installed()
  inst, inst_rows = {}, {}
  local ok, list = pcall(sys.list, "apps")
  for _, e in ipairs(ok and list or {}) do
    local name = e.name:match("^(.+)%.lua$")
    if name and e.stored and not e.emb then
      local title = header_title(sys.read_text("apps/" .. e.name, 1024)) or name
      inst[#inst + 1] = { name = name, title = title }
    end
  end
  table.sort(inst, function(a, b) return a.title:lower() < b.title:lower() end)
  for i, a in ipairs(inst) do inst_rows[i] = { label = a.title, value = a.name } end
  in_sel = math.max(1, math.min(in_sel, #inst))
end

local function rescan()
  if tab == 1 then scan_sd() elseif tab == 3 then scan_installed() end
end

-- ---------------------------------------------------------------- install
-- src is the app text, or nil when tmp names a downloaded file to move into place.
local function install(src, name, title, tmp)
  name = clean_name(name)
  if name == "" then shell.toast("The name needs letters or digits"); return end
  local path = "apps/" .. name .. ".lua"
  if sys.is_embedded(path) then
    shell.prompt("Built-in name. Save as:", name .. "2", function(n) if n then install(src, n, title, tmp) end end)
    return
  end
  local function write()
    local ok
    if tmp then ok = sys.rename(tmp, path) else ok = sys.write_text(path, src) end
    if not ok then shell.toast("Could not save " .. path, 3); return end
    rescan()
    shell.confirm("Installed", title .. " is installed. Open it now?", function(yes)
      if yes then shell.launch(name) end
    end)
  end
  if sys.exists(path) then
    shell.confirm("Replace app", "Replace the installed app '" .. name .. "'?", function(yes)
      if yes then write() else shell.toast("Not installed") end
    end)
  else
    write()
  end
end

local function install_sd()
  local e = sd[sd_sel]
  if not e then return end
  local src = sys.read_text(SD_DIR .. "/" .. e.file, MAX_APP + 1)
  if not src then shell.toast("Could not read " .. e.file, 3); return end
  if #src > MAX_APP then shell.toast("App is too large (32K max)", 3); return end
  local title = header_title(src)
  if not title then shell.toast("Not a LiveOS app: no 'local app = {' line", 3); return end
  install(src, e.name, title)
end

-- ---------------------------------------------------------------- web
-- Downloads stream to a temp file (no RAM copy), then only the header is read.
local TMP = "data/download.tmp"
local function fetch(url)
  collectgarbage("collect")
  local bytes, code = http.download(url, TMP, MAX_APP)
  if not bytes then shell.toast("Download failed: " .. tostring(code), 4); return end
  if code ~= 200 then sys.remove(TMP); shell.toast("Server replied " .. tostring(code), 4); return end
  if bytes >= MAX_APP then sys.remove(TMP); shell.toast("App is too large (32K max)", 3); return end
  local title = header_title(sys.read_text(TMP, 1024))
  if not title then sys.remove(TMP); shell.toast("Not a LiveOS app: no 'local app = {' line", 4); return end
  local default = clean_name(url:match("([^/?#]+)%.lua") or title)
  shell.prompt("Save " .. title .. " as", default, function(name)
    if name then install(nil, name, title, TMP) else sys.remove(TMP); shell.toast("Not installed") end
  end)
end

local function ask_url()
  local st = wifi.status()
  if st ~= "connected" then
    if st == "connecting" then shell.toast("Wi-Fi is connecting - try again in a moment", 3); return end
    local ssid = cfg.get("wifi_ssid")
    if not ssid then shell.toast("Set up Wi-Fi in Settings > Wi-Fi first", 3); return end
    if shell.wifi_start(ssid, cfg.get("wifi_pass") or "") then
      shell.toast("Turning Wi-Fi on - try again when connected", 3)
    end
    return
  end
  shell.prompt("App URL (http://...)", last_url ~= "" and last_url or "http://", function(url)
    if not url then return end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" or url == "http://" then return end
    if url:match("^https://") then shell.toast("https is not supported - use http://", 3); return end
    if not url:match("^http://") then url = "http://" .. url end
    last_url = url
    cfg.set("store_url", url)
    pending, wait = url, 2
    url_s = ui.fit(url, 220)
  end)
end

local function web_status()
  local st = wifi.status()
  if st == "connected" then wifi_s, wifi_c = "Wi-Fi connected", col.good
  elseif st == "connecting" then wifi_s, wifi_c = "Wi-Fi connecting...", col.warn
  elseif st == "off" then wifi_s, wifi_c = "Wi-Fi is off - Enter turns it on", col.warn
  else wifi_s, wifi_c = "Wi-Fi not connected - Enter retries", col.warn end
end

-- ---------------------------------------------------------------- lifecycle
function app.init(args, saved)
  tab = saved and saved.tab or 1
  last_url = cfg.get("store_url") or ""
  url_s = last_url ~= "" and ui.fit("Last: " .. last_url, 220) or ""
  pending, refresh = nil, 0
  rescan()
  web_status()
end

function app.save() return { tab = tab } end

function app.close()
  sd, sd_rows, inst, inst_rows = {}, {}, {}, {}
  pending = nil
end

function app.update(dt)
  if pending then
    wait = wait - 1
    if wait <= 0 then
      local url = pending
      pending = nil
      fetch(url)
      url_s = ui.fit("Last: " .. last_url, 220)
    end
  end
  refresh = refresh - dt
  if refresh <= 0 then refresh = 1; web_status() end
end

local function draw_sd()
  if not sd_ok then
    ui.empty("store", "No SD card", "Insert one with a liveos-apps folder")
    ui.footer({ { "Tab", "Mode" }, { "Esc", "Home" } })
  elseif #sd_rows == 0 then
    ui.empty("store", "No apps on the SD card", "Copy .lua files to sd:/liveos-apps")
    ui.footer({ { "Tab", "Mode" }, { "Esc", "Home" } })
  else
    sd_top = ui.list(sd_rows, sd_sel, sd_top, 4, 34, 230, 15, 6)
    ui.footer({ { "Enter", "Install" }, { "Tab", "Mode" }, { "Esc", "Home" } })
  end
end

local function draw_web()
  if pending then
    ui.empty("store", "Downloading...", url_s)
  else
    ui.title(6, 36, "DOWNLOAD AN APP")
    ui.text(6, 50, "Link to a .lua file on a plain http://", col.text)
    ui.text(6, 62, "server. 32K at most.", col.text)
    ui.text(6, 80, wifi_s, wifi_c)
    ui.text(6, 96, url_s, col.muted)
  end
  ui.footer({ { "Enter", "Download" }, { "Tab", "Mode" }, { "Esc", "Home" } })
end

local function draw_installed()
  if #inst_rows == 0 then
    ui.empty("store", "No apps installed", "Install from the SD card or the web")
    ui.footer({ { "Tab", "Mode" }, { "Esc", "Home" } })
  else
    in_top = ui.list(inst_rows, in_sel, in_top, 4, 34, 230, 15, 6)
    ui.footer({ { "Enter", "Open" }, { "X", "Remove" }, { "Tab", "Mode" }, { "Esc", "Home" } })
  end
end

function app.draw()
  ui.tabs(TABS, tab, 16)
  if tab == 1 then draw_sd() elseif tab == 2 then draw_web() else draw_installed() end
end

function app.key(k)
  if pending then return true end
  if k.key == "tab" then
    tab = k.shift and (tab - 2) % #TABS + 1 or tab % #TABS + 1
    rescan()
    return true
  end
  if k.key == "esc" then return false end
  local d = ui.nav(k)
  if tab == 1 then
    if d == "up" then sd_sel = math.max(1, sd_sel - 1)
    elseif d == "down" then sd_sel = math.min(#sd, sd_sel + 1)
    elseif k.key == "enter" then install_sd()
    else return false end
  elseif tab == 2 then
    if k.key == "enter" then ask_url() else return false end
  else
    local a = inst[in_sel]
    if d == "up" then in_sel = math.max(1, in_sel - 1)
    elseif d == "down" then in_sel = math.min(#inst, in_sel + 1)
    elseif k.key == "enter" then if a then shell.launch(a.name) end
    elseif k.text == "x" then
      if not a then return true end
      shell.confirm("Uninstall", "Remove " .. a.title .. "? Its data files stay.", function(yes)
        if not yes then return end
        if sys.remove("apps/" .. a.name .. ".lua") then shell.toast("Removed " .. a.title) else shell.toast("Could not remove") end
        scan_installed()
      end)
    else return false end
  end
  return true
end

return app
