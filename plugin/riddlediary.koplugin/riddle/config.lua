-- Загрузка /mnt/us/riddle/config.lua (ключи, заветное слово и подсказки печати; в git не лежат).
-- Нет файла или он битый → конфиг без ключей: дневник тогда отвечает только «сонными» фразами.
-- Заветное слово и подсказки хранятся только в config.lua на устройстве; здесь их нет
-- (без слова печать не открыть, без подсказок неудача — просто отказ).

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

local function valid_variants(v)
  if type(v) ~= "table" or #v == 0 then return false end
  for _, s in ipairs(v) do
    if type(s) ~= "string" or s == "" then return false end
  end
  return true
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

-- слова нет (не битое): поля нет или список из одних пустых строк — печать необязательна
local function no_variants(v)
  if v == nil then return true end
  if type(v) ~= "table" then return false end
  for _, s in pairs(v) do
    if s ~= "" then return false end
  end
  return true
end

function config.load(path)
  path = path or config.DEFAULT_PATH
  local ok, raw = pcall(dofile, path)
  -- файл есть, но не загрузился: что в нём было, неизвестно — печать закрыта (seal_invalid)
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

  local hint_every = raw.hint_every
  if type(hint_every) == "number" and hint_every >= 1 and hint_every == math.floor(hint_every) then
    cfg.hint_every = hint_every
  else
    cfg.hint_every = 3
  end

  -- подсказки печати: непустые строки по порядку, остальное отброшено
  cfg.hints = {}
  if type(raw.hints) == "table" then
    for _, s in ipairs(raw.hints) do
      if type(s) == "string" and s ~= "" then cfg.hints[#cfg.hints + 1] = s end
    end
  end

  if valid_variants(raw.password_variants) then
    cfg.password_variants = {}
    for i, s in ipairs(raw.password_variants) do cfg.password_variants[i] = s end
  else
    cfg.password_variants = {}
    -- слово есть, но битое: печать закрыта (открыть нечем), а не «печати нет»
    if broken or not no_variants(raw.password_variants) then cfg.seal_invalid = true end
  end
  return cfg
end

return config
