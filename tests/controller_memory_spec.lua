require("sqlite_shim")
local t = require("t")
local stand = require("seal_stand")
local json = require("dkjson")
local memory = require("riddle.memory")
local controller = require("riddle.controller")

local H = 3600
local PNG = "/p.png"
local LORE = "/lore.md"
-- строка конфига Kindle владельца: без неё дневник спрашивает «Чей это дневник?» (задача 8) — здесь нужны «Методы»
local WHOSE = "Том Реддл из «Методов рационального мышления»"

local T = {}

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

-- база дневника после ивента 2026-10-23/24 (схема до 2026-10-24): таблица quest с ходом игры
local OLD_EVENT_DB = [[
CREATE TABLE sessions(id INTEGER PRIMARY KEY, started INT, last_ts INT, summary TEXT);
CREATE TABLE entries(id INTEGER PRIMARY KEY, session_id INT, ts INT, role TEXT, text TEXT);
CREATE INDEX entries_session ON entries(session_id, ts, id);
CREATE TABLE lore(section TEXT PRIMARY KEY, text TEXT, mtime INT);
CREATE TABLE quest(key TEXT PRIMARY KEY, value INT);
INSERT INTO sessions VALUES(1, 0, 100, NULL);
INSERT INTO entries VALUES(1, 1, 50, 'legacy', 'СТАРАЯ-ЗАПИСЬ');
INSERT INTO entries VALUES(2, 1, 60, 'diary', 'СТАРЫЙ-ОТВЕТ');
INSERT INTO quest VALUES('world1', 3), ('world5', 2), ('final_given', 0), ('last', 5);
]]

