-- «Чей это дневник» (спека docs/superpowers/specs/2026-10-31-whose-diary-design.md): строка → персонаж.
-- Чистая логика без UI, сети и базы: ключ строки, распознавание встроенной персоны «Методов», разделы генерации
-- (запрос, проверка ответа) и вид персонажа для промпта. Хранит контроллер (memory: personas, persona_parts).
local json = require("dkjson")
local llm = require("riddle.llm")
local mapdata = require("riddle.mapdata")
local prompt = require("riddle.prompt")
local str = require("riddle.str")
local terrain = require("riddle.terrain")
local texts = require("riddle.texts")

local persona = {}

-- строка personas встроенной персоны «Методов» (миграция 5, riddle/memory.lua)
persona.METHODS_ID = 1

-- встроенная персона «Методов»: промпт и фразы — прежние, в коде (prompt.lua, texts.lua); генерируются только данные
-- карты (persona.MAP_SECTIONS)
persona.METHODS_VIEW = { id = persona.METHODS_ID, builtin = true, lang = "ru", gender = "m", kind = "дневник",
  title = "Дневник Реддла" }

-- персонажа нет (вопрос «чей дневник», раздела persona ещё нет): служебные промпты пишут на языке записи, о себе без
-- рода (prompt.locked / summarize / roll); имя меню — DEFAULT_TITLE
persona.NONE_VIEW = { none = true }
persona.DEFAULT_TITLE = "Дневник / Diary"

-- ключ строки: без пробелов (%s) по краям, пробелы схлопнуты, нижний регистр (ё → е); прочие знаки — как есть.
-- Не str.one_line: ключ хранится в базе (personas.key, UNIQUE) и ищется persona_by_key — склейка неразрывного пробела
-- сменила бы ключ персоны, сохранённой со строкой с U+00A0, и её память стала бы недоступна
function persona.key(line)
  local s = str.trim(line):gsub("%s+", " ")
  return str.lower(s)
end

-- «Методы» — маркер мира и маркер героя вместе: «Том Реддл» без мира — канон Роулинг, другой персонаж.
-- Точное вхождение в нижнем регистре, не нечёткий поиск: строка напечатана, а нечёткий принимал
-- «национального» за «рационального» (одна правка)
local WORLD = { "рациональн", "hpmor", "rationality" }
local HERO = { "реддл", "волдеморт", "riddle", "voldemort" }

local function any_in(s, list)
  for _, needle in ipairs(list) do
    if s:find(needle, 1, true) then return true end
  end
  return false
end

-- язык нейтрального голоса по строке конфига, пока персоны (и её языка) нет: есть кириллица — "ru", иначе "en"
function persona.lang_of(line)
  return type(line) == "string" and line:find("[\208\209][\128-\191]") and "ru" or "en"
end

function persona.is_methods(line)
  local s = str.lower(line)
  return any_in(s, WORLD) and any_in(s, HERO)
end

local function nonempty(v) return type(v) == "string" and v:find("%S") ~= nil end

local PERSONA_KEYS = { "head", "body", "lang", "lang_name", "kind", "title", "invitation" }
local GENDERS = { m = true, f = true, n = true }

