local t = require("t")
local str = require("riddle.str")

local T = {}

-- нижний регистр: латиница и кириллица, ё → е (так хранится ключ персоны, persona.key — менять нельзя)
function T.test_lower_cyrillic()
  t.eq(str.lower("ЁЖИК Abc"), "ежик abc")
  t.eq(str.lower("ПРИВЕТ, Мир! 42"), "привет, мир! 42", "знаки и цифры — как есть")
  t.eq(str.lower("Ёлка ёлка"), "елка елка")
  t.eq(str.lower("«Методы» — HPMOR"), "«методы» — hpmor", "кавычки и тире байт в байт")
  t.eq(str.lower(""), "")
end

t.run(T)
