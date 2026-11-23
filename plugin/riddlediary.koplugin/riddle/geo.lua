-- Точка владельца для карты (план карты, раздел 2 «Точка»): разбор Wi‑Fi-скана, запрос и ответ BeaconDB
-- (Ichnaea-совместимый API), ответ ipinfo.io, выбор между сохранённой и свежей точкой. Чистые функции,
-- без сети и файлов (их делает riddle.mapjob). Имена сетей (SSID) из разбора не выходят.
local json = require("dkjson")

local geo = {}

geo.MAX_APS = 20      -- сетей в запросе BeaconDB, сильнейшие
geo.MIN_APS = 2       -- Ichnaea ищет по Wi‑Fi от двух сетей; меньше — сразу IP
geo.IP_ACC_M = 20000  -- точность точки по IP: город
geo.CITY_M = 25000    -- IP ближе этого к сохранённой точке по Wi‑Fi — тот же город, точку не сбивает

geo.EARTH_M = 6371000 -- радиус сферы: расстояния здесь, проекция местности (riddle.terrain)
local EARTH_M = geo.EARTH_M

local MAC = "^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$"

-- вывод `wpa_cli scan_results`: заголовок, затем bssid \t частота \t сигнал \t флаги \t ssid.
-- -> { {mac, signal} } по убыванию сигнала (без сигнала — в конце), ≤ MAX_APS; сети с SSID на _nomap
-- исключены (правило MLS/Ichnaea: владелец сети просит не класть её на карту)
function geo.parse_scan(text)
  local aps = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
    local mac, _, sig, _, ssid = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
    if mac and mac:match(MAC) and not ssid:match("_nomap$") then
      aps[#aps + 1] = { mac = mac:lower(), signal = tonumber(sig) }
    end
  end
  table.sort(aps, function(a, b)
    if (a.signal ~= nil) ~= (b.signal ~= nil) then return a.signal ~= nil end
    if a.signal and a.signal ~= b.signal then return a.signal > b.signal end
    return a.mac < b.mac
  end)
  for i = #aps, geo.MAX_APS + 1, -1 do aps[i] = nil end
  return aps
end

-- BeaconDB разбирает signalStrength как i8: дробь или число вне -128..127 — 400 на весь запрос (замер curl
-- 2026-11-16). Дробный сигнал округляется, вне диапазона — сеть идёт без сигнала
local function i8_signal(s)
  if type(s) ~= "number" or s ~= s then return nil end
  s = math.floor(s + 0.5)
  if s < -128 or s > 127 then return nil end
  return s
end

-- тело POST /v1/geolocate: только Wi‑Fi, без IP вызывающего (его точка — отдельный путь)
function geo.beacondb_body(aps)
  local list = {}
  for i, ap in ipairs(aps) do list[i] = { macAddress = ap.mac, signalStrength = i8_signal(ap.signal) } end
  return json.encode({ wifiAccessPoints = list, considerIp = false })
end

local function valid(lat, lon)
  return type(lat) == "number" and type(lon) == "number" and lat == lat and lon == lon
    and lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180
end

local function decode(body)
  local ok, v = pcall(json.decode, body or "")
  if ok and type(v) == "table" then return v end
end

-- причины неудачи — только из этого словаря (идут в лог): "net", "http N", "http 400 signal|mac|json",
-- "notfound", "decode"
local function status_err(status)
  if type(status) ~= "number" then return "net" end
  return "http " .. status
end

-- 400 BeaconDB: текст ошибки serde («Json deserialize error: …») -> какое поле не принято. Сам текст в лог не
-- идёт: в нём бывают значения полей
local function bad_request(body)
  body = tostring(body or "")
  if not body:find("Json deserialize error", 1, true) then return "http 400" end
  if body:find("expected i8", 1, true) then return "http 400 signal" end
  if body:find("macAddress", 1, true) or body:find("invalid length", 1, true) or body:find("invalid digit", 1, true) then
    return "http 400 mac"
  end
  return "http 400 json"
end

-- -> { lat, lon, acc } | nil, причина
function geo.parse_beacondb(status, body)
  if status == 404 then return nil, "notfound" end
  if status == 400 then return nil, bad_request(body) end
  if status ~= 200 then return nil, status_err(status) end
  local v = decode(body)
  local loc = v and v.location
  if type(loc) ~= "table" or not valid(loc.lat, loc.lng) or type(v.accuracy) ~= "number" or v.accuracy < 0 then
    return nil, "decode"
  end
  return { lat = loc.lat, lon = loc.lng, acc = math.floor(v.accuracy + 0.5) }
end

-- ipinfo.io/json: loc «lat,lon» -> { lat, lon, acc = IP_ACC_M } | nil, причина
function geo.parse_ip(status, body)
  if status ~= 200 then return nil, status_err(status) end
  local v = decode(body)
  local a, b = tostring(v and v.loc or ""):match("^%s*([-%d.]+)%s*,%s*([-%d.]+)%s*$")
  local lat, lon = tonumber(a), tonumber(b)
  if not valid(lat, lon) then return nil, "decode" end
  return { lat = lat, lon = lon, acc = geo.IP_ACC_M }
end

-- метры по дуге большого круга
function geo.distance_m(a, b)
  local r = math.pi / 180
  local dlat, dlon = (b.lat - a.lat) * r, (b.lon - a.lon) * r
  local h = math.sin(dlat / 2) ^ 2 + math.cos(a.lat * r) * math.cos(b.lat * r) * math.sin(dlon / 2) ^ 2
  return 2 * EARTH_M * math.asin(math.min(1, math.sqrt(h)))
end

-- saved, fresh: { lat, lon, source = "wifi"|"ip", … } | nil -> какая точка верна. Свежая по Wi‑Fi — всегда;
-- свежая по IP не заменяет сохранённую по Wi‑Fi в том же городе (ближе CITY_M); иначе свежая
function geo.choose(saved, fresh)
  if not fresh then return saved end
  if fresh.source == "ip" and saved and saved.source == "wifi" and geo.distance_m(saved, fresh) < geo.CITY_M then
    return saved
  end
  return fresh
end

return geo
