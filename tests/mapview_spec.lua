-- Данные карты (riddle.mapdata) и перо дневника (riddle_ink) — план карты, срез 1.
local t = require("t")
local persona = require("riddle.persona")
local mapdata = require("riddle.mapdata")
local ink = require("riddle_ink")
local layout = require("riddle.layout")

local T = {}

-- «Методов» — мир Поттера: фразы открытия и закрытия канонические, по-русски (язык «Методов»)
function T.test_methods_is_potter_canon()
  local m = mapdata.of(persona.METHODS_VIEW, { id = persona.METHODS_ID }, nil)
  t.eq(m.potter, true)
  t.eq(m.open, mapdata.POTTER.ru.open)
  t.eq(m.close, mapdata.POTTER.ru.close)
end

-- сгенерированная персона без раздела map: надпись «не видит» по языку персоны;
-- язык неизвестен — английский (как нейтральный голос контроллера)
function T.test_blind_default_by_lang()
  local ru = mapdata.of({ lang = "ru" }, { id = 7, lang = "ru" }, {})
  t.eq(ru.potter, false)
  t.eq(ru.blind, mapdata.BLIND.ru)
  local en = mapdata.of({ lang = "en" }, { id = 7 }, {})
  t.eq(en.blind, mapdata.BLIND.en)
  local row_only = mapdata.of(nil, { id = 7, lang = "ru" }, nil)
  local none = mapdata.of(nil, nil, nil)
  t.eq(none.blind, mapdata.BLIND.en)
  t.eq(#none.cast, 0)
  t.eq(next(none.places), nil)
end

-- разделы карты сохранены, как их сохраняет генерация (persona.SECTIONS.decode)
local MP = require("fixtures.map_parts")
local json = require("dkjson")

local function parts_of(map_obj, cast)
  local p = { persona = "{}" }
  if map_obj then p.map = persona.section("map").decode(MP.wrap(map_obj)) end
  if cast then p["map.cast"] = persona.section("map.cast").decode(MP.wrap(cast)) end
  return p
end

-- персона ещё генерируется (раздела map нет) — запасные: название и blind по языку, мест и героев нет
-- (план карты, Review Focus 4); у «Методов» без разделов — канон Поттера и запасная blind
function T.test_mapdata_defaults_without_parts()
  local m = mapdata.of({ lang = "ru" }, { id = 7, lang = "ru" }, { persona = "{}" })
  t.eq(m.potter, false)
  t.eq(m.blind, mapdata.BLIND.ru)
  t.eq(m.open, nil)
  t.eq(m.close, nil)
  t.eq(next(m.places), nil)
  t.eq(#m.cast, 0)
  local only_map = mapdata.of({ lang = "ru" }, { id = 7 }, parts_of(MP.map, nil))
  t.eq(#only_map.cast, 0, "героев нет — карта без них")
  local methods = mapdata.of(persona.METHODS_VIEW, { id = persona.METHODS_ID }, {})
  t.eq(methods.potter, true)
  t.eq(methods.blind, mapdata.BLIND.ru)
  t.eq(#methods.cast, 0)
end

-- мир Поттера (признак из раздела map или «Методов»): название и фразы канонические, сгенерированные не берутся;
-- blind, места и герои — сгенерированные (план карты, раздел 6 п.1)
function T.test_mapdata_potter_canonical()
  local gen = json.decode(json.encode(MP.map))
  gen.potter, gen.open, gen.close = true, "Открыть карту", "Закрыть карту"
  gen.blind = "Карта пока слепа."
  gen.places = { school = "Класс трансфигурации", pub = "Дырявый котёл" }
  local m = mapdata.of({ lang = "ru" }, { id = 7, lang = "ru" }, parts_of(gen, MP.cast()))
  t.eq(m.potter, true)
  t.eq(m.open, mapdata.POTTER.ru.open)
  t.eq(m.close, mapdata.POTTER.ru.close)
  t.eq(m.blind, "Карта пока слепа.")
  t.eq(m.places.school, "Класс трансфигурации")
  t.eq(#m.cast, 10)
  local en = mapdata.of({ lang = "en" }, { id = 7 }, parts_of(gen, nil))
  t.eq(en.open, mapdata.POTTER.en.open)
  -- «Методов» — мир Поттера, даже если модель ответила potter = false
  local methods = mapdata.of(persona.METHODS_VIEW, { id = persona.METHODS_ID }, parts_of(MP.map, MP.cast()))
  t.eq(methods.potter, true)
  t.eq(methods.blind, MP.map.blind, "blind «Методов» — сгенерированная")
  t.eq(methods.places.pub, "Гарцующий пони")
end

-- другой мир: своё название и фразы, места и герои с ролью и распорядком (план карты, раздел 2)
function T.test_mapdata_other_world()
  local m = mapdata.of({ lang = "ru" }, { id = 7, lang = "ru" }, parts_of(MP.map, MP.cast()))
  t.eq(m.potter, false)
  t.eq(m.open, MP.map.open)
  t.eq(m.close, MP.map.close)
  t.eq(m.blind, MP.map.blind)
  t.eq(m.places.pub, "Гарцующий пони")
  t.eq(m.places.house, "Нора")
  t.eq(#m.cast, 10)
  local c = m.cast[9]
  t.eq(c.name, "Саруман")
  t.eq(c.role, "villain")
  t.eq(c.day, "work")
  t.eq(c.night, "street")
end

-- перо: штрих — отпечатки 4 px в каждой точке черты, без пропусков
function T.test_ink_line_stamps_every_step()
  local hits = {}
  local bb = { paintRect = function(_, x, y, w, h, c) hits[#hits + 1] = { x, y, w, h, c } end }
  ink.line(bb, 10, 20, 13, 20, 0, ink.stamp)
  t.eq(#hits, 8, "4 точки × 2 прямоугольника отпечатка")
  t.eq(hits[1][1], 9)
  t.eq(hits[1][2], 18)
  t.eq(hits[7][1], 12, "последняя точка — x 13")
  ink.stamp_small(bb, 5, 6, 0)
  t.eq(hits[9][3], 2, "малое перо — 2 px")
end

-- срез 5: местность тушью. Холст — запись paintRect; местность — сжатая синтетика (tests/fixtures/overpass_small.json)
package.loaded["ffi/blitbuffer"] = package.loaded["ffi/blitbuffer"] or { COLOR_WHITE = 0xFF, COLOR_BLACK = 0 }
local warns = {}
local infos = {}
package.loaded["logger"] = package.loaded["logger"] or {
  info = function(...) infos[#infos + 1] = table.concat({ ... }, " ") end, dbg = function() end,
  warn = function(...) warns[#warns + 1] = table.concat({ ... }, " ") end }
local clock = 0 -- часы карты (ui/time.monotonic) в секундах
package.loaded["ui/time"] = package.loaded["ui/time"] or { monotonic = function() return clock end,
  to_ms = function(x) return x * 1000 end }
local MapView = require("riddle_mapview")
local terrain = require("riddle.terrain")

local W, H = 758, 1024
local CENTER = { lat = 10.0, lon = 20.0 }
local PX_LON = 6371000 * math.pi / 180 / 0.7 * math.cos(math.rad(10))

local function fixture_terrain()
  local f = assert(io.open("tests/fixtures/overpass_small.json", "rb"))
  local s = f:read("*a")
  f:close()
  return assert(terrain.compact(s, CENTER, terrain.field(CENTER, W, H)))
end

-- ширина текста в моке: px/2 на знак, одна строка высотой px (без opts — шрифт приглашения, вся ширина)
local function text_w(text, px)
  local n = 0
  for _ in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
  return n * px / 2
end

-- diary: холст пишет каждый прямоугольник; paintText — список текстов (opts.dry — только размер, без записи);
-- schedule — очередь задач, run_tasks() выполняет её по порядку; push — список выводов на экран
local function map_diary(tt)
  local d = { w = W, h = H, CFG = { margin = 44, prompt_px = 36, map_idle_s = 180, map_ink_batches = 4, idle_s = 2.5,
                    map_step_s = 2.5, map_trail = 4, dissolve = { wf = "DU" }, answer_px = 42 },
              texts = {}, rects = {}, pushes = {}, tasks = {},
              map_clock = function() return { hour = 12, wday = 3, month = 10 } end } -- вторник, полдень
  -- seq — порядок записи на холст: прямоугольник — его 6-й элемент, текст — поле seq
  d.seq = 0
  local function nxt() d.seq = d.seq + 1 return d.seq end
  d.canvas = { fill = function() d.rects = {} end,
               paintRect = function(_, x, y, w, h, c) d.rects[#d.rects + 1] = { x, y, w, h, c, nxt() } end }
  d.paintText = function(_, text, top, opts)
    if not opts then
      d.texts[#d.texts + 1] = { text = text, top = top, seq = nxt() }
      return { x = 0, y = top, w = 100, h = 40 }
    end
    local w = text_w(text, opts.px)
    local r = { x = opts.cx - w / 2, y = top, w = w, h = opts.px }
    if opts.dry then
      d.dry_opts = opts
    else
      d.texts[#d.texts + 1] = { text = text, top = top, rect = r, px = opts.px, opts = opts, seq = nxt() }
    end
    return r
  end
  -- пачка текстов (Diary:paintTexts): здесь — те же записи по одному
  d.paintTexts = function(self, list)
    local out = {}
    for i, it in ipairs(list) do out[i] = self:paintText(it[1], it[2], it[3]) end
    return out
  end
  d.map_terrain = function() return tt end
  d.push = function(_, x, y, w, h, mode) d.pushes[#d.pushes + 1] = { x, y, w, h, mode } end
  d.schedule = function(_, s, fn)
    local task = { s = s, fn = fn }
    d.tasks[#d.tasks + 1] = task
    return task
  end
  d.cancel = function(_, task)
    for i, x in ipairs(d.tasks) do if x == task then table.remove(d.tasks, i) return end end
  end
  return d
end

-- выполнить назначенные задачи с шагом s (только задачи этого шага, по порядку назначения; не больше max,
-- назначенные по ходу — тоже) -> сколько выполнено
local function run_tasks(d, s, max)
  local ran = 0
  while not max or ran < max do
    local found
    for i, x in ipairs(d.tasks) do if x.s == s then found = table.remove(d.tasks, i) break end end
    if not found then return ran end
    clock = clock + s
    found.fn()
    ran = ran + 1
  end
  return ran
end

-- закрашен ли пиксель отпечатком пера (прямоугольники ≤ 2 px — перо, крупные — рамка)
local function inked(d, x, y)
  for _, r in ipairs(d.rects) do
    if r[3] <= 2 and r[4] <= 2 and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4] then return true end
  end
  return false
end

local function has_text(d, s)
  for _, e in ipairs(d.texts) do if e.text == s then return e end end
end

function T.test_terrain_drawn_around_point()
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, mapdata.of(nil, nil, nil), CENTER)
  v:paint()
  -- две улицы крест-накрест через точку: центр экрана
  t.ok(inked(d, W / 2, H / 2), "перекрёсток в центре экрана")
  t.ok(inked(d, W / 2, H / 2 - 200), "улица на север")
  t.ok(inked(d, W / 2 - 200, H / 2), "улица на запад")
  t.ok(not inked(d, W / 2 + 100, H / 2 + 100), "между улицами пусто")
  t.ok(not has_text(d, "© OpenStreetMap"), "атрибуции нет — карта на весь экран")
  t.ok(not has_text(d, mapdata.BLIND.en), "точка есть — без blind")
  -- тушь только внутри рамки (до самой рамки сверху и снизу — поле не занято ни заголовком, ни атрибуцией)
  for _, r in ipairs(d.rects) do
    if r[3] <= 2 and r[4] <= 2 then
      t.ok(r[1] >= 25 and r[1] + r[3] <= W - 25 and r[2] >= 25 and r[2] + r[4] <= H - 25,
        "отпечаток внутри рамки: " .. table.concat(r, ","))
    end
  end
end

-- карта на весь экран (владелец 2026-11-16): ни заголовка, ни «© OpenStreetMap» — поле туши от рамки до рамки
function T.test_ink_box_is_90_percent_of_pw2_screen()
  local d = map_diary(fixture_terrain())
  d.w, d.h = 1072, 1448
  local v = MapView.new(d, mapdata.of(nil, nil, nil), CENTER)
  v:paint()
  local b = assert(v.box, "поле туши есть")
  local share = (b[3] - b[1]) * (b[4] - b[2]) / (d.w * d.h)
  t.ok(share >= 0.9, "поле туши — не меньше 90% экрана, сейчас " .. math.floor(share * 1000) / 10 .. "%")
  t.eq(#d.texts, 0, "на карте с местностью нет ни заголовка, ни атрибуции (подписи зданий — отдельно)")
end

function T.test_blind_map_has_only_blind_text()
  local d = map_diary(nil)
  local data = mapdata.of(nil, nil, nil)
  MapView.new(d, data, CENTER):paint()
  t.eq(#d.texts, 1, "paintText зовётся один раз")
  t.eq(d.texts[1].text, data.blind)
end

-- точка сдвинулась на 100 px к востоку от центра местности: местность уезжает на 100 px к западу
function T.test_terrain_shifted_by_point_offset()
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, mapdata.of(nil, nil, nil), { lat = 10.0, lon = 20.0 + 100 / PX_LON })
  v:paint()
  t.ok(inked(d, W / 2 - 100, H / 2 - 200), "улица юг-север на x − 100")
  t.ok(not inked(d, W / 2, H / 2 - 200), "в центре её нет")
end

-- нет местности (Overpass не ответил, файла нет) — пергамент без туши, blind; без точки при сохранённой местности —
-- местность по её центру (спека, раздел 3)
function T.test_no_terrain_no_ink()
  local d = map_diary(nil)
  local v = MapView.new(d, mapdata.of(nil, nil, nil), CENTER)
  v:paint()
  t.ok(not inked(d, W / 2, H / 2))
  t.ok(has_text(d, mapdata.BLIND.en), "точка есть, местности нет — blind (решение оркестратора 2026-11-16)")
  -- без точки, местность сохранена: спека, раздел 3 — последняя сохранённая местность, по её центру
  local d2 = map_diary(fixture_terrain())
  MapView.new(d2, mapdata.of(nil, nil, nil), nil):paint()
  t.ok(inked(d2, W / 2, H / 2), "без точки — местность по её центру")
  t.ok(not has_text(d2, mapdata.BLIND.en), "местность сохранена — не blind")
  local d3 = map_diary(nil)
  d3.map_terrain = function() error("disk") end
  MapView.new(d3, mapdata.of(nil, nil, nil), CENTER):paint()
  t.ok(has_text(d3, mapdata.BLIND.en), "сбой чтения — как нет местности: blind")
  t.ok(warns[#warns] and warns[#warns]:find("riddle: map terrain read failed", 1, true), "сбой чтения в логе")
end

-- старая местность не покрывает точку (владелец уехал, новый Overpass упал): спека, раздел 3 — «Без интернета —
-- последняя сохранённая местность»: она рисуется по своему центру, не blind (blind — только без местности)
function T.test_terrain_far_from_point_draws_its_center()
  local tt = fixture_terrain()
  local d = map_diary(tt)
  local v = MapView.new(d, mapdata.of(nil, nil, nil), { lat = 10.0, lon = 20.0 + 800 / PX_LON })
  v:paint()
  t.ok(not has_text(d, mapdata.BLIND.en), "точка за полуполем (758 px) — не blind")
  t.ok(inked(d, W / 2, H / 2), "перекрёсток центра местности — в центре экрана")
  t.ok(v:pan(100, 0), "сохранённую местность можно двигать пальцем")
  local d2 = map_diary(tt)
  MapView.new(d2, mapdata.of(nil, nil, nil), { lat = 10.0, lon = 20.0 + 700 / PX_LON }):paint()
  t.ok(not has_text(d2, mapdata.BLIND.en), "в пределах полуполя — местность рисуется")
  t.ok(d2.rects[#d2.rects], "пергамент нарисован")
end

-- задание принесло новую местность при той же точке — карта перерисована с ней
function T.test_set_point_brings_new_terrain()
  local d = map_diary(nil)
  local pushes = 0
  d.push = function() pushes = pushes + 1 end
  local v = MapView.new(d, mapdata.of(nil, nil, nil), CENTER)
  v:open()
  t.ok(not inked(d, W / 2, H / 2), "местности ещё нет")
  local before = pushes
  d.map_terrain = function() return fixture_terrain() end
  v:setPoint(CENTER, true)
  -- срез 6: новая местность проступает партиями, а не вся сразу
  t.ok(not inked(d, W / 2, H / 2), "сразу — только пергамент")
  t.ok(run_tasks(d, MapView.INK_STEP_S) >= 1, "проявление назначено")
  t.ok(inked(d, W / 2, H / 2), "местность пришла — нарисована")
  t.ok(pushes > before, "выведена на экран")
  -- то же ещё раз: ничего не изменилось — без перерисовки
  before = pushes
  v:setPoint(CENTER, true) -- задание перекачало ту же
  t.eq(pushes, before, "та же местность — экран не трогается")
end

-- срез 6: подписи зданий на языке вселенной и проявление чернилами.
-- Тесты подписей и героев срезов 6–7, где подписанное здание стоит посреди экрана, открывают карту без точки владельца:
-- экран тот же (по центру местности), а книги нет — с точкой там книга (срез 13а), и подпись у неё пропускается

-- данные карты мира Поттера: места — словарь раздела map, как его сохраняет генерация
local function potter_data(places)
  local gen = json.decode(json.encode(MP.map))
  gen.potter, gen.places = true, places
  return mapdata.of({ lang = "ru" }, { id = 7, lang = "ru" }, parts_of(gen, nil))
end

local PLACES = { school = "Класс трансфигурации", worship = "Часовня", pub = "Дырявый котёл", house = "Нора",
                 library = "Запретная секция" }

local function labels_of(d)
  local out = {}
  for _, e in ipairs(d.texts) do if e.rect then out[#out + 1] = e end end
  return out
end

local function label_text(d, s)
  for _, e in ipairs(labels_of(d)) do if e.text == s then return e end end
end

-- подпись внутри рамки (поле туши — от рамки до рамки)
local function inside(_, r)
  return r.x >= 25 and r.x + r.w <= W - 25 and r.y >= 25 and r.y + r.h <= H - 25
end

function T.test_label_from_places()
  local data = potter_data(PLACES)
  t.eq(mapdata.label(data, "school"), "Класс трансфигурации")
  t.eq(mapdata.label(data, "pub"), "Дырявый котёл")
  -- на карте: школа фикстуры (экран 692–754 × 766–830) подписана, подпись сдвинута внутрь рамки
  local d = map_diary(fixture_terrain())
  MapView.new(d, data, CENTER):paint()
  local school = label_text(d, "Класс трансфигурации")
  t.ok(school, "школа подписана словом вселенной")
  t.ok(inside(d, school.rect), "подпись не выходит за экран: " .. school.rect.x .. "+" .. school.rect.w)
  t.ok(school.rect.y <= 798 and school.rect.y + school.rect.h >= 798, "по высоте — на центре контура")
  t.ok(label_text(d, "Часовня"), "храм")
  t.ok(label_text(d, "Дырявый котёл"), "паб")
end

function T.test_no_label_for_house_or_unknown()
  local data = potter_data(PLACES)
  t.eq(mapdata.label(data, "house"), nil, "жилой дом не подписывается, даже если в словаре есть")
  t.eq(mapdata.label(data, "hospital"), nil, "типа нет в словаре")
  t.eq(mapdata.label(data, nil), nil, "здание без типа")
  t.eq(mapdata.label(mapdata.of(nil, nil, nil), "school"), nil, "раздела map нет — подписей нет")
  t.eq(mapdata.label(potter_data({ school = "" }), "school"), nil, "пустое название — нет подписи")
  local d = map_diary(fixture_terrain())
  MapView.new(d, data, CENTER):paint()
  t.ok(not label_text(d, "Нора"), "дома без подписей")
  local d2 = map_diary(fixture_terrain())
  MapView.new(d2, mapdata.of(nil, nil, nil), CENTER):paint()
  t.eq(#labels_of(d2), 0, "без словаря — ни одной подписи")
end

-- квадрат 20 × 20 px с центром в точке экрана (x, y); экран — середина поля 2 × экран
local function square(x, y, kind)
  local fx, fy = x + W / 2, y + H / 2
  return { kind = kind, pts = { fx - 10, fy - 10, fx + 10, fy - 10, fx + 10, fy + 10, fx - 10, fy + 10 } }
end

function T.test_labels_do_not_overlap()
  local tt = { center = CENTER, w = 2 * W, h = 2 * H, m_per_px = terrain.M_PER_PX, streets = {}, buildings = {
    square(300, 400, "school"), square(320, 405, "pub"), -- рядом: подписи легли бы друг на друга
    square(150, 700, "worship"),
    square(720, 600, "library"),                          -- у правого края: подпись сдвигается внутрь
    square(400, 300, "house"),
  } }
  local d = map_diary(tt)
  MapView.new(d, potter_data(PLACES), CENTER):paint()
  local ls = labels_of(d)
  t.eq(#ls, 3, "из двух соседних — одна; храм; библиотека")
  t.ok(label_text(d, "Часовня") and label_text(d, "Запретная секция"))
  t.ok((label_text(d, "Класс трансфигурации") ~= nil) ~= (label_text(d, "Дырявый котёл") ~= nil),
    "пересёкшаяся следующая пропущена")
  for i, a in ipairs(ls) do
    t.ok(inside(d, a.rect), "внутри рамки: " .. a.text)
    for j = i + 1, #ls do
      local b = ls[j].rect
      local r = a.rect
      t.ok(r.x + r.w <= b.x or b.x + b.w <= r.x or r.y + r.h <= b.y or b.y + b.h <= r.y,
        "не пересекаются: " .. a.text .. " / " .. ls[j].text)
    end
  end
end

function T.test_ink_batches_cover_all_once()
  local tt = fixture_terrain()
  local d = map_diary(tt)
  local v = MapView.new(d, potter_data(PLACES), CENTER)
  v:paint()
  local steps = v:inkSteps()
  t.eq(#steps, 4, "четыре партии")
  local seen = {}
  for _, batch in ipairs(steps) do
    t.ok(#batch > 0, "партия не пуста")
    for _, way in ipairs(batch) do
      t.eq(seen[way.pts], nil, "линия — в одной партии и один раз")
      seen[way.pts] = true
    end
  end
  -- на экране: все улицы и здания, кроме лежащих за рамкой (больница, парк, вокзал, библиотека, лавка у края)
  -- (третья улица, y = 35 px экрана, лежала выше заголовка; без заголовка поле начинается у рамки — она на месте)
  local off = { hospital = true, park = true, station = true, library = true, shop = true }
  local want = 0
  for i, s in ipairs(tt.streets) do
    t.ok(seen[s], "улица " .. i .. " в партиях")
    want = want + 1
  end
  for _, b in ipairs(tt.buildings) do
    if off[b.kind] then
      t.ok(not seen[b.pts], "за экраном — не рисуется: " .. b.kind)
    else
      t.ok(seen[b.pts], "здание в партиях: " .. tostring(b.kind))
      want = want + 1
    end
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  t.eq(n, want)

  -- проявление: пергамент сразу (full), линии — партиями по INK_STEP_S в DU, подписи — с последней
  local d2 = map_diary(tt)
  local v2 = MapView.new(d2, potter_data(PLACES), CENTER)
  infos[#infos + 1] = "-"
  v2:open()
  t.eq(#d2.pushes, 1)
  t.eq(d2.pushes[1][5], "full")
  t.ok(#d2.rects > 0, "пергамент сразу")
  t.ok(not inked(d2, W / 2, H / 2), "линий ещё нет")
  local counts = {}
  for k = 1, 4 do
    t.eq(run_tasks(d2, MapView.INK_STEP_S, 1), 1, "шаг " .. k)
    counts[k] = #d2.rects
    t.eq(d2.pushes[#d2.pushes][5], "DU", "шаг — частичное DU")
    if k > 1 then t.ok(counts[k] > counts[k - 1], "каждая партия добавляет туши") end
    if k < 4 then t.eq(#labels_of(d2), 0, "подписи — после линий") end
  end
  t.eq(run_tasks(d2, MapView.INK_STEP_S), 0, "проявление окончено")
  t.ok(inked(d2, W / 2, H / 2), "линии на месте")
  t.ok(label_text(d2, "Класс трансфигурации"), "подписи с последней партией")
  t.eq(infos[#infos], "riddle: map drawn ways=" .. want .. " labels=3 in " .. math.floor(4 * MapView.INK_STEP_S * 1000 + 0.5) .. " ms")
  for _, e in ipairs(infos) do t.ok(not e:find("Класс", 1, true), "в логе нет названий") end

  -- карта закрыта посреди проявления: оставшиеся партии не рисуются
  local d3 = map_diary(tt)
  local v3 = MapView.new(d3, potter_data(PLACES), CENTER)
  v3:open()
  -- перо на стекле: партия ждёт шаг, экран под пером не обновляется
  d3.cur = {}
  local rects, pushes = #d3.rects, #d3.pushes
  t.eq(run_tasks(d3, MapView.INK_STEP_S, 1), 1)
  t.eq(#d3.rects, rects, "под пером партия не рисуется")
  t.eq(#d3.pushes, pushes, "и не выводится")
  d3.cur = nil
  t.eq(run_tasks(d3, MapView.INK_STEP_S, 1), 1, "первая партия")
  t.ok(#d3.rects > rects, "перо поднято — партия нарисована")
  v3:close()
  local after = #d3.rects
  t.eq(run_tasks(d3, MapView.INK_STEP_S), 0, "после закрытия шагов нет")
  t.eq(#d3.rects, after)
end

-- полная перерисовка посреди проявления (сдвиг поля, страница на карте): проявление снято, линии все на холсте,
-- экран обновлён целиком — недопроявленное иначе осталось бы только на холсте
function T.test_paint_mid_reveal_stops_it()
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, potter_data(PLACES), CENTER)
  v:open()
  t.eq(run_tasks(d, MapView.INK_STEP_S, 1), 1, "первая партия")
  t.eq(v:paint(), true, "paint сообщает: проявление прервано")
  t.eq(run_tasks(d, MapView.INK_STEP_S), 0, "шагов проявления в очереди нет")
  t.ok(inked(d, W / 2, H / 2) and label_text(d, "Класс трансфигурации"), "линии и подписи — сразу все")
  t.eq(v:paint(), false, "проявления уже нет")
  -- настройка партий 0 или меньше — одна партия со всеми линиями
  for _, bad in ipairs({ 0, -1 }) do
    d.CFG.map_ink_batches = bad
    local st, all = v:inkSteps(), 0
    t.eq(#st, 1, "партий " .. bad .. " — одна партия")
    for _, b in ipairs(st) do all = all + #b end
    t.eq(all, #v:visibleWays(), "партий " .. bad .. " — все линии в ней")
  end

  -- страница на карте дописана посреди проявления: не роза, ушла модели; экран — целиком
  local d2 = map_diary(fixture_terrain())
  d2.isRose = function() return false end
  local read = 0
  d2.readMapPage = function() read = read + 1 end
  local v2 = MapView.new(d2, potter_data(PLACES), CENTER)
  v2:open()
  t.eq(run_tasks(d2, MapView.INK_STEP_S, 1), 1)
  v2.page = { strokes = { { p = { 100, 300, 120, 320 }, b = { 100, 300, 120, 320 } } }, ink = { 100, 300, 120, 320 } }
  v2:onPageDone()
  t.eq(read, 1, "страница ушла на чтение")
  t.eq(run_tasks(d2, MapView.INK_STEP_S), 0, "проявление снято")
  local p = d2.pushes[#d2.pushes]
  t.ok(p[1] == 0 and p[2] == 0 and p[3] == W and p[4] == H, "push на весь экран: " .. table.concat(p, ",", 1, 4))
  -- та же страница без проявления — push только её рамки
  v2.page = { strokes = { { p = { 100, 300, 120, 320 }, b = { 100, 300, 120, 320 } } }, ink = { 100, 300, 120, 320 } }
  v2:onPageDone()
  p = d2.pushes[#d2.pushes]
  t.ok(p[3] < W and p[4] < H, "без проявления — только рамка страницы")
end

-- срез 9: сдвиг поля пальцем. Зоны: полоса у любого края — «edge», нижняя полоса — «pad» (тачпад, углы снизу —
-- тоже pad), середина — чернила
local ZONES = { map_edge_px = 83, map_pad_px = 167, map_edge_extra = 0 }

function T.test_zone_edges_and_pad()
  local z = function(x, y) return MapView.zone(x, y, W, H, ZONES) end
  t.eq(z(W / 2, H / 2), nil, "середина — чернила")
  t.eq(z(0, H / 2), "edge", "левый край")
  t.eq(z(82, H / 2), "edge", "левая полоса — 83 px")
  t.eq(z(83, H / 2), nil, "за полосой — чернила")
  t.eq(z(W - 83, H / 2), "edge", "правая полоса")
  t.eq(z(W - 84, H / 2), nil)
  t.eq(z(W / 2, 0), "edge", "верхний край")
  t.eq(z(W / 2, 83), nil)
  t.eq(z(W - 1, 0), "edge", "верхний правый угол (угол выхода) — край")
  t.eq(z(0, 0), "edge", "верхний левый угол")
  t.eq(z(W / 2, H - 1), "pad", "нижний край — тачпад")
  t.eq(z(W / 2, H - 167), "pad", "нижняя полоса — 167 px")
  t.eq(z(W / 2, H - 168), nil, "над тачпадом — чернила")
  t.eq(z(0, H - 1), "pad", "нижний левый угол — тачпад")
  t.eq(z(W - 1, H - 1), "pad", "нижний правый угол — тачпад")
  t.eq(z(10, H - 168), "edge", "над тачпадом у края — край")
end

-- владелец 2026-11-16: «расширь зону управления картой на 10% (от размера экрана) по левой правой и верхней границам» —
-- бока: полоса + 10% ширины, верх: полоса + 10% высоты, низ как был
function T.test_zone_wider_sides_and_top()
  local cfg = { map_edge_px = 83, map_pad_px = 167, map_edge_extra = 0.10 }
  local z = function(x, y) return MapView.zone(x, y, W, H, cfg) end
  t.eq(z(158, H / 2), "edge", "левая полоса — 83 + 76 = 159 px")
  t.eq(z(159, H / 2), nil)
  t.eq(z(W - 159, H / 2), "edge", "правая полоса")
  t.eq(z(W - 160, H / 2), nil)
  t.eq(z(W / 2, 184), "edge", "верх — 83 + 102 = 185 px")
  t.eq(z(W / 2, 185), nil)
  t.eq(z(W / 2, H - 167), "pad")
  t.eq(z(W / 2, H - 168), nil, "низ не изменился")
  t.eq(z(0, 0), "edge")
end

function T.test_zone_scales_with_screen()
  local cfg = { map_edge_px = 83, map_pad_px = 167, map_edge_extra = 0.10 }
  local w, h = 1072, 1448
  local z = function(x, y) return MapView.zone(x, y, w, h, cfg) end
  t.eq(z(189, h / 2), "edge", "бока 83 + 107 = 190 px")
  t.eq(z(190, h / 2), nil)
  t.eq(z(w - 190, h / 2), "edge")
  t.eq(z(w - 191, h / 2), nil)
  t.eq(z(w / 2, 227), "edge", "верх 83 + 145 = 228 px")
  t.eq(z(w / 2, 228), nil)
end

-- отпечатки толстого пера (ink.stamp: 2×4 и 4×2) — чернила пальца, не местность (перо местности — 2×2)
local function finger_ink(d, x, y)
  for _, r in ipairs(d.rects) do
    if (r[3] == 4 and r[4] == 2 or r[3] == 2 and r[4] == 4) and x >= r[1] and x < r[1] + r[3]
      and y >= r[2] and y < r[2] + r[4] then return true end
  end
  return false
end

-- одни и те же отпечатки (порядок не важен)
local function same_rects(a, b)
  local function key(rs)
    local out = {}
    for i, r in ipairs(rs) do out[i] = table.concat(r, ",") end
    table.sort(out)
    return table.concat(out, ";")
  end
  return key(a) == key(b)
end

local function panned(dx, dy)
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, mapdata.of(nil, nil, nil), CENTER)
  v:open()
  local moved = v:pan(dx, dy)
  return d, moved
end

-- сдвиг: местность идёт за пальцем; дальше поля не уходит (поле 2 × экран: по полэкрана с каждой стороны)
function T.test_pan_clamped_to_field()
  local d, moved = panned(100, -60)
  t.ok(moved, "сдвиг состоялся")
  t.ok(inked(d, W / 2 + 100, H / 2 - 260), "улица юг-север — на 100 px правее, за пальцем")
  t.ok(inked(d, W / 2 - 250, H / 2 - 60), "улица запад-восток — на 60 px выше")
  t.ok(not inked(d, W / 2, H / 2 - 260), "на старом месте её нет")
  t.ok(not has_text(d, mapdata.BLIND.en), "пергамент перерисован целиком: местность на месте")
  -- предел: экран не выходит за поле — полэкрана (379 px по x, 512 по y) от центра
  local edge = panned(W / 2, 0)
  local far = panned(10000, 0)
  t.ok(same_rects(far.rects, edge.rects), "сдвиг дальше поля — как до края поля")
  t.ok(not same_rects(panned(W / 2 - 1, 0).rects, edge.rects), "до края — ещё двигается")
  local top, beyond = panned(0, H / 2), panned(0, 5000)
  t.ok(same_rects(top.rects, beyond.rects), "по y — тоже до края поля")
  -- у края поля: дальше не двигается, обратно — да
  local d2 = map_diary(fixture_terrain())
  local v = MapView.new(d2, mapdata.of(nil, nil, nil), CENTER)
  v:open()
  t.ok(v:pan(10000, 0), "до края")
  t.eq(v:pan(50, 0), false, "у края поля дальше нет — без перерисовки")
  t.ok(v:pan(-50, 0), "обратно — можно")
  -- без местности двигать нечего
  local d3 = map_diary(nil)
  local v3 = MapView.new(d3, mapdata.of(nil, nil, nil), CENTER)
  v3:open()
  t.eq(v3:pan(100, 0), false, "без местности — blind, сдвига нет")
end

-- точка у края поля (дальше полэкрана от центра местности): нулевой сдвиг рисует как раньше, сдвиг внутрь поля — можно,
-- наружу — нет
function T.test_pan_point_near_field_edge()
  local p = { lat = 10.0, lon = 20.0 + 500 / PX_LON }
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, mapdata.of(nil, nil, nil), p)
  v:paint() -- всё сразу, без проявления (срез 6)
  -- ревью среза 10, Б3: экран не выходит за поле и без сдвига — встаёт у края поля (левый край экрана — x 758 поля);
  -- улица запад-восток кончается в поле на x 1384: на экране — у x 1384 − 758 = 626
  t.ok(inked(d, 620, H / 2) and not inked(d, 640, H / 2), "без сдвига — экран у края поля")
  t.eq(v:pan(-30, 0), false, "наружу поля — нет")
  t.ok(v:pan(30, 0), "внутрь — да, от того, где экран стоит")
  t.ok(inked(d, 650, H / 2) and not inked(d, 670, H / 2), "конец улицы — на 30 px правее")
end

-- подписи и местность — от одной точки вида: после сдвига подпись уехала на тот же вектор, что и линии
function T.test_pan_moves_labels_with_lines()
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, potter_data(PLACES), CENTER)
  v:paint()
  local pub = label_text(d, "Дырявый котёл").rect -- паб фикстуры — середина экрана, подпись не прижата к рамке
  t.ok(inked(d, W / 2, H / 2 - 200), "улица юг-север до сдвига")
  d.texts = {} -- тексты фейка копятся между перерисовками
  t.ok(v:pan(-40, -30))
  local moved = label_text(d, "Дырявый котёл").rect
  t.eq(moved.x - pub.x, -40, "подпись — на 40 левее")
  t.eq(moved.y - pub.y, -30, "и на 30 выше")
  t.ok(inked(d, W / 2 - 40, H / 2 - 200), "улица — на те же 40 левее")
  t.ok(not inked(d, W / 2, H / 2 - 200))
  t.ok(inked(d, W / 2 - 200, H / 2 - 30), "улица запад-восток — на те же 30 выше")
end

-- карта закрыта посреди тачпада (палец лежит, следующий шаг ждёт таймера): ни одного таймера карты не осталось
-- (проявление, автозакрытие, страница, шаг тачпада), и перерисовок больше нет
function T.test_close_mid_pad_leaves_no_timers()
  local d = map_diary(fixture_terrain())
  d.CFG.map_edge_px, d.CFG.map_pad_px, d.CFG.map_pan_slop_px, d.CFG.map_drag_s = 83, 167, 10, 0.4
  local live = {}
  d.schedule = function(_, _, fn) local task = { fn = fn } live[task] = true return task end
  d.cancel = function(_, task) if task then live[task] = nil end end
  local pushes = 0
  d.push = function() pushes = pushes + 1 end
  local v = MapView.new(d, mapdata.of(nil, nil, nil), CENTER)
  v:open()
  t.ok(v:dragStart(300, 950), "тачпад")
  v:dragMove(340, 950) -- шаг сразу, следующий — по таймеру
  v:dragMove(380, 950)
  t.ok(v.drag_task, "шаг тачпада ждёт таймера")
  v:close()
  t.eq(next(live), nil, "таймеров карты не осталось")
  local before = pushes
  for task in pairs(live) do task.fn() end
  t.eq(pushes, before, "после закрытия — ни одной перерисовки")
end

-- страница карты (крест, ещё не дописана) при сдвиге остаётся на стекле
function T.test_pan_keeps_page_ink()
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, mapdata.of(nil, nil, nil), CENTER)
  v:open()
  v:onStrokeDone({ p = { 300, 400, 340, 400 }, b = { 300, 400, 340, 400 } })
  t.ok(v:pan(40, 0))
  t.ok(finger_ink(d, 320, 400), "штрих страницы перерисован поверх местности")
end

-- решение владельца 2026-11-16: заголовок карты не рисуется — формат раздела map его не несёт, mapdata.of его не отдаёт;
-- старый сохранённый раздел с title читается без ошибки, лишний ключ игнорируется
function T.test_map_data_has_no_title_and_old_saved_section_with_title_reads()
  local old = json.decode(json.encode(MP.map))
  old.title = "Карта Средиземья" -- как раздел сохраняли до решения
  local saved = json.encode(old)
  local m = mapdata.of({ lang = "ru" }, { id = 7, lang = "ru" }, { persona = "{}", map = saved })
  t.eq(m.title, nil, "заголовка у данных карты нет")
  t.eq(m.open, MP.map.open, "остальное читается: " .. saved)
  t.eq(m.blind, MP.map.blind)
  t.eq(m.places.pub, "Гарцующий пони")
  for _, case in ipairs({
    { persona.METHODS_VIEW, { id = persona.METHODS_ID }, nil },
    { { lang = "en" }, { id = 7 }, {} },
    { nil, nil, nil },
    { { lang = "ru" }, { id = 7 }, { map = saved } },
    { persona.METHODS_VIEW, { id = persona.METHODS_ID }, { map = saved } },
  }) do
    t.eq(mapdata.of(case[1], case[2], case[3]).title, nil, "title нет ни у одной ветки of")
  end
  t.eq(mapdata.POTTER.ru.title, nil, "канон Поттера — только клятва и закрытие")
  t.eq(mapdata.POTTER.en.title, nil)
  t.eq(mapdata.TITLE, nil, "запасных названий нет")
end

-- починка подписей. Владелец 2026-11-16 на Kindle: «запретный лес почемуто почти везде. несколько хогвартсов…
-- надписи вообще не читаются». Каждое имя места — один раз на экране (у самого большого из видимых зданий: на всё поле
-- имя уходило за экран, и на живой местности оставалась одна подпись), мелкий парк без имени, кегль крупнее; подложки
-- нет — подпись чернее и жирнее (владелец 2026-11-16)

-- прямоугольное здание w × h с центром в точке экрана (x, y); экран — середина поля 2 × экран
local function rect_bld(x, y, w, h, kind)
  local fx, fy = x + W / 2, y + H / 2
  return { kind = kind, pts = { fx - w / 2, fy - h / 2, fx + w / 2, fy - h / 2, fx + w / 2, fy + h / 2,
                                fx - w / 2, fy + h / 2 } }
end

local function field_of(buildings, streets)
  return { center = CENTER, w = 2 * W, h = 2 * H, m_per_px = terrain.M_PER_PX, streets = streets or {},
           buildings = buildings }
end

local function count_text(d, s)
  local n = 0
  for _, e in ipairs(labels_of(d)) do if e.text == s then n = n + 1 end end
  return n
end

-- середина подписи (её прямоугольника) — в точке экрана (x, y) с точностью до пикселя
local function centered_at(e, x, y)
  local r = e.rect
  return math.abs(r.x + r.w / 2 - x) <= 1 and math.abs(r.y + r.h / 2 - y) <= 1
end

function T.test_each_place_labelled_once()
  local tt = field_of({ rect_bld(200, 300, 30, 30, "school"), rect_bld(500, 700, 80, 60, "school"),
                        rect_bld(150, 850, 40, 40, "school"),
                        rect_bld(600, 250, 20, 20, "shop"), rect_bld(400, 500, 20, 20, "shop") })
  local d = map_diary(tt)
  MapView.new(d, potter_data({ school = "Хогвартс", shop = "Олливандер" }), nil):paint()
  t.eq(count_text(d, "Хогвартс"), 1, "три школы — одна подпись")
  t.ok(centered_at(label_text(d, "Хогвартс"), 500, 700), "у самой большой по площади")
  t.eq(count_text(d, "Олливандер"), 1, "две лавки — одна подпись")
  t.ok(centered_at(label_text(d, "Олливандер"), 400, 500), "площади равны — у той, что ближе к середине экрана")
  local d2 = map_diary(tt)
  MapView.new(d2, potter_data({ school = "Хогвартс", shop = "Хогвартс" }), nil):paint()
  t.eq(count_text(d2, "Хогвартс"), 1, "одно имя у двух типов — тоже один раз")
end

-- имя выбирает здание среди видимых: самое большое за экраном не забирает его у видимого (на живой местности
-- 2026-11-16 так оставалась одна подпись из двенадцати); на экране имя по-прежнему одно; поле сдвинули — имя
-- переходит к самому большому из видимых теперь
function T.test_label_goes_to_visible_building()
  local tt = field_of({ rect_bld(W + 200, 500, 100, 100, "school"), rect_bld(300, 500, 30, 30, "school"),
                        rect_bld(200, 800, 20, 20, "school") })
  local d = map_diary(tt)
  local v = MapView.new(d, potter_data({ school = "Хогвартс" }), nil)
  v:paint()
  t.eq(count_text(d, "Хогвартс"), 1, "большая школа за экраном — имя у видимой, один раз")
  t.ok(centered_at(label_text(d, "Хогвартс"), 300, 500), "у самой большой из видимых")
  d.texts = {}
  t.ok(v:pan(-300, 0))
  t.eq(count_text(d, "Хогвартс"), 1, "сдвинули к большой — второй экземпляр не появляется")
  t.ok(centered_at(label_text(d, "Хогвартс"), W + 200 - 300, 500), "имя перешло к большой школе")
end

-- имя берёт здание с серединой рамки в поле туши: большое, что лишь заходит на экран (середина в 10 px за правым краем
-- поля), не отнимает его у малого посреди экрана
function T.test_label_needs_middle_in_ink_box()
  local probe = MapView.new(map_diary(field_of({})), potter_data({}), CENTER)
  probe:paintParchment()
  local edge = probe.box[3]
  local d = map_diary(field_of({ rect_bld(edge + 10, 500, 100, 100, "school"), rect_bld(300, 500, 30, 30, "school") }))
  MapView.new(d, potter_data({ school = "Хогвартс" }), nil):paint()
  t.eq(count_text(d, "Хогвартс"), 1)
  t.ok(centered_at(label_text(d, "Хогвартс"), 300, 500), "у малой школы: середина большой — за полем туши")
end

-- мелкий сквер — не «Запретный лес»: парк подписывается от MapView.PARK_MIN площади экрана
function T.test_small_park_no_label()
  local side = math.sqrt(W * H * MapView.PARK_MIN)
  local d = map_diary(field_of({ rect_bld(250, 300, side - 2, side - 2, "park") }))
  MapView.new(d, potter_data({ park = "Запретный лес" }), CENTER):paint()
  t.eq(count_text(d, "Запретный лес"), 0, "сквер меньше порога — без имени")
  local d2 = map_diary(field_of({ rect_bld(250, 300, side - 2, side - 2, "park"),
                                  rect_bld(450, 700, side + 2, side + 2, "park") }))
  MapView.new(d2, potter_data({ park = "Запретный лес" }), CENTER):paint()
  t.eq(count_text(d2, "Запретный лес"), 1, "большой парк — с именем")
  t.ok(centered_at(label_text(d2, "Запретный лес"), 450, 700), "у большого")
end

-- отпечатки пера (≤ 2 px) под прямоугольником r -> сколько; белые прямоугольники, задевшие r -> сколько
local function under(d, r)
  local pen, white = 0, 0
  for _, a in ipairs(d.rects) do
    local ix0, iy0 = math.max(a[1], r.x), math.max(a[2], r.y)
    local ix1, iy1 = math.min(a[1] + a[3], r.x + r.w), math.min(a[2] + a[4], r.y + r.h)
    if ix0 < ix1 and iy0 < iy1 then
      if a[5] == 0 and a[3] <= 2 and a[4] <= 2 then pen = pen + 1 end
      if a[5] == 0xFF then white = white + 1 end
    end
  end
  return pen, white
end

-- школа на перекрёстке (владелец 2026-11-16: «большие белые плашки занимают место … сделай без плашек, но чернее
-- и жирным»): под подписью улицы и контур остаются, белого под ней не кладётся — и при paint, и при проявлении;
-- подпись рисуется тушью подписей (порог выше страничного 0x80, жирная) и меряется ею же; кегль крупнее 24 px
function T.test_label_over_lines_without_plate()
  local streets = { { 0, H, 2 * W, H }, { W, 0, W, 2 * H } } -- крест через середину экрана
  local tt = field_of({ rect_bld(W / 2, H / 2, 60, 60, "school") }, streets)
  local function check(d, how)
    local e = label_text(d, "Хогвартс")
    t.ok(e, how .. ": подпись есть")
    t.ok(e.px >= 30, how .. ": кегль ≥ 30 px, сейчас " .. tostring(e.px))
    local pen, white = under(d, e.rect)
    t.ok(pen > 0, how .. ": под подписью линии")
    t.eq(white, 0, how .. ": под подписью нет белых плашек")
    t.ok((e.opts.threshold or 0) > 0x80, how .. ": порог подписи выше страничного: " .. tostring(e.opts.threshold))
    t.ok(e.opts.bold and (e.opts.bold[1] > 0 or e.opts.bold[2] > 0), how .. ": подпись жирная")
    t.ok((e.opts.halo or 0) > 0, how .. ": линии обрываются у букв подписи (halo)")
    local c = e.opts.clip
    t.ok(c and c[1] >= 25 and c[2] >= 25 and c[3] <= W - 25 and c[4] <= H - 25,
      how .. ": обводка подписи — только внутри поля туши, рамка цела")
    t.eq(d.dry_opts.bold, e.opts.bold, how .. ": размер подписи меряется с тем же утолщением")
  end
  local d = map_diary(tt)
  MapView.new(d, potter_data({ school = "Хогвартс" }), nil):paint()
  check(d, "paint")
  local d2 = map_diary(tt)
  MapView.new(d2, potter_data({ school = "Хогвартс" }), nil):open()
  run_tasks(d2, MapView.INK_STEP_S)
  check(d2, "проявление")
end

-- ревью ff5f761: владелец пишет на карте, пока тушь проявляется; последняя партия кладёт подписи —
-- его штрих по месту подписи остаётся поверх неё (перерисован после текста)
function T.test_review_owner_ink_over_label()
  local tt = field_of({ rect_bld(W / 2, H / 2, 60, 60, "school"), rect_bld(100, 150, 20, 20, "house"),
    rect_bld(650, 150, 20, 20, "house"), rect_bld(100, 900, 20, 20, "house"), rect_bld(650, 900, 20, 20, "house"),
    rect_bld(400, 150, 20, 20, "house"), rect_bld(400, 900, 20, 20, "house"), rect_bld(100, 500, 20, 20, "house") })
  local d = map_diary(tt)
  local v = MapView.new(d, potter_data({ school = "Хогвартс" }), nil)
  v:open()
  run_tasks(d, MapView.INK_STEP_S, 1) -- первая партия из четырёх
  -- штрих пальцем прямо по месту будущей подписи (середина экрана): Diary кладёт чернила на холст сам
  local x, y = W / 2 - 10, H / 2
  d.canvas:paintRect(x, y, 4, 2, 0)
  v:onStrokeDone({ p = { x, y, x + 20, y }, b = { x, y, x + 20, y + 2 } })
  run_tasks(d, MapView.INK_STEP_S) -- остальные партии, с подписями
  local e = label_text(d, "Хогвартс")
  t.ok(e, "подпись есть")
  local r = e.rect
  t.ok(x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h, "штрих — на месте подписи")
  local last_black, last_white = 0, 0
  for _, a in ipairs(d.rects) do
    local covers = x >= a[1] and x < a[1] + a[3] and y >= a[2] and y < a[2] + a[4]
    if covers and a[5] == 0 then last_black = math.max(last_black, a[6]) end
    if covers and a[5] == 0xFF and a[3] > 4 then last_white = math.max(last_white, a[6]) end
  end
  t.ok(last_black > e.seq, "штрих владельца поверх подписи: штрих #" .. last_black .. ", подпись #" .. e.seq)
  t.ok(last_black > last_white, "и не стёрт белым: штрих #" .. last_black .. ", белый #" .. last_white)
end

-- срез 7: герои вселенной — пара отпечатков и имя (answer_px/2), стоят в поле и едут вместе с картой

-- данные карты с составом героев (как их сохраняет генерация) и словарём мест
local function cast_data(list, places)
  local gen = json.decode(json.encode(MP.map))
  gen.potter, gen.places = true, places or {}
  return mapdata.of({ lang = "ru" }, { id = 7, lang = "ru" }, parts_of(gen, list))
end

-- отпечатки пера ink.stamp (2×4 и 4×2) в квадрате ±r вокруг точки экрана
local function stamps_near(d, x, y, r)
  local n = 0
  for _, q in ipairs(d.rects) do
    if (q[3] == 4 and q[4] == 2 or q[3] == 2 and q[4] == 4) and q[5] == 0 and math.abs(q[1] - x) <= r
      and math.abs(q[2] - y) <= r then n = n + 1 end
  end
  return n
end

-- герои на экране по расстановке вида (поле → экран сдвигом вида)
local function on_screen_heroes(v)
  local out, screen = {}, v:heroScreen()
  for _, h in ipairs(v:heroes()) do
    if require("riddle.cast").on_screen(screen, h.x, h.y) then
      out[#out + 1] = { name = h.name, x = terrain.round(h.x - v.ox), y = terrain.round(h.y - v.oy) }
    end
  end
  return out
end

local function names_of(d)
  local out = {}
  for _, e in ipairs(d.texts) do if e.px == 21 then out[#out + 1] = e end end
  return out
end

function T.test_heroes_drawn_with_names()
  local d = map_diary(fixture_terrain())
  local first = #infos
  local v = MapView.new(d, cast_data(MP.cast()), CENTER, 3)
  v:paint()
  local list = v:heroes()
  t.ok(#list >= 2 and #list <= 6, "2–6 героев")
  local shown = on_screen_heroes(v)
  t.ok(#shown >= 1, "на экране хотя бы один")
  for _, h in ipairs(shown) do
    t.ok(stamps_near(d, h.x, h.y, 8) >= 4, "пара отпечатков у героя")
  end
  t.ok(#names_of(d) >= 1, "имена — кеглем answer_px/2 = 21")
  -- владелец 2026-11-16: «большие белые плашки занимают место» — под именами подложек нет (мест в словаре нет — и
  -- подписей с подложками тоже): ни одного белого прямоугольника
  for _, q in ipairs(d.rects) do t.ok(q[5] ~= 0xFF, "белый прямоугольник: " .. table.concat(q, ",", 1, 4)) end
  for _, e in ipairs(names_of(d)) do
    t.ok(e.rect.y > 0, "имя на экране: " .. e.text)
    -- имя — той же тушью, что подпись места (владелец 2026-11-16: «без плашек, но чернее и жирным»)
    t.ok((e.opts.threshold or 0) > 0x80, "порог имени выше страничного: " .. tostring(e.opts.threshold))
    t.ok(e.opts.bold ~= nil, "имя жирное")
    t.ok((e.opts.halo or 0) > 0, "линии обрываются у букв имени (halo)")
    t.eq(e.opts.halo, MapView.LABEL_HALO, "halo имени — как у подписей")
    t.ok(e.opts.clip and e.opts.clip[1] >= 25, "обводка имени — только внутри поля туши")
    t.eq(e.opts.threshold, MapView.LABEL_THRESHOLD, "порог имени — как у подписей")
    t.eq(e.opts.bold, MapView.LABEL_BOLD, "жирность имени — как у подписей")
  end
  -- лог: число, видимые, местный час; ни имён, ни координат
  local logged = {}
  for i = first + 1, #infos do
    if infos[i]:find("riddle: map cast", 1, true) then logged[#logged + 1] = infos[i] end
    for _, row in ipairs(MP.cast()) do t.ok(not infos[i]:find(row.name, 1, true), "имени нет в логе") end
  end
  t.eq(#logged, 1, "расстановка — одна на открытие")
  t.eq(logged[1], string.format("riddle: map cast n=%d visible=%d hour=12", #list, #shown))
  -- перерисовка (страница, сдвиг) героев не переставляет
  v:paint()
  t.eq(v:heroes(), list, "та же расстановка")
  -- проявление: следы — с последней партией, после линий
  local d2 = map_diary(fixture_terrain())
  local v2 = MapView.new(d2, cast_data(MP.cast()), CENTER, 3)
  v2:open()
  run_tasks(d2, MapView.INK_STEP_S, 3)
  t.eq(#names_of(d2), 0, "до последней партии имён нет")
  run_tasks(d2, MapView.INK_STEP_S)
  t.ok(#names_of(d2) >= 1, "с последней партией — имена")
  -- героев нет в составе (раздел map.cast не сгенерирован) — карта без следов, лог n=0
  local d3 = map_diary(fixture_terrain())
  MapView.new(d3, cast_data(nil), CENTER, 1):paint()
  t.eq(#names_of(d3), 0)
  t.eq(infos[#infos], "riddle: map cast n=0 visible=0 hour=12")
end

-- все в одной школе с подписью: отпечатки не под подписью, имена не пересекают подпись и друг друга —
-- лишнее имя пропущено, герой остаётся
function T.test_hero_names_skip_overlaps()
  local students = {}
  for i = 1, 6 do students[i] = { name = "Ученик " .. i, role = "student", day = "school", night = "home" } end
  local tt = field_of({ rect_bld(W / 2, H / 2, 200, 120, "school") })
  local d = map_diary(tt)
  local v = MapView.new(d, cast_data(students, { school = "Хогвартс" }), nil, 2)
  v:paint()
  local label = label_text(d, "Хогвартс").rect
  local shown = on_screen_heroes(v)
  t.ok(#shown >= 2, "в школе несколько учеников, сейчас " .. #shown)
  for _, h in ipairs(v:heroes()) do t.eq(h.at, "school") end
  local feet = 0
  for _, q in ipairs(d.rects) do
    if (q[3] == 4 and q[4] == 2 or q[3] == 2 and q[4] == 4) and q[5] == 0 then
      feet = feet + 1
      t.ok(q[1] + q[3] <= label.x or q[1] >= label.x + label.w or q[2] + q[4] <= label.y or q[2] >= label.y + label.h,
        "отпечаток не под подписью")
    end
  end
  t.eq(feet, 8 * #shown, "у каждого героя на экране — оба отпечатка (4 штампа по 2 прямоугольника)")
  local names = names_of(d)
  t.ok(#names >= 1 and #names < #shown, "имена есть, лишние пропущены: " .. #names .. " из " .. #shown)
  local all = { label }
  for _, e in ipairs(names) do all[#all + 1] = e.rect end
  for i, a in ipairs(all) do
    t.ok(inside(d, a), "внутри рамки")
    for j = i + 1, #all do
      local b = all[j]
      t.ok(a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y, "не пересекаются")
    end
  end
end

-- поле сдвинули пальцем: герои едут вместе с картой, расстановка та же
function T.test_heroes_ride_with_pan()
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, cast_data(MP.cast()), CENTER, 3)
  v:paint()
  local list = v:heroes()
  local h = on_screen_heroes(v)[1]
  t.ok(v:pan(-40, -30))
  t.eq(v:heroes(), list, "сдвиг не переставляет героев")
  for _, s in ipairs(on_screen_heroes(v)) do
    if s.name == h.name then
      t.eq(s.x - h.x, -40)
      t.eq(s.y - h.y, -30)
      t.ok(stamps_near(d, s.x, s.y, 8) >= 4, "отпечатки на новом месте")
    end
  end
end

-- та же местность, перечитанная заданием (setPoint с тем же файлом), — герои на прежних местах
function T.test_same_terrain_keeps_heroes()
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, cast_data(MP.cast()), CENTER, 3)
  v:paint()
  local list = v:heroes()
  d.map_terrain = function() return fixture_terrain() end
  v:setPoint(CENTER, true)
  v:paint()
  t.eq(v:heroes(), list, "та же местность — та же расстановка, без новой строки лога")
end

-- ревью среза 7, круг 1: имя героя не ложится ни на подпись места, ни на чужие следы

-- шесть бандитов-«улица» (меньше шести раздел map.cast не сохраняет)
local function bandits()
  local out = {}
  for i = 1, 6 do out[i] = { name = "Бандит " .. i, role = "villain", day = "street", night = "street" } end
  return out
end

-- отпечатки следов (чёрные ink.stamp) -> { { x0, y0, x1, y1 }, … } (края включены)
local function stamp_edges(d)
  local out = {}
  for _, q in ipairs(d.rects) do
    if (q[3] == 4 and q[4] == 2 or q[3] == 2 and q[4] == 4) and q[5] == 0 then
      out[#out + 1] = { q[1], q[2], q[1] + q[3] - 1, q[2] + q[4] - 1 }
    end
  end
  return out
end

-- геометрия имён и следов на холсте: имя героя — не ближе LABEL_GAP (4 px) к подписи места и к любому отпечатку
-- (свои следы стоят над именем ровно в 4 px — не ближе), отпечаток — не ближе HERO_PAD (4 px) к подписи
-- -> число нарушений, первое из них строкой
local function overlaps(d)
  local near = require("riddle.layout").near
  local n, first = 0, nil
  local function bad(msg)
    n = n + 1
    first = first or msg
  end
  local labels = {}
  for _, e in ipairs(labels_of(d)) do if e.px ~= 21 then labels[#labels + 1] = e end end
  local feet = stamp_edges(d)
  for _, l in ipairs(labels) do
    local le = { l.rect.x, l.rect.y, l.rect.x + l.rect.w - 1, l.rect.y + l.rect.h - 1 }
    for _, q in ipairs(feet) do
      if near(q, le, 4) then bad("отпечаток " .. table.concat(q, ",") .. " у подписи «" .. l.text .. "»") end
    end
    for _, e in ipairs(names_of(d)) do
      local r = e.rect
      if near({ r.x, r.y, r.x + r.w - 1, r.y + r.h - 1 }, le, 4) then
        bad("имя «" .. e.text .. "» у подписи «" .. l.text .. "»")
      end
    end
  end
  for _, e in ipairs(names_of(d)) do
    local r = e.rect
    for _, q in ipairs(feet) do
      if near({ r.x, r.y, r.x + r.w - 1, r.y + r.h - 1 }, q, 4) then
        bad("имя «" .. e.text .. "» на отпечатке " .. table.concat(q, ","))
      end
    end
  end
  return n, first
end

-- улица — короткий отрезок вертикально через середину экрана: точки улиц через 40 px, герои стоят друг под другом —
-- имя верхнего пришлось бы на следы нижнего (ревью среза 7, круг 1, п.6: проверка — геометрия имени против отпечатков,
-- не стирание белым — подложек нет)
function T.test_review_hero_name_not_over_others_feet()
  local cx, cy = W, H -- середина экрана в поле
  local d = map_diary(field_of({}, { { cx, cy - 40, cx, cy + 40 } }))
  local v = MapView.new(d, cast_data(bandits()), nil, 1)
  v:paint()
  t.ok(#on_screen_heroes(v) >= 2, "на экране несколько героев")
  t.ok(#names_of(d) >= 1, "имена есть")
  t.ok(#names_of(d) < #on_screen_heroes(v), "имя, легшее бы на чужие следы, пропущено")
  local n, first = overlaps(d)
  t.eq(n, 0, first)
end

-- ревью среза 7, п.2: улица идёт сквозь подпись школы, сразу под ней — подпись паба. Следы, сдвинутые из-под школы
-- вниз, легли бы на паб — встают над школой; ни след, ни имя не у подписей
function T.test_review_feet_moved_off_label_miss_the_next()
  local cx, cy = W, H
  local tt = field_of({ rect_bld(379, 400, 200, 40, "school"), rect_bld(379, 440, 200, 40, "pub") },
    { { cx - 50, cy - 112, cx + 50, cy - 112 } })
  local d = map_diary(tt)
  local v = MapView.new(d, cast_data(bandits(), { school = "Хогвартс", pub = "Котёл" }), nil, 1)
  v:paint()
  local school, pub = label_text(d, "Хогвартс"), label_text(d, "Котёл")
  t.ok(school and pub, "обе подписи на экране")
  t.ok(pub.rect.y - (school.rect.y + school.rect.h) < 2 * MapView.FOOT + 8, "под школой следам места нет")
  t.ok(#on_screen_heroes(v) >= 1, "герои на улице сквозь школу")
  t.ok(#stamp_edges(d) >= 8, "следы нарисованы")
  local n, first = overlaps(d)
  t.eq(n, 0, first)
end

-- герои на улице прямо над подписанной школой: следы не задевают подпись, а имя под ними легло бы на неё — пропущено
function T.test_review_hero_name_not_over_label()
  local cx, cy = W, H
  local tt = field_of({ rect_bld(W / 2, H / 2 + 20, 160, 60, "school") }, { { cx - 20, cy - 26, cx + 60, cy - 26 } })
  local d = map_diary(tt)
  local v = MapView.new(d, cast_data(bandits(), { school = "Хогвартс" }), nil, 1)
  v:paint()
  local label = label_text(d, "Хогвартс").rect
  t.ok(#on_screen_heroes(v) >= 1, "герои над школой")
  for _, e in ipairs(names_of(d)) do
    local r = e.rect
    t.ok(r.x + r.w + 4 <= label.x or label.x + label.w + 4 <= r.x or r.y + r.h + 4 <= label.y
      or label.y + label.h + 4 <= r.y, "имя «" .. e.text .. "» не на подписи")
  end
  for _, q in ipairs(d.rects) do
    if (q[3] == 4 and q[4] == 2 or q[3] == 2 and q[4] == 4) and q[5] == 0 then
      t.ok(q[2] + q[4] <= label.y or q[2] >= label.y + label.h or q[1] + q[3] <= label.x or q[1] >= label.x + label.w,
        "отпечаток не под подписью")
    end
  end
end

-- срез 8: следы движутся — шаг раз в map_step_s, частичное обновление только изменившихся мест (DU)

-- цвет пикселя экрана на холсте фейка: последний закрасивший его прямоугольник (nil — не тронут после fill)
local function color_at(d, x, y)
  local c
  for _, r in ipairs(d.rects) do
    if x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4] then c = r[5] end
  end
  return c
end

-- прямоугольник { x0, y0, x1, y1 } (правый и нижний край не включены) целиком внутри какого-нибудь вывода
local function pushed(d, from, x0, y0, x1, y1)
  for i = from, #d.pushes do
    local p = d.pushes[i]
    if x0 >= p[1] and y0 >= p[2] and x1 <= p[1] + p[3] and y1 <= p[2] + p[4] then return true end
  end
  return false
end

local function touches_push(d, from, x0, y0, x1, y1)
  for i = from, #d.pushes do
    local p = d.pushes[i]
    if x0 < p[1] + p[3] and p[1] < x1 and y0 < p[2] + p[4] and p[2] < y1 then return true end
  end
  return false
end

-- бандит ходит по улице на 200 px ниже середины экрана (в середине — точка владельца и книга, срез 13а: следы её
-- обходят — тесты шагов здесь не о ней), пятеро домоседов — в домах на экране (днём не выходят)
local function walk_town()
  local list = { { name = "Бандит", role = "villain", day = "street", night = "street" } }
  for i = 1, 5 do list[#list + 1] = { name = "Домосед " .. i, role = "townsfolk", day = "home", night = "home" } end
  local tt = field_of({ rect_bld(150, 250, 40, 40, "house"), rect_bld(600, 250, 40, 40, "house"),
                        rect_bld(380, 800, 40, 40, "house") }, { { W / 2, H + 200, 3 * W / 2, H + 200 } })
  return list, tt
end

-- открытая и проявленная карта с бандитом и хотя бы одним домоседом на экране -> d, v, бандит, домосед
local function walking_map()
  local list, tt = walk_town()
  for seed = 1, 100 do
    local d = map_diary(tt)
    local v = MapView.new(d, cast_data(list), CENTER, seed)
    v:open()
    run_tasks(d, MapView.INK_STEP_S)
    local walker, still
    for _, h in ipairs(on_screen_heroes(v)) do
      if h.name == "Бандит" then walker = h elseif not still then still = h end
    end
    if walker and still then return d, v, walker, still end
  end
  error("нет seed с бандитом и домоседом на экране")
end

local function hero_on_screen(v, name)
  for _, h in ipairs(on_screen_heroes(v)) do if h.name == name then return h end end
end

-- шаг: бандит сделал шаг, выводятся только места его старых и новых следов и имени (DU), холст не заливается целиком,
-- домосед не перерисован; координаты — экрана при текущем сдвиге поля
function T.test_dirty_rects_only_changed()
  local d, v = walking_map()
  t.ok(v:pan(-40, -30), "поле сдвинуто")
  local walker = hero_on_screen(v, "Бандит")
  local still
  for _, h in ipairs(on_screen_heroes(v)) do if h.name ~= "Бандит" then still = h break end end
  t.ok(walker and still, "после сдвига оба на экране")
  local fills = 0
  local fill = d.canvas.fill
  d.canvas.fill = function(...) fills = fills + 1 return fill(...) end
  local from = #d.pushes + 1
  t.eq(run_tasks(d, d.CFG.map_step_s, 1), 1, "шаг по таймеру map_step_s")
  local now = hero_on_screen(v, "Бандит")
  t.ok(now and (now.x ~= walker.x or now.y ~= walker.y), "бандит шагнул")
  t.eq(fills, 0, "холст не заливается целиком")
  t.ok(#d.pushes >= from, "шаг выведен")
  local area = 0
  for i = from, #d.pushes do
    local p = d.pushes[i]
    t.eq(p[5], "DU", "частичное обновление DU")
    t.ok(p[1] >= 25 and p[2] >= 25 and p[1] + p[3] <= W - 25 and p[2] + p[4] <= H - 25, "внутри рамки")
    area = area + p[3] * p[4]
  end
  t.ok(area < W * H / 10, "выведено меньше десятой экрана: " .. area)
  local f = MapView.FOOT
  t.ok(pushed(d, from, now.x - f, now.y - f, now.x + f, now.y + f), "новые следы выведены")
  t.ok(stamps_near(d, now.x, now.y, 8) >= 4, "новые следы на холсте")
  t.ok(not touches_push(d, from, still.x - f, still.y - f, still.x + f, still.y + f), "домосед не перерисован")
  local name
  for _, e in ipairs(names_of(d)) do if e.text == "Бандит" then name = e end end
  t.ok(name and name.seq > 0, "имя бандита на новом месте")
  t.eq(name.opts.threshold, MapView.LABEL_THRESHOLD, "имя — той же тушью (labelOpts)")
  t.ok(name.opts.clip, "обводка имени — в пределах перерисовки")
  t.ok(math.abs(name.rect.x + name.rect.w / 2 - now.x) <= 1, "имя под следами")
end

-- след гаснет через map_trail шагов: на месте первого отпечатка снова пергамент (и улица)
function T.test_step_trail_fades_on_screen()
  local d, v, walker = walking_map()
  local x, y = walker.x - 4, walker.y + 4 -- нижний отпечаток левой ноги (FEET), ниже линии улицы
  t.eq(color_at(d, x, y), 0, "отпечаток есть")
  for k = 1, d.CFG.map_trail - 1 do
    run_tasks(d, d.CFG.map_step_s, 1)
    t.eq(color_at(d, x, y), 0, "шаг " .. k .. ": след ещё виден")
  end
  run_tasks(d, d.CFG.map_step_s, 1)
  t.ok(color_at(d, x, y) ~= 0, "через " .. d.CFG.map_trail .. " шага след погас")
end

-- штрих владельца на карте (страница ещё пишется) остаётся поверх перерисовки шага
function T.test_step_keeps_page_ink_on_top()
  local d, v, walker = walking_map()
  d.CFG.idle_s = 60 -- страница не кончается во время шагов
  local sy = walker.y + 3
  v:onStrokeDone({ p = { 40, sy, W - 40, sy }, b = { 40, sy, W - 40, sy } })
  v:paintPage()
  for _ = 1, 3 do run_tasks(d, d.CFG.map_step_s, 1) end
  local now = hero_on_screen(v, "Бандит")
  t.ok(now and now.x ~= walker.x, "бандит ушёл")
  t.eq(color_at(d, now.x, sy), 0, "штрих поверх новых следов")
  t.eq(color_at(d, walker.x, sy), 0, "и там, где были следы")
end

-- палец на тачпаде или перо на стекле: шаг ждёт (ни вывода, ни перестановки), потом идёт дальше
function T.test_step_waits_for_finger()
  local d, v = walking_map()
  d.CFG.map_edge_px, d.CFG.map_pad_px, d.CFG.map_pan_slop_px, d.CFG.map_drag_s = 83, 167, 10, 0.4
  local list = v:heroes()
  t.ok(v:dragStart(300, 950), "палец на тачпаде")
  local from = #d.pushes + 1
  t.eq(run_tasks(d, d.CFG.map_step_s, 1), 1)
  t.eq(#d.pushes, from - 1, "под пальцем — ни одного вывода")
  t.eq(v:heroes(), list, "герои ждут")
  v:dragEnd() -- касание без сдвига
  d.cur = { p = { 300, 400 } } -- перо на стекле
  t.eq(run_tasks(d, d.CFG.map_step_s, 1), 1)
  t.eq(#d.pushes, from - 1, "под пером — ни одного вывода")
  d.cur = nil
  t.eq(run_tasks(d, d.CFG.map_step_s, 1), 1)
  t.ok(v:heroes() ~= list, "шаг сделан")
  t.ok(#d.pushes >= from, "и выведен")
end

-- закрытие карты (роза, фраза, сон, угол — Diary:closeMap -> close; и автозакрытие): таймеров карты не остаётся, в лог —
-- одна строка шагов без имён и координат (замер A12)
function T.test_step_timer_stops_on_close()
  local d, v = walking_map()
  for _ = 1, 3 do run_tasks(d, d.CFG.map_step_s, 1) end
  local first = #infos
  v:close()
  t.eq(#d.tasks, 0, "таймеров карты не осталось")
  local logged = {}
  for i = first + 1, #infos do
    if infos[i]:find("riddle: map steps", 1, true) then logged[#logged + 1] = infos[i] end
    t.ok(not infos[i]:find("Бандит", 1, true), "имени нет в логе")
  end
  t.eq(#logged, 1, "одна строка на закрытие")
  local n, px, ms = logged[1]:match("^riddle: map steps n=(%d+) dirty_px=(%d+) max_ms=(%d+)$")
  t.eq(tonumber(n), 3, "три шага")
  t.ok(tonumber(px) > 0 and tonumber(ms) >= 0, logged[1])
  -- автозакрытие через map_idle_s
  local d2, v2 = walking_map()
  d2.closeMap = function(_, why) v2:close() end
  run_tasks(d2, d2.CFG.map_step_s, 2)
  t.eq(run_tasks(d2, d2.CFG.map_idle_s, 1), 1, "автозакрытие")
  t.eq(#d2.tasks, 0, "после автозакрытия таймеров нет")
  -- карта «не видит» (местности нет): шаг не падает, закрытие — тоже без таймеров
  local d3 = map_diary(nil)
  local v3 = MapView.new(d3, cast_data(bandits()), CENTER, 1)
  v3:open()
  run_tasks(d3, MapView.INK_STEP_S)
  run_tasks(d3, d3.CFG.map_step_s, 2)
  v3:close()
  t.eq(#d3.tasks, 0)
end

-- ревью среза 8: перерисовка шагов (только изменившиеся места) даёт тот же холст, что полная перерисовка того же
-- состояния — с подписью у улицы, сдвигом поля и штрихом владельца. Холст — растр W × H; текст фейка — штриховка
-- его rect и свеса over px вправо (латиница MarckScript; по умолчанию 0), обводка halo — белое вокруг туши только внутри
-- clip (как haloWhite), тушь — поверх без clip; пачка (paintTexts) — сначала обводки всех, потом тушь всех, как у Diary

local OVER = 4

local function raster(d, over)
  over = over or 0
  local px = {}
  local function put(x, y, c)
    if x >= 0 and y >= 0 and x < W and y < H then px[y * W + x + 1] = c end
  end
  d.canvas = {
    fill = function() for i = 1, W * H do px[i] = 0xFF end end,
    paintRect = function(_, x, y, w, h, c)
      for yy = y, y + h - 1 do for xx = x, x + w - 1 do put(xx, yy, c) end end
    end }
  local measure = d.paintText
  local function extent(r)
    local x0, y0 = math.floor(r.x), math.floor(r.y)
    return x0, y0, x0 + math.floor(r.w) - 1 + over, y0 + math.floor(r.h) - 1
  end
  d.paintTexts = function(self, list)
    local rs = {}
    for i, it in ipairs(list) do rs[i] = measure(self, it[1], it[2], it[3]) end
    for i, it in ipairs(list) do
      local opts = it[3]
      if opts and not opts.dry then
        local x0, y0, x1, y1 = extent(rs[i])
        local h, c = opts.halo or 0, opts.clip
        for yy = y0 - h, y1 + h do
          for xx = x0 - h, x1 + h do
            if not c or (xx >= c[1] and yy >= c[2] and xx < c[3] and yy < c[4]) then put(xx, yy, 0xFF) end
          end
        end
      end
    end
    for i, it in ipairs(list) do
      if it[3] and not it[3].dry then
        local x0, y0, x1, y1 = extent(rs[i])
        for yy = y0, y1 do for xx = x0, x1 do if (xx + yy) % 3 == 0 then put(xx, yy, 0) end end end
      end
    end
    return rs
  end
  d.paintText = function(self, text, top, opts) return self:paintTexts({ { text, top, opts } })[1] end
  return px
end

-- задача «обводка подписи не откусывает буквы соседней»: подписи школы и паба в LABEL_GAP = 4 px друг от друга, у
-- «Хогвартса» свес OVER вправо — до соседней подписи 0 px; обводка одной не белит туши другой, кто бы ни рисовался
-- первым: обводки карты — до туши любого текста, и при полной перерисовке, и при перерисовке шага
function T.test_label_halo_spares_neighbour_overhang()
  local tt = field_of({ rect_bld(300, 500, 60, 60, "school"), rect_bld(408, 500, 20, 20, "pub") })
  local d = map_diary(tt)
  local px = raster(d, OVER)
  local v = MapView.new(d, potter_data({ school = "Хогвартс", pub = "Котёл" }), nil)
  local function check(how)
    local a, b = label_text(d, "Хогвартс"), label_text(d, "Котёл")
    t.ok(a and b, how .. ": обе подписи")
    t.eq(math.floor(b.rect.x) - (math.floor(a.rect.x) + math.floor(a.rect.w)), 4, how .. ": между подписями LABEL_GAP")
    for _, e in ipairs({ a, b }) do
      local x0, y0 = math.floor(e.rect.x), math.floor(e.rect.y)
      local x1, y1 = x0 + math.floor(e.rect.w) - 1 + OVER, y0 + math.floor(e.rect.h) - 1
      local bitten = 0
      for yy = y0, y1 do
        for xx = x0, x1 do
          if (xx + yy) % 3 == 0 and px[yy * W + xx + 1] ~= 0 then bitten = bitten + 1 end
        end
      end
      t.eq(bitten, 0, how .. ": пикселей туши «" .. e.text .. "» выбелено")
    end
  end
  v:paint()
  check("paint")
  v.drawn.ink = {} -- шаг: «Котёл» в полосе перерисовки
  local b = label_text(d, "Котёл").rect
  v:repaintRect({ math.floor(b.x) - 2, math.floor(b.y), math.floor(b.x) + 10, math.floor(b.y) + 10 })
  check("шаг")
end

-- owner — имя владельца в данных карты (срез 13а: книга и имя в его точке) или nil; after(v) — зовётся после шагов,
-- до сверки с полной перерисовкой; over — свес текста растра (raster), по умолчанию 0 -> сколько прогонов, в скольких
-- герои шагали
local function steps_equal_full(owner, after, over)
  local list = { { name = "Бандит", role = "villain", day = "street", night = "street" },
                 { name = "Сторож", role = "guard", day = "street", night = "street" } }
  for i = 1, 4 do list[#list + 1] = { name = "Домосед " .. i, role = "townsfolk", day = "home", night = "home" } end
  -- крест улиц с общим узлом; подпись школы под улицей: имя идущего по ней ложится в 7 px над подписью (ближе
  -- запаса туши текста — перерисовка имени задевает подпись); дома
  local tt = field_of({ rect_bld(380, H / 2 + 53, 140, 50, "school"), rect_bld(150, 250, 40, 40, "house"),
                        rect_bld(600, 250, 40, 40, "house"), rect_bld(380, 800, 40, 40, "house") },
                      { { W / 2, H, W, H, 3 * W / 2, H }, { W, H / 2, W, H, W, 3 * H / 2 } })
  local runs, moved = 0, 0
  for seed = 1, 12 do
    local d = map_diary(tt)
    d.CFG.idle_s = 600 -- страница владельца не кончается во время шагов
    local px = raster(d, over)
    local data = cast_data(list, { school = "Хогвартс" })
    data.owner = owner
    local v = MapView.new(d, data, CENTER, seed)
    v:open()
    run_tasks(d, MapView.INK_STEP_S)
    t.ok(v:pan(-30 + seed, -20), "поле сдвинуто")
    -- штрихи владельца: вдоль улицы по следам, по полосе имён под ней и поперёк — вдоль второй улицы
    local sx, sy = terrain.round(W - v.ox), terrain.round(H - v.oy)
    for _, p in ipairs({ { 60, sy + 2, W - 60, sy + 2 }, { 60, sy + 18, W - 60, sy + 18 }, { sx, 60, sx, H - 200 } }) do
      v:onStrokeDone({ p = p, b = { p[1], p[2], p[3], p[4] } })
    end
    v:paintPage()
    local start = v:heroes()
    for _ = 1, 8 do run_tasks(d, d.CFG.map_step_s, 1) end
    if v:heroes() ~= start then moved = moved + 1 end
    if after then after(v) end
    local steps = {}
    for i = 1, W * H do steps[i] = px[i] end
    v:paint()
    v:paintPage()
    local diff = 0
    for i = 1, W * H do if steps[i] ~= px[i] then diff = diff + 1 end end
    t.eq(diff, 0, "seed " .. seed .. ": пикселей расходится с полной перерисовкой")
    runs = runs + 1
  end
  return runs, moved
end

function T.test_review_steps_equal_full_repaint()
  local runs, moved = steps_equal_full(nil)
  t.ok(moved >= 6, "герои шагали в большинстве прогонов: " .. moved .. " из " .. runs)
end

-- задача «след от свеса имени героя»: буквы имени свисают за его rect на OVER px вправо (латиница MarckScript); имя у
-- правого края поля туши — его буквы не выходят за поле (шаг чистит только поле) — после шагов холст тот же, что
-- полная перерисовка. На каждом шаге rect каждого имени — в поле, суженном на свес layout.TEXT_OVERHANG с обоих боков
-- (свес бывает и влево); имя у края (его тушь по мере layout доходит до края поля) — хоть раз у правого и у левого
function T.test_steps_equal_full_repaint_name_at_side_edges()
  local o, outside, at = layout.TEXT_OVERHANG, {}, { left = 0, right = 0 }
  local real_step = MapView.step
  MapView.step = function(v)
    real_step(v)
    local box = v.box
    for _, it in ipairs(v.drawn and v.drawn.ink or {}) do
      local r = it.name and it.name.rect
      if r then
        local x0, x1 = math.floor(r.x), math.floor(r.x) + math.floor(r.w) - 1
        if x0 - o < box[1] or x1 + o > box[3] - 1 then outside[#outside + 1] = it.name.text .. "@" .. x0 .. ".." .. x1 end
        if x0 - o == box[1] then at.left = at.left + 1 end
        if x1 + o == box[3] - 1 then at.right = at.right + 1 end
      end
    end
  end
  local ok, err = pcall(steps_equal_full, nil, nil, OVER)
  MapView.step = real_step
  if not ok then error(err, 0) end
  t.eq(table.concat(outside, ", "), "", "имена со свесом за полем")
  t.ok(at.left >= 1 and at.right >= 1, "имя у левого и у правого края: " .. at.left .. ", " .. at.right)
end

---------------------------------------------------------------------------
-- срез 10: владелец переместился

local function near(a, b) return math.abs(a - b) < 0.01 end

-- строки лога после first, где есть needle
local function logged_since(first, needle)
  local out = {}
  for i = first + 1, #infos do
    if infos[i]:find(needle, 1, true) then out[#out + 1] = infos[i] end
  end
  return out
end

-- точка ближе экрана: та же местность, поле сдвигается на разницу тем же путём, что сдвиг пальцем (весь экран A2,
-- без нового проявления); герои едут с полем, их шаг не сбрасывается; лог без координат
function T.test_near_move_shifts_same_terrain()
  local d, v, _, still = walking_map()
  t.ok(v:pan(-20, 10), "владелец уже двигал поле пальцем")
  run_tasks(d, d.CFG.map_step_s, 1)
  local tt, list, st, step = v.terrain, v:heroes(), v.cast_state, v.step_task
  local ox, oy = v.ox, v.oy
  local h0 = hero_on_screen(v, still.name)
  local pushes, first = #d.pushes, #infos
  v:setPoint(terrain.at(tt, 60 + terrain.offset(tt, v.point), -40), false)
  t.eq(v.terrain, tt, "та же местность")
  t.ok(near(v.ox - ox, 60) and near(v.oy - oy, -40), "поле сдвинуто на разницу: " .. (v.ox - ox) .. "," .. (v.oy - oy))
  t.eq(#d.pushes, pushes + 1, "один вывод")
  local p = d.pushes[#d.pushes]
  t.ok(p[1] == 0 and p[2] == 0 and p[3] == W and p[4] == H and p[5] == MapView.PAN_WF, "весь экран, как сдвиг пальцем")
  t.eq(v.reveal_task, nil, "без нового проявления")
  t.eq(v:heroes(), list, "герои те же")
  t.eq(v.cast_state, st, "шаг героев не сброшен")
  t.eq(v.step_task, step, "таймер шага тот же")
  local h = hero_on_screen(v, still.name)
  t.ok(h and h.x == h0.x - 60 and h.y == h0.y + 40, "герой едет с полем")
  t.ok(stamps_near(d, h.x, h.y, 8) >= 4, "его следы на новом месте")
  t.eq(table.concat(logged_since(first, "riddle: map moved"), "|"), "riddle: map moved near")
  t.eq(run_tasks(d, d.CFG.map_step_s, 1), 1)
  t.eq(v.cast_state.tick, st.tick + 1, "шаг пошёл дальше, не с начала")
  -- сдвиг пальцем ограничен полем и у новой точки: точка у края поля, палец тянул дальше — экран у края, не за ним
  t.ok(v:pan(-10000, 0), "палец к восточному краю")
  v:setPoint(terrain.at(tt, (tt.w - W) / 2 - 50, 0), false)
  t.ok(near(v.ox, tt.w - W), "экран у края поля: ox=" .. v.ox)
end

-- точка дальше экрана, задание записало новую местность: подмена — полная перерисовка (full), подписи заново, герои
-- расставлены заново, сдвиг пальцем сброшен; таймер шага переживает подмену
function T.test_far_move_fetches_and_swaps()
  local d, v = walking_map()
  t.ok(v:pan(-40, -30))
  local old, list, step = v.terrain, v:heroes(), v.step_task
  local far = terrain.at(old, 3 * W, 0)
  local new = json.decode(json.encode(old))
  new.center = { lat = far.lat, lon = far.lon }
  -- школа только в новой местности, ниже новой точки (в самой точке — книга владельца, срез 13а): её подпись — видимый
  -- след раскладки по новой
  new.buildings[#new.buildings + 1] = rect_bld(380, 700, 60, 60, "school")
  v.data.places.school = "Хогвартс"
  d.map_terrain = function() return new end
  local pushes, first = #d.pushes, #infos
  v:setPoint(far, true)
  t.eq(v.terrain, new, "новая местность")
  t.eq(v.point, far)
  t.eq(d.pushes[pushes + 1][5], "full", "подмена — полная перерисовка")
  t.ok(v.shift[1] == 0 and v.shift[2] == 0, "сдвиг пальцем — от старой местности, сброшен")
  t.ok(run_tasks(d, MapView.INK_STEP_S) >= 1, "тушь проступает")
  t.ok(v.cast_for == new and v:heroes() ~= list, "герои расставлены заново")
  local school = label_text(d, "Хогвартс")
  t.ok(school and centered_at(school, 380, 700), "подписи — по новой местности")
  t.eq(v.step_task, step, "таймер шага пережил подмену")
  t.eq(run_tasks(d, d.CFG.map_step_s, 1), 1, "шаг идёт")
  t.eq(table.concat(logged_since(first, "riddle: map moved"), "|"), "riddle: map moved far")
  t.eq(#logged_since(first, "riddle: map cast"), 1, "герои расставлены один раз")
end

-- точка дальше экрана, новая местность не пришла (нет сети, Overpass упал): карта остаётся прежней — та же точка и
-- местность, без blind и без перерисовки
function T.test_far_move_offline_keeps_old()
  local d, v = walking_map()
  local tt, pt, step = v.terrain, v.point, v.step_task
  local pushes, first = #d.pushes, #infos
  v:setPoint(terrain.at(tt, 3 * W, 0), false)
  t.eq(v.point, pt, "точка прежняя")
  t.eq(v.terrain, tt, "местность прежняя")
  t.eq(#d.pushes, pushes, "экран не тронут")
  t.eq(#logged_since(first, "riddle: map moved"), 0)
  v:paint()
  t.ok(v.box and not has_text(d, mapdata.BLIND.en), "при следующей перерисовке — та же карта, не blind")
  t.eq(v.step_task, step, "шаг идёт")
end

-- точка пришла, пока на карте страница чернил: перерисовка ждёт конца страницы и тогда выводит весь экран (поле уже
-- на новом месте), а не только место страницы
function T.test_near_move_under_page_waits_whole_push()
  local d, v = walking_map()
  d.isRose = function() return false end
  d.readMapPage = function() end
  v:onStrokeDone({ p = { 300, 300, 340, 300 }, b = { 300, 300, 340, 302 } })
  local pushes, ox = #d.pushes, v.ox
  v:setPoint(terrain.at(v.terrain, 60 + terrain.offset(v.terrain, v.point), 0), false)
  t.eq(#d.pushes, pushes, "страница пишется — экран не тронут")
  t.eq(#v.page.strokes, 1, "штрих цел")
  local page = assert(v.page_task, "страница кончится через idle_s") -- idle_s = map_step_s: run_tasks шёл бы по шагам
  d:cancel(page)
  page.fn()
  t.ok(near(v.ox - ox, 60), "поле на новом месте")
  local p = d.pushes[#d.pushes]
  t.ok(p[1] == 0 and p[2] == 0 and p[3] == W and p[4] == H, "выведен весь экран: " .. table.concat(p, ","))
end

-- ревью среза 10, Б1: новая местность пришла посреди открывающего проявления, пока пишется страница: проявление
-- старой местности останавливается (не дорисовывает подписи и героев новой на старый экран); всё — после страницы
function T.test_far_during_reveal_under_page_stops_reveal()
  local d = map_diary(fixture_terrain())
  local v = MapView.new(d, cast_data(MP.cast(), { school = "Хогвартс" }), CENTER, 3)
  v:open()
  t.eq(run_tasks(d, MapView.INK_STEP_S, 1), 1, "первая партия туши")
  d.isRose = function() return false end
  d.readMapPage = function() end
  v:onStrokeDone({ p = { 300, 300, 340, 300 }, b = { 300, 300, 340, 302 } })
  local old = v.terrain
  local far = terrain.at(old, 3 * W, 0)
  local new = json.decode(json.encode(old))
  new.center = { lat = far.lat, lon = far.lon }
  d.map_terrain = function() return new end
  local pushes = #d.pushes
  v:setPoint(far, true)
  t.eq(v.terrain, new)
  t.eq(v.reveal_task, nil, "проявление старой местности остановлено")
  t.eq(run_tasks(d, MapView.INK_STEP_S, 10), 0, "партий больше нет")
  t.ok(v.cast_for ~= new, "герои новой местности не легли на старый экран")
  t.eq(#d.pushes, pushes, "страница пишется — экран не тронут")
  local page = assert(v.page_task)
  d:cancel(page)
  page.fn()
  t.eq(v.cast_for, new, "после страницы — герои новой местности")
  t.ok(#labels_of(d) > 0, "и её подписи")
  local p = d.pushes[#d.pushes]
  t.ok(p[1] == 0 and p[2] == 0 and p[3] == W and p[4] == H, "выведен весь экран")
end

-- ревью среза 10, Б2: задание записало местность, а чтение файла упало — карта с тушью остаётся прежней, не blind
function T.test_fetched_but_read_failed_keeps_terrain()
  local d, v = walking_map()
  local tt = v.terrain
  d.map_terrain = function() error("disk") end
  v:setPoint(terrain.at(tt, 3 * W, 0), true)
  t.eq(v.terrain, tt, "далеко: прежняя местность")
  v:setPoint(terrain.at(tt, 30 + terrain.offset(tt, v.point), 0), true)
  t.eq(v.terrain, tt, "рядом: прежняя местность")
  v:paint()
  t.ok(v.box and not has_text(d, mapdata.BLIND.en), "не blind")
end

-- ревью среза 10, Б3: без сети точка ушла в полосу между полэкрана и экраном от центра местности (поле её ещё
-- покрывает, новой местности нет) — экран у края поля, не за ним, как при сдвиге пальцем
function T.test_near_move_into_field_band_clamped()
  local d, v = walking_map()
  local tt = v.terrain
  v:setPoint(terrain.at(tt, (tt.w - W) / 2 + 100, 0), false)
  t.ok(near(v.ox, tt.w - W), "экран у восточного края поля: ox=" .. v.ox)
  v:setPoint(terrain.at(tt, 0, -(tt.h - H) / 2 - 100), false)
  t.ok(near(v.oy, 0), "экран у северного края поля: oy=" .. v.oy)
end

-- срез 12: те же герои 15 минут (владелец 2026-11-16: «персонажей нужно сделать консистентными хотябы на 10-15 мин»).
-- Срез 14 (владелец 2026-11-16: «не надо чтобы они стояли там же где были, надо чтобы они были»): вид отдаёт на
-- закрытии состав (kept: местность и имена), следующий вид на той же местности (перечитанной — новая таблица) выводит
-- тех же героев, расставленных заново, как при свежем открытии: по часу открытия, на экране сейчас, без следов

-- копия таблицы (местность, прочитанная из файла заново)
local function copy(v) return json.decode(json.encode(v)) end

-- cast.place подменён счётчиком на время fn -> сколько раз зван
local function place_calls(fn)
  local cast = require("riddle.cast")
  local orig, n = cast.place, 0
  cast.place = function(...)
    n = n + 1
    return orig(...)
  end
  local ok, err = pcall(fn)
  cast.place = orig
  assert(ok, err)
  return n
end

-- герои как значения: имя, место в поле, след
local function hero_rows(list)
  local out = {}
  for _, h in ipairs(list) do
    local tr = {}
    for _, p in ipairs(h.trail or {}) do tr[#tr + 1] = p[1] .. "," .. p[2] end
    out[#out + 1] = h.name .. "@" .. h.x .. "," .. h.y .. "[" .. table.concat(tr, " ") .. "]"
  end
  return table.concat(out, "; ")
end

-- открытая карта сделала 3 шага -> d, v, kept
local function walked_and_kept()
  local d, v = walking_map()
  t.eq(run_tasks(d, d.CFG.map_step_s, 3), 3, "три шага")
  return d, v, v:kept()
end

-- новый вид на копии той же местности с kept, проявлен -> d2, v2, сколько раз звали cast.place
local function reopened(v, kept, point, data)
  local d2 = map_diary(copy(v.terrain))
  local v2
  local n = place_calls(function()
    v2 = MapView.new(d2, data or v.data, point or CENTER, v.seed + 7, kept)
    v2:open()
    run_tasks(d2, MapView.INK_STEP_S)
  end)
  return d2, v2, n
end

-- имена героев по алфавиту, через запятую
local function names_key(list)
  local out = {}
  for _, h in ipairs(list) do out[#out + 1] = type(h) == "table" and h.name or h end
  table.sort(out)
  return table.concat(out, ",")
end

-- строки состава персоны с именами из names
local function cast_rows(data, names)
  local want, out = {}, {}
  for _, n in ipairs(names) do want[n] = true end
  for _, c in ipairs(data.cast) do if want[c.name] then out[#out + 1] = c end end
  return out
end

-- свежая расстановка этих героев на виде v сейчас (его местность, час, номер открытия, экран): все выходят
local function placed_anew(v, names)
  return require("riddle.cast").place(cast_rows(v.data, names), v.terrain, v.diary.map_clock(), v.seed,
    v:heroScreen(), true)
end

function T.test_kept_heroes_same_terrain()
  local _, v, kept = walked_and_kept()
  t.ok(kept and kept.terrain == v.terrain, "kept — местность вида")
  t.eq(names_key(kept.names), names_key(v:heroes()), "kept — имена героев вида")
  t.eq(kept.state, nil, "места, следы и tick не помнятся")
  local first = #infos
  local d2, v2, n = reopened(v, kept)
  t.eq(n, 1, "расстановка заново")
  t.eq(names_key(v2:heroes()), names_key(v:heroes()), "те же имена")
  t.eq(hero_rows(v2:heroes()), hero_rows(placed_anew(v2, kept.names)), "места — как при свежем открытии")
  for _, h in ipairs(v2:heroes()) do t.eq(h.trail, nil, h.name .. ": следов прежнего открытия нет") end
  t.eq(v2.cast_state.tick, nil, "шаги с начала")
  local logged = logged_since(first, "riddle: map cast")
  t.eq(#logged, 1, "одна строка героев")
  t.eq(logged[1], string.format("riddle: map cast kept n=%d visible=%d hour=12", #v2:heroes(),
    #on_screen_heroes(v2)))
  for _, h in ipairs(v2:heroes()) do t.ok(not logged[1]:find(h.name, 1, true), "имени нет в логе") end
  t.eq(run_tasks(d2, d2.CFG.map_step_s, 1), 1)
  t.eq(v2.cast_state.tick, 1, "шаг пошёл")
end

-- срез 14, улика с Kindle 07:58 («kept n=6 visible=3» против 4 при первом открытии): экран открытия снова — в другом
-- месте той же местности; герои стоят на нём, как при свежем открытии, а не там, где были
function T.test_kept_heroes_placed_on_screen_now()
  local _, v, kept = walked_and_kept()
  local tt = v.terrain
  local point = terrain.at(tt, -(tt.w - W) / 2, -(tt.h - H) / 2) -- экран в северо-западном углу поля
  local _, v2 = reopened(v, kept, point)
  t.ok(v2.ox ~= v.ox or v2.oy ~= v.oy, "экран сдвинут")
  t.eq(names_key(v2:heroes()), names_key(kept.names), "те же имена")
  t.eq(hero_rows(v2:heroes()), hero_rows(placed_anew(v2, kept.names)), "расставлены под экран сейчас")
  t.ok(#on_screen_heroes(v2) >= 1, "на экране хотя бы один")
end

-- срез 14: открыта снова в другой час — те же герои по распорядку нового часа (ночь: домой)
function T.test_kept_heroes_other_hour()
  local _, v, kept = walked_and_kept()
  local d2 = map_diary(copy(v.terrain))
  d2.map_clock = function() return { hour = 23, wday = 3, month = 10 } end
  local v2 = MapView.new(d2, v.data, CENTER, v.seed + 7, kept)
  v2:open()
  run_tasks(d2, MapView.INK_STEP_S)
  t.eq(names_key(v2:heroes()), names_key(kept.names), "те же имена")
  t.eq(hero_rows(v2:heroes()), hero_rows(placed_anew(v2, kept.names)), "места по новому часу")
end

-- Notion 41a13e60-bc8d-81d6: местность без улиц и без жилья — только лавка. Ночью все в ней (домой некуда — на работу),
-- в полдень будней ученикам места нет (ни школы, ни улиц, ни дома): не выходят, но состав из памяти не выпадает —
-- следующее открытие ночью выводит всех. Цепочка открытий состав не теряет; всем места нет — память та же
function T.test_kept_cast_survives_terrain_without_streets()
  local tt = field_of({ rect_bld(W / 2, H / 2, 120, 80, "shop") })
  local list, students = {}, {}
  for i = 1, 3 do
    list[#list + 1] = { name = "Ученик " .. i, role = "student", day = "school", night = "home" }
    list[#list + 1] = { name = "Лавочник " .. i, role = "townsfolk", day = "work", night = "home" }
  end
  for i = 1, 6 do students[i] = { name = "Ученик " .. i, role = "student", day = "school", night = "home" } end
  local NIGHT, NOON = { hour = 23, wday = 3, month = 10 }, { hour = 12, wday = 3, month = 10 }
  -- открытие на копии местности в час tm -> вид с расставленными героями
  local function open(data, tm, seed, kept)
    local d = map_diary(copy(tt))
    d.map_clock = function() return tm end
    local v = MapView.new(d, data, CENTER, seed, kept)
    v:open()
    run_tasks(d, MapView.INK_STEP_S)
    return v
  end
  for _, c in ipairs({ { list, "Лавочник 1,Лавочник 2,Лавочник 3" }, { students, "" } }) do
    local data, all = cast_data(c[1]), names_key(c[1])
    local v, seed
    for s = 1, 200 do
      v, seed = open(data, NIGHT, s), s
      if #v:heroes() == #c[1] then break end
    end
    t.eq(names_key(v:heroes()), all, "ночью выходят все шестеро")
    local kept = v:kept()
    for i = 1, 8 do
      local tm = i % 2 == 1 and NOON or NIGHT
      v = open(data, tm, seed + i, kept)
      t.eq(names_key(v:heroes()), tm == NOON and c[2] or all,
        (tm == NOON and "полдень: ученикам места нет — не вышли" or "ночь: снова все") .. " (открытие " .. i .. ")")
      kept = v:kept()
      t.ok(kept, "состав запомнен (открытие " .. i .. ")")
      t.eq(kept and names_key(kept.names), all, "в памяти все шестеро (открытие " .. i .. ")")
    end
  end
end

function T.test_kept_ignored_other_terrain()
  local _, v, kept = walked_and_kept()
  local other = copy(v.terrain)
  other.center = { lat = CENTER.lat + 0.01, lon = CENTER.lon }
  local d2 = map_diary(other)
  local first = #infos
  local n = place_calls(function()
    MapView.new(d2, v.data, other.center, v.seed + 7, kept):paint()
  end)
  t.eq(n, 1, "другая местность — расстановка заново")
  t.ok(logged_since(first, "riddle: map cast n=")[1], "лог новой расстановки")
  t.eq(#logged_since(first, "kept"), 0)
end

function T.test_kept_ignored_when_cast_changed()
  local _, v, kept = walked_and_kept()
  local gone = kept.names[1]
  local list = {}
  for _, h in ipairs(v.data.cast) do if h.name ~= gone then list[#list + 1] = h end end
  local _, v2, n = reopened(v, kept, nil, cast_data(list))
  t.eq(n, 1, "персона без одного из героев — расстановка заново")
  for _, h in ipairs(v2:heroes()) do t.ok(h.name ~= gone, "чужого героя нет") end
end

function T.test_kept_nil_before_heroes()
  local blind = MapView.new(map_diary(nil), cast_data(MP.cast()), nil, 1)
  blind:paint()
  t.eq(blind:kept(), nil, "blind: героев нет — помнить нечего")
  local fresh = MapView.new(map_diary(fixture_terrain()), cast_data(MP.cast()), CENTER, 1)
  t.eq(fresh:kept(), nil, "местность есть, но карта ещё не нарисована")
  -- ревью среза 12, Б1: раздел map.cast ещё не сгенерирован — героев нет, помнить нечего
  local empty = MapView.new(map_diary(fixture_terrain()), cast_data(nil), CENTER, 1)
  empty:paint()
  t.eq(#empty:heroes(), 0)
  t.eq(empty:kept(), nil, "пустой состав не запоминается")
end

-- восстановленные герои и точка рядом (near) — те же, шаг идёт; точка далеко с новой местностью (far) — заново
function T.test_kept_heroes_near_then_far()
  local _, v, kept = walked_and_kept()
  local d2, v2 = reopened(v, kept)
  local st = v2.cast_state
  v2:setPoint(terrain.at(v2.terrain, 40 + terrain.offset(v2.terrain, v2.point), 0), false)
  t.eq(v2.cast_state, st, "near: те же герои и шаг")
  local far = terrain.at(v2.terrain, 3 * W, 0)
  local new = copy(v2.terrain)
  new.center = { lat = far.lat, lon = far.lon }
  d2.map_terrain = function() return new end
  local first = #infos
  local n = place_calls(function()
    v2:setPoint(far, true)
    run_tasks(d2, MapView.INK_STEP_S)
  end)
  t.eq(v2.terrain, new)
  t.eq(n, 1, "far: расстановка заново")
  t.ok(v2.cast_for == new and v2.cast_state ~= st)
  t.eq(#logged_since(first, "riddle: map cast n="), 1)
  t.eq(#logged_since(first, "riddle: map cast kept"), 0)
end

-- восстановленные герои при другом сдвиге экрана (точка на той же местности над школой; в самой школе — книга
-- владельца, срез 13а): имена не на подписи и не друг на друге, отпечатки не под подписью
function T.test_kept_heroes_other_shift_no_overlap()
  local students = {}
  for i = 1, 6 do students[i] = { name = "Ученик " .. i, role = "student", day = "school", night = "home" } end
  local tt = field_of({ rect_bld(W / 2 + 60, H / 2 + 50, 200, 120, "school") })
  local data = cast_data(students, { school = "Хогвартс" })
  local v = MapView.new(map_diary(tt), data, CENTER, 2)
  v:paint()
  local kept = v:kept()
  local d2 = map_diary(copy(tt))
  local v2 = MapView.new(d2, data, terrain.at(tt, 60, -60), 9, kept)
  v2:paint()
  t.ok(v2.ox ~= v.ox and v2.oy ~= v.oy, "экран сдвинут")
  t.eq(names_key(v2:heroes()), names_key(v:heroes()), "те же герои")
  local label = label_text(d2, "Хогвартс").rect
  t.ok(#on_screen_heroes(v2) >= 2, "в школе несколько учеников")
  for _, q in ipairs(d2.rects) do
    if (q[3] == 4 and q[4] == 2 or q[3] == 2 and q[4] == 4) and q[5] == 0 then
      t.ok(q[1] + q[3] <= label.x or q[1] >= label.x + label.w or q[2] + q[4] <= label.y or q[2] >= label.y + label.h,
        "отпечаток не под подписью")
    end
  end
  local all = { label }
  for _, e in ipairs(names_of(d2)) do all[#all + 1] = e.rect end
  t.ok(#all >= 2, "имена есть")
  for i, a in ipairs(all) do
    for j = i + 1, #all do
      local b = all[j]
      t.ok(a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y, "не пересекаются")
    end
  end
end

-- одно правило «та же местность» — для setPoint и для памяти героев
function T.test_same_terrain_rule_public()
  local a = fixture_terrain()
  t.ok(MapView.sameTerrain(a, copy(a)), "перечитанная — та же")
  local b = copy(a)
  b.center.lat = b.center.lat + 0.001
  t.ok(not MapView.sameTerrain(a, b), "другой центр")
  t.ok(not MapView.sameTerrain(a, nil))
  t.ok(MapView.sameTerrain(nil, nil))
end

---------------------------------------------------------------------------
-- срез 13а: книга владельца в его точке и имя рядом (владелец 2026-11-16: «в той точке где находится книга на карте
-- (она в центре должна быть при открытии карты) пиши имя которым представился держатель дневника»)

-- данные карты с именем владельца (mapdata.of кладёт его в owner)
local function owner_data(owner, list, places)
  local data = cast_data(list, places)
  data.owner = owner
  return data
end

-- чёрные отпечатки малого пера (2 × 2: линии книги, улиц, контуров) внутри e = { x0, y0, x1, y1 } (края включены;
-- без e — все) -> сколько
local function small_ink(d, e)
  local n = 0
  for _, q in ipairs(d.rects) do
    if q[3] == 2 and q[4] == 2 and q[5] == 0 and (not e or q[1] >= e[1] and q[2] >= e[2] and q[1] + 1 <= e[3]
      and q[2] + 1 <= e[4]) then n = n + 1 end
  end
  return n
end

-- прямоугольник { x, y, w, h } -> края { x0, y0, x1, y1 } (включены)
local function edges_of(r) return { r.x, r.y, r.x + r.w - 1, r.y + r.h - 1 } end

-- отпечатки следов (ink.stamp: 4 × 2 и 2 × 4, чёрные) -> { { x0, y0, x1, y1 }, … }
local function feet_rects(d)
  local out = {}
  for _, q in ipairs(d.rects) do
    if (q[3] == 4 and q[4] == 2 or q[3] == 2 and q[4] == 4) and q[5] == 0 then
      out[#out + 1] = { q[1], q[2], q[1] + q[3] - 1, q[2] + q[4] - 1 }
    end
  end
  return out
end

-- книга и имя владельца не под следами и именами героев (метка m — ownerMark); owner — имя владельца
local function heroes_off_mark(d, m, owner, how)
  local feet = feet_rects(d)
  for _, q in ipairs(feet) do
    t.ok(not layout.near(q, m.book, 0), how .. ": отпечаток не на книге: " .. table.concat(q, ","))
    t.ok(not (m.name and layout.near(q, m.name.edges, 0)), how .. ": отпечаток не на имени: " .. table.concat(q, ","))
  end
  local names = 0
  for _, e in ipairs(names_of(d)) do
    if e.text ~= owner then
      names = names + 1
      t.ok(not layout.near(edges_of(e.rect), m.book, 4), how .. ": имя «" .. e.text .. "» не на книге")
      t.ok(not (m.name and layout.near(edges_of(e.rect), m.name.edges, 4)), how .. ": имя «" .. e.text ..
        "» не на имени владельца")
    end
  end
  return #feet, names
end

-- точка покрыта местностью: книга по центру экрана (там, где точка), полуширина BOOK, тушью линий (малое перо)
function T.test_book_at_owner_point()
  local d = map_diary(field_of({}))
  local v = MapView.new(d, owner_data(nil), CENTER, 1)
  v:paint()
  local m = assert(v:ownerMark(), "точка покрыта — книга есть")
  local b, x, y = m.book, W / 2, H / 2
  t.ok(b[1] <= x - MapView.BOOK and b[3] >= x + MapView.BOOK, "книга шириной 2·BOOK вокруг точки: " .. table.concat(b, ","))
  t.ok(b[3] - b[1] <= 2 * MapView.BOOK + 2 and b[4] - b[2] <= 2 * MapView.BOOK + 2, "не дальше BOOK от точки")
  t.ok(math.abs((b[1] + b[3]) / 2 - x) <= 1 and math.abs((b[2] + b[4]) / 2 - y) <= 1, "по центру пикселя точки")
  local n = small_ink(d, b)
  t.ok(n > 0, "чернила книги в центре экрана")
  t.eq(n, small_ink(d), "на пустом поле другой туши нет — это книга")
  t.ok(inked(d, x, y), "корешок — в точке владельца")
  t.eq(#labels_of(d), 0, "имени нет — ни одного текста")
end

-- точка вне поля (владелец уехал, новой местности нет): местность по её центру, книги нет — как у якоря среза 10; без
-- точки и без местности — тоже
function T.test_no_book_when_point_off_terrain()
  local tt = field_of({})
  local d = map_diary(tt)
  local v = MapView.new(d, owner_data("Гермиона"), terrain.at(tt, W + 50, 0), 1)
  v:paint()
  t.ok(v.box, "местность рисуется по своему центру")
  t.eq(v:ownerMark(), nil, "точка вне поля — книги нет")
  t.eq(small_ink(d), 0, "центр экрана без чернил книги")
  t.ok(not has_text(d, "Гермиона"), "и без имени")
  local nopoint = MapView.new(map_diary(tt), owner_data("Гермиона"), nil, 1)
  nopoint:paint()
  t.eq(nopoint:ownerMark(), nil, "точки нет")
  local blind = MapView.new(map_diary(nil), owner_data("Гермиона"), CENTER, 1)
  blind:paint()
  t.eq(blind:ownerMark(), nil, "местности нет (blind)")
end

-- поле под пальцем: книга и имя едут с ним; ушла за поле туши — её нет
function T.test_book_moves_with_pan()
  local d = map_diary(field_of({}))
  local v = MapView.new(d, owner_data("Гермиона"), CENTER, 1)
  v:paint()
  local before = assert(v:ownerMark())
  d.texts = {}
  t.ok(v:pan(-50, 0))
  local after = assert(v:ownerMark(), "книга на экране")
  t.eq(after.book[1], before.book[1] - 50, "книга на 50 px левее")
  t.eq(after.book[3], before.book[3] - 50)
  t.eq(after.book[2], before.book[2], "по вертикали на месте")
  t.ok(small_ink(d, after.book) > 0, "тушь книги на новом месте")
  t.eq(small_ink(d, after.book), small_ink(d), "и только там")
  local e = assert(has_text(d, "Гермиона"), "имя есть")
  t.ok(math.abs(e.rect.x + e.rect.w / 2 - (W / 2 - 50)) <= 1, "имя едет с книгой")
  d.texts = {}
  t.ok(v:pan(-(W / 2 - 70), 0), "точка к левой рамке")
  t.eq(v:ownerMark(), nil, "книга вышла за поле туши — её нет")
  t.eq(small_ink(d), 0, "ни штриха книги у рамки")
  t.ok(not has_text(d, "Гермиона"), "и имени")
end

-- штрихи книги и отпечатки следов, записанные на холст после последнего текста: (книга после, следов, следов после)
local function after_texts(d, m)
  local last_text = 0
  for _, e in ipairs(d.texts) do last_text = math.max(last_text, e.seq) end
  local book_after, feet, feet_after = 0, 0, 0
  for _, q in ipairs(d.rects) do
    if q[5] == 0 and q[3] <= 2 and q[4] <= 2 and q[1] >= m.book[1] and q[1] <= m.book[3] and q[2] >= m.book[2]
      and q[2] <= m.book[4] and q[6] > last_text then book_after = book_after + 1 end
    if q[5] == 0 and (q[3] == 4 and q[4] == 2 or q[3] == 2 and q[4] == 4) then
      feet = feet + 1
      if q[6] > last_text then feet_after = feet_after + 1 end
    end
  end
  return book_after, feet, feet_after
end

-- ревью пачки 4: книга и следы рисуются после обводок всех текстов (их обводка книгу и следы не белит) — при полной
-- перерисовке и при перерисовке места (repaintRect) через книгу и имя: каждый текст раньше последнего штриха книги и
-- каждого отпечатка
function T.test_book_and_feet_after_texts()
  local d = map_diary(field_of({}, { { W - 200, H, W + 200, H } }))
  local v = MapView.new(d, owner_data("Гермиона", bandits()), CENTER, 1)
  v:paint()
  local m = assert(v:ownerMark())
  t.ok(has_text(d, "Гермиона") and #names_of(d) >= 2, "имя владельца и имена героев")
  local book_after, feet, feet_after = after_texts(d, m)
  t.ok(book_after > 0, "книга — после текстов")
  t.ok(feet > 0, "следы есть")
  t.eq(feet_after, feet, "все отпечатки — после текстов")
  d.rects, d.texts = {}, {}
  local e, box = m.name.edges, v.box
  v:repaintRect({ math.max(box[1], math.min(m.book[1], e[1]) - 6), math.max(box[2], math.min(m.book[2], e[2]) - 6),
                  math.min(box[3] - 1, math.max(m.book[3], e[3]) + 6), math.min(box[4] - 1, math.max(m.book[4], e[4]) + 6) })
  t.ok(has_text(d, "Гермиона"), "место перерисовано: имя владельца заново")
  book_after, feet, feet_after = after_texts(d, m)
  t.ok(book_after > 0, "место: книга — после текстов")
  t.eq(feet_after, feet, "место: все отпечатки — после текстов")
end

-- имя, которым владелец представился, — под книгой, кеглем и тушью имён героев; у нижнего края — над книгой; шире
-- поля туши — книга без имени
function T.test_owner_name_under_book()
  local d = map_diary(field_of({}))
  local v = MapView.new(d, owner_data("Гермиона"), CENTER, 1)
  v:paint()
  local m = assert(v:ownerMark())
  local e = assert(has_text(d, "Гермиона"), "имя на карте")
  t.eq(e.px, math.floor(d.CFG.answer_px / 2), "кегль имён героев")
  t.eq(e.opts.threshold, MapView.LABEL_THRESHOLD, "тушь подписей: порог")
  t.eq(e.opts.bold, MapView.LABEL_BOLD, "жирность")
  t.eq(e.opts.halo, MapView.LABEL_HALO, "halo")
  t.ok(e.opts.clip and e.opts.clip[1] >= 25, "обводка — только в поле туши")
  t.ok(e.rect.y > m.book[4] and e.rect.y - m.book[4] <= 8, "под книгой, рядом: книга до " .. m.book[4] .. ", имя с " ..
    e.rect.y)
  t.ok(math.abs(e.rect.x + e.rect.w / 2 - W / 2) <= 1, "по центру книги")
  t.eq(m.name.text, "Гермиона")
  t.eq(m.name.rect.y, e.rect.y, "ownerMark — то, что нарисовано")
  -- точка у нижнего края экрана: под книгой места нет — имя над ней
  local tt = field_of({})
  local d2 = map_diary(tt)
  local v2 = MapView.new(d2, owner_data("Гермиона"), terrain.at(tt, 0, H - 50), 1)
  v2:paint()
  local m2 = assert(v2:ownerMark(), "книга у нижнего края")
  local e2 = assert(has_text(d2, "Гермиона"), "имя есть")
  t.ok(e2.rect.y + e2.rect.h <= m2.book[2], "над книгой")
  t.ok(inside(d2, e2.rect), "внутри рамки")
  -- шире поля туши — без имени, книга остаётся
  local d3 = map_diary(field_of({}))
  local v3 = MapView.new(d3, owner_data(string.rep("Ж", 80)), CENTER, 1)
  v3:paint()
  local m3 = assert(v3:ownerMark(), "книга есть")
  t.eq(m3.name, nil, "имя шире поля — без имени")
  t.eq(#labels_of(d3), 0)
  t.ok(small_ink(d3, m3.book) > 0)
end

-- имя неизвестно (до среза 13б — всегда): книга без имени
function T.test_no_name_book_only()
  local d = map_diary(field_of({}))
  local v = MapView.new(d, owner_data(nil), CENTER, 1)
  v:paint()
  local m = assert(v:ownerMark())
  t.ok(m.book, "книга есть")
  t.eq(m.name, nil, "имени нет")
  t.eq(#labels_of(d), 0, "на карте ни одного текста")
  t.ok(small_ink(d, m.book) > 0)
end

-- подпись здания в точке владельца пропущена (книга и имя — первыми в раскладке), дальняя — на месте; labels() не
-- пересекает книгу и имя, и при проявлении тоже
function T.test_label_skips_owner_mark()
  local tt = field_of({ rect_bld(W / 2, H / 2 + 10, 60, 60, "school"), rect_bld(200, 250, 40, 40, "pub") })
  local data = owner_data("Гермиона", nil, { school = "Хогвартс", pub = "Дырявый котёл" })
  local function check(d, v, how)
    local m = assert(v:ownerMark(), how)
    t.ok(m.name, how .. ": имя владельца есть")
    t.eq(label_text(d, "Хогвартс"), nil, how .. ": подпись места на книге пропущена")
    t.ok(label_text(d, "Дырявый котёл"), how .. ": дальняя подпись на месте")
    local ls = v:labels()
    t.ok(#ls >= 1)
    for _, l in ipairs(ls) do
      t.ok(not layout.near(l.edges, m.book, 4), how .. ": подпись «" .. l.text .. "» не на книге")
      t.ok(not layout.near(l.edges, m.name.edges, 4), how .. ": подпись «" .. l.text .. "» не на имени")
    end
  end
  local d = map_diary(tt)
  local v = MapView.new(d, data, CENTER, 1)
  v:paint()
  check(d, v, "paint")
  local d2 = map_diary(tt)
  local v2 = MapView.new(d2, data, CENTER, 1)
  v2:open()
  run_tasks(d2, MapView.INK_STEP_S)
  check(d2, v2, "проявление")
  t.ok(has_text(d2, "Гермиона"), "проявление: имя с последней партией")
end

-- вид v ставит на своей местности героев state (riddle.cast.step: heroes, trail, tick), а не расставляет сам -> v
local function given_heroes(v, state)
  v.cast_for, v.cast_state = v.terrain, state
  return v
end

-- Notion 41a13e60-bc8d-8165: карта открыта (герои расставлены самим видом под экран открытия), и до первого шага поле
-- сдвинуто пальцем так, что единственную улицу новый экран не видит: первый же шаг уводит всех бандитов с поля
-- (riddle.cast.step видит сдвиг от экрана расстановки). Поле вернули сразу: у каждого — отпечаток последней точки в следе,
-- но ни места, ни имени. Следы гаснут; дальше ни следов, ни имён: до следующего открытия не возвращаются
function T.test_shift_hero_unreachable_leaves()
  local tt = field_of({}, { { W / 2 + 150, H, W / 2 + 350, H } })
  local d = map_diary(tt)
  local v = MapView.new(d, cast_data(bandits()), CENTER, 1)
  v:open()
  run_tasks(d, MapView.INK_STEP_S)
  local cast = require("riddle.cast")
  local placed = v:heroes()
  t.ok(#placed >= 2, "бандиты расставлены: " .. #placed)
  for _, h in ipairs(placed) do
    t.ok(h.at == "street" and cast.on_screen(v:heroScreen(), h.x, h.y), h.name .. " на улице на экране")
  end
  t.ok(v:pan(-1000, 0), "поле сдвинуто к восточному краю")
  t.ok(not cast.on_screen(v:heroScreen(), W / 2 + 350, H), "улица бандитов за экраном")
  t.eq(run_tasks(d, d.CFG.map_step_s, 1), 1)
  local function spot(h) return terrain.round(h.x - v.ox), terrain.round(h.y - v.oy) end
  for i, h in ipairs(v.cast_state.heroes) do
    t.ok(h.gone, h.name .. " ушёл с поля")
    t.ok(h.x == placed[i].x and h.y == placed[i].y, h.name .. " стоит, где был")
  end
  d.texts = {}
  t.ok(v:pan(1000, 0), "поле вернули")
  for _, h in ipairs(v.cast_state.heroes) do
    t.ok(cast.on_screen(v:heroScreen(), h.x, h.y), h.name .. ": место снова на экране")
    local sx, sy = spot(h)
    t.ok(stamps_near(d, sx, sy, 12) > 0, h.name .. ": отпечаток последней точки в следе")
    t.ok(not has_text(d, h.name), h.name .. ": имени нет и у следа")
  end
  t.eq(run_tasks(d, d.CFG.map_step_s, 3), 3)
  d.texts = {}
  v:repaint()
  for _, h in ipairs(v.cast_state.heroes) do
    t.ok(h.gone, h.name .. ": шаги после возврата поля — не вернулся")
    t.eq(#h.trail, 0, h.name .. ": следы погасли")
    local sx, sy = spot(h)
    t.eq(stamps_near(d, sx, sy, 12), 0, h.name .. ": следов нет")
    t.ok(not has_text(d, h.name), h.name .. ": имени нет")
  end
end

-- герой в точке владельца (и его след через неё), другой — на месте имени владельца: следы сдвинуты с книги и имени,
-- не пропали; имена героев не на имени владельца и не на книге
function T.test_hero_off_owner_mark()
  local tt = field_of({}, { { W / 2, H, 3 * W / 2, H } })
  local d = map_diary(tt)
  local v = given_heroes(MapView.new(d, owner_data("Гермиона", bandits()), CENTER, 1), { trail = 4, tick = 0, heroes = {
    { name = "Бандит 1", x = W, y = H, trail = { { W - 8, H }, { W + 8, H } } },
    { name = "Бандит 2", x = W + 2, y = H + 22, trail = {} } } })
  v:paint()
  t.eq(#v:heroes(), 2, "герои — заданные")
  local m = assert(v:ownerMark())
  t.ok(m.name, "имя владельца есть")
  local feet, names = heroes_off_mark(d, m, "Гермиона", "paint")
  t.eq(feet, 4 * 8, "все четыре пары следов на карте (8 прямоугольников пара)")
  t.ok(names <= 2, "имена героев — не больше двух")
end

-- ревью среза 13а, Б1: книга у нижнего края — имя над ней; след героя в точке владельца, сдвинутый с книги вверх, лёг
-- бы на имя, а с имени вниз — снова на книгу. Ни тот, ни другой: след у свободного места, не пропал. Оба пути к краю:
-- точка у края поля и сдвиг пальцем
function T.test_review_hero_off_owner_mark_at_bottom()
  local tt = field_of({})
  local function check(point, fy, pan, how)
    local d = map_diary(tt)
    local v = given_heroes(MapView.new(d, owner_data("Гермиона", bandits()), point, 1), { trail = 4, tick = 0, heroes = {
      { name = "Бандит 1", x = W, y = fy, trail = { { W - 8, fy } } } } })
    v:paint()
    if pan then
      d.texts = {}
      t.ok(v:pan(0, pan), how .. ": поле сдвинуто")
    end
    local m = assert(v:ownerMark(), how .. ": книга есть")
    t.ok(m.name and m.name.rect.y < m.book[2], how .. ": имя над книгой")
    local feet = heroes_off_mark(d, m, "Гермиона", how)
    t.ok(feet >= 8, how .. ": следы на карте: " .. feet)
  end
  check(terrain.at(tt, 0, H - 50), 2 * H - 50, nil, "точка у края поля")
  check(CENTER, H, H / 2 - 50, "сдвиг пальцем")
end

-- срез 12/14: карту открыли снова там, где стоял один из героев (владелец пришёл к нему): те же герои расставлены
-- заново, книга и имя не под их следами и именами
function T.test_kept_heroes_off_owner_mark()
  local _, v, kept = walked_and_kept()
  local walker
  for _, h in ipairs(v:heroes()) do if h.name == "Бандит" then walker = h end end
  t.ok(walker, "бандит на прежней карте")
  local tt = v.terrain
  local point = terrain.at(tt, walker.x - tt.w / 2, walker.y - tt.h / 2)
  local data = copy(v.data)
  data.owner = "Гермиона"
  local d2, v2 = reopened(v, kept, point, data)
  t.eq(names_key(v2:heroes()), names_key(kept.names), "те же герои")
  local m = assert(v2:ownerMark(), "книга в точке владельца")
  t.ok(m.name, "имя владельца есть")
  heroes_off_mark(d2, m, "Гермиона", "открыта снова")
  -- и после шагов (частичная перерисовка): ни один след и ни одно имя, нарисованные за шаги, не легли на метку
  t.eq(run_tasks(d2, d2.CFG.map_step_s, 3), 3)
  t.ok(v2.cast_state.tick == 3, "шаги шли")
  heroes_off_mark(d2, v2.drawn.owner, "Гермиона", "после шагов")
end

-- вариант test_review_steps_equal_full_repaint с книгой и именем: улицы крестом через точку владельца — идущие по ним
-- обходят книгу и имя; после шагов холст = полной перерисовке. Следы обходят метку, и место шага задевает её только
-- слитым прямоугольником — поэтому после шагов перерисовано и место через книгу и имя целиком (как слитое место шага):
-- холст тот же
function T.test_steps_keep_owner_mark()
  local runs, moved = steps_equal_full("Гермиона", function(v)
    local m, box = v.drawn.owner, v.box
    t.ok(m and m.name, "книга и имя на карте")
    local e = m.name.edges
    v:repaintRect({ math.max(box[1], math.min(m.book[1], e[1]) - 6), math.max(box[2], math.min(m.book[2], e[2]) - 6),
                    math.min(box[3] - 1, math.max(m.book[3], e[3]) + 6), math.min(box[4] - 1, math.max(m.book[4], e[4]) + 6) })
  end)
  t.ok(moved >= 6, "герои шагали в большинстве прогонов: " .. moved .. " из " .. runs)
end

-- лог отрисовки: есть ли книга и имя — без имени и без координат; та же метка при сдвиге не повторяется
function T.test_owner_log_no_name()
  local first = #infos
  local d = map_diary(field_of({}))
  local v = MapView.new(d, owner_data("Гермиона"), CENTER, 1)
  v:paint()
  local logged = logged_since(first, "riddle: map owner")
  t.eq(#logged, 1, "одна строка")
  t.eq(logged[1], "riddle: map owner book=1 name=1")
  for i = first + 1, #infos do t.ok(not infos[i]:find("Гермиона", 1, true), "имени нет в логе: " .. infos[i]) end
  t.ok(v:pan(-20, 0))
  t.eq(#logged_since(first, "riddle: map owner"), 1, "сдвиг с той же меткой — без новой строки")
  local first2 = #infos
  local v2 = MapView.new(map_diary(field_of({})), owner_data(nil), CENTER, 1)
  v2:paint()
  t.eq(table.concat(logged_since(first2, "riddle: map owner"), "|"), "riddle: map owner book=1 name=0")
  local first3 = #infos
  local tt = field_of({})
  MapView.new(map_diary(tt), owner_data("Гермиона"), terrain.at(tt, W + 50, 0), 1):paint()
  t.eq(table.concat(logged_since(first3, "riddle: map owner"), "|"), "riddle: map owner book=0 name=0")
end

t.run(T)
