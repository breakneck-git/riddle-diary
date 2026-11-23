-- Герои карты мародёров (план карты, раздел 2 «Герои», срез 7): где кто из состава раздела map.cast стоит сейчас.
-- Чистые функции без сети, файлов и часов: время приходит снаружи (os.date("*t") у вида карты), местность — сжатая
-- (riddle.terrain), координаты — пиксели поля. Шаг движения (cast.step, срез 8) берёт результат cast.place как
-- состояние.
local terrain = require("riddle.terrain")

local cast = {}

cast.NIGHT_FROM, cast.NIGHT_TO = 22, 6   -- ночь: с 22:00 до 6:00
cast.SCHOOL_FROM, cast.SCHOOL_TO = 8, 15 -- уроки: с 8:00 до 15:00 в будни, кроме каникул
cast.MIN, cast.MAX = 2, 6                -- героев на карте (меньше — если меньше в составе)
cast.RESERVE_MAX = 3                     -- героев в запасе поля (за экраном)
cast.STREET_STEP = 40                    -- точки улиц, где может стоять герой, — через столько пикселей

local M31 = 2147483647 -- 2^31 − 1: хеш и генератор считают точно в числах Lua (double)

-- хеш строки: тот же на Mac и на Kindle
local function hash(s)
  local h = 7
  for i = 1, #s do h = (h * 31 + s:byte(i)) % M31 end
  return h
end

-- генератор Парка — Миллера от seed -> r(n): целое 1..n
local function rng(seed)
  local s = math.floor(seed) % (M31 - 1) + 1
  return function(n)
    s = s * 16807 % M31
    return s % n + 1
  end
end

-- t = os.date("*t") (hour, wday: 1 — воскресенье … 7 — суббота, month) -> { night, school_day, weekend, winter }
function cast.clock(t)
  local h, m = t.hour, t.month
  local weekend = t.wday == 1 or t.wday == 7
  local summer = m >= 6 and m <= 8 -- каникулы
  return {
    night = h >= cast.NIGHT_FROM or h < cast.NIGHT_TO,
    weekend = weekend,
    winter = m == 12 or m <= 2,
    school_day = not weekend and not summer and h >= cast.SCHOOL_FROM and h < cast.SCHOOL_TO,
  }
end

