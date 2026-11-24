local t = require("t")
local json = require("dkjson")
local texts = require("riddle.texts")
local prompt = require("riddle.prompt")
local controller = require("riddle.controller")
local llm = require("riddle.llm")

local T = {}

local PNG = "/mnt/us/riddle/samples/1.png"
local LORE = "/mnt/us/riddle/lore.md"
local VARIANTS = { "salandusa", "шаландуша", "шаланда" }
local HINTS = { "ПОДСКАЗКА-ИЗ-КОНФИГА" }

local function in_list(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

local function logged(env, needle)
  for _, l in ipairs(env.logs) do
    if has(l, needle) then return l end
  end
end

-- фейк памяти строго по интерфейсу Task 3 -----------------------------------
local function fake_memory()
  local m = { sessions = {}, entries_ = {}, adds = {}, imported = {}, lore_mtime_ = nil, lore = "", set_summaries = {} }
  function m:session(now)
    local cur = self.sessions[#self.sessions]
    if not (cur and now - cur.last_ts <= 4 * 3600) then
      cur = { id = #self.sessions + 1, started = now, last_ts = now }
      self.sessions[#self.sessions + 1] = cur
    end
    local unsum
    for i = #self.sessions, 1, -1 do
      local s = self.sessions[i]
      if s.id ~= cur.id and s.summary == nil then unsum = s.id; break end
    end
    return cur.id, unsum
  end
  function m:add(sid, role, text, now)
    self.adds[#self.adds + 1] = { sid = sid, role = role, text = text }
    self.entries_[#self.entries_ + 1] = { sid = sid, role = role, text = text }
    self.sessions[sid].last_ts = now
  end
  function m:entries(sid)
    local out = {}
    for _, e in ipairs(self.entries_) do
      if e.sid == sid then out[#out + 1] = { role = e.role, text = e.text } end
    end
    return out
  end
  function m:recent(sid, n)
    local all = self:entries(sid)
    local out = {}
    for i = math.max(1, #all - n + 1), #all do out[#out + 1] = all[i] end
    return out
  end
  function m:set_summary(sid, text)
    self.sessions[sid].summary = text
    self.set_summaries[#self.set_summaries + 1] = { sid = sid, text = text }
  end
  function m:summaries(limit)
    local out = {}
    for i = #self.sessions, 1, -1 do
      local s = self.sessions[i]
      if s.summary ~= nil and #out < limit then out[#out + 1] = s.summary end
    end
    return out
  end
  function m:import_lore(md, mtime)
    self.imported[#self.imported + 1] = { md = md, mtime = mtime }
    self.lore = md
    self.lore_mtime_ = mtime
  end
  function m:lore_mtime() return self.lore_mtime_ end
  -- одна персона («Методов»): своя память — вся; чей лор — её, если mtime тот же
  function m:use_persona() return true end
  function m:lore_owner(mtime) return mtime == self.lore_mtime_ and 1 or nil end
  function m:lore_text(...)
    self.lore_args = { n = select("#", ...), ... }
    return self.lore
  end
  -- свёртки нет — как у memory без таблицы rollups (миграция 4 не прошла); свёртка — controller_memory_spec
  function m:rollup() return nil, nil end
  function m:unrolled() return nil end
  return m
end

-- окружение контроллера -----------------------------------------------------
-- script: очередь ответов llm_call; элемент — таблица результата или {fail="budget"}
local function make(opts)
  opts = opts or {}
  local env = {
    now_value = opts.now or 1000,
    files = { [PNG] = "PNGBYTES" },
    mtimes = {},
    removed = {},
    llm_calls = {},
    script = {},
    logs = {},
    memory = opts.memory or fake_memory(),
  }
  local deps = {
    cfg = opts.cfg or { password_variants = opts.variants or VARIANTS, hint_every = 3, hints = HINTS },
    memory = env.memory,
    llm_call = function(messages, want_json, call_opts)
      env.llm_calls[#env.llm_calls + 1] = { messages = messages, want_json = want_json, opts = call_opts }
      local step = table.remove(env.script, 1)
      if step == nil then error("llm_call: сценарий кончился") end
      if step.throw then error(step.throw) end
      if step.fail then return nil, step.fail end
      return step
    end,
    read_file = function(path)
      if env.read_fails and path == PNG then error("read failed") end
      local f = env.files[path]
      if f == nil then error("нет файла " .. path) end
      return f
    end,
    b64 = function(bytes) return "B64:" .. bytes end,
    remove = function(path) env.removed[#env.removed + 1] = path end,
    now = function() return env.now_value end,
    lore_path = LORE,
    file_mtime = function(path) return env.mtimes[path] end,
    random = function(n) return 1 end,
    log = function(msg) env.logs[#env.logs + 1] = msg end,
    devmode = opts.devmode,
    knowledge_text = opts.knowledge_text,
  }
  -- путь через дочерний процесс: remote_fn создаётся в родителе, run выполняется «в дочернем»,
  -- absorb разбирает payload в родителе (здесь — тот же сценарий llm_call)
  deps.remote_fn = function(messages, want_json, call_opts)
    return function()
      local result, err = deps.llm_call(messages, want_json, call_opts)
      return { result = result, err = err }
    end
  end
  deps.absorb = function(payload) return payload.result, payload.err end
  env.ctrl = controller.new(deps)
  function env:say(read, reply)
    env.script[#env.script + 1] = { read = read, reply = reply }
  end
  function env:page() return env.ctrl:on_page(PNG) end
  -- та же страница через begin/finish (асинхронный путь виджета)
  function env:page_async()
    local job, text = env.ctrl:begin(PNG)
    if not job then return text end
    return env.ctrl:finish(job, job.run())
  end
  function env:unlock()
    env:say("Salandusa", "что-то")
    local text = env:page()
    t.ok(env.ctrl.seal_open, "печать должна быть снята")
    return text
  end
  return env
end

local function system_of(call) return call.messages[1].content end
local LOCKED_SYSTEM = prompt.locked("x")[1].content
local function is_locked_call(call) return system_of(call) == LOCKED_SYSTEM end

-- закрытая печать -----------------------------------------------------------

function T.test_locked_refuse()
  local env = make()
  env:say("кто ты", "Мои страницы молчат…")
  local text = env:page()
  t.eq(text, "Мои страницы молчат…")
  t.eq(#env.memory.adds, 0, "в память ничего")
  t.eq(#env.llm_calls, 1)
  t.ok(is_locked_call(env.llm_calls[1]), "запрос по закрытому промпту")
  t.eq(env.llm_calls[1].want_json, true)
  t.eq(env.llm_calls[1].opts, nil, "ответ — с потолком провайдера, без потолка пересказа")
  t.ok(has(json.encode(env.llm_calls[1].messages), "B64:PNGBYTES"), "картинка ушла в запрос")
  t.ok(not env.ctrl.seal_open)
end

local function fixture(name)
  local f = assert(io.open("tests/fixtures/png/" .. name, "rb"))
  local bytes = f:read("*a")
  f:close()
  return bytes
end

-- узкая сторона меньше 32 px (тире) — Groq отвечает 400; в запрос уходит дополненная до 32
function T.test_narrow_png_padded_to_32_before_b64()
  local env = make()
  env.files[PNG] = fixture("g40x10_dynamic.png")
  local encoded = {}
  env.ctrl.deps.b64 = function(bytes) encoded[#encoded + 1] = bytes; return "B64" end
  env:say("кто ты", "Нет.")
  local job = env.ctrl:begin(PNG)
  t.ok(job, "job собран")
  t.eq(#encoded, 1, "одно кодирование")
  local s = encoded[1]
  local function be32(i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  t.eq(s:sub(13, 16), "IHDR")
  t.ok(be32(17) >= 32 and be32(21) >= 32, string.format("в запрос ушло %dx%d", be32(17), be32(21)))
  t.ok(logged(env, "riddle: image padded 40x10 -> 40x32"), table.concat(env.logs, "\n"))
end

-- обе стороны меньше 32 px — случайное касание (владелец 2026-10-25): в модель не идёт,
-- текста нет, PNG удалён, в лог — только размеры
local function check_tiny_skipped(env, name, size, call)
  env.files[PNG] = fixture(name)
  local encoded = 0
  env.ctrl.deps.b64 = function() encoded = encoded + 1; return "B64" end
  env.ctrl.deps.remote_fn = function() error("remote_fn для касания") end
  local job, text = call(env)
  t.eq(job, nil, "job нет")
  t.eq(text, nil, "текста нет")
  t.eq(encoded, 0, "не кодировали")
  t.eq(#env.llm_calls, 0, "модель не вызвана")
  t.eq(env.removed[1], PNG, "PNG удалён")
  t.ok(logged(env, "riddle: page too small " .. size .. " -> skipped"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "padded") and not has(l, "failed"), "лишняя строка: " .. l)
  end
end

function T.test_tiny_png_begin_skipped()
  check_tiny_skipped(make(), "b2_13x9_dynamic.png", "13x9", function(env) return env.ctrl:begin(PNG) end)
end

function T.test_tiny_png_on_page_skipped()
  check_tiny_skipped(make(), "b1_17x31_dynamic.png", "17x31", function(env) return nil, env.ctrl:on_page(PNG) end)
end

-- сборка запроса открытой печати в родителе: время и размер — решение о кэше на устройстве;
-- в лог только числа
function T.test_open_begin_logs_build_time()
  local env = make({ variants = {} })
  local ticks = { 1.000, 1.012 }
  env.ctrl.deps.clock = function() return table.remove(ticks, 1) or 1.012 end
  env:say("кто ты", "Нет.")
  t.ok(env.ctrl:begin(PNG), "job есть")
  local line = logged(env, "riddle: prompt built in 12 ms chars=")
  t.ok(line, table.concat(env.logs, "\n"))
  t.ok(line:match("chars=%d+$"), line)
end

function T.test_locked_begin_logs_no_build_time()
  local env = make()
  env.ctrl.deps.clock = function() return 1.000 end
  env:say("кто ты", "Нет.")
  t.ok(env.ctrl:begin(PNG), "job есть")
  t.ok(not logged(env, "prompt built"), table.concat(env.logs, "\n"))
end

-- касание не съедает хвост разблокировки (без печати он ждёт первого настоящего ответа)
function T.test_tiny_png_keeps_followup_without_seal()
  local env = make({ variants = {} })
  env.files[PNG] = fixture("rgb5x5_dynamic.png")
  t.eq(env.ctrl:on_page(PNG), nil)
  t.ok(env.ctrl:take_followup(), "хвост остался")
end

-- закрытая печать: что прочла модель и что решила печать — в лог (диагностика пароля);
-- текст read — только в devmode, иначе в лог Kindle попадает всё, что написано на странице
function T.test_locked_logs_seal_read_kind_provider_in_devmode()
  local env = make({ devmode = true })
  env.script[1] = { read = "шалонда\nвот", reply = "Нет.", via = "gemini" }
  env:page()
  t.ok(env.logs[1] and has(env.logs[1], 'riddle: seal read "шалонда\\nвот" -> unlock via gemini'),
    table.concat(env.logs, "\n"))
  local env2 = make({ devmode = true })
  env2:say("кто ты", "Нет.")
  env2:page()
  t.ok(env2.logs[1] and has(env2.logs[1], 'riddle: seal read "кто ты" -> refuse via ?'),
    table.concat(env2.logs, "\n"))
end

function T.test_locked_log_without_devmode_has_length_not_text()
  local env = make()
  env.script[1] = { read = "шалонда\nвот", reply = "Нет.", via = "gemini" }
  env:page()
  t.ok(env.logs[1] and has(env.logs[1], "riddle: seal read 11 chars -> unlock via gemini"),
    table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "шалонда") and not has(l, "вот"), "текст read не в логе: " .. l)
  end
  local env2 = make()
  env2:say("кто ты", "Нет.")
  env2:page()
  t.ok(env2.logs[1] and has(env2.logs[1], "riddle: seal read 6 chars -> refuse via ?"),
    table.concat(env2.logs, "\n"))
  t.ok(not has(env2.logs[1], "кто ты"), "текст read не в логе")
end

-- на открытой печати строки seal read нет; без devmode нет и текста read: в лог Kindle не идёт написанное
function T.test_open_seal_does_not_log_read()
  for _, devmode in ipairs({ false, true }) do
    local env = make({ devmode = devmode })
    env:unlock()
    env.logs = {}
    env:say("секретные слова дианы", "Ответ.")
    env:page()
    for _, l in ipairs(env.logs) do
      t.ok(not has(l, "seal read"), "на открытой печати нет строки seal read: " .. l)
      if not devmode then t.ok(not has(l, "секретные слова"), "текст read не в логе: " .. l) end
    end
  end
end

-- открытая печать в devmode: что прочла модель и сырые служебные поля (task, tasks_source) — одной строкой;
-- нет поля — nil, пустое — "": в логе их видно порознь (модель пропустила ключ или ответила, что о нём ни слова)
function T.test_open_seal_logs_read_and_raw_fields_in_devmode()
  local env = make({ devmode = true })
  env:unlock()
  env.logs = {}
  env.script[1] = { read = "мои дела\nв tasks", reply = "Ответ.", task = "t2", tasks_source = "tasks", via = "gemini" }
  env:page()
  local all = table.concat(env.logs, "\n")
  t.ok(has(all, 'riddle: open read "мои дела\\nв tasks" task="t2" tasks_source="tasks" via gemini'), all)
  env.logs = {}
  env.script[1] = { read = "кто ты", reply = "Ответ.", tasks_source = "" }
  env:page()
  all = table.concat(env.logs, "\n")
  t.ok(has(all, 'riddle: open read "кто ты" task=nil tasks_source="" via ?'), all)
  -- нечитаемая страница тоже видна: модель прочла "?"
  env.logs = {}
  env.script[1] = { read = "?", reply = "" }
  env:page()
  all = table.concat(env.logs, "\n")
  t.ok(has(all, 'riddle: open read "?" task=nil tasks_source=nil via ?'), all)
end

-- без devmode на открытой печати новой строки нет вовсе
function T.test_open_seal_without_devmode_has_no_open_read_line()
  local env = make()
  env:unlock()
  env.logs = {}
  env.script[1] = { read = "мои дела", reply = "Ответ.", task = "t2", tasks_source = "tasks" }
  env:page()
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "open read"), "без devmode строки open read нет: " .. l)
    t.ok(not has(l, "мои дела") and not has(l, "tasks_source"), "ни текста, ни полей: " .. l)
  end
end

function T.test_locked_hint_on_third()
  local env = make()
  for i = 1, 2 do
    env:say("кто ты", "отказ " .. i)
    t.eq(env:page(), "отказ " .. i)
  end
  env:say("кто ты", "отказ 3")
  t.eq(env:page(), HINTS[1], "третья неудача -> подсказка из конфига, не ответ модели")
  t.eq(#env.memory.adds, 0)
end

function T.test_unlock_no_llm_reply()
  local env = make()
  env:say("Salandusa", "СЕКРЕТНЫЙ-ОТВЕТ-МОДЕЛИ")
  local text = env:page()
  t.eq(text, texts.welcomes[1], "только приветствие")
  t.ok(not has(text, "СЕКРЕТНЫЙ"), "reply модели не показан")
  t.ok(env.ctrl.seal_open)
  t.eq(#env.memory.adds, 0, "слово не пишется в память")
end

function T.test_unreadable_closed()
  local env = make()
  env:say("?", "")
  local text = env:page()
  t.ok(in_list(texts.unreadable, text), text)
  t.eq(#env.memory.adds, 0)
  -- нераспознанное не считается неудачей: три "?" и потом две неудачи — подсказки ещё нет
  for _ = 1, 2 do env:say("?", ""); env:page() end
  env:say("кто ты", "а"); t.eq(env:page(), "а")
  env:say("кто ты", "б"); t.eq(env:page(), "б")
end

function T.test_all_providers_fail_closed()
  local env = make()
  env.script = { { fail = "budget" } }
  local text = env:page()
  t.ok(in_list(texts.fail_slow, text), text)
  t.eq(#env.memory.adds, 0)
end

-- открытая печать -----------------------------------------------------------

function T.test_open_writes_memory()
  local env = make()
  env.memory.lore = "ЛОР-МАРКЕР"
  env.memory.sessions[1] = { id = 1, started = 0, last_ts = 0, summary = "ПЕРЕСКАЗ-МАРКЕР" }
  env:unlock()
  env:say("Мне грустно", "Я с тобой")
  local text = env:page()
  t.eq(text, "Я с тобой")
  t.eq(#env.memory.adds, 2)
  t.eq(env.memory.adds[1].role, "owner")
  t.eq(env.memory.adds[1].text, "Мне грустно")
  t.eq(env.memory.adds[2].role, "diary")
  t.eq(env.memory.adds[2].text, "Я с тобой")
  t.eq(env.memory.adds[1].sid, env.memory.adds[2].sid)

  local first = env.llm_calls[2]
  t.ok(not is_locked_call(first), "открытая печать — другой промпт")
  t.eq(first.want_json, true)
  local s1 = json.encode(first.messages)
  t.ok(has(s1, "ЛОР-МАРКЕР"), "лор в промпте")
  t.ok(has(s1, "ПЕРЕСКАЗ-МАРКЕР"), "пересказ в промпте")
  t.ok(has(s1, "B64:PNGBYTES"))

  -- следующая запись видит прошлые реплики как диалог
  env:say("Расскажи мне сказку", "Жила-была…")
  env:page()
  local s2 = json.encode(env.llm_calls[3].messages)
  t.ok(has(s2, "Мне грустно") and has(s2, "Я с тобой"), "recent в промпте")
  t.eq(#env.memory.adds, 4)
end

-- окно истории контроллера — то же, что у промпта (prompt.MAX_RECENT = 40): 40 реплик доходят, 41-я — нет
function T.test_open_history_window_40()
  local env = make({ cfg = {} }) -- печати нет: открыт сразу
  env:say("Привет", "Здравствуй")
  env:page()
  for i = 1, 45 do
    env.memory:add(1, (i % 2 == 1) and "owner" or "diary", string.format("реплика-%02d", i), env.now_value)
  end
  env:say("ещё", "ответ")
  env:page()
  local m = env.llm_calls[#env.llm_calls].messages
  t.eq(#m - 2, 40, "40 реплик истории")
  local s = json.encode(m)
  t.ok(has(s, "реплика-45") and has(s, "реплика-06"), "последние 40")
  t.ok(not has(s, "реплика-05"), "41-я с конца не дошла")
end

function T.test_open_drops_empty_summaries()
  local env = make()
  env.memory.sessions[1] = { id = 1, started = 0, last_ts = 0, summary = "" }
  env.memory.sessions[2] = { id = 2, started = 1, last_ts = 1, summary = "НАСТОЯЩИЙ-ПЕРЕСКАЗ" }
  env:unlock()
  env:say("привет", "здравствуй")
  env:page()
  local s = json.encode(env.llm_calls[2].messages)
  t.ok(has(s, "НАСТОЯЩИЙ-ПЕРЕСКАЗ"))
  t.ok(not has(s, "- \\n") and not has(s, '- "'), "пустого пересказа в промпте нет")
end

function T.test_unreadable_open()
  local env = make()
  env:unlock()
  env:say("?", "")
  local text = env:page()
  t.ok(in_list(texts.unreadable, text), text)
  t.eq(#env.memory.adds, 0)
end

function T.test_unreadable_open_with_nonempty_reply()
  local env = make()
  env:unlock()
  env:say("?", "Я не разобрала…")
  local text = env:page()
  t.ok(in_list(texts.unreadable, text), text)
  t.ok(not has(text, "Я не разобрала"), "reply модели при read=? не показывается")
  t.eq(#env.memory.adds, 0)
end

-- на открытой печати любая разобранная запись — ответ модели: кода-ведущего нет
-- (бывшие слова квеста ивента 2026-10-23 и «руна» — обычные записи)
function T.test_open_every_read_is_model_reply()
  for _, read in ipairs({ "Сезам", "НОЧЬ", "тайну", "СЕРДЦЕ", "РУНА 1", "Х" }) do
    local env = make()
    env:unlock()
    env:say(read, "ОТВЕТ-МОДЕЛИ")
    t.eq(env:page(), "ОТВЕТ-МОДЕЛИ", read)
    t.eq(env.memory.adds[1].text, read, read)
    t.eq(env.memory.adds[2].text, "ОТВЕТ-МОДЕЛИ", read)
    t.eq(env.memory.lore_args.n, 0, "лор целиком, без фильтра: " .. read)
  end
end

-- лишний аргумент (бывшая руна от виджета) не меняет пути: запрос к модели всё равно идёт
function T.test_open_page_extra_arg_ignored()
  local env = make()
  env:unlock()
  env:say("привет", "здравствуй")
  local calls = #env.llm_calls
  t.eq(env.ctrl:on_page(PNG, 3), "здравствуй")
  t.eq(#env.llm_calls, calls + 1)
end

-- закрытая печать: прочитанное слово идёт в seal:feed и при пустом reply (решение оркестратора)
function T.test_locked_empty_reply_still_feeds_seal()
  local env = make()
  env:say("Salandusa", "")
  t.eq(env:page(), texts.welcomes[1], "слово снимает печать и без reply")
  t.ok(env.ctrl.seal_open)

  env = make()
  for _ = 1, 2 do
    env:say("кто ты", "")
    t.ok(in_list(texts.unreadable, env:page()), "пустой отказ — «не разобрала»")
  end
  env:say("кто ты", "")
  t.eq(env:page(), HINTS[1], "попытки с пустым reply засчитываются: третья — подсказка")
end

function T.test_all_providers_fail_open()
  local env = make()
  env:unlock()
  env.script = { { fail = "budget" } }
  local text = env:page()
  t.ok(in_list(texts.fail_slow, text), text)
  t.eq(#env.memory.adds, 0, "при провале в память ничего не пишем")
  t.ok(env.ctrl.seal_open, "печать остаётся снятой")
end


-- причина сбоя различима по ошибке llm_call (последний провайдер цепочки): свой пул на каждую
local FAIL_CASES = {
  { "gemini: offline", "fail_offline" },
  { "beatapi: dns: timeout", "fail_offline" },
  { "gemini: dns: rcode 3", "fail_offline" },
  { "budget", "fail_slow" },
  { "beatapi: timeout", "fail_slow" },
  { "gemini: http 429", "fail_limit" },
  -- luasocket: сети нет (регистр не важен) — одно правило с страницей состояния (net.fail_kind)
  { "gemini: Network is unreachable", "fail_offline" },
  { "beatapi: No route to host", "fail_offline" },
  -- вся цепочка отказала суточной квотой (llm.call: префикс llm.DAILY к ошибке последнего)
  { (llm.DAILY or "?") .. "gemini: http 429", "fail_daily" },
  { "beatapi: http 500", "fail_other" },
  { "gemini: not json", "fail_other" },
  { "no providers", "fail_other" },
}

function T.test_fail_reason_picks_its_pool_open_and_locked()
  for _, c in ipairs(FAIL_CASES) do
    local env = make()
    env.script = { { fail = c[1] } }
    t.ok(in_list(texts[c[2]], env:page()), "закрытая печать, " .. c[1] .. " → " .. c[2])
    env:unlock()
    env.script = { { fail = c[1] } }
    t.ok(in_list(texts[c[2]], env:page()), "открытая печать, " .. c[1] .. " → " .. c[2])
  end
end

function T.test_crash_in_on_page_is_other_failure()
  local env = make()
  env.script = { { throw = "boom" } }
  t.ok(in_list(texts.fail_other, env:page()), "сбой внутри — «напиши ещё раз»")
end

function T.test_open_empty_reply_not_shown_blank()
  local env = make()
  env:unlock()
  env:say("привет", "")
  local text = env:page()
  t.ok(#text > 0)
  t.eq(#env.memory.adds, 0)
end

-- PNG и устойчивость --------------------------------------------------------

function T.test_png_always_removed()
  local scenarios = {
    closed_refuse = function(env) env:say("кто ты", "отказ") end,
    closed_unlock = function(env) env:say("Salandusa", "x") end,
    closed_unreadable = function(env) env:say("?", "") end,
    closed_fail = function(env) env.script = { { fail = "budget" } } end,
    llm_throws = function(env) env.script = { { throw = "boom" } } end,
    read_fails = function(env) env.read_fails = true end,
    open_ok = function(env) env:unlock(); env.removed = {}; env:say("привет", "здравствуй") end,
    open_fail = function(env) env:unlock(); env.removed = {}; env.script = { { fail = "http 500" } } end,
  }
  for name, setup in pairs(scenarios) do
    local env = make()
    setup(env)
    local text = env:page()
    t.eq(#env.removed, 1, name .. ": remove вызван ровно раз")
    t.eq(env.removed[1], PNG, name)
    t.ok(type(text) == "string" and #text > 0, name .. ": текст непустой")
  end
end

function T.test_never_raises_and_logs()
  local env = make()
  env.script = { { throw = "boom" } }
  local text = env:page()
  t.ok(in_list(texts.fail_other, text), text)
  t.ok(#env.logs >= 1, "ошибка залогирована")
  t.ok(has(env.logs[1], "boom"))
end

function T.test_llm_call_throws_gives_fail_other_and_removes_png()
  local env = make()
  env.script = { { throw = "stack overflow" } }
  local text = env:page()
  t.ok(in_list(texts.fail_other, text), text)
  t.eq(#env.removed, 1)
  t.eq(env.removed[1], PNG)
end

function T.test_memory_read_throws_gives_fail_other()
  for _, method in ipairs({ "session", "summaries", "lore_text", "recent" }) do
    local env = make()
    env:unlock()
    env.removed = {}
    env.memory[method] = function() error("db locked: " .. method) end
    env:say("привет", "здравствуй")
    local text = env:page()
    t.ok(in_list(texts.fail_other, text), method .. ": " .. text)
    t.eq(#env.removed, 1, method)
  end
end

function T.test_memory_error_does_not_crash()
  local env = make()
  env:unlock()
  env.memory.add = function() error("disk full") end
  env:say("привет", "здравствуй")
  local text = env:page()
  t.ok(type(text) == "string" and #text > 0)
  t.eq(#env.removed, 2, "обе страницы — по одному remove")
end

-- печать необязательна: слова в конфиге нет — дневник открыт сразу (владелец 2026-10-25) -------------

function T.test_no_password_diary_is_open_at_once()
  local env = make({ variants = {} })
  t.ok(env.ctrl.seal_open, "печати нет: открыт до первой страницы")
  t.ok(not env.ctrl.sealed, "печать не настроена")
  t.ok(logged(env, "riddle: seal off (no password in config)"), table.concat(env.logs, "\n"))
  env:say("привет", "здравствуй")
  t.eq(env:page(), "здравствуй", "ответ — обычный, не приветствие")
  t.eq(#env.llm_calls, 1)
  t.ok(not is_locked_call(env.llm_calls[1]), "запрос по промпту открытой печати")
  t.eq(#env.memory.adds, 2, "страница и ответ — в память")
end

function T.test_empty_password_strings_mean_no_seal()
  local env = make({ variants = { "", "" } })
  t.ok(env.ctrl.seal_open and not env.ctrl.sealed, "все варианты пустые — печати нет")
end

function T.test_password_set_keeps_seal()
  local env = make()
  t.ok(env.ctrl.sealed, "слово есть — печать есть")
  t.ok(not env.ctrl.seal_open)
  t.ok(not logged(env, "seal off"), "строки «seal off» нет")
end

function T.test_no_password_sleep_does_not_close()
  local env = make({ variants = {} })
  env.ctrl:on_sleep()
  t.ok(env.ctrl.seal_open, "закрывать нечего")
  env:say("привет", "здравствуй")
  env:page()
  t.ok(not is_locked_call(env.llm_calls[1]), "после сна всё равно открытый промпт")
end

-- без разблокировки нет и «после приветствия»: хвост (лор, пересказ) — после первого ответа,
-- и снова после сна. Повод гасит начало хвоста, не взятие: не начатый хвост берётся снова
function T.test_no_password_followup_due_after_start_and_sleep()
  local env = make({ variants = {} })
  t.ok(env.ctrl:take_followup(), "после старта хвост положен")
  t.ok(env.ctrl:take_followup(), "хвост не начался — повод остаётся")
  env.ctrl:on_unlocked_followup()
  t.ok(not env.ctrl:take_followup(), "хвост начался — повод погашен")
  env.ctrl:on_sleep()
  t.ok(env.ctrl:take_followup(), "после сна снова")
end

function T.test_sealed_take_followup_is_false()
  local env = make()
  env:unlock()
  t.ok(not env.ctrl:take_followup(), "с печатью хвост идёт по разблокировке, не по этому флагу")
end

-- сон -----------------------------------------------------------------------

function T.test_sleep_locks()
  local env = make()
  env:unlock()
  env:say("привет", "здравствуй")
  env:page()
  t.ok(not is_locked_call(env.llm_calls[2]))
  env.ctrl:on_sleep()
  t.ok(not env.ctrl.seal_open)
  env:say("кто ты", "закрыто")
  t.eq(env:page(), "закрыто")
  t.ok(is_locked_call(env.llm_calls[3]), "после сна запрос идёт через prompt.locked")
end

function T.test_sleep_resets_hint_counter()
  local env = make()
  for _ = 1, 2 do env:say("кто ты", "отказ"); env:page() end
  env.ctrl:on_sleep()
  env:say("кто ты", "отказ"); t.eq(env:page(), "отказ", "счётчик сброшен: это 1-я неудача")
end

function T.test_session_continues_after_sleep()
  local env = make({ now = 0 })
  env:unlock()
  env:say("первая", "ответ 1"); env:page()
  env.ctrl:on_sleep()
  env.now_value = 3600
  env:unlock()
  env:say("вторая", "ответ 2"); env:page()
  t.eq(env.memory.adds[1].sid, env.memory.adds[3].sid, "тот же сеанс в пределах 4 ч")
  t.ok(has(json.encode(env.llm_calls[#env.llm_calls].messages), "ответ 1"), "разговор продолжается")
end

-- после приветствия ---------------------------------------------------------

function T.test_followup_lore_and_summary()
  local env = make({ now = 0 })
  local m = env.memory
  m:session(0)
  m:add(1, "owner", "ЗАПИСЬ-ПРОШЛОЙ", 10)
  m:add(1, "diary", "ОТВЕТ-ПРОШЛОЙ", 11)
  env.now_value = 5 * 3600
  env.files[LORE] = "## Мир\nЛОР-ТЕКСТ"
  env.mtimes[LORE] = 777
  env.script = { { text = "Ты писала мне о прошлом." } }

  env.ctrl:on_unlocked_followup()

  t.eq(#env.llm_calls, 1, "один LLM-вызов")
  t.eq(env.llm_calls[1].want_json, false)
  t.eq(env.llm_calls[1].opts and env.llm_calls[1].opts.max_tokens, controller.SUMMARY_MAX_TOKENS,
    "у пересказа свой потолок ответа")
  t.ok(controller.SUMMARY_MAX_TOKENS > 200, "больше потолка ответа по умолчанию")
  local s = json.encode(env.llm_calls[1].messages)
  t.ok(has(s, "ЗАПИСЬ-ПРОШЛОЙ") and has(s, "ОТВЕТ-ПРОШЛОЙ"), "реплики прошлой сессии в пересказе")
  t.ok(not has(s, "image_url"))
  t.eq(#m.set_summaries, 1)
  t.eq(m.set_summaries[1].sid, 1)
  t.eq(m.set_summaries[1].text, "Ты писала мне о прошлом.")
  t.eq(#m.imported, 1)
  t.eq(m.imported[1].md, "## Мир\nЛОР-ТЕКСТ")
  t.eq(m.imported[1].mtime, 777)

  -- повторно: пересказ уже есть, mtime тот же -> ничего
  env.ctrl:on_unlocked_followup()
  t.eq(#env.llm_calls, 1)
  t.eq(#m.imported, 1)

  -- лор изменился -> импорт
  env.mtimes[LORE] = 888
  env.files[LORE] = "## Мир\nНОВЫЙ"
  env.ctrl:on_unlocked_followup()
  t.eq(#m.imported, 2)
  t.eq(m.imported[2].mtime, 888)
end

function T.test_followup_failure_is_silent()
  local env = make({ now = 0 })
  local m = env.memory
  m:session(0)
  m:add(1, "owner", "x", 10)
  env.now_value = 5 * 3600
  env.script = { { fail = "budget" } }
  env.ctrl:on_unlocked_followup()
  t.eq(#m.set_summaries, 0, "провал пересказа — молча пропущен")

  env.script = { { throw = "boom" } }
  env.ctrl:on_unlocked_followup()
  t.eq(#m.set_summaries, 0)
end

function T.test_followup_no_lore_file()
  local env = make()
  env.ctrl:on_unlocked_followup()
  t.eq(#env.memory.imported, 0)
  t.eq(#env.llm_calls, 0, "нечего пересказывать")
end

function T.test_followup_empty_session_skipped_without_llm()
  local env = make({ now = 0 })
  local m = env.memory
  m:session(0) -- пустая сессия без записей
  env.now_value = 5 * 3600
  env.ctrl:on_unlocked_followup()
  t.eq(#env.llm_calls, 0)
  t.eq(#m.set_summaries, 1)
  t.eq(m.set_summaries[1].text, "", "пустая сессия помечена, чтобы не возвращаться")
end

-- пересказ через дочерний процесс: begin_followup в родителе (лор, запрос), job.run в дочернем,
-- finish_followup в родителе сохраняет; LLM в родителе не зовётся
local function past_session(env)
  local m = env.memory
  m:session(0)
  m:add(1, "owner", "ЗАПИСЬ-ПРОШЛОЙ", 10)
  m:add(1, "diary", "ОТВЕТ-ПРОШЛОЙ", 11)
  env.now_value = 5 * 3600
  return m
end

function T.test_followup_async_begin_run_finish()
  local env = make({ now = 0 })
  local m = past_session(env)
  env.files[LORE] = "## Мир\nЛОР-ТЕКСТ"
  env.mtimes[LORE] = 777
  local job = env.ctrl:begin_followup()
  t.ok(job and type(job.run) == "function", "задача для дочернего")
  t.eq(#env.llm_calls, 0, "в родителе LLM не зовётся")
  t.eq(#m.imported, 1, "лор — в родителе, сразу")
  t.eq(#m.set_summaries, 0, "пересказа ещё нет")
  env.script = { { text = "Мне писали о прошлом." } }
  local payload = job.run()
  t.eq(env.llm_calls[1].want_json, false)
  t.eq(env.llm_calls[1].opts and env.llm_calls[1].opts.max_tokens, controller.SUMMARY_MAX_TOKENS,
    "потолок пересказа и в дочернем")
  t.ok(has(json.encode(env.llm_calls[1].messages), "ЗАПИСЬ-ПРОШЛОЙ"))
  env.ctrl:finish_followup(job, payload)
  t.eq(#m.set_summaries, 1)
  t.eq(m.set_summaries[1].sid, 1)
  t.eq(m.set_summaries[1].text, "Мне писали о прошлом.")
  t.eq(env.ctrl:begin_followup(), nil, "пересказ есть — пересказывать нечего")
end

-- таймаут, отмена, ошибка модели, исключение — пересказ не сохраняется (повторится в следующий раз)
function T.test_followup_async_failure_not_saved()
  for _, case in ipairs({ { nil, "timeout" }, { nil, "cancelled" }, { { err = "budget" } }, { { result = { text = "" } } } }) do
    local env = make({ now = 0 })
    local m = past_session(env)
    local job = env.ctrl:begin_followup()
    t.ok(job, "задача есть")
    env.ctrl:finish_followup(job, case[1], case[2])
    t.eq(#m.set_summaries, 0, "не сохранён: " .. tostring(case[2]))
    t.ok(env.ctrl:begin_followup(), "пересказ повторится")
  end
  local env = make({ now = 0 })
  past_session(env)
  local job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, nil, "timeout")
  t.ok(logged(env, "riddle: summary failed: timeout"), table.concat(env.logs, "\n"))
  env.memory.set_summary = function() error("disk") end
  env.ctrl:finish_followup(job, { result = { text = "x" } }) -- не падает
  t.ok(logged(env, "riddle: summary failed:"), "сбой записи — в лог")
end

function T.test_followup_async_empty_session_marked_without_job()
  local env = make({ now = 0 })
  local m = env.memory
  m:session(0)
  env.now_value = 5 * 3600
  t.eq(env.ctrl:begin_followup(), nil)
  t.eq(#m.set_summaries, 1)
  t.eq(m.set_summaries[1].text, "", "пустая сессия помечена")
  t.eq(#env.llm_calls, 0)
end

function T.test_followup_async_remote_fn_failure_is_silent()
  local env = make({ now = 0 })
  past_session(env)
  env.ctrl.deps.remote_fn = function() error("boom") end
  t.eq(env.ctrl:begin_followup(), nil)
  t.ok(logged(env, "riddle: summary failed:"))
end

-- begin/finish (ответ в дочернем процессе) ----------------------------------

-- один сценарий двумя путями: on_page и begin -> run -> finish; совпадают текст, память, лог, PNG
local function both_ways(prepare, steps)
  local out = {}
  for _, async in ipairs({ false, true }) do
    local env = make({ devmode = true })
    prepare(env)
    env.logs, env.removed, env.memory.adds = {}, {}, {}
    local shown = {}
    for _, step in ipairs(steps) do
      env:say(step[1], step[2])
      shown[#shown + 1] = async and env:page_async() or env:page()
    end
    out[#out + 1] = { shown = json.encode(shown), adds = json.encode(env.memory.adds),
                      logs = json.encode(env.logs), removed = json.encode(env.removed),
                      calls = #env.llm_calls, open = env.ctrl.seal_open }
  end
  return out[1], out[2]
end

local function same(a, b)
  for _, k in ipairs({ "shown", "adds", "logs", "removed", "calls", "open" }) do
    t.eq(b[k], a[k], k)
  end
end

function T.test_begin_finish_equals_on_page_open()
  local a, b = both_ways(function(env) env:unlock() end,
    { { "кто ты", "Я — страницы." }, { "?", "" }, { "а ты", "" } })
  t.ok(a.adds:find("Я — страницы.", 1, true), a.adds)
  same(a, b)
end

function T.test_begin_finish_equals_on_page_locked()
  local a, b = both_ways(function() end,
    { { "кто ты", "отказ 1" }, { "кто ты", "отказ 2" }, { "кто ты", "отказ 3" }, { "Salandusa", "x" } })
  t.ok(a.logs:find("seal read", 1, true), a.logs)
  t.eq(a.open, true)
  same(a, b)
end

function T.test_begin_removes_png_even_on_error()
  local env = make()
  env.read_fails = true
  local job, text = env.ctrl:begin(PNG)
  t.eq(job, nil)
  t.ok(in_list(texts.fail_other, text), tostring(text))
  t.eq(env.removed[1], PNG, "PNG удалён и при сбое чтения")
  t.eq(#env.llm_calls, 0)
end

function T.test_begin_removes_png_before_answer()
  local env = make()
  local job = env.ctrl:begin(PNG)
  t.ok(job and job.mode == "locked" and type(job.run) == "function", "job закрытой печати")
  t.eq(env.removed[1], PNG, "PNG удалён до ответа")
  t.eq(#env.llm_calls, 0, "begin не зовёт модель")
end

function T.test_finish_timeout_gives_fail_slow()
  local env = make()
  local job = env.ctrl:begin(PNG)
  local text = env.ctrl:finish(job, nil, "timeout")
  t.ok(in_list(texts.fail_slow, text), text)
  t.ok(env.logs[#env.logs]:find("timeout", 1, true), table.concat(env.logs, "\n"))
end

function T.test_finish_crashed_gives_fail_other_and_keeps_memory_clean()
  local env = make()
  env:unlock()
  env.memory.adds = {}
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "open")
  t.ok(in_list(texts.fail_other, env.ctrl:finish(job, nil, "crashed")))
  t.eq(#env.memory.adds, 0)
end

-- печати нет: промпт открытой печати без слов о печати; печать снята — модель это знает
function T.test_no_seal_prompt_has_no_seal()
  local env = make({ variants = {} })
  env:say("привет", "здравствуй")
  env:page()
  local s = system_of(env.llm_calls[1])
  t.ok(not has(s, "печат") and not has(s, "Печат"), "без печати модель не слышит о печати")
end

function T.test_unlocked_prompt_says_seal_is_off()
  local env = make()
  env:unlock()
  env:say("привет", "здравствуй")
  env:page()
  t.ok(has(system_of(env.llm_calls[#env.llm_calls]), "Печать снята"))
end

-- знания из Notion (срез 4): читаются в begin в родителе, только для открытой печати ---------------

local function knowledge_dep(calls, text, mode)
  return function()
    calls.n = calls.n + 1
    if text == "THROW" then error("database is locked") end
    return text, mode
  end
end

function T.test_begin_open_includes_knowledge()
  local calls = { n = 0 }
  local env = make({ knowledge_text = knowledge_dep(calls, "ЗНАНИЕ-МАРКЕР", "small") })
  env:unlock()
  t.eq(calls.n, 0, "закрытая печать знание не читала")
  local job = env.ctrl:begin(PNG)
  t.eq(calls.n, 1, "знание прочитано в begin, до run")
  t.ok(job.mode == "open" and has(job.messages[1].content, "ЗНАНИЕ-МАРКЕР"), "знание в системном промпте")
  -- синхронный путь — тот же промпт
  env:say("кто ты", "Я помню.")
  t.eq(env:page(), "Я помню.")
  t.ok(has(system_of(env.llm_calls[#env.llm_calls]), "ЗНАНИЕ-МАРКЕР"), "on_page тоже со знанием")
end

function T.test_begin_locked_has_no_knowledge()
  local calls = { n = 0 }
  local env = make({ knowledge_text = knowledge_dep(calls, "ЗНАНИЕ-МАРКЕР", "small") })
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "locked")
  t.eq(calls.n, 0, "закрытая печать знание не читает")
  t.ok(not has(json.encode(job.messages), "ЗНАНИЕ-МАРКЕР"), "знания нет в закрытой печати")
  env:say("кто ты", "Молчу.")
  env:page()
  t.ok(is_locked_call(env.llm_calls[1]), "закрытый промпт без знания")
end

function T.test_knowledge_read_failure_still_answers()
  for _, text in ipairs({ "THROW", false }) do
    local calls = { n = 0 }
    local env = make({ knowledge_text = knowledge_dep(calls, text or nil) })
    local plain = make()
    env:unlock(); plain:unlock()
    env.logs = {}
    local job = env.ctrl:begin(PNG)
    t.ok(job and job.mode == "open", "ответ собран и без знания")
    t.eq(job.messages[1].content, plain.ctrl:begin(PNG).messages[1].content, "промпт как без знания")
    env:say("кто ты", "Я помню.")
    t.eq(env.ctrl:finish(job, job.run()), "Я помню.")
    if text == "THROW" then
      t.ok(logged(env, "riddle: knowledge read failed: "), table.concat(env.logs, "\n"))
    end
  end
end

-- проба модели (страница состояния, план 2026-11-19-status-triangle Task 6): один короткий запрос без JSON через
-- дочерний; ответ не читается — только дошёл ли. payload — через absorb (логи, мёртвые ключи)
function T.test_probe_job_one_token_request()
  local env = make()
  local job = env.ctrl:probe_job()
  t.eq(type(job.run), "function", "run — для дочернего")
  t.eq(#env.llm_calls, 0, "в родителе запроса нет")
  env.script[1] = { text = "ok" }
  local payload = job.run()
  local call = env.llm_calls[1]
  t.eq(call.opts.max_tokens, 1)
  t.eq(call.want_json, false)
  t.eq(#call.messages, 1)
  t.eq(call.messages[1].role, "user")
  t.eq(call.messages[1].content, "ok")
  t.eq(env.ctrl:probe_finish(payload), true)
end

function T.test_probe_finish_errors()
  local env = make()
  local job = env.ctrl:probe_job()
  env.script[1] = { fail = "gemini: http 429" }
  local ok, err = env.ctrl:probe_finish(job.run())
  t.eq(ok, nil)
  t.eq(err, "gemini: http 429")
  ok, err = env.ctrl:probe_finish(nil, "timeout")
  t.eq(ok, nil)
  t.eq(err, "timeout", "ошибка раннера — как есть")
end

-- цепочка не собралась (remote_fn упал в родителе): задания нет, причина — вторым значением
function T.test_probe_job_remote_fn_failure()
  local env = make()
  env.ctrl.deps.remote_fn = function() error("no providers") end
  local job, err = env.ctrl:probe_job()
  t.eq(job, nil)
  t.ok(tostring(err):find("no providers", 1, true), tostring(err))
end

t.run(T)
