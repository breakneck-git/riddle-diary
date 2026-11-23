-- riddle.mapjob: задание дочернего процесса "map" — точка владельца (план карты, срез 4).
-- Сеть, команды и файлы — поддельные deps; ответы — по замерам на Kindle (план, раздел 4: A1–A3).
local t = require("t")
local json = require("dkjson")
local mapjob = require("riddle.mapjob")

local T = {}

local SCAN = table.concat({
  "bssid / frequency / signal level / flags / ssid",
  "02:00:00:00:00:01\t2412\t-71\t[WPA2-PSK-CCMP][ESS]\tHomeNet",
  "02:00:00:00:00:02\t2437\t-48\t[WPA2-PSK-CCMP][ESS]\tNeighbour",
  "02:00:00:00:00:03\t2462\t-60\t[ESS]\tCafe",
}, "\n")
local BEACON_OK = '{"location":{"lat":55.7512,"lng":37.6184},"accuracy":34.2}'
local BEACON_404 = '{"error":{"code":404,"message":"Not found"}}'
local IP_OK = '{"ip":"192.0.2.1","city":"Moscow","loc":"55.7558,37.6173"}'
local IP_FAR = '{"ip":"192.0.2.1","city":"Kazan","loc":"55.7963,49.1088"}'

-- deps: files — словарь путь -> содержимое; ops — порядок команд, запросов и файловых операций.
-- Ответ сети — { status, body, секунд?, headers? }: часы поддельные (d.t), sleep и запрос их двигают.
-- overpass = { seq = { ответ, … } } — ответы по очереди, лишний запрос — offline
local function deps(o)
  o = o or {}
  local d = { dir = "/r/map", files = o.files or {}, ops = {}, reqs = {}, t = 0 }
  d.run = function(cmd)
    d.ops[#d.ops + 1] = "run " .. cmd
    if cmd:find(" scan_results", 1, true) then return o.scan or SCAN end
    if cmd:find(" scan", 1, true) then return "OK\n" end
  end
  d.sleep = function(s)
    d.ops[#d.ops + 1] = "sleep " .. s
    d.t = d.t + s
  end
  local seq = 0
  d.request = function(method, url, headers, body, timeout_s)
    d.reqs[#d.reqs + 1] = { method = method, url = url, headers = headers, body = body, timeout_s = timeout_s }
    d.ops[#d.ops + 1] = method .. " " .. url
    local r = url:find("beacondb", 1, true) and o.beacon or url:find("overpass", 1, true) and o.overpass or o.ip
    if r and r.seq then
      seq = seq + 1
      r = r.seq[seq]
    end
    if not r then return nil, "offline" end
    d.t = d.t + (r[3] or 0)
    return r[1], r[2], r[4]
  end
  d.read_file = function(path) return d.files[path] end
  d.write_file = function(path, s)
    d.ops[#d.ops + 1] = "write " .. path
    d.files[path] = s
    return true
  end
  d.rename = function(a, b)
    d.ops[#d.ops + 1] = "rename " .. a .. " " .. b
    d.files[b], d.files[a] = d.files[a], nil
    return true
  end
  d.mkdir = function(dir) d.ops[#d.ops + 1] = "mkdir " .. dir end
  d.now = function() return 5000 end
  d.clock = function() return d.t end
  d.screen = { w = 758, h = 1024 }
  d.logs = {}
  d.log = function(line) d.logs[#d.logs + 1] = line end
  return d
end

local function in_ops(ops, s)
  for _, op in ipairs(ops) do if op == s then return true end end
  return false
end

local function saved(p) return { ["/r/map/point.json"] = json.encode(p) } end

-- запросы точки (BeaconDB, IP) и местности (Overpass) — порознь
local function reqs_where(d, overpass)
  local out = {}
  for _, r in ipairs(d.reqs) do
    if (r.url:find("overpass", 1, true) ~= nil) == overpass then out[#out + 1] = r end
  end
  return out
end
local function geo_reqs(d) return reqs_where(d, false) end
local function overpass_reqs(d) return reqs_where(d, true) end

function T.test_wifi_then_beacondb()
  local d = deps({ beacon = { 200, BEACON_OK } })
  local res = mapjob.run(d)
  t.eq(d.ops[1], "run /usr/bin/wpa_cli -i wlan0 scan", "сначала свежий скан (A1)")
  t.ok(d.ops[2]:match("^sleep "), "ждёт скан")
  t.eq(d.ops[3], "run /usr/bin/wpa_cli -i wlan0 scan_results")
  t.eq(d.reqs[1].method, "POST")
  t.eq(d.reqs[1].url, "https://api.beacondb.net/v1/geolocate")
  t.eq(#json.decode(d.reqs[1].body).wifiAccessPoints, 3)
  t.eq(#geo_reqs(d), 1, "IP не спрашивали")
  t.eq(res.point_source, "wifi")
  t.eq(res.acc, 34)
  local p = mapjob.read_point(d.read_file, d.dir)
  t.eq(p.source, "wifi")
  t.eq(p.lat, 55.7512)
  t.eq(p.lon, 37.6184)
  t.eq(p.ts, 5000)
end

function T.test_beacondb_miss_falls_to_ip()
  local d = deps({ beacon = { 404, BEACON_404 }, ip = { 200, IP_OK } })
  local res = mapjob.run(d)
  t.eq(#geo_reqs(d), 2)
  t.eq(d.reqs[2].method, "GET")
  t.eq(d.reqs[2].url, "https://ipinfo.io/json")
  t.eq(res.point_source, "ip")
  t.eq(res.acc, 20000)
  t.eq(mapjob.read_point(d.read_file, d.dir).source, "ip")
end

function T.test_too_few_networks_skip_beacondb()
  local d = deps({ scan = "bssid / frequency / signal level / flags / ssid\n02:00:00:00:00:01\t2412\t-71\t[ESS]\tx\n",
                   beacon = { 200, BEACON_OK }, ip = { 200, IP_OK } })
  local res = mapjob.run(d)
  t.eq(#geo_reqs(d), 1, "одна сеть — BeaconDB не спрашивают")
  t.eq(d.reqs[1].url, "https://ipinfo.io/json")
  t.eq(res.point_source, "ip")
end

function T.test_ip_near_saved_wifi_keeps_saved()
  local home = { lat = 55.7512, lon = 37.6184, source = "wifi", acc = 34, ts = 100 }
  local d = deps({ files = saved(home), beacon = { 404, BEACON_404 }, ip = { 200, IP_OK } })
  local res = mapjob.run(d)
  t.eq(res.point_source, "saved")
  t.eq(res.acc, 34)
  for _, op in ipairs(d.ops) do t.ok(not op:match("^write"), "сохранённая не переписывается: " .. op) end
  local d2 = deps({ files = saved(home), beacon = { 404, BEACON_404 }, ip = { 200, IP_FAR } })
  t.eq(mapjob.run(d2).point_source, "ip", "другой город — точка по IP")
end

function T.test_no_network_keeps_saved()
  local home = { lat = 55.7512, lon = 37.6184, source = "wifi", acc = 34, ts = 100 }
  local d = deps({ files = saved(home) })
  local res = mapjob.run(d)
  t.eq(res.point_source, "saved")
  t.eq(mapjob.read_point(d.read_file, d.dir).ts, 100, "файл прежний")
  local none = mapjob.run(deps())
  t.eq(none.point_source, "none")
  t.eq(none.acc, nil)
end

function T.test_point_written_atomically()
  local d = deps({ beacon = { 200, BEACON_OK } })
  mapjob.run(d)
  local w, r
  for i, op in ipairs(d.ops) do
    if op == "write /r/map/point.json.tmp" then w = i end
    if op == "rename /r/map/point.json.tmp /r/map/point.json" then r = i end
    t.ok(op ~= "write /r/map/point.json", "прямой записи в point.json нет")
  end
  t.ok(w and r and w < r, "запись во временный файл, затем rename: " .. table.concat(d.ops, " | "))
  t.ok(in_ops(d.ops, "mkdir /r/map"), "каталог создан")
end

function T.test_bad_point_file_is_missing()
  local read = function(s) return function() return s end end
  t.eq(mapjob.read_point(read(nil), "/r/map"), nil, "нет файла")
  t.eq(mapjob.read_point(read('{"lat":55.7,"lon":37'), "/r/map"), nil, "обрыв записи")
  t.eq(mapjob.read_point(read('[]'), "/r/map"), nil)
  t.eq(mapjob.read_point(read('{"lat":"55","lon":37,"source":"wifi","acc":34,"ts":1}'), "/r/map"), nil)
  t.eq(mapjob.read_point(read('{"lat":55,"lon":37,"source":"gps","acc":34,"ts":1}'), "/r/map"), nil)
  t.eq(mapjob.read_point(read('{"lat":55,"lon":200,"source":"wifi","acc":34,"ts":1}'), "/r/map"), nil)
  local ok = mapjob.read_point(read('{"lat":55,"lon":37,"source":"wifi","acc":34,"ts":1}'), "/r/map")
  t.eq(ok.lat, 55)
  -- задание с негодным файлом: как файла нет
  local d = deps({ files = { ["/r/map/point.json"] = "{" } })
  t.eq(mapjob.run(d).point_source, "none")
end

function T.test_user_agent_on_every_request()
  local d = deps({ beacon = { 404, BEACON_404 }, ip = { 200, IP_OK } })
  mapjob.run(d)
  t.eq(#d.reqs, 3, "BeaconDB, IP, Overpass")
  for _, r in ipairs(d.reqs) do
    t.eq(r.headers["User-Agent"], "riddle-diary/1.0", r.url)
    t.ok(r.url:match("^https://"), "только https: " .. r.url)
    t.ok(type(r.timeout_s) == "number" and r.timeout_s > 0, "с таймаутом")
  end
  t.eq(d.reqs[1].headers["Content-Type"], "application/json")
  t.eq(d.reqs[3].url, "https://overpass-api.de/api/interpreter")
  t.eq(d.reqs[3].headers["Content-Type"], "application/x-www-form-urlencoded")
end

-- лог и конверт: только источник, точность, числа и состояния
function T.test_log_has_no_coordinates()
  local cases = {
    deps({ beacon = { 200, BEACON_OK } }),
    deps({ beacon = { 404, BEACON_404 }, ip = { 200, IP_OK } }),
    deps({ files = saved({ lat = 55.7512, lon = 37.6184, source = "wifi", acc = 34, ts = 100 }) }),
    deps(),
  }
  for _, d in ipairs(cases) do
    local res = mapjob.run(d)
    for _, line in ipairs({ mapjob.log_line(res, nil, 1234), json.encode(res) }) do
      t.ok(not line:find("55%.7"), "нет широты: " .. line)
      t.ok(not line:find("37%.6"), "нет долготы: " .. line)
      t.ok(not line:find("%x%x:%x%x:"), "нет BSSID: " .. line)
      for _, ssid in ipairs({ "HomeNet", "Neighbour", "Cafe", "Moscow", "192.0.2" }) do
        t.ok(not line:find(ssid, 1, true), "нет " .. ssid .. ": " .. line)
      end
    end
  end
  local line = mapjob.log_line({ point_source = "wifi", acc = 34, aps = 3 }, nil, 1234)
  t.ok(line:find("riddle: map point wifi acc=34 in 1234 ms", 1, true), line)
end

-- задание не завершилось (вытеснено ответом, таймаут, упало) — не «точки нет»
function T.test_log_line_job_failed()
  local line = mapjob.log_line(nil, "cancelled", 40000)
  t.ok(line:find("riddle: map job failed (cancelled) in 40000 ms", 1, true), line)
  t.ok(not line:find("map point", 1, true), line)
  t.ok(mapjob.log_line({ point_source = "none", aps = 0 }, nil, 10):find("riddle: map point none", 1, true))
end

-- запись файла: сбой write или close — ошибка (полный диск FAT), не true
function T.test_write_file_checks_write_and_close()
  local function open_with(file) return function() return file end end
  local ok_file = { write = function(f) return f end, close = function() return true end }
  t.eq(mapjob.write_file("/x", "s", open_with(ok_file)), true)
  t.eq(mapjob.write_file("/x", "s", function() return nil, "EACCES" end), nil, "не открылся")
  local bad_write = { write = function() return nil, "ENOSPC" end, close = function() return true end }
  t.eq(mapjob.write_file("/x", "s", open_with(bad_write)), nil, "write упал")
  local bad_close = { write = function(f) return f end, close = function() return nil, "ENOSPC" end }
  local r, err = mapjob.write_file("/x", "s", open_with(bad_close))
  t.eq(r, nil, "close упал")
  t.eq(err, "ENOSPC")
  -- настоящий файл
  local path = os.tmpname()
  t.eq(mapjob.write_file(path, "abc"), true)
  local f = assert(io.open(path, "rb"))
  t.eq(f:read("*a"), "abc")
  f:close()
  os.remove(path)
end

-- неудачная запись .tmp: rename не зовётся, сохранённая точка цела
function T.test_failed_write_keeps_saved_point()
  local home = { lat = 55.70, lon = 37.50, source = "wifi", acc = 34, ts = 100 }
  local d = deps({ files = saved(home), beacon = { 200, BEACON_OK } })
  local before = d.files["/r/map/point.json"]
  d.write_file = function(path) d.ops[#d.ops + 1] = "write " .. path return nil, "ENOSPC" end
  local res = mapjob.run(d)
  t.eq(res.write, "fail")
  for _, op in ipairs(d.ops) do t.ok(not op:match("^rename"), "rename не зовётся: " .. op) end
  t.eq(d.files["/r/map/point.json"], before, "сохранённая точка не тронута")
end

-- один писатель файла точки: его имя знает только riddle.mapjob (main.lua и виджет — через mapjob)
function T.test_point_file_named_only_in_mapjob()
  local p = assert(io.popen("grep -rlF 'point.json' plugin/riddlediary.koplugin --include='*.lua'"))
  local hits = {}
  for line in p:lines() do hits[#hits + 1] = line end
  p:close()
  t.eq(table.concat(hits, ","), "plugin/riddlediary.koplugin/riddle/mapjob.lua")
end

-- срез 5: местность. Синтетика у точки lat 10, lon 20 (tests/fixtures/overpass_small.json)
local function read_fixture(name)
  local f = assert(io.open("tests/fixtures/" .. name, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end
local OVERPASS = read_fixture("overpass_small.json")
local function beacon_at(lat, lon)
  return { 200, string.format('{"location":{"lat":%.6f,"lng":%.6f},"accuracy":30}', lat, lon) }
end
local TERRAIN = "/r/map/terrain.json"
local FIX_WAYS = 17 -- 3 улицы + 14 зданий в поле (terrain_spec)

function T.test_terrain_fetched_once()
  local d = deps({ beacon = beacon_at(10, 20), overpass = { 200, OVERPASS } })
  local res = mapjob.run(d)
  local ov = overpass_reqs(d)
  t.eq(#ov, 1, "местности нет — Overpass")
  t.eq(ov[1].method, "POST")
  t.ok(ov[1].body:match("^data="), "запрос — форма data=: " .. ov[1].body:sub(1, 40))
  t.ok(ov[1].body:find("%5Bout%3Ajson%5D", 1, true), "QL закодирован для формы")
  t.ok(not ov[1].body:find(" ", 1, true), "без пробелов в теле формы")
  t.eq(res.terrain.state, "fetched")
  t.eq(res.terrain.ways, FIX_WAYS)
  t.eq(res.terrain.bytes, #d.files[TERRAIN], "размер файла местности")
  local w, r
  for i, op in ipairs(d.ops) do
    if op == "write " .. TERRAIN .. ".tmp" then w = i end
    if op == "rename " .. TERRAIN .. ".tmp " .. TERRAIN then r = i end
    t.ok(op ~= "write " .. TERRAIN, "прямой записи нет")
  end
  t.ok(w and r and w < r, "временный файл, затем rename")
  local tt = mapjob.read_terrain(d.read_file, d.dir)
  t.ok(tt, "файл местности читается")
  t.eq(#tt.streets, 3)
  -- второе открытие с той же точкой: местность из файла
  d.reqs = {}
  local res2 = mapjob.run(d)
  t.eq(#overpass_reqs(d), 0, "Overpass не вызван")
  t.eq(res2.terrain.state, "cached")
  t.eq(res2.terrain.ways, FIX_WAYS)
  -- точка сдвинулась меньше чем на полэкрана: та же местность
  local d3 = deps({ files = d.files, beacon = beacon_at(10.001, 20.001), overpass = { 200, OVERPASS } })
  t.eq(mapjob.run(d3).terrain.state, "cached")
  t.eq(#overpass_reqs(d3), 0)
end

function T.test_overpass_failure_keeps_old_terrain()
  local d = deps({ beacon = beacon_at(10, 20), overpass = { 200, OVERPASS } })
  mapjob.run(d)
  local before = d.files[TERRAIN]
  t.ok(before, "местность есть")
  local cases = { -- ответ, состояние, попыток (быстрый отказ сервера повторяется)
    { { 502, "# 502 Gateway Timeout\n\nThis Overpass API server is currently at capacity.", 0.25 }, "http 502", 3 },
    { { 429, "rate limited", 0.2 }, "http 429", 3 },
    { { 200, '{"elements":[],"remark":"runtime error: Query timed out in \\"query\\" at line 1 after 21 seconds."}' }, "remark", 1 },
    { { 200, "<html>" }, "json", 1 },
    { nil, "offline", 1 },
  }
  for _, c in ipairs(cases) do
    -- точка в 1,1 км к северу: экран вышел за поле — нужна новая местность
    local d2 = deps({ files = d.files, beacon = beacon_at(10.01, 20), overpass = c[1] })
    local res = mapjob.run(d2)
    t.eq(#overpass_reqs(d2), c[3], c[2])
    t.eq(res.terrain.state, c[2])
    t.eq(d2.files[TERRAIN], before, "старая местность цела: " .. c[2])
    for _, op in ipairs(d2.ops) do t.ok(not op:find("terrain", 1, true), "файл местности не тронут: " .. op) end
  end
end

-- Overpass «at capacity»: быстрый отказ (502/503/504/429 за < 2 с) повторяется в том же задании —
-- пауза 3 с, затем 6 с, не больше 3 попыток (живой прогон 2026-11-16: http 502 за 448 мс, местности нет)
local BUSY = { 502, "# 502 Gateway Timeout\n\nThis Overpass API server is currently at capacity.", 0.25 }

local function sleeps(d)
  local out = {}
  for _, op in ipairs(d.ops) do
    local s = op:match("^sleep (.+)$")
    if s then out[#out + 1] = s end
  end
  return table.concat(out, ",")
end

function T.test_overpass_fast_failure_retried()
  local d = deps({ beacon = beacon_at(10, 20), overpass = { seq = { BUSY, BUSY, { 200, OVERPASS, 1 } } } })
  local res = mapjob.run(d)
  t.eq(#overpass_reqs(d), 3, "третья попытка")
  t.eq(res.terrain.state, "fetched")
  t.eq(res.terrain.ways, FIX_WAYS)
  t.ok(d.files[TERRAIN], "местность записана")
  t.eq(sleeps(d), mapjob.SCAN_WAIT_S .. ",3,6", "паузы 3 и 6 с между попытками")
  t.eq(#d.logs, 2, table.concat(d.logs, " | "))
  t.ok(d.logs[1]:match("^riddle: map terrain fetched " .. #OVERPASS .. " bytes in %d+ ms tries=3$"), d.logs[1])
  for _, r in ipairs(overpass_reqs(d)) do t.eq(r.timeout_s, mapjob.OVERPASS_S, "каждая попытка — полный запрос") end
end

function T.test_overpass_three_fast_failures_keep_old()
  local d = deps({ beacon = beacon_at(10, 20), overpass = { 200, OVERPASS } })
  mapjob.run(d)
  local before = d.files[TERRAIN]
  local d2 = deps({ files = d.files, beacon = beacon_at(10.01, 20),
    overpass = { seq = { BUSY, BUSY, BUSY, { 200, OVERPASS } } } })
  local res = mapjob.run(d2)
  t.eq(#overpass_reqs(d2), 3, "не больше 3 попыток")
  t.eq(res.terrain.state, "http 502")
  t.eq(d2.files[TERRAIN], before, "старая местность цела")
  t.eq(#d2.logs, 1, table.concat(d2.logs, " | "))
  t.ok(d2.logs[1]:match("^riddle: map terrain failed %(http 502%) in %d+ ms tries=3$"), d2.logs[1])
end

-- медленный отказ — сервер честно считал и не успел: повтор только съест потолок. 5 с — медленнее FAST_FAIL_S,
-- но повтор ещё влез бы в бюджет: отсекает именно скорость отказа, не бюджет
function T.test_overpass_slow_failure_not_retried()
  local d = deps({ beacon = beacon_at(10, 20), overpass = { seq = { { 504, "Gateway Timeout", 5 }, { 200, OVERPASS } } } })
  local res = mapjob.run(d)
  t.eq(#overpass_reqs(d), 1, "без повтора")
  t.eq(res.terrain.state, "http 504")
  t.ok(d.logs[1]:match("tries=1$"), d.logs[1])
  for _, c in ipairs({ { 503, "x", 0.3 }, { 504, "x", 0.3 }, { 429, "x", 0.3 } }) do
    local d2 = deps({ beacon = beacon_at(10, 20), overpass = { seq = { c, { 200, OVERPASS } } } })
    t.eq(mapjob.run(d2).terrain.state, "fetched", "быстрый " .. c[1] .. " повторяется")
  end
  for _, c in ipairs({ { 500, "x", 0.3 }, { 400, "x", 0.3 }, { nil, "timeout" } }) do
    local d2 = deps({ beacon = beacon_at(10, 20), overpass = { seq = { c, { 200, OVERPASS } } } })
    mapjob.run(d2)
    t.eq(#overpass_reqs(d2), 1, "без повтора: " .. tostring(c[1] or c[2]))
  end
end

-- 429 с Retry-After: пауза не меньше просимой, если после неё влезает полный запрос; не влезает — без повтора
function T.test_overpass_retry_after()
  local d = deps({ beacon = beacon_at(10, 20),
    overpass = { seq = { { 429, "slow down", 0.2, { ["retry-after"] = "10" } }, { 200, OVERPASS } } } })
  t.eq(mapjob.run(d).terrain.state, "fetched")
  t.eq(sleeps(d), mapjob.SCAN_WAIT_S .. ",10", "Retry-After вместо 3 с")
  local d2 = deps({ beacon = beacon_at(10, 20),
    overpass = { seq = { { 429, "slow down", 0.2, { ["retry-after"] = "120" } }, { 200, OVERPASS } } } })
  t.eq(mapjob.run(d2).terrain.state, "http 429")
  t.eq(#overpass_reqs(d2), 1, "Retry-After не влезает в бюджет — без повтора")
  local d3 = deps({ beacon = beacon_at(10, 20),
    overpass = { seq = { { 429, "slow down", 0.2, { ["retry-after"] = "Wed, 21 Oct 2026 07:28:00 GMT" } }, { 200, OVERPASS } } } })
  t.eq(mapjob.run(d3).terrain.state, "fetched", "дата в Retry-After — обычная пауза")
  t.eq(sleeps(d3), mapjob.SCAN_WAIT_S .. ",3")
end

-- бюджет: задание кончается само до потолка runner'а при любой длительности фазы точки; повтор — только
-- если после паузы влезает полный запрос Overpass
function T.test_overpass_retries_fit_budget()
  t.ok(mapjob.SCAN_WAIT_S + 2 * mapjob.REQUEST_S + mapjob.OVERPASS_S <= mapjob.BUDGET_S,
    "первая попытка Overpass всегда полная")
  -- BeaconDB и IP тянут по 12 с (точка к 26 с): после отказа и паузы 3 с полный запрос ещё влезает, после 6 с — нет
  local d = deps({ beacon = { nil, "timeout", mapjob.REQUEST_S }, ip = { 200, IP_OK, mapjob.REQUEST_S },
    overpass = { seq = { BUSY, BUSY, BUSY } } })
  local res = mapjob.run(d)
  t.eq(#overpass_reqs(d), 2, "вторая попытка влезла, третья нет")
  t.ok(d.logs[1]:match("tries=2$"), d.logs[1])
  t.eq(res.terrain.state, "http 502")
  for _, slow in ipairs({ 0, 5, 12 }) do
    local d2 = deps({ beacon = { nil, "timeout", slow }, ip = { 200, IP_OK, slow },
      overpass = { seq = { BUSY, BUSY, { nil, "timeout", mapjob.OVERPASS_S } } } })
    mapjob.run(d2)
    t.ok(d2.t <= mapjob.BUDGET_S, "задание кончилось за " .. d2.t .. " с, бюджет " .. mapjob.BUDGET_S .. " с")
  end
end

-- неудачная запись местности: rename не зовётся, прежний файл цел
function T.test_failed_terrain_write_keeps_old()
  local d = deps({ beacon = beacon_at(10, 20), overpass = { 200, OVERPASS } })
  mapjob.run(d)
  local before = d.files[TERRAIN]
  local d2 = deps({ files = d.files, beacon = beacon_at(10.01, 20), overpass = { 200, OVERPASS } })
  d2.write_file = function(path, s)
    d2.ops[#d2.ops + 1] = "write " .. path
    if path:find("terrain", 1, true) then return nil, "ENOSPC" end
    d2.files[path] = s
    return true
  end
  local res = mapjob.run(d2)
  t.eq(res.terrain.state, "write fail")
  for _, op in ipairs(d2.ops) do t.ok(not op:match("^rename .*terrain"), "rename не зовётся: " .. op) end
  t.eq(d2.files[TERRAIN], before)
end

-- точка пишется до Overpass: задание, убитое потолком или упавшее на местности, уже сохранило точку
function T.test_point_written_before_overpass()
  local d = deps({ beacon = beacon_at(10, 20) })
  local inner = d.request
  d.request = function(method, url, ...)
    if url:find("overpass", 1, true) then
      d.ops[#d.ops + 1] = "overpass"
      error("killed by the ceiling")
    end
    return inner(method, url, ...)
  end
  t.ok(not pcall(mapjob.run, d), "задание упало на Overpass")
  t.ok(mapjob.read_point(d.read_file, d.dir), "точка уже записана")
  local r, o
  for i, op in ipairs(d.ops) do
    if op == "rename /r/map/point.json.tmp /r/map/point.json" then r = i end
    if op == "overpass" then o = i end
  end
  t.ok(r and o and r < o, "rename точки до Overpass: " .. table.concat(d.ops, " | "))
end

function T.test_no_point_no_overpass()
  local d = deps({ overpass = { 200, OVERPASS } })
  local res = mapjob.run(d)
  t.eq(res.point_source, "none")
  t.eq(#overpass_reqs(d), 0, "без точки местность не нужна")
  t.eq(res.terrain, nil)
end

-- конверт runner ≤ 32 КБ: данные местности в файле, в конверте только числа
function T.test_envelope_small()
  local els = {}
  for i = 1, 2000 do
    local la, lo = 10 + (i % 45 - 22) * 0.0001, 20 + (math.floor(i / 45) - 22) * 0.0001
    els[i] = { type = "way", id = i, tags = { building = "house" }, geometry = {
      { lat = la, lon = lo }, { lat = la, lon = lo + 0.00005 }, { lat = la + 0.00005, lon = lo + 0.00005 },
      { lat = la + 0.00005, lon = lo }, { lat = la, lon = lo } } }
  end
  local d = deps({ beacon = beacon_at(10, 20), overpass = { 200, json.encode({ elements = els }) } })
  local res = mapjob.run(d)
  t.ok(#d.files[TERRAIN] >= 100000, "местность ≥ 100 КБ: " .. #d.files[TERRAIN])
  local env = json.encode(res)
  t.ok(#env < 1024, "конверт < 1 КБ: " .. #env)
  t.eq(res.terrain.ways, 2000)
end

-- негодная местность (здание с вершиной за пределом карты) — файл не пишется, прежний цел; годная пишется
function T.test_invalid_terrain_is_not_written()
  local d = deps({ beacon = beacon_at(10, 20), overpass = { 200, OVERPASS } })
  mapjob.run(d)
  t.ok(d.files[TERRAIN], "годная местность записана")
  local before = d.files[TERRAIN]
  local far = '{"elements":[{"type":"way","id":1,"tags":{"building":"yes"},"geometry":['
    .. '{"lat":10.0,"lon":20.0},{"lat":10.0,"lon":20.001},{"lat":10.001,"lon":20.001},{"lat":40.0,"lon":20.0}]}]}'
  local d2 = deps({ files = d.files, beacon = beacon_at(10.01, 20), overpass = { 200, far } })
  local res = mapjob.run(d2)
  t.eq(res.terrain.state, "invalid")
  for _, op in ipairs(d2.ops) do t.ok(not op:find("terrain", 1, true), "файл местности не тронут: " .. op) end
  t.eq(d2.files[TERRAIN], before)
end

function T.test_bad_terrain_file_is_missing()
  local read = function(s) return function() return s end end
  t.eq(mapjob.read_terrain(read(nil), "/r/map"), nil, "нет файла")
  t.eq(mapjob.read_terrain(read('{"center":{"lat":10'), "/r/map"), nil, "обрыв записи")
  t.eq(mapjob.read_terrain(read('[]'), "/r/map"), nil)
  t.eq(mapjob.read_terrain(read('{"center":{"lat":10,"lon":20},"w":"x"}'), "/r/map"), nil)
  -- задание с негодным файлом: как файла нет — Overpass
  local d = deps({ files = { [TERRAIN] = "{" }, beacon = beacon_at(10, 20), overpass = { 200, OVERPASS } })
  t.eq(mapjob.run(d).terrain.state, "fetched")
end

-- лог дочернего процесса и строка родителя: только числа и состояния
function T.test_terrain_log_lines()
  local d = deps({ beacon = beacon_at(10, 20), overpass = { 200, OVERPASS } })
  d.rss = function() return 23456 end
  local res = mapjob.run(d)
  t.eq(#d.logs, 2, table.concat(d.logs, " | "))
  t.ok(d.logs[1]:match("^riddle: map terrain fetched " .. #OVERPASS .. " bytes in %d+ ms tries=1$"), d.logs[1])
  t.ok(d.logs[2]:match("^riddle: map terrain compact ways=17 bytes=%d+ in %d+ ms, child RSS KB 23456$"), d.logs[2])
  local line = mapjob.log_line(res, nil, 1234)
  t.ok(line:find("terrain=fetched ways=17", 1, true), line)
  local d2 = deps({ beacon = beacon_at(10, 20), overpass = { 502, "busy", 0.25 } })
  local res2 = mapjob.run(d2)
  t.eq(#d2.logs, 1, "одна итоговая строка на все попытки: " .. table.concat(d2.logs, " | "))
  t.ok(d2.logs[1]:match("^riddle: map terrain failed %(http 502%) in %d+ ms tries=3$"), tostring(d2.logs[1]))
  t.ok(mapjob.log_line(res2, nil, 1):find("terrain=http 502", 1, true))
  for _, l in ipairs({ d.logs[1], d.logs[2], line, json.encode(res) }) do
    t.ok(not l:find("10%.0") and not l:find("20%.0"), "нет координат: " .. l)
    t.ok(not l:find("lat", 1, true) and not l:find("lon", 1, true), "нет координат: " .. l)
  end
end

-- один писатель файла местности: его имя знает только riddle.mapjob
function T.test_terrain_file_named_only_in_mapjob()
  local p = assert(io.popen("grep -rlF 'terrain.json' plugin/riddlediary.koplugin --include='*.lua'"))
  local hits = {}
  for l in p:lines() do hits[#hits + 1] = l end
  p:close()
  t.eq(table.concat(hits, ","), "plugin/riddlediary.koplugin/riddle/mapjob.lua")
end

t.run(T)
