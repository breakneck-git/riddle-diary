-- Нарезка текста документа на куски для отпечатков: короткий — целиком, длинный — абзацы пакуются до
-- chunk.WHOLE знаков с перекрытием хвостом предыдущего куска, потолок chunk.CAP; знак — кодпойнт UTF-8.
local t = require("t")
local chunk = require("riddle.chunk")

local function ulen(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

-- строгая проверка UTF-8: каждая последовательность целая, без хвостов и оборванных начал
local function valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or (c >= 0xC2 and c < 0xE0) and 2 or (c >= 0xE0 and c < 0xF0) and 3
      or (c >= 0xF0 and c < 0xF5) and 4 or nil
    if not len or i + len - 1 > n then return false end
    for j = i + 1, i + len - 1 do
      local b = s:byte(j)
      if b < 0x80 or b > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

-- абзац из n знаков: слова «словоNN» через пробел, кириллица (2 байта на знак)
local function para(tag, n)
  local words, len = {}, 0
  local i = 0
  while true do
    i = i + 1
    local w = tag .. "слово" .. i
    local add = ulen(w) + (len > 0 and 1 or 0)
    if len + add > n then break end
    words[#words + 1] = w
    len = len + add
  end
  local s = table.concat(words, " ")
  return s .. string.rep("я", n - ulen(s))
end

local tests = {}

function tests.test_short_text_one_chunk()
  t.eq(chunk.WHOLE, 1500, "WHOLE")
  local text = string.rep("ж", chunk.WHOLE) -- 3000 байт, но 1500 знаков
  local out = chunk.split(text)
  t.eq(#out, 1, "один кусок")
  t.eq(out[1], text, "текст целиком")
  t.eq(#chunk.split("Короткая заметка."), 1, "совсем короткий")
  t.eq(#chunk.split(""), 0, "пустой — без кусков")
  t.eq(#chunk.split("  \n\n \n"), 0, "одни пробелы — без кусков")
  t.eq(#chunk.split(nil), 0, "nil — без кусков")
end

function tests.test_paragraph_padding_is_trimmed_in_chunks()
  local paras, padded = {}, {}
  for i = 1, 6 do
    paras[i] = para("п" .. i, 500)
    padded[i] = " \t" .. paras[i] .. "\t "
  end
  local out = chunk.split(table.concat(padded, "\n\n"))
  t.eq(#out, 3, "по два абзаца в кусок")
  t.eq(out[1], paras[1] .. "\n\n" .. paras[2], "пробелы и табуляции вокруг абзацев срезаны")
  for k, c in ipairs(out) do
    t.ok(not c:find("[ \t]\n\n") and not c:find("\n\n[ \t]"), "кусок " .. k .. ": на стыке абзацев нет пробелов")
    t.ok(not c:find("^[ \t]") and not c:find("[ \t]$"), "кусок " .. k .. ": края чистые")
  end
end

function tests.test_long_text_paragraph_packing_with_overlap()
  t.eq(chunk.OVERLAP, 300, "OVERLAP")
  local paras = {}
  for i = 1, 6 do paras[i] = para("п" .. i, 500) end
  local out = chunk.split(table.concat(paras, "\n\n"))
  t.eq(#out, 3, "по два абзаца в кусок")
  -- каждый абзац целиком в своём куске, по порядку
  for i, p in ipairs(paras) do
    local k = math.floor((i - 1) / 2) + 1
    t.ok(out[k]:find(p, 1, true), "абзац " .. i .. " целиком в куске " .. k)
  end
  for k = 2, #out do
    local prev, cur = out[k - 1], out[k]
    t.ok(ulen(cur) <= chunk.WHOLE + chunk.OVERLAP + 2, "кусок " .. k .. " не раздут: " .. ulen(cur))
    local head = cur:match("^(.-)\n\n")
    t.ok(head and #head > 0, "кусок " .. k .. " начинается с перекрытия")
    t.ok(ulen(head) <= chunk.OVERLAP, "перекрытие ≤ OVERLAP: " .. ulen(head))
    t.ok(ulen(head) >= chunk.OVERLAP / 2, "перекрытие не пустяковое: " .. ulen(head))
    t.eq(prev:sub(-#head), head, "перекрытие — хвост куска " .. (k - 1))
    t.ok(not head:find("^%s"), "перекрытие без ведущих пробелов")
    t.ok(head:find("^п%dслово%d"), "перекрытие с начала слова: " .. head:sub(1, 24))
    t.ok(prev:sub(-#head - 1, -#head - 1):match("%s"), "перед перекрытием в предыдущем куске — пробел")
  end
  t.ok(ulen(out[1]) <= chunk.WHOLE, "первый кусок без перекрытия ≤ WHOLE")
end

-- граница WHOLE и упаковка считаются в знаках, не в байтах: кириллица — 2 байта на знак
function tests.test_whole_boundary_in_codepoints()
  -- ровно 1500 знаков с пустой строкой внутри — один кусок как есть; 1501 — уже по абзацам
  local a, b = para("а", 749), para("б", 749)
  local text = a .. "\n\n" .. b
  t.eq(#chunk.split(text), 1, "1500 знаков (3000+ байт) — один кусок")
  t.eq(chunk.split(text)[1], text, "как есть")
  t.eq(#chunk.split(para("а", 750) .. "\n\n" .. b), 2, "1501 знак — по абзацам, два куска")
  -- упаковка: 749 + 2 + 749 = 1500 — вместе; 750 + 2 + 749 = 1501 — порознь
  local c = para("в", 750)
  local out = chunk.split(a .. "\n\n" .. b .. "\n\n" .. c)
  t.eq(#out, 2, "1500 в упаковке — вместе")
  t.ok(out[1]:find(a, 1, true) and out[1]:find(b, 1, true), "а и б в первом куске")
  out = chunk.split(para("а", 750) .. "\n\n" .. b .. "\n\n" .. c)
  t.eq(#out, 3, "1501 в упаковке — порознь")
  -- по 700 знаков (1400 байт): в байтах каждый абзац шёл бы отдельно, в знаках — по два
  local ps = {}
  for i = 1, 4 do ps[i] = para("п" .. i, 700) end
  out = chunk.split(table.concat(ps, "\n\n"))
  t.eq(#out, 2, "по два абзаца по 700 знаков")
end

-- ≤ WHOLE знаков — кусок как есть, без нормализации пробелов и абзацев (и при > WHOLE байт)
function tests.test_short_text_kept_verbatim()
  local text = "  " .. para("а", 600) .. "\n\n\n" .. para("б", 600) .. "\r\n\r\n" .. para("в", 200) .. " \n"
  t.ok(#text > chunk.WHOLE and ulen(text) <= chunk.WHOLE, "байт больше WHOLE, знаков — нет")
  local out = chunk.split(text)
  t.eq(#out, 1, "один кусок")
  t.eq(out[1], text, "дословно")
end

-- перекрытие начинается с целого слова: абзац 899 знаков, хвост 300 начинается с 600-го знака — внутри «пять»
function tests.test_overlap_starts_at_word()
  local cycle = "один два три четыре пять шесть семь "
  local words = {}
  for w in cycle:gmatch("%S+") do words[w] = true end
  local p = string.rep(cycle, 25):sub(1, -2) -- 899 знаков, без хвостового пробела
  local chars = {}
  for ch in p:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  t.eq(#chars, 899, "посылка: длина в знаках")
  t.ok(not chars[#chars - chunk.OVERLAP]:match("%s") and not chars[#chars - chunk.OVERLAP + 1]:match("%s"),
    "посылка: срез 300 — внутри слова")
  local out = chunk.split(table.concat({ p, p, p, p }, "\n\n"))
  t.ok(#out >= 2, "несколько кусков")
  for k = 2, #out do
    local head = out[k]:match("^(.-)\n\n")
    t.ok(head and #head > 0, "кусок " .. k .. " с перекрытием")
    local first = head:match("^(%S+)")
    t.ok(first and words[first], "кусок " .. k .. ": перекрытие с целого слова, а не «" .. tostring(first) .. "»")
  end
end

function tests.test_crlf_paragraphs()
  local paras = {}
  for i = 1, 6 do paras[i] = para("п" .. i, 500) end
  local out = chunk.split(table.concat(paras, "\r\n\r\n"))
  t.eq(#out, 3, "CRLF-абзацы пакуются как LF")
  for k, c in ipairs(out) do t.ok(not c:find("\r", 1, true), "кусок " .. k .. " без \\r") end
end

function tests.test_cap_8000()
  t.eq(chunk.CAP, 8000, "CAP")
  -- абзац длиннее WHOLE, но короче CAP — один кусок, не режется
  local mid = para("с", 5000)
  local out = chunk.split(mid)
  t.eq(#out, 1, "абзац 5000 знаков — один кусок")
  t.eq(out[1], mid, "без изменений")
  -- абзац 20 000 знаков без пустых строк — режется, ни один кусок не длиннее CAP, текст не теряется
  local huge = para("б", 20000)
  out = chunk.split(huge)
  t.ok(#out >= 3, "на части: " .. #out)
  local total = 0
  for k, c in ipairs(out) do
    t.ok(ulen(c) <= chunk.CAP, "кусок " .. k .. " ≤ CAP: " .. ulen(c))
    total = total + ulen(c)
  end
  t.ok(total >= 20000, "текст не потерян: " .. total)
  t.eq(out[1], huge:sub(1, #out[1]), "первый кусок — начало абзаца")
end

function tests.test_no_broken_utf8()
  -- без пробелов и пустых строк, вперемешку 1-, 2-, 3- и 4-байтные знаки: резка только по кодпойнтам
  local unit = "aж€😀"
  local text = string.rep(unit, 5000) -- 20 000 знаков
  local out = chunk.split(text)
  t.ok(#out >= 3, "на части")
  for k, c in ipairs(out) do t.ok(valid_utf8(c), "кусок " .. k .. " — целый UTF-8") end
  -- абзацы со смешанными знаками: перекрытие тоже не рвёт знак
  local paras = {}
  for i = 1, 8 do paras[i] = string.rep("ж😀 €", 100) .. i end
  out = chunk.split(table.concat(paras, "\n\n"))
  t.ok(#out >= 2, "абзацы на несколько кусков")
  for k, c in ipairs(out) do t.ok(valid_utf8(c), "кусок с перекрытием " .. k .. " — целый UTF-8") end
end

t.run(tests)
