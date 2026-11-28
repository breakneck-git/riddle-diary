-- Свои варианты рисунка знака управления: другое место, размер, наклон руки, порядок и направление штрихов.
-- Одно место для tests/signs_spec.lua и отчёта tools/sign_matrix.lua.
local M = {}

-- наклон руки, градусы: облако не нормировано по повороту, у квадрата углы уходят дальше всего (план, M8)
M.TILT = { square = 5 }
M.TILT_DEFAULT = 10

-- рисунок, повёрнутый на deg градусов и растянутый в k раз около центра его рамки, сдвинутый на (dx, dy)
function M.moved(strokes, deg, k, dx, dy)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, s in ipairs(strokes) do
    for j = 1, #s.p, 2 do
      x0, x1 = math.min(x0, s.p[j]), math.max(x1, s.p[j])
      y0, y1 = math.min(y0, s.p[j + 1]), math.max(y1, s.p[j + 1])
    end
  end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  local c, sn = math.cos(math.rad(deg)), math.sin(math.rad(deg))
  local out = {}
  for i, s in ipairs(strokes) do
    local p = {}
    for j = 1, #s.p, 2 do
      local x, y = s.p[j] - cx, s.p[j + 1] - cy
      p[j], p[j + 1] = cx + k * (x * c - y * sn) + dx, cy + k * (x * sn + y * c) + dy
    end
    out[i] = { p = p }
  end
  return out
end

-- обратный порядок штрихов и обратное направление каждого
function M.reversed(strokes)
  local out = {}
  for i = #strokes, 1, -1 do
    local p, s = {}, strokes[i].p
    for j = #s - 1, 1, -2 do p[#p + 1], p[#p + 2] = s[j], s[j + 1] end
    out[#out + 1] = { p = p }
  end
  return out
end

-- рисунок знака name -> { [вариант] = рисунок }
function M.of(name, d)
  local tilt = M.TILT[name] or M.TILT_DEFAULT
  return {
    shift = M.moved(d, 0, 1, 120, -90),
    small = M.moved(d, 0, 0.7, 0, 0),
    big = M.moved(d, 0, 1.3, 0, 0),
    tilt_left = M.moved(d, -tilt, 1, 0, 0),
    tilt_right = M.moved(d, tilt, 1, 0, 0),
    backwards = M.reversed(d),
  }
end

-- все рисунки модуля фикстур (значения-рисунки: список штрихов { p = … }; списки имён пропускаются) -> { [имя] = рисунок }
function M.drawings(mod)
  local out = {}
  for name, v in pairs(mod) do
    if type(v) == "table" and type(v[1]) == "table" and type(v[1].p) == "table" then out[name] = v end
  end
  return out
end

return M
