-- Small helpers shared by the games: high scores kept in data/<game>/scores.txt
-- (one key=value per line) and sound that stays off until the player turns it
-- on (shared by all games that use this, and muted by Settings > Sound).
local gk = {}

function gk.load(game)
  local t = {}
  local s = sys.read_text("data/" .. game .. "/scores.txt", 2048)
  if s then
    for k, v in s:gmatch("([%w_]+)=([^\n]*)") do t[k] = v end
  end
  return t
end

function gk.save(game, t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = {}
  for i, k in ipairs(keys) do out[i] = k .. "=" .. tostring(t[k]) end
  sys.mkdirs("data/" .. game)
  return sys.write_text("data/" .. game .. "/scores.txt", table.concat(out, "\n") .. "\n")
end

function gk.sound_on()
  return cfg.get("game_sound") == "1" and cfg.get("sounds") ~= "0"
end

function gk.toggle_sound()
  local on = cfg.get("game_sound") ~= "1"
  cfg.set("game_sound", on and "1" or "0")
  shell.toast(on and "Game sound on" or "Game sound off")
end

function gk.beep(freq, ms)
  if gk.sound_on() then snd.tone(freq, ms) end
end

return gk
