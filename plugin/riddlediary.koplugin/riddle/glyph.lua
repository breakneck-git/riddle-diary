-- Знак печати: рисунок пером сравнивается с образцом, который нарисовал сам владелец (спека 2026-11-20-seal-key §5).
-- Метод — облако точек, семейство $P: штрихи — одно облако из N точек, центр в нуле, большая сторона рамки — 1;
-- расстояние — взвешенное жадное сопоставление точек в обе стороны. Порядок и направление штрихов не важны, место на
-- странице — тоже. Чистые функции без KOReader, на общей геометрии пера (riddle.pen).
-- Ложное открытие хуже пропуска: до облака — ворота (штрихов 1..MAX_STROKES, рамка не мельче SIZE, число штрихов —
-- как у рисунка образца с точностью до разрывов пера); DIST — по фикстурам (tests/glyph_spec.lua), с зазором до
-- чужих фигур.
-- Число штрихов — несущая примета: облако его не видит («Ф» против розы — 1.27 < DIST). Разрыв пера (перо оторвалось
-- и село рядом, повело штрих дальше) его не меняет: знак совместим с рисунком образца, если у них одно число штрихов
-- как нарисовано или одно число после склейки всех разрывов. Промежуточные склейки не в счёт: иначе чужой рисунок с
-- лишним оторванным куском набирает число штрихов образца, у которого разрыв склеен (атака разрывами, ревью a54ff28).
-- Касание (штрих начат у конца другого, но поперёк) — не разрыв.
local pen = require("riddle.pen")
local rose = require("riddle.rose")
local triangle = require("riddle.triangle")

local glyph = {}

glyph.N = 64            -- точек в облаке
glyph.MAX_STROKES = 4   -- штрихов в знаке не больше: страница со словами не сравнивается
glyph.SIZE = triangle.SIZE -- меньшая сторона рамки знака, px ≥: та же, что у треугольника
-- допуск cloud: свои пары фикстур в тестах — до 2.222, с образцом из одного рисунка — до 3.470; чужие после
-- ворот — от 3.312 (letter_ef против образца-треугольника в два штриха)
glyph.DIST = 3.0
-- разрыв пера (дело 25.11: у владельца 2 розы из 12 — черта двумя штрихами, перо село в 40 и 85 px, внахлёст):
-- следующий штрих начат не дальше BREAK_GAP большей стороны рамки рисунка от конца предыдущего, и направления конца
-- и начала (по BREAK_TAIL стороны рамки) расходятся не больше BREAK_TURN градусов. Пробой по фикстурам: разрывы
-- владельца — 0.12 и 0.09 стороны рамки, 0.2 — с запасом; на 0.3 смайлик открывает круг с крестом; без направления
-- «Ф» открывает розы, где черта касается круга (rose_ccw)
glyph.BREAK_GAP = 0.2
glyph.BREAK_TURN = 45
glyph.BREAK_TAIL = 0.08

