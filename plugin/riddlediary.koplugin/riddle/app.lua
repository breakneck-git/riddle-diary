-- Связка на устройстве: controller + llm + http. Зависимости среды (часы, лог, файлы) приходят
-- снаружи, поэтому сборка тестируется без KOReader.
-- В лог идут только хост провайдера, статус, время и метаданные ответа — ни ключей, ни URL с аккаунтом.

local json = require("dkjson")
local controller = require("riddle.controller")
local llm = require("riddle.llm")
local str = require("riddle.str")
local prompt = require("riddle.prompt")
local seal = require("riddle.seal")
local file = require("riddle.file")

local app = {}

app.BUDGET_S = 8
-- путь ответа в дочернем процессе (потолок riddle_diarywidget CFG.ceil_s = 30 с): бюджет цепочки и
-- потолок одной попытки провайдера; синхронные вызовы (пересказ, devtest) — BUDGET_S и 4 с llm
app.ANSWER_BUDGET_S = 25
app.ANSWER_ATTEMPT_S = 12
-- потолок попытки по длине ответа (llm.call attempt_base_s/attempt_per_token_s), не больше ANSWER_ATTEMPT_S. Замеры
-- crash.log Kindle (10.23–11.19): удачный прямой Gemini на короткий ответ (≤ 70 токенов) — до 8,7 с (p95 7,2 с), и ни
-- одной удачи между 8,7 и 12 с; ответы 540–770 токенов — не дольше 4,7 с (≥ 130 ток/с, 7,5 мс/токен). База 9 с — хвост
-- задержки, а не генерация: ответ дневника (200 токенов) — 10,5 с, от 400 токенов (пересказ, классификация) — 12 с
app.ANSWER_ATTEMPT_BASE_S = 9
app.ANSWER_ATTEMPT_PER_TOKEN_S = 0.0075
-- потолок попытки gemini-proxy (format = "gemini"): живой ответ 2–3 с, зависший не должен отнимать время у прямого Gemini
app.ANSWER_PROXY_ATTEMPT_S = 7
-- сколько секунд бюджета ответа не-последние провайдеры оставляют последнему (BeatAPI), даже если висят
app.ANSWER_RESERVE_S = 7
-- генерация персоны (opts.limits = "gen"; потолок дочернего riddle_diarywidget CFG.gen_ceil_s = 60 с): ответ на
-- тысячи токенов — свои бюджет, попытка провайдера, попытка gemini-proxy и запас последнему
app.GEN_BUDGET_S = 50
app.GEN_ATTEMPT_S = 20
app.GEN_PROXY_ATTEMPT_S = 15
app.GEN_RESERVE_S = 15
app.LORE_PATH = "/mnt/us/riddle/lore.md"
-- хост Gemini: прогрев DNS; хосты запасных (Groq, BeatAPI) приходят из providers конфига (app.hosts)
app.HOSTS = { "generativelanguage.googleapis.com" }

