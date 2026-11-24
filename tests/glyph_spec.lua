-- Знак печати: riddle.glyph сравнивает рисунок с образцом облаком точек (спека 2026-11-20-seal-key §5).
-- Свои пары — одна фигура одной руки (12 роз владельца, треугольник со стороной 360 в разных исполнениях); чужие —
-- роза с треугольником и буквы со страницы. Ложное открытие хуже пропуска.
local t = require("t")
local glyph = require("riddle.glyph")
local O = require("fixtures.rose_owner")
local R = require("fixtures.rose_strokes")
local TR = require("fixtures.triangle_strokes")

local T = {}

-- один и тот же треугольник ABC (triangle_strokes.lua:70) разной рукой; obtuse_106, right_ccw и tilted_37 — другие
-- фигуры, своими парами не считаются
local SAME_TRIANGLE = { "equilateral", "start_mid_side", "rounded_corners", "gap_8", "overshoot_10", "two_strokes",
                        "wobbly", "flick_tail", "kinked_side", "two_strokes_far" }

-- буквы и слова со страницы (rose_strokes.lua)
local LETTERS = { "letter_o", "word_salandusa", "word_oh", "word_to", "letter_ef", "theta_underlined" }

-- образец из двух соседей по кругу: names[i+1], names[i+2]
local function neighbours(src, names, i)
  local n = #names
  return { src[names[i % n + 1]], src[names[(i + 1) % n + 1]] }
end

-- образец своей фигуры: до двух следующих по кругу рисунков с тем же числом штрихов, что у names[i] (контракт
-- glyph: все рисунки образца — одного числа штрихов). Своих в этом числе штрихов нет — пустой образец
local function same_strokes(src, names, i)
  local n, key = #names, {}
  for k = 1, n - 1 do
    local d = src[names[(i - 1 + k) % n + 1]]
    if #d == #src[names[i]] and #key < 2 then key[#key + 1] = d end
  end
  return key
end

local function shifted(strokes, dx, dy, k)
  local out = {}
  for i, s in ipairs(strokes) do
    local p = {}
    for j = 1, #s.p, 2 do
      p[j], p[j + 1] = s.p[j] * k + dx, s.p[j + 1] * k + dy
    end
    out[i] = { p = p }
  end
  return out
end

