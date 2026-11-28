-- Знаки управления Kindle (спека 2026-11-28-control-signs, подход А): riddle.signs узнаёт знак по вшитым шаблонам
-- (riddle.sign_shapes) тем же glyph.match, что и ключ печати, со своим порогом и своими воротами размера.
-- Ложное срабатывание хуже пропуска.
local t = require("t")
local signs = require("riddle.signs")
local shapes = require("riddle.sign_shapes")
local control = require("riddle.control")

local T = {}

-- рисунок, повёрнутый на deg градусов и растянутый в k раз около центра его рамки, сдвинутый на (dx, dy)
local function moved(strokes, deg, k, dx, dy)
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
local function reversed(strokes)
  local out = {}
  for i = #strokes, 1, -1 do
    local p, s = {}, strokes[i].p
    for j = #s - 1, 1, -2 do p[#p + 1], p[#p + 2] = s[j], s[j + 1] end
    out[#out + 1] = { p = p }
  end
  return out
end

-- свои варианты шаблона: другое место, размер, наклон руки, порядок и направление штрихов
local function variants(d)
  return {
    shift = moved(d, 0, 1, 120, -90),
    small = moved(d, 0, 0.7, 0, 0),
    big = moved(d, 0, 1.3, 0, 0),
    tilt_left = moved(d, -10, 1, 0, 0),
    tilt_right = moved(d, 10, 1, 0, 0),
    backwards = reversed(d),
  }
end

-- таблица знаков — одна: у каждого знака списка есть шаблоны и команда, лишних нет ни там, ни там
function T.test_shapes_cover_list()
  local listed = {}
  for _, name in ipairs(signs.LIST) do
    listed[name] = true
    t.ok(shapes[name] and #shapes[name] > 0, "шаблоны знака " .. name)
    t.eq(type(control.COMMANDS[name]), "function", "команда знака " .. name)
  end
  for name in pairs(shapes) do t.ok(listed[name], "шаблон без знака в списке: " .. name) end
  for name in pairs(control.COMMANDS) do t.ok(listed[name], "команда без знака в списке: " .. name) end
  t.eq(signs.CRITERIA, signs.LIST, "критерии лога — знаки списка")
end

function T.test_detect_own_variants()
  for _, name in ipairs(signs.LIST) do
    for i, d in ipairs(shapes[name]) do
      t.eq((signs.detect(d)), name, name .. " шаблон " .. i .. " как есть")
      for v, strokes in pairs(variants(d)) do
        local got, score = signs.detect(strokes)
        t.eq(got, name, string.format("%s шаблон %d вариант %s (score=%.2f)", name, i, v, score))
      end
    end
  end
end

-- ↑ и ↓ различаются положением головы (облако не нормировано по повороту)
function T.test_up_down_not_swapped()
  for _, pair in ipairs({ { "up", "down" }, { "down", "up" } }) do
    for i, d in ipairs(shapes[pair[1]]) do
      for v, strokes in pairs(variants(d)) do
        t.ok(signs.detect(strokes) ~= pair[2], pair[1] .. " " .. i .. " " .. v .. " узнан как " .. pair[2])
      end
    end
  end
end

-- why — доля порога по каждому знаку, дошедшему до облака: у своего ≤ 1, у чужого > 1
function T.test_why_shares()
  local name, score, why = signs.detect(shapes.up[1])
  t.eq(name, "up")
  t.ok(why.up <= 1, "своя доля " .. tostring(why.up))
  t.ok(why.down > 1, "чужая доля " .. tostring(why.down))
  t.eq(score, why.up * signs.DIST, "score — ближайшее расстояние")
end

-- мимо ворот: страница слов, пустая страница, мелкий росчерк — не знак, сравнивать не с чем
function T.test_gates_miss()
  local many = {}
  for i = 1, signs.MAX_STROKES + 1 do many[i] = { p = { i * 40, 300, i * 40 + 30, 500 } } end
  for label, strokes in pairs({ many = many, empty = {}, tiny = { { p = { 300, 300, 330, 340, 300, 380 } } } }) do
    local name, score = signs.detect(strokes)
    t.eq(name, false, label)
    t.eq(score, math.huge, label)
  end
end

t.run(T)