-- здания местности по назначению -> { school = {i…}, work = {i…}, homes = {i…}, parks = {i…} } (индексы
-- terrain.buildings). Жилые — дома (kind house); их нет — здания без типа. Парк — место прогулок, не работы (владелец
-- 2026-11-16). Работа — не-жилое здание с типом: любое, кроме дома, школы и парка
local function sites(tr)
  local s = { school = {}, work = {}, homes = {}, parks = {} }
  local untyped = {}
  for i, b in ipairs(tr.buildings) do
    local k = b.kind
    local list = k == "house" and s.homes or k == "school" and s.school or k == "park" and s.parks
      or k and s.work or untyped
    list[#list + 1] = i
  end
  if #s.homes == 0 then s.homes = untyped end
  return s
end

-- дом героя: жилое здание местности по хешу имени — тот же между открытиями, пока местность та же -> индекс | nil
function cast.home(name, tr)
  local homes = sites(tr).homes
  if #homes == 0 then return nil end
  return homes[hash(name) % #homes + 1]
end

-- куда герою можно сейчас, в порядке его предпочтения: { "school" | "work" | "street" | "home", … } (по распорядку;
-- r — генератор открытия)
local function wants(h, c, r)
  if c.night then return { h.night == "street" and "street" or "home" } end
  -- без дела (каникулы, выходной, до и после уроков): на улице или дома, что первым — бросок; зимой — только дома
  local function free()
    if c.winter then return { "home" } end
    if r(2) == 1 then return { "street", "home" } end
    return { "home", "street" }
  end
  if h.day == "school" then return c.school_day and { "school" } or free() end
  if h.day == "work" then return c.weekend and free() or { "work" } end
  if h.day == "street" then return { "street" } end
  return { "home" }
end

-- нужного места в местности нет — следующее по списку
local FALLBACK = { school = { "school", "street", "home" }, work = { "work", "street", "home" },
                   street = { "street", "home", "work" }, home = { "home", "street", "work" } }

-- точка (x, y) в видимой части поля screen = { x0, y0, x1, y1 } — единственное «на экране» героев (cast.place и вид карты)
function cast.on_screen(screen, x, y)
  return x >= screen[1] and x <= screen[3] and y >= screen[2] and y <= screen[4]
end

-- (x, y) строго внутри контура pts (плоский список, замкнутый повтором первой точки или нет): на кромке — нет
local function strictly_inside(pts, x, y)
  local n = #pts
  if n >= 4 and pts[n - 1] == pts[1] and pts[n] == pts[2] then n = n - 2 end
  local inside, j = false, n - 1
  for i = 1, n - 1, 2 do
    local xi, yi, xj, yj = pts[i], pts[i + 1], pts[j], pts[j + 1]
    if (x - xi) * (yj - yi) == (y - yi) * (xj - xi)
        and x >= math.min(xi, xj) and x <= math.max(xi, xj) and y >= math.min(yi, yj) and y <= math.max(yi, yj) then
      return false
    end
    if (yi > y) ~= (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi then inside = not inside end
    j = i
  end
  return inside
end

local SPOT_GRID = 20 -- запасная точка: сетка рамки SPOT_GRID × SPOT_GRID

-- точка героя в здании: середина контура, сдвинутая по хешу имени на треть полуширины (двое в одном здании —
-- обычно в разных местах; один и тот же герой — всегда в одном). Невыпуклый контур (Г, П): середина или сдвиг
-- могут лечь в вырез — тогда ближайшая к ним строго внутренняя точка сетки рамки (контур без внутренности — как есть)
local function spot_in(b, name)
  local x0, y0, x1, y1 = terrain.bounds(b.pts)
  local hs = hash(name)
  local sx = terrain.round((x0 + x1) / 2 + (hs % 5 - 2) * (x1 - x0) / 6)
  local sy = terrain.round((y0 + y1) / 2 + (math.floor(hs / 5) % 3 - 1) * (y1 - y0) / 6)
  if strictly_inside(b.pts, sx, sy) then return sx, sy end
  local bx, by, bd = sx, sy, math.huge
  for i = 1, SPOT_GRID - 1 do
    for k = 1, SPOT_GRID - 1 do
      local x, y = terrain.round(x0 + (x1 - x0) * i / SPOT_GRID), terrain.round(y0 + (y1 - y0) * k / SPOT_GRID)
      local d = (x - sx) ^ 2 + (y - sy) ^ 2
      if d < bd and strictly_inside(b.pts, x, y) then bx, by, bd = x, y, d end
    end
  end
  return bx, by
end

cast.PARK_STEP = 2 * cast.STREET_STEP -- точки прогулки в парке — сетка через столько пикселей

-- отрезок (ax, ay)–(bx, by) задевает контур pts (плоский список, замкнутый или нет) не концом: пересекает ребро
-- крест-накрест или проходит через вершину контура. Идти вдоль ребра можно (на кромке — не внутри)
local function cuts(pts, ax, ay, bx, by)
  local n = #pts
  if n >= 4 and pts[n - 1] == pts[1] and pts[n] == pts[2] then n = n - 2 end
  local function side(px, py, qx, qy, rx, ry)
    local v = (qx - px) * (ry - py) - (qy - py) * (rx - px)
    return v > 0 and 1 or v < 0 and -1 or 0
  end
  local j = n - 1
  for i = 1, n - 1, 2 do
    local xi, yi, xj, yj = pts[i], pts[i + 1], pts[j], pts[j + 1]
    local d1 = side(ax, ay, bx, by, xi, yi)
    if d1 * side(ax, ay, bx, by, xj, yj) < 0 and side(xi, yi, xj, yj, ax, ay) * side(xi, yi, xj, yj, bx, by) < 0 then
      return true
    end
    if d1 == 0 and (xi - ax) * (xi - bx) + (yi - ay) * (yi - by) < 0 then return true end
    j = i
  end
  return false
end

-- рамки по клеткам сетки PARK_STEP в части поля x0..x1 × y0..y1: list = { {pts, a0, b0, a1, b1}, … } (pts и его
-- рамка) -> any(ax, ay, bx, by, hit): hit(e) истинно у какой-нибудь e, чья рамка задевает рамку (ax, ay)–(bx, by) в этой
-- части поля
local function by_cells(list, x0, y0, x1, y1)
  local S, cells = cast.PARK_STEP, {}
  for _, e in ipairs(list) do
    if e[4] >= x0 and e[2] <= x1 and e[5] >= y0 and e[3] <= y1 then
      for cx = math.floor(math.max(e[2], x0) / S), math.floor(math.min(e[4], x1) / S) do
        for cy = math.floor(math.max(e[3], y0) / S), math.floor(math.min(e[5], y1) / S) do
          local key = cx .. "," .. cy
          cells[key] = cells[key] or {}
          table.insert(cells[key], e)
        end
      end
    end
  end
  return function(ax, ay, bx, by, hit)
    for cx = math.floor(ax / S), math.floor(bx / S) do
      for cy = math.floor(ay / S), math.floor(by / S) do
        for _, e in ipairs(cells[cx .. "," .. cy] or {}) do
          if e[4] >= ax and e[2] <= bx and e[5] >= ay and e[3] <= by and hit(e) then return true end
        end
      end
    end
    return false
  end
end

-- сетка прогулки парка tr.buildings[i] (один раз на (местность, парк)) -> { pts = { {x, y}, … }, at = { ["x,y"] = k },
-- lines = { {x0, y0, x1, y1}, … }, near = { [k] = { соседи k по путям } } }.
-- Точки — сетка PARK_STEP строго внутри контура и в поле [0, w] × [0, h] (местность берёт и парк, лишь задевающий поле:
-- сетка не шире поля), не внутри другого здания в парке (лавка, павильон); в узкий парк между её линиями — одна точка
-- (spot_in), если она в поле и не в другом здании. lines — пути гуляющего (те же ломаные, что улицы для шага): соседние
-- по сетке точки, если путь между ними не выходит из парка и не идёт через другое здание (здания и рёбра контура —
-- по клеткам сетки, by_cells: на большой местности путь сверяется только с соседними)
local grids_of = setmetatable({}, { __mode = "k" })
local function park_grid(tr, i)
  local cache = grids_of[tr]
  if not cache then
    cache = {}
    grids_of[tr] = cache
  end
  if cache[i] then return cache[i] end
  local b = tr.buildings[i]
  local x0, y0, x1, y1 = terrain.bounds(b.pts)
  x0, y0, x1, y1 = math.max(x0, 0), math.max(y0, 0), math.min(x1, tr.w), math.min(y1, tr.h)
  -- другие здания (не парки) и рёбра контура парка, чья рамка задевает эту часть парка
  local others, edges = {}, {}
  for k, o in ipairs(tr.buildings) do
    if k ~= i and o.kind ~= "park" then
      local a0, b0, a1, b1 = terrain.bounds(o.pts)
      others[#others + 1] = { o.pts, a0, b0, a1, b1 }
    end
  end
  local p, n = b.pts, #b.pts
  for k = 1, n - 1, 2 do
    local m = k + 2 <= n - 1 and k + 2 or 1
    local e = { p[k], p[k + 1], p[m], p[m + 1] }
    edges[#edges + 1] = { e, math.min(e[1], e[3]), math.min(e[2], e[4]), math.max(e[1], e[3]), math.max(e[2], e[4]) }
  end
  local any_other, any_edge = by_cells(others, x0, y0, x1, y1), by_cells(edges, x0, y0, x1, y1)
  local function free(x, y)
    if x < 0 or x > tr.w or y < 0 or y > tr.h then return false end
    return not any_other(x, y, x, y, function(o)
      return x > o[2] and x < o[4] and y > o[3] and y < o[5] and strictly_inside(o[1], x, y)
    end)
  end
  local g = { pts = {}, at = {}, lines = {}, near = {} }
  local function add(x, y)
    g.pts[#g.pts + 1] = { x, y }
    g.at[x .. "," .. y] = #g.pts
  end
  for x = math.ceil(x0 / cast.PARK_STEP) * cast.PARK_STEP, x1, cast.PARK_STEP do
    for y = math.ceil(y0 / cast.PARK_STEP) * cast.PARK_STEP, y1, cast.PARK_STEP do
      if strictly_inside(b.pts, x, y) and free(x, y) then add(x, y) end
    end
  end
  if #g.pts == 0 then
    local x, y = spot_in(b, "")
    if free(x, y) then add(x, y) end
  end
  -- пути: к соседу справа и снизу
  local near = g.near
  for k = 1, #g.pts do near[k] = {} end
  local function open(ax, ay, bx, by)
    if any_edge(ax, ay, bx, by, function(e) return cuts(e[1], ax, ay, bx, by) end) then return false end
    local mx, my = (ax + bx) / 2, (ay + by) / 2
    return not any_other(ax, ay, bx, by, function(o) return cuts(o[1], ax, ay, bx, by) or strictly_inside(o[1], mx, my) end)
  end
  for k, p in ipairs(g.pts) do
    for _, d in ipairs({ { cast.PARK_STEP, 0 }, { 0, cast.PARK_STEP } }) do
      local x, y = p[1] + d[1], p[2] + d[2]
      local m = g.at[x .. "," .. y]
      if m and open(p[1], p[2], x, y) then
        g.lines[#g.lines + 1] = { p[1], p[2], x, y }
        near[k][#near[k] + 1], near[m][#near[m] + 1] = m, k
      end
    end
  end
  cache[i] = g
  return g
end

local function dist2(x0, y0, x1, y1) return (x1 - x0) ^ 2 + (y1 - y0) ^ 2 end

-- узлы сети lines -> at, ids, occ: at[node_key(x, y)] — id узла (номер в сети, 1, 2, …), occ[id] — { s, i, s, i, … }
-- (ломаная s, её точка с индексом x i; одним плоским списком на узел — без таблицы на каждую точку сети: на Kindle их
-- тысячи, это десятки мс) — общие точки ломаных (перекрёстки OpenStreetMap — общие узлы, в сжатой местности — одни и те же целые
-- пиксели; пути парка — точки его сетки): общая точка — один узел; ids[s][(i + 1) / 2] — id узла точки i ломаной s (даль
-- до экрана считает по числам, без строк ключей: на Kindle строка из чисел дорога, Notion 41b13e60-bc8d-8189).
-- Единственное место, где задан узел сети: шаг (ways_from) и даль до экрана (graph, reach) берут узлы отсюда. Один раз
-- на сеть. Ключ точки — число, не строка (на Kindle строка на каждую точку сети — десятки мс): точки сети — целые
-- пиксели, |y| < terrain.COORD_MAX (держит terrain.valid) — у разных точек ключи разные
local NODE_ROW = 2 * terrain.COORD_MAX
local function node_key(x, y) return x * NODE_ROW + y end
local joints_of = setmetatable({}, { __mode = "k" })
local function joints(lines)
  local j = joints_of[lines]
  if j then return j[1], j[2], j[3] end
  local at, ids, occ, n = {}, {}, {}, 0
  for s, pts in ipairs(lines) do
    local line = {}
    ids[s] = line
    for i = 1, #pts - 1, 2 do
      local k = node_key(pts[i], pts[i + 1])
      local id = at[k]
      if not id then
        n = n + 1
        id, at[k], occ[n] = n, n, {}
      end
      local o = occ[id]
      o[#o + 1], o[#o + 2] = s, i
      line[(i + 1) / 2] = id
    end
  end
  joints_of[lines] = { at, ids, occ }
  return at, ids, occ
end

-- точки улиц, где может стоять гуляющий: через STREET_STEP px вдоль каждой ломаной tr.streets -> { {x, y, s, i}, … }
-- (точка на отрезке s, i сети улиц: ломаная s, от её точки i к i + 2). Один раз на местность
local street_points_of = setmetatable({}, { __mode = "k" })
local function street_points(tr)
  local out = street_points_of[tr.streets]
  if out then return out end
  out = {}
  for si, s in ipairs(tr.streets) do
    for i = 1, #s - 2, 2 do
      local x0, y0, x1, y1 = s[i], s[i + 1], s[i + 2], s[i + 3]
      local n = math.max(1, math.floor(math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2) / cast.STREET_STEP))
      for k = 0, n - 1 do
        out[#out + 1] = { terrain.round(x0 + (x1 - x0) * k / n), terrain.round(y0 + (y1 - y0) * k / n), si, i }
      end
    end
  end
  street_points_of[tr.streets] = out
  return out
end

-- точки парка i, где может стоять гуляющий: точки сетки (park_grid) -> { {x, y, s, i}, … } (s, i — путь парка от точки,
-- отрезок его сети lines: путь — ломаная из двух точек, i = 1; s nil — точка без путей). Точка без путей (киоски вокруг) — только если путей в парке нет
-- совсем (стоит, как точка узкого парка): иначе первый шаг шёл бы к пути по прямой, мимо сети. Один раз на сетку
local park_points_of = setmetatable({}, { __mode = "k" })
local function park_points(tr, i)
  local g = park_grid(tr, i)
  local out = park_points_of[g]
  if out then return out end
  out = {}
  local at, _, occ = joints(g.lines)
  for k, p in ipairs(g.pts) do
    if #g.near[k] > 0 or #g.lines == 0 then
      local id = at[node_key(p[1], p[2])]
      local s = id and occ[id][1]
      out[#out + 1] = { p[1], p[2], s, s and 1 }
    end
  end
  park_points_of[g] = out
  return out
end

-- сеть прогулки: улицы (park nil) или пути парка park (индекс tr.buildings) -> lines (ломаные: tr.streets |
-- park_grid(…).lines), pts — точки, где может стоять гуляющий (street_points | park_points)
local function net(tr, park)
  if park then return park_grid(tr, park).lines, park_points(tr, park) end
  return tr.streets, street_points(tr)
end

-- граф сети lines: узлы — узлы joints, рёбра — отрезки ломаных -> { [id узла] = { m, w, m, w, … } } (m — id соседнего
-- узла, w — длина отрезка, px), wmin — длина самого короткого отрезка между разными узлами (корзины reach). Один раз
-- на сеть
local graphs_of, wmins_of = setmetatable({}, { __mode = "k" }), setmetatable({}, { __mode = "k" })
local function graph(lines)
  local adj = graphs_of[lines]
  if adj then return adj, wmins_of[lines] end
  adj = {}
  local wmin = math.huge
  local _, ids = joints(lines)
  for s, q in ipairs(lines) do
    local line = ids[s]
    for i = 1, #q - 3, 2 do
      local a, b = line[(i + 1) / 2], line[(i + 3) / 2]
      local w = math.sqrt(dist2(q[i], q[i + 1], q[i + 2], q[i + 3]))
      if a ~= b and w < wmin then wmin = w end
      local ea = adj[a] or {}
      adj[a] = ea
      local eb = adj[b] or {}
      adj[b] = eb
      ea[#ea + 1], ea[#ea + 2] = b, w
      eb[#eb + 1], eb[#eb + 2] = a, w
    end
  end
  graphs_of[lines], wmins_of[lines] = adj, wmin
  return adj, wmin
end

-- связные куски сети lines: { [id узла] = номер куска } (узлы joints, рёбра graph): от узла дойти до экрана — то же,
-- что его кусок задевает экран. Один раз на сеть
local parts_of = setmetatable({}, { __mode = "k" })
local function parts(lines)
  local part = parts_of[lines]
  if part then return part end
  part = {}
  local _, ids = joints(lines)
  local adj, stack, np = graph(lines), {}, 0
  for _, line in ipairs(ids) do
    for _, id in ipairs(line) do
      if not part[id] then
        np = np + 1
        part[id], stack[1] = np, id
        local top = 1
        while top > 0 do
          local e = adj[stack[top]] or {}
          stack[top], top = nil, top - 1
          for k = 1, #e, 2 do
            local m = e[k]
            if not part[m] then part[m], top = np, top + 1; stack[top] = m end
          end
        end
      end
    end
  end
  parts_of[lines] = part
  return part
end

-- даль по сети до экрана screen: сеть lines, её точки pts (net) -> {
--   reaches(x, y) — от узла (точки ломаной) по сети дойти до экрана;
--   far(x, y) — px по сети от узла до ближайшей точки pts на экране | nil (откуда экран не достать);
--   sides() -> on — точки pts на экране, off — в запасе, от которых по сети дойти до экрана (каждая — та же точка pts,
--   порядок тот же) }.
-- Даль — обход Дейкстры (graph) от точек pts на экране: каждая — к обоим концам своего отрезка, дальше по отрезкам сети.
-- Обход ленивый: идёт, пока спрошенный узел не получит окончательную даль, и продолжается со следующего вопроса — дали
-- те же, что у обхода всей сети (на Kindle полный обход при каждом сдвиге карты дорог, Notion 41b13e60-bc8d-8189).
-- Дойти ли до экрана — по кускам сети (parts), без обхода. Одно правило для расстановки (walk_points), шага из запаса и
-- сдвига карты (cast.step), улиц и парков. Один раз на (сеть, экран): экран меняется сдвигом карты
local reach_of = setmetatable({}, { __mode = "k" })
local function reach(lines, pts, screen)
  local key = table.concat(screen, ",")
  local done = reach_of[lines]
  if done and done.screen == key and done.pts == pts then return done end
  local scr = { screen[1], screen[2], screen[3], screen[4] }
  local at, ids = joints(lines)
  local part, live, src = parts(lines), {}, {} -- live — куски, что задевают экран; src — точки pts на экране с отрезком
  for _, p in ipairs(pts) do
    if p[3] and cast.on_screen(scr, p[1], p[2]) then
      src[#src + 1] = p
      live[part[ids[p[3]][(p[4] + 1) / 2]]] = true
    end
  end
  -- очередь по корзинам ширины B: даль d — в корзине floor(d / B). B меньше самого короткого ребра между разными узлами
  -- (узлы — целые пиксели: ребро не короче 1 px), поэтому узел корзины k улучшает только узел дальше корзины k: даль
  -- узла окончательна, как только обход дошёл до его корзины. Внутри корзины — список: en — id узла, nx — следующий
  local adj, wmin = graph(lines)
  local B = wmin / 2
  local floor = math.floor
  local dist, head, en, nx, ne, cur, top, seen = {}, {}, {}, {}, 0, 0, -1, {}
  local function push(n, d) -- узел с id n и далью d в корзину, если даль меньше известной
    if dist[n] and dist[n] <= d then return end
    dist[n] = d
    local k = floor(d / B)
    ne = ne + 1
    en[ne], nx[ne], head[k] = n, head[k], ne
    if k > top then top = k end
  end
  local started = false
  local function lives(n) return live[part[n]] end -- от узла с id n дойти до экрана: его кусок задевает экран
  local function id_of(x, y) -- узел (x, y), если от него дойти до экрана -> id | nil
    local n = at[node_key(x, y)]
    return n and lives(n) and n
  end
  local function reaches(x, y) return id_of(x, y) ~= nil end
  local function far(x, y)
    local n = id_of(x, y)
    if not n then return nil end
    if not started then
      started = true
      for _, p in ipairs(src) do
        local q, i, line = lines[p[3]], p[4], ids[p[3]]
        push(line[(i + 1) / 2], math.sqrt(dist2(p[1], p[2], q[i], q[i + 1])))
        push(line[(i + 3) / 2], math.sqrt(dist2(p[1], p[2], q[i + 2], q[i + 3])))
      end
    end
    -- обход до корзины узла: узлы корзин раньше cur раскрыты, в корзине cur — окончательны
    while not dist[n] or floor(dist[n] / B) > cur do
      local e = head[cur]
      if e then
        head[cur] = nx[e]
        local m = en[e]
        if not seen[m] then -- в корзине cur нераскрытый узел — с далью этой корзины: прежние корзины раскрыты
          seen[m] = true
          local d, a = dist[m], adj[m]
          for k = 1, #a, 2 do push(a[k], d + a[k + 1]) end
        end
      elseif cur < top then cur = cur + 1
      else break end
    end
    return dist[n]
  end
  local on, off
  local function sides()
    if not on then
      on, off = {}, {}
      for _, p in ipairs(pts) do
        if cast.on_screen(scr, p[1], p[2]) then on[#on + 1] = p
        elseif p[3] and lives(ids[p[3]][(p[4] + 1) / 2]) then off[#off + 1] = p end
      end
    end
    return on, off
  end
  done = { screen = key, pts = pts, reaches = reaches, far = far, sides = sides }
  reach_of[lines] = done
  return done
end
cast.reach = reach -- даль по сети до экрана: тесты сверяют её с обходом всей сети

-- места прогулки -> на экране, в запасе: { {x, y, at, park}, … } каждая — точки улиц (street_points, at "street"),
-- потом точки парков parks (индексы tr.buildings; at "park", park — индекс парка, park_points). Точка парка в запасе —
-- только та, от которой по путям парка дойти до экрана (reach): из запаса гуляющий идёт к экрану (Notion
-- 41a13e60-bc8d-81cf). Точки улиц — все: расстановка без сдвига карты та же, что до 41a13e60-bc8d-8165 (уличного на
-- улице, откуда экран не достать, переставляет cast.step только после сдвига). Сеть улиц (узлы, граф, куски — parts)
-- готовится здесь, при открытии карты: первый шаг и шаг после сдвига на Kindle за неё не платят (Notion
-- 41b13e60-bc8d-8189)
local function walk_points(tr, screen, parks)
  parts(tr.streets)
  local on, off = {}, {}
  for _, p in ipairs(street_points(tr)) do
    local list = cast.on_screen(screen, p[1], p[2]) and on or off
    list[#list + 1] = { p[1], p[2], "street" }
  end
  for _, i in ipairs(parks) do
    local lines, pts = net(tr, i)
    local pon, poff = reach(lines, pts, screen).sides()
    for _, p in ipairs(pon) do on[#on + 1] = { p[1], p[2], "park", i } end
    for _, p in ipairs(poff) do off[#off + 1] = { p[1], p[2], "park", i } end
  end
  return on, off
end

-- cast — состав (mapdata.of(...).cast: {name, role, day, night}), tr — местность, t — os.date("*t"), seed — номер
-- открытия (ротация состава), screen — видимая часть поля { x0, y0, x1, y1 } (пиксели поля), all — выходят все из cast
-- (не больше MAX), а не 2–6 по seed, и запас их не отсекает (срез 14: тот же состав, открытый снова; броски — те же,
-- что без all)
-- -> { {name, x, y, at = "street" | "park" (гуляет в парке) | тип здания | "home", park} } (пиксели поля, у каждого —
-- точка; park — у гуляющего в парке: индекс парка в tr.buildings, по его путям он ходит в cast.step). Инварианты: 2–6
-- героев
-- (меньше — если меньше в составе или места нет совсем), в запасе (вне screen) ≤ RESERVE_MAX (с all — больше, если
-- иначе герою не выйти), на экране ≥ 1, если
-- хоть кому-то из состава распорядок позволяет стоять там; школа пуста ночью, в выходные и на каникулах; без школы в
-- местности — никого в школе
function cast.place(list, tr, t, seed, screen, all)
  local c, r = cast.clock(t), rng(seed)
  local order = {}
  for i, h in ipairs(list) do order[i] = h end
  for i = #order, 2, -1 do -- ротация: состав перемешан от seed
    local j = r(i)
    order[i], order[j] = order[j], order[i]
  end
  local n = math.min(#order, cast.MIN + r(cast.MAX - cast.MIN + 1) - 1)
  if all then n = math.min(#order, cast.MAX) end
  local s = sites(tr)
  local on, off = walk_points(tr, screen, s.parks)

  -- место where в местности: здание { x, y, at } | прогулка { at = "street" } (точку улицы или парка даёт street) |
  -- nil — такого нет
  local function resolve(h, where)
    local i
    if where == "street" then
      if #on + #off > 0 then return { at = "street" } end
    elseif where == "home" then
      i = cast.home(h.name, tr)
    elseif #s[where] > 0 then
      i = s[where][hash(h.name) % #s[where] + 1]
    end
    if i then
      local x, y = spot_in(tr.buildings[i], h.name)
      return { x = x, y = y, at = where == "home" and "home" or tr.buildings[i].kind }
    end
  end

  -- места, куда герою можно сейчас, в порядке предпочтения (нужного нет в местности — следующее по FALLBACK)
  local function options(h)
    local out, seen = {}, {}
    for _, w in ipairs(wants(h, c, r)) do
      for _, where in ipairs(FALLBACK[w]) do
        local p = resolve(h, where)
        if p then
          if not seen[where] then seen[where], out[#out + 1] = true, p end
          break
        end
      end
    end
    return out
  end

  -- уличному — точка прогулки на экране (screen_side) или в запасе; нужной стороны нет — другой (одна есть:
  -- resolve); at — "street" или "park" (park — индекс парка)
  local function street(screen_side)
    local pts = screen_side and on or off
    if #pts == 0 then pts = screen_side and off or on end
    local q = pts[r(#pts)]
    return { x = q[1], y = q[2], at = q[3], park = q[4] }
  end
  -- место может быть на экране: здание на экране или улица с точками на экране
  local function showable(p)
    if p.x then return cast.on_screen(screen, p.x, p.y) end
    return #on > 0
  end

  -- out[k] — расставленный герой, who[k] — его строка состава, opts[k] — его разрешённые места
  local out, who, opts, visible, used = {}, {}, {}, 0, {}
  local function put(k, h, p, ways)
    local old = out[k]
    if old and cast.on_screen(screen, old.x, old.y) then visible = visible - 1 end
    out[k], who[k], opts[k], used[h] = { name = h.name, x = p.x, y = p.y, at = p.at, park = p.park }, h, ways, true
    if cast.on_screen(screen, p.x, p.y) then visible = visible + 1 end
  end
  for _, h in ipairs(order) do
    if #out >= n then break end
    local ways = options(h)
    local p = ways[1]
    if p and not p.x then
      -- первый уличный — на экран; дальше в запас — каждый третий, пока запас не полон
      p = street(not (visible > 0 and #out - visible < cast.RESERVE_MAX and r(3) == 1))
    end
    if p and not cast.on_screen(screen, p.x, p.y) and #out - visible >= cast.RESERVE_MAX then
      -- запас полон: другое разрешённое место на экране, или герой не выходит (с all — остаётся в запасе: состав тот же)
      local alt
      for k = 2, #ways do
        if showable(ways[k]) then
          alt = ways[k].x and ways[k] or street(true)
          break
        end
      end
      p = alt or all and p or nil
    end
    if p then put(#out + 1, h, p, ways) end
  end

  -- добор «≥ 1 на экране»: все в запасе — сначала расставленный, кому распорядок позволяет стоять на экране, потом
  -- первый из не вышедших (занимает последнее место)
  local function show(k, h, ways)
    for _, p in ipairs(ways) do
      if showable(p) then
        put(k, h, p.x and p or street(true), ways)
        return true
      end
    end
  end
  if visible == 0 then
    local done = false
    for k = 1, #out do
      if show(k, who[k], opts[k]) then done = true break end
    end
    for _, h in ipairs(order) do
      if done then break end
      if not used[h] then done = show(#out < n and #out + 1 or math.max(#out, 1), h, options(h)) end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- срез 8: следы движутся

-- скорость гуляющего героя, px/с: своя у каждого (по хешу имени); при шаге CFG.map_step_s = 2,5 с — 20–40 px
cast.SPEED_MIN, cast.SPEED_MAX = 8, 16

-- Сеть путей — список ломаных { {x0, y0, x1, y1, …}, … }: улицы местности (tr.streets) или пути парка (park_grid).
-- Шаг по сети один для улиц и парков (walk).

-- отрезок сети lines, на котором стоит точка (x, y): ближайший -> s, i (отрезок от точки i к точке i + 2) | nil (сеть
-- пуста)
local function locate(lines, x, y)
  local best, bs, bi = math.huge
  for s, pts in ipairs(lines) do
    for i = 1, #pts - 3, 2 do
      local x0, y0, x1, y1 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
      local dx, dy = x1 - x0, y1 - y0
      local l2 = dx * dx + dy * dy
      local k = l2 > 0 and math.max(0, math.min(1, ((x - x0) * dx + (y - y0) * dy) / l2)) or 0
      local d = (x - x0 - k * dx) ^ 2 + (y - y0 - k * dy) ^ 2
      if d < best then best, bs, bi = d, s, i end
    end
  end
  return bs, bi
end

-- куда идти из узла (x, y), придя по отрезку back = {s, i, dir} (nil — ещё не шёл): { {s, i, dir, nx, ny}, … } — все
-- отрезки сети lines от узла, кроме обратного; nx, ny — точка, к которой ведёт отрезок. Тупик — только обратный
local function ways_from(lines, x, y, back)
  local out, rev = {}, nil
  local at, _, occ = joints(lines)
  local id = at[node_key(x, y)]
  local o = id and occ[id] or {}
  for k = 1, #o, 2 do
    local s, i = o[k], o[k + 1]
    local pts = lines[s]
    local cand = {}
    if i + 3 <= #pts then cand[#cand + 1] = { s, i, 1, pts[i + 2], pts[i + 3] } end
    if i >= 3 then cand[#cand + 1] = { s, i - 2, -1, pts[i - 2], pts[i - 1] } end
    for _, c in ipairs(cand) do
      if back and c[1] == back[1] and c[2] == back[2] and c[3] == -back[3] then rev = c
      else out[#out + 1] = c end
    end
  end
  if #out == 0 and rev then out[1] = rev end
  return out
end

-- выбор пути: из запаса — с наименьшей далью до экрана toward(nx, ny) точки, к которой ведёт путь; на экране (toward
-- nil) или экран отовсюду недостижим (даль math.huge) — бросок r
local function choose(opts, toward, r)
  if #opts == 0 then return nil end
  if toward then
    local best, bd = nil, math.huge
    for _, o in ipairs(opts) do
      local d = toward(o[4], o[5])
      if d < bd then best, bd = o, d end
    end
    if best then return best end
  end
  return opts[r(#opts)]
end

-- гуляющий герой h проходит dist px по сети lines -> x, y, way = {s, i, dir}. toward — даль до экрана от узла сети
-- (герой в запасе, choose; дошёл до тупика с далью 0 — точки прогулки на экране — шаг кончается там) | nil (на экране —
-- повороты по броску r, в тупике разворот)
local function walk(h, lines, dist, toward, r)
  local x, y, way = h.x, h.y, h.way
  if not way then
    local s, i = locate(lines, x, y)
    if not s then return x, y, nil end
    local pts = lines[s]
    local fwd = { s, i, 1, pts[i + 2], pts[i + 3] }
    local bwd = { s, i, -1, pts[i], pts[i + 1] }
    local c = choose({ fwd, bwd }, toward, r)
    way = { c[1], c[2], c[3] }
  end
  local s, i, dir = way[1], way[2], way[3]
  for _ = 1, 64 do -- отрезки нулевой длины и тупики не зацикливают
    if dist <= 0 then break end
    local pts = lines[s]
    local v = dir > 0 and i + 2 or i
    local vx, vy = pts[v], pts[v + 1]
    local d = math.sqrt(dist2(x, y, vx, vy))
    if d > dist then
      x, y, dist = x + (vx - x) * dist / d, y + (vy - y) * dist / d, 0
    else
      x, y, dist = vx, vy, dist - d
      local back = { s, i, dir }
      local c = choose(ways_from(lines, vx, vy, back), toward, r)
      if not c then break end
      s, i, dir = c[1], c[2], c[3]
      -- из запаса дошёл до тупика, а тупик — точка прогулки на экране (даль 0): шаг кончается здесь. Разворот увёл бы
      -- обратно за экран, и у кончика улицы в паре px от кромки так каждый шаг (Notion 41a13e60-bc8d-81c3)
      if toward and s == back[1] and i == back[2] and dir == -back[3] and toward(vx, vy) == 0 then break end
    end
  end
  return x, y, { s, i, dir }
end

-- гуляющий h (уличный или в парке) не на экране screen после сдвига карты, его сеть lines и её точки pts (net): с его
-- места по сети экран достижим (reach — то же правило, что у расстановки и шага) -> nil, идёт как шёл; нет -> точка
-- запаса { x, y } той же сети, откуда экран достижим (бросок r: появляется за краем и выходит к экрану шагом) | false —
-- такой нет, уходит с поля
local function reseat(h, lines, pts, screen, r)
  local to = reach(lines, pts, screen)
  local s, i
  if h.way then s, i = h.way[1], h.way[2] else s, i = locate(lines, h.x, h.y) end
  if to.reaches(lines[s][i], lines[s][i + 1]) then return nil end
  local _, off = to.sides()
  if #off == 0 then return false end
  return off[r(#off)]
end

-- state = { heroes = cast.place(…) | прошлый cast.step, screen = видимая часть поля { x0, y0, x1, y1 }, к которой шли
-- (nil — неизвестна), trail = N (CFG.map_trail) }, tr — местность, dt — с (CFG.map_step_s), screen — видимая часть
-- поля сейчас (сдвиг карты пальцем или с владельцем; nil — state.screen) -> новое состояние (screen — этот; прежнее не
-- меняется), у скольких героев изменились следы (шагнул, переставлен, ушёл или погас старший отпечаток). Тем же
-- распорядком, что cast.place: идут только гуляющие — уличный вдоль улиц, гуляющий в парке по путям своего парка
-- (park_grid), на SPEED × dt px; из запаса — к экрану: к узлу ближе к экрану по своей сети (reach: даль по улицам или
-- по путям парка, Notion 41a13e60-bc8d-81c0-9850); в зданиях и дома — на месте (ночью школа не наполняется,
-- домосед не выходит). Экран сдвинут (screen не state.screen): гуляющий за экраном, из чьей части сети его не достать,
-- в этот шаг не идёт, а переставлен в запас, откуда достать, или уходит с поля (gone = true: стоит, не рисуется, до
-- следующего открытия не возвращается) — reseat; остальные шагают как без сдвига (Notion 41a13e60-bc8d-8165). У
-- гуляющего — trail: прежние точки { {x, y}, … }, старшая первой, не больше N − 1 (с текущей — N пар отпечатков; старше
-- — гаснут; у ушедшего текущая точка уходит в след и гаснет с ним), way — где он на сети
function cast.step(state, tr, dt, screen)
  screen = screen or state.screen
  local was = state.screen
  local shifted = was and (was[1] ~= screen[1] or was[2] ~= screen[2] or was[3] ~= screen[3] or was[4] ~= screen[4])
  local tick = (state.tick or 0) + 1
  local keep = math.max(0, (state.trail or 1) - 1)
  local heroes, moved = {}, 0
  for k, h in ipairs(state.heroes) do
    local n = {}
    for key, v in pairs(h) do n[key] = v end
    local away = not cast.on_screen(screen, h.x, h.y)
    local lines, pts
    if h.at == "street" then
      lines, pts = net(tr)
    elseif h.at == "park" and h.park then
      lines, pts = net(tr, h.park)
    end
    if lines and #lines > 0 then
      if not h.gone then
        local hs = hash(h.name)
        local r = rng(hs + tick * 7919 + k)
        local seat
        if shifted and away then seat = reseat(h, lines, pts, screen, r) end
        if seat then
          n.x, n.y, n.way = seat[1], seat[2], nil
        elseif seat == false then
          n.gone, n.way = true, nil
        else
          local speed = cast.SPEED_MIN + hs % (cast.SPEED_MAX - cast.SPEED_MIN + 1)
          local toward
          if away then
            local far = reach(lines, pts, screen).far
            toward = function(x, y) return far(x, y) or math.huge end
          end
          n.x, n.y, n.way = walk(h, lines, speed * dt, toward, r)
        end
      end
      -- след стареет каждый шаг: шагнул, переставлен или ушёл — прежняя точка в след; стоит (тупик без длины, ушедший) —
      -- старшая гаснет
      local trail = {}
      for _, p in ipairs(h.trail or {}) do trail[#trail + 1] = p end
      if n.x ~= h.x or n.y ~= h.y or n.gone and not h.gone then
        moved = moved + 1
        trail[#trail + 1] = { h.x, h.y }
      elseif #trail > 0 then
        table.remove(trail, 1)
        moved = moved + 1
      end
      while #trail > keep do table.remove(trail, 1) end
      n.trail = trail
    end
    heroes[k] = n
  end
  return { heroes = heroes, screen = screen, trail = state.trail, tick = tick }, moved
end

return cast
