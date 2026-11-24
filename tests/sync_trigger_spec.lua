-- main.lua, срез 3: фоновое чтение Notion. Сон — всегда; открытие дневника и простой виджета (on_idle) —
-- если удачному чтению больше sync.STALE_S и не чаще раза в 60 с. Нет токена — ничего не запускается.
-- Плагин на поддельной ФС и поддельном UIManager (как devwatch_spec.lua), runner — подделка по
-- интерфейсу riddle.worker (start/busy/cancel), sync.should_start — настоящий.
require("sqlite_shim")
local t = require("t")
local real_sync = require("riddle.sync")
local real_knowledge = require("riddle.knowledge")

local function fake_env(files, env)
  local fio = setmetatable({
    open = function(path, mode)
      if path:find("^/mnt/us/") or path:find("^/proc/") then
        if mode and mode:find("w") then
          -- запись: содержимое попадает в files[path] при close (как на диске); env.open_fails / env.write_fails —
          -- отказ открытия / записи (полный FAT)
          env.opened_for_write[#env.opened_for_write + 1] = path
          if env.open_fails then return nil, path .. ": No space left on device" end
          local buf = {}
          return { write = function(self, ...)
                     if env.write_fails then return nil, "No space left on device" end
                     for _, x in ipairs{ ... } do buf[#buf + 1] = tostring(x) end
                     return self
                   end,
                   close = function() files[path] = table.concat(buf) return true end }
        end
        if files[path] then return { close = function() end } end
        return nil, path .. ": No such file"
      end
      return io.open(path, mode)
    end,
  }, { __index = io })
  local fos = setmetatable({
    remove = function(path) files[path] = nil return true end,
    rename = function(from, to)
      if files[from] == nil then return nil, from .. ": No such file" end
      files[to], files[from] = files[from], nil
      return true
    end,
    time = function() return 100000 end,
  }, { __index = os })
  return fio, fos
end

-- поддельный runner по интерфейсу riddle.worker: start(kind, fn, opts) -> true | nil, err
local function fake_runner()
  local r = { jobs = {}, cancels = {} }
  function r:start(kind, fn, opts)
    if self.cur then return nil, "busy" end
    self.cur = { kind = kind, fn = fn, opts = opts }
    self.jobs[#self.jobs + 1] = self.cur
    return true
  end
  function r:busy() return self.cur and self.cur.kind or nil end
  function r:cancel(kind)
    self.cancels[#self.cancels + 1] = kind or "*"
    if self.cur and (not kind or self.cur.kind == kind) then self.cur = nil end
  end
  function r:done(payload, err)
    local job = self.cur
    self.cur = nil
    job.opts.on_done(payload, err)
  end
  return r
end

-- env: token, last_ok, now (монотонные секунды), store_fails, tasks_source
local function load_plugin(env)
  local LOG, widgets = {}, {}
  local runner = fake_runner()
  local opened = { n = 0 }
  local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    LOG[#LOG + 1] = table.concat(parts, " ")
  end
  local ui = { queue = {}, restarts = 0 }
  function ui:scheduleIn(_, fn) self.queue[#self.queue + 1] = fn end
  function ui:restartKOReader() self.restarts = self.restarts + 1 end
  function ui:nextTick() end
  function ui:show() end
  local stubs = {
    ["datastorage"] = {},
    ["luasettings"] = {},
    ["ui/uimanager"] = ui,
    ["ui/widget/container/widgetcontainer"] = { extend = function(_, o) return o end },
    ["libs/libkoreader-lfs"] = {},
    ["logger"] = { info = log, warn = log, err = log },
    ["ui/time"] = { monotonic = function() return env.now or 0 end, to_s = function(x) return x end,
                    to_ms = function(x) return x * 1000 end },
    ["riddle.app"] = { new_controller = function()
      return { on_sleep = function() end, seal = { closes_on_sleep = function() return false end } }
    end,
                       hosts = function() return {} end },
    ["riddle.config"] = { load = function()
      return { seal = { on = false }, notion_token = env.token, tasks_source = env.tasks_source }
    end },
    ["riddle.http"] = {},
    ["riddle.llm"] = { providers = function() return {} end },
    ["riddle.memory"] = { open = function() return {} end },
    ["riddle.worker"] = { koreader_sys = function() return {} end, new = function() return runner end,
                          rss_kb = function()
                            if env.rss_fails then error("rss boom") end
                            return env.parent_rss
                          end },
    ["riddle.sync"] = real_sync,
    ["riddle.knowledge"] = env.real_store and real_knowledge or {
      PATH = "/mnt/us/riddle/knowledge.sqlite3",
      open = function(path)
        if env.store_fails then error("no sqlite") end
        opened.n = opened.n + 1
        opened.path = path
        return { meta = function(_, k)
                   if env.meta_fails then error("disk I/O error") end
                   return k == "last_ok" and env.last_ok or nil
                 end,
                 stats = function()
                   opened.stats = (opened.stats or 0) + 1
                   if env.stats_fails then error("disk I/O error") end
                   return { docs = 7, chars = 100, collections = 2 }
                 end,
                 close = function() opened.closed = (opened.closed or 0) + 1 end }
      end,
    },
    ["riddle_diarywidget"] = { new = function(_, o) widgets[#widgets + 1] = o; return o end },
  }
  for name, mod in pairs(stubs) do package.loaded[name] = mod end
  package.loaded["riddlediary/state"] = nil
  local chunk = assert(loadfile("plugin/riddlediary.koplugin/main.lua"))
  local files = env.files or {}
  env.opened_for_write = {}
  local fio, fos = fake_env(files, env)
  local gc = {}
  local function spy_gc(opt, ...)
    gc[#gc + 1] = opt or "collect"
    return collectgarbage(opt == "restart" and "count" or opt, ...)
  end
  setfenv(chunk, setmetatable({ io = fio, os = fos, collectgarbage = spy_gc }, { __index = _G }))
  return { plugin = chunk(), runner = runner, LOG = LOG, widgets = widgets, opened = opened, ui = ui,
           gc = gc, files = files, env = env }
end

local function count(LOG, needle)
  local n = 0
  for _, line in ipairs(LOG) do if line:find(needle, 1, true) then n = n + 1 end end
  return n
end

local T = {}

function T.test_suspend_starts_sync_with_timeout()
  local p = load_plugin{ token = "secret_abc123", last_ok = 99999 }
  p.plugin:onSuspend()
  local job = p.runner.jobs[1]
  t.ok(job, "сон запускает sync")
  t.eq(job.kind, "sync")
  t.eq(job.opts.timeout_s, 600)
  t.eq(type(job.fn), "function")
  t.eq(count(p.LOG, "riddle: sync start (suspend)"), 1, table.concat(p.LOG, "\n"))
end

function T.test_no_token_nothing_starts()
  local p = load_plugin{ token = nil }
  p.plugin:onSuspend()
  p.plugin:openDiary()
  p.widgets[1].on_idle()
  t.eq(#p.runner.jobs, 0, "без токена дочерний не запускается")
  t.eq(p.opened.n, 0, "без токена хранилище не открывается")
  t.eq(count(p.LOG, "sync start"), 0)
end

function T.test_open_starts_sync_when_stale()
  local p = load_plugin{ token = "tok", last_ok = 100000 - 3600 }
  p.plugin:openDiary()
  t.eq(#p.runner.jobs, 1, "удачному чтению час — открытие запускает sync")
  t.eq(count(p.LOG, "riddle: sync start (stale)"), 1, table.concat(p.LOG, "\n"))
  t.eq(p.opened.path, "/mnt/us/riddle/knowledge.sqlite3")
  t.eq(p.opened.closed, 1, "родитель закрыл хранилище после meta")
end

function T.test_open_never_synced_starts()
  local p = load_plugin{ token = "tok", last_ok = nil }
  p.plugin:openDiary()
  t.eq(#p.runner.jobs, 1, "ни одного удачного чтения — запуск")
end

function T.test_open_fresh_does_not_start()
  local p = load_plugin{ token = "tok", last_ok = 100000 - 600 }
  p.plugin:openDiary()
  t.eq(#p.runner.jobs, 0, "свежее чтение — не запускать")
end

function T.test_idle_throttled_to_once_per_minute()
  local env = { token = "tok", last_ok = 100000 - 600, now = 10 }
  local p = load_plugin(env)
  p.plugin:openDiary()
  t.eq(p.opened.n, 1)
  local idle = p.widgets[1].on_idle
  t.eq(type(idle), "function", "виджет получил on_idle")
  env.now = 40
  idle()
  t.eq(p.opened.n, 1, "через 30 с хранилище не перечитывается")
  env.last_ok = 1
  env.now = 71
  idle()
  t.eq(p.opened.n, 2, "через 61 с — проверка снова")
  t.eq(#p.runner.jobs, 1, "простой запустил sync")
  t.eq(count(p.LOG, "riddle: sync start (stale)"), 1)
end

function T.test_busy_runner_skips_and_keeps_store_closed()
  local p = load_plugin{ token = "tok", last_ok = nil }
  p.runner.cur = { kind = "answer" }
  p.plugin:openDiary()
  t.eq(#p.runner.jobs, 0, "runner занят ответом — sync не стартует")
  t.eq(p.opened.n, 0, "занят — хранилище не открывается")
  p.plugin:onSuspend()
  t.eq(#p.runner.jobs, 0, "сон при занятом runner — не вытеснять")
end

function T.test_store_open_failure_skips_quietly()
  local p = load_plugin{ token = "tok", store_fails = true }
  p.plugin:openDiary()
  t.eq(#p.runner.jobs, 0, "хранилище не открылось — не запускать")
  t.ok(p.widgets[1], "дневник открылся")
end

-- страница состояния (план 2026-11-19-status-triangle, Task 5; спека 2026-11-19-status-notion-design): дневник
-- получает чтение last_ok и чисел Notion одним коротким подключением, как у maybeSync (open -> meta, stats -> close);
-- хранилище не открылось или чтение упало — ошибка (её ловит status.collect), соединение всё равно закрыто
function T.test_diary_gets_store_reader()
  local p = load_plugin{ token = "tok", last_ok = "99000" }
  p.plugin:openDiary()
  local w = p.widgets[1]
  local opens, before = p.opened.n, p.opened.closed or 0
  local s = w.store()
  t.eq(s.last_ok, "99000")
  t.eq(s.docs, 7); t.eq(s.collections, 2)
  t.eq(p.opened.n, opens + 1, "одно соединение на метку и числа")
  t.eq(p.opened.closed, before + 1, "хранилище закрыто после чтения")
  p.env.stats_fails = true
  t.ok(not pcall(w.store), "чтение упало — ошибка")
  t.eq(p.opened.closed, before + 2, "и соединение закрыто")
  p.env.stats_fails = nil
  p.env.store_fails = true
  t.ok(not pcall(w.store), "не открылось — ошибка, не тихий nil")
end

-- maybeSync числа не считает: ему нужна только метка
function T.test_maybe_sync_reads_only_last_ok()
  local p = load_plugin{ token = "tok", last_ok = "99000" }
  p.plugin:openDiary()
  t.ok(p.opened.n >= 1, "maybeSync читал хранилище")
  t.eq(p.opened.stats, nil, "без подсчёта документов")
end

-- страница читает last_ok на потоке интерфейса: занятая база (другое соединение держит блокировку) не держит её —
-- чтение сразу отказывает (страница покажет «—»), а не ждёт общий busy_timeout (2 с)
function T.test_diary_last_ok_reader_does_not_wait_for_busy_store()
  local path = os.tmpname()
  real_knowledge.open(path):close()
  local saved = real_knowledge.PATH
  real_knowledge.PATH = path
  local holder
  -- всё, что может упасть, — в pcall: PATH и файл возвращаются до проверок (как restore() у child_request)
  local ran, ok, waited, after = pcall(function()
    local p = load_plugin{ token = "tok", real_store = true }
    p.plugin:openDiary()
    local w = p.widgets[1]
    holder = require("lua-ljsqlite3/init").open(path)
    holder:exec("BEGIN EXCLUSIVE")
    local t0 = os.time()
    local read_ok = pcall(w.store)
    local dt = os.time() - t0
    holder:exec("ROLLBACK")
    return read_ok, dt, w.store()
  end)
  if holder then pcall(holder.close, holder) end
  real_knowledge.PATH = saved
  os.remove(path)
  t.ok(ran, "стенд: " .. tostring(ok))
  t.ok(not ok, "база занята — чтение отказывает")
  t.ok(waited <= 1, "не ждали busy_timeout: " .. waited .. " с")
  t.eq(after.last_ok, nil, "блокировка снята — читается (меток ещё нет)")
  t.eq(after.docs, 0); t.eq(after.collections, 0, "и числа настоящей базы — пусто")
end

-- и чтение файлов (сборка, итог синхронизации, /proc) — тем же readFile плагина, своей копии у дневника нет
function T.test_diary_gets_file_reader()
  local p = load_plugin{ token = "tok", last_ok = "99000" }
  p.plugin:openDiary()
  local w = p.widgets[1]
  local path = os.tmpname()
  local f = assert(io.open(path, "wb"))
  f:write("21171e3\n")
  f:close()
  t.eq(w.read_file(path), "21171e3\n")
  os.remove(path)
  t.eq(w.read_file(path), nil, "нет файла — nil")
end

function T.test_done_logs_numbers_only()
  local p = load_plugin{ token = "secret_abc123" }
  p.plugin:onSuspend()
  p.runner:done({ seen = 5, updated = 2, deleted = 1, chars = 777, ms = 4321, collections = 7, tasks = 18, open = 9 })
  t.eq(count(p.LOG, "riddle: sync done seen=5 updated=2 deleted=1 chars=777 in 4321 ms collections=7 tasks=18 open=9"),
    1, table.concat(p.LOG, "\n"))
  t.eq(count(p.LOG, "secret_abc123"), 0, "токена в логе нет")
end

-- RSS дочернего (payload.rss_kb) — в строке sync done; нет в payload — «?»
function T.test_done_logs_child_rss()
  local p = load_plugin{ token = "tok" }
  p.plugin:onSuspend()
  p.runner:done({ seen = 5, updated = 2, deleted = 1, chars = 777, ms = 4321, collections = 7, tasks = 18, open = 9,
    rss_kb = 20480 })
  t.eq(count(p.LOG, "riddle: sync done seen=5 updated=2 deleted=1 chars=777 in 4321 ms collections=7 tasks=18 open=9" ..
    " child_rss_kb=20480"), 1, table.concat(p.LOG, "\n"))
  p.plugin:onSuspend()
  p.runner:done({ seen = 1, updated = 0, deleted = 0, chars = 0, ms = 9 })
  t.eq(count(p.LOG, " open=0 child_rss_kb=?"), 1, table.concat(p.LOG, "\n"))
end

-- RSS родителя снимается в момент startSync и в sync done — рядом с RSS дочернего, одной строкой для тестера
function T.test_sync_rss_lines_parent_at_start_and_done()
  local env = { token = "tok", parent_rss = 51234 }
  local p = load_plugin(env)
  p.plugin:onSuspend()
  t.eq(count(p.LOG, "riddle: sync rss start parent_kb=51234 child_kb=-"), 1, table.concat(p.LOG, "\n"))
  env.parent_rss = 60001
  p.runner:done({ seen = 1, updated = 0, deleted = 0, chars = 0, ms = 9, rss_kb = 20480 })
  t.eq(count(p.LOG, "riddle: sync rss done parent_kb=60001 child_kb=20480"), 1, table.concat(p.LOG, "\n"))
end

-- сбой снятия RSS родителя не трогает sync: строка sync done, llm_logs и classify всё равно в журнале
function T.test_sync_rss_failure_keeps_done_llm_logs_and_classify()
  local env = { token = "tok", rss_fails = true }
  local p = load_plugin(env)
  p.plugin:onSuspend()
  t.eq(count(p.LOG, "riddle: sync start"), 1, table.concat(p.LOG, "\n"))
  p.runner:done({ seen = 1, updated = 0, deleted = 0, chars = 0, ms = 9, rss_kb = 20480,
    llm_logs = { "llm-line-1", "llm-line-2" }, classify = "ok", candidates = 4, pick = true, classify_ms = 7 })
  t.eq(count(p.LOG, "riddle: sync done seen=1"), 1, table.concat(p.LOG, "\n"))
  t.eq(count(p.LOG, "llm-line-1"), 1, table.concat(p.LOG, "\n"))
  t.eq(count(p.LOG, "llm-line-2"), 1, table.concat(p.LOG, "\n"))
  t.eq(count(p.LOG, "riddle: classify ok candidates=4 pick=yes in 7 ms"), 1, table.concat(p.LOG, "\n"))
  t.eq(count(p.LOG, "sync rss"), 0, "строки RSS не вышли")
end

function T.test_sync_rss_line_when_sync_stopped_and_not_started()
  local env = { token = "tok", parent_rss = 70000 }
  local p = load_plugin(env)
  p.plugin:onSuspend()
  p.runner:done({ seen = 3, updated = 1, deleted = 0, chars = 10, ms = 5, err = "unauthorized", rss_kb = 999 })
  t.eq(count(p.LOG, "riddle: sync rss done parent_kb=70000 child_kb=999"), 1, "остановка тоже снимает цифры")
  local q = load_plugin{ token = nil, parent_rss = 1 }
  q.plugin:onSuspend()
  t.eq(count(q.LOG, "sync rss"), 0, "sync не запущен — строк RSS нет")
end

-- часы сброшены назад: last_ok из будущего — устаревший, открытие запускает sync
function T.test_open_starts_sync_when_last_ok_in_future()
  local p = load_plugin{ token = "tok", last_ok = 100000 + 86400 }
  p.plugin:openDiary()
  t.eq(#p.runner.jobs, 1, "метка из будущего — запуск")
end

function T.test_stopped_logs_error()
  local p = load_plugin{ token = "tok" }
  p.plugin:onSuspend()
  p.runner:done({ seen = 3, updated = 1, deleted = 0, chars = 10, ms = 5, err = "unauthorized" })
  t.eq(count(p.LOG, "riddle: sync stopped: unauthorized (updated=1)"), 1, table.concat(p.LOG, "\n"))
  p.plugin:onSuspend()
  p.runner:done(nil, "cancelled")
  t.eq(count(p.LOG, "riddle: sync stopped: cancelled (updated=0)"), 1, table.concat(p.LOG, "\n"))
end

-- срез 6: логи цепочки классификации (уже замаскированы в дочернем) и строка classify — родителем, числами
function T.test_done_logs_classify_line_and_chain_logs()
  local p = load_plugin{ token = "tok" }
  p.plugin:onSuspend()
  p.runner:done({ seen = 1, updated = 0, deleted = 0, chars = 0, ms = 9, collections = 3, tasks = 4, open = 2,
    classify = "ok", candidates = 2, pick = true, classify_ms = 812,
    llm_logs = { "riddle: llm host -> 200 in 800 ms", "riddle: llm done ok in 810 ms" } })
  local log = table.concat(p.LOG, "\n")
  t.eq(count(p.LOG, "riddle: llm done ok in 810 ms"), 1, log)
  t.eq(count(p.LOG, "riddle: classify ok candidates=2 pick=yes in 812 ms"), 1, log)
  p.plugin:onSuspend()
  p.runner:done({ seen = 1, updated = 0, deleted = 0, chars = 0, ms = 9 })
  t.eq(count(p.LOG, "riddle: classify "), 1, "без классификации строки нет")
end

-- дочерний: classify для sync.run — цепочка LLM из конфига в этом процессе, ответ текстом, логи через mask
function T.test_child_classify_runs_chain_and_masks_logs()
  local p = load_plugin{ token = "tok" }
  p.plugin:onSuspend()
  local seen, chain_d, call = nil, nil, nil
  package.loaded["riddle.sync"] = { run = function(d) seen = d; return { seen = 0 } end,
    classify_line = real_sync.classify_line }
  package.loaded["riddle.notion"] = { new = function() return {} end }
  package.loaded["riddle.http"] = { request = function() end, post = function() end }
  package.loaded["ffi/util"] = { sleep = function() end, usleep = function() end }
  local real_app = package.loaded["riddle.app"]
  package.loaded["riddle.app"] = { chain = function(d)
    chain_d = d
    return {
      mask = function(s) return (s:gsub("KEY", "***")) end,
      remote_fn = function(_, messages, want_json, opts)
        call = { messages = messages, want_json = want_json, opts = opts }
        return function() return { result = { text = "{}" }, logs = { "riddle: llm KEY -> 200" } } end
      end,
    }
  end }
  p.runner.jobs[1].fn()
  local text, err, logs = seen.classify({ { role = "user", content = "x" } })
  package.loaded["riddle.app"] = real_app
  package.loaded["riddle.sync"] = real_sync
  t.eq(text, "{}")
  t.eq(err, nil)
  t.eq(logs[1], "riddle: llm *** -> 200", "лог цепочки замаскирован")
  t.eq(call.want_json, false)
  t.eq(call.opts.max_tokens, 1500)
  t.eq(call.opts.temperature, 0, "классификация — temperature 0")
  t.eq(call.messages[1].content, "x")
  t.eq(type(chain_d.cfg), "table", "цепочка из конфига")
  t.eq(type(chain_d.http.post), "function")
  t.eq(type(chain_d.clock), "function")
end

-- дочерний: sync.run получает клиента Notion с токеном из конфига и путь хранилища
function T.test_child_runs_sync_with_client_and_store()
  local p = load_plugin{ token = "tok-1" }
  p.plugin:onSuspend()
  local seen, made = nil, nil
  package.loaded["riddle.sync"] = { run = function(d) seen = d; return { seen = 0 } end }
  package.loaded["riddle.notion"] = { new = function(o) made = o; return { client = true } end }
  package.loaded["riddle.http"] = { request = function() end }
  package.loaded["ffi/util"] = { sleep = function() end, usleep = function() end }
  local res = p.runner.jobs[1].fn()
  t.eq(res.seen, 0)
  t.eq(made.token, "tok-1")
  t.eq(type(made.request), "function", "запрос — обёртка над http.request (сирота, срок)")
  t.eq(type(made.sleep), "function")
  t.eq(type(made.clock), "function")
  t.ok(seen.client and seen.client.client, "sync.run получил клиента")
  t.eq(seen.store_path, "/mnt/us/riddle/knowledge.sqlite3")
  t.eq(type(seen.wall), "function")
  t.eq(type(seen.clock), "function")
  t.eq(seen.tasks_source, nil, "ключа в конфиге нет")
  package.loaded["riddle.sync"] = real_sync
end

-- ключ конфига tasks_source доходит до sync.run (выбор базы задач для снимка)
function T.test_child_passes_tasks_source()
  local p = load_plugin{ token = "tok", tasks_source = "Мои задачи" }
  p.plugin:onSuspend()
  local seen
  package.loaded["riddle.sync"] = { run = function(d) seen = d; return {} end }
  package.loaded["riddle.notion"] = { new = function() return {} end }
  package.loaded["riddle.http"] = { request = function() end }
  package.loaded["ffi/util"] = { sleep = function() end, usleep = function() end }
  p.runner.jobs[1].fn()
  t.eq(seen.tasks_source, "Мои задачи")
  package.loaded["riddle.sync"] = real_sync
end

-- usleep принимает unsigned int: дробные секунды min_interval_s (0.34) не должны обнуляться
function T.test_child_sleep_keeps_fractions()
  local p = load_plugin{ token = "tok" }
  p.plugin:onSuspend()
  local made, slept, usl = nil, 0, 0
  package.loaded["riddle.sync"] = { run = function() return {} end }
  package.loaded["riddle.notion"] = { new = function(o) made = o; return {} end }
  package.loaded["riddle.http"] = { request = function() end }
  package.loaded["ffi/util"] = { sleep = function(s) slept = slept + s end, usleep = function(u) usl = usl + u end }
  p.runner.jobs[1].fn()
  made.sleep(2.34)
  t.eq(slept, 2)
  t.ok(math.abs(usl - 340000) < 2, "usleep " .. usl)
  package.loaded["riddle.sync"] = real_sync
end

-- ревью 0066e4d: worker.child_main останавливает GC (collectgarbage("stop")) — sync без GC на ~0,5 МБ
-- на страницу Notion уходит в OOM. fn синхронизации первым делом включает GC обратно
function T.test_child_restarts_gc_first()
  local p = load_plugin{ token = "tok" }
  p.plugin:onSuspend()
  local order = {}
  package.loaded["riddle.sync"] = { run = function() order[#order + 1] = "run" return {} end }
  package.loaded["riddle.notion"] = { new = function() order[#order + 1] = "notion" return {} end }
  package.loaded["riddle.http"] = { request = function() end }
  package.loaded["ffi/util"] = { sleep = function() end, usleep = function() end }
  local n0 = #p.gc
  p.runner.jobs[1].fn()
  t.eq(p.gc[n0 + 1], "restart", "первый вызов в дочернем — collectgarbage(\"restart\")")
  t.eq(order[1], "notion", "клиент — после включения GC")
  package.loaded["riddle.sync"] = real_sync
end

-- граница троттла: ровно 60 с после прошлой проверки — проверка снова
function T.test_idle_check_again_at_exactly_60s()
  local env = { token = "tok", last_ok = 100000 - 600, now = 10 }
  local p = load_plugin(env)
  p.plugin:openDiary()
  t.eq(p.opened.n, 1)
  env.now = 70
  p.widgets[1].on_idle()
  t.eq(p.opened.n, 2, "через 60 с хранилище перечитывается")
end

-- meta бросила — соединение всё равно закрыто, sync не стартует
function T.test_store_closed_when_meta_throws()
  local p = load_plugin{ token = "tok", meta_fails = true }
  p.plugin:openDiary()
  t.eq(p.opened.closed, 1, "соединение закрыто после сбоя meta")
  t.eq(#p.runner.jobs, 0)
end

-- выход или рестарт KOReader посреди sync: плагину о выходе не сообщают (UIManager:quit без событий),
-- дочерний сам перестаёт ходить в Notion, если родитель сменился (сирота) или вышел свой срок
local function child_request(env_over)
  local env = { token = "tok", now = 0 }
  for k, v in pairs(env_over or {}) do env[k] = v end
  local p = load_plugin(env)
  p.plugin:onSuspend()
  local made, calls = nil, 0
  local ppid = { 100 }
  package.loaded["riddle.sync"] = { run = function() return {} end }
  package.loaded["riddle.notion"] = { new = function(o) made = o return {} end }
  package.loaded["riddle.http"] = { request = function() calls = calls + 1 return 200, "{}", {} end }
  package.loaded["ffi/util"] = { sleep = function() end, usleep = function() end }
  local real_ffi = package.loaded["ffi"]
  package.loaded["ffi"] = { C = { getppid = function() return ppid[1] end } }
  package.loaded["ffi/posix_h"] = true
  p.runner.jobs[1].fn()
  package.loaded["riddle.sync"] = real_sync
  local function restore() package.loaded["ffi"] = real_ffi end
  return made, function() return calls end, ppid, env, restore
end

function T.test_child_request_passes_while_parent_alive()
  local made, calls, _, _, restore = child_request()
  local status = made.request("POST", "https://api.notion.com/v1/search", {}, "{}", 20)
  restore()
  t.eq(status, 200)
  t.eq(calls(), 1)
end

function T.test_orphan_child_stops_requests()
  local made, calls, ppid, _, restore = child_request()
  ppid[1] = 1
  local status, err = made.request("POST", "https://api.notion.com/v1/search", {}, "{}", 20)
  restore()
  t.eq(status, nil)
  t.eq(err, "parent gone")
  t.eq(calls(), 0, "сирота в сеть не ходит")
end

-- свой срок дочернего — те же 600 с, что и у runner: до него запросы идут (мутация 600 → 10 падает)
function T.test_child_requests_pass_until_600s()
  local made, calls, _, env, restore = child_request()
  env.now = 599
  local status = made.request("POST", "https://api.notion.com/v1/search", {}, "{}", 20)
  restore()
  t.eq(status, 200)
  t.eq(calls(), 1, "на 599-й секунде запрос уходит")
end

function T.test_child_stops_after_own_deadline()
  local made, calls, _, env, restore = child_request()
  env.now = 601
  local status, err = made.request("POST", "https://api.notion.com/v1/search", {}, "{}", 20)
  restore()
  t.eq(status, nil)
  t.eq(err, "deadline")
  t.eq(calls(), 0)
end

-- итог синхронизации — файлом для страницы состояния (формат и путь — riddle.sync)
local SYNC_LAST = real_sync.LAST_PATH

local function finished_sync(files, payload, err, env)
  env = env or {}
  env.token, env.files = "tok", files
  local p = load_plugin(env)
  p.plugin:onSuspend()
  p.runner:done(payload, err)
  return p
end

function T.test_sync_last_ok()
  local files = {}
  finished_sync(files, { updated = 3 })
  t.eq(files[SYNC_LAST], real_sync.last_line(100000, nil))
  t.eq(real_sync.parse_last(files[SYNC_LAST]).err, nil)
end

function T.test_sync_last_error_text()
  local files = {}
  finished_sync(files, nil, "timeout")
  t.eq(files[SYNC_LAST], real_sync.last_line(100000, "timeout"))
  files = {}
  finished_sync(files, { updated = 1, err = "parent gone" })
  t.eq(files[SYNC_LAST], real_sync.last_line(100000, "parent gone"))
end

function T.test_sync_last_is_overwritten_by_the_next_run()
  local files = {}
  finished_sync(files, { updated = 3 })
  finished_sync(files, nil, "timeout")
  t.eq(files[SYNC_LAST], real_sync.last_line(100000, "timeout"))
  t.ok(files[SYNC_LAST .. ".tmp"] == nil, "временного файла не остаётся")
end

function T.test_sync_last_is_written_through_tmp()
  local p = finished_sync({}, { updated = 3 })
  t.eq(table.concat(p.env.opened_for_write, ","), SYNC_LAST .. ".tmp")
end

-- сбой записи (полный FAT): прежний итог цел, синхронизация доложена как обычно, сбой записи — в логе
local function failed_write(env)
  local files = { [SYNC_LAST] = real_sync.last_line(99000, nil) }
  local p = finished_sync(files, { updated = 3 }, nil, env)
  t.eq(files[SYNC_LAST], real_sync.last_line(99000, nil), "прежний sync_last цел: негодный .tmp на место не встал")
  t.eq(count(p.LOG, "riddle: sync done"), 1, table.concat(p.LOG, "\n"))
  t.eq(count(p.LOG, "riddle: sync_last not written"), 1, table.concat(p.LOG, "\n"))
end

function T.test_sync_last_open_failure_keeps_previous()
  failed_write({ open_fails = true })
end

function T.test_sync_last_write_failure_keeps_previous()
  failed_write({ write_fails = true })
end

-- dev-рестарт (файл restart) — sync отменяется до restartKOReader
function T.test_dev_restart_cancels_sync()
  local files = { ["/mnt/us/riddle/devmode"] = true }
  local p = load_plugin{ token = "tok", files = files }
  p.plugin:maybeStartDevWatch()
  p.plugin:onSuspend()
  t.eq(p.runner:busy(), "sync")
  files["/mnt/us/riddle/restart"] = true
  local q = p.ui.queue
  p.ui.queue = {}
  for _, fn in ipairs(q) do fn() end
  t.eq(p.ui.restarts, 1)
  t.ok(p.runner:busy() == nil, "sync отменён перед рестартом")
end

t.run(T)
