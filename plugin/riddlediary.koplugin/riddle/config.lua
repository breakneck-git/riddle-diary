-- Загрузка /mnt/us/riddle/config.lua (ключи и правила печати; в git не лежат).
-- Нет файла или он битый → конфиг без ключей: дневник тогда отвечает только «сонными» фразами.
-- Печать — таблица seal (spec 2026-11-20 §3): правила, а не слово; образец ключа пишет дневник, не конфиг.

local str = require("riddle.str")

local config = {}

config.DEFAULT_PATH = "/mnt/us/riddle/config.lua"

local PLACEHOLDERS = { your_token_here = true }
local KEY_FIELDS = { "gemini_key", "notion_token" }

-- ключ без пробелов и переводов строки по краям; пусто или заглушка — нет ключа
local function clean_key(v)
  if type(v) ~= "string" then return nil end
  v = str.trim(v)
  if v == "" or PLACEHOLDERS[v] then return nil end
  return v
end

-- непустая строка без пробелов по краям или nil
local function clean_str(v)
  if type(v) ~= "string" then return nil end
  v = str.trim(v)
  return v ~= "" and v or nil
end

-- providers: любой OpenAI-совместимый сервер строкой { name, url (полный …/chat/completions), model, key? }.
-- Без key — без заголовка Authorization (сервер без ключа). Пропущена запись без url/model, с url не на
-- https:// (другого транспорта нет) и с ключом не строкой, пустым или заглушкой: без ключа запрос
-- ушёл бы неавторизованным. after_legacy = true — запись идёт после ключей Gemini (запасная).
-- max_tokens — потолок ответа модели (целое 1..MAX_TOKENS_CAP); не задан или некорректен — по умолчанию llm.lua.
-- max_input_chars — лимит знаков текста запроса (целое 1..MAX_INPUT_CHARS_CAP): запрос урезается
-- prompt.fit (Groq: ITPM 7000); не задан или некорректен — полный запрос.
-- format = "gemini" — нативный generateContent (gemini-proxy): url — корень API, proxy_auth — токен прокси
-- (заголовок X-Proxy-Auth). Другой format, proxy_auth не строкой, пустой или заглушка — запись пропущена.
local MAX_TOKENS_CAP = 4096
local MAX_INPUT_CHARS_CAP = 1000000
local function int_in(v, cap)
  return type(v) == "number" and v >= 1 and v <= cap and v == math.floor(v) and v or nil
end
local function clean_providers(list)
  local out = {}
  if type(list) ~= "table" then return out end
  for _, e in ipairs(list) do
    if type(e) == "table" then
      local url, model = clean_str(e.url), clean_str(e.model)
      local key = e.key ~= nil and clean_key(e.key) or nil
      local proxy_auth = e.proxy_auth ~= nil and clean_key(e.proxy_auth) or nil
      if url and url:find("^https://") and model and (e.key == nil or key)
          and (e.format == nil or e.format == "gemini") and (e.proxy_auth == nil or proxy_auth) then
        out[#out + 1] = { name = clean_str(e.name) or url:match("^%a+://([^/:?#]+)") or "custom",
                          url = url, model = model, key = key, format = e.format, proxy_auth = proxy_auth,
                          after_legacy = e.after_legacy == true or nil,
                          max_tokens = int_in(e.max_tokens, MAX_TOKENS_CAP),
                          max_input_chars = int_in(e.max_input_chars, MAX_INPUT_CHARS_CAP) }
      end
    end
  end
  return out
end

-- поля таблицы seal — одно место: разбор (parse_seal) и сборка строки для устройства (seal_lua, tools/push_config.sh)
-- читают только этот список. kind: boolean — true/false; count — целое ≥ 1. default — значение, пока поле не
-- задано (нет default — поля в таблице нет)
config.SEAL_FIELDS = {
  { name = "key", kind = "boolean", default = false },
  { name = "minutes", kind = "count" },
  { name = "on_sleep", kind = "boolean", default = false },
  { name = "remember", kind = "boolean", default = true },
  { name = "off", kind = "boolean", default = false },
}

local SEAL_KIND = {}
for _, f in ipairs(config.SEAL_FIELDS) do SEAL_KIND[f.name] = f.kind end

local function valid_value(kind, v)
  if kind == "boolean" then return type(v) == "boolean" end
  return type(v) == "number" and v >= 1 and v < math.huge and v == math.floor(v)
end

