-- Images: browse screenshots and pictures and view them full screen. While a
-- picture is shown the display is held (sys.display_hold) and drawn directly
-- with disp.*, so it is redrawn only when the picture changes.
local col = ui.col
local app = { title = "Images", icon = "image", color = "teal", order = 23, category = "media" }
app.help = {
  { "Up/Dn", "Select" },
  { "Enter", "View image" },
  { "X", "Delete" },
  { "Arrows", "Viewer: prev / next" },
  { "Enter", "Viewer: caption" },
  { "Esc", "Close viewer / home" },
}

local EXT = { bmp = true, jpg = true, jpeg = true, png = true }
local MAX_FILES = 200

local files, rows, sel, top = {}, {}, 1, 1
local viewing, dirty, caption = false, false, true
local where = ""   -- hint for the empty screen

local function ext_of(name) return (name:match("%.(%w+)$") or ""):lower() end

local function scan()
  files, rows = {}, {}
  local dirs = { "data/screenshots", "data/images" }
  where = #dirs > 1 and "Screenshots (Fn+P) and sd:/images" or "Screenshots (Fn+P) appear here"
  for _, d in ipairs(dirs) do
    local found = {}
    local ok, list = pcall(sys.list, d)
    for _, e in ipairs(ok and list or {}) do
      if not e.dir and EXT[ext_of(e.name)] then found[#found + 1] = e.name end
    end
    -- newest screenshots first, other pictures by name
    local newest = d:match("screenshots$") ~= nil
    table.sort(found, function(a, b) if newest then return a > b end return a:lower() < b:lower() end)
    for _, name in ipairs(found) do
      if #files >= MAX_FILES then break end
      files[#files + 1] = { path = d .. "/" .. name, name = name, dir = d:match("[^/]+$") }
    end
  end
  for i, f in ipairs(files) do rows[i] = { label = f.name, value = f.dir } end
  sel = math.max(1, math.min(sel, #files))
end

-- Width and height from the file header (BMP, PNG, baseline/progressive JPEG),
-- or nil when it cannot be read.
local function image_size(path)
  local ext = ext_of(path)
  local ok, w, h = pcall(function()
    if ext == "bmp" then
      local s = sys.read_text(path, 26)
      if s and #s >= 26 and s:sub(1, 2) == "BM" then
        local bw, bh = string.unpack("<i4i4", s, 19)
        return bw, math.abs(bh)
      end
    elseif ext == "png" then
      local s = sys.read_text(path, 24)
      if s and #s >= 24 and s:sub(2, 4) == "PNG" then return string.unpack(">I4I4", s, 17) end
    else
      local s = sys.read_text(path, 4096)
      local i = 3
      while s and i + 8 <= #s do
        if s:byte(i) ~= 0xFF then return nil end
        local m = s:byte(i + 1)
        if m == 0xC0 or m == 0xC1 or m == 0xC2 then
          local jh, jw = string.unpack(">I2I2", s, i + 5)
          return jw, jh
        end
        i = i + 2 + string.unpack(">I2", s, i + 2)
      end
    end
  end)
  if ok and w and h and w > 0 and h > 0 then return w, h end
end

-- Draws the current picture straight to the panel.
local function show()
  local f = files[sel]
  disp.fill(0, 0, 240, 135, 0)
  if not f then return end
  local w, h = image_size(f.path)
  local scale, x, y = 1, 0, 0
  if w then
    scale = math.min(1, 240 / w, 135 / h)
    x = math.max(0, math.floor((240 - w * scale) / 2))
    y = math.max(0, math.floor((135 - h * scale) / 2))
  end
  local ok = disp.image(f.path, x, y, scale)
  if not ok then
    disp.text(54, 56, "Can't show this image", col.white)
    disp.text(54, 68, "BMP, JPG and PNG only", col.muted)
  end
  if caption then
    disp.fill(0, 123, 240, 12, col.surface)
    disp.text(4, 125, ui.fit(sel .. "/" .. #files .. "  " .. f.name, 168), col.text)
    disp.text(178, 125, "<> Esc", col.muted)
  end
end

local function view()
  if not files[sel] then return end
  viewing, dirty = true, true
  sys.display_hold(true)
end

local function leave()
  viewing, dirty = false, false
  sys.display_hold(false)
end

local function delete()
  local f = files[sel]
  if not f then return end
  shell.confirm("Delete image", "Delete " .. f.name .. "?", function(yes)
    if not yes then return end
    if sys.remove(f.path) then shell.toast("Deleted") else shell.toast("Could not delete") end
    scan()
  end)
end

function app.init(args)
  sel, top, caption = 1, 1, true
  viewing, dirty = false, false
  scan()
  local path = args and args.path
  if path then
    local found
    for i, f in ipairs(files) do if f.path == path then found = i end end
    if not found then
      table.insert(files, 1, { path = path, name = path:match("[^/]+$") or path, dir = "" })
      table.insert(rows, 1, { label = files[1].name, value = "" })
      found = 1
    end
    sel = found
    view()
  end
end

function app.close()
  if viewing then leave() end
  files, rows = {}, {}
end

function app.update()
  if viewing and dirty then
    dirty = false
    show()
  end
end

function app.draw()
  if viewing then return end  -- the picture is on the panel; frames are not shown
  if #rows == 0 then
    ui.empty("image", "No images yet", where)
    ui.footer({ { "Esc", "Home" } })
    return
  end
  top = ui.list(rows, sel, top, 4, 17, 230, 15, 7)
  ui.footer({ { "Enter", "View" }, { "X", "Delete" }, { "Esc", "Home" } })
end

function app.key(k)
  local d = ui.nav(k)
  if viewing then
    if k.key == "esc" then leave()
    elseif d == "left" or d == "up" then sel = (sel - 2) % #files + 1; dirty = true
    elseif d == "right" or d == "down" then sel = sel % #files + 1; dirty = true
    elseif k.key == "enter" or k.key == "space" or k.text == " " then caption = not caption; dirty = true
    end
    return true  -- nothing else may draw while the display is held
  end
  if d == "up" then sel = math.max(1, sel - 1)
  elseif d == "down" then sel = math.min(#files, sel + 1)
  elseif k.key == "enter" or d == "right" then view()
  elseif k.text == "x" then delete()
  elseif k.key == "esc" then return false
  else return false end
  return true
end

-- The shell calls this when it gives the held display back (after a toast,
-- dialog or overlay), so the picture is drawn again.
function app.repaint()
  if viewing then dirty = true end
end

return app