-- хосты для прогрева DNS: по умолчанию и providers из конфига (только https: другого транспорта нет)
function app.hosts(cfg)
  local out, seen = {}, {}
  local function add(h)
    if h and not seen[h] then seen[h] = true; out[#out + 1] = h end
  end
  for _, h in ipairs(app.HOSTS) do add(h) end
  for _, e in ipairs(type(cfg) == "table" and type(cfg.providers) == "table" and cfg.providers or {}) do
    add(type(e) == "table" and type(e.url) == "string" and e.url:match("^https://([^/:?#]+)") or nil)
  end
  return out
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function app.b64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1, c2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
    local c3, c4 = math.floor(n / 64) % 64, n % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

-- метаданные ответа 200 для лога: finish_reason и число токенов (видно, если модель «думает»),
-- cached — токены входа из кэша провайдера
local function describe(body)
  local ok, obj = pcall(json.decode, body or "")
  if not ok or type(obj) ~= "table" then return "" end
  -- нативный ответ Gemini (gemini-proxy): candidates и usageMetadata
  if type(obj.candidates) == "table" or type(obj.usageMetadata) == "table" then
    local cand = type(obj.candidates) == "table" and type(obj.candidates[1]) == "table" and obj.candidates[1] or {}
    local usage = type(obj.usageMetadata) == "table" and obj.usageMetadata or {}
    local parts = type(cand.content) == "table" and type(cand.content.parts) == "table" and cand.content.parts or {}
    local chars = 0
    for _, part in ipairs(parts) do
      if type(part) == "table" and type(part.text) == "string" and not part.thought then chars = chars + #part.text end
    end
    return string.format(" finish=%s out_tokens=%s chars=%d think=%s cached=%s", tostring(cand.finishReason),
      tostring(usage.candidatesTokenCount), chars, tostring(usage.thoughtsTokenCount or "-"),
      type(usage.cachedContentTokenCount) == "number" and string.format("%d", usage.cachedContentTokenCount) or "-")
  end
  local ch = type(obj.choices) == "table" and obj.choices[1] or {}
  local usage = type(obj.usage) == "table" and obj.usage or {}
  local content = type(ch.message) == "table" and ch.message.content
  local details = type(usage.prompt_tokens_details) == "table" and usage.prompt_tokens_details or {}
  return string.format(" finish=%s out_tokens=%s chars=%s think=%s cached=%s", tostring(ch.finish_reason),
    tostring(usage.completion_tokens), type(content) == "string" and #content or "-",
    type(content) == "string" and content:find("<think>", 1, true) and "yes" or "no",
    type(details.cached_tokens) == "number" and string.format("%d", details.cached_tokens) or "-")
end

-- значения ключей из конфига (gemini_key, gemini_keys, notion_token, providers[].key и .proxy_auth): формат ключа
-- чужого провайдера шаблонам mask не известен, поэтому маскируются дословно; короче 6 знаков не берём —
-- такая «строка-секрет» искалечила бы лог
local MIN_SECRET_LEN = 6

local function config_secrets(cfg)
  local out, seen = {}, {}
  local function add(v)
    if type(v) == "string" then
      v = str.trim(v)
      if #v >= MIN_SECRET_LEN and not seen[v] then seen[v] = true; out[#out + 1] = v end
    end
  end
  if type(cfg) ~= "table" then return out end
  add(cfg.gemini_key); add(cfg.notion_token)
  for _, v in ipairs(type(cfg.gemini_keys) == "table" and cfg.gemini_keys or {}) do add(v) end
  for _, e in ipairs(type(cfg.providers) == "table" and cfg.providers or {}) do
    if type(e) == "table" then add(e.key); add(e.proxy_auth) end
  end
  return out
end

-- всё, похожее на секрет (ключи Google/OpenAI-стиля, Bearer-токен, key= в URL, ключи из конфига) -> ***
local function mask(text, secrets)
  text = tostring(text)
  for _, v in ipairs(secrets or {}) do
    local from = 1
    while true do
      local a, b = text:find(v, from, true)
      if not a then break end
      text = text:sub(1, a - 1) .. "***" .. text:sub(b + 1)
      from = a + 3
    end
  end
  return (text
    :gsub("Bearer%s+%S+", "***")
    :gsub("key=[^&%s]+", "***")
    :gsub("AIza[%w_%-]+", "***")
    :gsub("sk%-[%w_%-]+", "***"))
end

-- знание из Notion для ответа (dep контроллера knowledge_text): -> fn() -> sections | nil, mode, nil.
-- sections — K:sections (разделы по базам, у документа свежесть: по ней prompt.fit срезает старые).
-- Без notion_token и до первого чтения (документов нет) — nil, как до знаний. Весь текст ≤ SMALL_CHARS —
-- целиком ("small"); больше — недавно изменённое до порога ("recent"; поиска по отпечаткам ещё нет).
-- Третье значение (прежний текст по свежести) всегда nil: свежесть теперь у каждого документа.
-- База открывается на одно чтение и закрывается; любой сбой -> nil и строка лога без секретов.
-- Четвёртое значение — контекст задач (app.tasks_context) из того же открытия базы; документов нет —
-- nil, nil, nil, задачи. Сбой чтения задач — задач нет (nil), знание отдаётся как раньше.
-- d: cfg, log; необязательно knowledge_path (по умолчанию knowledge.PATH)
function app.knowledge_text(d)
  local secrets = config_secrets(d.cfg)
  local log = d.log or function() end
  return function()
    if type(d.cfg) ~= "table" or not d.cfg.notion_token then return nil end
    local ok, text, mode, recent, tasks_ctx = pcall(function()
      local knowledge = require("riddle.knowledge")
      local K = knowledge.open(d.knowledge_path or knowledge.PATH)
      local rok, text, mode = pcall(function()
        local total = K:stats().chars
        if total == 0 then return nil end
        if total <= knowledge.SMALL_CHARS then
          log(string.format("riddle: knowledge small chars=%d", total))
          return (K:sections()), "small"
        end
        local sections, chars = K:sections(knowledge.SMALL_CHARS)
        log(string.format("riddle: knowledge recent chars=%d of %d", chars, total))
        return sections, "recent"
      end)
      local tok, tasks_ctx = pcall(app.tasks_context, K, d)
      K:close()
      if not tok then
        log("riddle: tasks read failed: " .. mask(tasks_ctx, secrets))
        tasks_ctx = nil
      end
      if not rok then
        log("riddle: knowledge read failed: " .. mask(text, secrets))
        return nil, nil, nil, tasks_ctx
      end
      return text, mode, nil, tasks_ctx
    end)
    if not ok then
      log("riddle: knowledge read failed: " .. mask(text, secrets))
      return nil
    end
    if text == nil or #text == 0 then return nil, nil, nil, tasks_ctx end
    return text, mode, recent, tasks_ctx
  end
end

-- контекст задач для ответа из уже открытой базы знаний (общий формат, срез 2): -> ctx | nil.
-- Книга дел — tasks.pick_source(коллекции, слово пользователя из core, cfg.tasks_source). ctx = { collection =
-- {id, title}, why, block = tasks.block | nil, open = незакрытые, collections, titles }; книги не выбрано или в ней
-- 0 незакрытых — block = nil; коллекций нет — nil. В лог — только числа и причина выбора
function app.tasks_context(K, d)
  local tasks = require("riddle.tasks")
  local collections = K:collections()
  if #collections == 0 then return nil end
  local titles = {}
  for i, c in ipairs(collections) do titles[i] = c.title or "" end
  local cfg = type(d.cfg) == "table" and d.cfg or {}
  local picked, why = tasks.pick_source(collections, K:core("tasks_source"), cfg.tasks_source)
  local ctx = { why = why, collections = collections, titles = titles }
  if picked then
    ctx.collection = { id = picked.id, title = picked.title }
    ctx.open = tasks.open_list(K:tasks_of(picked.id))
    -- блок и в потолок знаков (Groq): метки контроллер берёт у того же блока, что ушёл в промпт
    if #ctx.open > 0 then ctx.block = prompt.fit_tasks(tasks.block(ctx.open)) end
  end
  if d.log then
    d.log(string.format("riddle: tasks open=%d shown=%d via=%s", ctx.block and ctx.block.total or 0,
      ctx.block and #ctx.block.items or 0, picked and why or "none"))
  end
  return ctx
end

-- слово пользователя о книге дел (dep контроллера set_tasks_source): -> fn(id | nil) -> true | nil, err.
-- База знаний открывается на одну запись core и закрывается; nil — выбор стирается. Ошибка — через mask.
-- d: cfg; необязательно knowledge_path (по умолчанию knowledge.PATH)
function app.set_tasks_source(d)
  local secrets = config_secrets(d.cfg)
  return function(id)
    local ok, err = pcall(function()
      local knowledge = require("riddle.knowledge")
      local K = knowledge.open(d.knowledge_path or knowledge.PATH)
      local wok, werr = pcall(K.set_core, K, "tasks_source", id)
      K:close()
      if not wok then error(werr, 0) end
    end)
    if not ok then return nil, mask(err, secrets) end
    return true
  end
end

-- цепочка провайдеров для контроллера: бюджет BUDGET_S, каждая попытка — строка лога
-- (у Gemini — номер ключа, не значение); стартовый ключ Gemini сдвигается на один с каждым вызовом;
-- ключ, ответивший 401/403 с «API key» / «API_KEY» в теле, мёртв до перезапуска и в цепочку больше не
-- попадает (403 captive-портала или прокси без этой метки — обычная ошибка, ключ жив); свой провайдер
-- из конфига — так же после 401 с непустым телом не из HTML (учёт по url и ключу или токену прокси: два
-- своих провайдера на одном url с разными ключами умирают порознь).
-- call — синхронно в родителе; remote_fn — то же в дочернем процессе (riddle.worker): счётчик вызовов
-- и список живых провайдеров берутся в родителе при создании, строки лога и новые мёртвые копятся в
-- payload и попадают в родителя через absorb
local function custom_id(p)
  local h = p.headers or {}
  return p.url .. "\0" .. (h["Authorization"] or h["X-Proxy-Auth"] or "")
end

local Chain = {}
Chain.__index = Chain

-- путь ответа (remote_fn) — свои бюджет и потолок попытки: ANSWER_BUDGET_S, ANSWER_ATTEMPT_S
function app.chain(d)
  local secrets = config_secrets(d.cfg)
  return setmetatable({ d = d, calls = 0, dead = {}, mask = function(text) return mask(text, secrets) end }, Chain)
end

-- живые провайдеры для очередного вызова; сдвигает стартовый ключ
function Chain:_providers()
  local providers = {}
  for _, p in ipairs(llm.providers(self.d.cfg, self.calls)) do
    if not ((p.key and self.dead[p.key]) or (p.custom and self.dead[custom_id(p)])) then providers[#providers + 1] = p end
  end
  self.calls = self.calls + 1
  return providers
end

-- один проход цепочки; log — куда строки, on_dead(id) — новый мёртвый ключ (id: номер ключа Gemini
-- или custom_id своего провайдера)
-- limits — { budget_s, attempt_s, proxy_attempt_s, reserve_s, attempt_base_s, attempt_per_token_s } пути ответа;
-- nil — синхронные BUDGET_S и потолок попытки llm;
-- opts — { max_tokens, temperature, reply_optional } вызова | nil: max_tokens — потолок ответа (пересказ), nil — потолок
-- провайдера; temperature, nil — llm; reply_optional — пустой reply не «запасной» (llm.call)
function Chain:_run(providers, messages, want_json, log, on_dead, limits, opts)
  opts = opts or {}
  local d, mask_ = self.d, self.mask
  local dead = {}
  local function post(url, headers, body, timeout_s, p)
    local t0 = d.clock()
    -- phase — фаза обрыва при транспортном сбое (http.post): connect | tls | send | wait | read
    local status, resp, phase = d.http.post(url, headers, body, timeout_s)
    local host = url:match("^https://([^/:]+)") or "?"
    if p and p.key then host = string.format("%s gemini key %d", host, p.key) end
    local ms = math.floor((d.clock() - t0) * 1000 + 0.5)
    if status == 200 then
      log(string.format("riddle: llm %s -> 200 in %d ms%s", host, ms, describe(resp)))
    else
      -- маскируем до обрезки: иначе по границе 160 символов от ключа останется узнаваемый кусок
      local detail = status and str.one_line(mask_(resp or ""):sub(1, 160)) or ""
      -- 429: суточная квота или минутная (llm.quota — то же правило, что у ошибки цепочки); в лог только слово
      local q = llm.quota(p, status, resp)
      local quota = q and (" quota=" .. q) or ""
      local where = (not status and phase) and (" (" .. tostring(phase) .. ")") or ""
      log(string.format("riddle: llm %s -> %s%s in %d ms%s %s", host, mask_(status or resp), where, ms, quota, detail))
    end
    if (status == 401 or status == 403) and p and p.key and not dead[p.key]
        and (tostring(resp):find("API key", 1, true) or tostring(resp):find("API_KEY", 1, true)) then
      dead[p.key] = true
      on_dead(p.key)
      log(string.format("riddle: gemini key %d dead", p.key))
    -- свой провайдер: формат тела ошибки неизвестен, поэтому только 401 с непустым телом и не HTML
    -- (прокси, портал)
    elseif status == 401 and p and p.custom and not dead[custom_id(p)]
        and tostring(resp):find("%S") and not tostring(resp):find("^%s*<") then
      dead[custom_id(p)] = true
      on_dead(custom_id(p))
      log(string.format("riddle: provider %s dead", p.name))
    end
    return status, resp
  end
  -- провайдер с лимитом входа (max_input_chars) — урезанный запрос; в лог только размеры. Не влез и урезанным
  -- (несрезаемое длиннее лимита) — уходит урезанным до предела (срезано всё, что prompt.fit может), с флагом fit over
  local function fit(m, max_chars, p)
    local out, over = prompt.fit(m, max_chars)
    if out ~= m then
      log(string.format("riddle: llm %s fit chars=%d of %d", p.name, prompt.chars(out), prompt.chars(m)))
    end
    if over then
      log(string.format("riddle: llm %s fit over chars=%d limit=%d", p.name, prompt.chars(out), max_chars))
    end
    return out
  end
  local t0 = d.clock()
  local result, err = llm.call(providers, messages,
    { post = post, now = d.clock, fit = fit, log = log, budget_s = limits and limits.budget_s or app.BUDGET_S,
      attempt_s = limits and limits.attempt_s, proxy_attempt_s = limits and limits.proxy_attempt_s,
      reserve_s = limits and limits.reserve_s, attempt_base_s = limits and limits.attempt_base_s,
      attempt_per_token_s = limits and limits.attempt_per_token_s, want_json = want_json,
      max_tokens = opts.max_tokens, temperature = opts.temperature, reply_optional = opts.reply_optional })
  log(string.format("riddle: llm done %s in %d ms%s", result and "ok" or "fail",
    math.floor((d.clock() - t0) * 1000 + 0.5), result and "" or (" (" .. mask_(err) .. ")")))
  -- err уходит в лог контроллера («llm failed: …»): отдаём уже замаскированным
  return result, err and mask_(err)
end

-- _run и, по ответу, один повтор: opts.retry(result) -> запрос повтора, строка лога | nil (без повтора). Повтор —
-- провайдерами с давшего первый ответ (llm: result.via_idx) в остаток того же бюджета (limits или BUDGET_S), не удался, непригоден (controller.usable)
-- или бюджета нет — первый ответ.
-- Сбой самого retry — в лог, первый ответ
function Chain:_run_retry(providers, messages, want_json, log, on_dead, limits, opts)
  local d = self.d
  local t0 = d.clock()
  local result, err = self:_run(providers, messages, want_json, log, on_dead, limits, opts)
  if not (result and opts and opts.retry) then return result, err end
  local ok, again, line = pcall(opts.retry, result)
  if not ok then
    log("riddle: retry check failed: " .. tostring(again))
    return result
  end
  if not again then return result end
  if line then log(line) end
  local left = (limits and limits.budget_s or app.BUDGET_S) - (d.clock() - t0)
  if left <= 0 then
    log("riddle: llm retry skipped (budget)")
    return result
  end
  -- с провайдера (и ключа), давшего первый ответ: стоявшие раньше в первом проходе отказали — повторять их не надо
  local rest = {}
  for i = result.via_idx or 1, #providers do rest[#rest + 1] = providers[i] end
  -- те же потолки попытки, бюджет — остаток
  local again_limits = { budget_s = left }
  for k, v in pairs(limits or {}) do if k ~= "budget_s" then again_limits[k] = v end end
  local second = self:_run(rest, again, want_json, log, on_dead, again_limits, opts)
  -- годный — как для показа (controller.usable), иначе контроллер покажет «расплылись»
  if second and controller.usable(second) then return second end
  return result
end

-- opts: { max_tokens } — потолок ответа этого вызова (пересказ сессии); retry — повтор по ответу (_run_retry)
function Chain:call(messages, want_json, opts)
  local log = self.d.log or function() end
  return self:_run_retry(self:_providers(), messages, want_json, log, function(id) self.dead[id] = true end, nil,
    opts and { max_tokens = opts.max_tokens, retry = opts.retry })
end

-- -> fn() для дочернего процесса; fn() -> payload { result, err, logs, dead };
-- opts: { max_tokens, temperature, retry, reply_optional } — как у call (пересказ сессии; классификация баз —
-- temperature 0; чтение страницы на карте — reply_optional);
-- повтор (retry) — тоже в дочернем, в общий бюджет ANSWER_BUDGET_S. opts.limits = "gen" — бюджет генерации (GEN_*)
function Chain:remote_fn(messages, want_json, opts)
  local providers = self:_providers()
  local limits = opts and opts.limits == "gen"
    and { budget_s = app.GEN_BUDGET_S, attempt_s = app.GEN_ATTEMPT_S, proxy_attempt_s = app.GEN_PROXY_ATTEMPT_S,
      reserve_s = app.GEN_RESERVE_S }
    or { budget_s = app.ANSWER_BUDGET_S, attempt_s = app.ANSWER_ATTEMPT_S, proxy_attempt_s = app.ANSWER_PROXY_ATTEMPT_S,
      reserve_s = app.ANSWER_RESERVE_S, attempt_base_s = app.ANSWER_ATTEMPT_BASE_S,
      attempt_per_token_s = app.ANSWER_ATTEMPT_PER_TOKEN_S }
  return function()
    local logs, dead = {}, {}
    local result, err = self:_run_retry(providers, messages, want_json,
      function(msg) logs[#logs + 1] = msg end, function(id) dead[#dead + 1] = id end, limits, opts)
    return { result = result, err = err, logs = logs, dead = dead }
  end
end

-- в родителе: строки лога дочернего -> d.log, его мёртвые ключи -> учёт цепочки
function Chain:absorb(payload)
  local log = self.d.log or function() end
  for _, msg in ipairs(type(payload.logs) == "table" and payload.logs or {}) do log(tostring(msg)) end
  for _, id in ipairs(type(payload.dead) == "table" and payload.dead or {}) do self.dead[id] = true end
  return payload.result, payload.err
end

-- llm_call для контроллера (синхронный путь)
function app.llm_caller(d)
  local chain = app.chain(d)
  return function(messages, want_json, opts) return chain:call(messages, want_json, opts) end
end

-- блокирующая работа (прогрев DNS) не должна ложиться под движущееся перо: fn сразу, если
-- busy() ложно, иначе повторная проверка через retry_s по schedule(delay, fn)
function app.when_idle(busy, schedule, fn, retry_s)
  local function try()
    if busy() then
      schedule(retry_s, try)
      return
    end
    fn()
  end
  try()
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function remove(path)
  local ok, err = os.remove(path)
  if not ok then error(err) end
end

-- d: cfg, memory, http, clock (монотонные с), wall (os.time), log, file_mtime;
-- необязательно: read_file, remove, random, b64, lore_path, devmode (текст read и сырые поля ответа — в лог),
-- knowledge_path (знание из Notion, по умолчанию knowledge.PATH), key_path (образец ключа печати, по умолчанию
-- seal.KEY_PATH; образец пишется только через file.write_atomic)
function app.new_controller(d)
  local chain = app.chain(d)
  return controller.new{
    cfg = d.cfg,
    memory = d.memory,
    llm_call = function(messages, want_json, opts) return chain:call(messages, want_json, opts) end,
    remote_fn = function(messages, want_json, opts) return chain:remote_fn(messages, want_json, opts) end,
    absorb = function(payload) return chain:absorb(payload) end,
    read_file = d.read_file or read_file,
    b64 = d.b64 or app.b64,
    remove = d.remove or remove,
    now = d.wall or os.time,
    lore_path = d.lore_path or app.LORE_PATH,
    file_mtime = d.file_mtime,
    clock = d.clock,
    random = d.random or math.random,
    log = d.log,
    devmode = d.devmode,
    knowledge_text = app.knowledge_text(d),
    set_tasks_source = app.set_tasks_source(d),
    key_path = d.key_path,
    load_key = seal.load_key,
    write_key = function(path, s) return file.write_atomic(path, s) end,
    forget_key = seal.forget_key,
  }
end

return app
