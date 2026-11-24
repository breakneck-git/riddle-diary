local t = require("t")
local json = require("dkjson")
local texts = require("riddle.texts")
local prompt = require("riddle.prompt")
local controller = require("riddle.controller")
local llm = require("riddle.llm")
local config = require("riddle.config")
local tasks = require("riddle.tasks")

local T = {}

local PNG = "/mnt/us/riddle/samples/1.png"
local LORE = "/mnt/us/riddle/lore.md"

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
    -- печать по умолчанию — по ключу; seal = false — печати нет, таблица — свои правила
    cfg = opts.cfg or { seal = config.parse_seal(opts.seal == nil and { key = true } or opts.seal or nil) },
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
    -- образец ключа (seal.load_key / file.write_atomic в app.new_controller); нет — стенд образца не знает
    load_key = opts.load_key,
    write_key = opts.write_key,
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
  -- ключ узнан: печать открывается без вызова модели (задача 6 зовёт seal_toggle со страницы ключа)
  function env:unlock()
    local text = env.ctrl:seal_toggle()
    t.ok(env.ctrl.seal_open, "печать должна быть снята")
    return text
  end
  return env
end

local function system_of(call) return call.messages[1].content end
-- запрос собран при закрытой печати: в system правило закрытой печати (prompt.SEAL_CLOSED)
local function is_closed_call(call) return has(system_of(call), prompt.SEAL_CLOSED) end

-- закрытая печать -----------------------------------------------------------

function T.test_closed_page_answered_by_model()
  local env = make()
  env:say("кто ты", "Мои страницы молчат…")
  local text = env:page()
  t.eq(text, "Мои страницы молчат…")
  t.eq(#env.llm_calls, 1)
  t.ok(is_closed_call(env.llm_calls[1]), "запрос закрытой печати")
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
  local env = make({ seal = false })
  local ticks = { 1.000, 1.012 }
  env.ctrl.deps.clock = function() return table.remove(ticks, 1) or 1.012 end
  env:say("кто ты", "Нет.")
  t.ok(env.ctrl:begin(PNG), "job есть")
  local line = logged(env, "riddle: prompt built in 12 ms chars=")
  t.ok(line, table.concat(env.logs, "\n"))
  t.ok(line:match("chars=%d+$"), line)
end

-- закрытая печать собирает тот же запрос (без данных) — и время сборки в лог тоже
function T.test_closed_begin_logs_build_time()
  local env = make()
  local ticks = { 1.000, 1.003 }
  env.ctrl.deps.clock = function() return table.remove(ticks, 1) or 1.003 end
  t.ok(env.ctrl:begin(PNG), "job есть")
  t.ok(logged(env, "riddle: prompt built in 3 ms chars="), table.concat(env.logs, "\n"))
end

-- касание не съедает хвост разблокировки (без печати он ждёт первого настоящего ответа)
function T.test_tiny_png_keeps_followup_without_seal()
  local env = make({ seal = false })
  env.files[PNG] = fixture("rgb5x5_dynamic.png")
  t.eq(env.ctrl:on_page(PNG), nil)
  t.ok(env.ctrl:take_followup(), "хвост остался")
end

-- закрытая печать: что прочла модель и через кого — в лог только в devmode, как у открытой; без него в лог Kindle
-- не идёт написанное на странице
function T.test_closed_logs_read_and_provider_in_devmode()
  local env = make({ devmode = true })
  env.script[1] = { read = "кто ты\nвот", reply = "Нет.", via = "gemini" }
  env:page()
  t.ok(logged(env, 'riddle: open read "кто ты\\nвот"') and logged(env, "via gemini"), table.concat(env.logs, "\n"))
end

function T.test_closed_log_without_devmode_has_no_text()
  local env = make()
  env.script[1] = { read = "кто ты\nвот", reply = "Нет.", via = "gemini" }
  env:page()
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "кто ты") and not has(l, "вот"), "текст read не в логе: " .. l)
  end
end

-- открытая печать без devmode: текста read в логе нет — в лог Kindle не идёт написанное
function T.test_open_seal_does_not_log_read()
  for _, devmode in ipairs({ false, true }) do
    local env = make({ devmode = devmode })
    env:unlock()
    env.logs = {}
    env:say("секретные слова", "Ответ.")
    env:page()
    for _, l in ipairs(env.logs) do
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