-- список точек меньше другого: первая разная координата, потом длина
local function less(a, b)
  for i = 1, math.min(#a, #b) do
    for k = 1, 2 do
      if a[i][k] ~= b[i][k] then return a[i][k] < b[i][k] end
    end
  end
  return #a < #b
end

-- штрихи -> одно и то же облако при любом порядке и направлении: каждый штрих — в меньшем из двух направлений,
-- штрихи — по возрастанию; точки делятся между штрихами по длине (наибольший остаток), каждый передискретизуется
-- отдельно — прыжок пера между штрихами точек не получает
local function canonical(strokes)
  local lists = {}
  for _, s in ipairs(strokes) do
    local list = pen.points(s)
    if pen.length(list) > 0 then
      local back = pen.reversed(list)
      lists[#lists + 1] = less(back, list) and back or list
    end
  end
  table.sort(lists, less)
  return lists
end

-- штрихи -> облако из N точек, центр масс в нуле, большая сторона рамки 1 | nil (у рисунка нет длины)
local function cloud_of(strokes)
  local lists = canonical(strokes)
  local total = 0
  for _, list in ipairs(lists) do total = total + pen.length(list) end
  if total == 0 then return nil end
  local counts, rest, used = {}, {}, 0
  for i, list in ipairs(lists) do
    local share = glyph.N * pen.length(list) / total
    counts[i] = math.floor(share)
    rest[#rest + 1] = { i = i, r = share - counts[i] }
    used = used + counts[i]
  end
  table.sort(rest, function(a, b) return a.r > b.r or (a.r == b.r and a.i < b.i) end)
  for k = 1, glyph.N - used do counts[rest[k].i] = counts[rest[k].i] + 1 end
  local pts = {}
  for i, list in ipairs(lists) do
    if counts[i] > 0 then
      for _, q in ipairs(pen.resample(list, counts[i])) do pts[#pts + 1] = q end
    end
  end
  local cx, cy = 0, 0
  for _, q in ipairs(pts) do cx, cy = cx + q[1], cy + q[2] end
  cx, cy = cx / #pts, cy / #pts
  local x0, y0, x1, y1 = pen.bounds(pts)
  local side = math.max(x1 - x0, y1 - y0)
  local out = {}
  for i, q in ipairs(pts) do out[i] = { (q[1] - cx) / side, (q[2] - cy) / side } end
  return out
end

-- a, начиная с точки start, — к ближайшей свободной точке b; вес пары падает от 1 к 1/n по ходу обхода
local function greedy(a, b, start)
  local n, free, sum = #a, {}, 0
  for j = 1, n do free[j] = true end
  for k = 0, n - 1 do
    local p = a[(start - 1 + k) % n + 1]
    local best, bj = math.huge, nil
    for j = 1, n do
      if free[j] then
        local d = pen.dist(p, b[j])
        if d < best then best, bj = d, j end
      end
    end
    free[bj] = false
    sum = sum + (1 - k / n) * best
  end
  return sum
end

-- два облака одинакового размера -> расстояние: минимум по стартам с шагом ⌊√n⌋ и по обеим сторонам
function glyph.cloud(a, b)
  local n = #a
  local step = math.max(1, math.floor(n ^ 0.5))
  local best = math.huge
  for start = 1, n, step do
    best = math.min(best, greedy(a, b, start), greedy(b, a, start))
  end
  return best
end

-- направление ломаной на её конце: от точки за reach px до конца к последней -> единичный вектор | nil (длины нет)
local function heading(list, reach)
  local acc, i = 0, #list
  while i > 1 and acc < reach do
    acc = acc + pen.dist(list[i - 1], list[i])
    i = i - 1
  end
  local a, b = list[i], list[#list]
  local d = a and pen.dist(a, b) or 0
  if d == 0 then return nil end
  return { (b[1] - a[1]) / d, (b[2] - a[2]) / d }
end

-- рисунок -> число штрихов после склейки всех разрывов. Склейка — по одной, самым малым прыжком пера среди разрывов
-- (pen.joins: оба направления каждого штриха)
local function whole(strokes)
  local lists, all = {}, {}
  for i, s in ipairs(strokes) do
    lists[i] = pen.points(s)
    for _, q in ipairs(lists[i]) do all[#all + 1] = q end
  end
  local x0, y0, x1, y1 = pen.bounds(all)
  if x0 == math.huge then return #lists end
  local side = math.max(x1 - x0, y1 - y0)
  local gap, reach, turn = glyph.BREAK_GAP * side, glyph.BREAK_TAIL * side, math.cos(math.rad(glyph.BREAK_TURN))
  while #lists > 1 do
    local best, bi, bj, blist = math.huge
    for i = 1, #lists do
      for j = i + 1, #lists do
        local n = #lists[i]
        for _, join in ipairs(pen.joins(lists[i], lists[j])) do
          if join.jump <= gap and join.jump < best and n > 0 and #join.list > n then
            -- join.list — первый штрих (n точек), за ним второй; второй развёрнут, чтобы его начало шло первым
            local head, tail = {}, {}
            for k = 1, n do head[k] = join.list[k] end
            for k = #join.list, n + 1, -1 do tail[#tail + 1] = join.list[k] end
            local a, b = heading(head, reach), heading(tail, reach)
            -- b смотрит назад от начала второго штриха: продолжение — когда a и −b близки
            if a and b and -(a[1] * b[1] + a[2] * b[2]) >= turn then best, bi, bj, blist = join.jump, i, j, join.list end
          end
        end
      end
    end
    if not bi then break end
    table.remove(lists, bj)
    lists[bi] = blist
  end
  return #lists
end

-- рисунок -> меньшая сторона его рамки, px (0 — точек нет)
local function side(strokes)
  local all = {}
  for _, s in ipairs(strokes) do
    for _, q in ipairs(pen.points(s)) do all[#all + 1] = q end
  end
  local x0, y0, x1, y1 = pen.bounds(all)
  return x0 == math.huge and 0 or math.min(x1 - x0, y1 - y0)
end

-- рисунок, образец (список рисунков, каждый — список штрихов) -> совпал ли, расстояние до ближайшего рисунка
-- образца (math.huge — сравнивать не с чем), ворота промаха | nil (совпал). Ворота до облака: "count" — штрихов не
-- 1..MAX_STROKES или в образце нет рисунка, совместимого по числу штрихов (с точностью до разрывов пера); "size" —
-- рамка мельче SIZE; после облака "dist" — ближайший рисунок дальше DIST. opts — свой порог и свои ворота размера
-- ({ dist = , size = }, nil — DIST и SIZE ключа): у знаков управления шаблоны вшитые, чужие фигуры к ним ближе
-- (riddle.signs)
function glyph.match(strokes, drawings, opts)
  strokes = strokes or {}
  local limit = opts and opts.dist or glyph.DIST
  if #strokes == 0 or #strokes > glyph.MAX_STROKES then return false, math.huge, "count" end
  if side(strokes) < (opts and opts.size or glyph.SIZE) then return false, math.huge, "size" end
  local a = cloud_of(strokes)
  local glued = whole(strokes)
  local best = math.huge
  for _, d in ipairs(a and drawings or {}) do
    -- совместимы: одно число штрихов как нарисовано или после склейки всех разрывов (не промежуточное)
    local b = (#d == #strokes or whole(d) == glued) and cloud_of(d)
    if b then best = math.min(best, glyph.cloud(a, b)) end
  end
  if best == math.huge then return false, best, "count" end
  if best > limit then return false, best, "dist" end
  return true, best
end

-- рисунок -> годится ли в образец, причина отказа: "strokes" (штрихов 0 или больше MAX_STROKES), "size" (меньшая
-- сторона рамки меньше SIZE), "taken" (это треугольник или роза — знаки заняты)
function glyph.fits(strokes)
  strokes = strokes or {}
  if #strokes == 0 or #strokes > glyph.MAX_STROKES then return false, "strokes" end
  if side(strokes) < glyph.SIZE then return false, "size" end
  if triangle.detect(strokes) or rose.detect(strokes) then return false, "taken" end
  return true
end

return glyph
