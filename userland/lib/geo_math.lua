-- Geo helpers shared by the LoRa Chat and GPS apps: distance, bearing, compass
-- text and short distance labels. Numbers on the device are single precision,
-- so differences are taken in degrees before scaling to radians, and the
-- bearing uses a form without the cancellation of the textbook formula.
local geo = {}

local R, RAD = 6371000, math.pi / 180
local sin, cos = math.sin, math.cos

-- Great-circle distance in metres (haversine).
function geo.dist(la1, lo1, la2, lo2)
  local s1 = sin((la2 - la1) * RAD / 2)
  local s2 = sin((lo2 - lo1) * RAD / 2)
  local a = s1 * s1 + cos(la1 * RAD) * cos(la2 * RAD) * s2 * s2
  return 2 * R * math.asin(math.min(1, math.sqrt(a)))
end

-- Initial bearing from point 1 to point 2, degrees 0-360 (0 = north).
-- x = cos(p1)sin(p2) - sin(p1)cos(p2)cos(dlo), rewritten as
-- sin(p2 - p1) + 2 sin(p1)cos(p2)sin^2(dlo/2) so nearby points stay accurate.
function geo.bearing(la1, lo1, la2, lo2)
  local dlo = (lo2 - lo1) * RAD
  local p1, p2 = la1 * RAD, la2 * RAD
  local h = sin(dlo / 2)
  local y = sin(dlo) * cos(p2)
  local x = sin((la2 - la1) * RAD) + 2 * sin(p1) * cos(p2) * h * h
  return (math.deg(math.atan(y, x)) + 360) % 360
end

local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
function geo.compass(deg)
  return DIRS[math.floor((deg % 360) / 45 + 0.5) % 8 + 1]
end

-- "850m", "1.4km", "23km"
function geo.fmt_dist(m)
  if m >= 10000 then return string.format("%dkm", math.floor(m / 1000 + 0.5)) end
  if m >= 1000 then return string.format("%.1fkm", m / 1000) end
  return string.format("%dm", math.floor(m + 0.5))
end

return geo
