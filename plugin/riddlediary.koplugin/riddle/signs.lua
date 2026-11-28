-- Знаки управления Kindle (спека 2026-11-28-control-signs, подход А): рисунок пером -> имя знака. Один распознаватель
-- на все знаки — glyph.match (тот же, что сверяет ключ печати) по вшитым шаблонам riddle.sign_shapes; новый знак —
-- строка в LIST, шаблоны в sign_shapes и команда в riddle.control, не новая эвристика. Чистые функции без KOReader.
-- Контракт распознавателя виджета (Diary:isSign, как у riddle.triangle и riddle.rose): detect, CRITERIA, MAX_STROKES.
-- Ложное срабатывание хуже пропуска. Порог ключа (glyph.DIST 3.0) знакам не годится: чужие фигуры к шаблонам ближе —
-- ↑ в 1 штрих против молнии 2.94, крест розы против ↓ 2.97, закрытая «4» против ↓ 3.01; свои варианты синтетики
-- (наклон ±10°, размер, порядок штрихов) — до 1.33 (план 2026-11-28-control-signs, M1–M4). Узкая стрелка мельче
-- glyph.SIZE (150) по меньшей стороне — свои ворота размера. До калибровки по руке владельца (план, Task 3) — синтетика.
local glyph = require("riddle.glyph")
local shapes = require("riddle.sign_shapes")

local signs = {}

-- знаки в порядке строки лога; у каждого — шаблоны в sign_shapes и команда в riddle.control
signs.LIST = { "up", "down" }
-- критерии лога devmode (Diary:isSign) — доля порога по каждому знаку
signs.CRITERIA = signs.LIST
-- ближайший шаблон не дальше — знак
signs.DIST = 2.0
-- меньшая сторона рамки знака, px ≥
signs.SIZE = 100
-- штрихов у знака не больше (ворота glyph.match)
signs.MAX_STROKES = glyph.MAX_STROKES

-- рисунок -> имя ближайшего совпавшего знака | false, расстояние до ближайшего шаблона (math.huge — не с чем
-- сравнить: ворота числа штрихов или размера), доли порога { [имя] = расстояние / DIST } по знакам, дошедшим до облака
function signs.detect(strokes)
  local opts = { dist = signs.DIST, size = signs.SIZE }
  local best, name, why = math.huge, false, {}
  for _, n in ipairs(signs.LIST) do
    local ok, d = glyph.match(strokes, shapes[n], opts)
    if d < math.huge then why[n] = d / signs.DIST end
    if ok and d < best then name = n end
    best = math.min(best, d)
  end
  return name, best, why
end

return signs
