-- Геометрия штриха, общая для знаков пером (роза, треугольник): riddle.pen. Поведение роз на этих хелперах
-- закреплено tests/rose_spec.lua; здесь — контракт каждого хелпера.
local t = require("t")
local pen = require("riddle.pen")

local T = {}

local EPS = 1e-6

local function near(a, b, msg) t.ok(math.abs(a - b) < EPS, (msg or "near") .. ": " .. tostring(a) .. " ≠ " .. tostring(b)) end

function T.test_points_pairs_flat_list()
  local p = pen.points({ p = { 1, 2, 3, 4, 5 } })
  t.eq(#p, 2, "нечётный хвост отброшен")
  t.eq(p[1][1], 1) t.eq(p[1][2], 2) t.eq(p[2][1], 3) t.eq(p[2][2], 4)
  t.eq(#pen.points({}), 0, "штрих без p")
end

function T.test_bounds_box_of_points()
  local x0, y0, x1, y1 = pen.bounds({ { 3, -1 }, { -2, 4 }, { 5, 2 } })
  t.eq(x0, -2) t.eq(y0, -1) t.eq(x1, 5) t.eq(y1, 4)
  x0, y0, x1, y1 = pen.bounds({ { 7, 9 } })
  t.eq(x0, 7) t.eq(y0, 9) t.eq(x1, 7) t.eq(y1, 9)
end

function T.test_bounds_empty_has_no_box()
  local x0, y0, x1, y1 = pen.bounds({})
  t.eq(x0, math.huge) t.eq(y0, math.huge) t.eq(x1, -math.huge) t.eq(y1, -math.huge)
end

function T.test_dist()
  near(pen.dist({ 0, 0 }, { 3, 4 }), 5)
end

function T.test_reversed_is_a_copy()
  local a = { { 1, 1 }, { 2, 2 }, { 3, 3 } }
  local r = pen.reversed(a)
  t.eq(r[1], a[3]) t.eq(r[3], a[1])
  t.eq(a[1][1], 1, "исходный список не тронут")
end

function T.test_length()
  near(pen.length({ { 0, 0 }, { 3, 4 }, { 3, 10 } }), 11)
  t.eq(pen.length({ { 1, 1 } }), 0)
  t.eq(pen.length({}), 0)
end

-- два штриха склеиваются всеми четырьмя способами: каждый в своём или обратном направлении; jump — прыжок пера
-- от конца первого к началу второго
function T.test_joins()
  local a, b = { { 0, 0 }, { 10, 0 } }, { { 10, 5 }, { 30, 5 } }
  local js = pen.joins(a, b)
  t.eq(#js, 4)
  local seen = {}
  for _, j in ipairs(js) do
    t.eq(#j.list, 4)
    local key = table.concat({ j.list[1][1], j.list[2][1], j.list[3][1], j.list[4][1] }, ",")
    seen[key] = j.jump
  end
  near(seen["0,10,10,30"], 5, "a + b")
  near(seen["0,10,30,10"], pen.dist({ 10, 0 }, { 30, 5 }), "a + b задом")
  near(seen["10,0,10,30"], pen.dist({ 0, 0 }, { 10, 5 }), "a задом + b")
  near(seen["10,0,30,10"], pen.dist({ 0, 0 }, { 30, 5 }), "оба задом")
  t.eq(a[1][1], 0, "исходные не тронуты")
end

function T.test_resample_count_and_ends()
  local line = { { 0, 0 }, { 10, 0 }, { 10, 30 } }
  local s = pen.resample(line, 9)
  t.eq(#s, 9)
  near(s[1][1], 0) near(s[1][2], 0)
  near(s[9][1], 10) near(s[9][2], 30)
  -- равные отрезки: длина 40, шаг 5
  for i = 2, #s do near(pen.dist(s[i - 1], s[i]), 5, "шаг " .. i) end
end

function T.test_resample_zero_length()
  t.eq(pen.resample({ { 5, 5 }, { 5, 5 } }, 4), nil)
end

function T.test_percentile()
  local s = { 1, 2, 3, 4, 5 }
  t.eq(pen.percentile(s, 0), 1)
  t.eq(pen.percentile(s, 1), 5)
  t.eq(pen.percentile(s, 0.5), 3)
end

function T.test_turn()
  local s = { { 0, 0 }, { 10, 0 }, { 10, 10 }, { 20, 10 }, { 30, 10 } }
  near(pen.turn(s, 2, 1), math.pi / 2, "прямой угол")
  near(pen.turn(s, 4, 1), 0, "прямая")
  local back = { { 0, 0 }, { 10, 0 }, { 0, 0 } }
  near(pen.turn(back, 2, 1), math.pi, "разворот")
end

function T.test_bend()
  local straight = {}
  for i = 0, 20 do straight[#straight + 1] = { i * 10, i * 5 } end
  local seg, dev = pen.bend(straight, 41, 0.1)
  t.ok(seg, "прямая — черта")
  t.ok(dev < EPS, "прямая не изогнута: " .. tostring(dev))
  near(seg.len, pen.dist(straight[1], straight[#straight]))
  local arc = {}
  for i = 0, 18 do
    local a = math.rad(i * 5)
    arc[#arc + 1] = { 100 * math.cos(a), 100 * math.sin(a) }
  end
  local _, adev = pen.bend(arc, 41, 0.1)
  t.ok(adev > 0.1, "дуга 90° изогнута: " .. tostring(adev))
  t.eq(pen.bend({ { 1, 1 } }, 41, 0.1), nil, "одна точка")
  t.eq(pen.bend({ { 1, 1 }, { 1.5, 1 } }, 41, 0.1), nil, "короче пикселя")
end

t.run(T)
