-- Задание дочернего процесса "map" (план карты, раздел 2): точка владельца — свежий Wi‑Fi-скан → BeaconDB,
-- не нашлось — IP (ipinfo.io); выбор с сохранённой — riddle.geo.choose. Единственный писатель файлов карты
-- (dir = /mnt/us/riddle/map/): point.json пишется во временный файл и встаёт на место os.rename; родитель
-- файлы только читает (read_point), негодный — как нет. В конверт и лог — только источник, точность, числа и
-- состояния: ни координат, ни BSSID, ни имён сетей.
-- Срез 5: местность вокруг точки — Overpass (OpenStreetMap), если сохранённой нет или экран вокруг точки вышел бы
-- за её поле (riddle.terrain.needs_fetch); сжатая (terrain.compact) пишется так же через .tmp + rename. Сырой ответ
-- и сжатые данные в конверт не идут — только состояние и числа (конверт runner ≤ 32 КБ).
local json = require("dkjson")
local file = require("riddle.file")
local geo = require("riddle.geo")
local terrain = require("riddle.terrain")
local http = require("riddle.http") -- только urlencode: сам запрос — deps.request

local mapjob = {}

mapjob.POINT = "point.json"
mapjob.UA = "riddle-diary/1.0"
mapjob.WPA = "/usr/bin/wpa_cli -i wlan0"
mapjob.SCAN_WAIT_S = 2    -- без свежего scan список несвежий (замер A1); свежий готов за ≤ 1 с
mapjob.REQUEST_S = 12     -- на каждый запрос; задание целиком ограничивает runner (CFG.map_ceil_s)
mapjob.BEACONDB_URL = "https://api.beacondb.net/v1/geolocate"
mapjob.IP_URL = "https://ipinfo.io/json"
mapjob.TERRAIN = "terrain.json"
mapjob.OVERPASS_URL = "https://overpass-api.de/api/interpreter"
-- запрос Overpass: чуть больше его [timeout:45] (terrain.QUERY_TIMEOUT_S); живой замер с Mac 2026-11-16 —
-- 20–35 с до первого байта (очередь сервера). Точка пишется до Overpass: потолок отнимает только местность
mapjob.OVERPASS_S = 50
-- бюджет задания целиком, от его начала: скан, BeaconDB, IP, Overpass с повторами. Первая попытка Overpass
-- влезает всегда (SCAN_WAIT_S + 2 × REQUEST_S + OVERPASS_S ≤ BUDGET_S), повтор — только если после паузы
-- влезает полный OVERPASS_S. Потолок runner'а CFG.map_ceil_s ≥ BUDGET_S + 5 с (тесты)
mapjob.BUDGET_S = 80
-- Overpass «at capacity»: 502/503/504/429 быстрее FAST_FAIL_S — сервер не считал, повтор с паузой (Retry-After
-- у 429 — не меньше просимой); медленный отказ, таймаут, remark — без повтора
mapjob.RETRY_PAUSES_S = { 3, 6 } -- не больше 1 + #RETRY_PAUSES_S попыток
mapjob.FAST_FAIL_S = 2
local BUSY = { [502] = true, [503] = true, [504] = true, [429] = true }

local SOURCES = { wifi = true, ip = true }

local function path(dir, name) return dir .. "/" .. (name or mapjob.POINT) end

-- read_file(path) -> строка | nil -> { lat, lon, source, acc, ts } | nil (нет файла или он негодный)
function mapjob.read_point(read_file, dir)
  local ok, s = pcall(read_file, path(dir))
  if not ok or type(s) ~= "string" then return nil end
  local dok, p = pcall(json.decode, s)
  if not dok or type(p) ~= "table" then return nil end
  local lat, lon = p.lat, p.lon
  if type(lat) ~= "number" or type(lon) ~= "number" or lat ~= lat or lon ~= lon
      or lat < -90 or lat > 90 or lon < -180 or lon > 180 then
    return nil
  end
  if not SOURCES[p.source] or type(p.acc) ~= "number" or type(p.ts) ~= "number" then return nil end
  return { lat = lat, lon = lon, source = p.source, acc = p.acc, ts = p.ts }
end

-- запись файла и атомарная запись — riddle.file (общие с итогом синхронизации)
mapjob.write_file = file.write

