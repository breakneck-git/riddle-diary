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

-- нижний регистр, ё → е; nil — не буква латиницы или кириллицы
local function fold(cp)
  if cp >= 0x41 and cp <= 0x5A then return cp + 0x20 end -- A-Z
  if cp >= 0x61 and cp <= 0x7A then return cp end         -- a-z
  if cp == 0x401 or cp == 0x451 then return 0x435 end     -- Ё ё → е
  if cp >= 0x410 and cp <= 0x42F then return cp + 0x20 end -- А-Я
  if cp >= 0x430 and cp <= 0x44F then return cp end       -- а-я
  return nil
end

-- кодпойнт → UTF-8 (в LuaJIT нет utf8.char); хватает BMP
local function encode(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  end
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- нижний регистр латиницы и кириллицы, ё → е; прочие знаки — как есть, байт в байт. ё → е менять нельзя: так
-- построен ключ персоны в базе (persona.key, UNIQUE)
function str.lower(s)
  return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(ch)
    local f = fold(str.codepoints(ch)[1])
    return f and encode(f) or ch
  end))
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
