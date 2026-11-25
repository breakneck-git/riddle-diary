-- Запрос и разбор OpenAI-совместимого chat/completions (и нативного generateContent Gemini у провайдера
-- format = "gemini": gemini-proxy); цепочка провайдеров с общим бюджетом.
-- HTTP сюда подаётся снаружи (opts.post), поэтому модуль тестируется без сети.

local json = require("dkjson")
local str = require("riddle.str")

local llm = {}

local USER_AGENT = "riddle-diary/1.0"
local PER_PROVIDER_TIMEOUT_S = 4
local DEFAULT_BUDGET_S = 5
local DEFAULT_MAX_TOKENS = 200
-- меньше этого сверх резерва не-последнему не даём: запрос с таймаутом 0 или долями секунды пропадёт
local MIN_ATTEMPT_S = 2

-- латинские двойники -> кириллица (для ответа, который видит пользователь)
local LAT2CYR = {
  a = "а", e = "е", o = "о", p = "р", c = "с", x = "х", y = "у", k = "к", m = "м", t = "т", b = "в", h = "н",
  A = "А", B = "В", C = "С", E = "Е", H = "Н", K = "К", M = "М", O = "О", P = "Р", T = "Т", X = "Х", Y = "У",
}

local trim = str.trim

-- в слове, где есть хоть одна кириллическая буква, латинские двойники заменяются на кириллические
local function fix_homoglyphs(s)
  local chars = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  local function kind(ch)
    if #ch == 1 and ch:match("%a") then return "lat" end
    local b = ch:byte(1)
    if #ch == 2 and (b == 208 or b == 209) then return "cyr" end
  end
  local i = 1
  while i <= #chars do
    if kind(chars[i]) then
      local j, has_cyr = i, false
      while j <= #chars and kind(chars[j]) do
        if kind(chars[j]) == "cyr" then has_cyr = true end
        j = j + 1
      end
      if has_cyr then
        for k = i, j - 1 do chars[k] = LAT2CYR[chars[k]] or chars[k] end
      end
      i = j
    else
      i = i + 1
    end
  end
  return table.concat(chars)
end