-- контроллер на настоящей SQLite-памяти, LLM — по сценарию; path — готовая база (иначе новая)
local function make(path)
  path = path or os.tmpname()
  local env = { path = path, now = 0, script = {}, calls = {}, files = { [PNG] = "PNGBYTES" }, mtimes = {} }
  env.mem = memory.open(path)
  env.ctrl = controller.new({
    -- печать по ключу, сон её закрывает
    cfg = { whose = WHOSE, seal = stand.rules({ key = true, on_sleep = true }) },
    memory = env.mem,
    llm_call = function(messages, want_json)
      env.calls[#env.calls + 1] = { messages = messages, want_json = want_json }
      return table.remove(env.script, 1)
    end,
    read_file = function(p) return env.files[p] end,
    b64 = function(b) return "B64" end,
    remove = function() end,
    now = function() return env.now end,
    lore_path = LORE,
    file_mtime = function(p) return env.mtimes[p] end,
    random = function() return 1 end,
  })
  function env:say(read, reply) self.script[#self.script + 1] = { read = read, reply = reply } end
  function env:close() self.mem:close(); os.remove(self.path) end
  return env
end

function T.test_full_evening()
  local env = make()
  env.files[LORE] = "## Мир\nЛОР-МАРКЕР"
  env.mtimes[LORE] = 5

  -- вечер 1: печать снята, две реплики
  env.ctrl:seal_toggle()
  env.ctrl:on_unlocked_followup()
  env.now = 60
  env:say("Мне грустно", "Я с тобой")
  t.eq(env.ctrl:on_page(PNG), "Я с тобой")
  env.now = 120
  env:say("Расскажи про сад", "Там пахнет мятой…")
  env.ctrl:on_page(PNG)
  local s = json.encode(env.calls[#env.calls].messages)
  t.ok(has(s, "ЛОР-МАРКЕР"), "лор из файла дошёл до промпта")
  t.ok(has(s, "Мне грустно"), "память сессии в промпте")

  -- сон, возвращение через 5 ч: новая сессия, пересказ прошлой
  env.ctrl:on_sleep()
  env.now = 5 * H + 120
  env.ctrl:seal_toggle()
  env.script = { { text = "ПЕРЕСКАЗ-ВЕЧЕРА" } }
  env.ctrl:on_unlocked_followup()
  local sum_call = env.calls[#env.calls]
  t.eq(sum_call.want_json, false)
  t.ok(has(json.encode(sum_call.messages), "Мне грустно"), "в пересказ ушли реплики")
  t.eq(env.mem:summaries(5)[1], "ПЕРЕСКАЗ-ВЕЧЕРА")

  env:say("Я вернулась", "Рада тебе")
  env.ctrl:on_page(PNG)
  t.ok(has(json.encode(env.calls[#env.calls].messages), "ПЕРЕСКАЗ-ВЕЧЕРА"), "пересказ — долгая память")
  env:close()
end

-- на старой базе ивента дневник открывается и разговаривает: печать, ответ, запись, пересказ
function T.test_old_event_db_diary_opens()
  local path = os.tmpname()
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec(OLD_EVENT_DB)
  conn:close()
  local env = make(path)
  env.now = 10
  env.ctrl:seal_toggle()
  t.ok(env.ctrl.seal_open, "печать снята")
  env:say("Сезам", "Ответ дневника")
  t.eq(env.ctrl:on_page(PNG), "Ответ дневника", "бывшее слово ключа — обычная запись")
  local s = json.encode(env.calls[#env.calls].messages)
  t.ok(has(s, "СТАРАЯ-ЗАПИСЬ"), "старая реплика в разговоре")
  local e = env.mem:entries(1)
  t.eq(e[#e - 1].role, "owner"); t.eq(e[#e - 1].text, "Сезам")
  t.eq(e[1].role, "owner", "старая реплика пишущего переименована")
  env:close()
end

-- метка задачи у записи: контекст задач приходит четвёртым значением knowledge_text -----------------------
local tasks = require("riddle.tasks")

-- печати нет (дневник открыт сразу); tctx — контекст задач (как app.tasks_context) или nil; extra — зависимости
-- поверх (knowledge_text, set_tasks_source)
local function make_open(tctx, path, extra)
  local env = { now = 0, script = {}, calls = {}, logs = {}, path = path or os.tmpname() }
  env.mem = memory.open(env.path)
  env.ctrl = controller.new({
    cfg = { whose = WHOSE, seal = stand.none() },
    memory = env.mem,
    llm_call = function(messages, want_json)
      env.calls[#env.calls + 1] = { messages = messages, want_json = want_json }
      return table.remove(env.script, 1)
    end,
    read_file = function() return "PNGBYTES" end,
    b64 = function() return "B64" end,
    remove = function() end,
    now = function() return env.now end,
    lore_path = LORE,
    file_mtime = function() return nil end,
    random = function() return 1 end,
    log = function(msg) env.logs[#env.logs + 1] = msg end,
    knowledge_text = function() return nil, nil, nil, tctx end,
  })
  for k, v in pairs(extra or {}) do env.ctrl.deps[k] = v end
  function env:answer(result)
    self.script[#self.script + 1] = result
    self.logs = {}
    return self.ctrl:on_page(PNG)
  end
  function env:owner_task()
    local sid = self.mem:session(self.now)
    local marks = self.mem:marks(sid)
    for i = #marks, 1, -1 do
      if marks[i].role == "owner" then return marks[i].task, marks end
    end
  end
  function env:logged(needle)
    for _, l in ipairs(self.logs) do if has(l, needle) then return l end end
  end
  function env:close() self.mem:close(); os.remove(self.path) end
  return env
end

local function ctx_with_block()
  local open = { { id = "pg-aaa", title = "Купить хлеб" }, { id = "pg-bbb", title = "Позвонить в банк" } }
  return { collection = { id = "c1", title = "Дела" }, why = "depth", open = open, block = tasks.block(open),
    collections = { { id = "c1", title = "Дела" } }, titles = { "Дела" } }
end

function T.test_task_label_maps_to_id_on_owner_entry()
  local env = make_open(ctx_with_block())
  t.eq(env:answer({ read = "Банк опять", reply = "Звони.", task = "t2" }), "Звони.")
  local task, marks = env:owner_task()
  t.eq(task, "pg-bbb", "метка t2 → id второй задачи")
  t.eq(#marks, 2)
  t.eq(marks[2].role, "diary"); t.eq(marks[2].task, nil, "у ответа дневника метки задачи нет")
  t.ok(env:logged("riddle: entry task=yes"), table.concat(env.logs, "\n"))
  t.ok(has(env.calls[1].messages[1].content, "[t2] Позвонить в банк"), "блок дошёл до промпта")
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "pg-bbb") and not has(l, "Позвонить") and not has(l, "Банк опять"), "в логе: " .. l)
  end
  env:close()
end

function T.test_empty_task_is_none()
  local env = make_open(ctx_with_block())
  env:answer({ read = "Погода", reply = "Дождь.", task = "" })
  t.eq(env:owner_task(), "", "ни к какой задаче")
  t.ok(env:logged("riddle: entry task=none"), table.concat(env.logs, "\n"))
  env:close()
end

function T.test_bad_task_label_is_unknown()
  local env = make_open(ctx_with_block())
  for _, bad in ipairs({ "t99", "Купить хлеб", "pg-aaa" }) do
    env:answer({ read = "Запись " .. bad, reply = "Ответ.", task = bad })
    t.eq(env:owner_task(), nil, bad .. " — неизвестно")
    t.ok(env:logged("riddle: entry task=unknown"), bad .. ": " .. table.concat(env.logs, "\n"))
  end
  -- поля нет (запасной провайдер) — тоже неизвестно
  env:answer({ read = "Без поля", reply = "Ответ." })
  t.eq(env:owner_task(), nil, "без поля — неизвестно")
  t.ok(env:logged("riddle: entry task=unknown"), table.concat(env.logs, "\n"))
  env:close()
end

-- книга выбрана, но незакрытых нет (или книги нет): запись не может касаться дела — "" без оглядки на ответ
function T.test_no_block_marks_owner_none()
  local ctx = ctx_with_block()
  ctx.block = nil
  local env = make_open(ctx)
  env:answer({ read = "Привет", reply = "Здравствуй." })
  t.eq(env:owner_task(), "", "без поля — всё равно ни к какой")
  t.ok(env:logged("riddle: entry task=none"), table.concat(env.logs, "\n"))
  env:answer({ read = "Ещё", reply = "Да.", task = "t1" })
  t.eq(env:owner_task(), "", "метка без блока не значит ничего")
  local s = env.calls[1].messages[1].content
  t.ok(not has(s, require("riddle.prompt").TASKS_HEAD), "раздела задач нет")
  env:close()
end

-- миграция 3 сорвалась (колонок меток нет): ответ идёт, лог говорит, что метка не легла; сохранилась — флага нет
function T.test_entry_log_flags_unsaved_mark()
  local path = os.tmpname()
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec([[
CREATE TABLE sessions(id INTEGER PRIMARY KEY, started INT, last_ts INT, summary TEXT);
CREATE TABLE entries(id INTEGER PRIMARY KEY, session_id INT, ts INT, role TEXT, text TEXT, offer TEXT);
CREATE TABLE lore(section TEXT PRIMARY KEY, text TEXT, mtime INT);
PRAGMA user_version = 2;
]])
  conn:close()
  local env = make_open(ctx_with_block(), path)
  t.eq(env:answer({ read = "Банк", reply = "Звони.", task = "t2" }), "Звони.", "ответ на экране")
  t.ok(env:logged("riddle: entry task=yes saved=no"), table.concat(env.logs, "\n"))
  local e = env.mem:entries(env.mem:session(env.now))
  t.eq(#e, 2, "реплики записаны без меток")
  env:close()
  local ok_env = make_open(ctx_with_block())
  ok_env:answer({ read = "Банк", reply = "Звони.", task = "t2" })
  local l = ok_env:logged("riddle: entry task=yes")
  t.eq(l, "riddle: entry task=yes", "метка легла — без флага")
  ok_env:close()
end

function T.test_no_tasks_context_keeps_old_behaviour()
  local env = make_open(nil)
  t.eq(env:answer({ read = "Привет", reply = "Здравствуй.", task = "t1" }), "Здравствуй.")
  t.eq(env:owner_task(), nil, "как раньше: метки нет")
  t.ok(not env:logged("entry task="), "строки метки нет")
  local e = env.mem:entries(env.mem:session(env.now))
  t.eq(#e, 2); t.eq(e[1].text, "Привет"); t.eq(e[2].text, "Здравствуй.")
  t.ok(not has(env.calls[1].messages[1].content, require("riddle.prompt").TASKS_HEAD), "без раздела задач")
  env:close()
end

-- ритм: режим считается из меток сессии, строка режима — в последнем user, предложение — у реплики diary ----
local prompt = require("riddle.prompt")

local function ctx_with_tasks(n)
  local open = {}
  for i = 1, n do open[i] = { id = "pg-" .. i, title = "Дело номер " .. i } end
  return { collection = { id = "c1", title = "Дела" }, why = "depth", open = open, block = tasks.block(open),
    collections = { { id = "c1", title = "Дела" }, { id = "c2", title = "Фильмы" } }, titles = { "Дела", "Фильмы" } }
end

local function ctx_without_tasks()
  return { why = "none", collections = { { id = "c2", title = "Фильмы" }, { id = "c3", title = "Рецепты" } },
    titles = { "Фильмы", "Рецепты" } }
end

-- текст последнего user-сообщения последнего вызова модели
local function user_text(env)
  local m = env.calls[#env.calls].messages
  for _, part in ipairs(m[#m].content) do
    if part.type == "text" then return part.text end
  end
end

-- предложение у последней реплики diary
local function last_offer(env)
  local marks = env.mem:marks(env.mem:session(env.now))
  for i = #marks, 1, -1 do
    if marks[i].role == "diary" then return marks[i].offer end
  end
end

function T.test_first_answer_marks_offer_ids()
  local env = make_open(ctx_with_tasks(5))
  env:answer({ read = "Привет", reply = "Здравствуй.", task = "" })
  t.eq(last_offer(env), "pg-1 pg-2 pg-3", "первая запись — 1–3 дела, id через пробел")
  local u = user_text(env)
  t.ok(has(u, prompt.MODE_NOTE), "строка режима в user: " .. u)
  t.ok(has(u, "Дело номер 1") and has(u, "Дело номер 3") and not has(u, "Дело номер 4"), u)
  t.ok(not has(u, "[t1]"), "без меток: " .. u)
  t.ok(not has(u, prompt.MODE_IF), "первая запись — безусловно")
  t.ok(env:logged("riddle: rhythm mode=name n=1"), table.concat(env.logs, "\n"))
  -- вторая запись: предложение было, счёт с нуля — режима нет, system тот же
  env:answer({ read = "Ещё", reply = "Да.", task = "" })
  t.ok(not has(user_text(env), prompt.MODE_NOTE), "вторая — без строки режима")
  t.eq(last_offer(env), nil)
  t.ok(env:logged("riddle: rhythm mode=none n=1"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "pg-") and not has(l, "Дело"), "в логе: " .. l)
  end
  env:close()
end

-- 4-я запись — 3-я без задачи после предложения: намёк, предложения нет; 7-я — 6-я: другие дела, но только
-- если запись не о задаче
function T.test_conditional_offer_marked_only_if_task_empty()
  for _, case in ipairs({ { task = "t1", offer = nil }, { task = "", offer = "pg-4 pg-5" },
    { task = nil, offer = nil }, { task = "ask", offer = nil } }) do
    local env = make_open(ctx_with_tasks(5))
    env:answer({ read = "Привет", reply = "Здравствуй.", task = "" })
    for i = 2, 6 do
      env:answer({ read = "Запись " .. i, reply = "Ответ.", task = "" })
      if i == 4 then
        -- строка режима — только в user: system тот же, что у 3-й записи без режима (кэш провайдера)
        t.eq(env.calls[4].messages[1].content, env.calls[3].messages[1].content, "system не меняется")
        t.ok(env:logged("riddle: rhythm mode=drift n=3"), table.concat(env.logs, "\n"))
        local u = user_text(env)
        t.ok(has(u, prompt.MODE_DRIFT) and has(u, prompt.MODE_IF), "намёк с условием: " .. u)
        t.eq(last_offer(env), nil, "намёк — не предложение")
      end
    end
    env:answer({ read = "Запись 7", reply = "Ответ.", task = case.task })
    t.ok(env:logged("riddle: rhythm mode=name n=6"), table.concat(env.logs, "\n"))
    local u = user_text(env)
    t.ok(has(u, prompt.MODE_IF) and has(u, "Дело номер 4") and has(u, "Дело номер 5")
      and not has(u, "Дело номер 1"), "другие дела с условием: " .. u)
    t.eq(last_offer(env), case.offer, "task=" .. tostring(case.task))
    env:close()
  end
end

-- запись о делах вообще ("task":"all") — о делах, как запись об одном деле: метка "all", счёт с нуля, предложения
-- при условном режиме нет. Живой прогон 2026-10-26: «мои дела в …», «что мне сегодня сделать?» шли как "" и
-- выводили на намёк «ушли в сторону» ровно на вопросе о делах
function T.test_entry_about_tasks_in_general_resets_count()
  local env = make_open(ctx_with_tasks(5))
  env:answer({ read = "Привет", reply = "Здравствуй.", task = "" })
  env:answer({ read = "Фильмы", reply = "Ответ.", task = "" })
  env:answer({ read = "Что мне сделать?", reply = "Дело номер 1.", task = "all" })
  t.eq(env:owner_task(), "all", "метка — о делах вообще")
  t.ok(env:logged("riddle: entry task=all"), table.concat(env.logs, "\n"))
  for i = 4, 6 do
    env:answer({ read = "Запись " .. i, reply = "Ответ.", task = "" })
    local want = i == 6 and "drift" or "none"
    t.ok(env:logged("riddle: rhythm mode=" .. want .. " n=" .. (i - 3)), i .. ": " .. table.concat(env.logs, "\n"))
  end
  for _, l in ipairs(env.logs) do t.ok(not has(l, "Что мне"), "в логе: " .. l) end
  env:close()
  -- без блока задач "all" — как любая метка: запись не может касаться дел, которых нет
  local ctx = ctx_with_block()
  ctx.block = nil
  local nb = make_open(ctx)
  nb:answer({ read = "Что мне сделать?", reply = "Ничего.", task = "all" })
  t.eq(nb:owner_task(), "", "без блока — ни к какой")
  nb:close()
end

-- прямой вопрос не о делах ("task":"ask") — ответ только на него (владелец 2026-10-26, 812f): предложение не
-- пишется, напоминание переходит на следующую запись, что не вопрос. Живой прогон 2026-10-26: «какие фильмы мне
-- понравятся» первой записью — ответ о делах вместо фильмов
function T.test_direct_question_defers_first_reminder()
  local env = make_open(ctx_with_tasks(5))
  env:answer({ read = "Какие фильмы?", reply = "Такие.", task = "ask" })
  t.eq(env:owner_task(), "ask", "метка — вопрос")
  t.ok(env:logged("riddle: entry task=ask"), table.concat(env.logs, "\n"))
  t.ok(env:logged("riddle: rhythm mode=name n=1"), table.concat(env.logs, "\n"))
  t.ok(has(user_text(env), prompt.MODE_ASK_IF), "условие «не вопрос»: " .. user_text(env))
  t.eq(last_offer(env), nil, "на вопрос — без предложения")
  env:answer({ read = "Ещё вопрос?", reply = "Да.", task = "ask" })
  t.eq(last_offer(env), nil, "и на второй")
  env:answer({ read = "Устал", reply = "Отдохни.", task = "" })
  t.ok(env:logged("riddle: rhythm mode=name n=1"), "напоминание перенесено: " .. table.concat(env.logs, "\n"))
  t.eq(last_offer(env), "pg-1 pg-2 pg-3", "легло на запись не-вопрос")
  env:answer({ read = "Дальше", reply = "Да.", task = "" })
  t.ok(env:logged("riddle: rhythm mode=none n=1"), "дальше — обычный счёт: " .. table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do t.ok(not has(l, "фильм"), "в логе: " .. l) end
  env:close()
end

-- намёк на 3-й без задачи: пришёлся на вопрос — переходит на следующую запись
function T.test_direct_question_defers_drift()
  local env = make_open(ctx_with_tasks(5))
  env:answer({ read = "Привет", reply = "Здравствуй.", task = "" })
  env:answer({ read = "Запись 2", reply = "Ответ.", task = "" })
  env:answer({ read = "Запись 3", reply = "Ответ.", task = "" })
  env:answer({ read = "Вопрос?", reply = "Ответ.", task = "ask" })
  t.ok(env:logged("riddle: rhythm mode=drift n=3"), table.concat(env.logs, "\n"))
  env:answer({ read = "Запись 5", reply = "Ответ.", task = "" })
  t.ok(env:logged("riddle: rhythm mode=drift n=3"), "намёк перенесён: " .. table.concat(env.logs, "\n"))
  env:close()
end

-- после паузы от часа — снова дела (владелец 2026-10-26, 812e): та же сессия, следующие 1–3 дела
function T.test_first_entry_after_pause_names_next_tasks()
  local env = make_open(ctx_with_tasks(5))
  env:answer({ read = "Привет", reply = "Здравствуй.", task = "" })
  local sid = env.mem:session(env.now)
  env.now = 60
  env:answer({ read = "Ещё", reply = "Да.", task = "" })
  t.ok(env:logged("riddle: rhythm mode=none n=1"), table.concat(env.logs, "\n"))
  env.now = 60 + 3600
  env:answer({ read = "Вернулся", reply = "Ну что ж.", task = "" })
  t.ok(env:logged("riddle: rhythm mode=name n=1"), "после паузы: " .. table.concat(env.logs, "\n"))
  t.ok(not has(user_text(env), prompt.MODE_IF), "безусловно, как первая")
  t.eq(last_offer(env), "pg-4 pg-5", "следующие дела")
  t.eq(env.mem:session(env.now), sid, "сессия та же")
  env:close()
end

-- дела из строки напоминания доходят до prompt.fit меткой: урезанный запрос (провайдер с лимитом) их не теряет
-- (ревью decfb2d). После паузы напоминание называет дела 4–5 — хвост блока
function T.test_fit_keeps_tasks_from_mode_line()
  local env = make_open(ctx_with_tasks(5))
  env:answer({ read = "Привет", reply = "Здравствуй.", task = "" })
  env.now = 3600
  env:answer({ read = "Вернулся", reply = "Ну что ж.", task = "" })
  t.eq(last_offer(env), "pg-4 pg-5", "напоминание — о хвосте блока")
  local m = env.calls[#env.calls].messages
  local f = prompt.fit(m, 1)
  local s = f[1].content
  t.ok(has(s, "[t4] Дело номер 4") and has(s, "[t5] Дело номер 5"), "названные — в блоке: " .. s)
  t.ok(not has(s, "[t1] ") and not has(s, "[t3] "), "остальные срезаны")
  env:close()
end

-- первая запись — безусловно: предложение пишется, даже если запись о задаче или «неизвестно»
function T.test_first_offer_marked_even_if_entry_about_task()
  for _, task in ipairs({ "t2", false }) do
    local env = make_open(ctx_with_tasks(5))
    env:answer({ read = "Привет", reply = "Здравствуй.", task = task or nil })
    t.eq(last_offer(env), "pg-1 pg-2 pg-3", "task=" .. tostring(task))
    t.eq(env:owner_task(), task and "pg-2" or nil)
    env:close()
  end
end

function T.test_themes_offer_marked()
  local env = make_open(ctx_without_tasks())
  env:answer({ read = "Привет", reply = "Здравствуй." })
  t.eq(last_offer(env), "themes")
  local u = user_text(env)
  t.ok(has(u, prompt.MODE_NOTE) and has(u, "Фильмы") and has(u, "Рецепты"), u)
  t.ok(env:logged("riddle: rhythm mode=themes n=1"), table.concat(env.logs, "\n"))
  env:close()
end

-- задач нет, темы есть, ответы без поля task: темы на 1-й и на 6-й без задачи после неё (7-й)
function T.test_without_tasks_themes_first_and_sixth()
  local env = make_open(ctx_without_tasks())
  for i = 1, 7 do
    env:answer({ read = "Запись " .. i, reply = "Ответ " .. i .. "." })
    t.eq(env:owner_task(), "", i .. ": запись ни к какой задаче")
    local want = (i == 1 or i == 7) and "themes" or "none"
    t.ok(env:logged("riddle: rhythm mode=" .. want .. " "), i .. ": " .. table.concat(env.logs, "\n"))
    t.eq(last_offer(env), want == "themes" and "themes" or nil, i .. ": предложение")
    t.eq(has(user_text(env), prompt.MODE_NOTE), want == "themes", i .. ": строка режима")
  end
  env:close()
end

-- миграция 3 не прошла (меток нет): ритм выключен, а не «первая запись» на каждом ответе
function T.test_rhythm_off_without_marks()
  local path = os.tmpname()
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec([[
CREATE TABLE sessions(id INTEGER PRIMARY KEY, started INT, last_ts INT, summary TEXT);
CREATE TABLE entries(id INTEGER PRIMARY KEY, session_id INT, ts INT, role TEXT, text TEXT, offer TEXT);
CREATE TABLE lore(section TEXT PRIMARY KEY, text TEXT, mtime INT);
PRAGMA user_version = 2;
]])
  conn:close()
  local env = make_open(ctx_with_tasks(3), path)
  t.eq(env.mem:marks(env.mem:session(env.now)), nil, "меток нет")
  for i = 1, 2 do
    t.eq(env:answer({ read = "Запись " .. i, reply = "Ответ.", task = "" }), "Ответ.", "ответ есть")
    t.ok(not has(user_text(env), prompt.MODE_NOTE), "строки режима нет")
    t.ok(env:logged("riddle: rhythm mode=none n=-"), table.concat(env.logs, "\n"))
  end
  local e = env.mem:entries(env.mem:session(env.now))
  t.eq(#e, 4, "реплики записаны")
  env:close()
end

-- слово пользователя о книге дел (поле tasks_source): выбор — в core базы знаний, контекст задач — app ---------
local app = require("riddle.app")
local texts = require("riddle.texts")
local persona = require("riddle.persona")
local knowledge = require("riddle.knowledge")

-- c1 «ДЕЛА-ДОМА» (кандидат, выбирается сам), c2 «ПОКУПКИ НА НЕДЕЛЮ», c3 «ПОКУПКИ В ДОМ» (кандидаты глубже),
-- c4 «ФИЛЬМЫ» — не кандидат
local function word_db()
  local path = os.tmpname()
  local K = knowledge.open(path)
  K:put_snapshot("notion", {
    { id = "c1", title = "ДЕЛА-ДОМА", items = 1, task_candidate = true, depth = 1 },
    { id = "c2", title = "ПОКУПКИ НА НЕДЕЛЮ", items = 1, task_candidate = true, depth = 2 },
    { id = "c3", title = "ПОКУПКИ В ДОМ", items = 1, task_candidate = true, depth = 3 },
    { id = "c4", title = "ФИЛЬМЫ", items = 1, depth = 1 },
  }, {
    { id = "k1", collection_id = "c1", title = "ДЕЛО-ПЕРВОЙ-КНИГИ", open = true, archived = false },
    { id = "k2", collection_id = "c2", title = "ДЕЛО-ВТОРОЙ-КНИГИ", open = true, archived = false },
    { id = "k3", collection_id = "c3", title = "ДЕЛО-ТРЕТЬЕЙ-КНИГИ", open = true, archived = false },
  })
  K:close()
  return path
end

local function core_of(path)
  local K = knowledge.open(path)
  local v = K:core("tasks_source")
  K:close()
  return v
end

-- дневник, у которого контекст задач и слово о книге идут через app (как на устройстве); set — подмена записи
local function make_word(kpath, set)
  local env
  local d = { cfg = { notion_token = "secret_notion_TOKEN1", whose = WHOSE }, knowledge_path = kpath,
    log = function(msg) env.logs[#env.logs + 1] = msg end }
  env = make_open(nil, nil, { knowledge_text = app.knowledge_text(d), set_tasks_source = set or app.set_tasks_source(d) })
  env.kpath = kpath
  -- в логе — ни названий книг и дел, ни слов записи
  function env:clean_logs()
    for _, l in ipairs(self.logs) do
      for _, secret in ipairs({ "ДЕЛА-ДОМА", "ПОКУПКИ", "ФИЛЬМЫ", "ДЕЛО-", "покупк", "фильм", "Мои дела", "secret_" }) do
        t.ok(not has(l, secret), "в логе «" .. secret .. "»: " .. l)
      end
    end
  end
  local close = env.close
  function env:close() close(self); os.remove(self.kpath) end
  return env
end

local function in_pool(s, pool)
  for _, x in ipairs(pool) do if x == s then return true end end
  return false
end

function T.test_word_sets_source_and_next_answer_uses_it()
  local env = make_word(word_db())
  t.eq(env:answer({ read = "Мои дела — в покупках на неделю", reply = "Запомню.", tasks_source = "покупки на неделю" }),
    "Запомню.", "ответ модели на экране")
  t.ok(has(env.calls[1].messages[1].content, prompt.TITLES_HEAD), "названия книг в промпте")
  t.ok(has(env.calls[1].messages[1].content, "ДЕЛО-ПЕРВОЙ-КНИГИ"), "до слова — книга, выбранная сама")
  t.ok(env:logged("riddle: tasks source set"), table.concat(env.logs, "\n"))
  t.eq(core_of(env.kpath), "c2", "выбор в core")
  env:clean_logs()
  -- без синхронизации: следующий ответ — уже по выбранной книге
  env:answer({ read = "Что у меня там", reply = "Посмотрим." })
  t.ok(env:logged("via=user"), table.concat(env.logs, "\n"))
  local s = env.calls[2].messages[1].content
  t.ok(has(s, "ДЕЛО-ВТОРОЙ-КНИГИ") and not has(s, "ДЕЛО-ПЕРВОЙ-КНИГИ"), "блок второй книги")
  t.ok(not env:logged("tasks source"), "нет поля — выбор не трогается")
  env:clean_logs()
  env:close()
end

function T.test_repeat_word_overwrites()
  local env = make_word(word_db())
  env:answer({ read = "Дела в покупках", reply = "Да.", tasks_source = "ПОКУПКИ НА НЕДЕЛЮ" })
  t.eq(core_of(env.kpath), "c2")
  env:answer({ read = "Нет, дела дома", reply = "Да.", tasks_source = "Дела-дома" })
  t.eq(core_of(env.kpath), "c1", "второе слово перезаписало первое")
  t.ok(env:logged("riddle: tasks source set"), table.concat(env.logs, "\n"))
  env:answer({ read = "Ну", reply = "Да." })
  t.ok(env:logged("via=user"), table.concat(env.logs, "\n"))
  env:clean_logs()
  env:close()
end

-- "" — в записи ни слова о книге дел (ключ теперь всегда в ответе), "-" — так модели тоже пишут «пусто»: выбор и лог
-- не трогаются; сброс — только явное "reset"
function T.test_empty_word_keeps_choice_reset_clears()
  local env = make_word(word_db())
  env:answer({ read = "Дела в покупках", reply = "Да.", tasks_source = "покупки на неделю" })
  t.eq(core_of(env.kpath), "c2")
  env.logs = {}
  for _, v in ipairs({ "", "-" }) do
    t.eq(env:answer({ read = "Какая погода", reply = "Сухо.", tasks_source = v }), "Сухо.", "«" .. v .. "»: ответ модели")
    t.eq(core_of(env.kpath), "c2", "«" .. v .. "»: выбор прежний")
    t.ok(not env:logged("tasks source"), "«" .. v .. "»: в логе ни слова о книге: " .. table.concat(env.logs, "\n"))
  end
  t.eq(env:answer({ read = "Найди сам", reply = "Найду.", tasks_source = "reset" }), "Найду.")
  t.eq(core_of(env.kpath), nil, "выбор стёрт")
  t.ok(env:logged("riddle: tasks source cleared"), table.concat(env.logs, "\n"))
  env:answer({ read = "Ну", reply = "Да." })
  t.ok(env:logged("via=depth"), table.concat(env.logs, "\n"))
  env:clean_logs()
  env:close()
end

-- "" без прежнего выбора: запись не вызывается вовсе
function T.test_empty_word_does_not_write()
  local tried = 0
  local env = make_word(word_db(), function() tried = tried + 1 return true end)
  t.eq(env:answer({ read = "Привет", reply = "Здравствуй.", task = "", tasks_source = "" }), "Здравствуй.")
  t.eq(tried, 0, "пусто — set не вызван")
  t.ok(not env:logged("tasks source"), table.concat(env.logs, "\n"))
  env:close()
end

-- книги «Интернет-покупки / Фильмы / Мои задачи» (ревью: tasks_source теперь в каждом ответе, мусор модели не должен
-- ни выбирать книгу подстрокой, ни вызывать переспрос)
local function shop_db()
  local path = os.tmpname()
  local K = knowledge.open(path)
  K:put_snapshot("notion", {
    { id = "c1", title = "Интернет-покупки", items = 1, task_candidate = true, depth = 1 },
    { id = "c2", title = "Фильмы", items = 1, depth = 1 },
    { id = "c3", title = "Мои задачи", items = 1, task_candidate = true, depth = 2 },
  }, {
    { id = "k1", collection_id = "c1", title = "ДЕЛО-ПЕРВОЙ-КНИГИ", open = true, archived = false },
    { id = "k3", collection_id = "c3", title = "ДЕЛО-ТРЕТЬЕЙ-КНИГИ", open = true, archived = false },
  })
  K:set_core("tasks_source", "c3")
  K:close()
  return path
end

-- prompt.fit мог срезать раздел названий книг целиком (decfb2d), ключ tasks_source в примере остался: выдуманное
-- моделью название ищется по коллекциям контекста, не по промпту, — книгу не выбирает и не переспрашивает
function T.test_made_up_title_keeps_choice()
  local env = make_word(shop_db())
  for _, v in ipairs({ "Выдуманная книга", "КНИГА-07", "Мои дела" }) do
    env.logs = {}
    t.eq(env:answer({ read = "Привет", reply = "Здравствуй.", tasks_source = v }), "Здравствуй.", "«" .. v .. "»: ответ модели")
    t.eq(core_of(env.kpath), "c3", "«" .. v .. "»: выбор прежний")
    for _, l in ipairs(env.logs) do
      t.ok(l ~= "riddle: tasks source set" and l ~= "riddle: tasks source cleared", "«" .. v .. "»: " .. l)
    end
  end
  env:close()
end

function T.test_model_junk_keeps_choice_without_asking()
  local env = make_word(shop_db())
  for _, v in ipairs({ "нет", "Нет", "none", "None", "null", "nil", "no", "n/a", "N/A", "—", "–", "-", "...", "?", "пусто" }) do
    env.logs = {}
    t.eq(env:answer({ read = "Привет", reply = "Здравствуй.", tasks_source = v }), "Здравствуй.", "«" .. v .. "»: ответ модели")
    t.eq(core_of(env.kpath), "c3", "«" .. v .. "»: выбор прежний")
    for _, l in ipairs(env.logs) do
      t.ok(l ~= "riddle: tasks source set" and l ~= "riddle: tasks source cleared", "«" .. v .. "»: " .. l)
    end
  end
  env:close()
end

-- книга «Нет времени» содержит целое слово «нет»: без NO_WORD match_word выбрала бы её по значению «нет» —
-- мусор модели меняет источник. Отдельно от shop_db: там «нет» подстрокой «Интернет-покупки», целого слова нет
local function no_time_db()
  local path = os.tmpname()
  local K = knowledge.open(path)
  K:put_snapshot("notion", {
    { id = "c1", title = "Нет времени", items = 1, task_candidate = true, depth = 1 },
    { id = "c3", title = "Мои задачи", items = 1, task_candidate = true, depth = 2 },
  }, {
    { id = "k1", collection_id = "c1", title = "ДЕЛО-ПЕРВОЙ-КНИГИ", open = true, archived = false },
    { id = "k3", collection_id = "c3", title = "ДЕЛО-ТРЕТЬЕЙ-КНИГИ", open = true, archived = false },
  })
  K:set_core("tasks_source", "c3")
  K:close()
  return path
end

function T.test_model_no_word_does_not_pick_book_with_that_word()
  local env = make_word(no_time_db())
  for _, v in ipairs({ "нет", "Нет", " НЕТ " }) do
    env.logs = {}
    t.eq(env:answer({ read = "Привет", reply = "Здравствуй.", tasks_source = v }), "Здравствуй.", "«" .. v .. "»: ответ модели, не переспрос")
    t.eq(core_of(env.kpath), "c3", "«" .. v .. "»: источник прежний")
    t.ok(not env:logged("tasks source"), "«" .. v .. "»: " .. table.concat(env.logs, "\n"))
  end
  env:close()
end

function T.test_model_reset_any_case_clears()
  for _, v in ipairs({ "reset", "Reset", "RESET", " reset " }) do
    local env = make_word(shop_db())
    t.eq(env:answer({ read = "Найди сам", reply = "Найду.", tasks_source = v }), "Найду.")
    t.eq(core_of(env.kpath), nil, "«" .. v .. "»: выбор стёрт")
    t.ok(env:logged("riddle: tasks source cleared"), v .. ": " .. table.concat(env.logs, "\n"))
    env:close()
  end
end

function T.test_model_title_from_list_any_case_sets()
  for _, case in ipairs({ { "Интернет-покупки", "c1" }, { "интернет-ПОКУПКИ", "c1" }, { "Фильмы", "c2" },
    { "  мои задачи ", "c3" }, { "МОИ ЗАДАЧИ", "c3" } }) do
    local kpath = shop_db()
    local K = knowledge.open(kpath)
    K:set_core("tasks_source", nil)
    K:close()
    local env = make_word(kpath)
    t.eq(env:answer({ read = "Дела там", reply = "Запомню.", tasks_source = case[1] }), "Запомню.", case[1])
    t.eq(core_of(kpath), case[2], case[1] .. ": книга выбрана")
    t.ok(env:logged("riddle: tasks source set"), case[1] .. ": " .. table.concat(env.logs, "\n"))
    env:close()
  end
end

-- «покупки» подходят к двум книгам — переспрос из пула; «сад» — ни к одной: от мусора модели не отличить, поэтому
-- ответ модели как есть. Выбор прежний в обоих случаях
function T.test_unclear_word_asks_again_and_keeps_choice()
  local env = make_word(word_db())
  env:answer({ read = "Дела в покупках на неделю", reply = "Да.", tasks_source = "покупки на неделю" })
  for _, case in ipairs({ { word = "покупки", why = "many" }, { word = "сад", why = "none" } }) do
    local shown = env:answer({ read = "Дела в " .. case.word, reply = "Запомню.", tasks_source = case.word })
    if case.why == "many" then
      t.ok(in_pool(shown, texts.tasks_source_unclear), case.word .. ": переспрос из пула, а не «" .. tostring(shown) .. "»")
    else
      t.eq(shown, "Запомню.", case.word .. ": ответ модели")
    end
    t.eq(core_of(env.kpath), "c2", case.word .. ": выбор прежний")
    t.ok(env:logged("riddle: tasks source unclear (" .. case.why .. ")"), table.concat(env.logs, "\n"))
    local e = env.mem:entries(env.mem:session(env.now))
    t.eq(e[#e].text, shown, case.word .. ": в памяти — то, что показано")
    env:clean_logs()
  end
  env:close()
end

function T.test_word_may_name_non_candidate()
  local env = make_word(word_db())
  env:answer({ read = "Дела в фильмах", reply = "Да.", tasks_source = "фильмы" })
  t.eq(core_of(env.kpath), "c4", "не кандидат — тоже можно")
  env:answer({ read = "Ну", reply = "Да." })
  t.ok(env:logged("riddle: tasks open=0 shown=0 via=user"), table.concat(env.logs, "\n"))
  env:clean_logs()
  env:close()
end

-- база занята синхронизацией дольше busy_timeout: выбор не запомнен, ответ модели как есть
function T.test_set_failure_keeps_answer_and_choice()
  local kpath = word_db()
  local K = knowledge.open(kpath)
  K:set_core("tasks_source", "c2")
  K:close()
  local tried
  local env = make_word(kpath, function(id) tried = id return nil, "database is locked" end)
  t.eq(env:answer({ read = "Дела дома", reply = "Запомню.", tasks_source = "дела-дома" }), "Запомню.",
    "ответ модели")
  t.eq(tried, "c1", "запись пробовали")
  t.eq(core_of(kpath), "c2", "выбор прежний")
  t.ok(env:logged("riddle: tasks source set failed: database is locked"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do
    t.ok(l ~= "riddle: tasks source set" and l ~= "riddle: tasks source cleared", "успеха в логе нет: " .. l)
  end
  env:clean_logs()
  env:close()
end

-- персона без своего набора (не готова): переспрос из нейтрального пула «назови собрание точнее» на языке строки,
-- а не «не разобрал запись» (Notion 41013e60-bc8d-81e4)
function T.test_unclear_word_neutral_pool_for_persona_without_set()
  for _, case in ipairs({ { line = "Гермиона Грейнджер", lang = "ru" }, { line = "R2-D2 from Star Wars", lang = "en" } }) do
    local env = make_word(word_db())
    env.ctrl.deps.cfg = { whose = case.line }
    -- персона готова (характер и мир есть), сгенерированных наборов фраз нет
    env.mem:add_persona{ key = persona.key(case.line), line = case.line, source = "config", state = "ready", ts = 0 }
    local row = env.mem:persona_by_key(persona.key(case.line))
    env.mem:set_part(row.id, "persona", json.encode({ head = "ГОЛОВА-ПЕРСОНЫ.", body = "Характер: ГОЛОС-ПЕРСОНЫ.",
      lang = case.lang, lang_name = case.lang, gender = "f", kind = "дневник", title = "Дневник",
      invitation = "Кто здесь?" }), 1)
    env.mem:set_part(row.id, "world", "МИР-ПЕРСОНЫ.", 1)
    env.mem:use_persona(row.id)
    local shown = env:answer({ read = "Дела в покупках", reply = "Запомню.", tasks_source = "покупки" })
    t.ok(env:logged("riddle: tasks source unclear (many)"), case.lang .. ": " .. table.concat(env.logs, "\n"))
    t.ok(not in_pool(shown, texts.neutral[case.lang].unreadable), case.lang .. ": «не разобрал запись» вместо переспроса: " .. tostring(shown))
    t.ok(in_pool(shown, texts.neutral[case.lang].source_unclear), case.lang .. ": не из нового пула: " .. tostring(shown))
    env:close()
  end
end

-- переспрос о книге дел вместо ответа: дел в нём не названо — и предложения у реплики diary нет. Слово нашлось —
-- ответ модели и предложение прежние; не нашлось ни одной — тоже. «работы» — целым словом в двух книгах, «сад» —
-- ни в одной
function T.test_unclear_word_drops_offer()
  for _, case in ipairs({ { word = "работы", why = "many" }, { word = "сад", none = true, offer = "pg-1 pg-2 pg-3" },
    { word = "фильмы", offer = "pg-1 pg-2 pg-3" } }) do
    local ctx = ctx_with_tasks(5)
    ctx.collections[#ctx.collections + 1] = { id = "c3", title = "Дела работы" }
    ctx.collections[#ctx.collections + 1] = { id = "c4", title = "Работы по саду" }
    local env = make_open(ctx, nil, { set_tasks_source = function() return true end })
    local shown = env:answer({ read = "Дела в " .. case.word, reply = "Запомню.", task = "", tasks_source = case.word })
    t.ok(env:logged("riddle: rhythm mode=name n=1"), table.concat(env.logs, "\n"))
    if case.why then
      t.ok(in_pool(shown, texts.tasks_source_unclear), case.word .. ": переспрос, а не «" .. tostring(shown) .. "»")
      t.ok(env:logged("riddle: tasks source unclear (" .. case.why .. ")"), table.concat(env.logs, "\n"))
    else
      t.eq(shown, "Запомню.", case.word .. ": ответ модели")
    end
    if case.none then t.ok(env:logged("riddle: tasks source unclear (none)"), table.concat(env.logs, "\n")) end
    t.eq(last_offer(env), case.offer, case.word .. ": предложение")
    env:close()
  end
end

-- свёртка выпавшего из окна (план 2026-10-28-rolling-summary, срез 2) ------------------------------------
local prompt = require("riddle.prompt")

-- печати нет; ответ и хвост — через «дочерний» (путь виджета с runner): запрос ответа — в env.asked, хвоста — в
-- env.remote, ответ модели хвосту — из env.fold
local function make_roll(path)
  local env
  env = make_open(nil, path, {
    remote_fn = function(messages, want_json, opts)
      local list = want_json and env.asked or env.remote
      list[#list + 1] = { messages = messages, want_json = want_json, opts = opts }
      return function() return { result = table.remove(env.fold, 1) } end
    end,
    absorb = function(p) return p.result, p.err end,
  })
  env.remote, env.fold, env.asked = {}, {}, {}
  require("fixtures.map_parts").seed(env.mem) -- данные карты «Методов» готовы: хвост — пересказ и свёртка
  -- страница «З<i>»: реплика пишущего и ответ «ОЗ<i>»; -> take_followup после ответа
  function env:page(i)
    self.logs = {}
    local job = self.ctrl:begin(PNG)
    self.ctrl:finish(job, { result = { read = "З" .. i, reply = "ОЗ" .. i } })
    return self.ctrl:take_followup()
  end
  -- system последнего запроса ответа
  function env:sys() return self.asked[#self.asked].messages[1].content end
  function env:pages(from, to)
    local due
    for i = from, to do due = self:page(i) end
    return due
  end
  function env:sid() return (self.mem:session(self.now)) end
  -- взятый хвост начался (виджет: таймер после показа ответа) и отменён: поводы пересказа и свёртки погашены
  function env:start_tail()
    local job = self.ctrl:begin_followup()
    if job then self.ctrl:finish_followup(job, nil, "cancelled") end
  end
  return env
end

local function user_of(job) return job.messages[#job.messages].content end

function T.test_roll_due_when_window_full()
  local env = make_roll()
  t.ok(env:page(1), "после первого ответа — хвост старта (печати нет)")
  env:start_tail()
  for i = 2, 19 do t.ok(not env:page(i), "страница " .. i .. ": свёртка не назрела") end
  t.ok(env:page(20), "20-я страница: окно целиком из несвёрнутых")
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "roll")
  t.eq(env.remote[1].want_json, false)
  t.eq(env.remote[1].opts and env.remote[1].opts.max_tokens, controller.ROLL_MAX_TOKENS, "свой потолок ответа")
  env:close()
end

function T.test_roll_job_folds_oldest_batch()
  local env = make_roll()
  env:pages(1, 20)
  local job = env.ctrl:begin_followup()
  local user = user_of(job)
  t.ok(has(user, "Запись: З1\nДневник: ОЗ1\n"), "первая реплика")
  t.ok(has(user, "Запись: З10\nДневник: ОЗ10"), "десятая страница")
  t.ok(not has(user, "З11"), "свёртка — старейшие 20 реплик")
  t.ok(not has(user, "Пересказ до этого"), "прежнего пересказа нет")
  local list, total = env.mem:unrolled(env:sid(), nil)
  t.eq(job.upto, list[20].id, "upto — id 20-й реплики")
  t.eq(job.total, 40)
  t.eq(total, 40)
  env:close()
end

function T.test_roll_saved_and_reaches_prompt()
  local env = make_roll()
  env:pages(1, 20)
  local job = env.ctrl:begin_followup()
  env.fold = { { text = "СВЁРТКА\nДВА" } }
  env.logs = {}
  env.ctrl:finish_followup(job, job.run())
  local text, upto = env.mem:rollup(env:sid())
  t.eq(text, "СВЁРТКА ДВА", "одной строкой")
  t.eq(upto, job.upto)
  t.ok(env:logged(string.format("riddle: roll saved upto=%d chars=11", job.upto)), table.concat(env.logs, "\n"))
  t.ok(not env:logged("СВЁРТКА"), "текст свёртки в лог не идёт")
  env:page(21)
  local sys = env:sys()
  t.ok(has(sys, prompt.ROLLING_HEAD .. "\nСВЁРТКА ДВА"), "свёртка в промпте ответа")
  env:close()
end

function T.test_roll_second_includes_earlier()
  local env = make_roll()
  env:pages(1, 20)
  local job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, { result = { text = "СВЁРТКА ДВА" } })
  for i = 21, 29 do t.ok(not env:page(i), "страница " .. i) end
  t.ok(env:page(30), "ещё 10 страниц — снова окно несвёрнутых")
  local job2 = env.ctrl:begin_followup()
  t.eq(job2.kind, "roll")
  local user = user_of(job2)
  t.ok(has(user, "Пересказ до этого: СВЁРТКА ДВА\n\nЗапись: З11\n"), user)
  t.ok(has(user, "Дневник: ОЗ20"), "до 20-й страницы")
  t.ok(not has(user, "З21") and not has(user, "Запись: З10\n"), "только следующие 20 реплик")
  env.ctrl:finish_followup(job2, { result = { text = "ТРЕТЬЯ" } })
  t.eq((env.mem:rollup(env:sid())), "ТРЕТЬЯ")
  env:close()
end

function T.test_roll_empty_not_saved()
  for _, text in ipairs({ "", "  \n " }) do
    local env = make_roll()
    env:pages(1, 20)
    local job = env.ctrl:begin_followup()
    env.ctrl:finish_followup(job, { result = { text = text } })
    local saved, upto = env.mem:rollup(env:sid())
    t.eq(saved, nil, "пустая свёртка не сохраняется")
    t.eq(upto, 0)
    -- пустой ответ — неудача, как таймаут: при суточной квоте он не должен тратить вызов на каждой странице
    t.ok(not env:page(21), "пауза после пустой свёртки")
    t.ok(not env:page(22), "пауза после пустой свёртки")
    t.ok(env:page(23), "через ROLL_RETRY реплик — снова")
    env:close()
  end
end

function T.test_roll_failure_holds_until_retry()
  local env = make_roll()
  env:pages(1, 20)
  local job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, nil, "timeout")
  t.ok(env:logged("riddle: summary failed: timeout"), table.concat(env.logs, "\n"))
  t.ok(not env:page(21), "пауза после отказа")
  t.ok(not env:page(22), "пауза после отказа")
  t.eq(env.ctrl:begin_followup(), nil, "в паузе свёртку не спрашивать и по хвосту")
  t.ok(env:page(23), "через ROLL_RETRY реплик — снова")
  t.eq(env.ctrl:begin_followup().total, 40 + controller.ROLL_RETRY)
  env:close()
end

function T.test_roll_model_error_holds()
  local env = make_roll()
  env:pages(1, 20)
  local job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, { err = "groq: http 429" })
  t.ok(not env:page(21), "отказ модели — пауза, как таймаут")
  env:close()
end

function T.test_roll_cancelled_retries_next_answer()
  local env = make_roll()
  env:pages(1, 20)
  local job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, nil, "cancelled")
  t.ok(env:page(21), "перо, сон, вытеснение — снова после следующего ответа")
  env:close()
end

function T.test_session_summary_before_roll()
  local env = make_roll()
  env:page(1)
  env.now = 5 * H
  env:pages(2, 21)
  local job = env.ctrl:begin_followup()
  t.eq(job.kind, "session", "пересказ прошлой сессии — первым")
  t.eq(job.sid, 1)
  t.eq(env.remote[1].opts and env.remote[1].opts.max_tokens, controller.SUMMARY_MAX_TOKENS)
  env.ctrl:finish_followup(job, { result = { text = "ПРОШЛОЕ" } })
  t.eq(env.mem:summaries(5)[1], "ПРОШЛОЕ")
  local job2 = env.ctrl:begin_followup()
  t.eq(job2 and job2.kind, "roll", "потом — свёртка")
  t.eq(job2.sid, 2)
  env:close()
end

function T.test_roll_not_starved_by_old_unsummarized()
  local env = make_roll()
  for k = 1, 8 do
    env.now = (k - 1) * 5 * H
    env:page(1) -- 8 прошлых сессий с записью, без пересказа
  end
  env.now = 8 * 5 * H
  env:pages(1, 20) -- текущая: окно целиком несвёрнутое
  local tails = 0
  local job
  repeat
    tails = tails + 1
    job = env.ctrl:begin_followup()
    t.ok(job, "хвост " .. tails)
    if job.kind == "session" then env.ctrl:finish_followup(job, { result = { text = "П" .. tails } }) end
  until job.kind == "roll" or tails > 10
  t.eq(job.kind, "roll")
  t.ok(tails <= 6, "свёртка не позже 6-го хвоста, была на " .. tails)
  env:close()
end

function T.test_roll_saved_to_job_session()
  local env = make_roll()
  env:pages(1, 20)
  local job = env.ctrl:begin_followup()
  env.now = 5 * H
  env:page(21)
  t.eq(env:sid(), 2, "сессия сменилась, пока свёртка в пути")
  env.ctrl:finish_followup(job, { result = { text = "С1" } })
  t.eq((env.mem:rollup(1)), "С1", "свёртка — в свою сессию")
  local text, upto = env.mem:rollup(2)
  t.eq(text, nil, "в новую не попала")
  t.eq(upto, 0)
  env:close()
end

function T.test_sync_followup_does_not_roll()
  local env = make_roll()
  env:pages(1, 20)
  local n = #env.calls
  env.ctrl:on_unlocked_followup()
  t.eq(#env.calls, n, "без runner свёртки нет: цикл интерфейса её не ждёт")
  t.eq(#env.remote, 0)
  env:close()
end

-- ревью cda8f68: прошлая сессия без пересказа, в текущей назрела свёртка, пересказ прошлой стабильно падает —
-- хвост, поднятый одной свёрткой, не тратит вызов на каждой странице: сбой его пересказа ставит ту же паузу
-- ROLL_RETRY (раз в 3 страницы), что и сбой свёртки. Старые поводы (сон) спрашивают пересказ, как раньше
function T.test_roll_session_fail_holds()
  local env = make_roll()
  env:page(1)
  env.now = 5 * H
  local due = env:pages(2, 21)
  local n = 0
  for i = 22, 31 do
    if due then
      local job = env.ctrl:begin_followup()
      if job then
        n = n + 1
        t.eq(job.kind, "session", "пересказ прошлой — первым")
        env.ctrl:finish_followup(job, nil, "timeout")
      end
    end
    due = env:page(i)
  end
  t.ok(n <= 4, "вызовов хвоста на 10 страниц: " .. n .. " (раз в ROLL_RETRY реплик, не на каждой)")
  t.eq(#env.remote, n)
  env.ctrl:on_sleep()
  t.ok(env:page(32), "сон — старый повод хвоста")
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session", "по старому поводу пересказ спрашивается и в паузе")
  env.ctrl:finish_followup(job, nil, "cancelled")
  env:close()
end

-- сброс roll_tail (Notion 40613e60-bc8d-81cc): прошлая сессия без пересказа, в текущей назрела свёртка. Лишняя
-- пауза ROLL_RETRY у пересказа по чужому поводу — потерянные вызовы хвоста, поэтому каждый сброс держим отдельно

-- свёртка назрела вместе со старым поводом (сон): хвост не «свёрточный», сбой пересказа паузы не ставит
function T.test_roll_tail_off_with_old_trigger()
  local env = make_roll()
  env:page(1)
  env.now = 5 * H
  env:pages(2, 20)
  env.ctrl:on_sleep()
  t.ok(env:page(21), "и сон, и свёртка")
  t.eq(env.ctrl.roll_tail, false, "повод сна — не хвост свёртки")
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session")
  t.eq(job.hold, nil, "паузы у хвоста по старому поводу нет")
  env.ctrl:finish_followup(job, nil, "timeout")
  t.eq(env.ctrl.roll_hold, nil, "сбой пересказа без паузы свёртки")
  env:close()
end

-- хвост свёртки, не начатый до сна, — не повод для паузы у хвоста после сна
function T.test_roll_tail_reset_on_sleep()
  local env = make_roll()
  env:page(1)
  env:start_tail()
  env.now = 5 * H
  t.ok(env:pages(2, 21), "свёртка назрела")
  t.eq(env.ctrl.roll_tail, true)
  env.ctrl:on_sleep()
  t.eq(env.ctrl.roll_tail, false, "сон сбрасывает")
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session")
  t.eq(job.hold, nil, "паузы нет")
  env.ctrl:finish_followup(job, nil, "timeout")
  t.eq(env.ctrl.roll_hold, nil)
  env:close()
end

-- и хвост свёртки, не начатый до закрытия дневника (таймер упал вместе с виджетом), — не повод для паузы у хвоста
-- после него (цепочка генерации, разблокировка)
function T.test_roll_tail_reset_on_close()
  local env = make_roll()
  env:page(1)
  env:start_tail()
  env.now = 5 * H
  t.ok(env:pages(2, 21), "свёртка назрела")
  t.eq(env.ctrl.roll_tail, true)
  env.ctrl:on_close()
  t.eq(env.ctrl.roll_tail, false, "закрытие сбрасывает")
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session")
  t.eq(job.hold, nil, "паузы нет")
  env.ctrl:finish_followup(job, nil, "timeout")
  t.eq(env.ctrl.roll_hold, nil)
  env:close()
end

-- begin_followup расходует roll_tail: следующий begin_followup без нового take_followup (разблокировка) — не свёрточный
function T.test_roll_tail_consumed_by_begin_followup()
  local env = make_roll()
  env:page(1)
  env:start_tail()
  env.now = 5 * H
  t.ok(env:pages(2, 21), "свёртка назрела")
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session")
  t.ok(job.hold, "хвост свёртки — с паузой")
  t.eq(env.ctrl.roll_tail, false, "расходуется")
  env.ctrl:finish_followup(job, nil, "cancelled")
  t.eq(env.ctrl.roll_hold, nil, "отмена паузы не ставит")
  local job2 = env.ctrl:begin_followup()
  t.eq(job2 and job2.kind, "session", "пересказ всё ещё не сохранён")
  t.eq(job2.hold, nil, "повод другой — паузы нет")
  env.ctrl:finish_followup(job2, nil, "timeout")
  t.eq(env.ctrl.roll_hold, nil)
  env:close()
end

-- без runner свёртки нет — нет и повода для хвоста: синхронный цикл интерфейса не ждёт пересказ на каждой странице
-- данные карты «Методов» не держат пересказ и свёртку, сбой карты — одна попытка за открытие (ревью e0e50cf, БЛОК-1).
-- Без засева: модель на разделы карты отвечает негодным (bad), хвосты идут цепочкой, как у виджета
-- (finish_followup -> следующий хвост) -> счёт заданий по видам
local function map_failing_evening(bad)
  local MP = require("fixtures.map_parts")
  local env = make_roll()
  env.mem:forget_parts(persona.METHODS_ID)
  env.mem:add(env.mem:session(0), "owner", "ЗАП-ПРОШЛОЙ", 0) -- прошлая сессия без пересказа
  env.now = 5 * H
  local n = { gen = 0, session = 0, roll = 0 }
  local answers = { map = bad.map or MP.map_json, ["map.cast"] = bad.cast or MP.cast_json,
    session = "ПЕРЕСКАЗ", roll = "СВЁРТКА" }
  for i = 1, 60 do
    local due, chain = env:page(i), 0
    while due and chain < 5 do
      chain = chain + 1
      local job = env.ctrl:begin_followup()
      if not job then break end
      n[job.kind] = n[job.kind] + 1
      due = env.ctrl:finish_followup(job, { result = { text = answers[job.section or job.kind] } })
    end
  end
  env:close()
  return n
end

-- C: героев всегда меньше mapdata.MIN_CAST
function T.test_map_cast_failing_keeps_summary_and_roll()
  local MP = require("fixtures.map_parts")
  local n = map_failing_evening({ cast = MP.wrap(MP.cast(5)) })
  t.eq(n.session, 1, "пересказ прошлой сессии — первым, один раз")
  t.ok(n.roll >= 2, "свёртки идут: " .. n.roll)
  t.eq(n.gen, 2, "map — один раз, map.cast — одна попытка за открытие")
end

-- D: раздел map всегда не JSON
function T.test_map_failing_keeps_summary_and_roll()
  local n = map_failing_evening({ map = "не JSON" })
  t.eq(n.session, 1, "пересказ прошлой сессии — первым, один раз")
  t.ok(n.roll >= 2, "свёртки идут: " .. n.roll)
  t.eq(n.gen, 1, "map — одна попытка за открытие")
end

-- то же с печатью (ревью 6ac25c8): хвост разблокировки пересказывает ждущую сессию без флагов followup_due/roll_due —
-- карта уступает любому готовому пересказу и свёртке. 6 дней: сон -> разблокировка (хвост цепочкой, как у виджета) ->
-- 5 страниц. -> заданий по видам, gen карты по дням
local function sealed_days(bad)
  local MP = require("fixtures.map_parts")
  local env = make()
  env.ctrl.deps.remote_fn = function() return function() return {} end end
  env.ctrl.deps.absorb = function(p) return p.result, p.err end
  local answers = { map = bad.map or MP.map_json, ["map.cast"] = bad.cast or MP.cast_json,
    session = bad.session or "ПЕРЕСКАЗ", roll = "СВЁРТКА" }
  local n, gen_by_day = { gen = 0, session = 0, roll = 0 }, {}
  local function chain(due)
    local steps = 0
    while due and steps < 10 do
      steps = steps + 1
      local job = env.ctrl:begin_followup()
      if not job then break end
      n[job.kind] = n[job.kind] + 1
      due = env.ctrl:finish_followup(job, { result = { text = answers[job.section or job.kind] } })
    end
  end
  for day = 1, 6 do
    local gen0 = n.gen
    env.ctrl:on_sleep()
    env.now = (day - 1) * 24 * H
    env.ctrl:seal_toggle()
    t.ok(env.ctrl.seal_open, "день " .. day .. ": печать снята")
    chain(true) -- хвост разблокировки
    for i = 1, 5 do
      env.now = env.now + 60
      env:say("Запись " .. day .. "." .. i, "Ответ")
      env.ctrl:on_page(PNG)
      chain(env.ctrl:take_followup())
    end
    gen_by_day[day] = n.gen - gen0
  end
  local summaries = env.mem:summaries(10)
  env:close()
  return n, gen_by_day, summaries
end

local function check_sealed_days(n, gen_by_day, summaries)
  t.eq(n.session, 5, "пересказ каждой прошлой сессии (дни 1–5)")
  local done = 0
  for _, s in ipairs(summaries) do if s == "ПЕРЕСКАЗ" then done = done + 1 end end
  t.eq(done, 5, "пересказы сохранены")
  for day, g in ipairs(gen_by_day) do t.ok(g <= 2, "день " .. day .. ": вызовов карты " .. g) end
end

function T.test_sealed_map_failing_keeps_summary()
  local n, gen_by_day, summaries = sealed_days({ map = "не JSON" })
  check_sealed_days(n, gen_by_day, summaries)
  for day, g in ipairs(gen_by_day) do t.eq(g, 1, "день " .. day .. ": map — одна попытка на разблокировку") end
end

function T.test_sealed_map_cast_failing_keeps_summary()
  local MP = require("fixtures.map_parts")
  local n, gen_by_day, summaries = sealed_days({ cast = MP.wrap(MP.cast(5)) })
  check_sealed_days(n, gen_by_day, summaries)
  t.eq(gen_by_day[1], 2, "день 1: map сохранён, map.cast — одна попытка")
  for day = 2, 6 do t.eq(gen_by_day[day], 1, "день " .. day .. ": map.cast — одна попытка на разблокировку") end
end

-- пересказ, который не сохраняется (пустой ответ модели), цепочкой не повторяется: после него хвост — карте
function T.test_sealed_empty_summary_does_not_loop_before_map()
  local n, gen_by_day = sealed_days({ map = "не JSON", session = "" })
  t.eq(n.session, 5, "одна попытка пересказа на разблокировку (дни 2–6)")
  for day, g in ipairs(gen_by_day) do t.eq(g, 1, "день " .. day .. ": map — одна попытка") end
end

-- флаг map_next («карта — следующий хвост») выставляет итог пересказа, уступившего карте. Печать закрылась до итога
-- (сон посреди хвоста): карте следовать некому, флаг не остаётся лежать — после разблокировки пересказ ждущей сессии
-- идёт раньше карты, как обычно
function T.test_map_next_not_left_over_when_seal_closed_before_the_summary_result()
  local env = make()
  env.ctrl.deps.remote_fn = function() return function() return {} end end
  env.ctrl.deps.absorb = function(p) return p.result, p.err end
  local function unlock(now, asleep) -- asleep: печать уже закрыта сном посреди хвоста, второго сна нет
    if not asleep then env.ctrl:on_sleep() end
    env.now = now
    env.ctrl:seal_toggle()
    t.ok(env.ctrl.seal_open, "печать снята")
    env.now = now + 60
    env:say("Запись", "Ответ") -- страница после разблокировки: её реплики и есть сессия
    env.ctrl:on_page(PNG)
  end
  -- день 1: карта просится (раздел не сохраняется), сессия записана
  unlock(0)
  local job = env.ctrl:begin_followup()
  t.eq(job.section, "map")
  env.ctrl:finish_followup(job, { result = { text = "не JSON" } })
  -- день 2: пересказ дня 1 уступает карте, но печать закрывается до его итога
  unlock(24 * H)
  job = env.ctrl:begin_followup()
  t.eq(job.kind, "session", "пересказ дня 1 — первым")
  t.ok(job.before_map, "карта ему уступила")
  env.ctrl:on_sleep()
  env.ctrl:finish_followup(job, { result = { text = "ПЕРЕСКАЗ-1" } })
  -- день 3: печать снята заново, ждущий пересказ дня 2 идёт раньше карты, как обычно
  unlock(48 * H, true)
  local nxt = env.ctrl:begin_followup()
  t.eq(nxt and nxt.kind, "session", "пересказ раньше карты: " .. tostring(nxt and (nxt.section or nxt.kind)))
  env:close()
end

-- сбой карты ждёт следующего открытия (закрытие или сон), не следующей страницы
function T.test_map_failure_retried_after_close_or_sleep()
  local env = make_roll()
  env.mem:forget_parts(persona.METHODS_ID)
  local job = env.ctrl:begin_followup()
  t.eq(job.section, "map")
  t.eq(env.ctrl:finish_followup(job, { result = { text = "не JSON" } }), false, "сбой — цепочки нет")
  env:page(1)
  t.ok(not env.ctrl:gen_due(), "страница паузу карты не снимает")
  env.ctrl:on_close()
  t.ok(env.ctrl:gen_due(), "новое открытие — новая попытка")
  job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, { result = { text = "не JSON" } })
  t.ok(not env.ctrl:gen_due())
  env.ctrl:on_sleep()
  t.ok(env.ctrl:gen_due(), "после сна — новая попытка")
  env:close()
end

function T.test_sync_roll_due_no_call()
  local env = make_roll()
  env.mem:forget_parts(persona.METHODS_ID) -- данных карты нет: синхронный путь её не генерирует и лишнего не зовёт
  env:answer({ read = "З1", reply = "ОЗ1" })
  t.ok(env.ctrl:take_followup(), "хвост старта (печати нет)")
  env.ctrl:on_unlocked_followup()
  env.now = 5 * H
  for i = 2, 31 do
    env:answer({ read = "З" .. i, reply = "ОЗ" .. i })
    if env.ctrl:take_followup() then env.ctrl:on_unlocked_followup() end
  end
  t.eq(#env.calls, 31, "только ответы на страницы")
  t.eq(#env.remote, 0)
  env:close()
end

function T.test_roll_off_without_table()
  local env = make_roll()
  env.mem.conn:exec("DROP TABLE rollups")
  env:page(1)
  env:start_tail()
  for i = 2, 25 do
    t.ok(not env:page(i), "страница " .. i .. ": свёртки нет")
    t.eq(#env.mem:entries(env:sid()), 2 * i, "ответ записан")
  end
  t.eq(env.ctrl:begin_followup(), nil)
  t.ok(not has(env:sys(), prompt.ROLLING_HEAD))
  env:close()
end

-- пересказ прошлой сессии из её свёртки и несвёрнутого хвоста (срез 3): иначе пересказ долгой сессии — все её
-- реплики одним сообщением, которое prompt.fit не режет
function T.test_session_summary_uses_rollup()
  local env = make_roll()
  env:pages(1, 15)
  local list = env.mem:unrolled(1, 20)
  t.ok(env.mem:set_rollup(1, "СВ", list[20].id, env.now))
  env.ctrl:on_sleep()
  env.now = 5 * H
  env:page(16)
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session")
  t.eq(job.sid, 1)
  local user = user_of(job)
  t.ok(has(user, "Раньше в этой сессии: СВ\nЗапись: З11\n"), user)
  t.ok(has(user, "Дневник: ОЗ15"), "хвост до конца сессии")
  t.ok(not has(user, "Запись: З1\n") and not has(user, "З10"), "свёрнутое — только в свёртке")
  env:close()
end

function T.test_session_summary_all_rolled()
  local env = make_roll()
  env:pages(1, 10)
  local list = env.mem:unrolled(1, nil)
  t.ok(env.mem:set_rollup(1, "ВСЁ", list[#list].id, env.now))
  env.now = 5 * H
  env:page(11)
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session", "свёрнуто всё — пересказ всё равно есть из чего")
  t.eq(user_of(job), "Раньше в этой сессии: ВСЁ")
  env.ctrl:finish_followup(job, { result = { text = "ПРОШЛОЕ" } })
  t.eq(env.mem:summaries(5)[1], "ПРОШЛОЕ")
  env:close()
end

t.run(T)
