-- Матрица расстояний знаков управления (план 2026-11-28-control-signs): по каждому знаку signs.LIST — наибольшее
-- «своё» (свои варианты шаблонов: tests/sign_variants.lua), наименьшее «чужое» (рисунки модулей фикстур из
-- аргументов и шаблоны с вариантами других знаков) с именем, зазор, порог signs.DIST. Рисунок, не прошедший ворота
-- (число штрихов, размер), в счёт не идёт. Отчёт, не тест: им подбирают signs.DIST (Task 3).
-- Запуск из корня репо:
--   LUA_PATH="plugin/riddlediary.koplugin/?.lua;tests/?.lua;;" luajit tools/sign_matrix.lua \
--     fixtures.rose_strokes fixtures.triangle_strokes fixtures.rose_owner
-- Модуль фикстур с полем ALIKE = { [имя рисунка] = знак } отдаёт эти рисунки в «свои» того знака.
local glyph = require("riddle.glyph")
local signs = require("riddle.signs")
local shapes = require("riddle.sign_shapes")
local V = require("sign_variants")

local OPTS = { dist = math.huge, size = signs.SIZE }

local function dist(d, name)
  local _, x = glyph.match(d, shapes[name], OPTS)
  return x
end

-- знак -> { [метка] = рисунок } своих рисунков
local own, foreign = {}, {}
for _, name in ipairs(signs.LIST) do
  own[name] = {}
  for i, d in ipairs(shapes[name]) do
    for v, strokes in pairs(V.of(name, d)) do own[name][string.format("%s%d.%s", name, i, v)] = strokes end
  end
end
for _, modname in ipairs(arg) do
  local mod = require(modname)
  local alike = mod.ALIKE or {}
  for n, d in pairs(V.drawings(mod)) do
    local label = modname:gsub("^fixtures%.", "") .. "." .. n
    if alike[n] then own[alike[n]][label] = d else foreign[label] = d end
  end
end

print(string.format("signs.DIST = %.2f, signs.SIZE = %d", signs.DIST, signs.SIZE))
print(string.format("%-8s %-28s %6s  %-34s %6s %6s", "знак", "своё макс.", "", "чужое мин.", "", "зазор"))
for _, name in ipairs(signs.LIST) do
  local omax, olabel = -1, "-"
  for label, d in pairs(own[name]) do
    local x = dist(d, name)
    if x < math.huge and x > omax then omax, olabel = x, label end
  end
  local fmin, flabel = math.huge, "-"
  local function try(label, d)
    local x = dist(d, name)
    if x < fmin then fmin, flabel = x, label end
  end
  for label, d in pairs(foreign) do try(label, d) end
  for _, other in ipairs(signs.LIST) do
    if other ~= name then for label, d in pairs(own[other]) do try(label, d) end end
  end
  print(string.format("%-8s %-28s %6.2f  %-34s %6.2f %6.2f", name, olabel, omax, flabel, fmin, fmin - omax))
end
