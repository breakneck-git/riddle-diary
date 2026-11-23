-- Длина, голова, смещение и кодпойнты UTF-8 строки (str.utf8_len, str.utf8_head, str.utf8_offset, str.codepoints):
-- одна реализация на лимиты промпта, знания, страниц Notion, нарезку отпечатков, печать и раскладку текста.
-- Буква кириллицы (2 байта) не рвётся ни при каком n.
local t = require("t")
local str = require("riddle.str")

local T = {}

function T.test_utf8_len_counts_chars_not_bytes()
  t.eq(str.utf8_len(""), 0, "пустая строка")
  t.eq(str.utf8_len("abc"), 3, "ASCII")
  t.eq(str.utf8_len("Гарри"), 5, "кириллица — знаки, не байты")
  t.eq(str.utf8_len("a…б"), 3, "тройной байт (…) и двойной в одной строке")
end

function T.test_utf8_head_never_splits_a_letter()
  t.eq(str.utf8_head("Гарри Поттер", 5), "Гарри", "кириллица: ровно 5 знаков")
  t.eq(str.utf8_head("Гарри", 1), "Г", "один знак — целая буква")
  t.eq(str.utf8_head("a…б", 2), "a…", "тройной байт цел")
  for n = 0, 6 do
    t.eq(str.utf8_len(str.utf8_head("Гарри", n)), math.min(n, 5), "знаков столько, сколько просили: n=" .. n)
  end
end

function T.test_utf8_head_edges()
  t.eq(str.utf8_head("Гарри", 0), "", "n=0 — пусто")
  t.eq(str.utf8_head("Гарри", -3), "", "n<0 — пусто")
  t.eq(str.utf8_head("Гарри", 5), "Гарри", "n равен длине — строка целиком")
  t.eq(str.utf8_head("Гарри", 100), "Гарри", "n больше длины — строка целиком")
  t.eq(str.utf8_head("\128abc", 0), "", "n=0 при ведущем байте-продолжении — пусто, не один байт")
  t.eq(str.utf8_head("abc", 1.5), "a", "дробный n — как раньше: знаков, чей номер больше n, не берём")
  t.eq(str.utf8_head("abc", 0.5), "", "n между 0 и 1 — пусто")
  t.eq(str.utf8_head("", 5), "", "пустая строка")
  t.eq(str.utf8_head("", 0), "", "пустая строка, n=0")
end

function T.test_utf8_offset_is_byte_position_of_nth_char()
  t.eq(str.utf8_offset("abc", 1), 1, "ASCII: первый знак")
  t.eq(str.utf8_offset("abc", 3), 3, "ASCII: последний знак")
  t.eq(str.utf8_offset("Гарри", 1), 1, "кириллица: первый знак")
  t.eq(str.utf8_offset("Гарри", 2), 3, "кириллица: второй знак после двух байт")
  t.eq(str.utf8_offset("a…б", 2), 2, "тройной байт: начало …")
  t.eq(str.utf8_offset("a…б", 3), 5, "после тройного байта — б")
  t.eq(str.utf8_offset("a😀б", 3), 6, "четырёхбайтовый знак цел")
end

function T.test_utf8_offset_past_end_and_empty()
  t.eq(str.utf8_offset("abc", 4), 4, "n = длина + 1 — #s + 1")
  t.eq(str.utf8_offset("Гарри", 6), 11, "кириллица: за концом — #s + 1")
  t.eq(str.utf8_offset("Гарри", 100), 11, "n далеко за концом — #s + 1")
  t.eq(str.utf8_offset("abc", 0), 4, "n < 1 — знака с таким номером нет: #s + 1")
  t.eq(str.utf8_offset("abc", 1.5), 4, "дробный n — знака с таким номером нет: #s + 1")
  t.eq(str.utf8_offset("", 1), 1, "пустая строка")
end

function T.test_utf8_offset_slices_whole_chars()
  local s = "Гарри Поттер"
  for n = 1, 12 do
    local cut = str.utf8_offset(s, n)
    t.eq(str.utf8_len(s:sub(1, cut - 1)), n - 1, "голова до n-го знака: n=" .. n)
  end
end

local function pack(cps) return table.concat(cps, ",") end

function T.test_codepoints_decodes_valid_utf8()
  t.eq(pack(str.codepoints("")), "", "пустая строка")
  t.eq(pack(str.codepoints("abc")), "97,98,99", "ASCII")
  t.eq(pack(str.codepoints("Гарри")), "1043,1072,1088,1088,1080", "кириллица (2 байта)")
  t.eq(pack(str.codepoints("a…б")), "97,8230,1073", "трёхбайтовый знак между ASCII и кириллицей")
  t.eq(pack(str.codepoints("a😀б")), "97,128512,1073", "четырёхбайтовый знак")
end

function T.test_codepoints_count_equals_utf8_len_on_any_input()
  for i, s in ipairs({ "", "abc", "Гарри", "a…б", "a😀б", "\128abc", "ab\195", "\195a", "\226\130", "a\128\128b", "\192\128", "\245\128\128\128", "\255" }) do
    t.eq(#str.codepoints(s), str.utf8_len(s), "знаков столько же, сколько считает utf8_len: случай " .. i)
  end
end

function T.test_codepoints_invalid_input_is_dropped_or_replaced_not_fatal()
  t.eq(pack(str.codepoints("\128abc")), "97,98,99", "ведущий байт-продолжение отбрасывается")
  t.eq(pack(str.codepoints("a\128\128b")), "97,98", "байты-продолжения без начала отбрасываются")
  t.eq(pack(str.codepoints("ab\195")), "97,98,65533", "оборванная последовательность в конце — U+FFFD, не ошибка")
  t.eq(pack(str.codepoints("\195a")), "65533,97", "начало без продолжения не съедает следующий ASCII")
  t.eq(pack(str.codepoints("\226\130")), "65533", "трёхбайтовый знак, оборванный на втором байте")
end

function T.test_codepoints_never_yields_non_unicode_values()
  t.eq(pack(str.codepoints("\192\128")), "65533", "C0 — всегда переполнение: U+FFFD, не 0")
  t.eq(pack(str.codepoints("\193\191")), "65533", "C1 — переполнение: U+FFFD, не 127")
  t.eq(pack(str.codepoints("\245\128\128\128")), "65533", "F5 — вне Unicode: U+FFFD")
  t.eq(pack(str.codepoints("\255")), "65533", "FF — не байт UTF-8: U+FFFD")
  t.eq(pack(str.codepoints("\244\144\128\128")), "65533", "выше U+10FFFF: U+FFFD")
  t.eq(pack(str.codepoints("\224\128\128")), "65533", "многобайтовая запись нуля: U+FFFD, не 0")
  t.eq(pack(str.codepoints("\244\143\191\191")), "1114111", "U+10FFFF — последний допустимый")
  t.eq(pack(str.codepoints("a\0b")), "97,0,98", "настоящий NUL (один байт) — кодпойнт 0, как был")
end

t.run(T)
