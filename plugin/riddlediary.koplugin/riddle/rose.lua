-- Роза ветров пальцем: круг и две почти прямые черты накрест внутри него (план карты, решения, п.1). Чистая функция
-- без KOReader. Штрих — формат виджета { p = { x1, y1, x2, y2, … } }; порядок штрихов и их направление не важны.
-- Пороги — константы rose.*, подобраны по 12 живым розам владельца (2026-11-16, tests/fixtures/rose_owner.lua):
-- его максимум + запас; лог devmode «riddle: rose yes|no score=…» даёт каждый критерий долей порога.
local rose = {}

rose.SPREAD = 0.45     -- радиусы в осях овала: (95-й перцентиль − 5-й) / средний ≤ (владелец до 0.39)
rose.SWEEP = 300       -- обход вокруг центра, градусы ≥ (владелец от 366: его концы заходят друг за друга)
rose.LAP = 180         -- перехлёст сверх оборота, градусы ≤ (владелец до 105; спираль в два витка — 360)
rose.SIZE = 150        -- круг не мельче: средний диаметр, px ≥ (владелец от 262; буквы, клетка-чекбокс)
rose.OVAL = 1.8        -- овал не уже: большая ось / малая ≤ (владелец до 1.59)
rose.CORNER = 3.2      -- углов нет: поворот на 1/16 оборота ≤ стольких поворотов круга (владелец до 2.89, квадрат — 4)
rose.BEND = 0.12       -- черта почти прямая: отклонение средних 80% точек от их хорды ≤ доли её длины (владелец до 0.04)
rose.LENGTH = 0.6      -- черта длиной ≥ доли диаметра круга
rose.ANGLE_MIN = 60    -- черты пересекаются под углом ≥, градусы (угол между прямыми 0..90, верхней границы нет)
rose.EXTRA = 1         -- прочих штрихов (неровный росчерк) ≤
rose.SAMPLES = 96      -- точек круга после передискретизации по длине (скорость пальца не смещает центр)
rose.CORNER_STEPS = 16 -- хорд угла на оборот: поворот меряется между соседними хордами в 1/CORNER_STEPS оборота
rose.CORNER_SKIP = 0.05 -- доля точек круга с каждого конца, не входящая в поиск угла (палец садится и срывается)
rose.BAR_SAMPLES = 41  -- точек черты после передискретизации по длине
rose.BAR_TRIM = 0.1    -- доля длины черты с каждого конца, не входящая в изогнутость (росчерк на концах)

-- критерии разбора (rose.detect, третье значение) в порядке лога: круг, потом черты
rose.CRITERIA = { "spread", "sweep", "lap", "size", "oval", "corner", "bend", "inside", "tilt", "short" }

-- штрихов у розы не больше: круг до двух дуг, две черты, прочие
rose.MAX_STROKES = 2 + 2 + rose.EXTRA

local MISS = 9.99      -- score «кандидата нет»

local pen = require("riddle.pen")
local resample, percentile = pen.resample, pen.percentile

-- центр окружности по точкам — МНК для x² + y² + Dx + Ey + F = 0 (Kåsa): не смещается к дуге незамкнутого круга,
-- как центр масс, и для овала — его центр. nil — точки на одной прямой
local function fitCenter(s)
  local mx, my = 0, 0
  for _, q in ipairs(s) do mx, my = mx + q[1], my + q[2] end
  mx, my = mx / #s, my / #s
  local uu, vv, uv, uuu, vvv, uvv, vuu = 0, 0, 0, 0, 0, 0, 0
  for _, q in ipairs(s) do
    local u, v = q[1] - mx, q[2] - my
    uu, vv, uv = uu + u * u, vv + v * v, uv + u * v
    uuu, vvv, uvv, vuu = uuu + u * u * u, vvv + v * v * v, uvv + u * v * v, vuu + v * u * u
  end
  local det = uu * vv - uv * uv
  if det <= 1e-9 * (uu + vv) ^ 2 then return nil end
  local bu, bv = (uuu + uvv) / 2, (vvv + vuu) / 2
  return mx + (bu * vv - bv * uv) / det, my + (bv * uu - bu * uv) / det
end

