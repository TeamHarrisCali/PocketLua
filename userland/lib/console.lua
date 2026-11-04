-- Lua console on the USB serial port. Open the port in any terminal and type
-- Lua, or use tools/push.py to send files that run immediately.
--   !begin <path>   start receiving a file       !data <base64>   one chunk
--   !end            write it                     !get <path>      send a file back
--   !run <app>      launch an app                !reload          reload the system
--   !ls <dir>       list files                  !log   recent device log
-- Anything else is evaluated as Lua.
local console = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local lookup = {}
for i = 1, #B64 do lookup[B64:byte(i)] = i - 1 end

local function decode(s)
  local out, n, bits = {}, 0, 0
  for i = 1, #s do
    local v = lookup[s:byte(i)]
    if v then
      n, bits = n * 64 + v, bits + 6
      if bits >= 8 then
        bits = bits - 8
        out[#out + 1] = string.char((n >> bits) & 0xFF)
        n = n & ((1 << bits) - 1)
      end
    end
  end
  return table.concat(out)
end

local function encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local function ch(shift) local v = (n >> shift) & 63; return B64:sub(v + 1, v + 1) end
    out[#out + 1] = ch(18) .. ch(12) .. (b and ch(6) or "=") .. (c and ch(0) or "=")
  end
  return table.concat(out)
end

local function reply(s) usb.write(s .. "\n") end

local buf, recv_path, recv_chunks = "", nil, nil

local function eval(code)
  local fn, err = load("return " .. code, "=console")
  if not fn then fn, err = load(code, "=console") end
  if not fn then reply(err); return end
  local res = table.pack(pcall(fn))
  if not res[1] then reply(tostring(res[2])); return end
  for i = 2, res.n do reply(tostring(res[i])) end
end

local commands = {}

function commands.begin(arg)
  recv_path, recv_chunks = arg, {}
  reply("ok")
end

function commands.data(arg)
  if recv_chunks and arg then recv_chunks[#recv_chunks + 1] = decode(arg) end
  reply("+")
end

commands["end"] = function()
  if not recv_path then reply("error: no file open"); return end
  local ok = sys.write_text(recv_path, table.concat(recv_chunks))
  reply(ok and ("ok " .. recv_path) or "error: write failed")
  recv_path, recv_chunks = nil, nil
end

function commands.get(arg)
  local src = sys.read_text(arg)
  if not src then reply("error: not found"); return end
  for i = 1, #src, 768 do reply("!data " .. encode(src:sub(i, i + 767))) end
  reply("!end")
end

function commands.log()
  for line in usb.log_dump():gmatch("[^\n]+") do reply("# " .. line) end
end

function commands.run(arg) shell.launch(arg); reply("ok") end
function commands.reload() reply("ok"); sys.reload() end

function commands.ls(arg)
  for _, e in ipairs(sys.list(arg or "")) do reply((e.dir and "d " or "- ") .. e.name) end
end

local function handle(line)
  if line == "" then return end
  if line:sub(1, 1) == "!" then
    local name, arg = line:match("^!(%S+)%s*(.*)$")
    local fn = name and commands[name]
    if fn then fn(arg ~= "" and arg or nil) else reply("error: unknown command") end
  else
    eval(line)
  end
end

function console.poll()
  local s = usb.read()
  if not s then return end
  buf = buf .. s
  while true do
    local nl = buf:find("\n", 1, true)
    if not nl then break end
    local line = (buf:sub(1, nl - 1):gsub("\r", ""))
    buf = buf:sub(nl + 1)
    handle(line)
  end
  if #buf > 4096 then buf = "" end
end

console.encode, console.decode = encode, decode
return console
