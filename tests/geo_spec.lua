-- riddle.geo: точка владельца из Wi‑Fi-скана (BeaconDB) или по IP (ipinfo.io) — план карты, срез 4.
-- Фикстуры — по замерам на Kindle (план, раздел 4: A1, A2, A3); адреса и имена сетей выдуманные.
local t = require("t")
local json = require("dkjson")
local geo = require("riddle.geo")

local T = {}

-- вывод `wpa_cli scan_results` (A1): заголовок, колонки через таб; одна сеть _nomap, у одной нет сигнала,
-- у одной скрытое имя
local SCAN = table.concat({
  "bssid / frequency / signal level / flags / ssid",
  "02:00:00:00:00:01\t2412\t-71\t[WPA2-PSK-CCMP][ESS]\tHomeNet",
  "02:00:00:00:00:02\t2437\t-48\t[WPA2-PSK-CCMP][ESS]\tNeighbour",
  "02:00:00:00:00:03\t2462\t-60\t[ESS]\tCafe_nomap",
  "02:00:00:00:00:04\t2412\t\t[ESS]\tNoSignal",
  "02:00:00:00:00:05\t2452\t-80\t[WPA2-PSK-CCMP][ESS]\t",
  "",
}, "\n")

function T.test_parse_scan()
  local aps = geo.parse_scan(SCAN)
  t.eq(#aps, 4, "без _nomap")
  t.eq(aps[1].mac, "02:00:00:00:00:02", "сильнейший первым")
  t.eq(aps[1].signal, -48)
  t.eq(aps[2].mac, "02:00:00:00:00:01")
  t.eq(aps[3].mac, "02:00:00:00:00:05", "скрытое имя — сеть годна")
  t.eq(aps[4].mac, "02:00:00:00:00:04", "без сигнала — в конце")
  t.eq(aps[4].signal, nil)
  for _, ap in ipairs(aps) do t.ok(ap.ssid == nil, "имя сети не выходит из разбора") end
end

function T.test_parse_scan_caps_and_garbage()
  local lines = { "bssid / frequency / signal level / flags / ssid", "FAIL-BUSY", "zz:00:00:00:00:01\t2412\t-50\t\tx" }
  for i = 1, 30 do lines[#lines + 1] = string.format("02:00:00:00:01:%02X\t2412\t-%d\t[ESS]\tn%d", i, 40 + i, i) end
  local aps = geo.parse_scan(table.concat(lines, "\n"))
  t.eq(#aps, geo.MAX_APS, "не больше MAX_APS")
  t.eq(geo.MAX_APS, 20)
  t.eq(aps[1].mac, "02:00:00:00:01:01", "МАС в нижнем регистре, сильнейший первым")
  t.eq(#geo.parse_scan(nil), 0)
  t.eq(#geo.parse_scan("FAIL\n"), 0)
end

function T.test_beacondb_body()
  local body = json.decode(geo.beacondb_body({ { mac = "02:00:00:00:00:02", signal = -48 },
                                               { mac = "02:00:00:00:00:04" } }))
  t.eq(body.considerIp, false)
  t.eq(#body.wifiAccessPoints, 2)
  t.eq(body.wifiAccessPoints[1].macAddress, "02:00:00:00:00:02")
  t.eq(body.wifiAccessPoints[1].signalStrength, -48)
  t.eq(body.wifiAccessPoints[2].signalStrength, nil, "сигнала нет — поля нет")
end

-- BeaconDB разбирает signalStrength как i8 (целое -128..127): дробь, число вне диапазона — 400 на ВЕСЬ запрос
-- (замер curl 2026-11-16: -45.0 / 128 / -129 / 156 -> 400 «expected i8»; -128 / 127 / 0 / без поля -> 404).
-- Такой сигнал из scan_results не губит запрос: сеть идёт без поля, дробный — округлён
function T.test_beacondb_body_signal_fits_i8()
  local scan = table.concat({
    "bssid / frequency / signal level / flags / ssid",
    "02:00:00:00:00:01\t2412\t-71\t[WPA2-PSK-CCMP][ESS]\tHomeNet",
    "02:00:00:00:00:02\t2437\t156\t[ESS]\t",
    "02:00:00:00:00:03\t2462\t-129\t[ESS]\tFar away",
    "02:00:00:00:00:04\t2412\t-45.6\t[ESS]\tКафе",
    "02:00:00:00:00:05\t2452\t-128\t[WPA2-PSK-CCMP][ESS]\tEdge",
    "",
  }, "\n")
  local body = json.decode(geo.beacondb_body(geo.parse_scan(scan)))
  local by_mac = {}
  for _, ap in ipairs(body.wifiAccessPoints) do
    local s = ap.signalStrength
    t.ok(s == nil or (s == math.floor(s) and s >= -128 and s <= 127), ap.macAddress .. ": signalStrength i8 или нет")
    by_mac[ap.macAddress] = ap
  end
  t.eq(#body.wifiAccessPoints, 5, "ни одна сеть не потеряна")
  t.eq(by_mac["02:00:00:00:00:01"].signalStrength, -71)
  t.eq(by_mac["02:00:00:00:00:02"].signalStrength, nil, "156 — без поля")
  t.eq(by_mac["02:00:00:00:00:03"].signalStrength, nil, "-129 — без поля")
  t.eq(by_mac["02:00:00:00:00:04"].signalStrength, -46, "дробный — округлён")
  t.eq(by_mac["02:00:00:00:00:05"].signalStrength, -128, "граница i8 — как есть")
end

-- ответ Ichnaea-совместимого API (A2): location.lat/lng, accuracy; 404 — сети не знают
function T.test_parse_beacondb_ok_and_404()
  local p = assert(geo.parse_beacondb(200, '{"location":{"lat":55.7512,"lng":37.6184},"accuracy":34.2}'))
  t.eq(p.lat, 55.7512)
  t.eq(p.lon, 37.6184)
  t.eq(p.acc, 34)
  local miss, why = geo.parse_beacondb(404,
    '{"error":{"errors":[{"domain":"geolocation","reason":"notFound","message":"Not found"}],"code":404,"message":"Not found"}}')
  t.eq(miss, nil)
  t.eq(why, "notfound")
  t.eq(select(2, geo.parse_beacondb(500, "")), "http 500")
  t.eq(select(2, geo.parse_beacondb(200, "{")), "decode")
  t.eq(select(2, geo.parse_beacondb(200, '{"location":{"lat":"x","lng":1},"accuracy":5}')), "decode")
  t.eq(select(2, geo.parse_beacondb(200, '{"location":{"lat":95,"lng":1},"accuracy":5}')), "decode")
  t.eq(select(2, geo.parse_beacondb(nil, "timeout")), "net")
end

-- 400 BeaconDB — текст serde с причиной; в лог — слово из словаря, сам текст (в нём бывают значения полей) — нет
function T.test_parse_beacondb_400_reason()
  local function why(body) return select(2, geo.parse_beacondb(400, body)) end
  t.eq(why("Json deserialize error: invalid value: integer `156`, expected i8 at line 1 column 94"), "http 400 signal")
  t.eq(why("Json deserialize error: invalid type: floating point `-45.5`, expected i8 at line 1 column 77"),
    "http 400 signal")
  t.eq(why("Json deserialize error: invalid length at line 1 column 58"), "http 400 mac")
  t.eq(why("Json deserialize error: missing field `macAddress` at line 1 column 62"), "http 400 mac")
  -- мусорный MAC — ответы живого BeaconDB (ревью ui, 2026-11-16): нехексовы цифры и неверная длина — mac, не json
  t.eq(why("Json deserialize error: invalid digit at line 1 column 54"), "http 400 mac")
  t.eq(why("Json deserialize error: invalid length at line 1 column 49"), "http 400 mac")
  t.eq(why("Json deserialize error: expected value at line 1 column 1"), "http 400 json")
  t.eq(why(nil), "http 400")
  t.eq(why("<html>Bad Request</html>"), "http 400")
end

-- ipinfo.io/json без ключа (A3): loc «lat,lon», точность до города
function T.test_parse_ip_loc()
  local p = assert(geo.parse_ip(200, '{"ip":"192.0.2.1","city":"Moscow","loc":"55.7558,37.6173"}'))
  t.eq(p.lat, 55.7558)
  t.eq(p.lon, 37.6173)
  t.eq(p.acc, 20000)
  t.eq(select(2, geo.parse_ip(200, '{"city":"Moscow"}')), "decode")
  t.eq(select(2, geo.parse_ip(200, '{"loc":"a,b"}')), "decode")
  t.eq(select(2, geo.parse_ip(429, "{}")), "http 429")
  t.eq(select(2, geo.parse_ip(nil, "offline")), "net")
end

function T.test_distance_m()
  local d = geo.distance_m({ lat = 55.75, lon = 37.62 }, { lat = 55.75, lon = 37.62 + 0.0477 })
  t.ok(math.abs(d - 3000) < 50, "≈ 3 км: " .. d)
end

local HOME = { lat = 55.75, lon = 37.62, source = "wifi", acc = 34, ts = 100 }

function T.test_ip_does_not_replace_wifi_same_city()
  local ip = { lat = 55.75, lon = 37.62 + 0.0477, source = "ip", acc = 20000, ts = 200 }
  t.eq(geo.choose(HOME, ip), HOME, "IP в 3 км не сбивает домашнюю точку по Wi‑Fi")
end

function T.test_ip_replaces_wifi_other_city()
  local ip = { lat = 55.75 + 2.7, lon = 37.62, source = "ip", acc = 20000, ts = 200 } -- ≈ 300 км
  t.eq(geo.choose(HOME, ip), ip)
end

function T.test_wifi_replaces_anything()
  local wifi = { lat = 55.76, lon = 37.63, source = "wifi", acc = 20, ts = 200 }
  t.eq(geo.choose(HOME, wifi), wifi)
  local saved_ip = { lat = 55.75, lon = 37.62, source = "ip", acc = 20000, ts = 100 }
  t.eq(geo.choose(saved_ip, wifi), wifi)
  local fresh_ip = { lat = 55.75, lon = 37.63, source = "ip", acc = 20000, ts = 200 }
  t.eq(geo.choose(saved_ip, fresh_ip), fresh_ip, "IP заменяет IP")
  t.eq(geo.choose(nil, fresh_ip), fresh_ip)
  t.eq(geo.choose(HOME, nil), HOME, "свежей нет — сохранённая")
  t.eq(geo.choose(nil, nil), nil)
end

t.run(T)
