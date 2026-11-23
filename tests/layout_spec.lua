-- Приглашение «Кто касается моих страниц?» при каждом показе (открытие, пробуждение) встаёт на
-- случайную строку 2–5, а не в первую (владелец 2026-10-23). Строки — с 1, как видит человек:
-- строка N начинается на margin + (N-1)·высота строки шрифта.
local t = require("t")
local layout = require("riddle.layout")

local T = {}

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

function T.test_invitation_line_always_2_to_5()
  math.randomseed(20261023)
  for _ = 1, 1000 do
    local n = layout.invitation_line(math.random)
    t.ok(n >= 2 and n <= 5 and n == math.floor(n), "строка " .. tostring(n))
  end
end

function T.test_invitation_line_varies()
  math.randomseed(7)
  local seen, kinds = {}, 0
  for _ = 1, 200 do
    local n = layout.invitation_line(math.random)
    if not seen[n] then seen[n], kinds = true, kinds + 1 end
  end
  t.eq(kinds, 4, "за 200 показов встречаются все строки 2–5")
end

function T.test_invitation_line_uses_given_random()
  t.eq(layout.invitation_line(function(a, b) return a end), 2)
  t.eq(layout.invitation_line(function(a, b) return b end), 5)
end

function T.test_line_top_counts_from_one()
  t.eq(layout.line_top(44, 50, 1), 44, "строка 1 — сам отступ")
  t.eq(layout.line_top(44, 50, 2), 94)
  t.eq(layout.line_top(44, 50, 5), 244)
end

function T.test_widget_places_invitation_through_layout_on_every_show()
  local w = read("plugin/riddlediary.koplugin/riddle_diarywidget.lua")
  local body = w:match("function Diary:showInvitation%(push%)(.-)\nend")
  t.ok(body, "showInvitation найдена")
  t.ok(body:find("layout.invitation_line(", 1, true), "строка выбирается при каждом показе")
  t.ok(body:find("layout.line_top(", 1, true), "верх по номеру строки")
  t.ok(not w:find("texts.invitation, CFG.margin, CFG.margin", 1, true), "больше не в первой строке")
end

-- Перенос строк в тексте ответа: «\n» — принудительный перенос, «\n\n» — одна пустая строка,
-- перенос по ширине — как был, пробелы и табуляции — как были.
local texts = require("riddle.texts")

local function mw(w) return #w * 5 end -- ширина слова в тесте: 5 на байт
local SPACE = 3

