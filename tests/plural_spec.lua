-- Склонение существительного по числу: одно правило (str.plural) — строка Notion на странице состояния.
-- Правило русского языка: 1, 21, 101 — первая форма; 2–4, 22–24 — вторая; 0, 5–20, 11–14 в конце сотни — третья.
local t = require("t")
local str = require("riddle.str")

local T = {}

local DOC = { "документ", "документа", "документов" }
local function doc(n) return str.plural(n, DOC[1], DOC[2], DOC[3]) end

function T.test_one_few_many()
  t.eq(doc(1), "документ")
  t.eq(doc(2), "документа"); t.eq(doc(3), "документа"); t.eq(doc(4), "документа")
  t.eq(doc(0), "документов"); t.eq(doc(5), "документов"); t.eq(doc(10), "документов")
end

function T.test_teens_are_many()
  for n = 11, 14 do t.eq(doc(n), "документов", tostring(n)) end
  t.eq(doc(111), "документов"); t.eq(doc(112), "документов"); t.eq(doc(1012), "документов")
end

function T.test_by_last_digit_past_twenty()
  t.eq(doc(21), "документ"); t.eq(doc(101), "документ"); t.eq(doc(1001), "документ")
  t.eq(doc(22), "документа"); t.eq(doc(1234), "документа")
  t.eq(doc(25), "документов"); t.eq(doc(100), "документов")
  t.eq(str.plural(12, "база", "базы", "баз"), "баз")
  t.eq(str.plural(1, "база", "базы", "баз"), "база")
end

t.run(T)