-- обратный порядок штрихов и обратное направление каждого
local function reversed(strokes)
  local out = {}
  for i = #strokes, 1, -1 do
    local p, s = {}, strokes[i].p
    for j = #s - 1, 1, -2 do
      p[#p + 1], p[#p + 2] = s[j], s[j + 1]
    end
    out[#out + 1] = { p = p }
  end
  return out
end

function T.test_owner_roses_match_each_other()
  for i, name in ipairs(O.ROSES) do
    local key = same_strokes(O, O.ROSES, i)
    t.ok(#key > 0, name .. ": нет пары с тем же числом штрихов")
    local ok, dist = glyph.match(O[name], key)
    t.ok(ok, name .. ": своя роза не совпала, dist=" .. tostring(dist) .. " > DIST=" .. glyph.DIST)
  end
end

function T.test_triangles_match_each_other()
  for i, name in ipairs(SAME_TRIANGLE) do
    local key = same_strokes(TR, SAME_TRIANGLE, i)
    t.ok(#key > 0, name .. ": нет пары с тем же числом штрихов")
    local ok, dist = glyph.match(TR[name], key)
    t.ok(ok, name .. ": свой треугольник не совпал, dist=" .. tostring(dist) .. " > DIST=" .. glyph.DIST)
  end
end

function T.test_rose_vs_triangle_no_match()
  for i, name in ipairs(O.ROSES) do
    local rose_key = neighbours(O, O.ROSES, i)
    for j, tri in ipairs(TR.TRIANGLES) do
      local ok, dist = glyph.match(O[name], neighbours(TR, TR.TRIANGLES, j))
      t.ok(not ok, name .. " открыла образец-треугольник, dist=" .. tostring(dist))
      ok, dist = glyph.match(TR[tri], rose_key)
      t.ok(not ok, tri .. " открыл образец-розу, dist=" .. tostring(dist))
    end
  end
end

function T.test_letters_no_match()
  for _, name in ipairs(LETTERS) do
    for i = 1, #O.ROSES do
      local ok, dist = glyph.match(R[name], neighbours(O, O.ROSES, i))
      t.ok(not ok, name .. " открыл образец-розу, dist=" .. tostring(dist))
    end
    for i = 1, #TR.TRIANGLES do
      local ok, dist = glyph.match(R[name], neighbours(TR, TR.TRIANGLES, i))
      t.ok(not ok, name .. " открыл образец-треугольник, dist=" .. tostring(dist))
    end
  end
end

function T.test_order_and_direction_free()
  local cases = {
    { O.owner_03, { O.owner_01, O.owner_02 }, "owner_03" },
    { O.owner_06, { O.owner_12 }, "owner_06" },
    { O.owner_12, { O.owner_06 }, "owner_12" },
    { TR.two_strokes, { TR.two_strokes_far }, "two_strokes" },
  }
  for _, c in ipairs(cases) do
    local _, a = glyph.match(c[1], c[2])
    local _, b = glyph.match(reversed(c[1]), c[2])
    t.ok(a < math.huge, c[3] .. ": сравнение дошло до облака")
    t.ok(math.abs(a - b) < 1e-6, c[3] .. ": порядок и направление сменили dist " .. a .. " → " .. b)
  end
end

-- задуманный промах (контракт glyph): своя роза, нарисованная 4 штрихами (черта в два), против образца из роз в 3
-- штриха не открывает — ложное открытие хуже промаха
function T.test_stroke_count_gate_planned_miss()
  t.eq(#O.owner_06, 4) t.eq(#O.owner_01, 3) t.eq(#O.owner_02, 3)
  local ok, dist = glyph.match(O.owner_06, { O.owner_01, O.owner_02 })
  t.eq(ok, false)
  t.eq(dist, math.huge)
end

-- мельче SIZE — не знак, даже если фигура та же: △ 120 px против образца-треугольника
function T.test_size_gate()
  local key = { TR.equilateral, TR.wobbly }
  local ok, dist = glyph.match(TR.triangle_120, key)
  t.eq(ok, false)
  t.eq(dist, math.huge)
  t.eq(glyph.match(TR.gap_8, key), true, "крупный треугольник той же руки проходит")
end

-- «Ф» (круг и одна стойка, 2 штриха) — ближайшая чужая фигура: ни образец-роза, ни образец-треугольник, в том числе
-- в два штриха
function T.test_letter_ef_no_match()
  local keys = { { TR.two_strokes, TR.two_strokes_far } }
  for i = 1, #O.ROSES do keys[#keys + 1] = neighbours(O, O.ROSES, i) end
  for i = 1, #TR.TRIANGLES do keys[#keys + 1] = neighbours(TR, TR.TRIANGLES, i) end
  for k, key in ipairs(keys) do
    local ok, dist = glyph.match(R.letter_ef, key)
    t.ok(not ok, "«Ф» открыла образец " .. k .. ", dist=" .. tostring(dist))
  end
end

-- место и размер на странице не важны: сдвинутая и уменьшенная копия — тот же знак
function T.test_place_and_size_free()
  local ok, dist = glyph.match(shifted(O.owner_05, 180, -140, 0.5), { O.owner_05 })
  t.ok(ok and dist < 1e-6, "копия не совпала с собой, dist=" .. tostring(dist))
end

-- dist — минимум по рисункам образца
function T.test_dist_is_min_over_drawings()
  local _, alone = glyph.match(O.owner_04, { TR.equilateral })
  local ok, dist = glyph.match(O.owner_04, { TR.equilateral, O.owner_04 })
  t.ok(alone > glyph.DIST, "с чужим рисунком — не совпало")
  t.ok(ok and dist < 1e-6, "свой рисунок в образце, dist=" .. tostring(dist))
end

-- рисунок без длины (точки) — не совпадает ни с чем и не падает
function T.test_no_length_no_match()
  local ok, dist = glyph.match({ { p = { 100, 100 } } }, { O.owner_01 })
  t.eq(ok, false)
  t.eq(dist, math.huge)
end

-- взвешенное жадное сопоставление ($P): ранние пары весят больше, минимум по стартам и сторонам.
-- a = (0,0),(2,0), b = (1,0),(5,0): лучший обход — a1→b1 (1·1) и a2→b2 (3·½) = 2.5; без весов было бы 4
function T.test_cloud_weighted_greedy()
  local d = glyph.cloud({ { 0, 0 }, { 2, 0 } }, { { 1, 0 }, { 5, 0 } })
  t.ok(math.abs(d - 2.5) < 1e-9, "cloud=" .. tostring(d))
end

-- обход в обе стороны: a = 0,1,7, b = 2,4,7 по оси x. Лучший обход a→b — 7/3, b→a — 2 (с b3: 7→7 ·1, 2→1 ·⅔,
-- 4→0 ·⅓); расстояние — меньшее, одно и то же при любом порядке аргументов
function T.test_cloud_both_directions()
  local a, b = { { 0, 0 }, { 1, 0 }, { 7, 0 } }, { { 2, 0 }, { 4, 0 }, { 7, 0 } }
  local ab, ba = glyph.cloud(a, b), glyph.cloud(b, a)
  t.ok(math.abs(ab - 2) < 1e-9, "cloud(a, b)=" .. tostring(ab))
  t.ok(math.abs(ba - 2) < 1e-9, "cloud(b, a)=" .. tostring(ba))
end

-- рамка ровно SIZE — ещё знак: квадрат со стороной SIZE проходит ворота match и fits
function T.test_size_boundary_passes()
  local s = glyph.SIZE
  local square = { { p = { 200, 300, 200 + s, 300, 200 + s, 300 + s, 200, 300 + s, 200, 300 } } }
  local ok, dist = glyph.match(square, { square })
  t.eq(ok, true, "квадрат со стороной SIZE против себя, dist=" .. tostring(dist))
  t.eq(glyph.fits(square), true, "квадрат со стороной SIZE годится в образец")
end

function T.test_fits_accepts_own_sign()
  local ok, why = glyph.fits(TR.square)
  t.eq(ok, true, "квадрат годится в знак: " .. tostring(why))
  t.eq(glyph.fits(TR.letter_de), true, "«Д» двумя штрихами годится")
end

function T.test_fits_rejects_triangle()
  local ok, why = glyph.fits(TR.equilateral)
  t.eq(ok, false)
  t.eq(why, "taken")
end

function T.test_fits_rejects_rose()
  local ok, why = glyph.fits(O.owner_01)
  t.eq(ok, false)
  t.eq(why, "taken")
end

function T.test_fits_rejects_small()
  local ok, why = glyph.fits(TR.triangle_120)
  t.eq(ok, false)
  t.eq(why, "size")
  ok, why = glyph.fits(R.letter_o)
  t.eq(why, "size", "строчная «о»")
end

function T.test_fits_rejects_many_strokes()
  t.ok(#R.word_salandusa > glyph.MAX_STROKES, "фикстура: слово длиннее MAX_STROKES")
  local ok, why = glyph.fits(R.word_salandusa)
  t.eq(ok, false)
  t.eq(why, "strokes")
  ok, why = glyph.fits({})
  t.eq(why, "strokes", "пустая страница")
end

function T.test_constants()
  t.eq(glyph.N, 64)
  t.eq(glyph.MAX_STROKES, 4)
  t.eq(glyph.SIZE, 150)
  t.eq(type(glyph.DIST), "number")
end

t.run(T)