local function headers(extra)
  local h = { ["User-Agent"] = mapjob.UA, Accept = "application/json" }
  for k, v in pairs(extra or {}) do h[k] = v end
  return h
end

-- свежий список сетей: scan (ответ OK), пауза, scan_results
local function scan(deps)
  local ok = deps.run(mapjob.WPA .. " scan")
  deps.sleep(mapjob.SCAN_WAIT_S)
  local aps = geo.parse_scan(deps.run(mapjob.WPA .. " scan_results"))
  return aps, (tostring(ok or ""):match("^%s*OK") ~= nil)
end

-- файл карты целиком или никак: .tmp, затем rename (единственный писатель — это задание)
local function write_atomic(deps, name, s)
  local dir = deps.dir
  if deps.mkdir then pcall(deps.mkdir, dir) end
  return file.write_atomic(path(dir, name), s, { write = deps.write_file, rename = deps.rename })
end

-- read_file(path) -> строка | nil -> местность (riddle.terrain.valid), размер файла | nil (нет или негодный)
function mapjob.read_terrain(read_file, dir)
  local ok, s = pcall(read_file, path(dir, mapjob.TERRAIN))
  if not ok or type(s) ~= "string" then return nil end
  local dok, t = pcall(json.decode, s)
  if not dok or not terrain.valid(t) then return nil end
  return t, #s
end


-- запрос Overpass с повторами быстрого отказа, пока после паузы влезает полный запрос до deadline (по deps.clock)
-- -> status, body, попыток
local function overpass(deps, field, deadline)
  local hdrs = headers({ ["Content-Type"] = "application/x-www-form-urlencoded" })
  local form = "data=" .. http.urlencode(terrain.query(field.bbox))
  local tries = 0
  while true do
    tries = tries + 1
    local t0 = deps.clock()
    local status, body, rh = deps.request("POST", mapjob.OVERPASS_URL, hdrs, form, mapjob.OVERPASS_S)
    local pause = mapjob.RETRY_PAUSES_S[tries]
    if not (pause and BUSY[status] and deps.clock() - t0 < mapjob.FAST_FAIL_S) then return status, body, tries end
    local asked = status == 429 and type(rh) == "table" and tonumber(rh["retry-after"])
    if asked and asked > pause then pause = math.ceil(asked) end
    if deps.clock() + pause + mapjob.OVERPASS_S > deadline then return status, body, tries end
    deps.sleep(pause)
  end
end