-- сначала providers из конфига (любой OpenAI-совместимый сервер, по порядку списка), затем по провайдеру
-- gemini на каждый ключ (gemini_key, затем gemini_keys, без дублей); записи providers с
-- after_legacy = true идут в самом конце, после них (запасные: Groq, затем BeatAPI).
-- shift сдвигает стартовый ключ Gemini (нагрузка по всем ключам); key — номер ключа Gemini, для лога
-- и учёта мёртвых ключей: у providers из конфига его нет; key == nil у add — без заголовка Authorization.
-- format = "gemini" (gemini-proxy, Cloudflare Worker rss_bot): url — корень API, запрос нативный
-- generateContent, токен прокси proxy_auth — заголовком X-Proxy-Auth; ключ Google ставит сам прокси
function llm.providers(cfg, shift)
  local list = {}
  local function add(name, url, model, key, n, custom, max_tokens, max_input_chars, format, proxy_auth)
    list[#list + 1] = {
      name = name,
      format = format, -- "gemini" — нативный формат; nil — OpenAI-совместимый
      max_tokens = max_tokens, -- потолок ответа; nil — DEFAULT_MAX_TOKENS (BeatAPI режет ответ на 200)
      max_input_chars = max_input_chars, -- лимит знаков запроса (opts.fit); nil — полный запрос
      custom = custom, -- из providers конфига: для учёта мёртвых (у него нет номера ключа Gemini)
      url = url,
      model = model,
      key = n,
      headers = {
        ["Authorization"] = key and ("Bearer " .. key) or nil,
        ["X-Proxy-Auth"] = proxy_auth,
        ["Content-Type"] = "application/json",
        ["User-Agent"] = USER_AGENT,
      },
    }
  end
  local function have(v)
    return type(v) == "string" and v:match("%S") ~= nil
  end
  local custom = type(cfg.providers) == "table" and cfg.providers or {}
  local function add_custom(after)
    for _, e in ipairs(custom) do
      if type(e) == "table" and have(e.url) and have(e.model) and (e.after_legacy == true) == after then
        add(e.name or "custom", e.url, e.model, have(e.key) and e.key or nil, nil, true, e.max_tokens,
          e.max_input_chars, e.format, have(e.proxy_auth) and e.proxy_auth or nil)
      end
    end
  end
  add_custom(false)
  local keys, seen = {}, {}
  local function key(v)
    if not have(v) then return end
    v = trim(v)
    if seen[v] then return end
    seen[v] = true
    keys[#keys + 1] = v
  end
  key(cfg.gemini_key)
  for _, v in ipairs(type(cfg.gemini_keys) == "table" and cfg.gemini_keys or {}) do key(v) end
  for i = 0, #keys - 1 do
    local n = (i + (shift or 0)) % #keys + 1
    add("gemini", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      "gemini-3.5-flash-lite", keys[n], n)
  end
  add_custom(true)
  return list
end

-- сообщения OpenAI -> generateContent: все system — одна systemInstruction, assistant -> model, картинка
-- data:-URL -> inlineData; подряд одна роль — один ход, пустой текст не уходит (Gemini его не берёт)
local function native_body(messages, max_tokens, temperature)
  local system, contents = {}, {}
  for _, m in ipairs(messages) do
    local parts = {}
    local content = type(m.content) == "table" and m.content or { { type = "text", text = m.content } }
    for _, c in ipairs(content) do
      if c.type == "text" and type(c.text) == "string" and c.text ~= "" then
        parts[#parts + 1] = { text = c.text }
      elseif c.type == "image_url" and type(c.image_url) == "table" and type(c.image_url.url) == "string" then
        local mime, data = c.image_url.url:match("^data:([^;,]+);base64,(.*)$")
        if mime then parts[#parts + 1] = { inlineData = { mimeType = mime, data = data } } end
      end
    end
    if m.role == "system" then
      for _, part in ipairs(parts) do
        if part.text then system[#system + 1] = part.text end
      end
    elseif #parts > 0 then
      local role = m.role == "assistant" and "model" or "user"
      local last = contents[#contents]
      if last and last.role == role then
        for _, part in ipairs(parts) do last.parts[#last.parts + 1] = part end
      else
        contents[#contents + 1] = { role = role, parts = parts }
      end
    end
  end
  return {
    systemInstruction = #system > 0 and { parts = { { text = table.concat(system, "\n\n") } } } or nil,
    contents = contents,
    generationConfig = { temperature = temperature, maxOutputTokens = max_tokens },
  }
end

-- потолок ответа запроса: потолок провайдера (nil — DEFAULT_MAX_TOKENS), вызов может только поднять. Одно правило на
-- тело запроса (build) и на потолок попытки по длине ответа (call)
local function max_tokens_of(provider, max_tokens)
  return math.max(provider.max_tokens or DEFAULT_MAX_TOKENS, max_tokens or 0)
end

-- max_tokens — потолок вызова (пересказ сессии): поднимает потолок провайдера, но не опускает его;
-- temperature — вызова (классификация баз — 0), nil — 0.8 (ответы дневника)
function llm.build(provider, messages, max_tokens, temperature)
  max_tokens = max_tokens_of(provider, max_tokens)
  temperature = temperature or 0.8
  if provider.format == "gemini" then
    local native = native_body(messages, max_tokens, temperature)
    -- ни одной части user/assistant: Google на contents = [] отвечает 400 — в сеть не идём (nil, ошибка)
    if #native.contents == 0 then return nil, nil, "empty contents" end
    local url = provider.url:gsub("/+$", "") .. "/v1beta/models/" .. provider.model .. ":generateContent"
    return url, provider.headers, json.encode(native)
  end
  local body = {
    model = provider.model,
    messages = messages,
    temperature = temperature,
    max_tokens = max_tokens,
  }
  return provider.url, provider.headers, json.encode(body)
end

local function decode_object(text)
  local obj = json.decode(text)
  if type(obj) == "table" then return obj end
end

-- кандидаты: как есть, внутри ```-обёртки, от первой { до последней }
local function find_object(content)
  local c = trim(content)
  local obj = decode_object(c)
  if obj then return obj end
  local fenced = c:match("```[%w]*%s*(.-)```")
  if fenced then
    obj = decode_object(trim(fenced))
    if obj then return obj end
  end
  local first = c:find("{", 1, true)
  local last = c:match(".*()}")
  if first and last and last > first then
    return decode_object(c:sub(first, last))
  end
end
llm.find_object = find_object

-- необязательное строковое поле ответа: строка — без пробелов по краям, иначе (число, null, объект) — nil
local function opt_string(v)
  if type(v) == "string" then return trim(v) end
end

-- поле ответа настройки (who, world): непустая строка без пробелов по краям, иначе nil
local function opt_text(v)
  v = opt_string(v)
  return v ~= "" and v or nil
end

-- имя пишущего (name, prompt.NAME_FORMAT): непустая строка одной строкой (str.one_line), без латинских гомоглифов
-- (как reply): имя идёт на карту; иначе nil
local function opt_name(v)
  v = str.one_line(v)
  return v ~= "" and fix_homoglyphs(v) or nil
end

-- код языка (lang): короткий, не фраза (llm.LANG_MAX байт), иначе nil
llm.LANG_MAX = 8
local function opt_lang(v)
  v = opt_text(v)
  return v and #v <= llm.LANG_MAX and v or nil
end

-- действие карты (prompt.MAP_FORMAT — "open", prompt.map_read — "close"): только эти строки как есть, иначе nil
local MAP_ACTIONS = { open = true, close = true }
local function opt_map(v)
  if type(v) == "string" and MAP_ACTIONS[v] then return v end
end

-- picks (prompt.PICKS_FORMAT): массив строк без пробелов по краям, пустые и не строки — мимо; строка — одно название;
-- нет поля или другое значение — nil
local function opt_list(v)
  if type(v) == "string" then v = { v } end
  if type(v) ~= "table" then return nil end
  local out = {}
  for _, s in ipairs(v) do
    if type(s) == "string" and trim(s) ~= "" then out[#out + 1] = trim(s) end
  end
  return out
end

-- текст и причина конца ответа: OpenAI — choices[1].message.content и finish_reason; нативный Gemini —
-- текст всех частей candidates[1].content.parts подряд (рассуждение thought — мимо) и finishReason
local function answer_of(resp, format)
  if type(resp) ~= "table" then return end
  if format == "gemini" then
    local cand = type(resp.candidates) == "table" and resp.candidates[1]
    local parts = type(cand) == "table" and type(cand.content) == "table" and cand.content.parts
    if type(parts) ~= "table" then return end
    local out = {}
    for _, part in ipairs(parts) do
      if type(part) == "table" and type(part.text) == "string" and not part.thought then out[#out + 1] = part.text end
    end
    -- текста нет (одни thought-части): причина конца всё равно нужна — MAX_TOKENS это «truncated»
    if #out == 0 then return nil, cand.finishReason end
    return table.concat(out), cand.finishReason
  end
  local msg = type(resp.choices) == "table" and resp.choices[1]
  if type(msg) ~= "table" or type(msg.message) ~= "table" then return end
  return msg.message.content, msg.finish_reason
end

-- format — провайдера: "gemini" — нативный ответ generateContent, nil — OpenAI-совместимый
function llm.parse(status, body, want_json, format)
  if status ~= 200 then return nil, "http " .. tostring(status) end
  local content, finish = answer_of(json.decode(body or ""), format)
  -- обрыв по потолку ответа: OpenAI-совместимый — "length"; нативный Gemini — "MAX_TOKENS" (и сервер,
  -- отдающий причину по-своему). Обрезок — промах в обоих режимах
  local fin = type(finish) == "string" and finish:lower()
  local cut = fin == "length" or fin == "max_tokens"
  if type(content) ~= "string" then return nil, (cut and format == "gemini") and "truncated" or "bad body" end
  if cut then return nil, "truncated" end
  -- незакрытый <think> в начале ответа (рассуждение оборвалось) — до конца текста; дальше по тексту
  -- «<think>» — литерал (в строке JSON): вырезать его до конца — сломать ответ
  content = content:gsub("<think>.-</think>", ""):gsub("^%s*<think>.*$", "")

  if not want_json then
    local text = trim(content)
    if text == "" then return nil, "empty text" end
    return { text = text }
  end

  local obj = find_object(content)
  if not obj then return nil, "not json" end
  if type(obj.read) ~= "string" then return nil, "no read" end
  local read = trim(obj.read)
  -- пустой reply не ошибка разбора: ответа не просит чтение страницы на карте (reply_optional), фраза карты (map) и
  -- страница настройки обходятся без него (controller). Где он нужен, решают выше: llm.call держит такой ответ
  -- запасным и идёт к следующему провайдеру, ответ на страницу без reply — «нечитаемо» (controller.usable)
  local reply = type(obj.reply) == "string" and trim(obj.reply) or ""
  -- task — метка дела из блока задач (prompt.TASK_FORMAT), tasks_source — название книги дел, picks — что советует
  -- ответ (prompt.PICKS_FORMAT); who, world, lang, yes — ответ настройки (prompt.setup): yes — только булево true,
  -- строка "true" согласием не считается; нет — nil; map — действие карты (opt_map); name — как пишущий назвал себя в
  -- записи (opt_name), пусто — nil; needs_data — просьба о данных при закрытой печати (prompt.SEAL_CLOSED), как yes —
  -- только булево true
  return { read = read, reply = fix_homoglyphs(reply), task = opt_string(obj.task),
    tasks_source = opt_string(obj.tasks_source), picks = opt_list(obj.picks), who = opt_text(obj.who),
    world = opt_text(obj.world), lang = opt_lang(obj.lang), yes = obj.yes == true or nil, map = opt_map(obj.map),
    name = opt_name(obj.name), needs_data = obj.needs_data == true or nil }
end

-- квота провайдера в ответе 429: "day" | "minute" | nil (не 429 или признак у провайдера неизвестен). Одно правило на
-- лог (app: quota=day|minute) и на ошибку цепочки (llm.DAILY). Признак известен только у Gemini — прямого (p.key) и
-- gemini-proxy (format = "gemini": воркер rss_bot отдаёт тело 429 Google как есть): google.rpc.QuotaFailure, quotaId
-- …PerDay… / …PerMinute…, по всему телу (quotaId дальше первых 160 знаков); есть обе — "day". Groq (суточные лимиты —
-- только в заголовках x-ratelimit-*) и BeatAPI (суточного лимита в документации нет) — nil: их 429 суточным не считается
function llm.quota(p, status, body)
  if status ~= 429 or type(body) ~= "string" or not (p and (p.key or p.format == "gemini")) then return nil end
  if body:find("PerDay", 1, true) then return "day" end
  if body:find("PerMinute", 1, true) then return "minute" end
end

-- модель перегружена: gemini-proxy (format = "gemini") вернул 503 Google — тело JSON с error.code 503 («This model is
-- currently experiencing high demand», status UNAVAILABLE). Воркер rss_bot отдаёт ответ Google как есть, свои отказы
-- у него текстом (504 upstream timeout, 502 upstream fetch error), 503 Cloudflare — HTML: их это правило не ловит
function llm.overloaded(p, status, body)
  if status ~= 503 or not (p and p.format == "gemini") or type(body) ~= "string" then return false end
  local obj = decode_object(body)
  return type(obj) == "table" and type(obj.error) == "table" and obj.error.code == 503
end

-- ошибка цепочки, когда каждый опрошенный провайдер (запрос ушёл: ответ или транспортный сбой) отказал суточной
-- квотой (llm.quota == "day"): llm.DAILY перед ошибкой последнего — «daily quota: gemini: http 429». Не опрошен ни
-- один или хоть один отказал иначе — ошибка последнего как есть. llm.daily(err) — признак для фразы (controller)
llm.DAILY = "daily quota: "

function llm.daily(err)
  return type(err) == "string" and err:sub(1, #llm.DAILY) == llm.DAILY
end

function llm.call(providers, messages, opts)
  if #providers == 0 then return nil, "no providers" end
  local budget = opts.budget_s or DEFAULT_BUDGET_S
  local start = opts.now()
  -- опрошено провайдеров и из них отказали суточной квотой (llm.DAILY)
  local polled, daily = 0, 0
  -- прочитано, но reply пуст: запасной результат — сначала следующий провайдер, этот только если все отказали.
  -- opts.reply_optional — ответа не просили (prompt.map_read): пустой reply — обычный результат
  local last_err, spare
  -- транспортный сбой на ключе Gemini (таймаут, нет сети) — хост общий: остальные ключи пропускаем
  local skip_keyed = false
  -- модель, которую gemini-proxy назвал перегруженной (llm.overloaded): прямой Gemini той же модели в этом запросе
  -- не ждём (живой лог 19.11: 503 прокси за 790 мс, затем прямой Gemini висел 12 с) — сразу следующий провайдер
  local overloaded_model
  for i, p in ipairs(providers) do
    if skip_keyed and p.key then goto continue end
    if p.key and overloaded_model and p.model == overloaded_model then
      if opts.log then
        opts.log(string.format("riddle: llm gemini key %d skipped: gemini-proxy overloaded %s", p.key, p.model))
      end
      goto continue
    end
    local remaining = budget - (opts.now() - start)
    if remaining <= 0 then
      if spare then return spare end
      return nil, "budget"
    end
    -- весь остаток бюджета ждёт тот, за кем нет провайдера другого хоста: у ключа Gemini — провайдер без
    -- key (свой: Groq, BeatAPI); у своего (key == nil) — любой следующий. Ключи Gemini после сбоя на ключе
    -- пропустятся. Иначе потолок opts.attempt_s (по умолчанию PER_PROVIDER_TIMEOUT_S), остаток — следующему;
    -- не-последний не ест opts.reserve_s последнего провайдера (сверх резерва меньше MIN_ATTEMPT_S — пропускается)
    local others_after = false
    for j = i + 1, #providers do
      if not providers[j].key or not p.key then others_after = true break end
    end
    local timeout_s = remaining
    if others_after then
      local room = remaining - (opts.reserve_s or 0)
      if room < MIN_ATTEMPT_S then goto continue end
      timeout_s = math.min(opts.attempt_s or PER_PROVIDER_TIMEOUT_S, room)
      -- по длине ответа (opts.attempt_base_s, путь ответа): хвост задержки + потолок токенов × attempt_per_token_s.
      -- Повисший короткий ответ отрезается раньше потолка попытки, длинному остаётся прежний потолок
      if opts.attempt_base_s then
        timeout_s = math.min(timeout_s,
          opts.attempt_base_s + max_tokens_of(p, opts.max_tokens) * (opts.attempt_per_token_s or 0))
      end
      -- gemini-proxy — свой, меньший потолок попытки (opts.proxy_attempt_s)
      if p.format == "gemini" and opts.proxy_attempt_s then timeout_s = math.min(timeout_s, opts.proxy_attempt_s) end
    end
    -- провайдеру с лимитом входа — запрос, урезанный opts.fit (prompt.fit); без fit — как есть
    local msgs = (p.max_input_chars and opts.fit) and opts.fit(messages, p.max_input_chars, p) or messages
    local url, headers, body = llm.build(p, msgs, opts.max_tokens, opts.temperature)
    if not url then
      last_err = p.name .. ": " .. tostring(body) -- запрос не собран: провайдер не вызван, не мёртвый
      goto continue
    end
    local ok, status, resp = pcall(opts.post, url, headers, body, timeout_s, p)
    polled = polled + 1
    if ok and llm.quota(p, status, resp) == "day" then daily = daily + 1 end
    if ok and llm.overloaded(p, status, resp) then overloaded_model = p.model end
    if not ok then
      last_err = p.name .. ": " .. tostring(status)
      if p.key then skip_keyed = true end
    elseif not status then
      last_err = p.name .. ": " .. tostring(resp)
      if p.key then skip_keyed = true end
    else
      local result, err = llm.parse(status, resp, opts.want_json, p.format)
      if result and opts.want_json and not opts.reply_optional and result.reply == "" and result.read ~= "?" then
        result.via, result.via_idx = p.name, i
        spare = spare or result
        last_err = p.name .. ": empty reply"
      elseif result then
        result.via = p.name -- провайдер, чей ответ вернулся (для лога)
        result.via_idx = i -- и его место в списке providers: повтор запроса (app Chain:_run_retry) идёт с него
        return result
      else
        last_err = p.name .. ": " .. tostring(err)
      end
    end
    ::continue::
  end
  if spare then return spare end
  if polled > 0 and daily == polled then return nil, llm.DAILY .. last_err end
  return nil, last_err
end

return llm
