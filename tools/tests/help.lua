-- Source-text check that every app lists its keys for the Fn+H help overlay:
-- an `app.help = { { "Key", "What it does" }, ... }` block right after the
-- one-line header. Run from the project root:  lua5.4 tools/tests/help.lua
local say = print
local fails, passes = 0, 0
local function check(c, m)
  if c then passes = passes + 1; say("ok:   " .. m) else fails = fails + 1; say("FAIL: " .. m) end
end

-- Apps that are allowed to lack help for now (being rewritten separately).
local EXEMPT = { ["music.lua"] = true }
local MAX_ENTRIES, MAX_KEY, MAX_TEXT = 12, 6, 22

local p = io.popen("ls userland/apps/*.lua store/apps/*.lua 2>/dev/null")
local files = {}
for f in p:lines() do files[#files + 1] = f end
p:close()
check(#files > 0, "found app sources")

for _, path in ipairs(files) do
  local name = path:match("[^/]+$")
  local src = assert(io.open(path)):read("a")
  local is_app = src:find("\nreturn app%s*$") or src:find("^return app%s*$")
  if is_app then
    local block = src:match("\napp%.help = {\n(.-)\n}\n")
    if not block then
      check(EXEMPT[name], name .. ": has app.help = { ... }")
    else
      local n, bad = 0, nil
      for line in (block .. "\n"):gmatch("([^\n]*)\n") do
        local key, desc = line:match('^%s*{ "([^"]*)", "([^"]*)" },?%s*$')
        if not key then bad = bad or ("not a pair: " .. line)
        else
          n = n + 1
          if key == "" or #key > MAX_KEY then bad = bad or ("key label too long/empty: " .. key) end
          if desc == "" or #desc > MAX_TEXT then bad = bad or ("description too long/empty: " .. desc) end
          if key:find("[^\32-\126]") or desc:find("[^\32-\126]") then bad = bad or ("non-ASCII: " .. key .. " / " .. desc) end
        end
      end
      check(not bad and n >= 1 and n <= MAX_ENTRIES, name .. ": help has " .. n .. " short pairs" .. (bad and (" (" .. bad .. ")") or ""))
      -- the block must also be valid Lua
      local f = load("return {\n" .. block .. "\n}", "=" .. name)
      check(f and type(f()) == "table", name .. ": help block parses")
      -- the header stays one line, and the help follows it directly
      local hdr_end = src:match("\nlocal app = {[^\n]*}\napp%.help = {\n")
      check(hdr_end ~= nil, name .. ": app.help directly follows the one-line header")
    end
  end
end

say(string.format("%d ok, %d failure(s)", passes, fails))
os.exit(fails == 0 and 0 or 1)
