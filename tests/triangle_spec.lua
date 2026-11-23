-- Треугольник пером (спека 2026-11-19-status-triangle, подход А): одна замкнутая линия с тремя углами открывает
-- страницу состояния. Ложное срабатывание хуже пропуска: буквы, рисунки и роза — не треугольник.
local t = require("t")
local triangle = require("riddle.triangle")
local rose = require("riddle.rose")
local F = require("fixtures.triangle_strokes")
local R = require("fixtures.rose_strokes")
local O = require("fixtures.rose_owner")

local T = {}

local function reversed_points(s)
  local p, q = s.p, {}
  for i = #p - 1, 1, -2 do
    q[#q + 1] = p[i]
    q[#q + 1] = p[i + 1]
  end
  return { p = q }
end

function T.test_detect_triangles()
  for _, name in ipairs(F.TRIANGLES) do
    local ok, score = triangle.detect(F[name])
    t.eq(type(score), "number", name .. ": score — число")
    t.ok(ok == true, name .. ": треугольник не узнан, score=" .. tostring(score))
  end
end

function T.test_not_triangles()
  for _, name in ipairs(F.NON_TRIANGLES) do
    local ok, score = triangle.detect(F[name])
    t.eq(type(score), "number", name .. ": score — число")
    t.ok(ok == false, name .. ": узнан треугольником, score=" .. tostring(score))
  end
end

-- всё, что пишут на странице, из фикстур розы: розы, буквы, слова, рисунки, 12 живых роз владельца
function T.test_roses_and_letters_not_triangles()
  local names = {}
  for _, n in ipairs(R.ROSES) do names[#names + 1] = { R, n } end
  for _, n in ipairs(R.NON_ROSES) do names[#names + 1] = { R, n } end
  for _, n in ipairs(O.ROSES) do names[#names + 1] = { O, n } end
  t.ok(#names >= 47, "фикстур розы: " .. #names)
  for _, it in ipairs(names) do
    local ok, score = triangle.detect(it[1][it[2]])
    t.ok(ok == false, it[2] .. ": узнан треугольником, score=" .. tostring(score))
  end
end

function T.test_triangles_not_roses()
  for _, name in ipairs(F.TRIANGLES) do
    t.ok(not rose.detect(F[name]), name .. ": треугольник узнан розой")
  end
end

-- направление обхода и порядок штрихов не важны
function T.test_order_and_direction_irrelevant()
  for _, name in ipairs(F.TRIANGLES) do
    local strokes = F[name]
    local back = {}
    for i, s in ipairs(strokes) do back[i] = reversed_points(s) end
    t.ok(triangle.detect(back), name .. ": штрихи задом наперёд")
    if #strokes == 2 then
      t.ok(triangle.detect({ strokes[2], strokes[1] }), name .. ": штрихи в обратном порядке")
      t.ok(triangle.detect({ back[2], back[1] }), name .. ": обратный порядок и задом наперёд")
    end
  end
  for _, name in ipairs(F.NON_TRIANGLES) do
    local back = {}
    for i, s in ipairs(F[name]) do back[i] = reversed_points(s) end
    t.ok(not triangle.detect(back), name .. ": задом наперёд узнан треугольником")
  end
end

-- каждый порог держит свой не-треугольник: ослабь порог — он становится треугольником; без мутации — нет
function T.test_each_threshold_held()
  local held = {
    { "GAP", 1.0, "gap_half_side" }, { "JUMP", 1.0, "angle_sign" }, { "BEND", 1.0, "bulged_side" },
    { "SIDE", 0.01, "sliver_45" }, { "SIZE", 75, "triangle_120" }, { "TRIM", 1.0, "digit_4_closed" },
    { "TRIM", 1.0, "digit_4_closed_one" }, { "TRIM", 1.0, "digit_4_closed_500" },
  }
  for _, h in ipairs(held) do
    local key, loose, name = h[1], h[2], h[3]
    t.ok(not triangle.detect(F[name]), name .. ": не треугольник при triangle." .. key .. "=" .. tostring(triangle[key]))
    local keep = triangle[key]
    triangle[key] = loose
    local ok = triangle.detect(F[name])
    triangle[key] = keep
    t.ok(ok, name .. ": triangle." .. key .. "=" .. tostring(loose) .. " должен сделать его треугольником — порог не держит")
  end
end

-- излом стороны слабее угла — не четвёртый угол; порог угла ниже (CORNER_MIN 35) сделал бы его углом
function T.test_corner_min_held()
  t.ok(triangle.detect(F.kinked_side), "kinked_side: треугольник")
  local keep = triangle.CORNER_MIN
  triangle.CORNER_MIN = 35
  local ok = triangle.detect(F.kinked_side)
  triangle.CORNER_MIN = keep
  t.ok(not ok, "kinked_side: при CORNER_MIN=35 излом — угол; порог не держит")
end

-- больше штрихов, чем MAX_STROKES, — сразу false: третий штрих не отбрасывается молча (треугольник двумя штрихами
-- и слово рядом — не знак)
function T.test_extra_stroke_not_dropped()
  local s = { F.two_strokes[1], F.two_strokes[2], F.letter_a[2] }
  t.ok(triangle.detect({ s[1], s[2] }), "два штриха — треугольник")
  local ok, score, why = triangle.detect(s)
  t.eq(ok, false, "третий штрих")
  t.eq(type(score), "number")
  t.eq(why, nil, "разбора нет: кандидатов не строили")
end

-- разбор: каждый критерий — доля своего порога (≤ 1 — пройден), наихудший равен score
function T.test_detect_parts()
  local keys = triangle.CRITERIA
  t.eq(#keys, 6, "критерии: gap, trim, corners, bend, side, size")
  for _, name in ipairs(F.TRIANGLES) do
    local _, score, parts = triangle.detect(F[name])
    t.eq(type(parts), "table", name .. ": разбор есть")
    local worst = 0
    for _, k in ipairs(keys) do
      t.eq(type(parts[k]), "number", name .. ": " .. k)
      t.ok(parts[k] <= 1, name .. ": " .. k .. "=" .. tostring(parts[k]))
      worst = math.max(worst, parts[k])
    end
    t.ok(math.abs(worst - score) < 1e-9, name .. ": наихудший критерий = score")
  end
  -- углов не три: разбор есть, критерий углов > 1, сторон нет
  local _, _, parts = triangle.detect(F.square)
  t.eq(type(parts), "table", "square: разбор")
  t.ok(parts.corners > 1, "square: corners=" .. tostring(parts.corners))
  t.eq(parts.side, nil)
  t.eq((select(3, triangle.detect({}))), nil, "пусто — разбора нет")
end

-- константа triangle.X, которую в triangle.lua никто не читает, — мёртвый порог
function T.test_every_constant_is_read()
  local f = assert(io.open("plugin/riddlediary.koplugin/riddle/triangle.lua"))
  local src = f:read("*a")
  f:close()
  local n = 0
  for key, v in pairs(triangle) do
    if type(v) == "number" and key:match("^[A-Z_]+$") then
      n = n + 1
      local _, uses = src:gsub("triangle%." .. key .. "%f[^%w_]", "")
      t.ok(uses >= 2, "triangle." .. key .. " не читается нигде, кроме определения")
    end
  end
  t.ok(n >= 10, "констант найдено " .. n)
end

function T.test_degenerate_input()
  t.eq((triangle.detect({})), false)
  t.eq((triangle.detect(nil)), false)
  t.eq((triangle.detect({ { p = { 10, 10 } } })), false)
  t.eq((triangle.detect({ { p = { 10, 10, 10, 10, 10, 10 } } })), false, "все точки в одной")
  t.eq((triangle.detect({ { p = { 10, 10, 200, 200, 400, 400, 10, 10 } } })), false, "все точки на прямой")
  local _, score = triangle.detect({ { p = {} } })
  t.eq(type(score), "number")
end

-- исписанная страница: сразу false, без перебора
function T.test_many_strokes_not_triangle()
  local s = {}
  for i = 1, 400 do s[i] = F.equilateral[1] end
  local t0 = os.clock()
  t.eq((triangle.detect(s)), false, "400 штрихов")
  t.ok(os.clock() - t0 < 0.05, "400 штрихов разобраны сразу")
  t.eq((triangle.detect({ F.equilateral[1], F.equilateral[1], F.equilateral[1] })), false, "3 штриха — больше MAX_STROKES")
end

t.run(T)
