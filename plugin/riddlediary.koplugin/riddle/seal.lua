-- Печать: нечёткое сравнение заветного слова, счётчик неудач, подсказки.
-- Чистая логика, без UI и сети. Слово и подсказки — из конфига (cfg.password_variants, cfg.hints).
local str = require("riddle.str")

local seal = {}

local codepoints = str.codepoints

-- латинские двойники ↔ кириллица (a e o p c x y k m t b h → а е о р с х у к м т в н)
local LAT = { "a", "e", "o", "p", "c", "x", "y", "k", "m", "t", "b", "h" }
local CYR = { 0x430, 0x435, 0x43E, 0x440, 0x441, 0x445, 0x443, 0x43A, 0x43C, 0x442, 0x432, 0x43D }
local lat2cyr, cyr2lat = {}, {}
for i = 1, #LAT do
  local lat = LAT[i]:byte()
  lat2cyr[lat] = CYR[i]
  cyr2lat[CYR[i]] = lat
end

-- нижний регистр, ё → е; nil — символ не буква (отбрасывается)
local function fold(cp)
  if cp >= 0x41 and cp <= 0x5A then return cp + 0x20 end -- A-Z
  if cp >= 0x61 and cp <= 0x7A then return cp end         -- a-z
  if cp == 0x401 or cp == 0x451 then return 0x435 end     -- Ё ё → е
  if cp >= 0x410 and cp <= 0x42F then return cp + 0x20 end -- А-Я
  if cp >= 0x430 and cp <= 0x44F then return cp end       -- а-я
  return nil
end

-- нормализация в массив кодпойнтов
local function norm_cps(s, latin)
  local out = {}
  for _, cp in ipairs(codepoints(s)) do
    local f = fold(cp)
    if f then
      if latin then f = cyr2lat[f] or f else f = lat2cyr[f] or f end
      out[#out + 1] = f
    end
  end
  return out
end

-- кодпойнт → UTF-8 (в LuaJIT нет utf8.char); хватает BMP
local function encode(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  end
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- нижний регистр по fold (латиница, кириллица, ё → е); прочие знаки — как есть, байт в байт
function seal.lower(s)
  return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(ch)
    local f = fold(codepoints(ch)[1])
    return f and encode(f) or ch
  end))
end

function seal.normalize(s, latin)
  local parts = {}
  for i, cp in ipairs(norm_cps(s or "", latin)) do parts[i] = encode(cp) end
  return table.concat(parts)
end

-- Левенштейн между a[i1..i2] и b (массивы кодпойнтов)
local function levenshtein(a, i1, i2, b)
  local m, n = i2 - i1 + 1, #b
  local prev, cur = {}, {}
  for j = 0, n do prev[j] = j end
  for i = 1, m do
    cur[0] = i
    local ai = a[i1 + i - 1]
    for j = 1, n do
      local cost = (ai == b[j]) and 0 or 1
      local v = prev[j] + 1
      local w = cur[j - 1] + 1
      local x = prev[j - 1] + cost
      if w < v then v = w end
      if x < v then v = x end
      cur[j] = v
    end
    prev, cur = cur, prev
  end
  return prev[n]
end

-- допуск ошибок зависит от длины варианта: короткие (до 7 букв) строже (≤1; слово целиком — см. found)
local SHORT_LEN = 7
local function max_dist(nv)
  return nv <= SHORT_LEN and 1 or 2
end

-- слово (norm. variant) найдено в норм. строке: окна длиной #v±d, Левенштейн ≤ d
local function found(hay, needle)
  local nv = #needle
  if nv == 0 then return false end
  -- короткий вариант: слово целиком длиной nv±1 принимается с допуском 2 (почерк: «в» читается как «б»,
  -- буква теряется);
  -- внутри длинного слова он остаётся строгим (допуск 1)
  if nv <= SHORT_LEN and #hay >= nv - 1 and #hay <= nv + 1 and levenshtein(hay, 1, #hay, needle) <= 2 then
    return true
  end
  local d = max_dist(nv)
  local lo, hi = math.max(1, nv - d), nv + d
  for start = 1, #hay do
    for len = lo, hi do
      local stop = start + len - 1
      if stop > #hay then break end
      if levenshtein(hay, start, stop, needle) <= d then return true end
    end
  end
  return false
