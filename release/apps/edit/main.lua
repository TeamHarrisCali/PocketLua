-- Text editor with Lua highlighting. Ctrl+S saves, Ctrl+R saves and runs/reloads.
-- Arrow keys are Fn + ; , . /  (the bare keys type text here).
local col = ui.col

local app = { title = "Editor", icon = "pencil", color = "purple", hidden = true, category = "tools" }
app.help = {
  { "Arrows", "Move (Fn + ; . , /)" },
  { "^S", "Save" },
  { "^R", "Save and run" },
  { "^Z", "Undo" },
  { "^C/V", "Copy / paste line" },
  { "^X/K", "Cut / delete line" },
  { "^A/E", "Line start / end" },
  { "^U/D", "Page up / down" },
  { "Esc", "Exit; twice discards" },
}

local MAX_BYTES = 32 * 1024  -- one line costs ~30 bytes of overhead on top of its text
local GUTTER = 24
local ROWS = 11
local TOP_Y = 16
local COLS = (ui.W - GUTTER) // 6

local lines, path
local cx, cy = 1, 1     -- cursor column (1-based, may be #line+1) and line
local top, left = 1, 0  -- first visible line, horizontal scroll in columns
local dirty, esc_armed = false, false
local blink = 0

local KW = {}
for w in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%a+") do KW[w] = true end

local function split(s)
  local t = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = line end
  return t
end

-- Splits one line into colored runs for drawing.
local function split_runs(line)
  local out, i, n = {}, 1, #line
  local function put(s, c) out[#out + 1] = { s, c } end
  while i <= n do
    local c = line:sub(i, i)
    if c == "-" and line:sub(i, i + 1) == "--" then
      put(line:sub(i), col.dim)
      break
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = line:sub(j, j)
        if d == "\\" then j = j + 1 elseif d == c then break end
        j = j + 1
      end
      put(line:sub(i, j), col.good)
      i = j + 1
    elseif c:match("[%a_]") then
      local w = line:match("^[%w_]+", i)
      put(w, KW[w] and col.accent or col.text)
      i = i + #w
    elseif c:match("%d") then
      local w = line:match("^[%w%.]+", i)
      put(w, col.warn)
      i = i + #w
    else
      local j = line:find("[%a_%d\"'%-]", i + 1) or (n + 1)
      put(line:sub(i, j - 1), col.text)
      i = j
    end
  end
  return out
end

-- Highlighting allocates; cache it per line text so idle frames make no garbage.
local run_cache, run_cache_n = {}, 0
local function runs(line)
  local r = run_cache[line]
  if r then return r end
  if run_cache_n > 40 then run_cache, run_cache_n = {}, 0 end
  r = split_runs(line)
  run_cache[line], run_cache_n = r, run_cache_n + 1
  return r
end

function app.init(args, saved)
  -- reopening the editor without a file resumes the last one at the same place
  if not (args and args.path) and saved then args = { path = saved.path, line = saved.cy } end
  undo, typing_line = {}, nil
  path = args and args.path or "apps/untitled.lua"
  local src = sys.read_text(path)
  app.title = path
  if src and src:find("\0", 1, true) then
    shell.toast("Binary file, not opened")
    lines = { "" }
    path = nil
    return
  end
  if src and #src > MAX_BYTES then
    shell.toast("File too large to edit")
    lines = { "" }
    path = nil
    return
  end
  lines = split((src or ""):gsub("\t", "  "))
  cx, cy, top, left, dirty, esc_armed = 1, 1, 1, 0, false, false
  if args and args.line then cy = math.max(1, math.min(#lines, args.line)) end
  if not src then shell.toast("New file") end
end

function app.save()
  if path then return { path = path, cy = cy } end
end

local function save()
  if not path then return false end
  local text = table.concat(lines, "\n")
  local ok = sys.write_text(path, text)
  -- read it back: a short or failed write must never go unnoticed
  if ok and not (sys.safe_mode and path:match("^lib/")) then
    local back = sys.read_text(path)
    ok = back ~= nil and #back == #text
  end
  if ok then dirty = false else shell.toast("Save failed - file NOT written") end
  return ok
end

local function clamp()
  cy = math.max(1, math.min(#lines, cy))
  cx = math.max(1, math.min(#lines[cy] + 1, cx))
  if cy < top then top = cy elseif cy > top + ROWS - 1 then top = cy - ROWS + 1 end
  if cx - 1 < left then left = cx - 1 elseif cx - 1 > left + COLS - 1 then left = cx - COLS end
end

-- Undo keeps only what each change touched (a line, or a split/join), at most
-- 50 steps. Typing on one line is one step.
local undo = {}
local typing_line = nil

local function snap(u)
  u.cx, u.cy = cx, cy
  undo[#undo + 1] = u
  if #undo > 50 then table.remove(undo, 1) end
end

local function typing_snap()
  if typing_line ~= cy then
    snap({ kind = "line", y = cy, text = lines[cy] })
    typing_line = cy
  end
end

local function apply_undo()
  local u = table.remove(undo)
  if not u then shell.toast("Nothing to undo"); return end
  if u.kind == "line" then lines[u.y] = u.text
  elseif u.kind == "join" then lines[u.y] = u.a; table.insert(lines, u.y + 1, u.b)
  elseif u.kind == "split" then lines[u.y] = u.text; table.remove(lines, u.y + 1)
  elseif u.kind == "kill" then
    if u.only then lines[1] = u.text else table.insert(lines, u.y, u.text) end
  elseif u.kind == "lines" then
    for _ = 1, u.n do table.remove(lines, u.y) end
  end
  cx, cy, dirty, typing_line = u.cx, u.cy, true, nil
end

local function insert(s)
  typing_snap()
  local l = lines[cy]
  lines[cy] = l:sub(1, cx - 1) .. s .. l:sub(cx)
  cx = cx + #s
  dirty = true
end

local function newline()
  snap({ kind = "split", y = cy, text = lines[cy] })
  typing_line = nil
  local l = lines[cy]
  local indent = l:match("^%s*")
  if cx <= #indent then indent = indent:sub(1, cx - 1) end
  lines[cy] = l:sub(1, cx - 1)
  table.insert(lines, cy + 1, indent .. l:sub(cx))
  cy, cx = cy + 1, #indent + 1
  dirty = true
end

local function backspace()
  if cx > 1 then
    typing_snap()
    local l = lines[cy]
    lines[cy] = l:sub(1, cx - 2) .. l:sub(cx)
    cx = cx - 1
  elseif cy > 1 then
    snap({ kind = "join", y = cy - 1, a = lines[cy - 1], b = lines[cy] })
    typing_line = nil
    local prev = lines[cy - 1]
    lines[cy - 1] = prev .. lines[cy]
    table.remove(lines, cy)
    cy, cx = cy - 1, #prev + 1
  end
  dirty = true
end

function app.update(dt)
  blink = (blink + dt) % 1
end

function app.draw()
  gfx.clip(0, ui.BAR, ui.W, ui.BOTTOM - ui.BAR)
  for r = 0, ROWS - 1 do
    local n = top + r
    local line = lines[n]
    if not line then break end
    local y = TOP_Y + r * 10
    if n == cy then gfx.fill(0, y - 1, ui.W, 10, col.panel) end
    gfx.text(2, y, string.format("%3d", n), n == cy and col.accent or col.panel2)
    gfx.clip(GUTTER, y - 1, ui.W - GUTTER, 10)
    local x = GUTTER - left * 6
    for _, run in ipairs(runs(#line > 400 and line:sub(1, 400) or line)) do
      if x + #run[1] * 6 > GUTTER and x < ui.W then gfx.text(x, y, run[1], run[2]) end
      x = x + #run[1] * 6
    end
    gfx.clip(0, ui.BAR, ui.W, ui.BOTTOM - ui.BAR)
  end
  if blink < 0.6 then
    gfx.fill(GUTTER + (cx - 1 - left) * 6, TOP_Y + (cy - top) * 10 - 1, 2, 9, col.white)
  end
  gfx.noclip()
  ui.footer({ { "^S", "Save" }, { "^R", "Run" }, { "^Z", "Undo" }, { "^C/V", "Line" } })
  local status = string.format("%d:%d%s", cy, cx, dirty and "*" or "")
  gfx.fill(ui.W - #status * 6 - 6, 124, #status * 6 + 6, 11, col.bg)
  ui.right(ui.W - 3, 126, status, dirty and col.warn or col.muted)
end

function app.key(k)
  if not lines then return false end
  -- the core already turns Fn + ; , . / into these key names
  local d = (k.key == "up" or k.key == "down" or k.key == "left" or k.key == "right") and k.key or nil
  if k.key == "esc" then
    if dirty and not esc_armed then
      esc_armed = true
      shell.toast("Unsaved changes - Esc again to discard")
      return true
    end
    return false
  end
  esc_armed = false
  blink = 0

  if k.ctrl and k.text then
    local c = k.text:lower()
    if c == "s" then
      if save() then shell.toast("Saved") end
    elseif c == "r" then
      if path and save() then shell.run_file(path) end
    elseif c == "a" then cx = 1
    elseif c == "e" then cx = #lines[cy] + 1
    elseif c == "k" or c == "x" then
      if c == "x" then shell.clipboard = lines[cy] .. "\n" end
      snap({ kind = "kill", y = cy, text = lines[cy], only = #lines == 1 })
      typing_line = nil
      if #lines > 1 then table.remove(lines, cy) else lines[1] = "" end
      dirty = true
    elseif c == "c" then
      shell.clipboard = lines[cy] .. "\n"
      shell.toast("Line copied")
    elseif c == "v" then
      local clip = shell.clipboard or ""
      if clip:find("\n") then
        -- whole lines: insert above the cursor line
        local n = 0
        for line in clip:gmatch("([^\n]*)\n") do
          table.insert(lines, cy + n, line)
          n = n + 1
        end
        snap({ kind = "lines", y = cy, n = n })
        cy = cy + n
        dirty, typing_line = true, nil
      elseif clip ~= "" then
        insert(clip)
      end
    elseif c == "z" then
      apply_undo()
    elseif c == "u" then cy = cy - ROWS
    elseif c == "d" then cy = cy + ROWS
    end
    clamp()
    return true
  end

  if d == "up" then cy = cy - 1
  elseif d == "down" then cy = cy + 1
  elseif d == "left" then
    if cx > 1 then cx = cx - 1 elseif cy > 1 then cy = cy - 1; cx = #lines[cy] + 1 end
  elseif d == "right" then
    if cx <= #lines[cy] then cx = cx + 1 elseif cy < #lines then cy = cy + 1; cx = 1 end
  elseif k.key == "enter" then newline()
  elseif k.key == "backspace" then backspace()
  elseif k.key == "delete" then
    if cx <= #lines[cy] then cx = cx + 1; backspace()
    elseif cy < #lines then cy = cy + 1; cx = 1; backspace() end
  elseif k.key == "tab" then insert("  ")
  elseif k.text and not k.fn then insert(k.text)
  else return false end
  clamp()
  return true
end

return app
