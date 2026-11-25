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

-- разрыв пера (дело 25.11, рука владельца): своя роза, где одна черта двумя штрихами (06 — перо село назад внахлёст,
-- 12 — с зазором), открывает образец из роз в 3 штриха. Раньше — промах по числу штрихов
function T.test_owner_rose_with_break_opens()
  for _, name in ipairs({ "owner_06", "owner_12" }) do
    t.eq(#O[name], 4)
    local ok, dist, gate = glyph.match(O[name], { O.owner_01, O.owner_02 })
    t.ok(ok, name .. ": роза с разрывом не открыла, dist=" .. tostring(dist) .. " gate=" .. tostring(gate))
  end
end

-- штрих -> куски: cuts — доли длины списка точек, где перо оторвалось; drop > 0 — столько точек пропало в зазоре,
-- drop < 0 — следующий кусок начат на столько точек раньше (внахлёст)
local function torn(stroke, cuts, drop)
  local p = stroke.p
  local n = #p / 2
  local out, from = {}, 1
  for k = 1, #cuts + 1 do
    local to = k <= #cuts and math.floor(n * cuts[k]) or n
    local q = {}
    for i = from, to do q[#q + 1], q[#q + 2] = p[2 * i - 1], p[2 * i] end
    out[#out + 1] = { p = q }
    from = math.max(1, to + 1 + drop)
  end
  return out
end

-- тот же знак, перо оторвано один или два раза посреди стороны (с зазором и внахлёст), открывает образец из целого
-- знака. Углы квадрата — на долях 0.25, 0.5, 0.75: отрыв в углу не разрыв (направление ломается) — его не отличить от
-- касания двух разных штрихов
function T.test_torn_sign_opens_whole_key()
  local key = { TR.square }
  for _, c in ipairs({ { { 0.4 }, 2 }, { { 0.35, 0.6 }, 2 }, { { 0.4 }, -4 }, { { 0.3, 0.7 }, -4 } }) do
    local attempt = torn(TR.square[1], c[1], c[2])
    t.eq(#attempt, #c[1] + 1)
    local ok, dist, gate = glyph.match(attempt, key)
    t.ok(ok, #attempt .. " куска, drop=" .. c[2] .. ": не открыл, dist=" .. tostring(dist) .. " gate=" .. tostring(gate))
  end
end

-- задуманный промах: отрыв ровно в углу (0.5 — угол квадрата) — не разрыв, а два штриха под углом
function T.test_corner_lift_is_not_a_break()
  local ok, _, gate = glyph.match(torn(TR.square[1], { 0.5 }, 2), { TR.square })
  t.eq(ok, false)
  t.eq(gate, "count")
end

-- и наоборот: образец задан с разрывом, знак нарисован одним штрихом — открывает
function T.test_whole_sign_opens_torn_key()
  local key = { torn(TR.square[1], { 0.6 }, 2), torn(TR.square[1], { 0.4 }, -4) }
  local ok, dist, gate = glyph.match(TR.square, key)
  t.ok(ok, "целый знак не открыл образец с разрывом, dist=" .. tostring(dist) .. " gate=" .. tostring(gate))
end

-- касание — не разрыв: у rose_ccw горизонтальная черта кончается у начала круга (зазор 11 px), но круг идёт
-- поперёк неё. «Ф» (круг и стойка, 2 штриха) образец из такой розы не открывает: штрихи склеились бы по одному зазору
function T.test_touching_strokes_not_a_break()
  local ok, dist, gate = glyph.match(R.letter_ef, { R.rose_ccw })
  t.ok(not ok, "«Ф» открыла розу с касанием, dist=" .. tostring(dist))
  t.eq(gate, "count")
end

-- атака разрывами (ревью a54ff28): чужой рисунок с оторванным пером набирает число штрихов образца, где разрыв
-- склеен. «Ф», крест и четвёрки, каждый штрих оторван в одном или двух местах (зазор и внахлёст), против образцов
-- с рваными розами владельца (06 — 4 штриха, черта внахлёст; 12 — горизонталь с зазором) и с ними же в паре с целой
-- розой, как ляжет в «задать ключ». Склейка разрывов не открывает ничего сверх правила до неё: открыл образец — значит,
-- открывает и рисунок этого образца с тем же числом штрихов, как нарисовано (на a54ff28 — 234 открытия склейкой).
-- Само правило до склейки рваную «Ф» в 3–4 штриха пускает к сравнению с розой того же числа штрихов — держит одно
-- облако. Остаток (замер 25.11) закреплён поимённо: «4» и закрытая «4», оторванные ровно в углу (3 штриха, не
-- склеиваются), открывают образцы с owner_12 (после склейки 3 штриха) при dist 2.96 и 3.00 — фигура того же класса,
-- что и до склейки: так же открывает owner_10 в 3 штриха (2.37 и 2.35)
local TEAR_RESIDUE = { ["digit_4>06+12"] = true, ["digit_4>12"] = true, ["digit_4>12+03"] = true,
                       ["digit_4_closed>06+12"] = true, ["digit_4_closed>12"] = true, ["digit_4_closed>12+03"] = true }
local function tears(strokes)
  local out = {}
  for i, s in ipairs(strokes) do
    for _, f in ipairs({ 0.1, 0.3, 0.5, 0.7, 0.9 }) do
      for _, drop in ipairs({ 2, -4 }) do
        local pieces = torn(s, { f }, drop)
        local a = {}
        for k, t2 in ipairs(strokes) do
          if k == i then
            for _, piece in ipairs(pieces) do a[#a + 1] = piece end
          else
            a[#a + 1] = t2
          end
        end
        out[#out + 1] = a
        -- второй отрыв в другом штрихе, пока штрихов не больше MAX_STROKES
        for j = i + 1, #a do
          if j ~= i and j ~= i + 1 and #a < glyph.MAX_STROKES then
            local b = {}
            for k, t2 in ipairs(a) do
              if k == j then
                for _, piece in ipairs(torn(t2, { 1 - f }, drop)) do b[#b + 1] = piece end
              else
                b[#b + 1] = t2
              end
            end
            out[#out + 1] = b
          end
        end
      end
    end
  end
  return out
end

function T.test_tear_attack_on_torn_owner_key()
  local keys = {
    { "06+12", { O.owner_06, O.owner_12 } }, { "06", { O.owner_06 } }, { "12", { O.owner_12 } },
    { "06+01", { O.owner_06, O.owner_01 } }, { "12+03", { O.owner_12, O.owner_03 } },
  }
  local attackers = { { "letter_ef", R.letter_ef }, { "cross_only", R.cross_only }, { "digit_4", TR.digit_4 },
                      { "digit_4_closed", TR.digit_4_closed } }
  local opened, tries, residue = {}, 0, {}
  for _, at in ipairs(attackers) do
    for _, attempt in ipairs(tears(at[2])) do
      for _, k in ipairs(keys) do
        tries = tries + 1
        local ok, dist = glyph.match(attempt, k[2])
        local raw = {}
        for _, d in ipairs(k[2]) do
          if #d == #attempt then raw[#raw + 1] = d end
        end
        if ok and not glyph.match(attempt, raw) then
          if TEAR_RESIDUE[at[1] .. ">" .. k[1]] then
            residue[at[1] .. ">" .. k[1]] = true
            t.ok(glyph.match(attempt, { O.owner_10 }), at[1] .. ": остаток не открывает owner_10 — уже не прежний класс")
          else
            opened[#opened + 1] = string.format("%s (%d штр.) открыл %s склейкой, dist=%.2f", at[1], #attempt, k[1], dist)
          end
        end
      end
    end
  end
  t.ok(tries > 400, "проб: " .. tries)
  t.eq(#opened, 0, table.concat(opened, "\n"))
  for k in pairs(TEAR_RESIDUE) do t.ok(residue[k], k .. ": остаток закрылся — убрать из TEAR_RESIDUE") end
end

-- матрица «образец × чужие»: ни одна чужая фигура не открывает ни один образец. Образцы — розы владельца (каждая с
-- соседями того же числа штрихов, в том числе 06+12 с разрывом) и треугольники одной руки; чужие розам — буквы со
-- страницы и все треугольники и не-треугольники, чужие треугольникам — буквы и розы владельца. На коде до склейки
-- разрывов — тоже 0 (сверено пробой); не-треугольники против треугольников открывают и до неё (трапеция, λ, «Д»):
-- допуск облака, не число штрихов — здесь не проверяются
function T.test_strangers_matrix()
  local keys = {}
  for i, name in ipairs(O.ROSES) do keys[#keys + 1] = { "роза " .. name, { O[name], unpack(same_strokes(O, O.ROSES, i)) }, "rose" } end
  for i, name in ipairs(SAME_TRIANGLE) do
    keys[#keys + 1] = { "треугольник " .. name, { TR[name], unpack(same_strokes(TR, SAME_TRIANGLE, i)) }, "triangle" }
  end
  local strangers = { rose = {}, triangle = {} }
  for _, n in ipairs(LETTERS) do
    strangers.rose[#strangers.rose + 1] = { n, R[n] }
    strangers.triangle[#strangers.triangle + 1] = { n, R[n] }
  end
  for _, list in ipairs({ TR.TRIANGLES, TR.NON_TRIANGLES }) do
    for _, n in ipairs(list) do strangers.rose[#strangers.rose + 1] = { n, TR[n] } end
  end
  for _, n in ipairs(O.ROSES) do strangers.triangle[#strangers.triangle + 1] = { n, O[n] } end
  local opened, pairs_n = {}, 0
  for _, k in ipairs(keys) do
    for _, s in ipairs(strangers[k[3]]) do
      pairs_n = pairs_n + 1
      local ok, dist = glyph.match(s[2], k[2])
      if ok then opened[#opened + 1] = string.format("%s открыл образец «%s», dist=%.2f", s[1], k[1], dist) end
    end
  end
  t.ok(pairs_n > 500, "матрица не пустая: " .. pairs_n)
  t.eq(table.concat(opened, "\n"), "")
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
