-- Строковые помощники без зависимостей: подключать можно откуда угодно, цикла require не будет.
local str = {}

-- Строка без пробельных знаков (%s: пробел, \t \n \v \f \r) по краям; внутри не трогается. Неразрывный пробел
-- (U+00A0) — не пробел, остаётся. Не строка (nil, число, таблица) — "": поле ответа модели может быть чем угодно.
function str.trim(v)
  if type(v) ~= "string" then return "" end
  -- Линейно: первый не-пробел слева, последний — жадным ".*%S" (откат только по хвостовым пробелам). Шаблон
  -- "^%s*(.-)%s*$" на серии пробелов внутри строки квадратичен.
  local b = v:find("%S")
  if not b then return "" end
  local _, e = v:find(".*%S")
  return v:sub(b, e)
end

-- Текст одной строкой: пробельные знаки подряд — %s и неразрывный пробел (U+00A0) — один пробел, по краям срезаны.
-- Не строка — "", как у str.trim.
function str.one_line(v)
  if type(v) ~= "string" then return "" end
  return (v:gsub("\194\160", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Длина строки в знаках UTF-8 (не в байтах)
function str.utf8_len(s)
  return select(2, s:gsub("[^\128-\191]", ""))
end

-- Последний знак s по правилу utf8_len (знак начинается с любого байта, кроме продолжения); знаков нет — ""
function str.utf8_last(s)
  return s:match("[^\128-\191][\128-\191]*$") or ""
end

-- Байтовая позиция начала n-го знака s (n ≥ 1; знак начинается с любого байта, кроме продолжения); n больше
-- числа знаков — #s + 1
function str.utf8_offset(s, n)
  local count = 0
  for pos in s:gmatch("()[^\128-\191]") do
    count = count + 1
    if count == n then return pos end
  end
  return #s + 1
end

-- Первые n знаков s (UTF-8 не рвётся); n <= 0 — "", n больше длины — строка целиком
function str.utf8_head(s, n)
  if n <= 0 then return "" end
  return s:sub(1, str.utf8_offset(s, math.floor(n) + 1) - 1)
end

-- UTF-8 → массив кодпойнтов; знаков столько же, сколько считает utf8_len. Невалидный ввод не роняет: байты-продолжения
-- без начала отбрасываются; U+FFFD — для оборванной последовательности (меньше продолжений, чем требует начальный
-- байт), начального байта вне UTF-8 (C0, C1, F5–FF) и значения вне Unicode (выше U+10FFFF, или 0 из многобайтовой записи).
function str.codepoints(s)
  local out = {}
  for ch in s:gmatch("[^\128-\191][\128-\191]*") do
    local c = ch:byte(1)
    local need = c < 0x80 and 0 or c >= 0xF0 and 3 or c >= 0xE0 and 2 or 1
    local cp = 0xFFFD
    if need == 0 then
      cp = c
    elseif c >= 0xC2 and c <= 0xF4 and #ch - 1 >= need then
      cp = c % 2 ^ (6 - need)
      for j = 2, need + 1 do cp = cp * 64 + ch:byte(j) % 64 end
      if cp == 0 or cp > 0x10FFFF then cp = 0xFFFD end
    end
    out[#out + 1] = cp
  end
  return out
end

-- форма существительного по целому n ≥ 0 (единственное правило склонения): 1, 21, 101 — one; 2–4, 22–24 — few;
-- 0, 5–20, 11–14 в конце сотни — many
function str.plural(n, one, few, many)
  local d, dd = n % 10, n % 100
  if dd >= 11 and dd <= 14 then return many end
  if d == 1 then return one end
  if d >= 2 and d <= 4 then return few end
  return many
end

return str
