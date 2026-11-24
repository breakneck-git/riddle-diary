-- Треугольник пером: одна замкнутая линия с тремя углами (спека 2026-11-19-status-triangle, подход А) — открывает
-- страницу состояния Kindle. Чистая функция без KOReader, на общей с розой геометрии (riddle.pen). Штрих — формат
-- виджета { p = { x1, y1, x2, y2, … } }; линия может прерваться один раз, порядок штрихов и направление не важны.
-- Ложное срабатывание хуже пропуска: пороги — с запасом против букв и рисунков (tests/fixtures/triangle_strokes.lua,
-- фикстуры розы); подстройка по руке владельца — по devmode-логу «riddle: triangle yes|no score=…», как у розы.
local pen = require("riddle.pen")

local triangle = {}

triangle.SAMPLES = 96       -- точек замкнутой линии после передискретизации по длине
triangle.ENDS = 0.25        -- доля длины с каждого конца, где ищется стык: недотянул, перетянул, росчерк на концах
triangle.TRIM = 0.13        -- отрезанное стыком (оба хвоста) ≤ доли длины линии (росчерк до 0.095; хвосты закрытой «4» ~0.2)
triangle.GAP = 0.15         -- зазор в стыке ≤ доли периметра
triangle.JUMP = 0.05        -- прыжок пера в обрыве линии ≤ доли периметра (перо снова садится рядом)
triangle.CORNER_STEPS = 16  -- хорд угла на оборот: поворот меряется между хордами в 1/CORNER_STEPS периметра
triangle.CORNER_MIN = 50    -- угол — поворот линии ≥, градусы (у тупого угла в 120° поворот 60°; у круга 22.5°)
triangle.BEND = 0.15        -- сторона почти прямая: отклонение средней части от хорды ≤ доли её длины
triangle.SIDE_SAMPLES = 25  -- точек стороны после передискретизации
triangle.SIDE_TRIM = 0.15   -- доля стороны с каждого конца, не входящая в изогнутость (скругление угла)
triangle.SIDE = 0.15        -- сторона не короче доли периметра (игла — не треугольник)
triangle.SIZE = 150         -- меньшая сторона описанного прямоугольника, px ≥ (буквы в слове мельче)

-- критерии разбора (triangle.detect, третье значение) в порядке лога
triangle.CRITERIA = { "gap", "trim", "corners", "bend", "side", "size" }

-- штрихов у треугольника не больше: линия и один её обрыв
triangle.MAX_STROKES = 2

local MISS = 9.99 -- score «кандидата нет»

-- стык: пара точек — одна в начальной доле ENDS, другая в конечной — с наименьшим зазором; линия между ними и есть
-- контур (перетянутый хвост и росчерк на концах отрезаются; сколько отрезано — критерий trim). -> контур, зазор
local function cut(s)
  local n = #s
  local head, tail = math.floor(n * triangle.ENDS) + 1, n - math.floor(n * triangle.ENDS)
  local bi, bj, bd = 1, n, math.huge
  for i = 1, head do
    for j = tail, n do
      local d = pen.dist(s[i], s[j])
      if d < bd then bi, bj, bd = i, j, d end
    end
  end
  local out = {}
  for k = bi, bj do out[#out + 1] = s[k] end
  return out, bd
end

-- одна линия -> оценка (≤ 1 — треугольник), разбор. jump — прыжок пера в обрыве (склейка двух штрихов): входит в
-- критерий стыка со своим порогом, иначе крыша «А» с перекладиной, крест или «4» склеились бы в треугольник прыжком
local function shape(list, jump)
  if #list < 3 then return MISS end
  local s = pen.resample(list, triangle.SAMPLES)
  if not s then return MISS end
  local outline, gap = cut(s)
  local kept = pen.length(outline)
  local perimeter = kept + gap
  if perimeter < 1 then return MISS end
  -- закрытая «4» (ревью среза 2): стык срезает хвосты вертикали, остаток — треугольник; хвостов больше росчерка —
  -- не знак
  local trimmed = 1 - kept / pen.length(s)
  outline[#outline + 1] = outline[1]
  local c = pen.resample(outline, triangle.SAMPLES + 1)
  if not c then return MISS end
  c[#c] = nil
  local n = #c
  local x0, y0, x1, y1 = pen.bounds(c)
  local parts = {
    gap = math.max((gap / perimeter) / triangle.GAP, (jump / perimeter) / triangle.JUMP),
    trim = trimmed / triangle.TRIM,
    size = triangle.SIZE / math.max(math.min(x1 - x0, y1 - y0), 1),
  }
  -- поворот в каждой точке по кругу: замкнутая линия, стык может прийтись на середину стороны
  local k = math.max(1, math.floor(n / triangle.CORNER_STEPS + 0.5))
  local function at(i) return c[(i - 1) % n + 1] end
  local turn = {}
  for i = 1, n do turn[i] = pen.turn({ at(i - k), c[i], at(i + k) }, 2, 1) end
  -- углы: поворот ≥ CORNER_MIN и наибольший в окне ±k (из равных — первый)
  local min_turn = math.rad(triangle.CORNER_MIN)
  local corners = {}
  for i = 1, n do
    local peak = turn[i] >= min_turn
    for d = 1, k do
      if not peak then break end
      local before, after = turn[(i - 1 - d) % n + 1], turn[(i - 1 + d) % n + 1]
      peak = turn[i] > before and turn[i] >= after
    end
    if peak then corners[#corners + 1] = i end
  end
  if #corners ~= 3 then
    parts.corners = 1 + math.abs(#corners - 3)
  else
    local weakest = math.huge
    for _, i in ipairs(corners) do weakest = math.min(weakest, turn[i]) end
    parts.corners = min_turn / weakest
    -- стороны между соседними углами
    local bend, share = 0, math.huge
    for m = 1, 3 do
      local from, to = corners[m], corners[m % 3 + 1]
      if to <= from then to = to + n end
      local side = {}
      for i = from, to do side[#side + 1] = at(i) end
      local seg, dev = pen.bend(side, triangle.SIDE_SAMPLES, triangle.SIDE_TRIM)
      bend = math.max(bend, seg and dev / triangle.BEND or MISS)
      share = math.min(share, pen.length(side) / perimeter)
    end
    parts.bend = bend
    parts.side = triangle.SIDE / math.max(share, 1e-9)
  end
  local score = 0
  for _, key in ipairs(triangle.CRITERIA) do
    if parts[key] then score = math.max(score, parts[key]) end
  end
  return score, parts
end

-- strokes -> треугольник ли, оценка лучшего кандидата (≤ 1 — все пороги пройдены; больше — во сколько раз хуже
-- порога), разбор этого кандидата по критериям (доли порогов) | nil
function triangle.detect(strokes)
  strokes = strokes or {}
  -- штрихов больше, чем у треугольника бывает (MAX_STROKES = 2), — сразу false: лишний штрих не отбрасывается
  -- молча, страница с треугольником и словом рядом — не знак
  if #strokes == 0 or #strokes > triangle.MAX_STROKES then return false, MISS end
  local lists = {}
  for i, s in ipairs(strokes) do lists[i] = pen.points(s) end
  -- кандидаты: сама линия; оборванная — два штриха, склеенные всеми четырьмя способами
  local cands = #lists == 1 and { { list = lists[1], jump = 0 } } or pen.joins(lists[1], lists[2])
  local best, why = MISS, nil
  for _, cand in ipairs(cands) do
    local score, parts = shape(cand.list, cand.jump)
    if parts and (not why or score < best) then best, why = score, parts end
  end
  return best <= 1, best, why
end

return triangle
