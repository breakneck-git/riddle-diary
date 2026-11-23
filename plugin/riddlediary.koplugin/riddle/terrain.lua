-- Местность карты мародёров (план карты, раздел 2 «Местность»): улицы и здания вокруг точки из OpenStreetMap.
-- Чистые функции без сети и файлов (их делает riddle.mapjob): поле вокруг точки, запрос Overpass, сжатие ответа
-- в целые пиксели поля, проверка сжатого, смещение точки и решение «нужна ли новая местность».
-- terrain.KINDS — единственный список типов зданий: по нему генерируется словарь мест (раздел map, mapdata)
-- и размечаются здания местности.
local json = require("dkjson")
local geo = require("riddle.geo")

local terrain = {}

terrain.KINDS = { "school", "worship", "pub", "shop", "hospital", "station", "library", "park", "house" }

terrain.M_PER_PX = 0.7      -- экран 758 px ≈ 530 м — «несколько улиц»; подбирает тестер
terrain.QUERY_TIMEOUT_S = 45 -- [timeout:N] Overpass: время выполнения на сервере (очередь — сверх него)
-- улицы, по которым ходят и ездят, и их съезды *_link; дорожки, тропы и проезды дворов не рисуются.
-- Один список: из него и регулярка запроса, и отбор улиц в ответе
terrain.STREETS = { "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
                    "living_street", "pedestrian" }

local IS_KIND, IS_STREET = {}, {}
for _, k in ipairs(terrain.KINDS) do IS_KIND[k] = true end
for _, k in ipairs(terrain.STREETS) do IS_STREET[k], IS_STREET[k .. "_link"] = true, true end
local STREETS_RE = "^(" .. table.concat(terrain.STREETS, "|") .. ")(_link)?$"

local M_PER_DEG = geo.EARTH_M * math.pi / 180
local HOUSE = { house = true, residential = true, apartments = true, detached = true }

-- до ближайшего целого пикселя (поле здесь, экран карты — riddle_mapview)
function terrain.round(v) return math.floor(v + 0.5) end
local round = terrain.round

-- рамка плоского списка точек {x1,y1,…} (улица, контур здания) -> x0, y0, x1, y1
function terrain.bounds(pts)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #pts - 1, 2 do
    local x, y = pts[i], pts[i + 1]
    if x < x0 then x0 = x end
    if x > x1 then x1 = x end
    if y < y0 then y0 = y end
    if y > y1 then y1 = y end
  end
  return x0, y0, x1, y1
end

-- пикселей в градусе широты и долготы у широты lat при масштабе m_per_px
local function px_per_deg(lat, m_per_px)
  local py = M_PER_DEG / m_per_px
  return py * math.cos(math.rad(lat)), py
end

-- поле: экран и по полэкрана с каждой стороны (2 × экран по каждой оси), центр — точка.
-- -> { w, h, bbox = { south, west, north, east } }
function terrain.field(center, screen_w, screen_h)
  local w, h = 2 * screen_w, 2 * screen_h
  local px_lon, px_lat = px_per_deg(center.lat, terrain.M_PER_PX)
  local dlon, dlat = (w / 2) / px_lon, (h / 2) / px_lat
  return { w = w, h = h, bbox = { south = center.lat - dlat, west = center.lon - dlon,
                                  north = center.lat + dlat, east = center.lon + dlon } }
end

-- Overpass QL: улицы, здания и места из terrain.KINDS, не размеченные зданием (парк, двор школы), в bbox поля.
-- out tags geom — теги и координаты точек, без списков узлов (меньше ответ)
function terrain.query(bbox)
  return string.format("[out:json][timeout:%d][bbox:%.6f,%.6f,%.6f,%.6f];(" ..
    'way[highway~"%s"];way[building];way[leisure=park];' ..
    'way[amenity~"^(school|place_of_worship|pub|bar|hospital|library)$"];' ..
    "way[railway=station];way[public_transport=station];);out tags geom qt;",
    terrain.QUERY_TIMEOUT_S, bbox.south, bbox.west, bbox.north, bbox.east, STREETS_RE)
end