end

-- «мягкие» границы между словами: пробел, перенос, дефис (в т.ч. перенос слова на новую строку).
-- Любая другая не-буква (запятая, точка, !, ? …) — «жёсткая»: склейка через неё не допускается.
local SOFT = { [9] = true, [10] = true, [13] = true, [32] = true, [0xA0] = true, [0x2D] = true, [0xAD] = true,
  [0x2010] = true, [0x2011] = true }

-- сегменты (между жёсткими границами) → слова (между мягкими) → кодпойнты, латиница → кириллица
local function segments(s)
  local segs, words, cur = {}, {}, {}
  local function close_word()
    if #cur > 0 then words[#words + 1] = cur; cur = {} end
  end
  local function close_seg()
    close_word()
    if #words > 0 then segs[#segs + 1] = words; words = {} end
  end
  for _, cp in ipairs(codepoints(s)) do
    local f = fold(cp)
    if f then
      cur[#cur + 1] = lat2cyr[f] or f
    elseif SOFT[cp] then
      close_word()
    else
      close_seg()
    end
  end
  close_seg()
  return segs
end

-- склейка целых слов words[i..j] в одну строку кодпойнтов
local function concat(words, i, j)
  local out = {}
  for k = i, j do
    for _, cp in ipairs(words[k]) do out[#out + 1] = cp end
  end
  return out
end

-- Варианты ищутся: (1) внутри одного слова — любым окном; (2) склейкой целых слов подряд
-- в пределах сегмента — целиком, без обрезки слов (обрезанные края соседних слов дают ложные совпадения).
-- Один проход (латиница → кириллица): латинский проход давал ровно тот же результат,
-- потому что двойники взаимно однозначны и сдвигают обе стороны сравнения одинаково.
local function found_in_segment(words, needle)
  local nv = #needle
  local d = max_dist(nv)
  for i = 1, #words do
    if found(words[i], needle) then return true end
    local len = #words[i]
    for j = i + 1, #words do
      len = len + #words[j]
      if len > nv + d then break end
      if len >= nv - d then
        local cand = concat(words, i, j)
        -- короткий вариант через границу слов — только точно, правки дают ложные срабатывания
        local dg = nv <= SHORT_LEN and 0 or d
        if levenshtein(cand, 1, #cand, needle) <= dg then return true end
      end
    end
  end
  return false
end

function seal.matches(read, variants)
  local segs = segments(read or "")
  for _, v in ipairs(variants) do
    local needle = norm_cps(v, false)
    if #needle > 0 then
      for _, words in ipairs(segs) do
        if found_in_segment(words, needle) then return true end
      end
    end
  end
  return false
end

local Seal = {}
Seal.__index = Seal

-- hints — подсказки по кругу, в порядке списка; пусто — каждая неудача просто отказ
function seal.new(variants, hint_every, hints)
  return setmetatable({
    variants = variants,
    hint_every = hint_every or 3,
    hints = hints or {},
    open = false,
    fails = 0,
    hints_given = 0,
  }, Seal)
end

function Seal:lock()
  self.open = false
  self.fails = 0
  self.hints_given = 0
end

function Seal:feed(read)
  if self.open then return nil end
  if #norm_cps(read or "", false) == 0 then
    return { kind = "unreadable" } -- «?» и пустое: не попытка
  end
  if seal.matches(read, self.variants) then
    self.open = true
    return { kind = "unlock" } -- приветствие выбирает контроллер: набор персоны (Controller:texts("welcomes"))
  end
  self.fails = self.fails + 1
  if self.fails % self.hint_every == 0 and #self.hints > 0 then
    local idx = self.hints_given % #self.hints + 1
    self.hints_given = self.hints_given + 1
    return { kind = "hint", hint = self.hints[idx] }
  end
  return { kind = "refuse" }
end

return seal
