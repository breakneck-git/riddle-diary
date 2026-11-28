-- Знаки управления Kindle (спека 2026-11-28-control-signs, подход А): riddle.signs узнаёт знак по вшитым шаблонам
-- (riddle.sign_shapes) тем же glyph.match, что и ключ печати, со своим порогом и своими воротами размера.
-- Ложное срабатывание хуже пропуска. Матрица коллизий — по signs.LIST: новый знак попадает в неё сам.
local t = require("t")
local glyph = require("riddle.glyph")
local signs = require("riddle.signs")
local shapes = require("riddle.sign_shapes")
local control = require("riddle.control")
local V = require("sign_variants")
local R = require("fixtures.rose_strokes")
local TR = require("fixtures.triangle_strokes")
local O = require("fixtures.rose_owner")

local T = {}

local OPTS = { dist = signs.DIST, size = signs.SIZE }

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
  for _, name in ipairs({ "up", "down", "moon", "square", "bolt" }) do t.ok(listed[name], "знак спеки " .. name) end
end

function T.test_detect_own_variants()
  for _, name in ipairs(signs.LIST) do
    for i, d in ipairs(shapes[name]) do
      t.eq((signs.detect(d)), name, name .. " шаблон " .. i .. " как есть")
      for v, strokes in pairs(V.of(name, d)) do
        local got, score = signs.detect(strokes)
        t.eq(got, name, string.format("%s шаблон %d вариант %s (score=%.2f)", name, i, v, score))
      end
    end
  end
end

-- ни один шаблон не совпадает с шаблонами другого знака, ни один вариант не узнаётся чужим знаком
function T.test_signs_never_match_each_other()
  for _, a in ipairs(signs.LIST) do
    for i, d in ipairs(shapes[a]) do
      for _, b in ipairs(signs.LIST) do
        if b ~= a then
          local ok, dist = glyph.match(d, shapes[b], OPTS)
          t.eq(ok, false, string.format("%s %d против шаблонов %s: %.2f", a, i, b, dist))
          for v, strokes in pairs(V.of(a, d)) do
            t.ok(signs.detect(strokes) ~= b, a .. " " .. i .. " " .. v .. " узнан как " .. b)
          end
        end
      end
    end
  end
end

-- ↑ и ↓ различаются положением головы (облако не нормировано по повороту)
function T.test_up_down_not_swapped()
  for _, pair in ipairs({ { "up", "down" }, { "down", "up" } }) do
    for i, d in ipairs(shapes[pair[1]]) do
      for v, strokes in pairs(V.of(pair[1], d)) do
        t.ok(signs.detect(strokes) ~= pair[2], pair[1] .. " " .. i .. " " .. v .. " узнан как " .. pair[2])
      end
    end
  end
end

-- обязательная пара спеки: стрелка в один штрих против молнии (на синтетике 2.94 и 3.06 — ниже порога ключа)
function T.test_one_stroke_arrows_not_bolt()
  local n = 0
  for _, name in ipairs({ "up", "down" }) do
    for i, d in ipairs(shapes[name]) do
      if #d == 1 then
        n = n + 1
        for v, strokes in pairs(V.of(name, d)) do
          t.ok(signs.detect(strokes) ~= "bolt", name .. " " .. i .. " " .. v .. " узнан молнией")
        end
        local ok, dist = glyph.match(d, shapes.bolt, OPTS)
        t.eq(ok, false, string.format("%s %d против молнии: %.2f", name, i, dist))
      end
    end
  end
  t.ok(n >= 2, "есть стрелки в один штрих")
  for i, d in ipairs(shapes.bolt) do
    for v, strokes in pairs(V.of("bolt", d)) do
      local got = signs.detect(strokes)
      t.ok(got ~= "up" and got ~= "down", "молния " .. i .. " " .. v .. " узнана стрелкой")
    end
  end
end

-- обязательная пара спеки: одиночный крест розы против ↓ (на синтетике 2.97)
function T.test_cross_only_not_down()
  local got, _, why = signs.detect(R.cross_only)
  t.eq(got, false)
  t.ok(why.down and why.down > 1, "крест дальше порога от ↓: " .. tostring(why.down))
end

-- чужие рисунки (фикстуры треугольника, розы, живые розы владельца, буквы и слова) — не знак; рисунки из ALIKE модуля
-- фикстур (квадрат одним штрихом у треугольника) — свой знак
function T.test_fixtures_not_signs()
  local sets = { triangle_strokes = TR, rose_strokes = R, rose_owner = O }
  local n = 0
  for set, mod in pairs(sets) do
    for name, d in pairs(V.drawings(mod)) do
      n = n + 1
      local key = set .. "." .. name
      local got, score = signs.detect(d)
      t.eq(got, (mod.ALIKE or {})[name] or false, string.format("%s (score=%.2f)", key, score))
    end
  end
  t.ok(n > 80, "фикстур в матрице: " .. n)
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
