-- riddle.terrain: местность карты из OpenStreetMap (план карты, срез 5) — запрос Overpass, сжатие ответа в целые
-- пиксели поля, решение «нужна ли новая местность». Фикстура — синтетика у точки lat 10, lon 20 (не реальное место).
local t = require("t")
local json = require("dkjson")
local terrain = require("riddle.terrain")

local T = {}

local CENTER = { lat = 10.0, lon = 20.0 }
local SW, SH = 758, 1024 -- экран PW2
-- независимо от модуля: метров в градусе широты (сфера R = 6371 км), пикселей в градусе при 0,7 м/px
local PX_LAT = 6371000 * math.pi / 180 / 0.7
local PX_LON = PX_LAT * math.cos(math.rad(10))

local function fixture()
  local f = assert(io.open("tests/fixtures/overpass_small.json", "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function compacted()
  local field = terrain.field(CENTER, SW, SH)
  return assert(terrain.compact(fixture(), CENTER, field)), field
end

-- valid от копии местности tt, испорченной f (через JSON — как из файла)
local function broken(tt, f)
  local c = json.decode(json.encode(tt))
  f(c)
  return terrain.valid(c)
end

-- полилиния, у которой все y равны y0 (± 1 px)
local function find_street(tt, pred)
  for _, s in ipairs(tt.streets) do if pred(s) then return s end end
end

function T.test_field_is_twice_the_screen()
  local f = terrain.field(CENTER, SW, SH)
  t.eq(terrain.M_PER_PX, 0.7)
  t.eq(f.w, 2 * SW)
  t.eq(f.h, 2 * SH)
  local b = f.bbox
  t.ok(math.abs((b.north - b.south) * PX_LAT - f.h) < 1, "высота bbox = h пикселей")
  t.ok(math.abs((b.east - b.west) * PX_LON - f.w) < 1, "ширина bbox = w пикселей")
  t.ok(math.abs((b.north + b.south) / 2 - 10.0) < 1e-9 and math.abs((b.east + b.west) / 2 - 20.0) < 1e-9, "центр в точке")
end

function T.test_query_has_bbox_and_timeout()
  local f = terrain.field(CENTER, SW, SH)
  local q = terrain.query(f.bbox)
  t.ok(q:find("[out:json]", 1, true), q)
  t.ok(q:find("[timeout:45]", 1, true), q)
  local bb = string.format("[bbox:%.6f,%.6f,%.6f,%.6f]", f.bbox.south, f.bbox.west, f.bbox.north, f.bbox.east)
  t.ok(q:find(bb, 1, true), "bbox поля юг,запад,север,восток: " .. q)
  t.ok(q:find("way[building]", 1, true), q)
  t.ok(q:find("way[highway~", 1, true), q)
  t.ok(q:find("way[leisure=park]", 1, true), q)
  t.ok(q:find("out tags geom qt;", 1, true), "геометрия в ответе, без списков узлов: " .. q)
end

function T.test_compact_projects_to_field()
  local tt, field = compacted()
  t.eq(tt.w, field.w)
  t.eq(tt.h, field.h)
  t.eq(tt.center.lat, 10.0)
  t.eq(tt.center.lon, 20.0)
  t.eq(tt.m_per_px, 0.7)
  -- улица запад-восток через центр: y = h/2, x от центра ± 0,004° долготы
  local ew = find_street(tt, function(s) return #s == 6 and s[2] == 1024 and s[4] == 1024 end)
  t.ok(ew, "улица через центр на y = h/2")
  t.eq(ew[3], 758, "центр — w/2")
  t.eq(ew[1], 758 - math.floor(0.004 * PX_LON + 0.5))
  t.eq(ew[5], 758 + math.floor(0.004 * PX_LON + 0.5))
  -- улица юг-север: север вверху (y меньше)
  local ns = find_street(tt, function(s) return s[1] == 758 and s[3] == 758 end)
  t.ok(ns, "улица по долготе центра")
  t.eq(ns[2], 1024 + math.floor(0.005 * PX_LAT + 0.5), "юг внизу")
  t.eq(ns[4], 1024 - math.floor(0.005 * PX_LAT + 0.5), "север вверху")
  for _, s in ipairs(tt.streets) do
    for _, v in ipairs(s) do t.eq(v, math.floor(v), "целые пиксели") end
  end
end

function T.test_compact_kinds()
  local tt = compacted()
  local n = {}
  for _, b in ipairs(tt.buildings) do
    local k = b.kind or "none"
    n[k] = (n[k] or 0) + 1
  end
  t.eq(n.school, 1, "amenity=school без building — школа")
  t.eq(n.worship, 1)
  t.eq(n.pub, 1)
  t.eq(n.shop, 1)
  t.eq(n.park, 1)
  t.eq(n.station, 1)
  t.eq(n.hospital, 1)
  t.eq(n.library, 1)
  t.eq(n.house, 5, "house, residential, apartments, detached; дом за полем отброшен")
  t.eq(n.none, 1, "building=yes без признаков — здание без типа")
  local kinds = {}
  for _, k in ipairs(terrain.KINDS) do kinds[k] = true end
  for _, b in ipairs(tt.buildings) do
    t.ok(b.kind == nil or kinds[b.kind], "тип только из terrain.KINDS: " .. tostring(b.kind))
    t.ok(#b.pts >= 6 and #b.pts % 2 == 0, "контур — пары x,y")
  end
end

-- здание у края поля: целиком за краем — отброшено; задевает поле хоть пикселем (рамка по округлённым точкам) —
-- остаётся, контур целиком (за краем тоже)
function T.test_compact_building_at_field_edge()
  local field = terrain.field(CENTER, SW, SH)
  local cx, cy = field.w / 2, field.h / 2
  local function way(id, xs)
    local g = {}
    for _, xy in ipairs(xs) do
      g[#g + 1] = { lon = CENTER.lon + (xy[1] - cx) / PX_LON, lat = CENTER.lat - (xy[2] - cy) / PX_LAT }
    end
    return { type = "way", id = id, tags = { building = "yes" }, geometry = g }
  end
  local raw = json.encode({ elements = {
    way(1, { { -20, 100 }, { -2, 100 }, { -2, 120 }, { -20, 120 }, { -20, 100 } }), -- весь левее x = 0
    way(2, { { -20, 200 }, { 0.2, 200 }, { 0.2, 220 }, { -20, 220 }, { -20, 200 } }), -- правый край → x = 0
    way(3, { { 10, field.h + 0.4 }, { 30, field.h + 0.4 }, { 30, field.h + 9 }, { 10, field.h + 9 } }), -- низ → h
    way(4, { { 10, field.h + 2 }, { 30, field.h + 2 }, { 30, field.h + 9 }, { 10, field.h + 9 } }), -- весь ниже
  } })
  local tt = assert(terrain.compact(raw, CENTER, field))
  t.eq(#tt.buildings, 2, "два здания задевают поле")
  t.eq(tt.buildings[1].pts[1], -20, "контур не обрезан")
  t.eq(tt.buildings[1].pts[3], 0)
  t.eq(tt.buildings[2].pts[2], field.h)
end

function T.test_compact_drops_outside_field()
  local tt, field = compacted()
  t.eq(#tt.streets, 3, "улица за полем и пешеходная дорожка отброшены")
  t.eq(#tt.buildings, 14, "дом за полем отброшен")
  -- улица, уходящая за западный край, обрезана по краю поля
  local cut = find_street(tt, function(s) return s[2] == s[4] and s[2] < 1024 end)
  t.ok(cut, "улица через западный край")
  t.eq(cut[1], 0, "обрезана по x = 0")
  t.eq(cut[3], 758)
  for _, s in ipairs(tt.streets) do
    for i = 1, #s, 2 do
      t.ok(s[i] >= 0 and s[i] <= field.w and s[i + 1] >= 0 and s[i + 1] <= field.h, "улицы внутри поля")
    end
  end
  -- в сжатом нет имён и тегов OSM
  local s = json.encode(tt)
  t.ok(not s:find("Synthetic", 1, true), "имён нет")
  t.ok(not s:find("highway", 1, true), "тегов нет")
end

function T.test_compact_rejects_bad_answers()
  local field = terrain.field(CENTER, SW, SH)
  local r, err = terrain.compact("<html>502</html>", CENTER, field)
  t.eq(r, nil)
  t.eq(err, "json")
  r, err = terrain.compact('{"elements":[],"remark":"runtime error: Query timed out in \\"query\\" at line 1"}', CENTER, field)
  t.eq(r, nil, "ошибка выполнения Overpass приходит со статусом 200 и remark — данные неполные")
  t.eq(err, "remark")
  r, err = terrain.compact('{"version":0.6}', CENTER, field)
  t.eq(r, nil)
  t.eq(err, "json")
  local empty = terrain.compact('{"elements":[]}', CENTER, field)
  t.eq(#empty.streets, 0, "поле, лес: пустая местность годна")
  t.eq(#empty.buildings, 0)
end

local function at(dx_px, dy_px) -- точка в dx пикселей к востоку и dy к северу от центра местности
  return { lat = 10.0 + dy_px / PX_LAT, lon = 20.0 + dx_px / PX_LON }
end

local SCREEN = { w = SW, h = SH }

function T.test_needs_fetch_within_screen_false()
  local tt = compacted()
  t.eq(terrain.needs_fetch(tt, CENTER, SCREEN), false, "та же точка")
  t.eq(terrain.needs_fetch(tt, at(300, 0), SCREEN), false, "300 px к востоку — экран ещё в поле")
  t.eq(terrain.needs_fetch(tt, at(0, -450), SCREEN), false, "450 px к югу")
  local dx, dy = terrain.offset(tt, at(300, 200))
  t.ok(math.abs(dx - 300) < 0.5 and math.abs(dy + 200) < 0.5, "смещение точки в пикселях, y вниз: " .. dx .. "," .. dy)
end

-- точка по смещению (сдвиг карты пальцем, срез 9) — обратная к offset
function T.test_at_inverts_offset()
  local tt = compacted()
  local p = terrain.at(tt, 300, -200)
  t.ok(math.abs(p.lon - at(300, 200).lon) < 1e-9 and math.abs(p.lat - at(300, 200).lat) < 1e-9, "300 к востоку, 200 к северу")
  local dx, dy = terrain.offset(tt, terrain.at(tt, -123.5, 456.25))
  t.ok(math.abs(dx + 123.5) < 1e-6 and math.abs(dy - 456.25) < 1e-6, "туда и обратно: " .. dx .. "," .. dy)
end

function T.test_needs_fetch_beyond_screen_true()
  local tt = compacted()
  t.eq(terrain.needs_fetch(nil, CENTER, SCREEN), true, "местности нет")
  t.eq(terrain.needs_fetch(tt, at(400, 0), SCREEN), true, "400 px к востоку — экран вышел бы за поле")
  t.eq(terrain.needs_fetch(tt, at(0, 600), SCREEN), true, "600 px к северу")
  local other = compacted()
  other.m_per_px = 1.0
  t.eq(terrain.needs_fetch(other, CENTER, SCREEN), true, "масштаб сменился")
end

-- файл местности читает родитель: негодный — как нет
function T.test_valid_rejects_bad_shapes()
  local tt = compacted()
  t.eq(terrain.valid(tt), true)
  t.eq(terrain.valid(json.decode(json.encode(tt))), true, "после JSON")
  t.eq(terrain.valid(nil), false)
  t.eq(broken(tt, function(c) c.center = nil end), false)
  t.eq(broken(tt, function(c) c.w = "1516" end), false)
  t.eq(broken(tt, function(c) c.streets[1][3] = "x" end), false)
  t.eq(broken(tt, function(c) c.streets[1] = { 1, 2, 3 } end), false)
  t.eq(broken(tt, function(c) c.buildings[1].kind = "castle" end), false)
  t.eq(broken(tt, function(c) c.buildings[1].pts = { 1, 2 } end), false)
end

-- карта (cast) держит узлы сети числовым ключом (node_key, пределы — terrain.COORD_MAX) и корзины обхода по рёбрам
-- ≥ 1 px: файл с дробной или слишком большой координатой ломает оба — валидатор такой файл отвергает (Notion 41c13e60-bc8d-819c)
function T.test_valid_rejects_fractional_and_out_of_range_coords()
  local tt = compacted()
  local MAX = terrain.COORD_MAX
  t.eq(broken(tt, function(c) c.streets[1][1] = c.streets[1][1] + 0.5 end), false, "дробный x улицы")
  t.eq(broken(tt, function(c) c.streets[1][2] = c.streets[1][2] + 0.25 end), false, "дробный y улицы")
  t.eq(broken(tt, function(c) c.buildings[1].pts[1] = c.buildings[1].pts[1] + 0.5 end), false, "дробный x здания")
  t.eq(broken(tt, function(c) c.buildings[1].pts[2] = c.buildings[1].pts[2] + 0.5 end), false, "дробный y здания")
  t.eq(broken(tt, function(c) c.streets[1][2] = MAX end), false, "y улицы = предел")
  t.eq(broken(tt, function(c) c.streets[1][2] = -MAX end), false, "y улицы = −предел")
  t.eq(broken(tt, function(c) c.streets[1][1] = MAX end), false, "x улицы = предел")
  t.eq(broken(tt, function(c) c.buildings[1].pts[2] = MAX end), false, "y здания = предел")
  t.eq(broken(tt, function(c) c.streets[1][2] = MAX - 1 end), true, "y улицы — граничная целая")
  t.eq(broken(tt, function(c) c.streets[1][2] = 1 - MAX end), true, "y улицы — граничная целая вниз")
  t.eq(broken(tt, function(c) c.buildings[1].pts[1] = -(MAX - 1) end), true, "x здания — граничная целая")
end

t.run(T)