-- прежний алгоритм из виджета (до «\n»), для регресс-сверки текста без «\n»
local function old_flow(text, x0, maxw)
  local out, x, line = {}, x0, 0
  for word in text:gmatch("%S+") do
    local ww = mw(word)
    if x > x0 and x + ww > x0 + maxw then x, line = x0, line + 1 end
    out[#out + 1] = { word = word, x = x, line = line }
    x = x + ww + SPACE
  end
  return out, line + 1
end

local function by_line(items)
  local lines = {}
  for _, it in ipairs(items) do
    lines[it.line] = (lines[it.line] and (lines[it.line] .. " ") or "") .. it.word
  end
  return lines
end

function T.test_flow_breaks_exactly_on_newline()
  local items, n = layout.flow("раз два\nтри\nчетыре пять шесть\nсемь", mw, SPACE, 10, 10000)
  local lines = by_line(items)
  t.eq(n, 4)
  t.eq(lines[0], "раз два")
  t.eq(lines[1], "три")
  t.eq(lines[2], "четыре пять шесть")
  t.eq(lines[3], "семь")
  for _, it in ipairs(items) do
    if it.word == "три" or it.word == "четыре" or it.word == "семь" then
      t.eq(it.x, 10, "первое слово строки встаёт на x0: " .. it.word)
    end
  end
end

function T.test_flow_double_newline_is_one_blank_line()
  local items, n = layout.flow("раз\n\nдва", mw, SPACE, 0, 10000)
  t.eq(n, 3)
  t.eq(items[1].line, 0)
  t.eq(items[2].line, 2, "между ними одна пустая строка")
end

-- крайние пробелы и «\n» не считаются: ответ с пустыми строками по краям не сдвигает текст вниз
function T.test_flow_edge_whitespace_and_newlines_are_not_counted()
  local items, n = layout.flow("\n\n \t раз\nдва \n\n", mw, SPACE, 0, 10000)
  t.eq(n, 2, "две строки")
  t.eq(#items, 2)
  t.eq(items[1].line, 0, "первое слово на первой строке")
  t.eq(items[2].line, 1)
  local blank, blank_n = layout.flow(" \n\t\n ", mw, SPACE, 0, 10000)
  t.eq(#blank, 0, "одни пробелы — слов нет")
  t.eq(blank_n, 1, "и одна (пустая) строка, как у пустого текста")
end

-- не строка — ошибка вызывающего, не пустая раскладка: ответ не должен молча пропасть со страницы (Notion
-- 41013e60-bc8d-819e)
function T.test_flow_not_a_string_is_an_error()
  for _, v in ipairs({ 5, true, {} }) do
    local ok, err = pcall(layout.flow, v, mw, SPACE, 0, 10000)
    t.eq(ok, false, "не строка (" .. type(v) .. ") — ошибка")
    t.ok(tostring(err):find("layout.flow: text is " .. type(v), 1, true), tostring(err))
  end
  local ok = pcall(layout.flow, nil, mw, SPACE, 0, 10000)
  t.eq(ok, false, "nil — ошибка")
end

function T.test_flow_still_wraps_by_width_inside_a_line()
  -- узкая колонка: каждая строка стиха сама переносится, но разрыв на «\n» остаётся
  local items = layout.flow("aaaa bbbb\ncccc dddd", mw, SPACE, 0, 30)
  local lines = by_line(items)
  t.eq(lines[0], "aaaa")
  t.eq(lines[1], "bbbb")
  t.eq(lines[2], "cccc")
  t.eq(lines[3], "dddd")
end

function T.test_flow_without_newline_matches_old_layout_exactly()
  local samples = {
    "один",
    "Пыль осыпалась со страниц: ты снова со мной.",
    "  много   пробелов \t и\ttабуляции  в тексте ",
    "Ждал тебя. Что у тебя для меня сегодня? Расскажи мне всё, что было за день.",
  }
  for _, s in ipairs(samples) do
    for _, maxw in ipairs({ 40, 120, 300, 100000 }) do
      local want, want_n = old_flow(s, 7, maxw)
      local got, got_n = layout.flow(s, mw, SPACE, 7, maxw)
      t.eq(got_n, want_n, "число строк: " .. s)
      t.eq(#got, #want, "число слов: " .. s)
      for i = 1, #want do
        t.eq(got[i].word, want[i].word)
        t.eq(got[i].x, want[i].x, "x слова " .. i)
        t.eq(got[i].line, want[i].line, "строка слова " .. i)
      end
    end
  end
end

-- подсказка печати (cfg.hints) — четверостишие: строки стиха не сливаются
local VERSES = {
  "Я стою у самой двери,\nСтарый ключ держу в руке.\nТы проверь, а не поверь —\nЧто лежит на сундуке.",
  "Тишина, страница, ночь,\nНе спешит ко мне рука.\nЯ могла бы и помочь —\nНо подскажет лишь строка.",
}

function T.test_flow_hint_verses_keep_four_stanza_lines()
  for i, hint in ipairs(VERSES) do
    local _, n = layout.flow(hint, mw, SPACE, 0, 100000)
    t.eq(n, 4, "стих " .. i .. ": 4 строки при широкой колонке")
    local _, n2 = layout.flow(hint, mw, SPACE, 0, 600)
    t.ok(n2 >= 4, "стих " .. i .. ": не меньше 4 строк в узкой")
  end
end

function T.test_widget_flows_text_through_layout()
  local w = read("plugin/riddlediary.koplugin/riddle_diarywidget.lua")
  local body = w:match("local function layoutText%(.-\nend\n")
  t.ok(body, "layoutText найдена")
  t.ok(body:find("layout.flow(", 1, true), "раскладка слов — в riddle.layout")
end

-- близость прямоугольников { x0, y0, x1, y1 } (края включены; «близко» — пустых пикселей между ними меньше pad): общая проверка стока у пера, devtest и подписей карты
function T.test_near_overlap_touch_and_gap()
  local a = { 10, 10, 19, 19 }
  t.eq(layout.near(a, { 15, 15, 30, 30 }, 0), true, "перекрываются")
  t.eq(layout.near(a, { 19, 0, 25, 5 }, 0), false, "по x сходятся, по y врозь")
  t.eq(layout.near(a, { 20, 10, 29, 19 }, 0), false, "вплотную справа, без зазора — не пересекаются")
  t.eq(layout.near(a, { 20, 10, 29, 19 }, 1), true, "в пределах pad = 1")
  t.eq(layout.near(a, { 23, 10, 29, 19 }, 4), true, "пустых между ними 3 < pad 4")
  t.eq(layout.near(a, { 24, 10, 29, 19 }, 4), false, "пустых 4 = pad — уже врозь")
  t.eq(layout.near({ 24, 10, 29, 19 }, a, 4), false, "симметрично")
  t.eq(layout.near(a, { 10, 23, 19, 30 }, 4), true, "по вертикали — так же")
  t.eq(layout.near(a, { 10, 24, 19, 30 }, 4), false)
end

t.run(T)