-- ключ: первый вызов открывает с приветствием, второй закрывает фразой; модель не зовётся, в память ничего
function T.test_toggle_welcome_then_close()
  local env = make()
  t.ok(not env.ctrl.seal_open)
  local text = env.ctrl:seal_toggle()
  t.ok(in_list(texts.welcomes, text), tostring(text))
  t.ok(env.ctrl.seal_open)
  t.eq(env.ctrl:seal_toggle(), texts.seal_closed)
  t.ok(not env.ctrl.seal_open)
  t.eq(#env.llm_calls, 0, "ключ не зовёт модель")
  t.eq(#env.memory.adds, 0, "ключ не пишется в память")
  t.ok(logged(env, "riddle: seal opened by key") and logged(env, "riddle: seal closed by key"),
    table.concat(env.logs, "\n"))
end

function T.test_seal_closed_text()
  t.eq(texts.seal_closed, "Печать легла. Страницы молчат.")
end

-- графический ключ (план seal-key, задача 6): образец — две розы владельца, страница-ключ — key_page ---------------
local O = require("fixtures.rose_owner")
local TF = require("fixtures.triangle_strokes")

local function keyed(opts)
  opts = opts or {}
  opts.load_key = function() return { O.owner_01, O.owner_02 } end
  return make(opts)
end

function T.test_key_opens_then_closes()
  local env = keyed()
  t.ok(not env.ctrl.seal_open)
  local text = env.ctrl:key_page(O.owner_03)
  t.ok(in_list(texts.welcomes, text), "закрытую ключ открывает приветствием: " .. tostring(text))
  t.ok(env.ctrl.seal_open)
  t.eq(env.ctrl:key_page(O.owner_04), texts.seal_closed, "открытую тот же ключ закрывает")
  t.ok(not env.ctrl.seal_open)
  t.eq(#env.llm_calls, 0, "ключ не зовёт модель")
  t.eq(#env.memory.adds, 0, "ключ не пишется в память")
end

-- промах — обычная страница: key_page молчит, печать на месте
function T.test_wrong_figure_is_normal_page()
  local env = keyed()
  t.eq(env.ctrl:key_page(TF.equilateral), nil, "треугольник — не ключ")
  t.eq(env.ctrl:key_page(TF.letter_a), nil, "буква — не ключ")
  t.eq(env.ctrl:key_page({}), nil)
  local six = {}
  for i = 1, 6 do six[i] = O.owner_03[1] end
  t.eq(env.ctrl:key_page(six), nil, "страница со словами не сравнивается")
  t.ok(not env.ctrl.seal_open)
end

-- Review Focus 1: ответ, собранный при открытой печати, пришёл после закрытия ключом — не показывается; в память
-- запись ложится, как решено в начале страницы (job.write): чернила растворились, память — единственная копия.
-- В лог — только факт
function T.test_answer_in_flight_dropped_on_close()
  local env = keyed()
  env.ctrl:key_page(O.owner_03)
  env:say("мои дела", "СЕКРЕТ")
  local job = env.ctrl:begin(PNG)
  t.ok(job and job.mode == "open", "запрос собран при открытой печати")
  t.eq(env.ctrl:key_page(O.owner_04), texts.seal_closed)
  local adds = #env.memory.adds
  t.eq(env.ctrl:finish(job, job.run()), nil, "ответ после закрытия не показывается")
  t.eq(#env.memory.adds, adds + 2, "запись и ответ легли в память")
  t.eq(#env.ctrl.closed_turns, 0, "реплика открытой печати — не в связности закрытой")
  t.ok(logged(env, "riddle: answer dropped, seal changed"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do t.ok(not has(l, "СЕКРЕТ"), "текста ответа в логе нет: " .. l) end
  -- печать не сдвигалась — ответ показывается, как всегда
  env:say("кто ты", "Ответ.")
  local job2 = env.ctrl:begin(PNG)
  t.eq(env.ctrl:finish(job2, job2.run()), "Ответ.")
end

-- и обратно: ответ закрытой печати, пришедший после открытия, не показывается; запись (remember = true) ложится
-- в память так же, как легла бы без ключа, а в связность закрытой печати — нет: она уже сброшена открытием
function T.test_closed_answer_dropped_on_open()
  local plain = keyed()
  plain:say("кто ты", "Мои страницы молчат…")
  local pjob = plain.ctrl:begin(PNG)
  t.eq(plain.ctrl:finish(pjob, pjob.run()), "Мои страницы молчат…")
  local env = keyed()
  env:say("кто ты", "Мои страницы молчат…")
  local job = env.ctrl:begin(PNG)
  t.ok(job.closed, "запрос без данных")
  env.ctrl:key_page(O.owner_03)
  t.ok(env.ctrl.seal_open)
  t.eq(env.ctrl:finish(job, job.run()), nil)
  t.eq(#plain.memory.adds, 2, "без ключа запись легла")
  t.eq(#env.memory.adds, #plain.memory.adds, "с ключом — так же")
  for i, a in ipairs(plain.memory.adds) do
    t.eq(env.memory.adds[i].role .. ":" .. env.memory.adds[i].text, a.role .. ":" .. a.text)
  end
  t.eq(#env.ctrl.closed_turns, 0, "реплика закрытой печати не легла в связность после открытия")
end

-- задание ключа (задача 5): образец записан — печать открыта с хвостом, связность закрытой печати сброшена (M8)
function T.test_key_saved_opens_with_followup()
  local writes = {}
  local env = make({
    load_key = function() return nil, "absent" end,
    write_key = function(path, s) writes[#writes + 1] = s return true end,
  })
  env:say("кто ты", "Мои страницы молчат…")
  env:page()
  t.ok(#env.ctrl.closed_turns > 0, "закрытый разговор шёл")
  t.ok(not env.ctrl.followup_due)
  local square_again = { { p = { 230, 320, 560, 310, 545, 660, 215, 640, 230, 320 } } }
  t.eq(env.ctrl:key_page(TF.square), texts.key_again)
  t.eq(env.ctrl:key_page(square_again), texts.key_saved)
  t.eq(#writes, 1)
  t.eq(env.ctrl.followup_due, true, "хвост (лор, пересказ) положен")
  t.eq(#env.ctrl.closed_turns, 0, "связность закрытой печати сброшена")
end

-- печати нет или конфиг битый — ключ печать не сдвигает
function T.test_toggle_without_seal_or_invalid_is_noop()
  local env = make({ seal = false })
  t.eq(env.ctrl:seal_toggle(), nil)
  t.ok(env.ctrl.seal_open, "печати нет — открыт")
  local bad = make({ seal = { minutes = 5 } })
  t.eq(bad.ctrl:seal_toggle(), nil)
  t.ok(not bad.ctrl.seal_open, "битая печать ключом не открывается")
  t.ok(logged(bad, "riddle: seal config invalid: close rule without key"), table.concat(bad.logs, "\n"))
end

-- открытие ключом при ждущем вопросе о строке: вопрос идёт вместе с приветствием
function T.test_toggle_welcome_carries_pending_question()
  local env = make()
  env.ctrl._pending_ask = function() return "ВОПРОС?" end
  local text = env.ctrl:seal_toggle()
  t.ok(has(text, " ВОПРОС?"), text)
  t.eq(env.ctrl.asked, "ВОПРОС?")
end

function T.test_unreadable_closed()
  local env = make()
  env:say("?", "")
  local text = env:page()
  t.ok(in_list(texts.unreadable, text), text)
  t.eq(#env.memory.adds, 0)
  -- закрытая печать показывает ответ модели (до задачи 3 — по закрытому промпту); слово больше ничего не снимает
  env:say("кто ты", "а"); t.eq(env:page(), "а")
  t.ok(not env.ctrl.seal_open)
end

function T.test_all_providers_fail_closed()
  local env = make()
  env.script = { { fail = "budget" } }
  local text = env:page()
  t.ok(in_list(texts.fail_slow, text), text)
  t.eq(#env.memory.adds, 0)
end

-- закрытая печать отсекает данные, дневник отвечает без них (spec §4) ------------------------------

local DATA_MARKS = { "МЕТКА-ЗНАНИЕ", "МЕТКА-ЗАДАЧА", "МЕТКА-ПЕРЕСКАЗ", "МЕТКА-РЕПЛИКА", "МЕТКА-ЛОР" }

-- стенд, где каждое данное пользователя помечено: знание и задача из Notion, пересказ прошлой сессии, реплика
-- текущей, лор
local function data_env(opts)
  opts = opts or {}
  opts.knowledge_text = function()
    return "МЕТКА-ЗНАНИЕ", nil, nil, { block = tasks.block({ { id = "id1", title = "МЕТКА-ЗАДАЧА" } }) }
  end
  local env = make(opts)
  local m = env.memory
  m.lore = "МЕТКА-ЛОР"
  m.sessions[1] = { id = 1, started = 0, last_ts = 0, summary = "МЕТКА-ПЕРЕСКАЗ" }
  m:add(1, "owner", "МЕТКА-РЕПЛИКА", 0)
  m.adds = {}
  return env
end

function T.test_closed_seal_sends_no_data()
  local env = data_env()
  t.ok(prompt.SEAL_CLOSED, "правило закрытой печати есть")
  env:say("кто ты", "Без печати не скажу.")
  t.eq(env:page(), "Без печати не скажу.", "ответ модели показан")
  t.eq(#env.llm_calls, 1)
  local s = json.encode(env.llm_calls[1].messages)
  for _, mark in ipairs(DATA_MARKS) do t.ok(not has(s, mark), "при закрытой печати в запросе " .. mark) end
  t.ok(has(system_of(env.llm_calls[1]), prompt.SEAL_CLOSED), "в system — правило закрытой печати")
  t.ok(has(s, "B64:PNGBYTES"), "картинка ушла в запрос")
  t.ok(not env.ctrl.seal_open)
end

function T.test_open_seal_sends_data()
  local env = data_env()
  env:unlock()
  env:say("кто ты", "Ответ.")
  env:page()
  local s = json.encode(env.llm_calls[1].messages)
  for _, mark in ipairs(DATA_MARKS) do t.ok(has(s, mark), "при открытой печати в запросе нет " .. mark) end
  t.ok(not has(system_of(env.llm_calls[1]), prompt.SEAL_CLOSED), "правила закрытой печати нет")
end

-- связность при закрытой печати — реплики с момента закрытия, из памяти процесса: при remember = false в базе их нет
function T.test_closed_turns_keep_context()
  local env = data_env({ seal = { key = true, remember = false } })
  env:say("ЗАПИСЬ-ЗАКРЫТАЯ-1", "ОТВЕТ-ЗАКРЫТЫЙ-1"); env:page()
  env:say("вторая", "ответ 2"); env:page()
  local s = json.encode(env.llm_calls[2].messages)
  t.ok(has(s, "ЗАПИСЬ-ЗАКРЫТАЯ-1") and has(s, "ОТВЕТ-ЗАКРЫТЫЙ-1"), "первая реплика во втором запросе")
  for _, mark in ipairs(DATA_MARKS) do t.ok(not has(s, mark), "во втором запросе " .. mark) end
end

-- открытие сбрасывает реплики закрытой печати: после нового закрытия разговор начинается заново
function T.test_unlock_resets_closed_turns()
  local env = data_env({ seal = { key = true, remember = false } })
  env:say("ЗАПИСЬ-ДО-КЛЮЧА", "ОТВЕТ-ДО-КЛЮЧА"); env:page()
  env:unlock()
  env.ctrl:seal_toggle()
  t.ok(not env.ctrl.seal_open)
  env:say("после", "ответ"); env:page()
  local s = json.encode(env.llm_calls[2].messages)
  t.ok(not has(s, "ЗАПИСЬ-ДО-КЛЮЧА") and not has(s, "ОТВЕТ-ДО-КЛЮЧА"), "реплики до ключа сброшены")
end

-- ответ владельца 20.11: разговор при закрытой печати по умолчанию пишется в память
function T.test_closed_remember_default_writes_memory()
  local env = data_env()
  env:say("ЗАКРЫТАЯ-ЗАПИСЬ", "ЗАКРЫТЫЙ-ОТВЕТ"); env:page()
  t.eq(#env.memory.adds, 2, "запись и ответ — в память")
  t.eq(env.memory.adds[1].text, "ЗАКРЫТАЯ-ЗАПИСЬ")
  t.eq(env.memory.adds[2].text, "ЗАКРЫТЫЙ-ОТВЕТ")
end

function T.test_closed_remember_false_skips_memory()
  local env = data_env({ seal = { key = true, remember = false } })
  env:say("ЗАКРЫТАЯ-ЗАПИСЬ", "ЗАКРЫТЫЙ-ОТВЕТ")
  t.eq(env:page(), "ЗАКРЫТЫЙ-ОТВЕТ")
  t.eq(#env.memory.adds, 0, "remember = false — в память ничего")
  env:unlock()
  env:say("открытая", "ответ"); env:page()
  t.eq(#env.memory.adds, 2, "при открытой — пишется")
end

-- хвосты при закрытой печати: ни лора, ни пересказа прошлой сессии, ни свёртки — они ждут открытия
function T.test_closed_followup_no_lore_no_summary()
  local env = data_env({ now = 5 * 3600 })
  local read = env.ctrl.deps.read_file
  local lore_reads = 0
  env.ctrl.deps.read_file = function(path)
    if path == LORE then lore_reads = lore_reads + 1 end
    return read(path)
  end
  env.files[LORE] = "## Мир\nНОВЫЙ-ЛОР"
  env.mtimes[LORE] = 777
  env.memory.sessions[1].summary = nil -- прошлая сессия ждёт пересказа
  env.ctrl.followup_due = true
  env.ctrl.roll_due = true
  local job = env.ctrl:begin_followup()
  t.ok(job == nil or job.kind == "gen", "при закрытой — только генерация персоны: " .. tostring(job and job.kind))
  t.eq(lore_reads, 0, "лор не читался")
  t.eq(#env.memory.imported, 0, "лор не импортирован")
  env.ctrl:on_unlocked_followup()
  t.eq(#env.llm_calls, 0, "синхронный хвост при закрытой модель не зовёт")
  t.eq(lore_reads, 0, "и лор не читает")
  t.ok(not env.ctrl:take_followup(), "хвост при закрытой не берётся")
  env:unlock()
  t.ok(env.ctrl:take_followup(), "открытие взводит хвост")
  job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session", "после открытия — пересказ ждущей сессии")
  t.eq(lore_reads, 1, "и лор")
end

-- имя владельца — тоже данные дневника: в память кладёт его фейк set_owner_name
local function owner_names(env)
  local names = {}
  env.memory.set_owner_name = function(_, id, name)
    names[#names + 1] = { id = id, name = name }
    return true
  end
  return names
end

-- решение о записи принимается в начале страницы: начатая при закрытой печати с remember = false не ложится в
-- память (ни реплики, ни имя), даже если печать открылась до ответа. Сам ответ не показывается (задача 6, Review
-- Focus 1)
function T.test_write_decided_at_page_start()
  local env = data_env({ seal = { key = true, remember = false } })
  local names = owner_names(env)
  env.script[1] = { read = "ЗАКРЫТАЯ-ЗАПИСЬ", reply = "ЗАКРЫТЫЙ-ОТВЕТ", name = "Гарри" }
  local job = env.ctrl:begin(PNG)
  env:unlock()
  t.eq(env.ctrl:finish(job, job.run()), nil)
  t.eq(#env.memory.adds, 0, "страница закрытой печати в память не легла")
  t.eq(#names, 0, "и имя не записано")
end

-- реплика страницы, начатой при открытой печати, не идёт в связность закрытой, даже если печать закрылась до ответа:
-- её запрос собран с данными. Сам ответ не показывается (задача 6, Review Focus 1)
function T.test_open_page_answered_after_close_not_in_closed_turns()
  local env = data_env({ seal = { key = true, remember = false } })
  env:unlock()
  env:say("ОТКРЫТАЯ-ЗАПИСЬ", "ОТКРЫТЫЙ-ОТВЕТ")
  local job = env.ctrl:begin(PNG)
  env.ctrl:seal_toggle()
  t.ok(not env.ctrl.seal_open, "печать закрыта до ответа")
  t.eq(env.ctrl:finish(job, job.run()), nil)
  env:say("закрытая", "ответ"); env:page()
  local s = json.encode(env.llm_calls[2].messages)
  t.ok(is_closed_call(env.llm_calls[2]), "второй запрос — закрытой печати")
  t.ok(not has(s, "ОТКРЫТАЯ-ЗАПИСЬ") and not has(s, "ОТКРЫТЫЙ-ОТВЕТ"), "реплика открытой — не в закрытом запросе")
end

-- лор — данные пользователя: страница при закрытой печати его не синхронизирует, даже когда хвост старта взведён
function T.test_closed_page_does_not_sync_lore()
  local env = data_env()
  local read = env.ctrl.deps.read_file
  local lore_reads = 0
  env.ctrl.deps.read_file = function(path)
    if path == LORE then lore_reads = lore_reads + 1 end
    return read(path)
  end
  env.files[LORE] = "## Мир\nНОВЫЙ-ЛОР"
  env.mtimes[LORE] = 777
  env.ctrl.followup_due = true
  env:say("кто ты", "ответ"); env:page()
  t.eq(lore_reads, 0, "лор не читался")
  t.eq(#env.memory.imported, 0, "лор не импортирован")
  t.ok(not has(json.encode(env.llm_calls[1].messages), "НОВЫЙ-ЛОР"), "и в запрос не ушёл")
end

-- имя владельца при закрытой печати с remember = false не пишется; при открытой — пишется (стенд проверяет, что имя
-- годное)
function T.test_closed_remember_false_skips_owner_name()
  local env = data_env({ seal = { key = true, remember = false } })
  local names = owner_names(env)
  env.script[1] = { read = "я Гарри", reply = "ответ", name = "Гарри" }
  env:page()
  t.eq(#names, 0, "при закрытой с remember = false имя не записано")
  env:unlock()
  env.script[1] = { read = "я Гарри", reply = "ответ", name = "Гарри" }
  env:page()
  t.eq(#names, 1, "при открытой — записано")
  t.eq(names[1].name, "Гарри")
end

-- просьба о данных при закрытой печати (план Task 8, spec §7): модель ставит needs_data; 5 просьб за 10 минут — к ответу
-- фраза texts.key_needed, окно начинается заново. at — время страницы (deps.now), needs — значение needs_data
local ASK_REPLY = "Для этого сними печать."
local function ask_data(env, at, needs)
  env.now_value = at
  if needs == nil then needs = true end
  env.script[#env.script + 1] = { read = "что я писал вчера", reply = ASK_REPLY, needs_data = needs }
  return env:page()
end
local function hinted() return ASK_REPLY .. " " .. tostring(texts.key_needed) end

function T.test_key_needed_text()
  t.eq(texts.key_needed, "Чтобы открыть данные, нарисуй графический ключ.")
end

function T.test_four_asks_no_hint()
  local env = data_env()
  for i, at in ipairs({ 0, 180, 360, 540 }) do t.eq(ask_data(env, 1000 + at), ASK_REPLY, "просьба " .. i) end
end

function T.test_fifth_ask_hint()
  local env = data_env()
  for _, at in ipairs({ 0, 120, 240, 360 }) do t.eq(ask_data(env, 1000 + at), ASK_REPLY) end
  t.eq(ask_data(env, 1000 + 540), hinted(), "5-я за 9 минут — фраза через пробел после ответа")
end

-- просьбы старше окна (seal.ASKS_SPAN) уходят: 5 за 11 минут — фразы нет
function T.test_window_slides()
  local env = data_env()
  for i = 0, 4 do t.eq(ask_data(env, 1000 + i * 165), ASK_REPLY, "просьба " .. i + 1) end
end

function T.test_hint_restarts_window()
  local env = data_env()
  for i = 0, 3 do ask_data(env, 1000 + i * 60) end
  t.eq(ask_data(env, 1240), hinted())
  for i = 1, 4 do t.eq(ask_data(env, 1240 + i * 60), ASK_REPLY, "после фразы просьба " .. i) end
end

function T.test_unlock_resets()
  local env = data_env()
  for i = 0, 3 do ask_data(env, 1000 + i * 60) end
  env:unlock()
  env.ctrl:seal_toggle()
  t.ok(not env.ctrl.seal_open)
  t.eq(ask_data(env, 1300), ASK_REPLY, "после ключа счёт заново")
end

-- фраза texts.key_needed — только на экран: в память (remember) и в связность закрытой печати ложится ответ модели
-- без фразы. Порядок в _settle: _remember и closed_turns до _data_ask
function T.test_key_hint_only_on_screen()
  local env = data_env()
  for i = 0, 3 do ask_data(env, 1000 + i * 60) end
  env.memory.adds = {}
  t.eq(ask_data(env, 1240), hinted(), "на экране — с фразой")
  t.eq(#env.memory.adds, 2, "реплики — в память (remember)")
  t.eq(env.memory.adds[2].role, "diary")
  t.eq(env.memory.adds[2].text, ASK_REPLY, "в памяти — ответ модели без фразы")
  local turns = env.ctrl.closed_turns
  t.eq(turns[#turns].text, ASK_REPLY, "в связности — ответ модели без фразы")
end

-- просьба, собранная до сдвига печати (job.epoch ≠ seal_epoch: ключ открыл и снова закрыл, пока ответ был в пути),
-- не считается: в окне просьб её нет, и четыре новые просьбы фразы не дают
function T.test_ask_from_old_epoch_not_counted()
  local env = data_env()
  for i = 0, 3 do ask_data(env, 1000 + i * 60) end
  env.now_value = 1240
  env.script[#env.script + 1] = { read = "что я писал вчера", reply = ASK_REPLY, needs_data = true }
  local job = env.ctrl:begin(PNG)
  env:unlock()
  env.ctrl:seal_toggle()
  t.ok(not env.ctrl.seal_open, "печать снова закрыта")
  t.eq(env.ctrl:finish(job, job.run()), nil, "ответ сдвинутой печати не показан")
  t.eq(#env.ctrl.data_asks, 0, "просьба старой эпохи не в окне")
  for i = 1, 4 do t.eq(ask_data(env, 1240 + i * 60), ASK_REPLY, "новая просьба " .. i) end
end

-- needs_data считается только у ответов закрытой печати: при открытой правила нет, поле — мусор модели
function T.test_open_seal_ignores_needs_data()
  local env = data_env()
  env:unlock()
  for i = 0, 4 do t.eq(ask_data(env, 1000 + i * 60), ASK_REPLY, "открытая, просьба " .. i + 1) end
  env.ctrl:seal_toggle()
  t.ok(not env.ctrl.seal_open)
  t.eq(ask_data(env, 1300), ASK_REPLY, "закрытая — первая просьба")
end

-- ответ без просьбы (needs_data = false) не считается
function T.test_needs_data_false_not_counted()
  local env = data_env()
  for i = 0, 4 do t.eq(ask_data(env, 1000 + i * 60, false), ASK_REPLY, "ответ " .. i + 1) end
end

-- имя владельца на карте при закрытой печати не меняется и при remember = true (решение владельца 2026-11-25): чужой,
-- назвавшийся другим именем, его не перезаписывает. Реплики при этом в память ложатся (remember); при открытой — имя
-- пишется
function T.test_closed_seal_keeps_owner_name()
  local env = data_env()
  local names = owner_names(env)
  env.script[1] = { read = "меня зовут Драко", reply = "ответ", name = "Драко" }
  env:page()
  t.eq(#names, 0, "при закрытой имя не записано")
  t.eq(#env.memory.adds, 2, "реплики — в память (remember)")
  env:unlock()
  env.script[1] = { read = "меня зовут Гарри", reply = "ответ", name = "Гарри" }
  env:page()
  t.eq(#names, 1, "при открытой — записано")
  t.eq(names[1].name, "Гарри")
end

-- данные карты (имя владельца, персона) — данные дневника: при закрытой печати Controller:map их не отдаёт —
-- запасные без имени; при открытой — как всегда
function T.test_closed_seal_map_has_no_data()
  local env = data_env()
  env.ctrl.owner_name = function() return "Гарри" end
  t.eq(env.ctrl:map().owner, nil, "при закрытой имени на карте нет")
  env:unlock()
  t.eq(env.ctrl:map().owner, "Гарри", "при открытой — есть")
end

-- страница на открытой карте при закрытой печати (простой истёк без таймера): задание чтения строится — закрывашка
-- персоны нужна, чтобы фраза закрыла карту; имя владельца при этом не читается, и данные карты по-прежнему запасные
function T.test_closed_seal_map_read_job()
  local env = data_env()
  local owner_reads = 0
  env.ctrl.owner_name = function() owner_reads = owner_reads + 1 return "Гарри" end
  local job = env.ctrl:map_read_job(PNG)
  t.ok(job and job.run, "задание чтения есть")
  t.ok(not has(json.encode(job.messages), "Гарри"), "имени в запросе нет")
  t.eq(owner_reads, 0, "имя владельца не читалось")
  local _, action = env.ctrl:finish(job, { result = { read = "Шалость удалась", reply = "", map = "close" } })
  t.eq(action, "map", "фраза закрывает карту")
  t.eq(env.ctrl:map().owner, nil, "данные карты при закрытой — запасные")
  t.ok(not env.ctrl.seal_open)
end

-- связность закрытой печати хранится в окне истории промпта (prompt.MAX_RECENT реплик): старые уходят, новые остаются
function T.test_closed_turns_window_is_bounded()
  t.eq(prompt.MAX_RECENT, 40, "окно истории промпта")
  local env = data_env({ seal = { key = true, remember = false } })
  local pages = prompt.MAX_RECENT -- реплик вдвое больше окна
  for i = 1, pages do
    env:say("ЗАПИСЬ-" .. i .. "-", "ОТВЕТ-" .. i .. "-"); env:page()
  end
  local turns = env.ctrl.closed_turns
  t.eq(#turns, prompt.MAX_RECENT, "хранится не больше окна")
  t.eq(turns[#turns].text, "ОТВЕТ-" .. pages .. "-", "последняя реплика — на месте")
  t.eq(turns[1].text, "ЗАПИСЬ-" .. (pages - prompt.MAX_RECENT / 2 + 1) .. "-", "старые ушли")
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

  local first = env.llm_calls[1]
  t.ok(not is_closed_call(first), "открытая печать — другой промпт")
  t.eq(first.want_json, true)
  local s1 = json.encode(first.messages)
  t.ok(has(s1, "ЛОР-МАРКЕР"), "лор в промпте")
  t.ok(has(s1, "ПЕРЕСКАЗ-МАРКЕР"), "пересказ в промпте")
  t.ok(has(s1, "B64:PNGBYTES"))

  -- следующая запись видит прошлые реплики как диалог
  env:say("Расскажи мне сказку", "Жила-была…")
  env:page()
  local s2 = json.encode(env.llm_calls[2].messages)
  t.ok(has(s2, "Мне грустно") and has(s2, "Я с тобой"), "recent в промпте")
  t.eq(#env.memory.adds, 4)
end

-- окно истории контроллера — то же, что у промпта (prompt.MAX_RECENT = 40): 40 реплик доходят, 41-я — нет
function T.test_open_history_window_40()
  local env = make({ seal = false }) -- печати нет: открыт сразу
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
  local s = json.encode(env.llm_calls[1].messages)
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

-- закрытая печать: пустой reply — «не разобрала», печать по-прежнему закрыта
function T.test_closed_empty_reply_is_unreadable()
  local env = make()
  env:say("кто ты", "")
  t.ok(in_list(texts.unreadable, env:page()), "пустой отказ — «не разобрала»")
  t.ok(not env.ctrl.seal_open)
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

function T.test_fail_reason_picks_its_pool_open_and_closed()
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
  t.ok(logged(env, "boom"), "ошибка залогирована: " .. table.concat(env.logs, "\n"))
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
  t.eq(#env.removed, 1, "страница — один remove")
end

-- печать необязательна: правил в конфиге нет — дневник открыт сразу (владелец 2026-10-25) -------------

function T.test_no_password_diary_is_open_at_once()
  local env = make({ seal = false })
  t.ok(env.ctrl.seal_open, "печати нет: открыт до первой страницы")
  t.ok(not env.ctrl.seal.configured, "печать не настроена")
  t.ok(logged(env, "riddle: seal off (no rules in config)"), table.concat(env.logs, "\n"))
  env:say("привет", "здравствуй")
  t.eq(env:page(), "здравствуй", "ответ — обычный, не приветствие")
  t.eq(#env.llm_calls, 1)
  t.ok(not is_closed_call(env.llm_calls[1]), "запрос по промпту открытой печати")
  t.eq(#env.memory.adds, 2, "страница и ответ — в память")
end

-- флаг off: печати нет, в лог — что сняла её строка конфига
function T.test_off_flag_means_no_seal()
  local env = make({ seal = { key = true, off = true } })
  t.ok(env.ctrl.seal_open and not env.ctrl.seal.configured, "off — печати нет")
  t.ok(logged(env, "riddle: seal off by flag"), table.concat(env.logs, "\n"))
end

function T.test_rules_keep_seal()
  local env = make()
  t.ok(env.ctrl.seal.configured, "правило есть — печать есть")
  t.ok(not env.ctrl.seal_open)
  t.ok(not logged(env, "seal off"), "строки «seal off» нет")
end

-- битый конфиг печати: закрыта, в лог причина, ключ не открывает (test_toggle_without_seal_or_invalid_is_noop)
function T.test_invalid_seal_config_keeps_seal_closed()
  local path = os.tmpname()
  local f = assert(io.open(path, "w"))
  f:write("return { gemini_key = ")
  f:close()
  local env = make({ cfg = config.load(path) })
  os.remove(path)
  t.ok(env.ctrl.seal.configured and not env.ctrl.seal_open, "файл не загрузился — закрыта")
  t.ok(logged(env, "riddle: seal config invalid: "), table.concat(env.logs, "\n"))
  t.ok(not logged(env, "seal off"))
end

function T.test_no_password_sleep_does_not_close()
  local env = make({ seal = false })
  env.ctrl:on_sleep()
  t.ok(env.ctrl.seal_open, "закрывать нечего")
  env:say("привет", "здравствуй")
  env:page()
  t.ok(not is_closed_call(env.llm_calls[1]), "после сна всё равно открытый промпт")
end

-- без разблокировки нет и «после приветствия»: хвост (лор, пересказ) — после первого ответа,
-- и снова после сна. Повод гасит начало хвоста, не взятие: не начатый хвост берётся снова
function T.test_no_password_followup_due_after_start_and_sleep()
  local env = make({ seal = false })
  t.ok(env.ctrl:take_followup(), "после старта хвост положен")
  t.ok(env.ctrl:take_followup(), "хвост не начался — повод остаётся")
  env.ctrl:on_unlocked_followup()
  t.ok(not env.ctrl:take_followup(), "хвост начался — повод погашен")
  env.ctrl:on_sleep()
  t.ok(env.ctrl:take_followup(), "после сна снова")
end

-- открытие ключом взводит хвост (лор, пересказ), как старт без печати; при закрытой он не берётся
function T.test_unlock_sets_followup_due()
  local env = make()
  t.ok(not env.ctrl:take_followup(), "закрытая — хвоста нет")
  env:unlock()
  t.ok(env.ctrl:take_followup(), "после открытия хвост положен")
end

-- сон -----------------------------------------------------------------------

-- сон закрывает печать только по правилу on_sleep (spec §6)
function T.test_sleep_locks()
  local env = make({ seal = { key = true, on_sleep = true } })
  env:unlock()
  env:say("привет", "здравствуй")
  env:page()
  t.ok(not is_closed_call(env.llm_calls[1]))
  env.ctrl:on_sleep()
  t.ok(not env.ctrl.seal_open)
  env:say("кто ты", "закрыто")
  t.eq(env:page(), "закрыто")
  t.ok(is_closed_call(env.llm_calls[2]), "после сна запрос — закрытой печати")
end

function T.test_sleep_without_on_sleep_keeps_seal_open()
  local env = make()
  env:unlock()
  env.ctrl:on_sleep()
  t.ok(env.ctrl.seal_open, "правила on_sleep нет — сон печать не закрывает")
end

-- сон закрывает печать только по on_sleep; закрыв, сдвигает эпоху: ответ, собранный при открытой, не показывается
-- (Review Focus 1). Без правила ответ в пути показывается, как всегда
function T.test_sleep_closes_only_with_on_sleep()
  local keep = make()
  keep:unlock()
  keep:say("кто ты", "Ответ.")
  local job = keep.ctrl:begin(PNG)
  keep.ctrl:on_sleep()
  t.ok(keep.ctrl.seal_open, "без on_sleep открыта")
  t.eq(keep.ctrl:finish(job, job.run()), "Ответ.", "ответ в пути показан")

  local env = make({ seal = { key = true, on_sleep = true } })
  env:unlock()
  env:say("мои дела", "СЕКРЕТ")
  job = env.ctrl:begin(PNG)
  env.ctrl:on_sleep()
  t.ok(not env.ctrl.seal_open, "с on_sleep закрыта")
  t.eq(env.ctrl:finish(job, job.run()), nil, "ответ открытой печати после сна не показывается")
  t.ok(logged(env, "riddle: answer dropped, seal changed"), table.concat(env.logs, "\n"))
  t.ok(logged(env, "riddle: seal closed by sleep"), table.concat(env.logs, "\n"))
  -- второй сон (виджет и плагин зовут on_sleep оба) — закрывать нечего, строки нет
  env.ctrl:on_sleep()
  local n = 0
  for _, l in ipairs(env.logs) do if has(l, "seal closed by sleep") then n = n + 1 end end
  t.eq(n, 1, "о закрытии — одна строка")
end

-- простой (spec §6, правило minutes) ---------------------------------------------------------------------------

-- просроченная печать закрывается в начале страницы, до сборки контекста: данные не уходят и без таймера виджета
function T.test_idle_closes_before_context()
  local env = data_env({ seal = { key = true, minutes = 30 } })
  env:unlock()
  env:say("кто ты", "Ответ.")
  env:page()
  t.ok(not is_closed_call(env.llm_calls[1]), "в 1000 печать открыта")
  env.now_value = 1000 + 1800
  env:say("кто ты", "Закрыто.")
  t.eq(env:page(), "Закрыто.")
  local s = json.encode(env.llm_calls[2].messages)
  for _, mark in ipairs(DATA_MARKS) do t.ok(not has(s, mark), "после простоя в запросе " .. mark) end
  t.ok(is_closed_call(env.llm_calls[2]), "запрос закрытой печати")
  t.ok(not env.ctrl.seal_open)
  t.ok(logged(env, "riddle: seal closed by idle"), table.concat(env.logs, "\n"))
end

-- простой считается от последней отвеченной страницы, не от открытия
function T.test_answer_postpones_idle()
  local env = make({ seal = { key = true, minutes = 30 } })
  env:unlock()
  env.now_value = 2000
  env:say("кто ты", "Ответ.")
  env:page_async()
  t.eq(env.ctrl:seal_left(2000), 1800, "ответ в 2000 — отсчёт заново")
  t.eq(env.ctrl:seal_check(1000 + 1800), false, "через 30 минут от открытия ещё открыта")
  t.ok(env.ctrl.seal_open)
  t.eq(env.ctrl:seal_check(2000 + 1800), true, "через 30 минут от ответа закрыта")
  t.ok(not env.ctrl.seal_open)
  t.eq(env.ctrl:seal_check(2000 + 1800), false, "повтор — закрывать нечего")
  t.eq(env.ctrl:seal_left(2000 + 1800), nil, "закрытой отсчитывать нечего")
end

-- Review Focus 3 у контроллера: часы ушли назад — отсчёт заново от «сейчас»; вопрос seal_left видит тот же
-- отсчёт, что seal_check (одна точка сброса)
function T.test_seal_left_counts_anew_after_clock_back()
  local env = make({ seal = { key = true, minutes = 30 } })
  env:unlock() -- в 1000
  t.eq(env.ctrl:seal_left(500), 1800, "часы назад — полный срок")
  t.eq(env.ctrl:seal_left(500 + 1700), 100, "отсчёт от 500, не от 1000")
  t.eq(env.ctrl:seal_check(500 + 1799), false)
  t.eq(env.ctrl:seal_check(500 + 1800), true, "закрыта по новому отсчёту")
end

-- Review Focus 1, таймер: страница начата при открытой печати, простой закрыл её, пока ответ в пути, — ответ не
-- показывается и простой не отодвигает: печать остаётся закрытой
function T.test_timer_closes_and_drops_in_flight()
  local env = make({ seal = { key = true, minutes = 30 } })
  env:unlock()
  env.now_value = 1000 + 1700
  env:say("мои дела", "СЕКРЕТ")
  local job = env.ctrl:begin(PNG)
  t.ok(job and job.mode == "open" and not job.closed, "запрос собран при открытой печати")
  t.eq(env.ctrl:seal_check(1000 + 1800), true, "простой закрыл печать")
  env.now_value = 1000 + 1810
  t.eq(env.ctrl:finish(job, job.run()), nil, "ответ после закрытия не показывается")
  t.ok(not env.ctrl.seal_open)
  t.eq(env.ctrl:seal_left(), nil, "ответ закрытую не открыл и отсчёта не начал")
  t.ok(logged(env, "riddle: answer dropped, seal changed"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do t.ok(not has(l, "СЕКРЕТ"), "текста ответа в логе нет: " .. l) end
end

-- повторное ревью Task 7: синхронный путь (runner не поднялся, main.lua) — срок вышел, пока шёл llm_call: ответ
-- открытой печати не показывается, запись ложится в память по решению начала страницы
function T.test_sync_answer_past_deadline_dropped()
  local env = make({ seal = { key = true, minutes = 30 } })
  env:unlock()
  env.now_value = 1000 + 1795
  local call = env.ctrl.deps.llm_call
  env.ctrl.deps.llm_call = function(...)
    env.now_value = 1000 + 1802 -- запрос идёт семь секунд
    return call(...)
  end
  env:say("мои дела", "СЕКРЕТ")
  local adds = #env.memory.adds
  t.eq(env:page(), nil, "ответ после срока не показывается")
  t.eq(#env.memory.adds, adds + 2, "запись и ответ легли в память")
  t.ok(not env.ctrl.seal_open)
  t.ok(logged(env, "riddle: answer dropped, seal changed"), table.concat(env.logs, "\n"))
end

-- срок вышел посреди разбора ответа (секунда пересечена после первой проверки в finish): ответ не показывается
function T.test_finish_close_inside_parse_dropped()
  local env = make({ seal = { key = true, minutes = 30 } })
  env:unlock()
  env.now_value = 1000 + 1795
  env:say("мои дела", "СЕКРЕТ")
  local job = env.ctrl:begin(PNG)
  local absorb = env.ctrl.deps.absorb
  env.ctrl.deps.absorb = function(payload)
    env.now_value = 1000 + 1800 -- разбор пересёк срок
    return absorb(payload)
  end
  env.now_value = 1000 + 1799
  t.eq(env.ctrl:finish(job, job.run()), nil, "ответ после срока не показывается")
  t.ok(not env.ctrl.seal_open)
end

-- ревью Task 7: печать, простоявшая срок, закрыта для любого читателя — аксессор seal_open (роза, карта виджета)
-- видит её закрытой без страницы и без таймера
function T.test_seal_open_sees_idle()
  local env = make({ seal = { key = true, minutes = 30 } })
  env:unlock()
  env.now_value = 1000 + 3600
  t.ok(not env.ctrl.seal_open, "после простоя закрыта")
  t.ok(logged(env, "riddle: seal closed by idle"), table.concat(env.logs, "\n"))
end

-- ключ после простоя открывает печать (её закрыл простой), а не закрывает: владельцу не рисовать ключ второй раз
function T.test_key_after_idle_opens()
  local env = keyed({ seal = { key = true, minutes = 30 } })
  env.ctrl:key_page(O.owner_03)
  t.ok(env.ctrl.seal_open)
  env.now_value = 1000 + 3600
  local text = env.ctrl:key_page(O.owner_04)
  t.ok(in_list(texts.welcomes, text), "ключ открыл печать приветствием: " .. tostring(text))
  t.ok(env.ctrl.seal_open)
end

-- ответ открытой печати пришёл после срока, а таймер не успел (разбор ответа сам видит простой): не показывается
function T.test_answer_after_deadline_dropped_without_timer()
  local env = make({ seal = { key = true, minutes = 30 } })
  env:unlock()
  env.now_value = 1000 + 1790
  env:say("мои дела", "СЕКРЕТ")
  local job = env.ctrl:begin(PNG)
  t.ok(job and not job.closed, "запрос собран при открытой печати")
  env.now_value = 1000 + 1830
  t.eq(env.ctrl:finish(job, job.run()), nil, "ответ после срока не показывается")
  t.ok(not env.ctrl.seal_open)
end

function T.test_session_continues_after_sleep()
  local env = make({ now = 0, seal = { key = true, on_sleep = true } })
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
  env:unlock() -- хвост — данные: идёт при открытой печати
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
  env:unlock() -- хвост — данные: идёт при открытой печати
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
  env:unlock() -- хвост — данные: идёт при открытой печати
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
  env:unlock() -- хвост — данные: идёт при открытой печати
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

-- ревью Task 7: истёкший простой видят все читатели печати, а не только начало страницы. Хвост после простоя (виджет
-- открыт заново, таймера не было) — ни лора, ни памяти модели
function T.test_followup_after_idle_sends_no_memory()
  local env = make({ now = 0, seal = { key = true, minutes = 30 } })
  env:unlock()
  local m = past_session(env) -- now = 5 ч: простой давно истёк
  env.files[LORE] = "## Мир\nЛОР-ТЕКСТ"
  env.mtimes[LORE] = 777
  local job = env.ctrl:begin_followup()
  if job then
    env.script = { { text = "пересказ" } }
    job.run()
  end
  for _, call in ipairs(env.llm_calls) do
    t.ok(not has(json.encode(call.messages), "ЗАПИСЬ-ПРОШЛОЙ"), "память ушла модели после простоя")
  end
  t.eq(#m.imported, 0, "лор не читан")
  t.ok(not env.ctrl.seal_open, "печать закрыта")
end

-- таймаут, отмена, ошибка модели, исключение — пересказ не сохраняется (повторится в следующий раз)
function T.test_followup_async_failure_not_saved()
  for _, case in ipairs({ { nil, "timeout" }, { nil, "cancelled" }, { { err = "budget" } }, { { result = { text = "" } } } }) do
    local env = make({ now = 0 })
    env:unlock() -- хвост — данные: идёт при открытой печати
    local m = past_session(env)
    local job = env.ctrl:begin_followup()
    t.ok(job, "задача есть")
    env.ctrl:finish_followup(job, case[1], case[2])
    t.eq(#m.set_summaries, 0, "не сохранён: " .. tostring(case[2]))
    t.ok(env.ctrl:begin_followup(), "пересказ повторится")
  end
  local env = make({ now = 0 })
  env:unlock() -- хвост — данные: идёт при открытой печати
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
  env:unlock() -- хвост — данные: идёт при открытой печати
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
  env:unlock() -- хвост — данные: идёт при открытой печати
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

function T.test_begin_finish_equals_on_page_closed()
  local a, b = both_ways(function() end,
    { { "кто ты", "отказ 1" }, { "?", "" }, { "кто ты", "" } })
  t.ok(a.adds:find("отказ 1", 1, true), a.adds)
  t.eq(a.open, false)
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
  t.ok(job and job.mode == "open" and job.closed and type(job.run) == "function", "job закрытой печати")
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
  local env = make({ seal = false })
  env:say("привет", "здравствуй")
  env:page()
  local s = system_of(env.llm_calls[1])
  t.ok(not has(s, "печат") and not has(s, "Печат"), "без печати модель не слышит о печати")
end

-- открытая печать — промпт как без печати: правило закрытой ушло, «печать снята» больше не говорится (spec §7)
function T.test_unlocked_prompt_is_silent_about_seal()
  local env = make()
  env:unlock()
  env:say("привет", "здравствуй")
  env:page()
  local s = system_of(env.llm_calls[#env.llm_calls])
  t.ok(not has(s, "печат") and not has(s, "Печат"), "открытая печать модели не называется")
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

function T.test_begin_closed_has_no_knowledge()
  local calls = { n = 0 }
  local env = make({ knowledge_text = knowledge_dep(calls, "ЗНАНИЕ-МАРКЕР", "small") })
  local job = env.ctrl:begin(PNG)
  t.ok(job.mode == "open" and job.closed, "запрос закрытой печати")
  t.eq(calls.n, 0, "закрытая печать знание не читает")
  t.ok(not has(json.encode(job.messages), "ЗНАНИЕ-МАРКЕР"), "знания нет в закрытой печати")
  env:say("кто ты", "Молчу.")
  env:page()
  t.ok(is_closed_call(env.llm_calls[1]), "закрытый промпт без знания")
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