-- тип места по тегам OSM (план карты, срез 5) или nil — здание без типа
local function kind_of(tags)
  local a = tags.amenity
  if a == "school" or tags.building == "school" then return "school" end
  if a == "place_of_worship" then return "worship" end
  if a == "pub" or a == "bar" then return "pub" end
  if tags.shop then return "shop" end
  if a == "hospital" then return "hospital" end
  if tags.railway == "station" or tags.public_transport == "station" then return "station" end
  if a == "library" then return "library" end
  if tags.leisure == "park" then return "park" end
  if HOUSE[tags.building] then return "house" end
end

-- часть отрезка (x0,y0)-(x1,y1) внутри прямоугольника [left,right]×[top,bottom] (Лян — Барски):
-- -> t0, t1 (доли от начала отрезка) | nil — отрезок целиком снаружи. Поле здесь, экран карты — riddle_mapview
function terrain.clip(x0, y0, x1, y1, left, top, right, bottom)
  local t0, t1 = 0, 1
  local dx, dy = x1 - x0, y1 - y0
  for _, pq in ipairs({ { -dx, x0 - left }, { dx, right - x0 }, { -dy, y0 - top }, { dy, bottom - y0 } }) do
    local p, q = pq[1], pq[2]
    if p == 0 then
      if q < 0 then return nil end
    else
      local r = q / p
      if p < 0 then
        if r > t1 then return nil end
        if r > t0 then t0 = r end
      else
        if r < t0 then return nil end
        if r < t1 then t1 = r end
      end
    end
  end
  return t0, t1
end

-- точка в конец плоского списка, если она не совпадает с последней
local function push_pt(list, x, y)
  local n = #list
  if n >= 2 and list[n - 1] == x and list[n] == y then return end
  list[n + 1], list[n + 2] = x, y
end

-- полилиния (точки поля, дробные) -> куски внутри поля в целых пикселях, каждый ≥ 2 разных точек
local function clip_polyline(pts, w, h, out)
  local cur
  local function flush()
    if cur and #cur >= 4 then out[#out + 1] = cur end
    cur = nil
  end
  for i = 1, #pts - 2, 2 do
    local x0, y0, x1, y1 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
    local t0, t1 = terrain.clip(x0, y0, x1, y1, 0, 0, w, h)
    if not t0 then
      flush()
    else
      local ax, ay = round(x0 + (x1 - x0) * t0), round(y0 + (y1 - y0) * t0)
      if not cur then cur = {} end
      push_pt(cur, ax, ay)
      push_pt(cur, round(x0 + (x1 - x0) * t1), round(y0 + (y1 - y0) * t1))
      if t1 < 1 then flush() end
    end
  end
  flush()
end