-- круг? -> { c = центр, r = средний радиус, d = диаметр, norm = радиус точки в долях круга (по овалу),
-- parts = { spread, sweep, oval, corner } }, оценка (≤ 1 — годен); parts — каждый критерий долей своего порога.
-- Важна форма, не замыкание (владелец 2026-11-16): концы могут не сойтись и зайти друг за друга, круг — овал
local function shape(s, total)
  local cx, cy = fitCenter(s)
  if not cx then return nil, MISS end
  -- овал: главные оси разброса точек вокруг центра; радиус точки меряется в осях овала
  local xx, yy, xy, mean = 0, 0, 0, 0
  for _, q in ipairs(s) do
    local u, v = q[1] - cx, q[2] - cy
    xx, yy, xy = xx + u * u, yy + v * v, xy + u * v
    mean = mean + math.sqrt(u * u + v * v)
  end
  mean = mean / #s
  if mean < 1 then return nil, MISS end
  local half = (xx + yy) / 2
  local disc = math.sqrt(math.max(0, half * half - (xx * yy - xy * xy)))
  local l1, l2 = half + disc, half - disc
  if l2 <= 0 then return nil, MISS end
  local ex, ey = 1, 0
  if math.abs(xy) > 1e-9 then
    ex, ey = xy, l1 - xx
    local n = math.sqrt(ex * ex + ey * ey)
    ex, ey = ex / n, ey / n
  elseif yy > xx then
    ex, ey = 0, 1
  end
  local k1, k2 = 1 / math.sqrt(l1), 1 / math.sqrt(l2)
  local function rho(p)
    local u, v = p[1] - cx, p[2] - cy
    local a, b = (u * ex + v * ey) * k1, (v * ex - u * ey) * k2
    return math.sqrt(a * a + b * b)
  end
  local radii, rmean = {}, 0
  for i, q in ipairs(s) do
    radii[i] = rho(q)
    rmean = rmean + radii[i]
  end
  rmean = rmean / #s
  table.sort(radii)
  local spread = (percentile(radii, 0.95) - percentile(radii, 0.05)) / rmean
  local sweep, a0 = 0, math.atan2(s[1][2] - cy, s[1][1] - cx)
  for i = 2, #s do
    local a = math.atan2(s[i][2] - cy, s[i][1] - cx)
    local da = a - a0
    if da > math.pi then da = da - 2 * math.pi elseif da < -math.pi then da = da + 2 * math.pi end
    sweep, a0 = sweep + da, a
  end
  sweep = math.abs(math.deg(sweep))
  -- угол: поворот между соседними хордами в 1/CORNER_STEPS оборота; у круга 360/CORNER_STEPS (22.5°), у угла
  -- квадрата — 90°. Концы штриха (палец садится и срывается) не в счёт
  local k = math.max(2, math.floor(#s * 360 / math.max(sweep, 1) / rose.CORNER_STEPS + 0.5))
  local skip, turn = math.floor(#s * rose.CORNER_SKIP), 0
  for i = 1 + k + skip, #s - k - skip do
    turn = math.max(turn, pen.turn(s, i, k))
  end
  local parts = {
    spread = spread / rose.SPREAD,
    sweep = rose.SWEEP / math.max(total, 1),
    lap = math.max(0, total - 360) / rose.LAP,
    size = rose.SIZE / (2 * mean),
    oval = math.sqrt(l1 / l2) / rose.OVAL,
    corner = math.deg(turn) / (360 / rose.CORNER_STEPS) / rose.CORNER,
  }
  local score = math.max(parts.spread, parts.sweep, parts.lap, parts.size, parts.oval, parts.corner)
  return { c = { cx, cy }, r = mean, d = 2 * mean, parts = parts, norm = function(p) return rho(p) / rmean end }, score
end

-- обход вокруг центра по точкам -> накопленный угол в каждой точке, градусы со знаком
local function turns(s, cx, cy)
  local cum, acc, a0 = { 0 }, 0, math.atan2(s[1][2] - cy, s[1][1] - cx)
  for i = 2, #s do
    local a = math.atan2(s[i][2] - cy, s[i][1] - cx)
    local da = a - a0
    if da > math.pi then da = da - 2 * math.pi elseif da < -math.pi then da = da + 2 * math.pi end
    acc, a0 = acc + da, a
    cum[i] = math.deg(acc)
  end
  return cum
end

-- круг больше оборота одним штрихом (перехлёст: у владельца хвост после оборота уходит внутрь круга) оценивается
-- по лучшему из двух оборотов — первому и последнему, обход — по всему штриху. Склейке двух штрихов (whole) хвост не
-- срезается: иначе круг с прилипшей к нему чертой сошёл бы за круг из двух дуг
local function circle(list, whole)
  local s = #list >= 3 and resample(list, rose.SAMPLES)
  if not s then return nil, MISS end
  local cx, cy = fitCenter(s)
  if not cx then return nil, MISS end
  local cum = turns(s, cx, cy)
  local total = math.abs(cum[#s])
  if total <= 360 or whole then return shape(s, total) end
  local first, last = #s, 1
  while first > 1 and math.abs(cum[first - 1]) >= 360 do first = first - 1 end
  while last < #s and math.abs(cum[#s] - cum[last + 1]) >= 360 do last = last + 1 end
  local best, bs = nil, MISS
  for _, w in ipairs({ { 1, first }, { last, #s } }) do
    local pts = {}
    for k = w[1], w[2] do pts[#pts + 1] = s[k] end
    local c, sc = shape(pts, total)
    if c and sc < bs then best, bs = c, sc end
  end
  return best, bs
end

-- черта: хорда концов и изогнутость -> { a, b, len }, оценка изогнутости (≤ 1 — прямая). Изогнутость — по средним
-- 80% длины: росчерк на концах (палец садится и срывается вбок) черту кривой не делает
local function bar(list)
  local seg, dev = pen.bend(list, rose.BAR_SAMPLES, rose.BAR_TRIM)
  if not seg then return nil, MISS end
  return seg, dev / rose.BEND
end

-- пересечение отрезков -> точка | nil
local function cross(u, v)
  local r = { u.b[1] - u.a[1], u.b[2] - u.a[2] }
  local s = { v.b[1] - v.a[1], v.b[2] - v.a[2] }
  local den = r[1] * s[2] - r[2] * s[1]
  if den == 0 then return nil end
  local qp = { v.a[1] - u.a[1], v.a[2] - u.a[2] }
  local tu = (qp[1] * s[2] - qp[2] * s[1]) / den
  local tv = (qp[1] * r[2] - qp[2] * r[1]) / den
  if tu < 0 or tu > 1 or tv < 0 or tv > 1 then return nil end
  return { u.a[1] + tu * r[1], u.a[2] + tu * r[2] }
end

-- две черты к кругу -> оценка (≤ 1 — роза), разбор { bend, inside, tilt, short } | nil (черты не пересеклись)
local function pair(circ, u, ub, v, vb)
  local p = cross(u, v)
  if not p then return MISS end
  local inside = circ.norm(p)
  local ang = math.deg(math.acos(math.min(1, math.abs(
    ((u.b[1] - u.a[1]) * (v.b[1] - v.a[1]) + (u.b[2] - u.a[2]) * (v.b[2] - v.a[2])) / (u.len * v.len)))))
  -- угол между прямыми 0..90: 90 — накрест; допуск ANGLE_MIN..ANGLE_MAX симметричен вокруг 90
  local tilt = (90 - ang) / (90 - rose.ANGLE_MIN)
  local short = rose.LENGTH * circ.d / math.min(u.len, v.len)
  local parts = { bend = math.max(ub, vb), inside = inside, tilt = tilt, short = short }
  return math.max(parts.bend, inside, tilt, short), parts
end

-- кандидаты в круг: каждый штрих и каждая пара штрихов, склеенная всеми четырьмя способами. Порога на зазор в
-- стыке нет: две дуги круга могут и разойтись, и зайти друг за друга (тогда в ближнем стыке — обратный ход), круг
-- ли это — решает форма (circle)
local function circles(strokes)
  local out = {}
  for i, s in ipairs(strokes) do
    out[#out + 1] = { used = { [i] = true }, list = s }
    for j = i + 1, #strokes do
      local t = strokes[j]
      if #s >= 2 and #t >= 2 then
        for _, join in ipairs(pen.joins(s, t)) do
          out[#out + 1] = { used = { [i] = true, [j] = true }, list = join.list, joined = true }
        end
      end
    end
  end
  return out
end

-- strokes -> роза ли, оценка лучшего кандидата (≤ 1 — все пороги пройдены; больше — во сколько раз хуже порога),
-- разбор этого кандидата по критериям (доли порогов: spread, sweep, oval, corner круга; bend, inside, tilt, short
-- черт) | nil.
-- Пары черт не нашлось — разбор лучшего круга, без критериев черт
function rose.detect(strokes)
  -- больше штрихов, чем у розы бывает (круг до двух дуг, две черты, прочие): перебор кандидатов квадратичен, а
  -- исписанная словами страница — десятки штрихов
  if #(strokes or {}) > rose.MAX_STROKES then return false, MISS end
  local list = {}
  for i, s in ipairs(strokes or {}) do list[i] = pen.points(s) end
  local best, why, round = MISS, nil, nil
  for _, cand in ipairs(circles(list)) do
    local circ, cs = circle(cand.list, cand.joined)
    if circ and (not round or cs < round.cs) then round = { cs = cs, parts = circ.parts } end
    if circ and cs < best then
      local rest = {}
      for i, s in ipairs(list) do
        if not cand.used[i] then rest[#rest + 1] = s end
      end
      if #rest >= 2 and #rest - 2 <= rose.EXTRA then
        for i = 1, #rest do
          local u, ub = bar(rest[i])
          for j = i + 1, u and #rest or 0 do
            local v, vb = bar(rest[j])
            if v then
              local ps, pp = pair(circ, u, ub, v, vb)
              local score = math.max(cs, ps)
              if pp and score < best then
                best, why = score, {}
                for k, x in pairs(circ.parts) do why[k] = x end
                for k, x in pairs(pp) do why[k] = x end
              end
            end
          end
        end
      end
    end
  end
  if not why and round then
    why = {}
    for k, x in pairs(round.parts) do why[k] = x end
  end
  return best <= 1, best, why
end

return rose
