-- Геометрия штриха пера, общая для знаков (riddle.rose, riddle.triangle). Чистые функции без KOReader.
-- Точка — { x, y }; штрих виджета — { p = { x1, y1, x2, y2, … } }. Пороги здесь не живут: их держит каждый знак.
local pen = {}

-- штрих виджета -> список точек
function pen.points(s)
  local out = {}
  local p = s.p or {}
  for i = 1, #p - 1, 2 do out[#out + 1] = { p[i], p[i + 1] } end
  return out
end

function pen.dist(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end

function pen.reversed(list)
  local out = {}
  for i = #list, 1, -1 do out[#out + 1] = list[i] end
  return out
end

-- длина ломаной
function pen.length(list)
  local total = 0
  for i = 2, #list do total = total + pen.dist(list[i - 1], list[i]) end
  return total
end

-- два штриха (списки точек) -> склейки всеми четырьмя способами (каждый — в своём или обратном направлении):
-- { { list, jump }, … }; jump — прыжок пера от конца первого к началу второго (0 — у пустого штриха)
function pen.joins(a, b)
  local out = {}
  for _, x in ipairs({ a, pen.reversed(a) }) do
    for _, y in ipairs({ b, pen.reversed(b) }) do
      local list = {}
      for _, q in ipairs(x) do list[#list + 1] = q end
      for _, q in ipairs(y) do list[#list + 1] = q end
      out[#out + 1] = { list = list, jump = (#x > 0 and #y > 0) and pen.dist(x[#x], y[1]) or 0 }
    end
  end
  return out
end

-- ломаная -> n точек через равные отрезки длины | nil (длина нулевая)
function pen.resample(list, n)
  local total = pen.length(list)
  if total == 0 then return nil end
  local out, step, acc, i = { list[1] }, total / (n - 1), 0, 2
  local prev = list[1]
  while #out < n and i <= #list do
    local d = pen.dist(prev, list[i])
    if acc + d >= step and d > 0 then
      local f = (step - acc) / d
      prev = { prev[1] + (list[i][1] - prev[1]) * f, prev[2] + (list[i][2] - prev[2]) * f }
      out[#out + 1] = prev
      acc = 0
    else
      acc = acc + d
      prev = list[i]
      i = i + 1
    end
  end
  if #out < n then out[#out + 1] = list[#list] end
  return out
end

-- отсортированный список -> значение квантиля q (0..1), ближайший ранг
function pen.percentile(sorted, q)
  return sorted[math.max(1, math.min(#sorted, math.floor(q * (#sorted - 1) + 1.5)))]
end

-- поворот в точке i между хордами s[i-k]→s[i] и s[i]→s[i+k], радианы 0..π. Индексы i-k и i+k — в пределах s
-- (замкнутую линию вызывающий разворачивает сам)
function pen.turn(s, i, k)
  local p, q, r = s[i - k], s[i], s[i + k]
  local d1 = math.atan2(q[2] - p[2], q[1] - p[1])
  local d2 = math.atan2(r[2] - q[2], r[1] - q[1])
  local da = math.abs(d2 - d1)
  if da > math.pi then da = 2 * math.pi - da end
  return da
end

-- черта: хорда концов и изогнутость -> { a, b, len }, отклонение | nil. Отклонение — наибольшее расстояние точек
-- средней части (без доли trim длины с каждого конца: палец садится и срывается вбок) от их хорды, долей её длины;
-- ломаная передискретизуется до samples точек
function pen.bend(list, samples, trim)
  if #list < 2 then return nil end
  local a, b = list[1], list[#list]
  local len = pen.dist(a, b)
  if len < 1 then return nil end
  local s = pen.resample(list, samples)
  if not s then return nil end
  local lo, hi = 1 + math.floor(#s * trim), #s - math.floor(#s * trim)
  local p, q = s[lo], s[hi]
  local mid = pen.dist(p, q)
  if mid < 1 then return nil end
  local dev = 0
  for i = lo, hi do
    local h = math.abs((q[1] - p[1]) * (p[2] - s[i][2]) - (p[1] - s[i][1]) * (q[2] - p[2])) / mid
    if h > dev then dev = h end
  end
  return { a = a, b = b, len = len }, dev / mid
end

return pen
