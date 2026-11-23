-- Ядро задач: работает только с общим форматом (коллекции и задачи в knowledge, см. knowledge.lua) и не знает,
-- откуда данные — источник пишет общий формат сам. Выбор базы задач, совпадение названия, список незакрытых,
-- блок с метками для промпта.
local str = require("riddle.str")

local tasks = {}

-- задач в блоке промпта не больше; общее число незакрытых — отдельно
tasks.LIMIT = 30

-- нижний регистр кириллицы по кодам UTF-8 (string.lower её не трогает); «ё» — как «е»
local UPPER = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯё"
local LOWER = "абвгдеежзийклмнопрстуфхцчшщъыьэюяе"
local TO_LOWER = {}
do
  local up, lo = {}, {}
  for ch in UPPER:gmatch("[\208\209][\128-\191]") do up[#up + 1] = ch end
  for ch in LOWER:gmatch("[\208\209][\128-\191]") do lo[#lo + 1] = ch end
  for i = 1, #up do TO_LOWER[up[i]] = lo[i] end
end

-- для сравнения названий: нижний регистр латиницы и кириллицы, ё → е, одной строкой (str.one_line)
function tasks.fold(s)
  s = tostring(s or ""):lower():gsub("[\208\209][\128-\191]", function(ch) return TO_LOWER[ch] or ch end)
  return str.one_line(s)
end

-- -> collection | nil, "none" | "many": равенство fold; иначе единственная, чьё название содержит name или
-- входит в него (обычный текст, не шаблон)
function tasks.match_title(collections, name)
  local want = tasks.fold(name)
  if want == "" then return nil, "none" end
  local equal, near = {}, {}
  for _, c in ipairs(collections) do
    local have = tasks.fold(c.title)
    if have == want then
      equal[#equal + 1] = c
    elseif have ~= "" and (have:find(want, 1, true) or want:find(have, 1, true)) then
      near[#near + 1] = c
    end
  end
  local found = #equal > 0 and equal or near
  if #found == 1 then return found[1] end
  return nil, #found == 0 and "none" or "many"
end

-- слова fold(s) множеством: слово — буквы и цифры (латиница, кириллица), всё прочее — разделитель
local function words(s)
  s = tasks.fold(s):gsub("[\192-\255][\128-\191]*", function(ch)
    return ch:match("^[\208\209][\128-\191]$") and ch or " "
  end):gsub("[^%w\128-\191\208\209]", " ")
  local set, n = {}, 0
  for w in s:gmatch("%S+") do
    if not set[w] then set[w], n = true, n + 1 end
  end
  return set, n
end

local function subset(a, b)
  for w in pairs(a) do
    if not b[w] then return false end
  end
  return true
end

-- слово модели (поле tasks_source; модель берёт название из списка): -> collection | nil, "none" | "many".
-- Равенство fold; иначе единственная, у которой все слова слова модели есть среди слов названия или наоборот —
-- только целыми словами: подстрокой «нет» находила «Интернет-покупки». match_title (конфиг) — прежний
function tasks.match_word(collections, name)
  local want = tasks.fold(name)
  local want_words, n = words(want)
  if n == 0 then return nil, "none" end
  local equal, near = {}, {}
  for _, c in ipairs(collections) do
    local have = tasks.fold(c.title)
    if have == want then
      equal[#equal + 1] = c
    else
      local have_words, m = words(have)
      if m > 0 and (subset(want_words, have_words) or subset(have_words, want_words)) then near[#near + 1] = c end
    end
  end
  local found = #equal > 0 and equal or near
  if #found == 1 then return found[1] end
  return nil, #found == 0 and "none" or "many"
end

-- значение пользователя или конфига: сначала id, потом название; -> collection | nil
local function named(collections, value)
  if type(value) ~= "string" or not value:find("%S") then return nil end
  for _, c in ipairs(collections) do
    if c.id == value then return c end
  end
  return (tasks.match_title(collections, value))
end

-- -> collection | nil, why: "user" | "config" | "native" | "model" | "depth" | "none".
-- Слово пользователя и конфиг могут назвать любую коллекцию; дальше — только task_candidate, среди них
-- native_tasks → model_pick → меньшая depth (равенство — по id)
function tasks.pick_source(collections, user_word, cfg_value)
  local c = named(collections, user_word)
  if c then return c, "user" end
  c = named(collections, cfg_value)
  if c then return c, "config" end
  local best
  local function rank(x)
    return (x.native_tasks and 0 or x.model_pick and 1 or 2), x.depth or math.huge
  end
  for _, x in ipairs(collections) do
    if x.task_candidate then
      if not best then
        best = x
      else
        local r1, d1 = rank(x)
        local r2, d2 = rank(best)
        if r1 < r2 or (r1 == r2 and (d1 < d2 or (d1 == d2 and x.id < best.id))) then best = x end
      end
    end
  end
  if not best then return nil, "none" end
  return best, best.native_tasks and "native" or best.model_pick and "model" or "depth"
end

local function present(s)
  return type(s) == "string" and s:find("%S") ~= nil
end

-- незакрытые: open, не archived, с непустым title; по due возр. (без срока — после), затем edited убыв.
-- (без edited — после), затем id
function tasks.open_list(task_rows)
  local out = {}
  for _, r in ipairs(task_rows) do
    if r.open and not r.archived and present(r.title) then out[#out + 1] = r end
  end
  table.sort(out, function(a, b)
    local da, db = present(a.due) and a.due, present(b.due) and b.due
    if da ~= db then
      if not da or not db then return da ~= false end
      return da < db
    end
    local ea, eb = present(a.edited) and a.edited, present(b.edited) and b.edited
    if ea ~= eb then
      if not ea or not eb then return ea ~= false end
      return ea > eb
    end
    return a.id < b.id
  end)
  return out
end

-- -> { items = {{label = "t1", id, title, due, project}…} (≤ LIMIT), total = #open_list, by_label = {t1 = id…} }
function tasks.block(open_list)
  local items, by_label = {}, {}
  for i = 1, math.min(#open_list, tasks.LIMIT) do
    local r = open_list[i]
    local label = "t" .. i
    items[i] = { label = label, id = r.id, title = r.title, due = r.due, project = r.project }
    by_label[label] = r.id
  end
  return { items = items, total = #open_list, by_label = by_label }
end

return tasks