-- правила печати из raw.seal (spec §3). Всегда таблица:
-- { on, key, minutes, on_sleep, remember, off, invalid }. on — печать есть: хоть одно правило и нет off.
-- invalid — причина, по которой правила битые (не таблица, неизвестное поле — опечатка вроде kye, значение не того
-- вида, правило закрытия без key): печать тогда есть и закрыта; off побеждает всё, в том числе битые правила — это
-- выход из битого конфига
function config.parse_seal(raw)
  local s = { on = false }
  for _, f in ipairs(config.SEAL_FIELDS) do s[f.name] = f.default end
  if raw == nil then return s end
  local invalid
  if type(raw) ~= "table" then
    invalid = "seal is not a table"
  else
    for k in pairs(raw) do
      if not SEAL_KIND[k] then invalid = invalid or ("unknown field " .. tostring(k)) end
    end
    for _, f in ipairs(config.SEAL_FIELDS) do
      local v = raw[f.name]
      if v ~= nil then
        if valid_value(f.kind, v) then
          s[f.name] = v
        else
          invalid = invalid or (f.name .. (f.kind == "boolean" and " is not a boolean" or " is not an integer >= 1"))
        end
      end
    end
    -- правило закрытия без ключа: закрыть можно, открыть нечем
    if not s.key and (raw.minutes ~= nil or s.on_sleep) then
      invalid = invalid or "close rule without key"
    end
  end
  if s.off then return s end
  s.invalid = invalid
  s.on = invalid ~= nil or s.key
  return s
end

-- строка Lua «seal = { … },» для config.lua устройства: поля, заданные в raw, значениями после разбора, в порядке
-- SEAL_FIELDS. -> строка | nil, причина (битые правила не пишутся)
function config.seal_lua(raw)
  local s = config.parse_seal(raw)
  if s.invalid then return nil, s.invalid end
  local parts = {}
  for _, f in ipairs(config.SEAL_FIELDS) do
    if raw[f.name] ~= nil then parts[#parts + 1] = f.name .. " = " .. tostring(s[f.name]) end
  end
  return "seal = { " .. table.concat(parts, ", ") .. " },"
end

function config.load(path)
  path = path or config.DEFAULT_PATH
  local ok, raw = pcall(dofile, path)
  -- файл есть, но не загрузился: что в нём было, неизвестно — печать закрыта (cfg.seal.invalid)
  local broken = false
  if not ok or type(raw) ~= "table" then
    local f = io.open(path, "r")
    if f then f:close(); broken = true end
    raw = {}
  end

  local cfg = {}
  for _, field in ipairs(KEY_FIELDS) do
    cfg[field] = clean_key(raw[field])
  end

  -- запасные ключи Gemini: список строк; пустые, заглушки и дубли отброшены
  cfg.gemini_keys = {}
  if type(raw.gemini_keys) == "table" then
    local seen = {}
    for _, v in ipairs(raw.gemini_keys) do
      local k = clean_key(v)
      if k and not seen[k] then
        seen[k] = true
        cfg.gemini_keys[#cfg.gemini_keys + 1] = k
      end
    end
  end

  cfg.providers = clean_providers(raw.providers)

  -- значения свойства знания, при которых документ пройден (сверка советов дневника): список непустых строк без
  -- пробелов по краям, без дублей; нет или пусто — сверка выключена. Слова данных живут только в конфиге на устройстве
  cfg.watched_values = {}
  if type(raw.watched_values) == "table" then
    local seen = {}
    for _, v in ipairs(raw.watched_values) do
      local s = clean_str(v)
      if s and not seen[s] then
        seen[s] = true
        cfg.watched_values[#cfg.watched_values + 1] = s
      end
    end
  end

  -- название или id базы задач (данные пользователя); нет — дневник ищет сам
  cfg.tasks_source = clean_str(raw.tasks_source)

  -- чей это дневник — свободный текст («Гермиона Грейнджер», «Том Реддл из «Методов рационального мышления»»);
  -- по нему дневник получает персону (riddle.persona). Нет — пока персона «Методов»
  cfg.whose = clean_str(raw.whose)

  cfg.seal = config.parse_seal(raw.seal)
  if broken then
    cfg.seal.on = true
    cfg.seal.invalid = "config file did not load"
  end
  -- старое слово (до графического ключа) не читается; флаг — для строки в логе
  if raw.password_variants ~= nil then cfg.legacy_word = true end
  return cfg
end

return config
