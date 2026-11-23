-- Значки угла (спека 2026-11-19-corner-icons): факты (время, заряд, Wi‑Fi), тик по минуте и геометрия значков.
-- Чистые функции: источники и измеритель текста внедряет вызывающий, KOReader не нужен. Каждый источник — в pcall:
-- упал или ответил не тем — поля нет, значок/текст не рисуется, сбор не падает.
-- Граф require: tray -> status -> str; status уже держит правило батареи и тире, свой общий модуль ради двух имён не нужен.
local status = require("riddle.status")

local tray = {}

local function num(v) return type(v) == "number" and v == v and v or nil end

-- src.clock() -> {hour, min, sec}, src.power() -> {pct, charging}, src.net() -> "up"|"down"|"off"
function tray.facts(src)
  local f = { charging = false, wifi = false }
  local ok, c = pcall(src.clock)
  if ok and type(c) == "table" and num(c.hour) and num(c.min) then
    f.hm = string.format("%d:%02d", c.hour, c.min)
    f.sec = num(c.sec) and math.floor(c.sec) or nil
  end
  local okp, p = pcall(src.power)
  if okp and type(p) == "table" then
    local b = status.battery(p) -- то же правило, что у страницы состояния
    if b then f.pct, f.charging = b.pct, b.charging end
  end
  local okn, n = pcall(src.net)
  f.wifi = okn and n == "up"
  return f
end

-- Секунд до начала следующей минуты, всегда в [1, 60]; без секунд — 60.
function tray.next_tick_s(f)
  local s = f and num(f.sec)
  if not s then return 60 end
  return math.max(1, math.min(60, 60 - math.floor(s)))
end

-- Одной строкой для лога: «21:40 87%+ wifi».
function tray.describe(f)
  local dash = status.DASH
  return string.format("%s %s%s %s", f.hm or (dash .. ":" .. dash), f.pct and (f.pct .. "%") or (dash .. "%"), f.charging and "+" or "",
    f.wifi and "wifi" or "nowifi")
end

function tray.union(a, b)
  if not a then return b end
  if not b then return a end
  local x0, y0 = math.min(a.x, b.x), math.min(a.y, b.y)
  local x1, y1 = math.max(a.x + a.w, b.x + b.w), math.max(a.y + a.h, b.y + b.h)
  return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Дуга радиуса r от 45° до 135° вокруг (cx, cy); точки — целые пиксели (paintRect не получает дробей), шаг дуги
-- меньше 1 px: после округления соседние точки расходятся не больше чем на 1 px по каждой оси.
local function arc(cx, cy, r)
  local a0, a1 = math.pi / 4, 3 * math.pi / 4
  local n = math.ceil(r * (a1 - a0)) + 1
  local p = {}
  for i = 0, n do
    local a = a0 + (a1 - a0) * i / n
    p[#p + 1] = math.floor(cx + r * math.cos(a) + 0.5)
    p[#p + 1] = math.floor(cy - r * math.sin(a) + 0.5)
  end
  return p
end

-- at = {right, base, asc, reach}: правый край, базовая линия (низ значков и цифр), асцендер цифр, запас вокруг цифр под
-- свесы глифов (reach, по умолчанию 0; вызывающий берёт layout.text_reach(0)). Все координаты результата целые.
-- Справа налево: время · gap · «87%» · gap · батарея (выступ справа) · gap · Wi‑Fi (если есть).
function tray.layout(f, at, measure, M)
  local L = { texts = {}, rects = {}, polys = {} }
  local top = at.base - M.icon_h
  local cur = at.right
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  local function grow(x, y, w, h)
    x0, y0 = math.min(x0, x), math.min(y0, y)
    x1, y1 = math.max(x1, x + w), math.max(y1, y + h)
  end
  local function text(s)
    local w = measure(s)
    cur = cur - w
    L.texts[#L.texts + 1] = { s = s, x = cur }
    local reach = at.reach or 0
    grow(cur - reach, at.base - at.asc - reach, w + 2 * reach, at.asc + 2 * reach)
    cur = cur - M.gap
  end
  local function rect(x, y, w, h)
    L.rects[#L.rects + 1] = { x = x, y = y, w = w, h = h }
    grow(x, y, w, h)
    return L.rects[#L.rects]
  end

  if f.hm then text(f.hm) end
  if f.pct then text(f.pct .. "%") end

  -- батарея: рамка batt_w × icon_h, выступ справа
  local bx = cur - M.nub_w - M.batt_w
  rect(bx, top, M.batt_w, M.line)
  rect(bx, at.base - M.line, M.batt_w, M.line)
  rect(bx, top, M.line, M.icon_h)
  rect(bx + M.batt_w - M.line, top, M.line, M.icon_h)
  rect(bx + M.batt_w, top + math.floor((M.icon_h - M.nub_h) / 2), M.nub_w, M.nub_h)
  local ix, iy = bx + M.line, top + M.line
  local iw, ih = M.batt_w - 2 * M.line, M.icon_h - 2 * M.line
  if f.pct then
    local fw = math.floor(iw * f.pct / 100 + 0.5)
    if fw > 0 then
      L.fill_x1 = ix + fw -- правый край заливки (молния белая левее него); сама заливка — один из rects
      rect(ix, iy, fw, ih)
    end
  end
  if f.charging then
    local cx, mid = bx + math.floor(M.batt_w / 2), iy + math.floor(ih / 2)
    -- точки — левый верхний угол штампа 2 × 2 (ink.stamp_small): нижняя на 2 px выше низа внутренности, иначе
    -- штамп ляжет на нижнюю линию рамки (белым — там, где под ней заливка)
    L.bolt = { cx + 1, iy, cx - 3, mid, cx + 2, mid, cx - 1, iy + ih - 2 }
    for i = 1, #L.bolt, 2 do grow(L.bolt[i], L.bolt[i + 1], 0, 0) end
  end
  cur = bx - M.gap

  if f.wifi then
    local r3 = M.wifi_r[3]
    local cx = cur - r3
    for _, r in ipairs(M.wifi_r) do
      local p = arc(cx, at.base, r)
      L.polys[#L.polys + 1] = p
      for i = 1, #p, 2 do grow(p[i], p[i + 1], 0, 0) end
    end
    L.polys[#L.polys + 1] = { cx, at.base - 2, cx, at.base }
    grow(cx, at.base - 2, 0, 2)
  end

  -- наружу до целых: слой угла и paintRegion берут целые пиксели
  local rx0, ry0 = math.floor(x0 - 2), math.floor(y0 - 2)
  L.rect = { x = rx0, y = ry0, w = math.ceil(x1 + 2) - rx0, h = math.ceil(y1 + 2) - ry0 }
  return L
end

return tray