-- новая местность вокруг point: Overpass -> terrain.compact -> файл. -> { state, ways?, bytes? };
-- state "fetched" | причина сбоя ("offline", "http 502", "remark", "json", "write fail", "invalid", …). Сбой — прежний файл цел.
-- deadline — конец бюджета задания по deps.clock. deps.log(строка) — лог дочернего (замеры A4, A5),
-- deps.rss() — RSS дочернего в КБ
local function fetch_terrain(deps, point, deadline)
  local log, clock = deps.log or function() end, deps.clock
  local function ms(since) return math.floor((clock() - since) * 1000 + 0.5) end
  local t0, tries = clock(), 0
  local function fail(why)
    log(string.format("riddle: map terrain failed (%s) in %d ms tries=%d", why, ms(t0), tries))
    return { state = why }
  end
  local field = terrain.field(point, deps.screen.w, deps.screen.h)
  local status, body
  status, body, tries = overpass(deps, field, deadline)
  if status == nil then return fail(tostring(body):sub(1, 40)) end
  if status ~= 200 then return fail("http " .. tostring(status)) end
  log(string.format("riddle: map terrain fetched %d bytes in %d ms tries=%d", #body, ms(t0), tries))
  local t1 = clock()
  local t, why = terrain.compact(body, point, field)
  if not t then return fail(why) end
  if not terrain.valid(t) then return fail("invalid") end -- файл читает родитель: негодную местность не пишем
  local s = json.encode(t)
  local ways = #t.streets + #t.buildings
  local rss = deps.rss and deps.rss()
  log(string.format("riddle: map terrain compact ways=%d bytes=%d in %d ms%s", ways, #s, ms(t1),
    rss and (", child RSS KB " .. rss) or ""))
  if not write_atomic(deps, mapjob.TERRAIN, s) then return fail("write fail") end
  return { state = "fetched", ways = ways, bytes = #s }
end

-- deps: run(cmd) -> вывод, sleep(s), request(method, url, headers, body, timeout_s) -> status, body
-- (riddle.http.request), read_file, write_file(path, s) -> ok, rename(a, b) -> ok, mkdir(dir), now() -> epoch, dir,
-- screen = { w, h } (экран карты, по нему поле местности), clock() -> секунды, log(строка)?, rss() -> КБ?.
-- -> { point_source = "wifi"|"ip"|"saved"|"none", acc?, aps, scan_ok, wifi?, ip?, write?,
-- terrain? = { state = "fetched"|"cached"|причина сбоя, ways?, bytes? } } — только числа и состояния
function mapjob.run(deps)
  local deadline = deps.clock() + mapjob.BUDGET_S
  local saved = mapjob.read_point(deps.read_file, deps.dir)
  local res = {}
  local aps, scan_ok = scan(deps)
  res.aps, res.scan_ok = #aps, scan_ok

  local fresh, why
  if #aps >= geo.MIN_APS then
    local status, body = deps.request("POST", mapjob.BEACONDB_URL,
      headers({ ["Content-Type"] = "application/json" }), geo.beacondb_body(aps), mapjob.REQUEST_S)
    fresh, why = geo.parse_beacondb(status, body)
    res.wifi = fresh and "ok" or why
    if fresh then fresh.source = "wifi" end
  else
    res.wifi = "few"
  end
  if not fresh then
    local status, body = deps.request("GET", mapjob.IP_URL, headers(), nil, mapjob.REQUEST_S)
    fresh, why = geo.parse_ip(status, body)
    res.ip = fresh and "ok" or why
    if fresh then fresh.source = "ip" end
  end
  if fresh then fresh.ts = deps.now() end

  local point = geo.choose(saved, fresh)
  if not point then
    res.point_source = "none"
  elseif point == fresh then
    res.point_source, res.acc = fresh.source, fresh.acc
    local ok = write_atomic(deps, mapjob.POINT, json.encode(fresh))
    res.write = ok and "ok" or "fail"
  else
    res.point_source, res.acc = "saved", saved.acc
  end

  if point then
    local old, bytes = mapjob.read_terrain(deps.read_file, deps.dir)
    if terrain.needs_fetch(old, point, deps.screen) then
      res.terrain = fetch_terrain(deps, point, deadline)
    else
      res.terrain = { state = "cached", ways = #old.streets + #old.buildings, bytes = bytes }
    end
  end
  return res
end

-- задание записало новую местность (конверт res; nil — не дошло): только тогда родителю есть что перечитать —
-- иначе map/terrain.json тот же, что он прочёл на открытии карты
function mapjob.fetched(res)
  return type(res) == "table" and type(res.terrain) == "table" and res.terrain.state == "fetched"
end

-- строка лога родителя: res — конверт задания (nil — задание не дошло), err — причина runner'а
function mapjob.log_line(res, err, ms)
  if type(res) ~= "table" then
    -- the job did not finish (preempted by an answer, timeout, crash): not "no point"
    return string.format("riddle: map job failed (%s) in %d ms", tostring(err):sub(1, 80), math.floor(tonumber(ms) or 0))
  end
  local parts = { string.format("riddle: map point %s", tostring(res.point_source or "none")) }
  if type(res.acc) == "number" then parts[#parts + 1] = string.format("acc=%d", res.acc) end
  parts[#parts + 1] = string.format("in %d ms", math.floor(tonumber(ms) or 0))
  if type(res.aps) == "number" then parts[#parts + 1] = string.format("aps=%d", res.aps) end
  if res.scan_ok == false then parts[#parts + 1] = "scan=fail" end
  for _, k in ipairs({ "wifi", "ip", "write" }) do
    if type(res[k]) == "string" then parts[#parts + 1] = k .. "=" .. res[k] end
  end
  local tr = res.terrain
  if type(tr) == "table" and type(tr.state) == "string" then
    parts[#parts + 1] = "terrain=" .. tr.state
    if type(tr.ways) == "number" then parts[#parts + 1] = string.format("ways=%d", tr.ways) end
  end
  if err then parts[#parts + 1] = "err=" .. tostring(err):sub(1, 80) end
  return table.concat(parts, " ")
end

return mapjob
