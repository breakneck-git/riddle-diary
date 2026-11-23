-- Синтетические штрихи для triangle.detect: формат штриха виджета — { p = { x1, y1, x2, y2, … } }, экранные пиксели
-- PW2 (758 × 1024). Дрожание пальца — детерминированное (своё ЛКГ), без math.random.
-- Треугольник — одна замкнутая линия с тремя углами (спека 2026-11-19, подход А); линия может прерваться один раз.
-- Не-треугольники — то, что пишут и рисуют на странице и что на треугольник похоже.
local F = {}

local seed = 20261119
local function jitter(a)
  seed = (seed * 1103515245 + 12345) % 2147483648
  return (seed % 1000) / 1000 * 2 * a - a
end

-- ломаная по вершинам { {x,y}, … }, точки через ~6 px, дрожание j px -> плоский список p
local function walk(vs, j)
  local p = {}
  for k = 1, #vs - 1 do
    local a, b = vs[k], vs[k + 1]
    local n = math.max(2, math.floor(math.max(math.abs(b[1] - a[1]), math.abs(b[2] - a[2])) / 6))
    for i = (k == 1) and 0 or 1, n do
      p[#p + 1] = math.floor(a[1] + (b[1] - a[1]) * i / n + jitter(j) + 0.5)
      p[#p + 1] = math.floor(a[2] + (b[2] - a[2]) * i / n + jitter(j) + 0.5)
    end
  end
  return p
end

local function stroke(vs, j) return { p = walk(vs, j or 3) } end

local function lerp(a, b, f) return { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f } end

-- вершины, повёрнутые на deg вокруг (cx, cy)
local function rotate(vs, deg, cx, cy)
  local r, out = math.rad(deg), {}
  for i, v in ipairs(vs) do
    local x, y = v[1] - cx, v[2] - cy
    out[i] = { cx + x * math.cos(r) - y * math.sin(r), cy + x * math.sin(r) + y * math.cos(r) }
  end
  return out
end

-- скруглить каждый угол замкнутой ломаной (последняя вершина = первая): дуга-Безье от r px до угла к r px после
local function rounded(vs, r)
  local out = {}
  local n = #vs - 1
  for k = 1, n do
    local prev, v, nxt = vs[(k - 2) % n + 1], vs[k], vs[k % n + 1]
    local la, lb = math.sqrt((v[1] - prev[1]) ^ 2 + (v[2] - prev[2]) ^ 2), math.sqrt((nxt[1] - v[1]) ^ 2 + (nxt[2] - v[2]) ^ 2)
    local a, b = lerp(v, prev, r / la), lerp(v, nxt, r / lb)
    for i = 0, 6 do
      local f = i / 6
      local p = lerp(lerp(a, v, f), lerp(v, b, f), f)
      out[#out + 1] = p
    end
  end
  out[#out + 1] = out[1]
  return out
end

-- дуга: центр, радиусы, от a0 до a1 градусов, шаг ~5°
local function arc(cx, cy, rx, ry, a0, a1, j)
  local vs = {}
  local n = math.max(2, math.floor(math.abs(a1 - a0) / 5))
  for i = 0, n do
    local a = math.rad(a0 + (a1 - a0) * i / n)
    vs[#vs + 1] = { cx + rx * math.cos(a), cy + ry * math.sin(a) }
  end
  return stroke(vs, j)
end

local A, B, C = { 380, 300 }, { 560, 612 }, { 200, 612 } -- равносторонний, сторона 360

-- треугольники ----------------------------------------------------------------------------------------------------

F.equilateral = { stroke({ A, B, C, A }) }
F.obtuse_106 = { stroke({ { 150, 700 }, { 650, 700 }, { 330, 520 }, { 150, 700 } }) }
F.right_ccw = { stroke({ { 200, 700 }, { 200, 350 }, { 550, 700 }, { 200, 700 } }) }
F.tilted_37 = { stroke(rotate({ A, B, C, A }, 37, 380, 508)) }
-- стык на середине стороны: штрих начат и кончен посреди AB
F.start_mid_side = { stroke({ lerp(A, B, 0.5), B, C, A, lerp(A, B, 0.5) }) }
F.rounded_corners = { stroke(rounded({ A, B, C, A }, 25)) }
-- не дотянул: конец не дошёл до начала на ~8% периметра (85 px из 1080)
F.gap_8 = { stroke({ A, B, C, lerp(C, A, 0.76) }) }
-- перетянул: конец ушёл за начало на 10% стороны AB
F.overshoot_10 = { stroke({ A, B, C, A, lerp(A, B, 0.1) }) }
-- линия прервалась на середине BC: два штриха
F.two_strokes = { stroke({ A, B, lerp(B, C, 0.5) }), stroke({ lerp(B, C, 0.52), C, A }) }
F.wobbly = { stroke({ A, B, C, A }, 7) }
-- росчерк наружу после замыкания (палец срывается): как перетянутый конец — отрезается
F.flick_tail = { stroke({ A, B, C, A, { 300, 220 } }) }

-- сторона BC с изломом (рука дрогнула): поворот в изломе ~40° — меньше угла (CORNER_MIN), не четвёртый угол
F.kinked_side = (function()
  local k = lerp(B, C, 0.25)
  return { stroke({ A, B, { k[1], k[2] + 60 }, C, A }) }
end)()

-- обрыв на BC, перо село на 20% стороны дальше (72 px): склейка у угла A, дыра — зазор стыка (6.7% < GAP)
F.two_strokes_far = { stroke({ A, B, lerp(B, C, 0.5) }), stroke({ lerp(B, C, 0.7), C, A }) }

F.TRIANGLES = { "equilateral", "obtuse_106", "right_ccw", "tilted_37", "start_mid_side", "rounded_corners", "gap_8",
                "overshoot_10", "two_strokes", "wobbly", "flick_tail", "kinked_side", "two_strokes_far" }

-- не треугольники -------------------------------------------------------------------------------------------------

F.square = { stroke({ { 200, 300 }, { 550, 300 }, { 550, 650 }, { 200, 650 }, { 200, 300 } }) }
F.pentagon = (function()
  local vs = {}
  for i = 0, 5 do
    local a = math.rad(-90 + 72 * i)
    vs[#vs + 1] = { 380 + 200 * math.cos(a), 500 + 200 * math.sin(a) }
  end
  return { stroke(vs) }
end)()
F.trapezoid = { stroke({ { 300, 400 }, { 460, 400 }, { 580, 650 }, { 180, 650 }, { 300, 400 } }) }
-- галочка и крыша: две стороны без третьей
F.v_open = { stroke({ { 200, 300 }, { 380, 700 }, { 560, 300 } }) }
F.lambda_open = { stroke({ { 200, 700 }, { 380, 300 }, { 560, 700 } }) }
-- «А»: крыша и перекладина
F.letter_a = { stroke({ { 220, 700 }, { 380, 300 }, { 540, 700 } }), stroke({ { 290, 540 }, { 470, 540 } }) }
-- «Д»: трапеция сверху, основание с ножками
F.letter_de = { stroke({ { 340, 420 }, { 300, 650 }, { 480, 650 }, { 440, 420 }, { 340, 420 } }),
                stroke({ { 260, 720 }, { 270, 650 }, { 510, 650 }, { 520, 720 } }) }
-- «4»: уголок и вертикаль; крупная — чтобы держал не размер, а прыжок между штрихами
F.digit_4 = { stroke({ { 430, 250 }, { 230, 650 }, { 560, 650 } }), stroke({ { 470, 350 }, { 470, 850 } }) }
-- закрытая «4» (ревью среза 2): уголок замкнут вертикалью, хвосты вертикали ~20% длины — не треугольник
F.digit_4_closed = { stroke({ { 470, 250 }, { 470, 850 } }), stroke({ { 470, 250 }, { 230, 650 }, { 560, 650 } }) }
F.digit_4_closed_one = { stroke({ { 470, 850 }, { 470, 250 }, { 230, 650 }, { 560, 650 } }) }
-- вертикаль 500: ниже перекладины 100 px
F.digit_4_closed_500 = { stroke({ { 470, 250 }, { 470, 750 } }), stroke({ { 470, 250 }, { 230, 650 }, { 560, 650 } }) }
-- знак угла «∠» двумя штрихами: основание и наклонная из его левого конца. Склейка через прыжок от правого конца
-- основания к верху наклонной дала бы третью сторону — прыжок больше JUMP
F.angle_sign = { stroke({ { 200, 700 }, { 560, 700 } }), stroke({ { 200, 698 }, { 500, 350 } }) }
-- недотянул на полстороны CA: зазор больше GAP, обрезано мало
F.gap_half_side = { stroke({ A, B, C, lerp(C, A, 0.5) }) }
-- △ размером с букву в слове
F.small_triangle = { stroke({ { 380, 500 }, { 410, 552 }, { 350, 552 }, { 380, 500 } }, 1) }
-- △ 120 px: крупная буква, ещё не знак (меньшая сторона описанного прямоугольника ~104 px < SIZE)
F.triangle_120 = { stroke({ { 380, 500 }, { 440, 604 }, { 320, 604 }, { 380, 500 } }, 1) }
F.circle = { arc(380, 500, 180, 175, 0, 360, 3) }
F.eight = (function()
  local vs = {}
  for i = 0, 72 do
    local a = math.rad(i * 5)
    vs[#vs + 1] = { 380 + 180 * math.sin(a), 500 + 220 * math.sin(a) * math.cos(a) }
  end
  return { stroke(vs) }
end)()
-- одна сторона выгнута дугой (как «D» на боку): два угла и дуга
F.bulged_side = (function()
  local vs = { C, A, B }
  for i = 1, 12 do
    local f = i / 12
    local p = lerp(B, C, f)
    vs[#vs + 1] = { p[1], p[2] + 110 * math.sin(math.pi * f) }
  end
  return { stroke(vs) }
end)()
-- игла под 45°: стороны 400, 400, ~60 — углы у основания сливаются в один
F.needle_45 = { stroke(rotate({ { 380, 300 }, { 410, 700 }, { 350, 700 }, { 380, 300 } }, 45, 380, 500)) }
-- лучина под 45°: стороны ~404, ~404, 110 — три угла, но основание короче доли периметра
F.sliver_45 = { stroke(rotate({ { 380, 300 }, { 435, 700 }, { 325, 700 }, { 380, 300 } }, 45, 380, 500)) }
F.zigzag = { stroke({ { 200, 300 }, { 560, 300 }, { 200, 700 }, { 560, 700 } }) }

F.NON_TRIANGLES = { "square", "pentagon", "trapezoid", "v_open", "lambda_open", "letter_a", "letter_de", "digit_4",
                    "digit_4_closed", "digit_4_closed_one", "digit_4_closed_500", "angle_sign", "gap_half_side",
                    "small_triangle",
                    "triangle_120",
                    "circle", "eight", "bulged_side", "needle_45", "sliver_45", "zigzag" }

return F