-- JSON-массив в ответе модели (бывает в ```-обёртке или с пояснением вокруг) -> таблица | nil
local function find_array(text)
  local a, b = text:find("%[.*%]")
  if not a then return nil end
  local v = json.decode(text:sub(a, b))
  return type(v) == "table" and v or nil
end

-- раздел texts.<name>: набор фраз голосом персонажа; годных (texts.clean) меньше texts.MIN_POOL — не сохраняется
local function text_section(set)
  return {
    name = "texts." .. set.name,
    max_tokens = 2000,
    messages = function(_, view) return prompt.gen_texts(set, view) end,
    decode = function(text, lang)
      local list = type(text) == "string" and find_array(text)
      if not list then return nil, "not json" end
      local kept = texts.clean(set.name, list, lang)
      if #kept < texts.MIN_POOL then return nil, "pool " .. #kept end
      return json.encode(kept)
    end,
  }
end

-- мир длиннее не сохраняется (раздел world): в лор он делит потолок с lore.md (prompt.lore_block), а запрос с ним
-- идёт каждой странице
persona.WORLD_MAX_CHARS = 4000

-- разделы генерации по порядку; раздел — одним вызовом модели (план, решение 3). messages(row, view) — запрос по
-- строке personas и готовой персоне (наборам фраз она нужна); decode(text, lang) -> текст для persona_parts | nil,
-- причина
persona.SECTIONS = {
  {
    name = "persona",
    max_tokens = 3000,
    messages = function(row) return prompt.gen_persona(row.line) end,
    decode = function(text)
      local obj = type(text) == "string" and llm.find_object(text)
      if not obj then return nil, "not json" end
      for _, k in ipairs(PERSONA_KEYS) do
        if not nonempty(obj[k]) then return nil, "no " .. k end
      end
      if not GENDERS[obj.gender] then return nil, "bad gender" end
      -- приглашение — фраза на экране: правила формы те же, что у наборов
      if not texts.fits(texts.INVITATION, obj.invitation, obj.lang) then return nil, "bad invitation" end
      local out = {}
      for _, k in ipairs(PERSONA_KEYS) do out[k] = obj[k] end
      out.gender = obj.gender
      return json.encode(out)
    end,
  },
  {
    name = "world",
    max_tokens = 3000,
    messages = function(row, view) return prompt.gen_world(view, row.line) end,
    decode = function(text)
      if type(text) ~= "string" then return nil, "not text" end
      -- модель иногда оборачивает ответ в ```
      local body = text:match("^%s*```[^\n]*\n(.-)\n?```%s*$") or text
      body = str.trim(body)
      if body == "" then return nil, "empty" end
      if prompt.utf8_len(body) > persona.WORLD_MAX_CHARS then return nil, "too long" end
      return body
    end,
  },
}
for _, set in ipairs(texts.SETS) do persona.SECTIONS[#persona.SECTIONS + 1] = text_section(set) end

-- название места, имя героя или владельца (mapdata.of): непустая строка не длиннее max знаков -> без пробелов по
-- краям | nil
local function short(v, max)
  if type(v) ~= "string" then return nil end
  v = str.trim(v)
  if v == "" or prompt.utf8_len(v) > max then return nil end
  return v
end
persona.short = short

local function in_list(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

-- фразы раздела map — на экране карты: правила формы те же, что у приглашения
local MAP_PHRASES = { "open", "close", "blind" }

-- данные карты мародёров (план карты, раздел 2): один формат для всех персон, читает их только mapdata.of. Эти же
-- таблицы — в конце SECTIONS; у «Методов» генерируются только они (next_section)
persona.MAP_SECTIONS = {
  {
    name = mapdata.SECTION_MAP,
    max_tokens = 1500,
    messages = function(row, view) return prompt.gen_map(view, row.line) end,
    -- -> { potter, open, close, blind, places = { [kind] = name } }: места — только типы terrain.KINDS,
    -- негодное название места отброшено, раздел годен
    decode = function(text, lang)
      local obj = type(text) == "string" and llm.find_object(text)
      if not obj then return nil, "not json" end
      if type(obj.potter) ~= "boolean" then return nil, "bad potter" end
      local out = { potter = obj.potter, places = {} }
      for _, k in ipairs(MAP_PHRASES) do
        if not texts.fits(texts.INVITATION, obj[k], lang) then return nil, "bad " .. k end
        out[k] = str.trim(obj[k])
      end
      local places = type(obj.places) == "table" and obj.places or {}
      for _, kind in ipairs(terrain.KINDS) do out.places[kind] = short(places[kind], mapdata.PLACE_MAX) end
      return json.encode(out)
    end,
  },
  {
    name = mapdata.SECTION_CAST,
    max_tokens = 2000,
    messages = function(row, view) return prompt.gen_cast(view, row.line) end,
    -- -> [{ name, role, day, night }]: годные (имя и значения формата mapdata), без повторов имени, не больше
    -- mapdata.MAX_CAST; годных меньше mapdata.MIN_CAST — не сохраняется
    decode = function(text)
      local list = type(text) == "string" and find_array(text)
      if not list then return nil, "not json" end
      local kept, seen = {}, {}
      for _, c in ipairs(list) do
        local name = type(c) == "table" and short(c.name, mapdata.NAME_MAX)
        if name and not seen[name] and in_list(mapdata.ROLES, c.role) and in_list(mapdata.DAY, c.day)
            and in_list(mapdata.NIGHT, c.night) then
          seen[name] = true
          kept[#kept + 1] = { name = name, role = c.role, day = c.day, night = c.night }
          if #kept == mapdata.MAX_CAST then break end
        end
      end
      if #kept < mapdata.MIN_CAST then return nil, "cast " .. #kept end
      return json.encode(kept)
    end,
  },
}
for _, s in ipairs(persona.MAP_SECTIONS) do persona.SECTIONS[#persona.SECTIONS + 1] = s end

-- раздел данных карты: ответу не нужен, хвост не держит (Controller:_summary_job, take_followup)
function persona.is_map(name)
  return name == mapdata.SECTION_MAP or name == mapdata.SECTION_CAST
end

-- вопрос «Так это дневник … из …?» на языке строки (модель не дала годного); мир не назван — без «из»
function persona.ask_line(who, world, lang)
  local ru = lang == "ru"
  if world == nil or world == "" then
    return string.format(ru and "Так это дневник %s?" or "So this is the diary of %s?", who)
  end
  return string.format(ru and "Так это дневник %s из %s?" or "So this is the diary of %s from %s?", who, world)
end

local trimmed = str.trim

-- ответ resolve -> { state = "ready" | "confirm" | "rejected", ask?, line, lang } | nil, причина. Мир назван в строке
-- (world_named ровно true) — подтверждать нечего: ready, строка как написана. Мир не назван и модель его не знает —
-- имя неоднозначно, в генерацию оно не идёт: rejected (строка — как не названа: дневник спрашивает «Чей это
-- дневник?» пером, Controller:_config_line).
-- Иначе confirm: вопрос (модели, если он годен как фраза на экране, иначе шаблон) и строка с миром — по ней идёт
-- генерация, ключ персоны прежний. Строка разбора — данные пользователя: в лог не идёт
local ASK_RULE = { max_cps = 160, sentences = 2 }
local RESOLVE_NAME_MAX = 100

function persona.decode_resolve(text, line)
  local obj = type(text) == "string" and llm.find_object(text)
  if not obj then return nil, "not json" end
  local who, world = trimmed(obj.who), trimmed(obj.world)
  if who == "" then return nil, "no who" end
  if prompt.utf8_len(who) > RESOLVE_NAME_MAX or prompt.utf8_len(world) > RESOLVE_NAME_MAX then
    return nil, "too long"
  end
  local lang = trimmed(obj.lang):lower()
  if lang == "" or #lang > llm.LANG_MAX then lang = persona.lang_of(line) end
  if obj.world_named == true then return { state = "ready", line = line, lang = lang } end
  if world == "" then return { state = "rejected", line = line, lang = lang } end
  local ask = str.one_line(obj.ask)
  if ask == "" or not texts.fits(ASK_RULE, ask) then ask = persona.ask_line(who, world, lang) end
  return { state = "confirm", ask = ask, line = who .. " — " .. world, lang = lang }
end

-- разбор строки: задание, которым начинается генерация новой строки (state = "new"); не в SECTIONS — раздела в
-- persona_parts у него нет, результат ложится в строку personas (Memory:resolve_persona)
persona.RESOLVE = {
  name = "resolve",
  max_tokens = 400,
  messages = function(row) return prompt.resolve(row.line) end,
}

function persona.section(name)
  if name == persona.RESOLVE.name then return persona.RESOLVE end
  for _, s in ipairs(persona.SECTIONS) do
    if s.name == name then return s end
  end
end

local function first_missing(list, parts)
  for _, s in ipairs(list) do
    if not (parts and parts[s.name]) then return s end
  end
end

-- первый недостающий раздел (обрыв — продолжение с него) | nil (готово). У «Методов» — только данные карты.
-- Новая строка — сначала разбор (resolve); ждущая ответа на вопрос (confirm) и отказ (rejected) не генерируются
function persona.next_section(row, parts)
  if row.id == persona.METHODS_ID then return first_missing(persona.MAP_SECTIONS, parts) end
  if row.state == "new" then return persona.RESOLVE end
  if row.state == "confirm" or row.state == "rejected" then return nil end
  return first_missing(persona.SECTIONS, parts)
end

-- отвечает ли дневник голосом персонажа: «Методов» — всегда, остальные — когда готовы persona и world.
-- Наборы фраз включаются по одному и готовность не задерживают (недостающий — запасной пул)
function persona.ready(row, parts)
  if row.id == persona.METHODS_ID then return true end
  return parts ~= nil and parts.persona ~= nil and parts.world ~= nil
end

-- вид персонажа для промпта и меню | nil (раздела persona ещё нет)
function persona.view(row, parts)
  if row.id == persona.METHODS_ID then return persona.METHODS_VIEW end
  local obj = parts and parts.persona and json.decode(parts.persona)
  if type(obj) ~= "table" then return nil end
  return {
    id = row.id,
    -- «Ты — » модель иногда повторяет в начале: в промпте вышло бы «Ты — Ты — …»
    head = (obj.head:gsub("^%s*Ты%s*—%s*", "")),
    body = obj.body,
    lang = obj.lang,
    lang_name = obj.lang_name,
    gender = obj.gender,
    kind = obj.kind,
    title = obj.title,
    invitation = obj.invitation, -- у персоны, сохранённой до задачи 2, нет: приглашение — texts.invitation
  }
end

return persona
