-- Герои на карте (план карты, срез 7): riddle.cast — чистая расстановка по часу, дню недели, сезону и типу здания.
local t = require("t")
local cast = require("riddle.cast")
local MP = require("fixtures.map_parts")

local T = {}

local terrain_round = require("riddle.terrain").round

local W, H = 758, 1024
-- экран — середина поля 2 × экран (поле в пикселях поля; запас — по полэкрана с каждой стороны)
local SCREEN = { W / 2 + 30, H / 2 + 30, 3 * W / 2 - 30, 3 * H / 2 - 30 }

local function rect(x0, y0, x1, y1, kind)
  return { kind = kind, pts = { x0, y0, x1, y0, x1, y1, x0, y1, x0, y0 } }
end

-- местность: улицы крест-накрест через всё поле, школа и лавка на экране, дома — на экране и в запасе
local function town()
  local b = {
    rect(700, 700, 800, 780, "school"),
    rect(900, 1200, 940, 1240, "shop"),
    rect(450, 600, 480, 630, "house"), rect(1000, 900, 1030, 930, "house"), rect(100, 100, 130, 130, "house"),
    rect(1400, 1900, 1430, 1930, "house"), rect(600, 1300, 630, 1330, "house"), rect(1200, 300, 1230, 330, "house"),
    rect(300, 1500, 330, 1530, nil),
  }
  return { center = { lat = 10, lon = 20 }, w = 2 * W, h = 2 * H, m_per_px = 0.7, buildings = b,
           streets = { { 0, H, 2 * W, H }, { W, 0, W, 2 * H }, { 0, 200, 2 * W, 250 } } }
end

local WEEKDAY_NOON = { hour = 12, wday = 3, month = 10 } -- вторник, октябрь
local NIGHT = { hour = 23, wday = 3, month = 10 }
local SATURDAY_NOON = { hour = 12, wday = 7, month = 10 }
local SUNDAY_NOON = { hour = 12, wday = 1, month = 10 }
local JULY_NOON = { hour = 12, wday = 3, month = 7 }

local function hero_of(list, name)
  for _, h in ipairs(list) do if h.name == name then return h end end
end

local function inside(b, x, y)
  local p = b.pts
  return x >= p[1] and x <= p[3] and y >= p[2] and y <= p[6]
end

local function on_screen(h)
  return h.x >= SCREEN[1] and h.x <= SCREEN[3] and h.y >= SCREEN[2] and h.y <= SCREEN[4]
end

-- каждый расставленный герой проверен check(hero, его строка состава) на seed 1..n
local function each_seed(tr, tm, n, check, list)
  list = list or MP.cast()
  for seed = 1, n do
    for _, h in ipairs(cast.place(list, tr, tm, seed, SCREEN)) do check(h, hero_of(list, h.name), seed) end
  end
end

function T.test_clock()
  local c = cast.clock(WEEKDAY_NOON)
  t.ok(c.school_day and not c.night and not c.weekend and not c.winter, "будни, полдень, октябрь")
  t.ok(cast.clock(NIGHT).night and not cast.clock(NIGHT).school_day, "23:00 — ночь")
  t.ok(cast.clock({ hour = 5, wday = 3, month = 10 }).night, "5:00 — ещё ночь")
  t.ok(not cast.clock({ hour = 6, wday = 3, month = 10 }).night, "6:00 — уже утро")
  t.ok(not cast.clock({ hour = 7, wday = 3, month = 10 }).school_day, "7:00 — школа ещё закрыта")
  t.ok(not cast.clock({ hour = 15, wday = 3, month = 10 }).school_day, "15:00 — уроки кончились")
  t.ok(cast.clock(SATURDAY_NOON).weekend and cast.clock(SUNDAY_NOON).weekend, "суббота и воскресенье (wday 7, 1)")
  t.ok(not cast.clock(SATURDAY_NOON).school_day, "в выходные школы нет")
  t.ok(not cast.clock(JULY_NOON).school_day, "летом каникулы")
  t.ok(cast.clock({ hour = 12, wday = 3, month = 1 }).winter and cast.clock({ hour = 12, wday = 3, month = 12 }).winter)
  t.ok(not cast.clock({ hour = 12, wday = 3, month = 3 }).winter, "март — не зима")
end

-- 23:00 в будни: ученики и все с night = home — дома, сторожа и злодеи с night = street — на улице, в школе никого
function T.test_night_students_home_guard_street()
  local tr = town()
  local saw_street, saw_home = false, false
  each_seed(tr, NIGHT, 30, function(h, row)
    t.ok(h.at ~= "school", "ночью в школе никого: " .. h.name)
    if row.night == "street" then
      t.eq(h.at, "street", h.name .. " ночью на улице")
      saw_street = true
    else
      t.eq(h.at, "home", h.name .. " ночью дома")
      t.ok(inside(tr.buildings[cast.home(h.name, tr)], h.x, h.y), h.name .. " в своём доме")
      saw_home = true
    end
  end)
  t.ok(saw_street and saw_home, "и дома, и на улице кто-то был")
end

function T.test_weekday_noon_students_in_school()
  local tr = town()
  local saw = false
  each_seed(tr, WEEKDAY_NOON, 30, function(h, row)
    if row.day == "school" then
      t.eq(h.at, "school", h.name .. " в будни в полдень — в школе")
      t.ok(inside(tr.buildings[1], h.x, h.y), "внутри школы")
      saw = true
    else
      t.ok(h.at ~= "school", "в школе только те, у кого day = school")
    end
    if row.day == "work" then t.ok(h.at == "shop" or h.at == "street", h.name .. " на работе: " .. h.at) end
    if row.day == "street" then t.eq(h.at, "street") end
    if row.day == "home" then t.eq(h.at, "home") end
  end)
  t.ok(saw, "ученики попадались")
end

function T.test_weekend_school_empty()
  local tr = town()
  for _, tm in ipairs({ SATURDAY_NOON, SUNDAY_NOON }) do
    each_seed(tr, tm, 30, function(h, row)
      t.ok(h.at ~= "school", "в выходные школа пуста: " .. h.name)
      if row.day == "school" then t.ok(h.at == "street" or h.at == "home", "школьник на улице или дома") end
    end)
  end
end

function T.test_summer_no_school()
  each_seed(town(), JULY_NOON, 30, function(h) t.ok(h.at ~= "school", "июль — каникулы: " .. h.name) end)
end

-- злодей-бандит с распорядком «улица» ходит и днём (спека, раздел 2), в будни и в выходные
function T.test_bandit_villain_street_by_day()
  local list = { { name = "Бандит", role = "villain", day = "street", night = "street" },
                 { name = "Ученик", role = "student", day = "school", night = "home" } }
  for _, tm in ipairs({ WEEKDAY_NOON, SATURDAY_NOON, NIGHT }) do
    for seed = 1, 10 do
      local h = hero_of(cast.place(list, town(), tm, seed, SCREEN), "Бандит")
      t.ok(h, "бандит на карте")
      t.eq(h.at, "street", "бандит на улице в " .. tm.hour .. ":00, день " .. tm.wday)
    end
  end
end

-- дом героя — жилое здание местности по хешу имени: тот же между открытиями (другой seed, другой час)
function T.test_home_stable_between_opens()
  local tr = town()
  local list = MP.cast()
  for _, row in ipairs(list) do
    local i = cast.home(row.name, tr)
    t.ok(i, "дом есть: " .. row.name)
    t.eq(tr.buildings[i].kind, "house", "дом — жилое здание")
    t.eq(cast.home(row.name, town()), i, "та же местность — тот же дом")
  end
  local at = {}
  for seed = 1, 40 do
    for _, h in ipairs(cast.place(list, tr, NIGHT, seed, SCREEN)) do
      if h.at == "home" then
        local key = h.x .. "," .. h.y
        t.ok(at[h.name] == nil or at[h.name] == key, h.name .. " дома всегда в одной точке")
        at[h.name] = key
      end
    end
  end
  -- жилых нет — дома в зданиях без типа; зданий нет вовсе — дома нет
  local untyped = { center = tr.center, w = tr.w, h = tr.h, m_per_px = 0.7, streets = {},
                    buildings = { rect(10, 10, 40, 40, "school"), rect(50, 50, 80, 80, nil) } }
  t.eq(cast.home("Фродо", untyped), 2, "без жилых — здание без типа")
  t.eq(cast.home("Фродо", { buildings = {}, streets = {} }), nil)
end

