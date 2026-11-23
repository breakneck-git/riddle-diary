-- Раскладка страницы без KOReader: на какой строке встаёт приглашение.
-- Строки — с 1, как видит человек: строка N начинается на margin + (N-1)·высота строки шрифта.
local str = require("riddle.str")

local layout = {}

layout.INVITATION_LINES = { 2, 5 } -- владелец 2026-10-23: случайно между 2-й и 5-й строкой

-- random(a, b) -> целое a..b (math.random)
function layout.invitation_line(random)
  return random(layout.INVITATION_LINES[1], layout.INVITATION_LINES[2])
end

function layout.line_top(margin, line_h, n)
  return margin + (n - 1) * line_h
end

-- насколько тушь текста (Diary:paintText) выходит за его rect: свесы глифов TEXT_OVERHANG px и обводка halo
-- (0 — без неё) — слой текста в виджете и перерисовка шага карты читают одно и то же
layout.TEXT_OVERHANG = 8
function layout.text_reach(halo)
  return layout.TEXT_OVERHANG + (halo or 0)
end

-- прямоугольники a и b ({ x0, y0, x1, y1 }, края включены) пересекаются или пустых пикселей между ними меньше pad
function layout.near(a, b, pad)
  return a[1] - pad <= b[3] and b[1] - pad <= a[3] and a[2] - pad <= b[4] and b[2] - pad <= a[4]
end

-- Раскладка слов ответа по строкам. «\n» между словами — принудительный перенос (каждый «\n» —
-- на строку вниз, значит «\n\n» оставляет одну пустую строку); иначе слово переносится, когда не
-- влезает в maxw; пробелы и табуляции — один промежуток space. Крайние пробелы и «\n» не считаются.
-- measure(word) -> ширина слова; x — абсолютный (от x0); line с 0.
-- Возвращает { {word, x, line}, ... }, число строк. Не строка — ошибка вызывающего: ответ не пропадает молча.
function layout.flow(text, measure, space, x0, maxw)
  if type(text) ~= "string" then error("layout.flow: text is " .. type(text), 2) end
  text = str.trim(text)
  local items, x, line, prev = {}, x0, 0, 1
  for pos, word, after in text:gmatch("()(%S+)()") do
    local _, nl = text:sub(prev, pos - 1):gsub("\n", "")
    local ww = measure(word)
    if nl > 0 then
      x, line = x0, line + nl
    elseif x > x0 and x + ww > x0 + maxw then
      x, line = x0, line + 1
    end
    items[#items + 1] = { word = word, x = x, line = line }
    x = x + ww + space
    prev = after
  end
  return items, line + 1
end

-- закрывающие знаки после конца предложения («Кто ты?»), и знаки, которые снимаются перед «…»
local CLOSERS = { "»", "\"", "'", ")", "]", "”", "’" }
local DANGLING = { ",", ";", ":", "—", "–", "-" }
local ENDS = { ".", "!", "?", "…" }

local function ends_with(s, tail) return tail ~= "" and s:sub(-#tail) == tail end

-- снять с конца s хвосты из списка, пока они есть
local function strip(s, tails)
  local again = true
  while again do
    again = false
    for _, tail in ipairs(tails) do
      if ends_with(s, tail) then s, again = s:sub(1, -#tail - 1), true end
    end
  end
  return s
end

-- не буквы среди многобайтных знаков, что могут стоять перед «.!?…»
local NOT_LETTERS = { "«", "»", "“", "”", "’", "—", "–", "…" }

-- конец предложения: «.!?…» (и закрывающие кавычки за ними) после буквы, и внутри слова точки нет — номер
-- пункта «3.», «1)», сокращения «т.е.», «т.д.» концом не считаются
local function ends_sentence(word)
  local w = strip(word, CLOSERS)
  local body = strip(strip(w, ENDS), CLOSERS)
  if body == w or body:find(".", 1, true) then return false end
  local c = str.utf8_last(body)
  if #c == 1 then return c:match("%a") ~= nil end
  for _, p in ipairs(NOT_LETTERS) do if c == p then return false end end
  return c ~= ""
end

-- Обрезка раскладки layout.flow до max_lines строк (ответ, не влезающий в экран). Последняя видимая строка
-- кончается целым предложением, если на ней есть его конец; иначе — последним словом и «…» (висящие «,;:—»
-- перед ней снимаются, снятое до пустого — уходит; «…» не влезает в maxw — слово уходит, «…» встаёт за предыдущим на
-- той же строке, а единственное на строке слово укорачивается по знаку).
-- items, nlines — что вернул flow; measure, x0, maxw — те же. -> items, nlines, обрезано ли.
-- Влезает целиком — те же items и nlines. Слово меняется в копии: items flow не трогаются.
function layout.clip(items, nlines, max_lines, measure, x0, maxw)
  if nlines <= max_lines then return items, nlines, false end
  local kept = {}
  for _, it in ipairs(items) do
    if it.line < max_lines then kept[#kept + 1] = it end
  end
  local last = kept[#kept]
  if not last then return kept, 1, true end
  local first = #kept -- первое слово последней видимой строки
  while first > 1 and kept[first - 1].line == last.line do first = first - 1 end
  for i = #kept, first, -1 do
    if ends_sentence(kept[i].word) then
      for j = #kept, i + 1, -1 do kept[j] = nil end
      return kept, last.line + 1, true
    end
  end
  while true do
    local it = kept[#kept]
    local word = strip(it.word, DANGLING)
    local fits = it.x + measure(word .. "…") <= x0 + maxw
    if #kept == first then -- одно слово на ряду: шире ряда — укорачивается по знаку, пока «…» не влезет
      while not fits and word ~= "" do
        word = str.utf8_head(word, str.utf8_len(word) - 1)
        fits = it.x + measure(word .. "…") <= x0 + maxw
      end
    end
    if #kept == first or (fits and word ~= "") then -- снятое до пустого («—») уходит, «…» — за предыдущим
      kept[#kept] = { word = word .. "…", x = it.x, line = it.line }
      return kept, last.line + 1, true
    end
    kept[#kept] = nil
  end
end

return layout