-- ответ Overpass (строка JSON) -> местность в пикселях поля с центром center:
-- { center = {lat, lon}, w, h, m_per_px, streets = { {x1,y1,…} }, buildings = { { pts = {x1,y1,…}, kind? } } }.
-- Север вверху. Улицы обрезаны по полю; здание, целиком вне поля, отброшено. Имён и тегов в результате нет.
-- Сбой -> nil, "json" (не JSON, нет elements) | "remark" (ошибка выполнения Overpass при статусе 200: данные неполные)
function terrain.compact(raw, center, field)
  local ok, doc = pcall(json.decode, raw)
  if not ok or type(doc) ~= "table" then return nil, "json" end
  if type(doc.remark) == "string" and doc.remark:find("error", 1, true) then return nil, "remark" end
  if type(doc.elements) ~= "table" then return nil, "json" end
  local w, h = field.w, field.h
  local px_lon, px_lat = px_per_deg(center.lat, terrain.M_PER_PX)
  local cx, cy = w / 2, h / 2
  local streets, buildings = {}, {}
  for _, el in ipairs(doc.elements) do
    local tags, geom = type(el) == "table" and el.tags, type(el) == "table" and el.geometry
    if el.type == "way" and type(tags) == "table" and type(geom) == "table" then
      local pts = {}
      for _, p in ipairs(geom) do -- точка без координат (null) — пропуск
        if type(p) == "table" and type(p.lat) == "number" and type(p.lon) == "number" then
          pts[#pts + 1] = cx + (p.lon - center.lon) * px_lon
          pts[#pts + 1] = cy - (p.lat - center.lat) * px_lat
        end
      end
      if IS_STREET[tags.highway] then
        clip_polyline(pts, w, h, streets)
      elseif #pts >= 6 then
        local kind = kind_of(tags)
        if kind or tags.building then
          local ring = {}
          for i = 1, #pts, 2 do push_pt(ring, round(pts[i]), round(pts[i + 1])) end
          local x0, y0, x1, y1 = terrain.bounds(ring)
          if x1 >= 0 and y1 >= 0 and x0 <= w and y0 <= h and #ring >= 6 then
            buildings[#buildings + 1] = { pts = ring, kind = kind }
          end
        end
      end
    end
  end
  return { center = { lat = center.lat, lon = center.lon }, w = w, h = h, m_per_px = terrain.M_PER_PX,
           streets = streets, buildings = buildings }
end

local function num(v) return type(v) == "number" and v == v and v > -math.huge and v < math.huge end

-- точки местности — целые пиксели строго внутри (−COORD_MAX, COORD_MAX): на этом держится карта (cast): ключ узла
-- сети (node_key) уникален только для целых x и |y| < COORD_MAX, корзины обхода рассчитаны на рёбра ≥ 1 px
terrain.COORD_MAX = 2 ^ 21

local function px(v) return num(v) and v == math.floor(v) and v > -terrain.COORD_MAX and v < terrain.COORD_MAX end

local function flat_pts(list, min)
  if type(list) ~= "table" or #list < min or #list % 2 ~= 0 then return false end
  for i = 1, #list do if not px(list[i]) then return false end end
  return true
end

-- местность из файла годна для отрисовки (родитель доверяет только проверенной)
function terrain.valid(t)
  if type(t) ~= "table" or type(t.center) ~= "table" then return false end
  local c = t.center
  if not (num(c.lat) and num(c.lon) and c.lat >= -90 and c.lat <= 90 and c.lon >= -180 and c.lon <= 180) then
    return false
  end
  if not (num(t.w) and num(t.h) and num(t.m_per_px) and t.w > 0 and t.h > 0 and t.m_per_px > 0) then return false end
  if type(t.streets) ~= "table" or type(t.buildings) ~= "table" then return false end
  for _, s in ipairs(t.streets) do
    if not flat_pts(s, 4) then return false end
  end
  for _, b in ipairs(t.buildings) do
    if type(b) ~= "table" or not flat_pts(b.pts, 6) then return false end
    if b.kind ~= nil and not IS_KIND[b.kind] then return false end
  end
  return true
end

-- смещение точки от центра местности в пикселях её масштаба: dx к востоку, dy вниз (к югу)
function terrain.offset(t, point)
  local px_lon, px_lat = px_per_deg(t.center.lat, t.m_per_px)
  return (point.lon - t.center.lon) * px_lon, -(point.lat - t.center.lat) * px_lat
end

-- точка в dx, dy пикселях от центра местности (обратная к terrain.offset)
function terrain.at(t, dx, dy)
  local px_lon, px_lat = px_per_deg(t.center.lat, t.m_per_px)
  return { lat = t.center.lat - dy / px_lat, lon = t.center.lon + dx / px_lon }
end

-- местность покрывает точку: точка внутри поля (не дальше полуполя от центра по каждой оси). Не покрывает
-- (владелец уехал, новая не скачалась) — для карты как местности нет
function terrain.covers(t, point)
  local dx, dy = terrain.offset(t, point)
  return math.abs(dx) <= t.w / 2 and math.abs(dy) <= t.h / 2
end

-- нужна новая местность: её нет, масштаб другой или экран вокруг точки вышел бы за поле
-- (точка дальше полэкрана от центра по любой оси). screen = { w, h }
function terrain.needs_fetch(t, point, screen)
  if not terrain.valid(t) or t.m_per_px ~= terrain.M_PER_PX then return true end
  local dx, dy = terrain.offset(t, point)
  return math.abs(dx) > (t.w - screen.w) / 2 or math.abs(dy) > (t.h - screen.h) / 2
end

return terrain