-- 100 открытий днём и ночью: 2–6 героев, ≥ 1 на экране, ≤ 3 в запасе поля
function T.test_count_and_visibility()
  local tr = town()
  for _, tm in ipairs({ WEEKDAY_NOON, NIGHT, SATURDAY_NOON }) do
    for seed = 1, 100 do
      local list = cast.place(MP.cast(), tr, tm, seed, SCREEN)
      t.ok(#list >= 2 and #list <= 6, "героев 2–6, сейчас " .. #list)
      local v = 0
      for _, h in ipairs(list) do
        if on_screen(h) then v = v + 1 end
        t.ok(h.x >= 0 and h.x <= tr.w and h.y >= 0 and h.y <= tr.h, "в поле")
      end
      t.ok(v >= 1, "на экране хотя бы один (seed " .. seed .. ", " .. tm.hour .. ":00)")
      t.ok(#list - v <= 3, "в запасе не больше трёх, сейчас " .. (#list - v))
      local names = {}
      for _, h in ipairs(list) do
        t.eq(names[h.name], nil, "герой один раз")
        names[h.name] = true
      end
    end
  end
  -- в составе меньше двух — сколько есть
  t.eq(#cast.place(MP.cast(1), tr, WEEKDAY_NOON, 1, SCREEN), 1)
  t.eq(#cast.place({}, tr, WEEKDAY_NOON, 1, SCREEN), 0)
  -- та же расстановка от тех же входов
  local a, b = cast.place(MP.cast(), tr, NIGHT, 7, SCREEN), cast.place(MP.cast(), tr, NIGHT, 7, SCREEN)
  for i = 1, #a do t.ok(a[i].name == b[i].name and a[i].x == b[i].x and a[i].y == b[i].y, "чистая функция") end
end

-- срез 14: состав задан (all — карта, открытая снова за 15 минут): выходят все герои списка, а не 2–6 по seed;
-- места — по тем же правилам, что у свежего открытия (≥ 1 на экране; в городке, где места на экране есть, в запасе ≤ 3)
function T.test_place_all_of_list()
  local tr = town()
  local full = MP.cast()
  for _, tm in ipairs({ WEEKDAY_NOON, NIGHT, SATURDAY_NOON }) do
    for k = 1, cast.MAX do
      for seed = 1, 30 do
        local list = {}
        for i = 1, k do list[i] = full[(seed + i * 3) % #full + 1] end
        local want, got = {}, {}
        for _, h in ipairs(list) do want[#want + 1] = h.name end
        local out = cast.place(list, tr, tm, seed, SCREEN, true)
        local v = 0
        for _, h in ipairs(out) do
          got[#got + 1] = h.name
          if on_screen(h) then v = v + 1 end
        end
        table.sort(want)
        table.sort(got)
        t.eq(table.concat(got, ","), table.concat(want, ","), "вышли все " .. k .. " (seed " .. seed .. ")")
        t.ok(v >= 1 and #out - v <= cast.RESERVE_MAX, "на экране ≥ 1, в запасе ≤ 3")
      end
    end
  end
end

-- срез 14: все дома за экраном, запас полон — без all домосед не выходит, с all выходит в запас (тот же состав:
-- «надо чтобы они были»); на экране — уличный
function T.test_place_all_reserve_full()
  local houses = {}
  for i = 1, 5 do houses[i] = rect(40 + i * 60, 40, 80 + i * 60, 80, "house") end
  local tr = { center = { lat = 10, lon = 20 }, w = 2 * W, h = 2 * H, m_per_px = 0.7, buildings = houses,
               streets = { { W / 2 + 100, H, 3 * W / 2 - 100, H } } }
  local list = { { name = "Бродяга", role = "villain", day = "street", night = "street" } }
  for i = 1, 5 do list[#list + 1] = { name = "Домосед " .. i, role = "townsfolk", day = "home", night = "home" } end
  for seed = 1, 20 do
    local out = cast.place(list, tr, WEEKDAY_NOON, seed, SCREEN, true)
    t.eq(#out, 6, "вышли все шестеро (seed " .. seed .. ")")
    local v = 0
    for _, h in ipairs(out) do if on_screen(h) then v = v + 1 end end
    t.eq(v, 1, "на экране — уличный")
    t.ok(#cast.place(list, tr, WEEKDAY_NOON, seed, SCREEN) <= 4, "без all — запас ≤ 3")
  end
end

-- без all — расстановка та же, что была до среза 14 (all меняет только сколько выходит)
function T.test_place_all_same_rules()
  local tr = town()
  for seed = 1, 30 do
    local a = cast.place(MP.cast(), tr, WEEKDAY_NOON, seed, SCREEN)
    local list = {}
    for i, h in ipairs(a) do list[i] = hero_of(MP.cast(), h.name) end
    if #list <= 2 then
      -- 2 героя: и без all выходят оба — расстановки совпадают (all не тратит лишних бросков)
      local b, c = cast.place(list, tr, WEEKDAY_NOON, seed, SCREEN), cast.place(list, tr, WEEKDAY_NOON, seed, SCREEN, true)
      for i = 1, #b do t.ok(b[i].name == c[i].name and b[i].x == c[i].x and b[i].y == c[i].y, "те же места") end
    end
  end
end

-- местность без школы и без жилых домов (только улицы): все на улицах; пустая местность — никого
function T.test_place_no_school_no_houses()
  local streets = { center = { lat = 10, lon = 20 }, w = 2 * W, h = 2 * H, m_per_px = 0.7, buildings = {},
                    streets = { { 0, H, 2 * W, H } } }
  for _, tm in ipairs({ WEEKDAY_NOON, NIGHT }) do
    for seed = 1, 20 do
      local list = cast.place(MP.cast(), streets, tm, seed, SCREEN)
      t.ok(#list >= 2 and #list <= 6, "2–6")
      for _, h in ipairs(list) do t.eq(h.at, "street", h.name .. ": доступна только улица") end
    end
  end
  local empty = { center = { lat = 10, lon = 20 }, w = 2 * W, h = 2 * H, m_per_px = 0.7, buildings = {}, streets = {} }
  t.eq(#cast.place(MP.cast(), empty, WEEKDAY_NOON, 1, SCREEN), 0, "пусто — героев нет")
  -- школа есть, но вне ночи и дня уроков все не в ней; школы нет — никого в школе
  local no_school = town()
  table.remove(no_school.buildings, 1)
  each_seed(no_school, WEEKDAY_NOON, 20, function(h) t.ok(h.at ~= "school", "школы нет — в школе никого") end)
end

-- состав ротируется между открытиями (seed — номер открытия)
function T.test_rotation_changes_cast()
  local seen, kinds = {}, 0
  for seed = 1, 10 do
    local names = {}
    for _, h in ipairs(cast.place(MP.cast(), town(), WEEKDAY_NOON, seed, SCREEN)) do names[#names + 1] = h.name end
    table.sort(names)
    local key = table.concat(names, ",")
    if not seen[key] then seen[key], kinds = true, kinds + 1 end
  end
  t.ok(kinds >= 5, "за 10 открытий — не меньше 5 разных составов, сейчас " .. kinds)
end

-- зима: меньше на улицах — в выходной полдень школьники и работники не гуляют
function T.test_winter_fewer_on_streets()
  local function street_count(month)
    local n = 0
    each_seed(town(), { hour = 12, wday = 7, month = month }, 50, function(h) if h.at == "street" then n = n + 1 end end)
    return n
  end
  t.ok(street_count(1) < street_count(10), "в январе на улицах меньше, чем в октябре")
end

-- ревью среза 7, круг 1

-- экран ревьюера: ровно середина поля
local MID = { W / 2, H / 2, 3 * W / 2, 3 * H / 2 }

local function field(buildings, streets)
  return { center = { lat = 1, lon = 2 }, w = 2 * W, h = 2 * H, m_per_px = 0.7, buildings = buildings, streets = streets }
end

local function visible_in(list, screen)
  local v = 0
  for _, h in ipairs(list) do if cast.on_screen(screen, h.x, h.y) then v = v + 1 end end
  return v
end

local function numbers(list)
  for _, h in ipairs(list) do
    if type(h.x) ~= "number" or type(h.y) ~= "number" or h.x ~= h.x or h.y ~= h.y then return false end
  end
  return true
end

local STUDENTS = { { name = "Гарри", role = "student", day = "school", night = "home" },
                   { name = "Рон", role = "student", day = "school", night = "home" } }

-- ночь, улица только за экраном (парк вокруг владельца), дома за экраном, сторож свободен: стоять на экране
-- по распорядку некому — visible = 0, но без падения, у каждого героя точка
function T.test_review_street_only_off_screen_no_crash()
  local tr = field({ rect(50, 50, 90, 90, "house"), rect(1400, 1900, 1440, 1940, "house") },
                   { { 0, 200, 2 * W, 200 } })
  local list = { STUDENTS[1], STUDENTS[2], { name = "Филч", role = "guard", day = "school", night = "street" } }
  for seed = 1, 200 do
    local ok, out = pcall(cast.place, list, tr, NIGHT, seed, MID)
    t.ok(ok, "seed " .. seed .. ": " .. tostring(out))
    t.ok(numbers(out), "у каждого героя x, y — числа")
    t.ok(#out >= 2, "герои расставлены в запасе")
    t.eq(visible_in(out, MID), 0, "на экран по распорядку некому")
  end
end

-- случайные местности (улицы и здания где угодно, в том числе только за экраном или нигде), состав, время и seed:
-- ни одного падения, у каждого героя точка в поле, героев ≤ 6, в запасе ≤ 3, имена не повторяются
function T.test_review_fuzz_random_terrains()
  local rnd = math.random
  math.randomseed(20261116)
  local KINDS = { "house", "house", "school", "shop", "park", "pub", false }
  for i = 1, 1500 do
    local streets, buildings = {}, {}
    for _ = 1, rnd(0, 3) do
      local s = {}
      for _ = 1, rnd(2, 4) do s[#s + 1], s[#s + 2] = rnd(0, 2 * W), rnd(0, 2 * H) end
      streets[#streets + 1] = s
    end
    for _ = 1, rnd(0, 6) do
      local x, y = rnd(0, 2 * W - 40), rnd(0, 2 * H - 40)
      buildings[#buildings + 1] = rect(x, y, x + rnd(10, 40), y + rnd(10, 40), KINDS[rnd(#KINDS)] or nil)
    end
    local list = {}
    for k = 1, rnd(0, 8) do
      list[k] = { name = "Герой " .. k, role = "guard",
                  day = ({ "school", "work", "street", "home" })[rnd(4)], night = ({ "home", "street" })[rnd(2)] }
    end
    local sx, sy = rnd(0, W), rnd(0, H)
    local screen = { sx, sy, sx + W - 12, sy + H - 12 }
    local tm = { hour = rnd(0, 23), wday = rnd(1, 7), month = rnd(1, 12) }
    local ok, out = pcall(cast.place, list, field(buildings, streets), tm, rnd(1, 100000), screen)
    t.ok(ok, "прогон " .. i .. ": " .. tostring(out))
    t.ok(numbers(out), "прогон " .. i .. ": точки — числа")
    t.ok(#out <= 6 and #out - visible_in(out, screen) <= 3, "прогон " .. i .. ": 6 и 3")
    local seen = {}
    for _, h in ipairs(out) do
      t.ok(not seen[h.name] and h.x >= 0 and h.x <= 2 * W and h.y >= 0 and h.y <= 2 * H, "прогон " .. i)
      seen[h.name] = true
    end
  end
end

-- суббота, август, полдень: ученикам можно и на улицу, и домой; улица через экран, дома за ним — на экране всегда
-- кто-то есть (добор берёт разрешённое распорядком место на экране)
function T.test_review_free_heroes_fill_screen()
  local tr = field({ rect(50, 50, 90, 90, "house"), rect(1400, 1900, 1440, 1940, "house") }, { { 0, H, 2 * W, H } })
  local sat = { hour = 12, wday = 7, month = 8 }
  local zero = 0
  for seed = 1, 200 do
    local out = cast.place(STUDENTS, tr, sat, seed, MID)
    t.eq(#out, 2)
    if visible_in(out, MID) == 0 then zero = zero + 1 end
    for _, h in ipairs(out) do
      if cast.on_screen(MID, h.x, h.y) then t.eq(h.at, "street", "на экране — на улице, как пускает распорядок") end
    end
  end
  t.eq(zero, 0, "visible = 0 на скольких seed из 200")
  -- зимой праздным только домой: на экран некому
  local jan = cast.place(STUDENTS, tr, { hour = 12, wday = 7, month = 1 }, 1, MID)
  t.eq(visible_in(jan, MID), 0, "январь: оба дома за экраном")
end

function T.test_review_clock_edges()
  t.ok(cast.clock({ hour = 22, wday = 3, month = 10 }).night, "22:00 — ночь")
  t.ok(not cast.clock({ hour = 21, wday = 3, month = 10 }).night, "21:00 — ещё вечер")
  t.ok(cast.clock({ hour = 8, wday = 3, month = 10 }).school_day, "8:00 — урок")
  t.ok(cast.clock({ hour = 14, wday = 3, month = 10 }).school_day, "14:00 — урок")
  t.ok(not cast.clock({ hour = 12, wday = 3, month = 6 }).school_day, "июнь — каникулы")
  t.ok(not cast.clock({ hour = 12, wday = 3, month = 8 }).school_day, "август — каникулы")
  t.ok(cast.clock({ hour = 12, wday = 3, month = 5 }).school_day, "май — учатся")
  t.ok(cast.clock({ hour = 12, wday = 3, month = 9 }).school_day, "сентябрь — учатся")
  local fri = cast.clock({ hour = 12, wday = 6, month = 10 })
  t.ok(not fri.weekend and fri.school_day, "пятница — будни")
  t.ok(not cast.clock({ hour = 12, wday = 2, month = 10 }).weekend, "понедельник — будни")
  t.ok(cast.clock({ hour = 12, wday = 1, month = 10 }).weekend, "воскресенье — выходной")
end

-- в выходные на работу не ходят: на улице или дома
function T.test_review_no_work_on_weekend()
  local list = MP.cast()
  each_seed(town(), SATURDAY_NOON, 40, function(h, row)
    if row.day == "work" then t.ok(h.at == "street" or h.at == "home", h.name .. " в выходной: " .. h.at) end
  end, list)
  local worked = false
  each_seed(town(), WEEKDAY_NOON, 40, function(h, row) if row.day == "work" and h.at == "shop" then worked = true end end)
  t.ok(worked, "в будни — в лавке")
end

-- Notion 41a13e60-bc8d-8159, п.3 (владелец 2026-11-16: «прогулки, работа в любых зданиях»): парк — место прогулок, не
-- работы. Парк и лавка на экране: работник в будни — в лавке, не в парке (без работы в местности работник гуляет —
-- FALLBACK, и прогулка может быть в парке: test_park_is_for_walks)
function T.test_park_is_not_work()
  local workers = {}
  for k = 1, 6 do workers[k] = { name = "Работник " .. k, role = "townsfolk", day = "work", night = "home" } end
  local houses = { rect(450, 600, 480, 630, "house"), rect(1000, 900, 1030, 930, "house") }
  local with_shop = field({ rect(700, 700, 900, 900, "park"), rect(950, 1200, 990, 1240, "shop"), houses[1], houses[2] },
                          { { 0, H, 2 * W, H } })
  local shop = with_shop.buildings[2]
  for seed = 1, 60 do
    for _, h in ipairs(cast.place(workers, with_shop, WEEKDAY_NOON, seed, SCREEN)) do
      t.eq(h.at, "shop", h.name .. ": на работе — в лавке (seed " .. seed .. ")")
      t.ok(inside(shop, h.x, h.y), h.name .. ": точка в лавке")
    end
  end
end

-- п.1 той же задачи: тип работы — работник стоит в здании, тип которого у него в at (лавка или паб), не в доме и не
-- в школе
function T.test_work_kind_is_building_kind()
  local tr = field({ rect(700, 700, 800, 780, "school"), rect(900, 1200, 940, 1240, "shop"),
                     rect(600, 900, 660, 960, "pub"), rect(450, 600, 480, 630, "house"), rect(300, 1500, 330, 1530) },
                   { { 0, H, 2 * W, H } })
  local workers = {}
  for k = 1, 6 do workers[k] = { name = "Работник " .. k, role = "townsfolk", day = "work", night = "home" } end
  local kinds = {}
  for seed = 1, 60 do
    for _, h in ipairs(cast.place(workers, tr, WEEKDAY_NOON, seed, SCREEN)) do
      t.ok(h.at == "shop" or h.at == "pub", h.name .. ": работа — лавка или паб, а не " .. h.at)
      local found = false
      for _, b in ipairs(tr.buildings) do if b.kind == h.at and inside(b, h.x, h.y) then found = true end end
      t.ok(found, h.name .. ": точка в здании типа " .. h.at)
      kinds[h.at] = true
    end
  end
  t.ok(kinds.shop and kinds.pub, "работают и в лавке, и в пабе")
end

-- парк — место прогулок (владелец 2026-11-16): уличный герой гуляет по улицам или в парке (at = "park", точка
-- строго внутри парка); в парке ходит по парку (Notion 41a13e60-bc8d-81cf). Местность без улиц, но с парком — уличному
-- есть где гулять
function T.test_park_is_for_walks()
  local park = rect(700, 700, 900, 900, "park")
  local walkers = {}
  for k = 1, 6 do walkers[k] = { name = "Гуляка " .. k, role = "villain", day = "street", night = "street" } end
  local tr = field({ park, rect(450, 600, 480, 630, "house") }, { { 0, H, 2 * W, H } })
  local seen = {}
  for seed = 1, 60 do
    local out = cast.place(walkers, tr, WEEKDAY_NOON, seed, SCREEN)
    for _, h in ipairs(out) do
      t.ok(h.at == "street" or h.at == "park", h.name .. ": гуляет, а не " .. h.at)
      if h.at == "park" then
        t.ok(inside(park, h.x, h.y) and h.x > 700 and h.x < 900 and h.y > 700 and h.y < 900, "точка в парке")
      end
      seen[h.at] = true
    end
    local st = cast.step({ heroes = out, screen = SCREEN, trail = 4 }, tr, 2.5)
    for k, h in ipairs(st.heroes) do
      if h.at == "park" then
        t.ok(h.x ~= out[k].x or h.y ~= out[k].y, "в парке ходит")
        t.ok(h.x > 700 and h.x < 900 and h.y > 700 and h.y < 900, "и не выходит из парка: " .. h.x .. "," .. h.y)
      end
    end
  end
  t.ok(seen.street and seen.park, "гуляют и по улицам, и в парке")
  local no_streets = field({ park }, {})
  for seed = 1, 20 do
    local out = cast.place(walkers, no_streets, WEEKDAY_NOON, seed, SCREEN)
    t.ok(#out >= 2, "без улиц — гуляют в парке (seed " .. seed .. ")")
    for _, h in ipairs(out) do t.eq(h.at, "park") end
  end
end

-- гуляки в местности trs на 50 seed: check(h) каждому в парке -> сколько гуляли в парке
local function park_walkers(tr, check)
  local walkers = {}
  for k = 1, 6 do walkers[k] = { name = "Гуляка " .. k, role = "villain", day = "street", night = "street" } end
  local n = 0
  for seed = 1, 50 do
    for _, h in ipairs(cast.place(walkers, tr, WEEKDAY_NOON, seed, SCREEN)) do
      if h.at == "park" then
        n = n + 1
        check(h)
      end
    end
  end
  return n
end

-- ревью пачки 6: парк больше поля (местность берёт его, если он лишь задевает поле) — все точки прогулки в поле
function T.test_big_park_walk_points_in_field()
  local tr = field({ rect(-3000, -3000, 2 * W + 3000, 2 * H + 3000, "park") }, {})
  local n = park_walkers(tr, function(h)
    t.ok(h.x >= 0 and h.x <= 2 * W and h.y >= 0 and h.y <= 2 * H, "точка прогулки в поле: " .. h.x .. "," .. h.y)
  end)
  t.ok(n >= 100, "гуляют в большом парке: " .. n)
end

-- ревью пачки 6: лавка в парке — гуляющий в парке не стоит внутри неё (на её кромке — можно: «внутри» строго, как
-- у мест героев в зданиях)
function T.test_park_walk_not_inside_building()
  local tr = field({ rect(500, 600, 1100, 1300, "park"), rect(600, 700, 1000, 1200, "shop") }, {})
  local n = park_walkers(tr, function(h)
    t.ok(not (h.x > 600 and h.x < 1000 and h.y > 700 and h.y < 1200), "не внутри лавки: " .. h.x .. "," .. h.y)
  end)
  t.ok(n >= 100, "гуляют в парке вокруг лавки: " .. n)
end

-- кандидатов в запас больше трёх (ночь, все дома за экраном, только один сторож на улице через экран):
-- в запасе не больше трёх
function T.test_review_reserve_capped()
  local houses = {}
  for k = 0, 9 do houses[#houses + 1] = rect(20 + k * 60, 40, 50 + k * 60, 70, "house") end
  local tr = field(houses, { { 0, H, 2 * W, H } })
  local list = {}
  for k = 1, 9 do list[k] = { name = "Житель " .. k, role = "townsfolk", day = "home", night = "home" } end
  list[10] = { name = "Сторож", role = "guard", day = "street", night = "street" }
  local most = 0
  for seed = 1, 60 do
    local out = cast.place(list, tr, NIGHT, seed, MID)
    local res = #out - visible_in(out, MID)
    t.ok(res <= 3, "в запасе " .. res)
    most = math.max(most, res)
  end
  t.eq(most, 3, "запас заполнялся до предела")
end

-- первый уличный — на экран: из двух бандитов-«улица» оба на экране чаще, чем в трети открытий
function T.test_review_first_street_on_screen()
  local list = { { name = "Бандит", role = "villain", day = "street", night = "street" },
                 { name = "Злодей", role = "villain", day = "street", night = "street" } }
  local both = 0
  for seed = 1, 300 do
    local out = cast.place(list, town(), WEEKDAY_NOON, seed, SCREEN)
    t.ok(cast.on_screen(SCREEN, out[1].x, out[1].y), "первый — на экране")
    if visible_in(out, SCREEN) == 2 then both = both + 1 end
  end
  t.ok(both > 150, "оба на экране в " .. both .. " из 300")
end

-- здание Г-образное: рамка шире и выше контура, середина рамки лежит в вырезе. Герой дома — строго внутри контура
-- (не на кромке и не в вырезе), у каждого имени
function T.test_non_convex_home_hero_stands_inside_the_outline()
  -- Г: верхняя полка 700..800 × 700..730 и левая ножка 700..730 × 700..800; вырез — x > 730, y > 730
  local L = { kind = "house", pts = { 700, 700, 800, 700, 800, 730, 730, 730, 730, 800, 700, 800, 700, 700 } }
  local function strictly_in_L(x, y)
    return (x > 700 and x < 800 and y > 700 and y < 730) or (x > 700 and x < 730 and y > 700 and y < 800)
  end
  local tr = field({ L }, {})
  local list = {}
  for k = 1, 40 do list[k] = { name = "Герой " .. k, role = "student", day = "school", night = "home" } end
  local seen, outside = 0, {}
  each_seed(tr, NIGHT, 30, function(h, row, seed)
    t.eq(h.at, "home", h.name .. " ночью дома")
    seen = seen + 1
    if not strictly_in_L(h.x, h.y) then outside[#outside + 1] = h.name .. " " .. h.x .. "," .. h.y end
  end, list)
  t.ok(seen > 0, "герои расставлены")
  t.eq(#outside, 0, "вне контура Г: " .. table.concat(outside, "; "))
  -- один герой — одна точка при каждом открытии
  local a = cast.place(list, tr, NIGHT, 1, SCREEN)
  local b = cast.place(list, tr, NIGHT, 1, SCREEN)
  t.eq(a[1].x, b[1].x)
  t.eq(a[1].y, b[1].y)
end

-- точка героя в здании сверяется с независимой проверкой «строго внутри» (in_poly, своя у каждой фигуры): сдвинутую по
-- имени точку даёт тот же прямоугольник с той же рамкой (там она всегда внутри). Лежит строго внутри — герой стоит ровно
-- в ней; на кромке, в вершине или в вырезе — герой в ближайшей к ней строго внутренней точке сетки рамки 20 × 20
local function check_spot(pts, in_poly, what)
  local x0, y0, x1, y1 = pts[1], pts[2], pts[1], pts[2]
  for i = 1, #pts - 1, 2 do
    x0, x1 = math.min(x0, pts[i]), math.max(x1, pts[i])
    y0, y1 = math.min(y0, pts[i + 1]), math.max(y1, pts[i + 1])
  end
  local box = { kind = "house", pts = { x0, y0, x1, y0, x1, y1, x0, y1, x0, y0 } }
  local shape = { kind = "house", pts = pts }
  local function where(b, name)
    local out = cast.place({ { name = name, role = "student", day = "school", night = "home" } },
      field({ b }, {}), NIGHT, 1, SCREEN)
    t.eq(#out, 1, what .. ": " .. name .. " расставлен")
    return out[1].x, out[1].y
  end
  local moved = 0
  for k = 1, 100 do
    local name = "Герой " .. k
    local sx, sy = where(box, name)
    local x, y = where(shape, name)
    if in_poly(sx, sy) then
      t.ok(x == sx and y == sy, string.format("%s: %s внутри в %d,%d, а стоит в %d,%d", what, name, sx, sy, x, y))
    else
      moved = moved + 1
      t.ok(in_poly(x, y), string.format("%s: %s из %d,%d (не внутри) стоит в %d,%d — не внутри", what, name, sx, sy, x, y))
      local best = math.huge
      for i = 1, 19 do
        for j = 1, 19 do
          local gx, gy = terrain_round(x0 + (x1 - x0) * i / 20), terrain_round(y0 + (y1 - y0) * j / 20)
          if in_poly(gx, gy) then best = math.min(best, (gx - sx) ^ 2 + (gy - sy) ^ 2) end
        end
      end
      t.eq((x - sx) ^ 2 + (y - sy) ^ 2, best, string.format("%s: %s — не ближайшая внутренняя точка", what, name))
    end
  end
  return moved
end

-- ромб 600 × 600: точки сдвига на кромке (100,200 и ещё три), луч по y = 300 проходит через вершину
function T.test_spot_in_diamond_edge_and_vertex_ray()
  local X, Y = 450, 700
  local pts = { X + 300, Y, X + 600, Y + 300, X + 300, Y + 600, X, Y + 300, X + 300, Y }
  local function in_poly(x, y) return math.abs(x - (X + 300)) + math.abs(y - (Y + 300)) < 300 end
  t.ok(check_spot(pts, in_poly, "ромб") > 0, "часть героев сдвинута с кромки")
end

-- П: вершины (200,200) и (400,200) — точки сдвига, ребро y = 200 горизонтально и лежит на луче, вырез снизу
function T.test_spot_in_arch_vertex_horizontal_edge_notch()
  local X, Y = 450, 700
  local pts = { X, Y, X + 600, Y, X + 600, Y + 600, X + 400, Y + 600, X + 400, Y + 200, X + 200, Y + 200,
                X + 200, Y + 600, X, Y + 600, X, Y }
  local function in_poly(x, y)
    local dx, dy = x - X, y - Y
    return dx > 0 and dx < 600 and dy > 0 and dy < 600 and not (dx >= 200 and dx <= 400 and dy >= 200)
  end
  t.ok(check_spot(pts, in_poly, "П") > 0, "часть героев сдвинута с кромки и из выреза")
end

-- запас полон (3 в запасе за экраном): герой, чьё первое место — за экраном, берёт другое своё разрешённое место
-- на экране (улицу), а не выпадает. Число героев то же, что на местности без запаса (там все дома и улица на экране)
function T.test_full_reserve_hero_takes_other_allowed_place()
  -- в выходной (школы нет) шесть «Гуляк» свободны: улица и дом, что первым — бросок; у каждого есть место на экране
  local list = {}
  for k = 1, 6 do list[k] = { name = "Гуляка " .. k, role = "townsfolk", day = "school", night = "home" } end
  local far = {}
  for k = 0, 9 do far[#far + 1] = rect(20 + k * 60, 40, 50 + k * 60, 70, "house") end -- все дома за экраном
  local hard = field(far, { { 0, H, 2 * W, H } })
  local easy = field({ rect(900, 700, 930, 730, "house") }, { { 0, H, 2 * W, H } }) -- дом на экране
  local drops = 0
  for seed = 1, 60 do
    local want = #cast.place(list, easy, SATURDAY_NOON, seed, SCREEN)
    local out = cast.place(list, hard, SATURDAY_NOON, seed, SCREEN)
    if #out < want then drops = drops + 1 end
    t.ok(#out - visible_in(out, SCREEN) <= cast.RESERVE_MAX, "запас не больше предела")
  end
  t.eq(drops, 0, "открытий, где герой выпал при полном запасе: " .. drops)
end

-- срез 8: следы движутся — cast.step(state, terrain, dt) -> state, moved (чистая: прежнее состояние не меняется)

local STEP_S = 2.5 -- CFG.map_step_s

-- точка (x, y) лежит на какой-нибудь улице местности (до eps px, по умолчанию полпикселя)
local function on_street(tr, x, y, eps)
  eps = eps or 0.5
  for _, s in ipairs(tr.streets) do
    for i = 1, #s - 2, 2 do
      local x0, y0, x1, y1 = s[i], s[i + 1], s[i + 2], s[i + 3]
      local dx, dy = x1 - x0, y1 - y0
      local l2 = dx * dx + dy * dy
      local k = l2 > 0 and math.max(0, math.min(1, ((x - x0) * dx + (y - y0) * dy) / l2)) or 0
      if (x - x0 - k * dx) ^ 2 + (y - y0 - k * dy) ^ 2 <= eps * eps then return true end
    end
  end
  return false
end

local function walker(name, x, y) return { name = name, x = x, y = y, at = "street" } end

-- уличный идёт вдоль своей улицы на 20–40 px за шаг; в здании — на месте; прежнее состояние не тронуто
function T.test_step_moves_along_street()
  local tr = town()
  local state = { heroes = { walker("Бандит", W, H + 0), { name = "Гарри", x = 715, y = 720, at = "school" } },
                  screen = SCREEN, trail = 4 }
  for k = 1, 10 do
    local before = state.heroes[1]
    local bx, by = before.x, before.y
    local nxt, moved = cast.step(state, tr, STEP_S)
    t.eq(moved, 1, "двигается один уличный")
    t.eq(before.x, bx, "шаг не меняет прежнее состояние")
    local h = nxt.heroes[1]
    local d = math.abs(h.x - bx)
    t.ok(d >= 20 and d <= 40, "шаг " .. k .. ": " .. d .. " px вдоль улицы")
    t.eq(h.y, H, "по своей улице (запад-восток)")
    t.ok(on_street(tr, h.x, h.y), "на улице")
    t.eq(h.at, "street")
    local g = nxt.heroes[2]
    t.eq(g.x, 715, "в школе — на месте")
    t.eq(g.y, 720)
    t.eq(g.at, "school")
    state = nxt
  end
end

-- из запаса — к экрану: на развилке поворачивает к нему, за 20 шагов хотя бы один из запаса на экране
function T.test_step_reserve_enters_screen()
  local tr = field({}, { { 0, 300, W, 300, 2 * W, 300 }, { W, 0, W, 300, W, H, W, 2 * H }, { 0, H, W, H, 2 * W, H } })
  local state = { heroes = { walker("Бандит 1", W - 100, 300), walker("Бандит 2", 200, 300), walker("Бандит 3", W, 100) },
                  screen = SCREEN, trail = 4 }
  for _, h in ipairs(state.heroes) do t.ok(not on_screen(h), h.name .. " в запасе") end
  local entered, turned = false, false
  for _ = 1, 20 do
    state = cast.step(state, tr, STEP_S)
    for _, h in ipairs(state.heroes) do
      t.ok(on_street(tr, h.x, h.y), h.name .. " на улице")
      if on_screen(h) then entered = true end
    end
    local h1 = state.heroes[1]
    if h1.y > 300 then
      t.eq(h1.x, W, "на развилке — вниз, к экрану, не на восток")
      turned = true
    end
    t.ok(h1.x <= W, "Бандит 1 не уходит на восток")
  end
  t.ok(turned, "Бандит 1 повернул к экрану")
  t.ok(entered, "за 20 шагов хотя бы один из запаса на экране")
end

-- уличный в запасе в петле улиц под экраном: выход к экрану — только с нижнего угла петли на запад, от середины экрана
-- (жадный шаг «ближе к середине по прямой» кружил по петле вечно). Идёт по дали по сети: откуда бы на петле ни начал,
-- за 150 шагов на экране, всё время на улице (Notion 41a13e60-bc8d-81c0-9850)
function T.test_step_reserve_leaves_street_loop()
  local tr = field({}, { { 758, 1536, 1137, 1536, 1137, 2048, 758, 2048, 758, 1536 },
                         { 758, 2048, 379, 2048, 379, 1200, 600, 1200 } })
  local starts = { { 1137, 1800 }, { 950, 1536 }, { 950, 2048 }, { 758, 1700 }, { 1137, 1600 } }
  for _, p in ipairs(starts) do
    local state = { heroes = { walker("Бандит", p[1], p[2]) }, screen = SCREEN, trail = 4 }
    t.ok(not on_screen(state.heroes[1]), p[1] .. "," .. p[2] .. " в запасе")
    local came
    for s = 1, 150 do
      state = cast.step(state, tr, STEP_S)
      local h = state.heroes[1]
      t.ok(on_street(tr, h.x, h.y, 1), "шаг " .. s .. ": на улице " .. h.x .. "," .. h.y)
      if on_screen(h) then came = s break end
    end
    t.ok(came, "из " .. p[1] .. "," .. p[2] .. " за 150 шагов на экране")
  end
end

-- тупиковый кончик улицы в 1 px над нижней кромкой экрана — единственная точка прогулки этой улицы на экране. Уличный из
-- запаса доходит до кончика посреди шага; разворот в тупике увёл бы его обратно за экран, и так каждый шаг (ревью
-- e15236b: 6 застрявших). Шаг кончается на кончике: откуда бы ни начал, за 40 шагов на экране, всё время на улице
-- (Notion 41a13e60-bc8d-81c3)
function T.test_step_reserve_stops_at_dead_end_tip_on_edge()
  local tip = SCREEN[4] - 1
  local tr = field({}, { { 758, tip, 758, 2000 } })
  t.ok(cast.on_screen(SCREEN, 758, tip) and not cast.on_screen(SCREEN, 758, tip + 2), "на экране — только кончик")
  for _, name in ipairs({ "Бандит", "Гуляка", "Сторож" }) do
    for y = tip + 5, tip + 165, 8 do
      local state = { heroes = { walker(name, 758, y) }, screen = SCREEN, trail = 4 }
      local came
      for s = 1, 40 do
        state = cast.step(state, tr, STEP_S)
        local h = state.heroes[1]
        t.ok(on_street(tr, h.x, h.y, 1), "шаг " .. s .. ": на улице " .. h.x .. "," .. h.y)
        if on_screen(h) then came = s break end
      end
      t.ok(came, name .. " из 758," .. y .. " за 40 шагов на экране")
    end
  end
end

-- остановка в тупике — только у героя из запаса и только в тупике на экране. Тупик за экраном у героя из запаса и тупик
-- на экране у героя на экране — разворот, шаг целиком: за 10 px до тупика при шаге 20–40 px кончает шаг на 10–30 px
-- обратно, не в тупике (Notion 41a13e60-bc8d-81c3)
function T.test_step_turns_at_dead_end_off_screen_or_when_on_screen()
  local below = field({}, { { 758, 1000, 758, 1900 } })
  t.ok(not cast.on_screen(SCREEN, 758, 1890), "тупик 758,1900 и герой — за экраном")
  local h = cast.step({ heroes = { { name = "Бандит", x = 758, y = 1890, at = "street", way = { 1, 1, 1 } } },
                        screen = SCREEN, trail = 4 }, below, STEP_S).heroes[1]
  t.eq(h.x, 758)
  t.ok(h.y >= 1870 and h.y <= 1890, "из запаса в тупике за экраном — разворот: " .. h.y)
  local inside = field({}, { { 758, 1000, 758, 600 } })
  t.ok(cast.on_screen(SCREEN, 758, 600), "тупик 758,600 и герой — на экране")
  h = cast.step({ heroes = { { name = "Бандит", x = 758, y = 610, at = "street", way = { 1, 1, 1 } } },
                  screen = SCREEN, trail = 4 }, inside, STEP_S).heroes[1]
  t.eq(h.x, 758)
  t.ok(h.y >= 610 and h.y <= 630, "на экране в тупике — разворот: " .. h.y)
end

-- остановка — только в тупике: узел с далью 0 (точка прогулки на экране), который не тупик, герой из запаса проходит
-- насквозь. Узел (758, 1500) — начало второго отрезка, точка прогулки на экране (кромка экрана y = 1506), дальше улица
-- идёт на север. Герой за 10 px до узла, снизу, за экраном: шаг 20–40 px — минует узел и кончает шаг дальше по улице
-- (мутант: стоп в любом узле с далью 0 — кончил бы ровно в узле) (Notion 41a13e60-bc8d-818b)
function T.test_step_reserve_passes_through_zero_far_node_that_is_not_dead_end()
  local tr = field({}, { { 758, 2000, 758, 1500, 758, 1000 } })
  t.ok(cast.on_screen(SCREEN, 758, 1500) and not cast.on_screen(SCREEN, 758, 1510), "узел на экране, герой — за ним")
  for _, name in ipairs({ "Бандит", "Гуляка", "Сторож" }) do
    local h = cast.step({ heroes = { { name = name, x = 758, y = 1510, at = "street", way = { 1, 1, 1 } } },
                          screen = SCREEN, trail = 4 }, tr, STEP_S).heroes[1]
    t.eq(h.x, 758, name .. ": по своей улице")
    t.ok(h.y < 1500, name .. ": прошёл узел с далью 0, не встал в нём: " .. h.y)
    t.ok(h.y >= 1469, name .. ": шаг 20–40 px: " .. h.y)
  end
end

-- остановка — только при дали 0: тупик с малой ненулевой далью (последний отрезок 30 px, даль от кончика до точки
-- прогулки на экране — 30 px, ≤ 40) герой из запаса разворачивает, как любой тупик за экраном. Кончик (758, 1520) — за
-- экраном (кромка y = 1506); герой за 10 px до него, лицом к тупику. Шаг 20–40 px: развернулся, кончил шаг на 10–30 px
-- обратно (мутант: стоп при дали ≤ 40 — кончил бы ровно на кончике) (Notion 41a13e60-bc8d-818b)
function T.test_step_reserve_turns_at_dead_end_with_small_nonzero_far()
  local tr = field({}, { { 758, 1000, 758, 1490, 758, 1520 } })
  t.ok(cast.on_screen(SCREEN, 758, 1490) and not cast.on_screen(SCREEN, 758, 1520), "точка прогулки — на экране, кончик — за ним")
  for _, name in ipairs({ "Бандит", "Гуляка", "Сторож" }) do
    local h = cast.step({ heroes = { { name = name, x = 758, y = 1510, at = "street", way = { 1, 3, 1 } } },
                          screen = SCREEN, trail = 4 }, tr, STEP_S).heroes[1]
    t.eq(h.x, 758, name .. ": по своей улице")
    t.ok(h.y <= 1510 and h.y >= 1490, name .. ": развернулся у тупика, не встал на кончике: " .. h.y)
  end
end

-- даль по сети — в пикселях, не в отрезках: от развилки J к экрану две дороги. Западная — прямо вниз, 150 px до экрана,
-- но из четырёх отрезков; восточная — два отрезка, но 340 + 445 px. Уличный из запаса сворачивает на короткую по px и
-- за 30 шагов на экране, на восточную не выходит (Notion 41a13e60-bc8d-81c0-9850, ревью e15236b, мутант M8)
function T.test_step_reserve_takes_shorter_road_in_px()
  local tr = field({}, { { 758, 100, 758, 400 }, { 758, 400, 758, 450, 758, 500, 758, 550, 758, 600 },
                         { 758, 400, 1100, 100, 1100, 545, 1100, 700 } })
  local state = { heroes = { walker("Бандит", 758, 200) }, screen = SCREEN, trail = 4 }
  t.ok(not on_screen(state.heroes[1]), "в запасе")
  local came
  for s = 1, 30 do
    state = cast.step(state, tr, STEP_S)
    local h = state.heroes[1]
    t.eq(h.x, 758, "шаг " .. s .. ": по короткой дороге, не на восточную " .. h.x .. "," .. h.y)
    if on_screen(h) then came = s break end
  end
  t.ok(came, "за 30 шагов на экране")
end

-- даль в парке у края экрана: точка экрана тянет за собой только себя, а не соседа по пути (ревью e15236b, мутант M10).
-- Гуляющий за левым краем экрана в узле (400, 640): восток (480, 640) — уже экран, север (400, 560) — тоже за краем
-- (сосед экрана слева). Первый шаг — на восток, на экран
function T.test_park_reserve_steps_onto_screen_not_along_edge()
  local tr = field({ rect(0, 0, 2 * W, 2 * H, "park") }, {})
  t.ok(not cast.on_screen(SCREEN, 400, 640) and not cast.on_screen(SCREEN, 400, 560), "узел и север — за экраном")
  t.ok(cast.on_screen(SCREEN, 480, 640), "восток — экран")
  local state = { heroes = { { name = "Гуляка", x = 400, y = 640, at = "park", park = 1 } }, screen = SCREEN, trail = 4 }
  local h = cast.step(state, tr, STEP_S).heroes[1]
  t.eq(h.y, 640, "на восток, не на север: " .. h.x .. "," .. h.y)
  t.ok(h.x > 400 and on_screen(h), "первым шагом на экране: " .. h.x .. "," .. h.y)
end

-- след: прежние точки — пара отпечатков на каждой; точка гаснет через trail шагов (на экране ≤ trail точек)
function T.test_trail_fades_after_n()
  local tr = town()
  local state = { heroes = { walker("Бандит", W, H) }, screen = SCREEN, trail = 4 }
  local path = { { W, H } }
  for k = 1, 6 do
    state = cast.step(state, tr, STEP_S)
    local h = state.heroes[1]
    path[#path + 1] = { h.x, h.y }
    t.ok(#h.trail <= 3, "текущая точка и не больше трёх прежних")
    t.eq(#h.trail, math.min(k, 3))
    -- прежние — последние точки пути до текущей, старшая первой
    for i, p in ipairs(h.trail) do
      local q = path[#path - #h.trail + i - 1]
      t.eq(p[1], q[1], "шаг " .. k .. ", след " .. i)
      t.eq(p[2], q[2])
    end
  end
  local h = state.heroes[1]
  for _, p in ipairs(h.trail) do t.ok(not (p[1] == W and p[2] == H), "первая точка погасла") end
end

-- шаг тем же распорядком: ночью школа не наполняется, домосед не выходит, уличные — по улицам
function T.test_step_keeps_schedule()
  local tr = town()
  for seed = 1, 20 do
    local placed = cast.place(MP.cast(), tr, NIGHT, seed, SCREEN)
    local state = { heroes = placed, screen = SCREEN, trail = 4 }
    for _ = 1, 10 do state = cast.step(state, tr, STEP_S) end
    for i, h in ipairs(state.heroes) do
      local p = placed[i]
      t.eq(h.name, p.name)
      t.eq(h.at, p.at, h.name .. " — там же, где ночью")
      t.ok(h.at ~= "school", "ночью в школе никого")
      if h.at == "street" then
        t.ok(on_street(tr, h.x, h.y), h.name .. " идёт по улице")
      else
        t.eq(h.x, p.x, h.name .. " не выходит")
        t.eq(h.y, p.y)
      end
    end
  end
end

-- улица без длины (одна точка) и тупик: шаг не зависает и не теряет героя
function T.test_step_dead_end_turns_back()
  local tr = field({}, { { 500, 800, 560, 800 }, { 700, 700, 700, 700 } })
  local state = { heroes = { walker("Бандит", 530, 800) }, screen = SCREEN, trail = 4 }
  local xs = {}
  for _ = 1, 8 do
    state = cast.step(state, tr, STEP_S)
    local h = state.heroes[1]
    t.ok(h.x >= 500 and h.x <= 560 and h.y == 800, "в пределах тупика: " .. h.x)
    t.ok(numbers(state.heroes), "координаты — числа")
    xs[#xs + 1] = h.x
  end
  t.ok(xs[1] ~= xs[2] or xs[2] ~= xs[3], "ходит туда-обратно")
end

-- ревью среза 8, п.1: фазз шага. Случайные местности (как в фаззе расстановки), расстановка cast.place и 30 шагов:
-- ни одного падения, координаты — числа в поле, шаг уличного — не дальше SPEED_MAX × dt по прямой и по улице, в
-- здании — на месте, след не длиннее trail − 1, прежнее состояние не тронуто (ревьюер: 1500 местностей × 30 шагов)
function T.test_review_fuzz_steps()
  local rnd = math.random
  math.randomseed(20261117)
  local KINDS = { "house", "house", "school", "shop", "park", "pub", false }
  local reach = cast.SPEED_MAX * STEP_S
  local walked = 0
  for i = 1, 1500 do
    local streets, buildings = {}, {}
    for _ = 1, rnd(0, 3) do
      local s = {}
      for _ = 1, rnd(2, 4) do s[#s + 1], s[#s + 2] = rnd(0, 2 * W), rnd(0, 2 * H) end
      streets[#streets + 1] = s
    end
    for _ = 1, rnd(0, 6) do
      local x, y = rnd(0, 2 * W - 40), rnd(0, 2 * H - 40)
      buildings[#buildings + 1] = rect(x, y, x + rnd(10, 40), y + rnd(10, 40), KINDS[rnd(#KINDS)] or nil)
    end
    local tr = field(buildings, streets)
    local list = {}
    for k = 1, rnd(1, 8) do
      list[k] = { name = "Герой " .. k, role = "guard",
                  day = ({ "school", "work", "street", "home" })[rnd(4)], night = ({ "home", "street" })[rnd(2)] }
    end
    local sx, sy = rnd(0, W), rnd(0, H)
    local screen = { sx, sy, sx + W - 12, sy + H - 12 }
    local tm = { hour = rnd(0, 23), wday = rnd(1, 7), month = rnd(1, 12) }
    local trail = rnd(1, 5)
    local state = { heroes = cast.place(list, tr, tm, rnd(1, 100000), screen), screen = screen, trail = trail }
    for k = 1, 30 do
      local before = {}
      for j, h in ipairs(state.heroes) do before[j] = { h.x, h.y } end
      local ok, nxt = pcall(cast.step, state, tr, STEP_S)
      local at = "прогон " .. i .. ", шаг " .. k
      if not ok then error(at .. ": " .. tostring(nxt)) end
      if not numbers(nxt.heroes) then error(at .. ": не числа") end
      if #nxt.heroes ~= #state.heroes then error(at .. ": героев " .. #nxt.heroes .. " вместо " .. #state.heroes) end
      for j, h in ipairs(nxt.heroes) do
        local b, o = before[j], state.heroes[j]
        if o.x ~= b[1] or o.y ~= b[2] then error(at .. ": прежнее состояние тронуто") end
        if h.x < 0 or h.x > 2 * W or h.y < 0 or h.y > 2 * H then error(at .. ": вне поля " .. h.x .. "," .. h.y) end
        local jump = math.sqrt((h.x - b[1]) ^ 2 + (h.y - b[2]) ^ 2)
        if h.at == "street" then
          if jump > reach + 1e-9 then error(at .. ": скачок " .. jump .. " px") end
          if jump > 0 then
            walked = walked + 1
            -- до 1 px: cast.place ставит уличного в округлённую точку улицы (до 0,7 px мимо линии, задача п.3), первый
            -- отрезок шага идёт от неё к узлу
            if not on_street(tr, h.x, h.y, 1) then error(at .. ": не на улице " .. h.x .. "," .. h.y) end
          end
        elseif jump ~= 0 then
          error(at .. ": " .. h.at .. " сдвинулся на " .. jump)
        end
        if #(h.trail or {}) > math.max(0, trail - 1) then error(at .. ": след " .. #h.trail) end
      end
      state = nxt
    end
  end
  t.ok(walked > 10000, "уличные действительно шагали: " .. walked)
end

-- Notion 41a13e60-bc8d-81cf: гуляющий в парке ходит по сетке парка тем же шагом, что уличный по улицам, и так выходит к
-- экрану. Случайные местности: 1–3 парка 100–600 px (в половине — лавка внутри), 0–2 улицы; шесть гуляк, 80 шагов.
-- Каждый в парке — строго внутри парка и в поле, не внутри лавки (и на пути между точками), шаг не дальше
-- SPEED_MAX × dt; кто стоял в парке за экраном, за 80 шагов выходит на экран (в часть парка, откуда экран не достать,
-- запасной не ставится)
function T.test_park_walkers_reach_screen()
  local rnd = math.random
  math.randomseed(20261118)
  local walkers = {}
  for k = 1, 6 do walkers[k] = { name = "Гуляка " .. k, role = "villain", day = "street", night = "street" } end
  local reach = cast.SPEED_MAX * STEP_S
  local off, came, moved = 0, 0, 0
  for i = 1, 300 do
    local parks, shops, streets = {}, {}, {}
    for _ = 1, rnd(1, 3) do
      local x, y = rnd(0, 2 * W - 200), rnd(0, 2 * H - 200)
      local p = rect(x, y, x + rnd(100, 600), y + rnd(100, 600), "park")
      parks[#parks + 1] = p
      if rnd(2) == 1 then
        local q = p.pts
        local sx, sy = rnd(q[1], q[3] - 60), rnd(q[2], q[6] - 60)
        shops[#shops + 1] = rect(sx, sy, sx + rnd(20, 60), sy + rnd(20, 60), "shop")
      end
    end
    for _ = 1, rnd(0, 2) do
      local s = {}
      for _ = 1, rnd(2, 4) do s[#s + 1], s[#s + 2] = rnd(0, 2 * W), rnd(0, 2 * H) end
      streets[#streets + 1] = s
    end
    local b = {}
    for _, p in ipairs(parks) do b[#b + 1] = p end
    for _, s in ipairs(shops) do b[#b + 1] = s end
    local tr = field(b, streets)
    local function in_park(x, y)
      for _, p in ipairs(parks) do
        local q = p.pts
        if x > q[1] and x < q[3] and y > q[2] and y < q[6] then return true end
      end
    end
    local function in_shop(x, y)
      for _, s in ipairs(shops) do
        local q = s.pts
        if x > q[1] and x < q[3] and y > q[2] and y < q[6] then return true end
      end
    end
    local state = { heroes = cast.place(walkers, tr, WEEKDAY_NOON, i, SCREEN), screen = SCREEN, trail = 4 }
    local waiting = {}
    for k, h in ipairs(state.heroes) do
      if h.at == "park" and not on_screen(h) then waiting[k], off = true, off + 1 end
    end
    for step = 1, 80 do
      local nxt = cast.step(state, tr, STEP_S)
      for k, h in ipairs(nxt.heroes) do
        if h.at == "park" then
          local o = state.heroes[k]
          local at = "местность " .. i .. ", шаг " .. step .. ", " .. h.name .. " " .. h.x .. "," .. h.y
          t.ok(in_park(h.x, h.y) and not in_shop(h.x, h.y), at .. ": в парке, не в лавке")
          -- путь от прежней точки (шаг короче PARK_STEP: прямо или через один узел сетки) — через каждый пиксель в
          -- парке и не в лавке
          local cx, cy = o.x, o.y
          if o.x ~= h.x and o.y ~= h.y then
            if o.x % cast.PARK_STEP == 0 and h.y % cast.PARK_STEP == 0 then cx, cy = o.x, h.y else cx, cy = h.x, o.y end
          end
          for _, leg in ipairs({ { o.x, o.y, cx, cy }, { cx, cy, h.x, h.y } }) do
            local len = math.max(math.abs(leg[3] - leg[1]), math.abs(leg[4] - leg[2]))
            for q = 0, math.ceil(len) do
              local f = len > 0 and q / math.ceil(len) or 0
              local x, y = leg[1] + (leg[3] - leg[1]) * f, leg[2] + (leg[4] - leg[2]) * f
              t.ok(in_park(x, y) and not in_shop(x, y), at .. ": путь в парке, не через лавку " .. x .. "," .. y)
            end
          end
          local jump = math.sqrt((h.x - o.x) ^ 2 + (h.y - o.y) ^ 2)
          t.ok(jump <= reach + 1e-9, at .. ": скачок " .. jump)
          if jump > 0 then moved = moved + 1 end
          if waiting[k] and on_screen(h) then waiting[k], came = nil, came + 1 end
        end
      end
      state = nxt
    end
    for k in pairs(waiting) do
      local h = state.heroes[k]
      error("местность " .. i .. ": " .. h.name .. " в парке за экраном 80 шагов, " .. h.x .. "," .. h.y)
    end
  end
  t.ok(off >= 50, "в парке за экраном ставились: " .. off)
  t.eq(came, off, "все из парка за экраном вышли на экран")
  t.ok(moved > 1000, "в парке шагали: " .. moved)
end

-- парк целиком за экраном, улиц нет: гулять, откуда экран не достать, некому — в этом парке никто не стоит
function T.test_park_off_screen_not_a_walk()
  local tr = field({ rect(20, 20, 300, 400, "park"), rect(450, 600, 480, 630, "house") }, {})
  for seed = 1, 30 do
    for _, h in ipairs(cast.place(STUDENTS, tr, SATURDAY_NOON, seed, SCREEN)) do
      t.ok(h.at ~= "park", "seed " .. seed .. ": " .. h.name .. " в парке за экраном")
    end
  end
end

-- ревью dac918e, Б1: точка сетки, у которой все пути закрыты (четыре киоска вокруг 720,960), — не место прогулки, пока
-- в парке есть пути: иначе первый шаг идёт к ближайшему пути по прямой, сквозь киоск
function T.test_park_point_without_paths_not_a_walk()
  local tr = field({ rect(450, 600, 1100, 1400, "park"), rect(700, 900, 740, 940, "shop"), rect(700, 980, 740, 1020, "shop"),
                     rect(660, 940, 700, 980, "shop"), rect(740, 940, 780, 980, "shop") }, {})
  local list = { { name = "Гуляка", role = "villain", day = "street", night = "street" } }
  local n = 0
  for seed = 1, 300 do
    for _, h in ipairs(cast.place(list, tr, WEEKDAY_NOON, seed, SCREEN)) do
      n = n + 1
      t.ok(not (h.x == 720 and h.y == 960), "seed " .. seed .. ": гуляка в точке без путей")
    end
  end
  t.eq(n, 300, "гуляет в парке")
end

-- шаги гуляк в парке tr (seed 1..seeds, steps шагов) -> за экраном при расстановке, не дошли до экрана; each(o, h) —
-- каждому шагу гуляющего в парке (прежний, новый)
local function park_run(tr, seeds, steps, each)
  local walkers = {}
  for k = 1, 6 do walkers[k] = { name = "Гуляка " .. k, role = "villain", day = "street", night = "street" } end
  local off, stuck = 0, 0
  for seed = 1, seeds do
    local st = { heroes = cast.place(walkers, tr, WEEKDAY_NOON, seed, SCREEN), screen = SCREEN, trail = 4 }
    local wait = {}
    for k, h in ipairs(st.heroes) do
      if h.at == "park" and not on_screen(h) then wait[k], off = true, off + 1 end
    end
    for _ = 1, steps do
      local nxt = cast.step(st, tr, STEP_S)
      for k, h in ipairs(nxt.heroes) do
        if h.at == "park" and each then each(st.heroes[k], h) end
        if wait[k] and on_screen(h) then wait[k] = nil end
      end
      st = nxt
    end
    for _ in pairs(wait) do stuck = stuck + 1 end
  end
  return off, stuck
end

-- ревью dac918e, Б2: Г-карман — верх парка над экраном, к экрану только коридор в один столбец сетки у края поля и
-- рукав на экран. Из запаса гуляющий идёт по путям парка к экрану (не «ближе к середине по прямой» — так он ходит вдоль
-- стены туда-обратно): за 200 шагов (8 мин) дошли все
function T.test_park_corridor_reaches_screen()
  local tr = field({ { kind = "park", pts = { 0, 0, 1516, 0, 1516, 500, 120, 500, 120, 900, 800, 900, 800, 1000, 0, 1000,
                                               0, 0 } } }, {})
  local off, stuck = park_run(tr, 40, 200)
  t.ok(off >= 40, "в парке за экраном ставились: " .. off)
  t.eq(stuck, 0, "все из запаса дошли до экрана")
end

-- ревью dac918e: невыпуклый парк — щель 750..770 сверху до y = 1000 между столбцами сетки 720 и 800: путь между точками
-- по обе стороны щели выходит из парка — его нет, гуляющий щель не пересекает (обходит снизу)
function T.test_park_slit_not_crossed()
  local tr = field({ { kind = "park", pts = { 450, 600, 750, 600, 750, 1000, 770, 1000, 770, 600, 1100, 600, 1100, 1400,
                                               450, 1400, 450, 600 } } }, {})
  local crossed = 0
  park_run(tr, 30, 60, function(o, h)
    if (o.x < 760) ~= (h.x < 760) and math.min(o.y, h.y) < 1000 then crossed = crossed + 1 end
    t.ok(not (h.x > 750 and h.x < 770 and h.y < 1000), "в щели: " .. h.x .. "," .. h.y)
  end)
  t.eq(crossed, 0, "через щель не ходят")
end

-- Notion 41a13e60-bc8d-8165: карту сдвинули пальцем — экран другой (cast.step(state, tr, dt, screen): state.screen —
-- экран, к которому шли, screen — экран сейчас). Экран SHIFTED — левее и выше SCREEN: восточная часть поля его не видит
local SHIFTED = { SCREEN[1] - 300, SCREEN[2] - 400, SCREEN[3] - 300, SCREEN[4] - 400 }

-- шаги героев heroes: первый — к экрану SCREEN (у гуляющего уже есть way), со второго экран SHIFTED (сдвиг перед вторым
-- шагом), steps шагов -> состояния по шагам { [0] = исходное, … }. still — эталон «не тронут»: экран SHIFTED со второго
-- шага подложен в state.screen, сдвига шаг не видит — все идут к SHIFTED, как шли бы без перестановки
local function shifted_run(tr, heroes, steps, still)
  local runs = { [0] = { heroes = heroes, screen = SCREEN, trail = 4 } }
  runs[1] = cast.step(runs[0], tr, STEP_S)
  for k = 2, steps do
    local st = runs[k - 1]
    if still then
      runs[k] = cast.step({ heroes = st.heroes, screen = SHIFTED, trail = st.trail, tick = st.tick }, tr, STEP_S)
    else
      runs[k] = cast.step(st, tr, STEP_S, SHIFTED)
    end
  end
  return runs
end

-- путь героя k по шагам runs: на экране SHIFTED он появляется только шагом (не дальше SPEED_MAX × dt от прежней
-- точки — телепорта внутрь экрана нет) -> номер шага, когда он впервые на экране | nil
local function enters_shifted(runs, k)
  local reach = cast.SPEED_MAX * STEP_S
  for s = 1, #runs do
    local o, h = runs[s - 1].heroes[k], runs[s].heroes[k]
    local now, was = cast.on_screen(SHIFTED, h.x, h.y), cast.on_screen(SHIFTED, o.x, o.y)
    if now and not h.gone then
      if not was then
        local jump = math.sqrt((h.x - o.x) ^ 2 + (h.y - o.y) ^ 2)
        t.ok(jump <= reach + 1e-9, h.name .. ": на экран шагом, не скачком: " .. jump .. " px на шаге " .. s)
      end
      return s
    end
  end
end

-- путь героя k по шагам runs -> «x,y;…» (сверка «не тронут»)
local function path_of(runs, k)
  local out = {}
  for s = 0, #runs do
    local h = runs[s].heroes[k]
    local tr = {}
    for _, p in ipairs(h.trail or {}) do tr[#tr + 1] = p[1] .. "," .. p[2] end
    out[#out + 1] = h.x .. "," .. h.y .. "[" .. table.concat(tr, " ") .. "]"
  end
  return table.concat(out, ";")
end

-- уличный на улице, что новый экран не видит (несвязна с улицей через экран): переставлен в запас на улицу, откуда
-- экран достижим (прежний путь way — на старой улице — забыт: дальше идёт по новой), и за 60 шагов на экране; на экран
-- выходит шагом, всё время на улице. Уличный за экраном на улице через экран — не тронут: путь и следы те же, что без
-- перестановки (эталон still)
function T.test_shift_street_hero_reseated_to_reach()
  local tr = field({}, { { 0, 300, 2 * W, 300 }, { 1200, 1700, 1500, 1700 } })
  local heroes = { walker("Бандит 1", 1300, 300), walker("Бандит 2", 1300, 1700) }
  local runs = shifted_run(tr, heroes, 60)
  t.ok(runs[1].heroes[2].way, "до сдвига Бандит 2 шёл по своей улице")
  t.ok(not cast.on_screen(SHIFTED, 1300, 1700), "Бандит 2 за новым экраном")
  t.ok(not cast.on_screen(SHIFTED, 1300, 300), "Бандит 1 тоже за новым экраном")
  local came = enters_shifted(runs, 2)
  t.ok(came, "Бандит 2 за 60 шагов на экране")
  local first = runs[2].heroes[2]
  t.eq(first.y, 300, "переставлен на улицу через экран")
  t.ok(not cast.on_screen(SHIFTED, first.x, first.y), "переставлен за край экрана, не на экран")
  for s = 1, 60 do
    local h = runs[s].heroes[2]
    t.ok(on_street(tr, h.x, h.y, 1), "шаг " .. s .. ": Бандит 2 на улице " .. h.x .. "," .. h.y)
    t.ok(not h.gone, "шаг " .. s .. ": Бандит 2 не ушёл — ему есть откуда выйти")
  end
  t.eq(path_of(runs, 1), path_of(shifted_run(tr, heroes, 60, true), 1), "Бандит 1 не тронут")
end

-- парк разрезан лавкой во всю высоту: восточная часть нового экрана не видит. Гуляющий в ней переставлен в западную
-- часть того же парка, в запас (прежний way забыт), и за 120 шагов на экране; гуляющий за экраном в западной части не
-- тронут (эталон still)
function T.test_shift_park_walker_reseated_in_own_park()
  local tr = field({ rect(0, 0, 2 * W, 2 * H, "park"), rect(900, 0, 1000, 2 * H, "shop") }, {})
  local function gul(name, x, y) return { name = name, x = x, y = y, at = "park", park = 1 } end
  local heroes = { gul("Гуляка 1", 400, 1600), gul("Гуляка 2", 1200, 1600) }
  local runs = shifted_run(tr, heroes, 120)
  t.ok(runs[1].heroes[2].way, "до сдвига Гуляка 2 шёл по путям парка")
  t.ok(not cast.on_screen(SHIFTED, 400, 1600), "Гуляка 1 за новым экраном")
  local came = enters_shifted(runs, 2)
  t.ok(came, "Гуляка 2 за 120 шагов на экране")
  local first = runs[2].heroes[2]
  t.ok(not cast.on_screen(SHIFTED, first.x, first.y), "переставлен за край экрана, не на экран")
  for s = 2, 120 do
    local h = runs[s].heroes[2]
    t.ok(h.x > 0 and h.x < 900 and h.y > 0 and h.y < 2 * H, "шаг " .. s .. ": в западной части парка " .. h.x .. "," .. h.y)
    t.eq(h.at, "park")
    t.eq(h.park, 1, "в своём парке")
  end
  t.eq(path_of(runs, 1), path_of(shifted_run(tr, heroes, 120, true), 1), "Гуляка 1 не тронут")
end

-- перестановка — никогда не на экран: бросок точки запаса зависит от tick, поэтому тот же сдвиг повторён на 200 tick
-- (разные броски). Каждый раз переставленный за экраном и в части сети, откуда экран достижим; точек набралось много
-- (бросок действительно разный), ни одна не на экране — правило, а не удача одного броска
function T.test_shift_reseat_never_on_screen()
  local street = field({}, { { 0, 300, 2 * W, 300 }, { 1200, 1700, 1500, 1700 } })
  local park = field({ rect(0, 0, 2 * W, 2 * H, "park"), rect(900, 0, 1000, 2 * H, "shop") }, {})
  local cases = {
    { tr = street, h = walker("Бандит", 1300, 1700), ok = function(x, y) return y == 300 end },
    { tr = park, h = { name = "Гуляка", x = 1200, y = 1600, at = "park", park = 1 },
      ok = function(x, y) return x > 0 and x < 900 and y > 0 and y < 2 * H end },
  }
  for _, c in ipairs(cases) do
    local seen, n = {}, 0
    for tick = 0, 199 do
      local r = cast.step({ heroes = { c.h }, screen = SCREEN, trail = 4, tick = tick }, c.tr, STEP_S, SHIFTED).heroes[1]
      local at = c.h.name .. ", tick " .. tick .. ": " .. r.x .. "," .. r.y
      t.ok(not r.gone, at .. " — не ушёл")
      t.ok(not cast.on_screen(SHIFTED, r.x, r.y), at .. " — переставлен не на экран")
      t.ok(c.ok(r.x, r.y), at .. " — в части сети, откуда экран достижим")
      local key = r.x .. "," .. r.y
      if not seen[key] then seen[key], n = true, n + 1 end
    end
    t.ok(n >= 10, c.h.name .. ": точек перестановки разных " .. n)
  end
end

-- новый экран не достать ниоткуда из сети героя (парк и улица целиком к востоку от него): герой уходит с поля — стоит,
-- след гаснет по точке за шаг, текущая точка уходит в след (тоже гаснет); экран вернулся — не возвращается
function T.test_shift_unreachable_hero_leaves()
  local tr = field({ rect(1000, 1400, 1500, 2000, "park") }, { { 1000, 1300, 1500, 1300 } })
  local st = { heroes = { { name = "Гуляка", x = 1200, y = 1600, at = "park", park = 1 }, walker("Бандит", 1300, 1300),
                          { name = "Гарри", x = 1050, y = 1500, at = "house" } }, screen = SCREEN, trail = 4 }
  for _ = 1, 3 do st = cast.step(st, tr, STEP_S) end
  local before = st.heroes
  for i = 1, 2 do t.eq(#before[i].trail, 3, before[i].name .. ": след до сдвига") end
  local gone, moved = cast.step(st, tr, STEP_S, SHIFTED)
  t.eq(moved, 2, "у обоих ушедших изменились следы")
  for i = 1, 2 do
    local h, o = gone.heroes[i], before[i]
    t.ok(h.gone, h.name .. " ушёл с поля")
    t.ok(h.x == o.x and h.y == o.y, h.name .. " не двигается")
    t.eq(#h.trail, 3, h.name .. ": текущая точка ушла в след, старшая погасла")
    t.eq(h.trail[3][1], o.x)
    t.eq(h.trail[3][2], o.y)
  end
  t.ok(not gone.heroes[3].gone, "в доме — не уходит")
  st = gone
  for k = 1, 3 do
    st = cast.step(st, tr, STEP_S, k == 3 and SCREEN or SHIFTED)
    for i = 1, 2 do t.eq(#st.heroes[i].trail, 3 - k, st.heroes[i].name .. ": след гаснет, шаг " .. k) end
  end
  for _ = 1, 10 do
    st = cast.step(st, tr, STEP_S)
    for i = 1, 2 do
      local h = st.heroes[i]
      t.ok(h.gone and h.x == before[i].x and h.y == before[i].y, h.name .. ": экран вернулся — не возвращается")
    end
  end
end

t.run(T)
