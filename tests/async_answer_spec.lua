-- Ответ через runner (дочерний процесс) в виджете: страница уходит в runner сразу, цикл интерфейса
-- не ждёт; ответ приходит через on_done. Заглушки KOReader и часы — как в answer_cycle_spec.lua;
-- runner поддельный (ручной on_done), контроллер настоящий на поддельных deps.
local t = require("t")
local stand = require("seal_stand")
local texts = require("riddle.texts")
local controller = require("riddle.controller")
local llm = require("riddle.llm")

local clock, timeline, LOG = 0, {}, {}

local function stub(name, mod) package.preload[name] = function() return mod end end

local nop = function() end
local bb_stub = { fill = nop, free = nop }
stub("ffi/blitbuffer", { COLOR_WHITE = 0xFF, COLOR_BLACK = 0, TYPE_BB8 = 1, new = function() return bb_stub end })
stub("device", { isKindle = function() return false end, screen = {} })
stub("ffi/freetype", {})
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/rendertext", {
  getGlyph = function() return { ax = 10, l = 0, t = 0, bb = { getWidth = function() return 0 end, getHeight = function() return 0 end } } end,
})
stub("ui/uimanager", {
  scheduleIn = function(_, s, fn) timeline[#timeline + 1] = { at = clock + s, fn = fn } end,
  unschedule = function(_, fn)
    for i = #timeline, 1, -1 do if timeline[i].fn == fn then table.remove(timeline, i) end end
  end,
  nextTick = function(self, fn) self:scheduleIn(0, fn) end,
})
stub("ui/widget/widget", { extend = function(_, o) return o end })
stub("logger", {
  info = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    LOG[#LOG + 1] = table.concat(parts, " ")
  end,
  warn = nop, err = nop, dbg = nop,
})
stub("ui/time", { monotonic = function() return clock end, to_ms = function(x) return x * 1000 end,
                  to_us = function(x) return x * 1e6 end, to_s = function(x) return x end })
stub("libs/libkoreader-lfs", { attributes = nop, dir = nop })

local Diary = require("riddle_diarywidget")

local function run(s)
  local stop = clock + s
  while true do
    local k
    for i, task in ipairs(timeline) do
      if task.at <= stop and (not k or task.at < timeline[k].at) then k = i end
    end
    if not k then break end
    local task = table.remove(timeline, k)
    clock = task.at
    task.fn()
  end
  clock = stop
end

local function count(needle)
  local n = 0
  for _, line in ipairs(LOG) do if line:find(needle, 1, true) then n = n + 1 end end
  return n
end

local function in_list(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

-- поддельный runner: start запоминает задачу, done(payload, err) — её on_done вручную
local function fake_runner()
  local r = { started = 0, cancels = {}, jobs = {} }
  function r:start(kind, fn, opts)
    self.started = self.started + 1
    self.cur = { kind = kind, fn = fn, opts = opts }
    self.jobs[#self.jobs + 1] = self.cur
    return true
  end
  function r:busy() return self.cur and self.cur.kind or nil end
  function r:cancel(kind)
    self.cancels[#self.cancels + 1] = kind or "*"
    if self.cur and (not kind or self.cur.kind == kind) then self.cur = nil end
  end
  -- ответ задачи i (по умолчанию — последней): payload модели { result = … } или ошибка runner'а
  function r:done(payload, err, i)
    local job = self.jobs[i or #self.jobs]
    if self.cur == job then self.cur = nil end
    job.opts.on_done(payload, err)
  end
  return r
end

-- rules — правила печати (по умолчанию — по ключу); extra — свои deps поверх
local function ctl(rules, extra)
  local deps = {
    cfg = { seal = rules or stand.key() },
    memory = nil,
    read_file = function() return "PNG" end,
    b64 = function(s) return "B64" .. s end,
    remove = nop,
    now = function() return 1000 end,
    random = function() return 1 end,
    log = nop,
    llm_call = function() error("синхронный путь не должен вызываться") end,
    remote_fn = function() return function() return {} end end,
    absorb = function(payload) return payload.result, payload.err end,
  }
  for k, v in pairs(extra or {}) do deps[k] = v end
  return controller.new(deps)
end

-- контроллер с образцом ключа (stand.load_key): страница-ключ сдвигает печать. Только тестам ключа — образец из роз
-- владельца, и с ним роза карты стала бы ключом
local function keyed(rules, extra)
  extra = extra or {}
  extra.load_key = stand.load_key
  return ctl(rules, extra)
end

local function reply(read, text) return { result = { read = read, reply = text } } end

local function diary()
  clock, timeline, LOG = 0, {}, {}
  Diary.map_kept = nil -- память карты о героях — в таблице модуля (срез 12): тест не видит прежних
  local d = setmetatable({
    canvas = bb_stub, tasks = {}, queue = {}, asks = {}, inflight = 0, strokes = {}, epoch = 0, w = 758, h = 1024,
    prompt = { rect = { x = 0, y = 0, w = 0, h = 0 } },
    face_answer = { ftsize = { getHeightAndAscender = function() return 52, 40 end } },
    stats = { frames = 0, frame_us = 0, frame_us_max = 0, sink_ticks = 0, sink_us = 0, sink_us_max = 0,
              ans_steps = 0, ans_us_max = 0, grey_px = 0, lost_ink = 0 },
    controller = ctl(),
    runner = fake_runner(),
    revealed = {},
  }, { __index = Diary })
  d.renderRegion = nop
  d.penNear = function() return false end
  d.countLostInk = function() return 0 end
  d.saveSample = function() return "/tmp/page.png" end
  d.revealAnswer = function(self, text, ...)
    self.revealed[#self.revealed + 1] = text
    return Diary.revealAnswer(self, text, ...)
  end
  d.responder = function(png, cb) d:respond(png, cb) end
  return d
end

-- страница дописана: strokes — её штрихи (по умолчанию нет — чернила уже растворились)
local function page_done(d, strokes)
  d.page = { strokes = strokes or {}, ink = { 10, 200, 100, 260 } }
  d:onPageDone()
end

-- страница-ключ (настоящий key_page): печать сдвигается без модели, фраза — на место страницы в очереди
local function key_page(d)
  page_done(d, stand.key_strokes(Diary.CFG.dissolve.steps))
end

local T = {}

-- сон и пробуждение (регресс «ответ после сна»): виджет без счётчика шагов проявления и приглашения
local function wired()
  local d = diary()
  d.steps, d.invite = 0, 0
  d.answerStep = function() d.steps = d.steps + 1 end
  d.showInvitation = function() d.invite = d.invite + 1 end
  require("ui/uimanager").setDirty = nop
  return d
end

-- ответ пришёл, но ждёт растворения чернил своей страницы (в queue) -> сон -> пробуждение:
-- ответ стёртой страницы не проявляется
function T.test_queued_answer_dropped_by_sleep()
  local d = wired()
  local st = { t_end = clock, lvl = 0, p = { 20, 220 } }
  d.strokes = { st }
  page_done(d, { st })
  d.runner:done(reply("кто ты", "в очереди"))
  t.eq(#d.queue, 1, "ответ стоит в queue")
  t.eq(#d.revealed, 0)
  d:onSuspend()
  t.eq(#d.queue, 0, "сон чистит queue")
  run(5)
  d:onResume()
  st.lvl = 99 -- чернила той страницы «растворились»: старый ответ, оставшись в queue, вышел бы теперь
  d:nextAnswer()
  run(60)
  t.eq(#d.revealed, 0, "после пробуждения старый ответ не всплывает")
  t.eq(d.steps, 0)
  t.eq(d.invite, 1, "на экране приглашение")
end

-- ответ на середине проявления -> сон, который закрывает печать (on_sleep): ни одной буквы ни после onSuspend, ни
-- после onResume
function T.test_revealing_answer_stops_at_sleep()
  local d = wired()
  d.controller = ctl(stand.rules({ key = true, on_sleep = true }))
  page_done(d)
  d.runner:done(reply("кто ты", "Длинный ответ из многих букв"))
  run(0.15)
  local a = d.answer
  local before = a and a.i or 0
  t.ok(before > 0 and a.phase == "reveal", "проявление идёт: " .. before)
  d:onSuspend()
  t.eq(d.answer, nil)
  run(60)
  t.eq(a.i, before, "после сна букв нет")
  d:onResume()
  run(60)
  t.eq(a.i, before, "после пробуждения тоже")
  t.eq(d.answer, nil)
  t.eq(#d.revealed, 1, "ответ не проявляется заново")
end

-- поздний on_done после onResume (ответ страницы, стёртой сном) — «answer dropped», не на экран
function T.test_late_answer_after_resume_dropped()
  local d = wired()
  page_done(d)
  d:onSuspend()
  d:onResume()
  -- настоящий Runner после cancel on_done не зовёт (worker_spec); здесь — принудительно
  d.runner:done(reply("кто ты", "поздний"), nil, 1)
  run(60)
  t.eq(#d.revealed, 0)
  t.eq(d.steps, 0)
  t.eq(d.inflight, 0, "счётчик страниц в пути не уходит в минус")
  t.eq(count("riddle: answer dropped, its page is gone"), 1)
end

function T.test_async_respond_returns_before_answer()
  local d = diary()
  page_done(d)
  t.eq(d.runner.started, 1, "страница ушла в runner")
  t.eq(d.runner.jobs[1].kind, "answer")
  t.eq(d.runner.jobs[1].opts.timeout_s, 30, "жёсткий потолок 30 с")
  t.eq(d.inflight, 1)
  t.eq(#d.revealed, 0, "ответа ещё нет")
  run(5)
  t.eq(#d.revealed, 1, "без on_done — только фраза-раздумье (срез 2)")
  t.ok(in_list(texts.thinking, d.revealed[1]), tostring(d.revealed[1]))
  d.runner:done(reply("кто ты", "Мои страницы молчат."))
  run(10)
  t.eq(d.inflight, 0)
  t.eq(d.revealed[2], "Мои страницы молчат.")
  t.eq(count("riddle: worker answer done in"), 1, table.concat(LOG, "\n"))
end

function T.test_async_sends_without_ink_wait()
  local d = diary()
  -- последний штрих страницы только что поднят: прежний путь ждал растворения его чернил (inkLeft)
  page_done(d, { { t_end = clock, lvl = 0, p = { 20, 220 } } })
  t.eq(d.runner.started, 1, "start в том же такте, что onPageDone")
end

-- ответ пришёл — следующая страница уходит в модель, даже если перо снова на странице
-- (ожидание поднятия пера нужно было только блокирующему пути); страница, законченная, пока ответ
-- в пути, получает отказ — ponder_spec.lua
function T.test_next_page_after_answer_goes_to_runner()
  local d = diary()
  page_done(d)
  d.runner:done(reply("кто ты", "первый"))
  t.eq(d.inflight, 0)
  page_done(d)
  t.eq(d.runner.started, 2, "вторая ушла после ответа на первую")
  d.runner:done(reply("кто ты", "второй"))
  run(60)
  t.eq(d.revealed[1], "первый")
  t.eq(d.revealed[2], "второй")
  t.eq(d.inflight, 0)
end

-- очередь asks/pumpAsks: путь в неё открыт, когда runner есть, а контроллера нет (main.lua:
-- getController() вернул nil) — отказ «страница во время раздумья» требует ctl, и вторая страница
-- встаёт в asks. Контракт: пока ответ на первую в пути, вторая в responder не уходит; ответ первой
-- отпускает вторую
function T.test_second_page_waits_while_answer_busy()
  local d = diary()
  d.controller = nil
  local calls = {}
  d.responder = function(png, cb) calls[#calls + 1] = cb end
  page_done(d)
  page_done(d)
  t.eq(#calls, 1, "вторая ждёт, пока занят ответ на первую")
  t.eq(d.inflight, 2)
  t.eq(#d.asks, 1, "вторая стоит в очереди")
  calls[1]("первый", false)
  t.eq(#calls, 2, "после ответа на первую уходит вторая")
  t.eq(#d.asks, 0)
  t.eq(d.inflight, 1)
  calls[2]("второй", false)
  run(60)
  t.eq(d.revealed[1], "первый")
  t.eq(d.revealed[2], "второй")
  t.eq(d.inflight, 0)
end

function T.test_suspend_cancels_answer_child()
  local d = diary()
  page_done(d)
  d:onSuspend()
  t.ok(in_list(d.runner.cancels, "answer"), "сон убивает дочерний ответа")
  d.runner:done(reply("кто ты", "поздний"), nil, 1)
  run(60)
  t.eq(#d.revealed, 0, "поздний ответ ничего не показывает")
  t.eq(d.inflight, 0)
  page_done(d)
  t.eq(d.runner.started, 2, "после сна новая страница уходит сразу")
end

function T.test_close_cancels_answer_child()
  local d = diary()
  page_done(d)
  d:onCloseWidget()
  t.ok(in_list(d.runner.cancels, "answer"), "закрытие убивает дочерний ответа")
  d.runner:done(reply("кто ты", "поздний"), nil, 1)
  run(60)
  t.eq(#d.revealed, 0)
end

function T.test_runner_failure_gives_fail_text()
  local d = diary()
  page_done(d)
  d.runner:done(nil, "crashed")
  run(60)
  t.ok(in_list(texts.fail_other, d.revealed[1]), tostring(d.revealed[1]))
  t.eq(count("riddle: worker answer failed: crashed"), 1, table.concat(LOG, "\n"))
end

function T.test_runner_start_refused_gives_fail_text()
  local d = diary()
  local tries = 0
  d.runner.start = function() tries = tries + 1 return nil, "spawn: fork failed" end
  page_done(d)
  t.eq(tries, 1, "страница шла в runner")
  run(60)
  t.ok(in_list(texts.fail_other, d.revealed[1]), tostring(d.revealed[1]))
  t.eq(d.inflight, 0)
end

function T.test_async_unlock_schedules_followup()
  local d = diary()
  d.controller = keyed()
  key_page(d)
  t.ok(d.controller.seal_open)
  t.ok(in_list(texts.welcomes, d.revealed[1]), tostring(d.revealed[1]))
  t.eq(#d.runner.jobs, 0, "ключ модель не зовёт")
  t.ok(d.followup_task, "после приветствия запланирован пересказ")
end

-- пересказ прошлой сессии — тоже в runner (вид "summary"): разблокировка и цикл интерфейса его не ждут,
-- пересказ сохраняется, когда придёт ответ дочернего
local function summary_memory(saved)
  return {
    use_persona = function() return true end, session = function() return 2, 1 end,
    entries = function() return { { role = "owner", text = "запись" }, { role = "diary", text = "ответ" } } end,
    set_summary = function(_, sid, text) saved[#saved + 1] = { sid = sid, text = text } end,
  }
end

function T.test_async_followup_summary_goes_to_runner()
  local d = diary()
  d.controller = keyed()
  local saved = {}
  d.controller.deps.memory = summary_memory(saved)
  key_page(d)
  run(120)
  local job = d.runner.jobs[#d.runner.jobs]
  t.eq(#d.runner.jobs, 1, "пересказ — единственный запрос: ключ модель не зовёт")
  t.eq(job.kind, "summary", "пересказ ушёл в runner")
  t.ok(job.opts.timeout_s > 0, "у пересказа свой потолок")
  t.eq(#saved, 0, "разблокировка не ждёт пересказа")
  d.runner:done({ result = { text = "Мне писали о прошлом." } })
  t.eq(#saved, 1, "пересказ сохранён по ответу дочернего")
  t.eq(saved[1].sid, 1)
  t.eq(saved[1].text, "Мне писали о прошлом.")
end

-- свёртка выпавшего из окна — тем же хвостом в runner ("summary"), после ответа на страницу без разблокировки.
-- state.total — сколько несвёрнутых реплик в сессии
local function roll_memory(state, rolled)
  return {
    use_persona = function() return true end, session = function() return 1, nil end,
    add = function() end,
    entries = function() return {} end,
    recent = function() return {} end,
    summaries = function() return {} end,
    lore_text = function() return "" end,
    rollup = function() return nil, 0 end,
    unrolled = function(_, _, limit)
      local list = {}
      for i = 1, math.min(limit or state.total, state.total) do
        list[i] = { id = i, role = i % 2 == 1 and "owner" or "diary", text = "р" .. i }
      end
      return list, state.total
    end,
    set_rollup = function(_, sid, text, upto) rolled[#rolled + 1] = { sid = sid, text = text, upto = upto }; return true end,
  }
end

function T.test_async_roll_goes_to_runner()
  local d = diary()
  d.controller = keyed()
  local state, rolled = { total = 0 }, {}
  d.controller.deps.memory = roll_memory(state, rolled)
  key_page(d)
  run(120)
  t.eq(#d.runner.jobs, 0, "после разблокировки сворачивать нечего")
  state.total = 40
  page_done(d)
  d.runner:done(reply("запись", "ответ"))
  run(120)
  local job = d.runner.jobs[#d.runner.jobs]
  t.eq(#d.runner.jobs, 2, "ответ, свёртка")
  t.eq(job.kind, "summary", "свёртка ушла в runner хвостом")
  t.eq(count("seal open (roll)"), 1, "хвост свёртки в логе — не разблокировка: " .. table.concat(LOG, "\n"))
  t.eq(count("(unlocked)"), 0, "разблокировка — страница-ключ, не ответ")
  t.ok(job.opts.timeout_s > 0, "у свёртки потолок дочернего")
  t.eq(#rolled, 0, "ответ не ждёт свёртки")
  d.runner:done({ result = { text = "С" } })
  t.eq(#rolled, 1, "свёртка сохранена по ответу дочернего")
  t.eq(rolled[1].sid, 1)
  t.eq(rolled[1].text, "С")
  t.eq(rolled[1].upto, 20, "upto — последняя из 20 свёрнутых")
end

-- runner занят (чтение Notion, ответ): пересказ ждёт, пока освободится, и не отменяет чужую задачу
function T.test_async_followup_waits_for_busy_runner()
  local d = diary()
  d.controller = keyed()
  local saved = {}
  d.controller.deps.memory = summary_memory(saved)
  key_page(d)
  d.runner.cur = { kind = "sync" }
  run(120)
  t.eq(#d.runner.jobs, 0, "пока runner занят, пересказ не стартует")
  t.eq(#d.runner.cancels, 0, "чужую задачу не отменяет")
  d.runner.cur = nil
  run(5)
  t.eq(d.runner.jobs[#d.runner.jobs].kind, "summary", "runner свободен — пересказ ушёл")
end

-- таймаут или вытеснение ответом — пересказ не сохраняется
function T.test_async_followup_failure_not_saved()
  local d = diary()
  d.controller = keyed()
  local saved = {}
  d.controller.deps.memory = summary_memory(saved)
  key_page(d)
  run(120)
  d.runner:done(nil, "cancelled")
  t.eq(#saved, 0)
  t.eq(count("riddle: worker summary failed: cancelled"), 1, table.concat(LOG, "\n"))
end

-- Review Focus 1, таймер простоя: страница начата при открытой печати, простой закрыл печать, пока ответ в пути, —
-- ответ не показывается, на экране первая строка чистой страницы. Часы контроллера идут с планировщиком
function T.test_timer_closes_and_drops_in_flight()
  local d = diary()
  d.controller = keyed(stand.rules({ key = true, minutes = 30 }), {
    now = function() return 1000 + math.floor(clock) end,
    memory = roll_memory({ total = 0 }, {}),
  })
  d.invite = 0
  d.showInvitation = function() d.invite = d.invite + 1 end
  key_page(d) -- открыта в 1000: от неё отсчёт простоя
  run(1700 - clock)
  page_done(d)
  t.eq(d.inflight, 1, "страница при открытой печати ушла в модель")
  run(110)
  t.ok(not d.controller.seal_open, "простой закрыл печать, пока ответ в пути")
  t.ok(d.answer == nil or d.answer.kind == "think", "на экране не реплика открытой печати (раздумье — заготовка)")
  t.eq(d.invite, 1, "первая строка чистой страницы")
  d.runner:done(reply("мои дела", "СЕКРЕТ"))
  run(120)
  for _, s in ipairs(d.revealed) do t.ok(s ~= "СЕКРЕТ", "ответ открытой печати не показан") end
  t.eq(d.inflight, 0, "страница больше не ждёт")
  t.eq(count("riddle: answer dropped, its page is gone"), 0, "ответ сброшен контроллером, не сбросом страницы")
end

-- срез 3: перо отменяет фоновое чтение Notion (дочерний "sync"), ответ не трогает
function T.test_pen_down_cancels_sync()
  local d = diary()
  d.canvas = { fill = nop, free = nop, paintRect = nop }
  d.markDirty = nop
  d.runner.cur = { kind = "sync" }
  d:penDown(300, 500)
  t.ok(in_list(d.runner.cancels, "sync"), "касание убивает дочерний sync")
  t.ok(not in_list(d.runner.cancels, "answer"), "касание не трогает ответ")
  t.ok(not in_list(d.runner.cancels, "*"), "отмена только вида sync")
end

-- настоящий riddle.worker поверх поддельного sys: дочерний не форкается, его вывод (конверт в pipe)
-- задаёт тест через sys.reply; sys.killed — pid'ы, которые runner убил
local function worker_runner()
  local json = require("dkjson")
  local sys = { procs = {}, killed = {} }
  function sys.spawn()
    sys.procs[#sys.procs + 1] = { dead = false }
    return #sys.procs, #sys.procs
  end
  function sys.done(pid) return sys.procs[pid].dead end
  function sys.has_data(fd) return sys.procs[fd].out ~= nil end
  function sys.read_all(fd)
    local s = sys.procs[fd].out or ""
    sys.procs[fd].out = nil
    return s
  end
  function sys.kill(pid)
    local p = sys.procs[pid]
    if not p.dead then
      p.dead = true
      sys.killed[#sys.killed + 1] = pid
    end
  end
  function sys.reply(pid, payload)
    local p = sys.procs[pid]
    if p.dead then return end -- убитый дочерний ничего не допишет
    p.out, p.dead = json.encode({ ok = payload }), true
  end
  local UIManager = require("ui/uimanager")
  local runner = require("riddle.worker").new{ sys = sys, clock = function() return clock end,
    schedule = function(s, fn) UIManager:scheduleIn(s, fn) end }
  return runner, sys
end

-- разблокировка через настоящий runner, пока пересказ не ушёл в дочерний -> pid пересказа
local function unlock_until_summary(d, sys)
  key_page(d)
  for _ = 1, 60 do
    if d.runner:busy() == "summary" then return #sys.procs end
    run(1)
  end
  error("пересказ не стартовал: " .. table.concat(LOG, "\n"))
end

local function summary_diary()
  local d = wired()
  d.controller = keyed(stand.rules({ key = true, on_sleep = true })) -- сон закрывает печать
  local saved = {}
  d.controller.deps.memory = summary_memory(saved)
  local sys
  d.runner, sys = worker_runner()
  d.canvas = { fill = nop, free = nop, paintRect = nop }
  d.markDirty = nop
  return d, sys, saved
end

-- после сна печать снова закрыта: следующая разблокировка спрашивает пересказ заново и сохраняет его
local function summary_asked_again(d, sys, saved, old_pid)
  d:onResume()
  local pid = unlock_until_summary(d, sys)
  t.ok(pid ~= old_pid, "пересказ спрошен заново новым дочерним")
  sys.reply(pid, { result = { text = "Мне писали о прошлом." } })
  run(1)
  t.eq(#saved, 1, "повторный пересказ сохранён")
  t.eq(saved[1].sid, 1)
end

-- касание пером во время пересказа убивает его дочерний (процессор PW2 — перу); пересказ не сохраняется
-- и повторяется на следующей разблокировке
function T.test_pen_down_cancels_summary()
  local d, sys, saved = summary_diary()
  local pid = unlock_until_summary(d, sys)
  d:penDown(300, 500)
  t.ok(in_list(sys.killed, pid), "касание убивает дочерний пересказ")
  t.eq(d.runner:busy(), nil, "runner свободен")
  sys.reply(pid, { result = { text = "поздний пересказ" } })
  run(60)
  t.eq(#saved, 0, "убитый пересказ не сохранён")
  t.eq(count("riddle: worker summary failed"), 0, "on_done убитого не зовётся")
  d:onSuspend()
  summary_asked_again(d, sys, saved, pid)
end

-- сон во время пересказа убивает его дочерний: runner свободен для чтения Notion по сну (main.lua)
function T.test_suspend_cancels_summary()
  local d, sys, saved = summary_diary()
  local pid = unlock_until_summary(d, sys)
  d:onSuspend()
  t.ok(in_list(sys.killed, pid), "сон убивает дочерний пересказ")
  t.eq(d.runner:busy(), nil, "runner свободен для sync по сну")
  run(60)
  t.eq(#saved, 0, "убитый пересказ не сохранён")
  summary_asked_again(d, sys, saved, pid)
end

-- без пера и сна пересказ через настоящий runner доходит и сохраняется, как раньше
function T.test_summary_without_pen_reaches_memory()
  local d, sys, saved = summary_diary()
  local pid = unlock_until_summary(d, sys)
  run(5)
  t.eq(#sys.killed, 0, "никого не убили")
  sys.reply(pid, { result = { text = "Мне писали о прошлом." } })
  run(1)
  t.eq(#saved, 1)
  t.eq(saved[1].text, "Мне писали о прошлом.")
end

-- касание во время ответа не трогает ответ (настоящий runner)
function T.test_pen_down_keeps_answer()
  local d, sys = summary_diary()
  page_done(d)
  d:penDown(300, 500)
  t.eq(d.runner:busy(), "answer", "ответ в дочернем жив")
  t.eq(#sys.killed, 0)
end

-- срез 3: пустой экран — виджет зовёт on_idle (плагин решает, читать ли Notion)
function T.test_idle_calls_on_idle()
  local d = diary()
  local n = 0
  d.on_idle = function() n = n + 1 end
  d:maybeIdle()
  t.eq(n, 1, "on_idle на пустом экране")
end

function T.test_no_on_idle_while_answer_pending()
  local d = diary()
  local n = 0
  d.on_idle = function() n = n + 1 end
  page_done(d)
  d:maybeIdle()
  t.eq(n, 0, "ответ в пути — не простой")
end

function T.test_idle_without_on_idle_is_fine()
  local d = diary()
  d:maybeIdle()
  t.ok(true)
end

-- сбой on_idle не роняет виджет
function T.test_on_idle_error_is_caught()
  local d = diary()
  d.on_idle = function() error("boom") end
  local ok = pcall(d.maybeIdle, d)
  t.ok(ok, "ошибка on_idle наружу не вышла")
end

-- печати нет: на чистой странице — приветствие из texts.greetings, а не белый экран
-- (91ab2a7 убрал строку-приглашение без печати и ничего не поставил взамен)
function T.test_greeting_instead_of_invitation_without_seal()
  local d = diary()
  d.controller = controller.new{ cfg = { seal = stand.none() }, random = function() return 1 end, log = nop }
  local s = d:invitationText()
  t.ok(in_list(texts.greetings, s), tostring(s))
end

function T.test_invitation_with_seal()
  local d = diary()
  t.eq(d:invitationText(), texts.invitation)
end

function T.test_invitation_without_controller()
  local d = diary()
  d.controller = nil
  t.eq(d:invitationText(), texts.invitation)
end

-- ревью a5d8720: поведением, а не текстом исходника — без печати showInvitation строит слой с
-- фразой из texts.greetings; два открытия подряд — разные приветствия (мешок контроллера)
local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function shown_line(d)
  local out, prev_base = {}, nil
  for _, g in ipairs(d.prompt.glyphs) do
    if g.word_start and #out > 0 then out[#out + 1] = " " end
    out[#out + 1] = utf8_char(g.cp)
    prev_base = g.base
  end
  return table.concat(out)
end

local function open_unsealed(random)
  local d = diary()
  d.face_prompt = { ftsize = { getHeightAndAscender = function() return 52, 40 end } }
  d.controller = controller.new{ cfg = { seal = stand.none() }, random = random or function() return 1 end,
                                 log = nop }
  return d
end

function T.test_show_invitation_without_seal_draws_greeting()
  local d = open_unsealed()
  d:showInvitation(true)
  t.ok(d.prompt.layer, "слой строки построен")
  local s = shown_line(d)
  t.ok(in_list(texts.greetings, s), "на странице — приветствие: " .. s)
  t.eq(count("riddle: invitation at line"), 1)
end

function T.test_show_invitation_with_seal_draws_invitation()
  local d = diary()
  d.face_prompt = { ftsize = { getHeightAndAscender = function() return 52, 40 end } }
  d:showInvitation(true)
  t.eq(shown_line(d), texts.invitation)
end

function T.test_two_opens_give_different_greetings()
  local d = open_unsealed(function(n) return n end)
  d:showInvitation(true)
  local first = shown_line(d)
  d.prompt = {}
  d:showInvitation(true)
  local second = shown_line(d)
  t.ok(in_list(texts.greetings, second), second)
  t.ok(first ~= second, "второе открытие — другое приветствие: " .. first)
end

-- «чей это дневник» (спека 2026-10-31): персона по строке конфига генерируется хвостом в runner («summary»)
-- со своим потолком CFG.gen_ceil_s; отменённый раздел — снова, следующим хвостом
local GEN_PERSONA = "{\"head\":\"дневник Гермионы.\",\"body\":\"ГОЛОС.\",\"lang\":\"ru\",\"lang_name\":\"русский\"," ..
  "\"gender\":\"f\",\"kind\":\"дневник\",\"title\":\"Дневник Гермионы\"," ..
  "\"invitation\":\"Кто открыл мой дневник?\"}"
local GEN_WORLD = "Хогвартс: замок, библиотека, Гриффиндор."

-- годный набор фраз: 36 разных, prefix различает наборы
local function gen_set(prefix)
  local list = {}
  for i = 1, 36 do list[i] = prefix .. " номер " .. i .. "." end
  return list
end

-- ask: строки нет ни в конфиге, ни в базе — дневник спрашивает «Чей это дневник?» (план, задача 8)
local function gen_diary(whose, ask)
  require("sqlite_shim")
  local d = diary()
  local path = os.tmpname()
  d.gen_path = path
  d.controller = controller.new{
    cfg = { whose = not ask and (whose or "Гермиона Грейнджер") or nil, seal = stand.none() },
    memory = require("riddle.memory").open(path),
    read_file = function() return "PNG" end,
    b64 = function(s) return "B64" .. s end,
    remove = nop,
    now = function() return 1000 end,
    random = function() return 1 end,
    log = nop,
    file_mtime = nop,
    lore_path = "/lore.md",
    llm_call = function() error("синхронный путь не должен вызываться") end,
    remote_fn = function() return function() return {} end end,
    absorb = function(payload) return payload.result, payload.err end,
    load_key = stand.load_key,
  }
  -- строка уже разобрана (state = "ready"): генерация начинается с раздела persona
  local line = whose or "Гермиона Грейнджер"
  if not ask and not require("riddle.persona").is_methods(line) then
    d.controller.deps.memory:add_persona{ key = require("riddle.persona").key(line), line = line, source = "config",
      state = "ready", ts = 1000 }
  end
  return d
end

function T.test_gen_starts_at_open_and_resumes_after_cancel()
  local d = gen_diary()
  d:maybeStartGen()
  run(120)
  t.eq(#d.runner.jobs, 1, "генерация ушла в runner без страницы")
  local job = d.runner.jobs[1]
  t.eq(job.kind, "summary", "вид дочернего — фоновый: перо и сон его убивают, ответ вытесняет")
  t.eq(job.opts.timeout_s, Diary.CFG.gen_ceil_s, "свой потолок генерации")
  d.runner:done(nil, "cancelled")
  run(120)
  t.eq(#d.runner.jobs, 2, "отменённый раздел — снова, следующим хвостом")
  d.runner:done(nil, "timeout")
  run(120)
  t.eq(#d.runner.jobs, 2, "сбой — пауза до следующей страницы")
  os.remove(d.gen_path)
end

-- Notion 41013e60-bc8d-8131: дневник закрыли, пока шёл хвост (закрытие убивает только ответ); его on_done приходит
-- после закрытия с «генерация ещё нужна» — итог хвоста контроллер получает, но закрытый виджет хвостов не ставит
function T.test_closed_diary_does_not_schedule_next_followup()
  local d = gen_diary()
  local ctl = d.controller
  d:maybeStartGen()
  run(120)
  t.eq(#d.runner.jobs, 1, "генерация в runner")
  t.ok(ctl.followup_job, "идущий хвост держит контроллер")
  d:onCloseWidget()
  d.runner:done(nil, "cancelled")
  t.eq(ctl.followup_job, nil, "итог хвоста дошёл до контроллера (finish_followup)")
  t.ok(ctl:gen_due(), "генерация всё ещё нужна — её поднимет следующее открытие")
  t.eq(d.followup_task, nil, "на закрытом виджете хвост не запланирован")
  t.eq(#timeline, 0, "таймеров закрытого виджета нет")
  run(120)
  t.eq(#d.runner.jobs, 1, "новых заданий нет")
  os.remove(d.gen_path)
end

-- Notion 41013e60-bc8d-810c: «генерацию, которая ещё нужна, поднимает следующее открытие». Дневник открывают заново
-- с теми же controller и runner (они живут весь процесс); часы и таймеры общие, счётчики заданий — runner'а
local function reopen(old)
  local clk, tl, lg = clock, timeline, LOG
  local d = diary() -- сбрасывает часы и лог: возвращаем
  clock, timeline, LOG = clk, tl, lg
  d.controller, d.runner, d.gen_path = old.controller, old.runner, old.gen_path
  return d
end

-- хвост шёл, дневник закрыли, хвост кончился отменой; новый дневник на тех же controller и runner ставит следующий
function T.test_reopened_diary_raises_followup_after_closed_one_was_cancelled()
  local d = gen_diary()
  local ctl = d.controller
  d:maybeStartGen()
  run(120)
  t.eq(#d.runner.jobs, 1, "генерация в runner")
  d:onCloseWidget()
  d.runner:done(nil, "cancelled")
  t.eq(ctl.followup_job, nil, "итог хвоста у контроллера")
  t.eq(d.followup_task, nil, "закрытый виджет следующего не ставит")
  run(120)
  t.eq(#d.runner.jobs, 1, "закрытый дневник нового хвоста не запускает")
  local d2 = reopen(d)
  d2:maybeStartGen()
  t.ok(d2.followup_task, "открытие поставило хвост")
  run(120)
  t.eq(#d2.runner.jobs, 2, "следующий хвост ушёл в runner")
  t.ok(ctl.followup_job, "хвост снова держит контроллер")
  os.remove(d.gen_path)
end

-- дневник открыли заново, пока хвост закрытого ещё в runner: новый виджет ждёт, после on_done старого — ровно один хвост
function T.test_reopened_diary_waits_for_closed_followup_then_one_next()
  local d = gen_diary()
  local ctl = d.controller
  d:maybeStartGen()
  run(120)
  d:onCloseWidget()
  local d2 = reopen(d)
  d2:maybeStartGen()
  run(120)
  t.eq(#d2.runner.jobs, 1, "runner занят хвостом закрытого: новых заданий нет")
  t.ok(ctl.followup_job, "хвост закрытого всё ещё у контроллера")
  d.runner:done(nil, "cancelled") -- on_done хвоста закрытого дневника
  t.eq(d.followup_task, nil, "закрытый виджет следующего не ставит")
  run(120)
  t.eq(#d2.runner.jobs, 2, "ровно один следующий хвост — от нового виджета")
  d2.runner:done(nil, "cancelled") -- on_done хвоста нового виджета: следующий ставит он, не закрытый
  t.ok(d2.followup_task, "новый виджет ставит следующий хвост")
  t.eq(d.followup_task, nil, "закрытый по-прежнему не ставит")
  run(120)
  t.eq(#d2.runner.jobs, 3, "и он ушёл в runner")
  os.remove(d.gen_path)
end

-- порядок в настоящем Diary:init: canvas есть к моменту maybeStartGen, иначе scheduleFollowup на открытии молчит.
-- Виджет собирается настоящим init; заглушки — только экран и шрифт (stub-таблицы общие для файла: возвращаем как были)
function T.test_init_builds_canvas_before_generation_starts()
  local d = gen_diary()
  local screen, ft = require("device").screen, require("ffi/freetype")
  local saved = { screen.getWidth, screen.getHeight, ft.newFaceSize }
  screen.getWidth, screen.getHeight = function() return 758 end, function() return 1024 end
  ft.newFaceSize = function() return d.face_answer.ftsize end
  d.canvas, d.showInvitation = nil, nop
  d.trayShow = nop -- угол рисует настоящий холст (tray_widget_spec.lua); здесь холст — заглушка без пикселей
  local ok, err = pcall(Diary.init, d)
  screen.getWidth, screen.getHeight, ft.newFaceSize = saved[1], saved[2], saved[3]
  -- снять input-хуки и gc-pause init'а раньше утверждений: упавшее не должно протечь в следующие тесты
  local has_canvas, due, task = d.canvas ~= nil, d.controller:gen_due(), d.followup_task ~= nil
  run(120)
  local jobs = #d.runner.jobs
  d:onCloseWidget()
  os.remove(d.gen_path)
  t.ok(ok, "init отработал: " .. tostring(err))
  t.ok(has_canvas, "canvas построен")
  t.ok(due, "генерация нужна")
  t.ok(task, "открытие поставило хвост генерации")
  t.eq(jobs, 1, "хвост ушёл в runner")
end

-- тот же хвост в открытом дневнике: следующий ставится и уходит
function T.test_open_diary_schedules_next_followup()
  local d = gen_diary()
  d:maybeStartGen()
  run(120)
  d.runner:done(nil, "cancelled")
  t.ok(d.followup_task, "следующий хвост запланирован")
  run(120)
  t.eq(#d.runner.jobs, 2, "следующий хвост ушёл в runner")
  os.remove(d.gen_path)
end

function T.test_gen_done_stops_chain()
  local json = require("dkjson")
  local d = gen_diary()
  d:maybeStartGen()
  run(120)
  d.runner:done({ result = { text = GEN_PERSONA } })
  run(120)
  d.runner:done({ result = { text = GEN_WORLD } }) -- второй раздел — мир
  run(120)
  local sets = 0
  while d.runner:busy() and sets < #texts.SETS do -- наборы фраз: цепочкой, хвост за хвостом
    sets = sets + 1
    d.runner:done({ result = { text = json.encode(gen_set("Набор " .. sets)) } })
    run(120)
  end
  t.eq(sets, #texts.SETS, "после персоны и мира — все наборы")
  local MP = require("fixtures.map_parts")
  t.ok(d.runner:busy(), "после наборов — данные карты")
  d.runner:done({ result = { text = MP.map_json } })
  run(120)
  d.runner:done({ result = { text = MP.cast_json } })
  run(120)
  t.eq(#d.runner.jobs, 2 + #texts.SETS + 2, "разделов больше нет — хвостов нет")
  t.eq(#d.revealed, 0, "конец генерации дневник не озвучивает")
  t.ok(not d.controller:gen_due())
  os.remove(d.gen_path)
end

-- строки нет (план, задача 8): страница — ответ на «Чей это дневник?»; названный персонаж — вопрос на экране; «да» —
-- строка сохранена, и генерация идёт сама (хвост после ответа), без новой страницы
function T.test_ask_yes_starts_generation_chain()
  local d = gen_diary(nil, true)
  t.ok(in_list(texts.neutral.ru.ask, d.controller:opening_text()), "на чистой странице — вопрос")
  d:maybeStartGen()
  run(120)
  t.eq(#d.runner.jobs, 0, "генерировать нечего, пока не сказали чей")
  page_done(d)
  t.eq(d.runner.jobs[1].kind, "answer", "страница — в модель")
  d.runner:done({ result = { read = "Гермиона", who = "Гермиона Грейнджер", world = "Хогвартс", lang = "ru",
    reply = "Так это дневник Гермионы Грейнджер из Хогвартса?" } })
  run(120)
  t.eq(d.revealed[1], "Так это дневник Гермионы Грейнджер из Хогвартса?", "вопрос с миром")
  t.eq(#d.runner.jobs, 1, "до «да» генерации нет")
  page_done(d)
  d.runner:done({ result = { read = "да", reply = "x", yes = true, lang = "ru" } })
  run(120)
  t.ok(in_list(texts.neutral.ru.later, d.revealed[2] or ""), "после «да» — «позже»: " .. tostring(d.revealed[2]))
  local kinds = {}
  for _, j in ipairs(d.runner.jobs) do kinds[#kinds + 1] = j.kind end
  t.eq(table.concat(kinds, ","), "answer,answer,summary", "после «да» пошла генерация персонажа")
  os.remove(d.gen_path)
end

-- страница до готовности (план, задача 6): читается моделью без образа (prompt.setup), на экране — «позже», после неё
-- генерация продолжается (пауза снята)
function T.test_page_before_ready_later_then_gen_goes_on()
  local d = gen_diary()
  d:maybeStartGen()
  run(120)
  d.runner:done(nil, "timeout") -- пауза
  page_done(d)
  t.eq(d.runner.jobs[2].kind, "answer", "страница — в модель")
  d.runner:done(reply("ЗАПИСЬ", "x"))
  run(120)
  t.ok(in_list(texts.neutral.en.later, d.revealed[1] or ""), "«позже» (нейтральный голос, язык персонажа ещё не известен — en): " .. tostring(d.revealed[1]))
  local kinds = {}
  for _, j in ipairs(d.runner.jobs) do kinds[#kinds + 1] = j.kind end
  t.eq(table.concat(kinds, ","), "summary,answer,summary", "после ответа генерация пошла снова")
  os.remove(d.gen_path)
end

-- конец генерации дневник не озвучивает (владелец 2026-10-25: «сам он не может активироваться»): запись посреди
-- генерации получает одно «позже», последний раздел — ни реплики, очередь ответов пуста
function T.test_generation_done_diary_stays_silent()
  local json = require("dkjson")
  local d = gen_diary()
  d:maybeStartGen()
  run(120)
  d.runner:done({ result = { text = GEN_PERSONA } })
  run(120)
  page_done(d) -- запись, пока идёт мир: ответ вытесняет генерацию
  t.eq(d.runner.jobs[#d.runner.jobs].kind, "answer", "страница — в модель")
  d.runner:done(nil, "cancelled", 2) -- вытесненный раздел
  d.runner:done(reply("ЗАПИСЬ", "x"))
  run(120)
  t.eq(#d.revealed, 1, "одна реплика на запись")
  t.ok(in_list(texts.neutral.ru.later, d.revealed[1] or ""), tostring(d.revealed[1]))
  local MP = require("fixtures.map_parts")
  local sections = 0
  while d.runner:busy() and sections < 20 do
    sections = sections + 1
    local text = sections == 1 and GEN_WORLD or sections <= 1 + #texts.SETS and json.encode(gen_set("Набор " .. sections))
      or sections == 2 + #texts.SETS and MP.map_json or MP.cast_json
    d.runner:done({ result = { text = text } })
    run(120)
  end
  t.eq(sections, 1 + #texts.SETS + 2, "мир, все наборы и данные карты")
  t.ok(not d.controller:gen_due(), "генерация кончилась")
  t.eq(#d.revealed, 1, "конец генерации не озвучен")
  t.eq(#d.queue, 0, "очередь ответов пуста")
  os.remove(d.gen_path)
end

-- первый запуск без сети (план, задача 6): строка персонажа есть, ничего не сгенерировано, ни один канал не включён —
-- нейтральная фраза «нет сети»: язык персонажа ещё не известен (строка не разобрана) — английская, не пусто
function T.test_offline_first_run_neutral_phrase()
  for _, case in ipairs({ { "Гермиона Грейнджер", "en" }, { "R2-D2 from Star Wars", "en" } }) do
    local d = gen_diary(case[1])
    package.loaded["ui/network/manager"] = { isWifiOn = function() return false end,
      isConnected = function() return false end }
    t.eq(require("riddle.net").state(), "off")
    page_done(d)
    run(120)
    package.loaded["ui/network/manager"] = nil
    local shown = d.revealed[1]
    t.ok(shown and shown ~= "", case[2] .. ": не пусто")
    t.ok(in_list(texts.neutral[case[2]].offline, shown or ""), case[2] .. ": " .. tostring(shown))
    os.remove(d.gen_path)
  end
end

-- готовая персона: раздумье, отказ и реплика на перебивание — из её наборов (Controller:texts), не «Методов»
function T.test_busy_and_thinking_from_controller_pools()
  local json = require("dkjson")
  local d = gen_diary()
  local mem = d.controller.deps.memory
  d.controller:gen_due() -- строка персонажа заведена
  local row = mem:persona_by_key(require("riddle.persona").key("Гермиона Грейнджер"))
  mem:set_part(row.id, "persona", GEN_PERSONA, 1)
  mem:set_part(row.id, "world", GEN_WORLD, 1)
  for _, n in ipairs({ "thinking", "busy" }) do mem:set_part(row.id, "texts." .. n, json.encode(gen_set(n)), 1) end
  page_done(d)
  t.eq(d.runner.jobs[#d.runner.jobs].kind, "answer", "персона готова — страница в модель")
  run(5)
  t.ok(in_list(gen_set("thinking"), d.revealed[1] or ""), "раздумье персоны: " .. tostring(d.revealed[1]))
  page_done(d)
  run(10)
  t.ok(in_list(gen_set("busy"), d.revealed[2] or ""), "отказ персоны: " .. tostring(d.revealed[2]))
  os.remove(d.gen_path)
end

-- ревью ba4087a: персона готова со всеми наборами — фраза каждого набора, которую видит пишущий, берётся из её
-- набора. Строка таблицы: набор, печать по ключу (nil — без печати), действие пишущего -> показанные фразы. Место,
-- что берёт пул «Методов» мимо ctl:texts(), даёт фразу не из набора персоны
local CASES = {
  { "thinking", nil, function(d) page_done(d); run(5) end },
  { "busy", nil, function(d) page_done(d); page_done(d); run(10) end },
  { "interrupted", nil, function(d)
    d.page = { strokes = {}, ink = { 10, 200, 100, 260 }, interrupted = true } -- перо перебило ответ (penDown)
    d:onPageDone()
    run(10)
  end },
  { "sleepy", nil, function(d) d:respond(nil, function(text) d.revealed[#d.revealed + 1] = text end) end },
  { "greetings", nil, function(d) d.revealed[1] = d:invitationText() end },
  { "welcomes", true, function(d)
    key_page(d); run(120)
  end },
  { "unreadable", nil, function(d) page_done(d); d.runner:done(reply("?", "")); run(120) end },
  { "unreadable", true, function(d) page_done(d); d.runner:done(reply("?", "")); run(120) end },
  { "fail_offline", nil, function(d) page_done(d); d.runner:done(nil, "gemini: offline"); run(120) end },
  { "fail_slow", nil, function(d) page_done(d); d.runner:done(nil, "timeout"); run(120) end },
  { "fail_limit", nil, function(d) page_done(d); d.runner:done(nil, "gemini: http 429"); run(120) end },
  { "fail_daily", nil, function(d) page_done(d); d.runner:done(nil, (llm.DAILY or "?") .. "gemini: http 429"); run(120) end },
  { "fail_other", nil, function(d) page_done(d); d.runner:done(nil, "crashed"); run(120) end },
  { "tasks_source_unclear", nil, function(d)
    page_done(d)
    d.runner:done({ result = { read = "Дела в покупках", reply = "Запомню.", tasks_source = "покупки" } })
    run(120)
  end },
}

function T.test_every_set_shown_from_persona()
  local json = require("dkjson")
  local covered = {}
  for _, c in ipairs(CASES) do covered[c[1]] = true end
  for _, s in ipairs(texts.SETS) do t.ok(covered[s.name], "строка таблицы на набор " .. s.name) end
  for _, c in ipairs(CASES) do
    local name, sealed, act = c[1], c[2], c[3]
    local d = gen_diary()
    local deps = d.controller.deps
    deps.cfg.seal = sealed and stand.key() or stand.none()
    -- «покупки» подходят к двум книгам дел — переспрос
    deps.knowledge_text = function()
      return nil, nil, nil, { collections = { { id = "c2", title = "ПОКУПКИ НА НЕДЕЛЮ" },
        { id = "c3", title = "ПОКУПКИ В ДОМ" } } }
    end
    deps.set_tasks_source = function() return true end
    d.controller = controller.new(deps) -- печать — по cfg на создании
    local mem = deps.memory
    local key = require("riddle.persona").key("Гермиона Грейнджер")
    mem:add_persona{ key = key, line = "Гермиона Грейнджер", source = "config", state = "ready" }
    local row = mem:persona_by_key(key)
    mem:set_part(row.id, "persona", GEN_PERSONA, 1)
    mem:set_part(row.id, "world", GEN_WORLD, 1)
    for _, s in ipairs(texts.SETS) do
      mem:set_part(row.id, "texts." .. s.name, json.encode(gen_set("Набор " .. s.name)), 1)
    end
    act(d)
    local mine = gen_set("Набор " .. name)
    local hit
    for _, s in ipairs(d.revealed) do
      t.ok(not in_list(texts[name], s), name .. ": фраза «Методов» мимо набора персоны: " .. s)
      if in_list(mine, s) then hit = true end
    end
    t.ok(hit, name .. ": фразы набора нет на экране: " .. table.concat(d.revealed, " | "))
    os.remove(d.gen_path)
  end
end

-- ревью 6a37853 (B1): перо убивает генерацию без on_done (finish_followup не зовётся, цепочка рвётся); хвост
-- старта без печати уже израсходован — следующая страница поднимает хвост одной генерацией
function T.test_gen_restarts_after_pen_cancel_once_start_followup_spent()
  local d = gen_diary()
  d.canvas = { fill = nop, free = nop, paintRect = nop }
  d.markDirty = nop
  d.controller.followup_due = false -- хвост старта уже израсходован
  d:maybeStartGen()
  run(120)
  t.eq(#d.runner.jobs, 1, "генерация ушла в runner")
  d:penDown(300, 500)
  t.eq(d.runner:busy(), nil, "перо убило генерацию")
  d.cur = nil
  page_done(d) -- первая страница: читается без образа, хвост поднимает одна генерация
  t.eq(d.runner.jobs[2].kind, "answer", "страница — в модель (prompt.setup)")
  d.runner:done(reply("ЗАПИСЬ", "x"))
  run(120)
  t.eq(#d.runner.jobs, 3, "первая страница — генерация снова")
  t.eq(d.runner.jobs[3].kind, "summary")
  d:penDown(300, 500)
  t.eq(d.runner:busy(), nil, "перо снова убило генерацию")
  d.cur = nil
  page_done(d) -- вторая страница: и снова одна генерация
  d.runner:done(reply("ЗАПИСЬ", "x"))
  run(120)
  t.eq(#d.runner.jobs, 5, "вторая страница — генерация снова")
  t.eq(d.runner.jobs[5].kind, "summary")
  os.remove(d.gen_path)
end

-- ревью 6a37853: страница без задания (фраза сбоя) берёт у контроллера хвост только ради генерации персоны;
-- пересказ прошлой сессии и свёртка ждут настоящего ответа
function T.test_fail_phrase_takes_followup_for_gen_only()
  local d = gen_diary()
  d.controller.deps.read_file = function() error("диск") end
  local ctl = d.controller
  ctl.followup_due, ctl.roll_due = true, true
  local text, due
  d:respond("/tmp/page.png", function(tx, un) text, due = tx, un end)
  t.ok(in_list(ctl:texts("fail_other"), text), "фраза сбоя: " .. tostring(text))
  t.eq(due, true, "хвост поднят ради генерации персоны")
  t.eq(ctl.followup_due, true, "пересказ ждёт настоящего ответа")
  t.eq(ctl.roll_due, true, "свёртка ждёт настоящего ответа")
  os.remove(d.gen_path)
end

-- ревью 15b91ff: хвост, взятый ради генерации (страница без задания), строит только её задание. Между respond и
-- началом хвоста генерация отпала (пауза после сбоя) — хвост пуст: пересказ прошлой сессии и свёртка ждут настоящего
-- ответа, а не уходят в нейросеть вперёд него (Notion 41013e60-bc8d-8165)
function T.test_gen_only_tail_builds_nothing_once_gen_is_not_due()
  local persona = require("riddle.persona")
  local d = gen_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  local row = mem:persona_by_key(persona.key("Гермиона Грейнджер"))
  mem:use_persona(row.id)
  local old = mem:session(1000)
  mem:add(old, "owner", "ЗАПИСЬ-ПРОШЛОЙ-СЕССИИ", 1000)
  ctl.deps.now = function() return 1000 + 5 * 3600 end -- прошлая сессия без пересказа: он назрел бы
  ctl.deps.read_file = function() error("диск") end
  local text, due
  d:respond("/tmp/page.png", function(tx, un)
    text, due = tx, un
    if un then d:scheduleFollowup() end -- как revealAnswer
  end)
  t.ok(in_list(ctl:texts("fail_other"), text), "фраза сбоя: " .. tostring(text))
  t.eq(due, true, "хвост поднят ради генерации персоны")
  ctl.gen_hold = true -- пока хвост ждал показа, генерация упала: пауза до следующей страницы
  run(120)
  t.eq(#d.runner.jobs, 0, "задания нет: ни генерации, ни пересказа прошлой сессии, ни свёртки")
  os.remove(d.gen_path)
end

-- и пока генерация нужна, хвост того же вида — задание генерации
function T.test_gen_only_tail_builds_gen_job_while_gen_is_due()
  local d = gen_diary()
  local ctl = d.controller
  ctl.deps.read_file = function() error("диск") end
  d:respond("/tmp/page.png", function(_, un) if un then d:scheduleFollowup() end end)
  run(120)
  t.eq(#d.runner.jobs, 1, "задание ушло")
  t.eq(d.runner.jobs[1].kind, "summary", "вид дочернего — фоновый")
  t.ok(ctl:gen_due() and not ctl.gen_hold, "это генерация персоны")
  os.remove(d.gen_path)
end

-- намерение «хвост ради генерации» живёт до начала хвоста и не переживает сон: хвост после пробуждения — обычный
function T.test_gen_only_tail_does_not_outlive_sleep()
  local persona = require("riddle.persona")
  local d = gen_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  mem:use_persona(mem:persona_by_key(persona.key("Гермиона Грейнджер")).id)
  mem:add(mem:session(1000), "owner", "ЗАПИСЬ-ПРОШЛОЙ-СЕССИИ", 1000)
  ctl.deps.now = function() return 1000 + 5 * 3600 end
  t.eq(ctl:take_followup(true), true, "генерация нужна")
  ctl:on_sleep()
  ctl.gen_hold = true
  local job = ctl:begin_followup()
  t.eq(job and job.kind, "session", "после сна хвост обычный: пересказ прошлой сессии")
  os.remove(d.gen_path)
end

-- ревью 4d91906 (Notion 41013e60-bc8d-81a0): хвост первой страницы взят ради генерации и ждёт занятый runner;
-- генерация в нём падает (пауза); вторая страница — снова сбой чтения, генерация уже не нужна. Отложенный хвост
-- первой страницы остаётся хвостом ради генерации: пустым, а не пересказом прошлой сессии вперёд настоящего ответа
function T.test_gen_only_tail_survives_next_gen_only_page_after_gen_fails()
  local persona = require("riddle.persona")
  local d = gen_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  mem:use_persona(mem:persona_by_key(persona.key("Гермиона Грейнджер")).id)
  mem:add(mem:session(1000), "owner", "ЗАПИСЬ-ПРОШЛОЙ-СЕССИИ", 1000)
  ctl.deps.now = function() return 1000 + 5 * 3600 end -- прошлая сессия без пересказа: он назрел бы
  d:maybeStartGen()
  run(120)
  t.eq(#d.runner.jobs, 1, "генерация в runner")
  ctl.deps.read_file = function() error("диск") end
  local dues = {}
  local function page()
    d:respond("/tmp/page.png", function(_, un)
      dues[#dues + 1] = un
      if un then d:scheduleFollowup() end -- как revealAnswer
    end)
  end
  page()
  t.eq(dues[1], true, "первая страница: хвост ради генерации, ждёт runner")
  d.runner:done(nil, "timeout") -- генерация упала: пауза до следующей прочитанной страницы
  page()
  t.eq(dues[2], false, "вторая страница: генерация не нужна")
  run(120)
  t.eq(#d.runner.jobs, 1, "отложенный хвост пуст: ни пересказа прошлой сессии, ни свёртки до настоящего ответа")
  os.remove(d.gen_path)
end

-- намерение «хвост ради генерации» одноразовое: его гасит начало хвоста. Следующий хвост, поставленный цепочкой
-- генерации (finish_followup -> true, без take_followup), — обычный: генерация к его началу встала — пересказ
-- прошлой сессии, а не пустой хвост
function T.test_gen_only_intent_spent_by_tail_start()
  local persona = require("riddle.persona")
  local d = gen_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  mem:use_persona(mem:persona_by_key(persona.key("Гермиона Грейнджер")).id)
  mem:add(mem:session(1000), "owner", "ЗАПИСЬ-ПРОШЛОЙ-СЕССИИ", 1000)
  ctl.deps.now = function() return 1000 + 5 * 3600 end
  t.eq(ctl:take_followup(true), true, "генерация нужна")
  local job = ctl:begin_followup()
  t.eq(job and job.kind, "gen", "хвост ради генерации — её задание")
  t.eq(ctl:finish_followup(job, nil, "cancelled"), true, "отменённый раздел — цепочкой, следующим хвостом")
  ctl.gen_hold = true -- генерация встала, пока цепной хвост ждал
  job = ctl:begin_followup()
  t.eq(job and job.kind, "session", "цепной хвост обычный: пересказ прошлой сессии")
  os.remove(d.gen_path)
end

-- разделы персоны row, кроме самой персоны, уже сгенерированы: раздел persona — последний
local function gen_rest(mem, row)
  local json = require("dkjson")
  mem:set_part(row.id, "world", GEN_WORLD, 1)
  for _, s in ipairs(texts.SETS) do
    mem:set_part(row.id, "texts." .. s.name, json.encode(gen_set("Набор " .. s.name)), 1)
  end
  require("fixtures.map_parts").seed(mem, row.id, 1)
end

-- настоящий ответ гасит намерение «хвост ради генерации»: хвост первой страницы (сбой чтения) ждёт runner, генерация
-- в нём доходит до конца, вторая страница прочитана — хвост обычный, пересказ прошлой сессии уходит
function T.test_real_answer_turns_waiting_gen_only_tail_into_full_one()
  local persona = require("riddle.persona")
  local d = gen_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  local row = mem:persona_by_key(persona.key("Гермиона Грейнджер"))
  mem:use_persona(row.id)
  mem:add(mem:session(1000), "owner", "ЗАПИСЬ-ПРОШЛОЙ-СЕССИИ", 1000)
  ctl.deps.now = function() return 1000 + 5 * 3600 end
  d:maybeStartGen()
  run(120)
  t.eq(#d.runner.jobs, 1, "генерация в runner")
  local read_file = ctl.deps.read_file
  ctl.deps.read_file = function() error("диск") end
  local dues = {}
  local function page()
    d:respond("/tmp/page.png", function(_, un)
      dues[#dues + 1] = un
      if un then d:scheduleFollowup() end -- как revealAnswer
    end)
  end
  page()
  t.eq(dues[1], true, "первая страница: хвост ради генерации, ждёт runner")
  gen_rest(mem, row) -- раздел в runner — последний
  d.runner:done({ result = { text = GEN_PERSONA } })
  t.ok(not ctl:gen_due(), "генерация кончилась")
  ctl.deps.read_file = read_file
  page()
  t.eq(d.runner.jobs[#d.runner.jobs].kind, "answer", "вторая страница — в модель")
  d.runner:done(reply("ЗАПИСЬ", "x"))
  t.eq(dues[2], true, "настоящий ответ: хвост")
  run(120)
  t.eq(#d.runner.jobs, 3, "хвост ушёл")
  t.eq(d.runner.jobs[3].kind, "summary", "пересказ прошлой сессии")
  os.remove(d.gen_path)
end

-- хвост, уже взятый настоящим ответом, страница без задания не понижает до хвоста ради генерации (Notion
-- 41013e60-bc8d-817c): понизь его — и пересказ прошлой сессии уйдёт лишь хвостом следующего настоящего ответа
local function past_session_diary()
  local persona = require("riddle.persona")
  local d = gen_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  mem:use_persona(mem:persona_by_key(persona.key("Гермиона Грейнджер")).id)
  mem:add(mem:session(1000), "owner", "ЗАПИСЬ-ПРОШЛОЙ-СЕССИИ", 1000)
  ctl.deps.now = function() return 1000 + 5 * 3600 end -- прошлая сессия без пересказа: он назрел
  local dues = {}
  -- страница: ok — прочитана (ответ модели), иначе сбой чтения (страница без задания)
  d.page_read = function(ok)
    local read_file = ctl.deps.read_file
    if not ok then ctl.deps.read_file = function() error("диск") end end
    d:respond("/tmp/page.png", function(_, un)
      dues[#dues + 1] = un
      if un then d:scheduleFollowup() end -- как revealAnswer
    end)
    ctl.deps.read_file = read_file
    if ok then d.runner:done(reply("ЗАПИСЬ", "x")) end
  end
  return d, dues
end

function T.test_gen_only_page_keeps_waiting_full_tail_full()
  local d, dues = past_session_diary()
  d.page_read(true)
  t.eq(dues[1], true, "настоящий ответ: обычный хвост")
  d.page_read(false)
  t.eq(dues[2], true, "страница без задания: генерация нужна")
  d.controller.gen_hold = true -- генерация встала, пока хвост ждал
  run(120)
  t.eq(#d.runner.jobs, 2, "ждущий обычный хвост ушёл")
  t.eq(d.runner.jobs[2].kind, "summary", "пересказ прошлой сессии")
  os.remove(d.gen_path)
end

-- и настоящий ответ, сам хвоста не взявший (повода нет), гасит ждущий хвост ради генерации: тот строится обычным
function T.test_real_answer_without_tail_lowers_waiting_gen_only_tail()
  local persona = require("riddle.persona")
  local d, dues = past_session_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  ctl.followup_due = false -- хвост старта уже израсходован
  d:maybeStartGen()
  run(120)
  t.eq(#d.runner.jobs, 1, "генерация в runner")
  d.page_read(false)
  t.eq(dues[1], true, "страница без задания: хвост ради генерации, ждёт runner")
  gen_rest(mem, mem:persona_by_key(persona.key("Гермиона Грейнджер")))
  d.runner:done({ result = { text = GEN_PERSONA } }) -- последний раздел: генерация кончилась
  d.page_read(true)
  t.eq(dues[2], false, "настоящий ответ: повода для хвоста нет")
  run(120)
  t.eq(#d.runner.jobs, 3, "ждущий хвост ушёл обычным")
  t.eq(d.runner.jobs[3].kind, "summary", "пересказ прошлой сессии")
  os.remove(d.gen_path)
end

-- закрытие дневника роняет таймер ждущего хвоста: хвост не начнётся, и его вид гаснет вместе с ним. Иначе взятый
-- до закрытия обычный хвост переживает его, и страница без задания после открытия ставит хвост, который строит
-- пересказ прошлой сессии раньше настоящего ответа
function T.test_close_drops_waiting_full_tail()
  local d, dues = past_session_diary()
  local ctl = d.controller
  d.page_read(true)
  t.eq(dues[1], true, "настоящий ответ: обычный хвост")
  d:onCloseWidget()
  local d2 = diary() -- дневник открыт снова, контроллер тот же
  d2.controller = ctl
  ctl.deps.read_file = function() error("диск") end
  local due
  d2:respond("/tmp/page.png", function(_, un)
    due = un
    if un then d2:scheduleFollowup() end -- как revealAnswer
  end)
  t.eq(due, true, "страница без задания: генерация нужна")
  ctl.gen_hold = true -- генерация встала, пока хвост ждал
  run(120)
  t.eq(#d2.runner.jobs, 0, "хвост ради генерации пуст: пересказ ждёт настоящего ответа")
  os.remove(d.gen_path)
end

-- страница без задания, когда генерация не нужна, хвоста ради генерации не заводит (ревью 129201b, мутант M3):
-- следующий хвост без take_followup (цепочка генерации, открытие) — обычный, пересказ прошлой сессии
function T.test_gen_only_page_without_due_gen_leaves_tail_alone()
  local d = past_session_diary()
  local ctl = d.controller
  ctl.gen_hold = true -- генерация не нужна: пауза после сбоя
  t.eq(ctl:take_followup(true), false, "хвоста нет")
  local job = ctl:begin_followup()
  t.eq(job and job.kind, "session", "хвост обычный: пересказ прошлой сессии")
  os.remove(d.gen_path)
end

-- пересказ, взятый хвостом, теряется до сна, только начавшись (Notion 41013e60-bc8d-8178). Дневник закрыт до начала
-- хвоста: таймер упал, хвост не начался — пересказ прошлой сессии достаётся первому настоящему ответу после открытия
function T.test_close_before_tail_start_keeps_summary_for_next_answer()
  local persona = require("riddle.persona")
  local d, dues = past_session_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  local row = mem:persona_by_key(persona.key("Гермиона Грейнджер"))
  gen_rest(mem, row)
  mem:set_part(row.id, "persona", GEN_PERSONA, 1) -- генерация кончилась: хвост берёт только пересказ
  d.page_read(true)
  t.eq(dues[1], true, "настоящий ответ: хвост (пересказ прошлой сессии)")
  d:onCloseWidget()
  local d2 = diary() -- дневник открыт снова, контроллер тот же
  d2.controller = ctl
  local due
  d2:respond("/tmp/page.png", function(_, un)
    due = un
    if un then d2:scheduleFollowup() end -- как revealAnswer
  end)
  d2.runner:done(reply("ЗАПИСЬ", "x"))
  t.eq(due, true, "первый настоящий ответ после открытия: хвост")
  run(120)
  t.eq(#d2.runner.jobs, 2, "хвост ушёл")
  t.eq(d2.runner.jobs[2].kind, "summary", "пересказ прошлой сессии")
  os.remove(d.gen_path)
end

-- обычный хвост при нужной генерации строит только её: пересказ прошлой сессии ждёт и уходит хвостом первого
-- настоящего ответа после конца генерации
function T.test_full_tail_spent_on_gen_keeps_summary_for_next_answer()
  local persona = require("riddle.persona")
  local d, dues = past_session_diary()
  local mem = d.controller.deps.memory
  d.page_read(true)
  t.eq(dues[1], true, "настоящий ответ: обычный хвост")
  run(120)
  t.eq(#d.runner.jobs, 2, "хвост ушёл генерацией")
  gen_rest(mem, mem:persona_by_key(persona.key("Гермиона Грейнджер")))
  d.runner:done({ result = { text = GEN_PERSONA } }) -- последний раздел: генерация кончилась
  d.page_read(true)
  t.eq(dues[2], true, "первый настоящий ответ после генерации: хвост")
  run(120)
  t.eq(#d.runner.jobs, 4, "хвост ушёл")
  t.eq(d.runner.jobs[4].kind, "summary", "пересказ прошлой сессии")
  os.remove(d.gen_path)
end

-- ответ, сам хвоста не взявший, ждущий обычный хвост не гасит (ревью, мутант N8: «elseif tail == "gen"» -> «else»):
-- иначе страница без задания понижает его до хвоста ради генерации, и пересказ прошлой сессии не строится
function T.test_answer_without_tail_keeps_waiting_full_tail()
  local d, dues = past_session_diary()
  local ctl = d.controller
  ctl.followup_due = false -- хвост старта израсходован: обычный хвост берёт одна генерация
  d.page_read(true)
  t.eq(dues[1], true, "настоящий ответ: обычный хвост")
  ctl.gen_hold = true -- генерация встала
  d:respond(nil, function(_, un) dues[#dues + 1] = un end) -- ответ без страницы (сонная фраза)
  t.eq(dues[2], false, "ответ без страницы: повода для хвоста нет")
  t.ok(ctl:forget_persona(), "персона стёрта (файл forget_persona): пауза генерации снята")
  d.page_read(false)
  t.eq(dues[3], true, "страница без задания: генерация снова нужна")
  ctl.gen_hold = true -- и снова встала, пока хвост ждал
  run(120)
  t.eq(#d.runner.jobs, 2, "ждущий обычный хвост ушёл")
  t.eq(d.runner.jobs[2].kind, "summary", "пересказ прошлой сессии")
  os.remove(d.gen_path)
end

-- хвост, начавшийся у персоны без своей памяти, поводы пересказа и свёртки тратит: пересказывать чужие сессии
-- нельзя, а повод остался бы — и каждый следующий ответ брал бы пустой хвост (мутант M6: сброс поводов после
-- проверки памяти). Память пропадает к началу хвоста: у персоны без памяти настоящих ответов нет вовсе
function T.test_tail_without_own_memory_spends_its_reasons()
  local persona = require("riddle.persona")
  local d, dues = past_session_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  d.page_read(true)
  t.eq(dues[1], true, "настоящий ответ: хвост")
  run(120)
  t.eq(#d.runner.jobs, 2, "хвост ушёл генерацией")
  gen_rest(mem, mem:persona_by_key(persona.key("Гермиона Грейнджер")))
  d.runner:done({ result = { text = GEN_PERSONA } }) -- последний раздел: генерация кончилась
  d.page_read(true)
  t.eq(dues[2], true, "ответ после генерации: хвост с пересказом прошлой сессии")
  t.eq(#d.runner.jobs, 3)
  local memory_on = true
  local use_persona = mem.use_persona
  mem.use_persona = function(self, id) return use_persona(self, id) and memory_on end
  memory_on = false
  run(120)
  t.eq(#d.runner.jobs, 3, "у персоны без памяти хвост ничего не взял")
  memory_on = true
  d.page_read(true)
  t.eq(dues[3], false, "поводы потрачены: следующий ответ хвост не берёт")
  run(120)
  t.eq(#d.runner.jobs, 4, "в runner только сам ответ")
  os.remove(d.gen_path)
end

-- пересказ, взятый хвостом, терялся до сна, если начатый хвост отменён до результата (Notion 41013e60-bc8d-81e5):
-- его поводы погашены началом хвоста, а итога нет. Отмена возвращает поводы — пересказ прошлой сессии строит хвост
-- следующего настоящего ответа. Сбой (таймаут, модель) — нет: стабильно падающий вызов шёл бы на каждой странице
-- настоящий ответ взял хвост (пересказ прошлой сессии), таймер хвоста ещё не сработал
local function summary_tail_taken()
  local persona = require("riddle.persona")
  local d, dues = past_session_diary()
  local ctl = d.controller
  local mem = ctl.deps.memory
  local row = mem:persona_by_key(persona.key("Гермиона Грейнджер"))
  gen_rest(mem, row)
  mem:set_part(row.id, "persona", GEN_PERSONA, 1) -- генерация кончилась: хвост берёт только пересказ
  d.canvas = { fill = nop, free = nop, paintRect = nop }
  d.markDirty = nop
  d.page_read(true)
  t.eq(dues[1], true, "настоящий ответ: хвост")
  return d, dues, mem
end

local function summary_tail_started()
  local d, dues, mem = summary_tail_taken()
  run(120)
  t.eq(#d.runner.jobs, 2, "хвост начался: пересказ прошлой сессии в runner")
  return d, dues, mem
end

-- хвост пересказа доходит до результата: пересказ прошлой сессии сохранён
local function summary_saved_by(d, runner, mem)
  t.eq(runner.jobs[#runner.jobs].kind, "summary", "хвост ушёл")
  runner:done({ result = { text = "ПЕРЕСКАЗ ПРОШЛОЙ СЕССИИ" } })
  t.eq(table.concat(mem:summaries(5), "|"), "ПЕРЕСКАЗ ПРОШЛОЙ СЕССИИ", "пересказ прошлой сессии сохранён")
  os.remove(d.gen_path)
end

-- дневник закрыт, пока пересказ в runner; после открытия ответ вытесняет его (worker: on_done "cancelled")
function T.test_tail_cancelled_after_close_keeps_summary_for_next_answer()
  local d, _, mem = summary_tail_started()
  d:onCloseWidget()
  local d2 = diary() -- дневник открыт снова: контроллер и runner (один на процесс KOReader) те же
  d2.controller, d2.runner = d.controller, d.runner
  local due
  d2:respond("/tmp/page.png", function(_, un)
    due = un
    if un then d2:scheduleFollowup() end -- как revealAnswer
  end)
  d2.runner:done(nil, "cancelled", 2) -- ответ вытеснил пересказ
  d2.runner:done(reply("ЗАПИСЬ", "x"))
  t.eq(due, true, "первый настоящий ответ после отмены: хвост")
  run(120)
  t.eq(#d2.runner.jobs, 4, "ответ, пересказ, ответ, пересказ снова")
  summary_saved_by(d, d2.runner, mem)
end

-- сбой модели на пересказе поводов не возвращает: следующий ответ хвоста не берёт, пересказ ждёт сна
function T.test_tail_failed_by_llm_waits_for_sleep()
  local d, dues, mem = summary_tail_started()
  d.runner:done({ err = "http 429" })
  d.page_read(true)
  t.eq(dues[2], false, "следующий ответ: хвоста нет, вызов модели не тратится")
  d:onSuspend()
  d.page_read(true)
  t.eq(dues[3], true, "после сна: хвост")
  run(120)
  t.eq(#d.runner.jobs, 5, "ответ, пересказ, ответ, ответ, пересказ снова")
  summary_saved_by(d, d.runner, mem)
end

-- перо убивает идущий пересказ (runner:cancel, его on_done не зовётся) — это тоже отмена: повод пересказа
-- возвращается хвосту следующего ответа, а не ждёт сна (ревью w1 67d5e45..daada9c, F1)
function T.test_pen_cancelled_tail_keeps_summary_for_next_answer()
  local d, dues, mem = summary_tail_started()
  d:penDown(300, 500)
  t.eq(d.runner:busy(), nil, "перо убило пересказ")
  d.cur = nil
  d.page_read(true)
  t.eq(dues[2], true, "следующий настоящий ответ: хвост")
  run(120)
  t.eq(#d.runner.jobs, 4, "ответ, пересказ, ответ, пересказ снова")
  summary_saved_by(d, d.runner, mem)
end

-- пересказ, начатый до закрытия дневника, живёт в runner (он, как и контроллер, — на весь процесс KOReader); перо
-- в открытом заново дневнике убивает его — повод пересказа цел (ревью w1 18334d4, п.1)
function T.test_pen_after_reopen_keeps_summary_for_next_answer()
  local d, _, mem = summary_tail_started()
  d:onCloseWidget()
  local d2 = reopen(d) -- дневник открыт снова: контроллер, runner и лента таймеров те же
  d2.canvas = { fill = nop, free = nop, paintRect = nop }
  d2.markDirty = nop
  d2:penDown(300, 500)
  t.eq(d2.runner:busy(), nil, "перо убило пересказ")
  d2.cur = nil
  local due
  d2:respond("/tmp/page.png", function(_, un)
    due = un
    if un then d2:scheduleFollowup() end -- как revealAnswer
  end)
  d2.runner:done(reply("ЗАПИСЬ", "x"))
  t.eq(due, true, "после открытия и пера: хвост следующего ответа")
  run(120)
  t.eq(#d2.runner.jobs, 4, "ответ, пересказ, ответ, пересказ снова")
  summary_saved_by(d, d2.runner, mem)
end

-- хвост с итогом снят: перо и сон после итога отменять нечего — повод не возвращается, хвост не повторяется
-- (ревью w1 18334d4, R2–R3)
function T.test_pen_after_tail_result_returns_no_reason()
  local d, dues = summary_tail_started()
  d.runner:done({ result = { text = "ПЕРЕСКАЗ ПРОШЛОЙ СЕССИИ" } })
  d:penDown(300, 500)
  d:penDown(300, 500) -- и вторая отмена ничего не меняет
  d.cur = nil
  d.page_read(true)
  t.eq(dues[2], false, "пересказ готов: следующий ответ хвоста не берёт")
  os.remove(d.gen_path)
end

-- страница пишется (после штриха idle_s до её конца): хвост не стартует — ответ на эту страницу вытеснил бы его,
-- повод вернулся бы, и так на каждой странице (ревью w1 67d5e45..daada9c, F2)
function T.test_tail_waits_while_page_is_being_written()
  local d = summary_tail_taken()
  d:penDown(300, 500)
  for i = 1, 20 do d:penMove(300 + 10 * i, 500 + 5 * i) end
  d:penUp()
  run(2) -- таймер хвоста (followup_s) сработал, страница ещё не кончилась (idle_s)
  t.eq(#d.runner.jobs, 1, "пока пишется страница, хвост не стартует")
  run(1) -- страница кончилась: её ответ — первым
  t.eq(d.runner.jobs[2] and d.runner.jobs[2].kind, "answer", "ответ на страницу, не хвост")
  os.remove(d.gen_path)
end

---------------------------------------------------------------------------
-- карта мародёров, срез 1: роза ветров на странице при открытой печати открывает пустой пергамент, роза на нём —
-- закрывает. Страница-роза не уходит ни в модель, ни в память; ответ в пути проявится раньше карты

local F = require("fixtures.rose_strokes")

-- штрихи фикстуры как штрихи страницы, чернила уже растворились
local function strokes_of(name)
  local out = {}
  for i, s in ipairs(F[name]) do out[i] = { p = s.p, lvl = Diary.CFG.dissolve.steps } end
  return out
end

-- виджет с холстом и лицом шрифта для пергамента; печать открыта
local function map_diary()
  local d = wired()
  d.canvas = { fill = nop, free = nop, paintRect = nop }
  d.face_prompt = d.face_answer
  d.pushes = {}
  d.push = function(_, _, _, _, _, mode) d.pushes[#d.pushes + 1] = mode end
  d.controller.seal.open = true
  return d
end

-- пальцем по экрану: каждый штрих — penDown, penMove по точкам, penUp
local function draw(d, strokes)
  for _, s in ipairs(strokes) do
    local p = s.p
    d:penDown(p[1], p[2])
    for i = 3, #p, 2 do d:penMove(p[i], p[i + 1]) end
    d:penUp()
  end
end

function T.test_rose_opens_map_without_model_or_memory()
  local d = map_diary()
  local touched = {} -- имена методов памяти, которые звал контроллер (чтение персоны картой допустимо)
  d.controller.deps.memory = setmetatable({}, { __index = function(_, k)
    touched[#touched + 1] = k
    return nop
  end })
  page_done(d, strokes_of("rose_ccw"))
  run(1)
  t.eq(d.runner.started, 0, "страница-роза не ушла в модель")
  t.ok(not in_list(touched, "session") and not in_list(touched, "add"), "в память не записана: " .. table.concat(touched, ","))
  t.eq(d.inflight, 0)
  t.ok(d.map, "карта открыта")
  t.eq(count("riddle: map open (rose)"), 1)
  t.eq(#d.revealed, 0, "Реддл молчит")
  t.eq(d.pushes[#d.pushes], "full", "пергамент — полным обновлением")
end

function T.test_rose_sealed_goes_to_seal()
  local d = map_diary()
  d.controller.seal.open = false
  page_done(d, strokes_of("rose_ccw"))
  t.eq(d.runner.started, 1, "закрытая печать: страница — в печать, как обычно")
  t.eq(d.runner.jobs[1].kind, "answer")
  run(1)
  t.eq(d.map, nil, "карты нет")
end

-- ревью Task 7: печать открыли, дневник закрыли, через два часа открыли снова — таймера не было, но простой истёк:
-- роза не открывает карту (на ней имя владельца)
function T.test_rose_after_idle_no_map()
  local d = map_diary()
  local wall = 1000
  d.controller = ctl(stand.rules({ key = true, minutes = 30 }), { now = function() return wall end })
  d.controller:seal_toggle() -- ключ узнан в 1000
  wall = 1000 + 2 * 3600
  page_done(d, strokes_of("rose_ccw"))
  run(1)
  t.eq(d.map, nil, "карты нет")
  t.eq(count("riddle: map open"), 0)
end

-- ревью Task 7 (M12): карта открыта дольше срока простоя (её resetPage снял таймер) — после возврата на страницу
-- печать закрыта
function T.test_map_longer_than_idle_closes_on_back()
  local d = map_diary()
  local jump = 0
  d.controller = ctl(stand.rules({ key = true, minutes = 30 }),
    { now = function() return 1000 + math.floor(clock) + jump end })
  d.controller:seal_toggle()
  d:openMap("rose")
  t.ok(d.map, "карта открыта")
  jump = 3600
  d:closeMap("rose")
  run(1)
  t.eq(d.controller.seal.open, false, "после возврата на страницу печать закрыта")
end

function T.test_rose_during_ponder_waits_answer()
  local d = map_diary()
  local idles = 0
  d.on_idle = function() idles = idles + 1 end
  local shown_before_map
  d.openMap = function(self, ...)
    shown_before_map = self.revealed[#self.revealed]
    return Diary.openMap(self, ...)
  end
  local answered
  d.responder = function(png, cb) d:respond(png, function(text, un) answered = text cb(text, un) end) end
  d.controller.seal.open = false
  page_done(d) -- обычная страница: ответ в пути (печать: на открытой нужна память — здесь её нет)
  t.eq(d.inflight, 1)
  d.controller.seal.open = true
  page_done(d, strokes_of("rose_ccw"))
  t.eq(d.runner.started, 1, "роза не в модель")
  t.eq(count("page during ponder -> refusal"), 0, "роза — не отказ")
  run(4)
  t.eq(d.map, nil, "ответ в пути: карта ждёт")
  d.runner:done(reply("кто ты", "Я Том"))
  t.ok(answered, "ответ пришёл")
  run(0.3)
  t.eq(d.map, nil, "ответ проявляется: карта ждёт")
  run(60)
  t.ok(d.map, "после ответа — карта")
  t.eq(shown_before_map, answered, "ответ проявился до карты")
  t.eq(idles, 0, "пока карта открыта, синхронизация не стартует")
  d:closeMap("rose")
  t.ok(idles > 0, "карта закрыта: как после ответа")
end

function T.test_rose_on_map_closes()
  local d = map_diary()
  d:openMap("rose")
  t.ok(d.map, "карта открыта")
  draw(d, F.rose_two_arcs)
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.map, nil, "роза на карте её закрыла")
  t.eq(count("riddle: map close (rose)"), 1)
  t.eq(d.invite, 1, "чистая страница дневника с приглашением")
  t.eq(d.pushes[#d.pushes], "full")
  t.eq(d.runner.started, 0, "в модель ничего")
end

function T.test_non_rose_on_map_keeps_it_open()
  local d = map_diary()
  d:openMap("rose")
  draw(d, F.cross_only)
  run(Diary.CFG.idle_s + 5)
  t.ok(d.map, "крест — не роза: карта открыта")
  t.eq(count("riddle: map close"), 0)
  t.eq(#d.strokes, 0, "чернила карты не в списке растворения страницы")
  draw(d, F.rose_ccw)
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.map, nil, "следующая страница карты — роза: закрыта")
end

-- срез 7: состав героев ротируется между открытиями — у каждого открытия свой номер (seed расстановки);
-- часы героев — местное время os.date("*t")
function T.test_map_opens_number_the_cast_rotation()
  local d = map_diary()
  d:openMap("rose")
  local first = d.map.seed
  t.ok(first, "открытие пронумеровано")
  d:closeMap("rose")
  d:openMap("rose")
  t.eq(d.map.seed, first + 1, "следующее открытие — следующий номер")
  local now = d.map_clock()
  t.ok(now.hour and now.wday and now.month, "часы карты — os.date(\"*t\")")
  d:closeMap("rose")
end

-- devtest rose=N на настоящем виджете: роза харнеса идёт через onRawTouch, карту открывает и закрывает настоящий
-- openMap/closeMap (оба зовут resetPage, а он снимает все задачи self:schedule). Счёт циклов не теряется
-- (живой лог d67ef65: после первого «map open (rose)» ни одной строки ROSE)
function T.test_devtest_rose_counts_cycles_through_real_open_and_close()
  local devtest = require("riddle.devtest")
  local Dev = setmetatable({}, { __index = Diary }) -- харнес ставится в подкласс: остальные тесты его не видят
  devtest.install(Dev, { rssKB = function() return 0 end, RIDDLE_DIR = "/nonexistent" })
  local d = setmetatable(map_diary(), { __index = Dev })
  d.toScreen = function(_, x, y) return x, y end
  d.keepAwake = nop
  d.gd = { feedEvent = function(_, tevs) d:onRawTouch(tevs) end, dropContacts = nop }
  d:testRose("rose=2")
  run(120)
  t.eq(count("riddle: map open (rose)"), 2, "роза харнеса дважды открыла карту")
  t.eq(count("riddle: map close (rose)"), 2, "и дважды закрыла")
  local cycles = {}
  for _, l in ipairs(LOG) do if l:find("riddle: ROSE cycle", 1, true) then cycles[#cycles + 1] = l end end
  t.eq(#cycles, 2, "строка на каждый цикл: " .. table.concat(cycles, " | "))
  for i, l in ipairs(cycles) do
    t.ok(l:match("^riddle: ROSE cycle " .. i .. " open=%d+ close=%d+$"), "открыта и закрыта: " .. l)
  end
  t.eq(count("riddle: ROSE done n=2 opened=2 closed=2"), 1)
  t.eq(d.map, nil)
end

function T.test_map_idle_closes()
  local d = map_diary()
  d:openMap("rose")
  run(100)
  draw(d, F.cross_only) -- касание: отсчёт заново
  run(Diary.CFG.map_idle_s - 10)
  t.ok(d.map, "касание отодвинуло автозакрытие")
  run(20)
  t.eq(d.map, nil, "без касаний — закрылась сама")
  t.eq(count("riddle: map close (idle)"), 1)
  t.eq(d.invite, 1)
end

function T.test_sleep_closes_map_and_cancels_job()
  local d = map_diary()
  d:openMap("rose")
  d:onSuspend()
  t.eq(d.map, nil)
  t.ok(in_list(d.runner.cancels, "map"), "задание карты снято")
  t.eq(count("riddle: map close (sleep)"), 1)
  t.eq(d.invite, 0, "сон: экран у заставки, приглашения нет")
  run(400)
  t.eq(count("riddle: map close"), 1, "таймер автозакрытия снят")
  d:onResume()
  t.eq(d.invite, 1, "после пробуждения — чистая страница и приглашение")
end

-- срез 8: шаг следов тикает только при открытой карте — любое закрытие (роза, фраза, сон, угол, автозакрытие) снимает
-- его таймер; в лог — одна строка шагов на закрытие (замер A12)
function T.test_map_close_stops_step_timer()
  for _, why in ipairs({ "rose", "phrase", "sleep", "exit", "idle" }) do
    local d = map_diary()
    d:openMap("rose")
    run(Diary.CFG.map_step_s * 3)
    local task = d.map.step_task
    t.ok(task and d.tasks[task], why .. ": шаг идёт по таймеру")
    local before = count("riddle: map steps n=")
    if why == "idle" then run(Diary.CFG.map_idle_s) else d:closeMap(why) end
    t.eq(d.map, nil, why .. ": карта закрыта")
    t.eq(d.tasks[task], nil, why .. ": таймера шага нет")
    t.eq(count("riddle: map steps n="), before + 1, why .. ": одна строка шагов")
  end
end

function T.test_no_followup_while_map_open()
  local d = map_diary()
  d.controller = keyed() -- печать закрыта, ключ её откроет
  d.controller.deps.memory = summary_memory({})
  key_page(d)
  t.ok(d.followup_task, "хвост назначен до карты")
  d:openMap("rose")
  run(120)
  t.eq(#d.runner.jobs, 0, "пока карта открыта, хвост не стартует")
  d:closeMap("rose")
  run(120)
  t.eq(#d.runner.jobs, 1, "карта закрыта: хвост ушёл")
  t.eq(d.runner.jobs[1].kind, "summary")
end

-- срез 4: точка карты. Пергамент рисуется сразу; надпись blind — пока точки нет
local function point_diary(point)
  local d = map_diary()
  d.painted = {}
  d.paintText = function(_, text, top)
    d.painted[#d.painted + 1] = text
    return { x = 0, y = top, w = 100, h = 40 }
  end
  d.paintTexts = function(self, list) -- пачка текстов карты (Diary:paintTexts) — те же записи по одному
    local out = {}
    for i, it in ipairs(list) do out[i] = self:paintText(it[1], it[2], it[3]) end
    return out
  end
  d.map_job = function() return { point_source = "none" } end
  d.point = point
  d.map_point = function() return d.point end
  d.terrain = nil -- срез 5: местность из файла задания (riddle.mapjob.read_terrain)
  d.map_terrain = function() return d.terrain end
  return d
end

-- пустая годная местность у точки (1, 2): улиц и домов нет, рисовать нечего
local TERRAIN = { center = { lat = 1, lon = 2 }, w = 1516, h = 2048, m_per_px = 0.7, streets = {}, buildings = {} }

local function painted(d, text)
  for _, s in ipairs(d.painted) do if s == text then return true end end
  return false
end

local function fills(d)
  d.fills = 0
  d.canvas.fill = function() d.fills = d.fills + 1 end
end

function T.test_first_open_offline_blind()
  local d = point_diary(nil)
  package.loaded["ui/network/manager"] = { isWifiOn = function() return true end,
    isConnected = function() return false end }
  d:openMap("rose")
  package.loaded["ui/network/manager"] = nil
  t.ok(d.map, "карта открыта без сети")
  t.ok(painted(d, d.map.data.blind), "надпись blind на пергаменте")
  t.eq(d.runner.started, 0, "без связи задание не стартует")
end

function T.test_open_starts_map_job_when_up()
  local d = point_diary(nil)
  fills(d)
  d:openMap("rose")
  t.eq(d.runner.started, 1)
  local job = d.runner.jobs[1]
  t.eq(job.kind, "map")
  t.eq(job.fn, d.map_job, "в дочернем — задание карты")
  t.eq(job.opts.timeout_s, Diary.CFG.map_ceil_s)
  -- потолок задания покрывает его бюджет (скан, BeaconDB, IP, Overpass с повторами — mapjob_spec) с запасом ≥ 5 с
  local mj = require("riddle.mapjob")
  t.ok(mj.BUDGET_S + 5 <= Diary.CFG.map_ceil_s, "бюджет " .. tostring(mj.BUDGET_S) .. " с, потолок " .. Diary.CFG.map_ceil_s .. " с")
  t.ok(painted(d, d.map.data.blind), "пока точки нет — blind")
  -- задание записало точку, местности нет (Overpass упал): рисовать нечего — blind остаётся
  d.point = { lat = 1, lon = 2, source = "wifi", acc = 34, ts = 1 }
  d.painted = {}
  d.runner:done({ point_source = "wifi", acc = 34, aps = 5, terrain = { state = "http 502" } })
  t.eq(count("riddle: map point wifi acc=34"), 1)
  t.ok(painted(d, d.map.data.blind), "точка без местности — blind (решение оркестратора 2026-11-16)")
  -- следующее задание принесло местность: надпись уходит
  d:closeMap("rose")
  d:openMap("rose")
  d.terrain = TERRAIN
  d.painted = {}
  d.fills = 0
  local pushes = #d.pushes
  d.runner:done({ point_source = "wifi", acc = 34, aps = 5, terrain = { state = "fetched", ways = 0 } })
  t.ok(not painted(d, d.map.data.blind), "местность есть — без blind")
  t.ok(d.fills > 0, "перерисовка: холст действительно закрашен")
  t.ok(#d.pushes > pushes, "перерисовка выведена")
  -- сохранённые точка и местность: blind не рисуется с самого открытия
  d:closeMap("rose")
  d.painted = {}
  d:openMap("rose")
  t.ok(not painted(d, d.map.data.blind), "точка и местность из файла — без blind")
  -- ответ задания после закрытия карты: не рисуется
  d:closeMap("rose")
  d.painted = {}
  d.runner:done({ point_source = "ip", acc = 20000 })
  t.eq(#d.painted, 0, "карта закрыта — ответ не рисуется")
end

-- задача Notion 41a13e60-bc8d-8189: map/terrain.json декодируется один раз за открытие — вид читает его на открытии,
-- а после задания перечитывает, только если задание записало новую местность («fetched»); прежняя («cached»), сбой
-- Overpass, задание без точки или упавшее — файла не трогали, второго чтения нет
function T.test_terrain_read_once_per_open()
  local d = point_diary({ lat = 1, lon = 2, source = "wifi", acc = 34, ts = 1 })
  d.terrain = TERRAIN
  local reads = 0
  d.map_terrain = function()
    reads = reads + 1
    return d.terrain
  end
  local same = {
    { { point_source = "saved", acc = 34, aps = 5, terrain = { state = "cached", ways = 0, bytes = 90 } } },
    { { point_source = "wifi", acc = 30, aps = 5, write = "ok", terrain = { state = "http 502" } } },
    { { point_source = "none", aps = 0 } },
    { nil, "timeout" },
  }
  for i, c in ipairs(same) do
    reads = 0
    d:openMap("rose")
    t.eq(reads, 1, i .. ": открытие читает местность")
    d.runner:done(c[1], c[2])
    t.eq(reads, 1, i .. ": задание не записало местность — второго чтения нет")
    t.eq(d.map.terrain, TERRAIN, i .. ": местность прежняя")
    d:closeMap("rose")
  end
  reads = 0
  d:openMap("rose")
  local NEW = { center = { lat = 1, lon = 2 }, w = 1516, h = 2048, m_per_px = 0.7,
                streets = { { 700, 1000, 800, 1000 } }, buildings = {} }
  d.terrain = NEW
  d.runner:done({ point_source = "wifi", acc = 30, aps = 5, write = "ok", terrain = { state = "fetched", ways = 1 } })
  t.eq(reads, 2, "задание записало новую местность — перечитана")
  t.eq(d.map.terrain, NEW, "новая местность в виде")
end

-- срез 10: на открытии — сохранённые точка и местность сразу, задание "map" — в фоне, после первой отрисовки
function T.test_open_draws_cached_before_job()
  local d = point_diary({ lat = 1, lon = 2, source = "wifi", acc = 34, ts = 1 })
  d.terrain = TERRAIN
  fills(d)
  local start, at_start = d.runner.start, nil
  d.runner.start = function(r, kind, fn, opts)
    if kind == "map" then at_start = { fills = d.fills, pushes = #d.pushes, terrain = d.map and d.map.terrain } end
    return start(r, kind, fn, opts)
  end
  d:openMap("rose")
  t.ok(at_start, "задание запущено")
  t.ok(at_start.fills > 0 and at_start.pushes > 0, "пергамент нарисован и выведен до задания")
  t.eq(at_start.terrain, TERRAIN, "сохранённая местность — до задания")
  t.ok(not painted(d, d.map.data.blind), "без blind: точка и местность из файлов")
end

-- срез 10: карта закрыта, пока задание качает местность: его результат отброшен (ни отрисовки, ни таймеров карты),
-- записанный им файл остаётся — следующее открытие берёт его
function T.test_close_during_fetch_drops_result_keeps_file()
  local d = point_diary({ lat = 1, lon = 2, source = "wifi", acc = 34, ts = 1 })
  d.terrain = TERRAIN
  fills(d)
  d:openMap("rose")
  local view = d.map
  d:closeMap("rose")
  t.ok(in_list(d.runner.cancels, "map"), "закрытие снимает задание")
  local FAR = { lat = 1.05, lon = 2, source = "wifi", acc = 30, ts = 2 }
  local NEW = { center = { lat = 1.05, lon = 2 }, w = 1516, h = 2048, m_per_px = 0.7, streets = {}, buildings = {} }
  d.point, d.terrain = FAR, NEW -- задание успело записать оба файла
  d.fills, d.painted = 0, {}
  local pushes, moved = #d.pushes, count("riddle: map moved")
  d.runner:done({ point_source = "wifi", acc = 30, aps = 5, write = "ok", terrain = { state = "fetched", ways = 0 } })
  t.eq(view.terrain, TERRAIN, "закрытый вид не перечитал местность")
  t.eq(d.fills + #d.painted, 0, "ничего не нарисовано")
  t.ok(not (view.step_task or view.idle_task or view.page_task or view.reveal_task), "таймеров карты нет")
  run(Diary.CFG.map_step_s * 4)
  t.eq(#d.pushes, pushes, "ничего не выведено и потом")
  t.eq(count("riddle: map moved"), moved)
  d:openMap("rose")
  t.eq(d.map.terrain, NEW, "файл задания остался — следующее открытие с ним")
  t.eq(d.map.point, FAR)
end

-- спека, раздел 3: «Без интернета — последняя сохранённая местность»; blind — только когда местности нет вовсе.
-- Владелец уехал, задание записало новую точку, местность не скачалась (сеть): карта остаётся прежней, и при следующем
-- открытии — та же сохранённая местность, а не blind
function T.test_far_offline_reopen_keeps_saved_terrain()
  local d = point_diary({ lat = 1, lon = 2, source = "wifi", acc = 34, ts = 1 })
  d.terrain = TERRAIN
  d:openMap("rose")
  d.point = { lat = 1.05, lon = 2, source = "wifi", acc = 30, ts = 2 } -- 5,5 км к северу: за полем местности
  d.runner:done({ point_source = "wifi", acc = 30, aps = 5, write = "ok", terrain = { state = "offline" } })
  t.ok(d.map.box and not painted(d, d.map.data.blind), "в открытой карте — прежняя местность")
  d:closeMap("rose")
  d.painted = {}
  d:openMap("rose")
  t.eq(d.map.terrain, TERRAIN, "сохранённая местность")
  t.ok(d.map.box, "местность рисуется")
  t.ok(not painted(d, d.map.data.blind), "не blind")
end

-- ревью 2341fe0, БЛОК 1: точка пришла, пока владелец пишет на карте (≈3–5 с после открытия — закрывающая роза) —
-- холст с его чернилами не очищается, штрихи страницы карты целы; blind уходит при следующей перерисовке
function T.test_point_keeps_ink_on_map()
  local d = point_diary(nil)
  fills(d)
  d:openMap("rose")
  draw(d, { F.cross_only[1] })
  d.fills, d.painted = 0, {}
  d.point = { lat = 1, lon = 2, source = "wifi", acc = 34, ts = 1 }
  d.terrain = TERRAIN
  d.runner:done({ point_source = "wifi", acc = 34, aps = 5, terrain = { state = "fetched", ways = 0 } })
  t.eq(d.fills, 0, "штрих на карте: холст не очищен")
  t.eq(#d.painted, 0, "пергамент не перерисован")
  t.eq(#d.map.page.strokes, 1, "штрих страницы карты цел")
  run(Diary.CFG.idle_s + 0.5) -- страница карты кончилась (не роза): перерисовка уже без blind
  t.ok(d.map, "крест — карта открыта")
  t.ok(d.fills > 0, "перерисовка после страницы")
  t.ok(not painted(d, d.map.data.blind), "точка есть — без blind")
end

function T.test_point_keeps_stroke_under_pen()
  local d = point_diary(nil)
  fills(d)
  d:openMap("rose")
  d:penDown(300, 300) -- перо на стекле, штрих не закончен
  d.fills, d.painted = 0, {}
  d.point = { lat = 1, lon = 2, source = "wifi", acc = 34, ts = 1 }
  d.runner:done({ point_source = "wifi", acc = 34, aps = 5 })
  t.eq(d.fills, 0, "перо на стекле: холст не очищен")
  t.ok(d.cur, "начатый штрих не оборван")
end

-- результат задания после закрытия карты (вид без точки) — не рисуется
function T.test_map_job_result_after_close_ignored()
  local d = point_diary(nil)
  fills(d)
  d:openMap("rose")
  d:closeMap("rose")
  d.point = { lat = 1, lon = 2, source = "wifi", acc = 34, ts = 1 }
  d.fills, d.painted = 0, {}
  local pushes = #d.pushes
  d.runner:done({ point_source = "wifi", acc = 34, aps = 5 }, nil, 1)
  t.eq(d.fills, 0, "холст дневника не тронут")
  t.eq(#d.painted, 0)
  t.eq(#d.pushes, pushes, "ничего не выведено")
end

-- после розы, пока карта ещё не открыта, касание пера отменяет её (ревью c2eb1a3, БЛОК-1; решение оркестратора:
-- владелец передумал — роза рисуется заново): написанное после розы не стирается открытием карты.
-- Роза в очереди: её чернила ещё не растворились (lvl 0), карта ждёт
local function rose_waiting(d)
  local strokes = strokes_of("rose_ccw")
  for _, s in ipairs(strokes) do s.lvl = 0 end
  page_done(d, strokes)
  t.eq(d.map, nil, "чернила розы ещё видны: карта ждёт")
  t.eq(#d.queue, 1, "карта в очереди")
  d.controller.seal.open = false -- страница P идёт в печать: задание runner без памяти
  return function() -- чернила розы растворились
    for _, s in ipairs(strokes) do s.lvl = Diary.CFG.dissolve.steps end
    d:nextAnswer()
  end
end

-- A: страница P после розы ушла в модель; открытие карты убило бы её ответ (runner:cancel("answer"))
function T.test_pen_after_rose_keeps_page_sent_to_model()
  local d = map_diary()
  local dissolve = rose_waiting(d)
  draw(d, F.cross_only)
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.runner.started, 1, "страница P ушла в модель")
  dissolve()
  t.eq(d.map, nil, "карта отменена пером")
  t.ok(not in_list(d.runner.cancels, "answer"), "ответ на P не снят")
  t.eq(count("riddle: map cancelled (pen)"), 1)
  local before = #d.revealed
  d.runner:done(reply("ЗАПИСЬ", "x"))
  run(60)
  t.ok(#d.revealed > before, "ответ на P показан")
end

-- B: перо на стекле в момент, когда карта открылась бы: недописанная страница цела
function T.test_pen_down_at_map_turn_keeps_unfinished_page()
  local d = map_diary()
  local dissolve = rose_waiting(d)
  d:penDown(300, 800)
  d:penMove(500, 900) -- крупнее случайного касания (png.tiny)
  dissolve()
  t.eq(d.map, nil, "карта не открылась")
  t.ok(d.cur, "штрих под пальцем жив")
  t.ok(d.page and #d.page.strokes == 1, "недописанная страница цела")
  d:penUp()
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.runner.started, 1, "дописанная страница ушла в модель")
end

-- C: ответ на P пришёл, пока карта стояла в очереди перед ним: открытие карты очистило бы очередь
function T.test_answer_after_rose_is_shown()
  local d = map_diary()
  local dissolve = rose_waiting(d)
  draw(d, F.cross_only)
  run(Diary.CFG.idle_s + 0.5)
  local before = #d.revealed
  d.runner:done(reply("ЗАПИСЬ", "x"))
  dissolve()
  run(60)
  t.eq(d.map, nil, "карты нет")
  t.ok(#d.revealed > before, "ответ на P показан")
end

-- карта, срез 3: фраза. Ответ на страницу — действие "map" (Controller:finish -> nil, "map"): Реддл молчит, страница не
-- в памяти, хвост ответа не берётся; карта встаёт в очередь, как после розы
local function phrase_memory(added)
  local m = roll_memory({ total = 0 }, {})
  m.add = function() added[#added + 1] = true end
  m.parts = function() return nil end
  return m
end

local function phrase_diary()
  local d = map_diary()
  d.added = {}
  d.controller.deps.memory = phrase_memory(d.added)
  d.controller.deps.log = function(msg) LOG[#LOG + 1] = msg end
  d.took = 0
  local take = d.controller.take_followup
  d.controller.take_followup = function(...) d.took = d.took + 1 return take(...) end
  return d
end

function T.test_phrase_action_queues_map()
  local d = phrase_diary()
  page_done(d)
  t.eq(d.runner.started, 1, "страница ушла в модель")
  t.eq(d.runner.jobs[1].kind, "answer")
  d.runner:done({ result = { read = "клянусь, что замышляю шалость", reply = "ОТВЕТ", map = "open" } })
  run(1)
  t.ok(d.map, "карта открыта")
  t.eq(count("riddle: map open (phrase)"), 1)
  t.eq(count("riddle: map phrase open"), 1)
  t.eq(#d.revealed, 0, "Реддл молчит")
  t.eq(#d.added, 0, "в память не легло")
  t.eq(d.inflight, 0)
  t.eq(d.took, 0, "хвост ответа не взят")
  -- обычная фраза: обычный ответ
  d:closeMap("rose")
  page_done(d)
  d.runner:done({ result = { read = "кто ты", reply = "ОТВЕТ", map = "" } })
  run(60)
  t.eq(d.map, nil)
  t.eq(d.revealed[#d.revealed], "ОТВЕТ")
  t.eq(#d.added, 2, "обычная запись — в память")
end

-- роза нарисована, пока фраза читалась: карта откроется один раз
function T.test_phrase_and_rose_open_map_once()
  local d = phrase_diary()
  page_done(d)
  page_done(d, strokes_of("rose_ccw"))
  t.ok(d.mode_due, "роза ждёт ответа")
  d.runner:done({ result = { read = "клянусь", reply = "x", map = "open" } })
  run(1)
  t.ok(d.map)
  t.eq(count("riddle: map open"), 1, "карта открыта один раз")
  t.eq(#d.queue, 0)
end

-- без runner (синхронный путь): то же действие
function T.test_phrase_action_sync_path()
  local d = phrase_diary()
  d.runner = nil
  d.controller.deps.llm_call = function() return { read = "клянусь", reply = "x", map = "open" } end
  d.inkLeft = function() return 0 end
  page_done(d)
  run(1)
  t.ok(d.map, "карта открыта")
  t.eq(count("riddle: map open (phrase)"), 1)
  t.eq(#d.revealed, 0)
  t.eq(#d.added, 0)
end

-- на карте страница не роза: после idle_s её читает модель (prompt.map_read, runner "answer"); фраза закрытия —
-- closeMap("phrase"), иное — карта открыта
function T.test_map_phrase_closes()
  local d = phrase_diary()
  d:openMap("rose")
  draw(d, F.cross_only)
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.runner.started, 1, "страница карты ушла на чтение")
  t.eq(d.runner.jobs[1].kind, "answer")
  t.ok(d.map, "до ответа карта открыта")
  d.runner:done({ result = { read = "Шалость удалась", reply = "", map = "close" } })
  t.eq(d.map, nil, "фраза закрыла карту")
  t.eq(count("riddle: map close (phrase)"), 1)
  t.eq(count("riddle: map phrase close"), 1)
  t.eq(d.invite, 1, "чистая страница с приглашением")
  t.eq(#d.added, 0, "в память ничего")
  d:openMap("rose")
  draw(d, F.cross_only)
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.runner.started, 2)
  d.runner:done({ result = { read = "просто слова", reply = "", map = "" } })
  t.ok(d.map, "не фраза — карта открыта")
  -- ответ после закрытия карты (роза) не закрывает уже новую
  draw(d, F.cross_only)
  run(Diary.CFG.idle_s + 0.5)
  local i = #d.runner.jobs
  d:closeMap("rose")
  d:openMap("rose")
  d.runner:done({ result = { read = "Шалость удалась", reply = "", map = "close" } }, nil, i)
  t.ok(d.map, "ответ закрытой карты новую не закрывает")
end

-- без сети фраза карту не закрывает: модель не зовётся, карта открыта (закрывают роза и автозакрытие)
function T.test_map_offline_phrase_does_not_close()
  local d = phrase_diary()
  d:openMap("rose")
  draw(d, F.cross_only)
  package.loaded["ui/network/manager"] = { isWifiOn = function() return true end,
    isConnected = function() return false end }
  run(Diary.CFG.idle_s + 0.5)
  package.loaded["ui/network/manager"] = nil
  t.eq(d.runner.started, 0, "модель не звалась")
  t.ok(d.map, "карта открыта")
  t.eq(count("riddle: map read skipped, network down"), 1)
end

-- чтение вытесняет задание карты (точка, местность: runner "answer" вытесняет "map"): после чтения, если карта
-- открыта, задание карты идёт заново
function T.test_map_read_restarts_preempted_map_job()
  local d = point_diary(nil)
  d.controller.deps.memory = phrase_memory({})
  d:openMap("rose")
  t.eq(d.runner.jobs[1].kind, "map")
  draw(d, F.cross_only)
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.runner.jobs[2].kind, "answer", "чтение вытеснило задание карты")
  d.runner:done({ result = { read = "слова", reply = "", map = "" } }, nil, 2)
  t.eq(#d.runner.jobs, 3)
  t.eq(d.runner.jobs[3].kind, "map", "задание карты заново")
  -- задание карты уже кончилось: чтение его не перезапускает
  d.runner:done({ point_source = "none" }, nil, 3)
  draw(d, F.cross_only)
  run(Diary.CFG.idle_s + 0.5)
  d.runner:done({ result = { read = "слова", reply = "", map = "" } })
  t.eq(#d.runner.jobs, 4, "только чтение")
end

-- роза во время ответа в пути (mode_due) — перо до ответа тоже отменяет карту
function T.test_pen_cancels_mode_due()
  local d = map_diary()
  d.controller.seal.open = false
  page_done(d) -- ответ в пути
  d.controller.seal.open = true
  page_done(d, strokes_of("rose_ccw"))
  t.ok(d.mode_due, "карта ждёт ответа")
  d:penDown(300, 800)
  t.eq(d.mode_due, nil, "перо отменило карту")
  t.eq(count("riddle: map cancelled (pen)"), 1)
  d:penUp()
  d.runner:done(reply("кто ты", "x"), nil, 1)
  run(60)
  t.eq(d.map, nil)
end

-- срез 6: настоящий Diary:paintText на холсте-буфере; глиф — ширина px/2 у шрифта размера px (шрифт приглашения
-- в тестах без размера — 10), отпечаток глифа 8 × 20; blits — куда легли глифы. Заглушки общие для файла: restore()
local function text_diary()
  local ffi = require("ffi")
  local d = map_diary()
  local blits = {}
  d.canvas = { data = ffi.new("uint8_t[?]", 758 * 1024), stride = 758,
               getWidth = function() return 758 end, getHeight = function() return 1024 end,
               colorblitFrom = function(_, _, x, y) blits[#blits + 1] = { x = x, y = y } end }
  local rt, ft = require("ui/rendertext"), require("ffi/freetype")
  local saved = { rt.getGlyph, ft.newFaceSize }
  ft.newFaceSize = function(_, px) return { getHeightAndAscender = function() return px + 6, px - 2 end } end
  rt.getGlyph = function(_, face)
    return { ax = face.size and face.size / 2 or 10, l = 0, t = 20,
             bb = { getWidth = function() return 8 end, getHeight = function() return 20 end } }
  end
  local function restore() rt.getGlyph, ft.newFaceSize = saved[1], saved[2] end
  return d, restore, blits
end

local function with_text_diary(fn)
  local d, restore, blits = text_diary()
  local ok, err = pcall(fn, d, blits)
  restore()
  assert(ok, err)
end

-- старый вызов (без opts) — тот же rect, что до подписей карты (cb0defe): блок на всю ширину страницы, строка по центру
function T.test_paint_text_without_opts_unchanged()
  with_text_diary(function(d, blits)
    local r = d:paintText("ab cd", 100)
    t.eq(r.x, 44 - 8)
    t.eq(r.y, 100 - 8)
    t.eq(r.w, 758 - 2 * 44 + 16)
    t.eq(r.h, 40 + 52 + 16, "подъём 40 + строка 52 + поля")
    t.eq(#blits, 4, "четыре глифа")
    -- «ab cd»: 4 × 10 + пробел 6 = 46 → сдвиг (670 − 46) / 2 = 312 от поля 44
    t.eq(blits[1].x, 44 + 312)
    t.eq(blits[1].y, 100 + 40 - 20)
  end)
end

-- opts (подписи карты): шрифт px, строки по центру cx, перенос по maxw, dry — только размер; rect — сами строки
function T.test_paint_text_opts_measure_and_center()
  with_text_diary(function(d, blits)
    local opts = { px = 24, cx = 200, maxw = 240, dry = true }
    local m = d:paintText("ab cd", 300, opts)
    t.eq(#blits, 0, "dry — без туши")
    -- px 24: глиф 12, пробел floor(12 × 0.6) = 7 → 4 × 12 + 7 = 55; поле строк — от 200 − 120 = 80
    t.eq(m.w, 55)
    t.eq(m.h, 30, "одна строка шрифта 24")
    t.eq(m.y, 300)
    t.eq(m.x, 80 + math.floor((240 - 55) / 2))
    opts.dry = nil
    local r = d:paintText("ab cd", 300, opts)
    t.eq(#blits, 4, "без dry — нарисована")
    t.eq(blits[1].x, m.x, "первый глиф — у левого края rect")
    t.eq(r.x, m.x)
    t.eq(r.w, m.w)
    t.eq(r.h, m.h)
    -- две строки: слова по 10 × 12 = 120 не влезают вдвоём в 150 → rect шириной в строку, высотой в две
    local two = d:paintText("abcdefghij klmnopqrst", 0, { px = 24, cx = 400, maxw = 150, dry = true })
    t.eq(two.w, 120)
    t.eq(two.h, 60)
    t.eq(two.x, 400 - 75 + 15)
  end)
end

-- тушь глифа на настоящем холсте: colorblitFrom смешивает к чёрному по покрытию a (белый → 255 − a), затем порог.
-- Глиф 4 × 3, покрытие по столбцам 255, 200, 100, 50 → на белом 0, 55, 155, 205.
local COVER = { 255, 200, 100, 50 }
-- буфер W × H байт (белый): fill, colorblitFrom по покрытию глифа, free — холст дневника и слой (Blitbuffer.new)
local function ink_bb(W, H)
  local ffi = require("ffi")
  local data = ffi.new("uint8_t[?]", W * H)
  ffi.fill(data, W * H, 0xFF)
  return { data = data, stride = W, getWidth = function() return W end, getHeight = function() return H end,
           fill = function(_, c) ffi.fill(data, W * H, c) end, free = function() end,
           colorblitFrom = function(_, src, x, y, _, _, w, h, c)
             for j = 0, h - 1 do
               for i = 0, w - 1 do
                 local p, a = (y + j) * W + x + i, src.cover[i + 1]
                 data[p] = math.floor((data[p] * (255 - a) + c * a) / 255 + 0.5)
               end
             end
           end }
end

local function ink_text_diary(fn)
  local d, restore = text_diary()
  local W, H = 758, 1024
  d.canvas = ink_bb(W, H)
  local data = d.canvas.data
  local Blitbuffer = require("ffi/blitbuffer")
  local saved_new = Blitbuffer.new
  Blitbuffer.new = function(w, h) return ink_bb(w, h) end
  local rt = require("ui/rendertext")
  local saved = rt.getGlyph
  rt.getGlyph = function(_, _, cp)
    if cp == 32 then return { ax = 10, l = 0, t = 0, bb = { getWidth = function() return 0 end,
                                                          getHeight = function() return 0 end } } end
    return { ax = 10, l = 0, t = 3, bb = { cover = COVER, getWidth = function() return 4 end,
                                           getHeight = function() return 3 end } }
  end
  -- чёрные пиксели холста: { [y] = { x, … } } и их число; серых нет — иначе ошибка
  local function black()
    local rows, n = {}, 0
    for i = 0, W * H - 1 do
      local v = data[i]
      assert(v == 0 or v == 0xFF, "серый пиксель " .. v .. " в " .. i % W .. "," .. math.floor(i / W))
      if v == 0 then
        local y = math.floor(i / W)
        rows[y] = rows[y] or {}
        table.insert(rows[y], i % W)
        n = n + 1
      end
    end
    return rows, n
  end
  local ok, err = pcall(fn, d, black)
  rt.getGlyph = saved
  Blitbuffer.new = saved_new
  restore()
  assert(ok, err)
end

-- страница дневника (ответ, приглашение — paintText без opts) и подписи без opts туши: порог прежний 0x80, глиф
-- один раз — в каждой строке глифа ровно столбцы 0 и 55, ровно три строки
function T.test_paint_text_ink_default_unchanged()
  ink_text_diary(function(d, black)
    d:paintText("a", 100)
    local rows, n = black()
    t.eq(n, 2 * 3, "две чёрных колонки × три строки")
    for _, xs in pairs(rows) do t.eq(#xs, 2) t.eq(xs[2], xs[1] + 1) end
  end)
  ink_text_diary(function(d, black)
    d:paintText("a", 300, { px = 24, cx = 200, maxw = 240 })
    local _, n = black()
    t.eq(n, 2 * 3, "opts без threshold и bold — та же тушь")
  end)
end

-- подписи карты (владелец 2026-11-16: «чернее и жирным»): threshold — порог выше, больше сглаживания уходит в
-- чёрный; bold { dx, dy } — глиф ещё раз со сдвигом на каждый (i ≤ dx, j ≤ dy): буква толще на dx вправо, dy вниз
-- halo (оркестратор 2026-11-16: улица по строке режет «Хогвартс»): линия под текстом обрывается вплотную к буквам —
-- белым только пиксели в радиусе r от туши, не прямоугольник; в межсловном пробеле и в 4 px от rect текста линия цела
function T.test_paint_text_halo_cuts_line_only_at_letters()
  ink_text_diary(function(d, black)
    local top = 300
    local opts = { px = 24, cx = 200, maxw = 240, threshold = 0xC0, bold = { 1, 0 }, halo = 1 }
    -- глиф: строки top + 19 … top + 21 (подъём 22, t = 3); линия улицы — через его середину, на всю ширину
    local row = top + 20
    for x = 0, 757 do d.canvas.data[row * 758 + x] = 0 end
    local r = d:paintText("a a", top, opts)
    local rows = black()
    local gx = math.min(unpack(rows[top + 19]))
    -- тушь: колонки gx … gx + 3 и gx + 16 … gx + 19 (шаг 10 + пробел 6); halo 1 — по пикселю с каждой стороны
    local white = {}
    local onrow = {}
    for _, x in ipairs(rows[row]) do onrow[x] = true end
    for x = 0, 757 do if not onrow[x] then white[#white + 1] = x end end
    t.eq(table.concat(white, ","), table.concat({ gx - 1, gx + 4, gx + 15, gx + 20 }, ","),
      "линия оборвана ровно у букв")
    t.ok(onrow[gx + 9], "в межсловном пробеле линия цела")
    t.ok(onrow[r.x - 4] and onrow[r.x + r.w + 3], "в 4 px от rect текста линия цела")
    t.eq(rows[top + 18], nil, "над буквами белое, как было")
  end)
end

-- ревью b52f8fd (Б1): слово шире maxw (одно, не переносится) с halo — тушь целиком, как без halo; слой обводки — по
-- собственному rect строк, не по maxw
function T.test_paint_text_halo_keeps_word_wider_than_maxw()
  local word = string.rep("a", 30) -- 30 × 10 = 300 > maxw 240 + 16 + обводка
  local counts = {}
  for i, halo in ipairs({ false, 2 }) do
    ink_text_diary(function(d, black)
      d:paintText(word, 300, { px = 24, cx = 379, maxw = 240, threshold = 0xC0, bold = { 1, 0 }, halo = halo or nil })
      local _, n = black()
      counts[i] = n
    end)
  end
  t.ok(counts[1] > 0, "слово нарисовано")
  t.eq(counts[2], counts[1], "с halo чёрных пикселей столько же, сколько без")
end

-- клип обводки (решение оркестратора 2026-11-16): halo белит только внутри clip — линия рамки за краем поля туши
-- цела, даже вплотную к букве; без clip та же линия у буквы стирается (она в досягаемости обводки)
function T.test_paint_text_halo_clip_keeps_frame()
  local top, gx = 300, nil
  local opts = { px = 24, cx = 200, maxw = 240, threshold = 0xC0, bold = { 1, 0 }, halo = 2 }
  ink_text_diary(function(d, black)
    d:paintText("a", top, opts)
    gx = math.min(unpack(black()[top + 19]))
  end)
  local function frame_after(clip)
    local left
    ink_text_diary(function(d, black)
      for y = top, top + 30 do d.canvas.data[y * 758 + gx - 1] = 0 end -- рамка — вертикаль вплотную к букве
      opts.clip = clip
      d:paintText("a", top, opts)
      local rows = black()
      left = 0
      for y = top, top + 30 do
        for _, x in ipairs(rows[y] or {}) do if x == gx - 1 then left = left + 1 end end
      end
    end)
    return left
  end
  t.eq(frame_after({ gx, 0, 758, 1024 }), 31, "рамка за краем клипа цела")
  t.ok(frame_after(nil) < 31, "без клипа обводка её задевает")
end

-- задача «обводка подписи не откусывает буквы соседней» (свес латиницы): «f» MarckScript выступает за свой rect вправо;
-- соседняя подпись в LABEL_GAP = 4 px с обводкой 2 px белит этот свес, если её рисуют после. Diary:paintTexts — пачка:
-- сначала обводки всех текстов, потом тушь всех — свес цел; по одному (paintText подряд) — откушен
function T.test_paint_texts_halos_before_any_ink()
  local OVER = 4 -- «f»: глиф на 4 px шире своего шага
  local opts = function(cx) return { px = 24, cx = cx, maxw = 240, threshold = 0xC0, halo = 2 } end
  local function draw(batch)
    local out
    ink_text_diary(function(d, black)
      local rt = require("ui/rendertext")
      rt.getGlyph = function(_, _, cp)
        local w = cp == 102 and 10 + OVER or 4
        local cover = {}
        for i = 1, w do cover[i] = 255 end
        return { ax = 10, l = 0, t = 3, bb = { cover = cover, getWidth = function() return w end,
                                               getHeight = function() return 3 end } }
      end
      local a = d:paintText("f", 300, setmetatable({ dry = true }, { __index = opts(200) }))
      local b = d:paintText("a", 300, setmetatable({ dry = true }, { __index = opts(0) }))
      -- «a» вплотную: между rect «f» и rect «a» — 4 px (LABEL_GAP карты)
      local bx = a.x + a.w + 4
      local cb = bx + b.w / 2 + (opts(0).maxw - b.w) / 2 - math.floor((opts(0).maxw - b.w) / 2)
      t.eq(d:paintText("a", 300, setmetatable({ dry = true }, { __index = opts(cb) })).x, bx, "«a» в 4 px от «f»")
      if batch then
        d:paintTexts({ { "f", 300, opts(200) }, { "a", 300, opts(cb) } })
      else
        d:paintText("f", 300, opts(200))
        d:paintText("a", 300, opts(cb))
      end
      local rows = black()
      local row, xs = rows[300 + 22 - 3 + 1], {}
      for _, x in ipairs(row or {}) do xs[x] = true end
      out = { a = a, xs = xs }
    end)
    return out
  end
  local one = draw(false)
  local tail = one.a.x + one.a.w - 1 + OVER -- последний столбец свеса «f»
  t.ok(not (one.xs[tail - 1] and one.xs[tail]), "по одному: свес «f» откушен обводкой «a»")
  local both = draw(true)
  for x = one.a.x, tail do t.ok(both.xs[x], "пачкой: «f» цела, столбец " .. x) end
end

function T.test_paint_text_ink_threshold_and_bold()
  ink_text_diary(function(d, black)
    d:paintText("a", 300, { px = 24, cx = 200, maxw = 240, threshold = 0xC0 })
    local rows, n = black()
    t.eq(n, 3 * 3, "155 < 0xC0 — третья колонка чёрная")
    for _, xs in pairs(rows) do t.eq(#xs, 3) end
  end)
  ink_text_diary(function(d, black)
    d:paintText("a", 300, { px = 24, cx = 200, maxw = 240, bold = { 1, 0 } })
    local rows, n = black()
    -- колонки: 0; 0 поверх 55; 33; 125 (205 под 155) — четыре чёрных, пятая 205 белая
    t.eq(n, 4 * 3, "глиф толще на столбец и темнее на краю")
    local ys = 0
    for _, xs in pairs(rows) do t.eq(#xs, 4) ys = ys + 1 end
    t.eq(ys, 3, "по вертикали не толще")
  end)
  ink_text_diary(function(d, black)
    local r = d:paintText("a", 300, { px = 24, cx = 200, maxw = 240, bold = { 1, 1 }, threshold = 0xC0, dry = true })
    local plain = d:paintText("a", 300, { px = 24, cx = 200, maxw = 240, dry = true })
    t.eq(r.w, plain.w + 1, "размер жирной подписи шире на dx")
    t.eq(r.h, plain.h + 1, "и выше на dy")
    local _, n0 = black()
    t.eq(n0, 0, "dry — без туши")
    d:paintText("a", 300, { px = 24, cx = 200, maxw = 240, bold = { 1, 1 }, threshold = 0xC0 })
    local rows, n = black()
    local ys = 0
    for _ in pairs(rows) do ys = ys + 1 end
    t.eq(ys, 4, "толще на строку вниз")
    t.ok(n > 4 * 3, "жирнее, чем без dy: " .. n)
  end)
end

---------------------------------------------------------------------------
-- карта, срез 9: поле двигается пальцем — штрих от края (полоса map_edge_px) и нижняя полоса-тачпад (map_pad_px).
-- Касания в зонах — не чернила и не страница карты. Холст пишет каждый прямоугольник; местность — синтетика
-- tests/fixtures/overpass_small.json: две улицы крест-накрест через точку

local terrain = require("riddle.terrain")
local CENTER = { lat = 10.0, lon = 20.0 }

local function pan_diary()
  local f = assert(io.open("tests/fixtures/overpass_small.json", "rb"))
  local raw = f:read("*a")
  f:close()
  local tt = assert(terrain.compact(raw, CENTER, terrain.field(CENTER, 758, 1024)))
  local d = point_diary(CENTER)
  d.terrain = tt
  d.rects = {}
  d.canvas = { free = nop, fill = function() d.rects = {} end,
               paintRect = function(_, x, y, w, h) d.rects[#d.rects + 1] = { x, y, w, h } end }
  return d
end

-- отпечаток пера местности (2×2) или пальца (2×4, 4×2) в точке
local function rect_at(d, x, y, small)
  for _, r in ipairs(d.rects) do
    local fits = small and (r[3] <= 2 and r[4] <= 2) or (not small and (r[3] == 4 and r[4] == 2 or r[3] == 2 and r[4] == 4))
    if fits and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4] then return true end
  end
  return false
end

local function n_pushes(d, mode)
  local n = 0
  for _, m in ipairs(d.pushes) do if m == mode then n = n + 1 end end
  return n
end

local function stroke(d, pts)
  d:penDown(pts[1], pts[2])
  for i = 3, #pts, 2 do d:penMove(pts[i], pts[i + 1]) end
  d:penUp()
end

function T.test_pan_tunables()
  t.eq(Diary.CFG.map_edge_px, 83, "≈ 1 см при 212 ppi")
  t.eq(Diary.CFG.map_pad_px, 167, "≈ 2 см")
  t.eq(Diary.CFG.map_edge_extra, 0.10, "полосы шире на 10% экрана (владелец 2026-11-16)")
  t.eq(Diary.CFG.map_drag_s, 0.4)
  t.eq(Diary.CFG.map_pan_slop_px, 10, "дрожь пальца — не сдвиг")
end

-- сон посреди тачпада (палец лежит): карта закрыта, после закрытия ни одной перерисовки; палец, двигаясь дальше,
-- страницу дневника не пишет
function T.test_close_mid_pad_no_repaint()
  local d = pan_diary()
  d:openMap("rose")
  run(3)
  d:penDown(300, 950)
  d:penMove(340, 950)
  d:penMove(380, 950) -- следующий шаг ждёт map_drag_s
  local pushes = #d.pushes
  d:onSuspend()
  t.eq(d.map, nil, "карта закрыта")
  run(2)
  d:penMove(420, 950)
  d:penUp()
  run(2)
  t.eq(#d.pushes, pushes, "после закрытия — ни одной перерисовки")
  t.eq(d.page, nil, "страница дневника не начата")
  t.eq(#d.strokes, 0, "чернил дневника нет")
  t.eq(count("riddle: map pan"), 0)
end

-- лог жеста — с временем перерисовки (замер тестера): у края — одной, у тачпада — самой долгой за жест
function T.test_pan_log_has_repaint_ms()
  local d = pan_diary()
  d:openMap("rose")
  local cost = { 0.05, 0.12, 0.03 }
  local k = 0
  d.push = function(_, _, _, _, _, mode)
    d.pushes[#d.pushes + 1] = mode
    k = k + 1
    clock = clock + (cost[k] or 0)
  end
  stroke(d, { 30, 600, 230, 600 })
  t.eq(count("riddle: map pan edge in 50 ms"), 1, "у края — время перерисовки")
  d:penDown(300, 950)
  d:penMove(340, 950) -- первая перерисовка сразу: 120 мс
  d:penMove(380, 950)
  run(Diary.CFG.map_drag_s) -- вторая: 30 мс
  d:penUp()
  t.eq(count("riddle: map pan pad in 120 ms"), 1, "тачпад — самая долгая перерисовка жеста")
end

-- тап с дрожью (2–5 px) у края и на тачпаде — не сдвиг: ни перерисовки, ни строки лога; от порога — сдвиг
function T.test_jitter_is_not_pan()
  local d = pan_diary()
  d:openMap("rose")
  local pushes = #d.pushes
  stroke(d, { 30, 600, 33, 603, 35, 598, 32, 601 })
  stroke(d, { 300, 950, 304, 952, 302, 947, 305, 950 })
  t.eq(#d.pushes, pushes, "дрожь — экран не трогается")
  t.eq(count("riddle: map pan"), 0)
  t.eq(#d.map.page.strokes, 0, "и не чернила")
  local slop = Diary.CFG.map_pan_slop_px
  stroke(d, { 30, 600, 30 + slop, 600 })
  t.eq(count("riddle: map pan edge"), 1, "сдвиг на порог — сдвиг")
  -- тачпад: палец ушёл за порог — карта идёт за ним от точки касания
  d:penDown(300, 950)
  d:penMove(304, 950)
  t.eq(count("riddle: map pan"), 1)
  d:penMove(300 + slop + 20, 950)
  d:penUp()
  t.eq(count("riddle: map pan pad"), 1, "за порогом — сдвиг")
  t.ok(rect_at(d, 379 + slop + slop + 20, 312, true), "на весь путь пальца, с порогом")
end

-- штрих из полосы у левого края вправо на 200 px: поле сдвинуто на вектор штриха (на отрыве), чернил нет,
-- страница карты пуста — ни розы, ни чтения
function T.test_edge_stroke_pans_not_ink()
  local d = pan_diary()
  d:openMap("rose")
  run(3) -- линии проявились (срез 6)
  t.ok(rect_at(d, 379, 312, true), "улица юг-север в центре")
  local pushes, started = #d.pushes, d.runner.started
  d:penDown(30, 600)
  for x = 50, 230, 20 do d:penMove(x, 600) end
  t.eq(#d.pushes, pushes, "пока палец лежит — карта стоит (сдвиг на отрыве)")
  d:penMove(230, 640)
  d:penUp()
  t.ok(not rect_at(d, 130, 600, false), "чернил пальца нет")
  t.eq(#d.map.page.strokes, 0, "страница карты пуста")
  t.eq(d.cur, nil)
  t.ok(rect_at(d, 379 + 200, 312 + 40, true), "улица юг-север — на 200 px правее и 40 ниже")
  t.ok(not rect_at(d, 379, 312, true), "на старом месте пусто")
  t.eq(n_pushes(d, "A2"), 1, "одна перерисовка A2")
  t.eq(count("riddle: map pan edge"), 1)
  run(Diary.CFG.idle_s + 1)
  t.ok(d.map, "карта открыта: страницы не было")
  t.eq(d.runner.started, started, "в модель ничего (не чтение страницы)")
  -- штрих от правого края влево, от верхнего вниз — тоже сдвиг
  stroke(d, { 740, 600, 640, 600 })
  t.ok(rect_at(d, 379 + 100, 312 + 40, true), "от правого края — обратно на 100")
  stroke(d, { 500, 30, 500, 130 })
  t.ok(rect_at(d, 379 + 100, 312 + 140, true), "от верхнего края — на 100 вниз")
  t.eq(count("riddle: map pan edge"), 3)
  -- касание у края без движения — не сдвиг, не чернила
  local before = #d.pushes
  stroke(d, { 30, 500 })
  t.eq(#d.pushes, before, "тап у края — ничего")
  t.eq(#d.map.page.strokes, 0)
end

-- тачпад: пока палец в нижней полосе лежит, карта едет за ним — перерисовка не чаще map_drag_s; на отрыве —
-- последнее положение
function T.test_pad_drag_follows_finger()
  local d = pan_diary()
  d:openMap("rose")
  local base = n_pushes(d, "A2")
  d:penDown(300, 950)
  for i = 1, 20 do
    d:penMove(300 + 5 * i, 950 - 2 * i)
    run(0.1)
  end
  -- 2 с пальцем: первая перерисовка сразу, дальше не чаще раза в 0,4 с
  local during = n_pushes(d, "A2") - base
  t.ok(during >= 4 and during <= 1 + 2 / Diary.CFG.map_drag_s, "перерисовок за 2 с: " .. during)
  t.ok(not rect_at(d, 379, 312, true), "карта едет за пальцем, пока он лежит")
  for i = 1, 5 do d:penMove(400 + 4 * i, 910) end -- быстрые движения перед отрывом
  d:penUp()
  t.ok(rect_at(d, 379 + 120, 312 - 40, true), "на отрыве — где палец: +120, −40")
  t.ok(not rect_at(d, 350, 930, false), "чернил пальца нет")
  t.eq(#d.map.page.strokes, 0, "страница карты пуста")
  t.eq(count("riddle: map pan pad"), 1, "строка лога на жест")
  local after = #d.pushes
  run(2)
  t.eq(#d.pushes, after, "после отрыва карта стоит")
  t.ok(d.map, "карта открыта")
end

-- крест розы в середине — чернила (страница карты), роза в середине — закрывает. Сдвиг посреди страницы её не рвёт:
-- страница кончается через idle_s после последнего касания
function T.test_short_cross_in_middle_is_ink()
  local d = pan_diary()
  d:openMap("rose")
  draw(d, F.cross_only)
  t.eq(#d.map.page.strokes, #F.cross_only, "крест — штрихи страницы карты")
  t.ok(rect_at(d, F.cross_only[1].p[1], F.cross_only[1].p[2], false), "крест — чернилами")
  stroke(d, { 30, 600, 130, 600 }) -- сдвиг посреди страницы
  t.eq(#d.map.page.strokes, #F.cross_only, "сдвиг страницу не трогает")
  t.ok(rect_at(d, F.cross_only[1].p[1], F.cross_only[1].p[2], false), "чернила креста на стекле после сдвига")
  run(Diary.CFG.idle_s + 0.5)
  t.eq(#d.map.page.strokes, 0, "страница кончилась после сдвига")
  t.ok(d.map, "крест — не роза")
  draw(d, F.rose_two_arcs)
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.map, nil, "роза в середине — закрыла")
  t.eq(count("riddle: map close (rose)"), 1)
end

-- роза закрывает карту, даже если росчерк (fixture rose_tilted_30: штрих с x = 599) начат в полосе края: решает зона
-- в penDown, раньше распознавания — росчерк становится сдвигом, круг с крестом остаются страницей и узнаются розой
function T.test_rose_with_stroke_in_edge_still_closes()
  local d = pan_diary()
  d:openMap("rose")
  local flick = F.rose_tilted_30[#F.rose_tilted_30]
  t.eq(require("riddle_mapview").zone(flick.p[1], flick.p[2], d.w, d.h, d.CFG), "edge", "росчерк — в полосе края")
  draw(d, F.rose_tilted_30)
  t.eq(#d.map.page.strokes, #F.rose_tilted_30 - 1, "росчерк из края — не штрих страницы")
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.map, nil, "роза закрыла карту")
  t.eq(count("riddle: map close (rose)"), 1)
end

-- слова оркестратора 2026-11-16: роза закрывает карту из любого места. Штрих из полосы края — сдвиг, только если он почти
-- прямой (хорда / длина пути ≥ CFG.map_edge_straight); дуга из полосы — штрих страницы, как будто края нет
local function path_len(p)
  local n = 0
  for i = 3, #p, 2 do n = n + math.sqrt((p[i] - p[i - 2]) ^ 2 + (p[i + 1] - p[i - 1]) ^ 2) end
  return n
end

-- роза name, сдвинутая (и, если надо, зеркально отражённая) так, чтобы начало её круга (самого длинного штриха) легло
-- в точку (tx, ty) по оси axis ("x" или "y"; по другой оси — где была); nil — розы не уместить на экран
local function rose_placed(d, name, axis, target)
  local src = F[name]
  local circle = 1
  for i, s in ipairs(src) do if path_len(s.p) > path_len(src[circle].p) then circle = i end end
  for _, flip in ipairs({ false, true }) do
    local sign = flip and -1 or 1
    local d0 = sign * src[circle].p[axis == "x" and 1 or 2]
    local off = target - d0
    local out, ok = {}, true
    for i, s in ipairs(src) do
      local q = {}
      for k = 1, #s.p, 2 do
        local x, y = s.p[k], s.p[k + 1]
        if axis == "x" then x = sign * x + off else y = sign * y + off end
        if x < 0 or x > d.w - 1 or y < 0 or y > d.h - 1 then ok = false end
        q[k], q[k + 1] = x, y
      end
      out[i] = { p = q }
    end
    if ok then return out end
  end
  return nil
end

local POSITIONS = {
  { name = "правая полоса", axis = "x", target = 758 - 159 }, -- первый пиксель полосы: дальше круг не умещается
  { name = "левая полоса", axis = "x", target = 158 },
  { name = "верхняя полоса", axis = "y", target = 184 },
}

function T.test_edge_tunables_straight()
  t.eq(Diary.CFG.map_edge_straight, 0.75, "хорда / длина: дуги роз ≤ 0,65, мазки пальцем ≥ 0,85")
end

function T.test_roses_closing_from_edge_strips()
  local misses = 0
  for _, pos in ipairs(POSITIONS) do
    local closed, placed = 0, 0
    for _, name in ipairs(F.ROSES) do
      local d = pan_diary()
      local strokes = rose_placed(d, name, pos.axis, pos.target)
      if strokes then
        placed = placed + 1
        d:openMap("rose")
        draw(d, strokes)
        run(Diary.CFG.idle_s + 0.5)
        if d.map == nil then closed = closed + 1 else print("  не закрыла: " .. name .. " @ " .. pos.name) end
      else
        print("  не уместить: " .. name .. " @ " .. pos.name)
      end
    end
    print(string.format("  %s: уместилось %d из %d, закрыли %d", pos.name, placed, #F.ROSES, closed))
    t.ok(placed >= 6, pos.name .. ": розы умещаются на экране: " .. placed)
    misses = misses + placed - closed
  end
  t.eq(misses, 0, "все уместившиеся розы закрывают карту")
end

-- прямой мазок из полосы двигает поле; дуга из полосы (стартует в полосе, уходит внутрь) — чернила страницы, не сдвиг
function T.test_arc_from_edge_is_ink_straight_is_pan()
  local d = pan_diary()
  d:openMap("rose")
  run(3)
  local arc = F.rose_ccw[1].p -- круг: 1 хорда ≈ 0
  local ox = 100 - arc[1]
  local p = {}
  for i = 1, #arc, 2 do p[i], p[i + 1] = arc[i] + ox, arc[i + 1] end
  t.eq(require("riddle_mapview").zone(p[1], p[2], d.w, d.h, d.CFG), "edge", "круг начат в полосе")
  stroke(d, p)
  t.eq(#d.map.page.strokes, 1, "круг из полосы — штрих страницы")
  t.ok(rect_at(d, p[1], p[2], false), "и он на стекле")
  t.eq(count("riddle: map pan edge"), 0, "сдвига нет")
  run(Diary.CFG.idle_s + 0.5)
  stroke(d, { 30, 600, 230, 600 })
  t.eq(count("riddle: map pan edge"), 1, "прямой мазок — сдвиг")
  t.eq(#d.map.page.strokes, 0)
end

-- сдвиг из края, давний относительно страницы, к странице не липнет: круг без креста — не роза, хоть сдвиг и был
function T.test_old_edge_pan_does_not_join_page()
  local d = pan_diary()
  d:openMap("rose")
  stroke(d, { 30, 500, 550, 500 }) -- два прямых мазка из полос: сдвиги, а вместе с кругом ниже — крест розы
  stroke(d, { 380, 30, 380, 670 })
  t.eq(count("riddle: map pan edge"), 2)
  run(Diary.CFG.idle_s + 1)
  draw(d, F.circle_only)
  run(Diary.CFG.idle_s + 0.5)
  t.ok(d.map, "круг один — не роза")
end

-- ревью среза 11: окно сдвигов для розы — от штрихов страницы в обе стороны. Крест из полос, сразу за ним медленный круг
-- (дольше idle_s): крест нарисован до круга — роза, хоть круг и кончился позже idle_s после креста
function T.test_edge_bars_before_slow_circle_close()
  local d = pan_diary()
  d:openMap("rose")
  stroke(d, { 30, 500, 550, 500 })
  stroke(d, { 380, 30, 380, 670 })
  t.eq(count("riddle: map pan edge"), 2, "крест из полос — сдвиги")
  local p = F.circle_only[1].p
  d:penDown(p[1], p[2])
  for i = 3, #p, 2 do
    run(0.06)
    d:penMove(p[i], p[i + 1])
  end
  t.ok(0.06 * (#p / 2 - 1) > Diary.CFG.idle_s, "круг дольше idle_s")
  d:penUp()
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.map, nil, "роза закрыла карту")
end

-- ревью пачки 4: черты розы из полос цепочкой — круг, через 2 с черта из края, ещё через 2 с вторая (в 4 с от круга,
-- но в 2 с от первой черты): роза. Сдвиг дальше idle_s от всего — и от штрихов, и от вошедших сдвигов — не входит:
-- черта задолго до второй черты, вторая — у круга: одна черта — не роза
function T.test_edge_bars_chain_to_rose()
  local d = pan_diary()
  d:openMap("rose")
  draw(d, F.circle_only)
  run(Diary.CFG.idle_s - 0.5)
  stroke(d, { 30, 500, 550, 500 })
  run(Diary.CFG.idle_s - 0.5)
  stroke(d, { 380, 30, 380, 670 })
  run(Diary.CFG.idle_s + 0.5)
  t.eq(d.map, nil, "черты цепочкой — роза закрыла карту")
  local d2 = pan_diary()
  d2:openMap("rose")
  stroke(d2, { 30, 500, 550, 500 })
  run(Diary.CFG.idle_s + 0.5)
  stroke(d2, { 380, 30, 380, 670 })
  run(1)
  draw(d2, F.circle_only)
  run(Diary.CFG.idle_s + 0.5)
  t.ok(d2.map, "первая черта дальше idle_s от всего — не входит: не роза")
end

-- розы владельца (tests/fixtures/rose_owner.lua), где обе черты начаты в полосе края и почти прямые — сдвиги: круг,
-- пауза 2 с, черта, пауза 2 с, черта (вторая — дальше idle_s от круга) — каждая закрывает карту
function T.test_owner_roses_with_both_bars_from_edge()
  local OWN = require("fixtures.rose_owner")
  local MapView = require("riddle_mapview")
  local names = {}
  for name in pairs(OWN) do if name:match("^owner_%d+$") then names[#names + 1] = name end end
  table.sort(names)
  local tried = 0
  for _, name in ipairs(names) do
    local d = pan_diary()
    local pans = 0
    for i = 2, #OWN[name] do
      local p = OWN[name][i].p
      if MapView.zone(p[1], p[2], d.w, d.h, d.CFG) == "edge" and MapView.straightness(p) >= d.CFG.map_edge_straight then
        pans = pans + 1
      end
    end
    if pans >= 2 then
      tried = tried + 1
      d:openMap("rose")
      for i, s in ipairs(OWN[name]) do
        if i > 1 then run(Diary.CFG.idle_s - 0.5) end
        draw(d, { s })
      end
      run(Diary.CFG.idle_s + 0.5)
      t.eq(d.map, nil, name .. ": обе черты из края — роза закрыла карту")
    end
  end
  t.ok(tried >= 5, "роз владельца с обеими чертами из края: " .. tried)
end

-- ревью пачки 4: навигация пальцем перед розой к ней не цепляется — 2–3 сдвига с паузой 1 с, через 2 с роза владельца
-- (черты из края, паузы по 2 с): сдвиг до первого штриха страницы входит только напрямую (≤ idle_s от штриха), не
-- цепочкой через другой сдвиг — роза закрывает карту
function T.test_finger_pans_before_rose_do_not_chain()
  local OWN = require("fixtures.rose_owner")
  for _, name in ipairs({ "owner_03", "owner_07", "owner_11" }) do
    for n = 2, 3 do
      local d = pan_diary()
      d:openMap("rose")
      run(3)
      local before = count("riddle: map pan edge")
      for k = 1, n do
        if k > 1 then run(1) end
        local y = 560 + 20 * k -- туда-обратно: поле не упирается в край
        stroke(d, k % 2 == 1 and { 30, y, 330, y } or { 740, y, 440, y })
      end
      t.eq(count("riddle: map pan edge") - before, n, name .. ": " .. n .. " мазка пальцем — сдвиги")
      run(2)
      for i, s in ipairs(OWN[name]) do
        if i > 1 then run(Diary.CFG.idle_s - 0.5) end
        draw(d, { s })
      end
      run(Diary.CFG.idle_s + 0.5)
      t.eq(d.map, nil, name .. " после " .. n .. " сдвигов пальцем — роза закрыла карту")
    end
  end
end

-- страница карты дописана, палец лёг на тачпад и держит дольше idle_s: страница не кончается посреди жеста —
-- через idle_s после отрыва
function T.test_page_waits_while_pad_held()
  local d = pan_diary()
  d:openMap("rose")
  draw(d, F.cross_only)
  d:penDown(300, 950)
  for i = 1, 10 do
    d:penMove(300 + 3 * i, 950)
    run(0.5)
  end
  t.ok(5 > Diary.CFG.idle_s, "жест дольше idle_s")
  t.eq(#d.map.page.strokes, #F.cross_only, "палец на тачпаде — страница ещё пишется")
  d:penUp()
  run(Diary.CFG.idle_s - 0.5)
  t.eq(#d.map.page.strokes, #F.cross_only, "idle_s от отрыва ещё не прошло")
  run(1)
  t.eq(#d.map.page.strokes, 0, "страница кончилась через idle_s после жеста")
end

-- слепая карта (местности нет): двигать нечего — штрих от края и в нижней полосе — чернила и страница карты, как в
-- середине (роза у края слепой карты её закрывает)
function T.test_blind_map_zones_are_ink()
  local d = pan_diary()
  d.terrain = nil
  d:openMap("rose")
  stroke(d, { 30, 600, 230, 600 })
  t.ok(rect_at(d, 30, 600, false), "у края — чернила")
  t.eq(#d.map.page.strokes, 1, "штрих — на странице карты")
  stroke(d, { 300, 950, 400, 950 })
  t.ok(rect_at(d, 300, 950, false), "в нижней полосе — чернила")
  t.eq(#d.map.page.strokes, 2)
  t.eq(count("riddle: map pan"), 0, "сдвига нет")
end

-- угол выхода (верхний правый, внутри полосы края) на карте: удержание — выход из дневника, не сдвиг
function T.test_corner_exit_still_works_on_map()
  local d = pan_diary()
  local exits = 0
  d.exit = function() exits = exits + 1 end
  d:openMap("rose")
  local pushes = #d.pushes
  d:penDown(700, 50, 10)
  d:penMove(705, 52)
  d:penUp(10 + Diary.CFG.corner_hold_s + 0.2)
  t.eq(exits, 1, "удержание в углу — выход")
  t.eq(#d.pushes, pushes, "без сдвига")
  -- таймер угла при неподвижном пальце
  d:penDown(700, 50)
  run(Diary.CFG.corner_hold_s + 0.1)
  t.eq(exits, 2, "таймер угла — выход")
  d:penUp()
  -- из угла увели палец дальше slop — это сдвиг, не выход
  d:penDown(700, 50, 20)
  d:penMove(600, 50)
  d:penUp(20 + Diary.CFG.corner_hold_s + 0.2)
  t.eq(exits, 2, "увёл палец — не выход")
  t.eq(count("riddle: map pan edge"), 1, "а сдвиг")
end

-- срез 12: те же герои 15 минут (владелец 2026-11-16: «персонажей нужно сделать консистентными хотябы на 10-15 мин»).
-- Часы карты — подмена map_clock: os.date("*t", now_s)

-- городок у точки (1, 2): крест улиц через середину поля и дома, школа — герои вселенной найдут себе места
local function town()
  local b = function(x, y, kind)
    return { kind = kind, pts = { x - 20, y - 20, x + 20, y - 20, x + 20, y + 20, x - 20, y + 20 } }
  end
  return { center = { lat = 1, lon = 2 }, w = 1516, h = 2048, m_per_px = 0.7,
           streets = { { 300, 1024, 1200, 1024 }, { 758, 600, 758, 1500 } },
           buildings = { b(600, 900, "house"), b(900, 1150, "house"), b(650, 1200, "school") } }
end

local function copy(v) return require("dkjson").decode(require("dkjson").encode(v)) end

-- карта с героями «Властелина колец» (fixtures.map_parts) на городке; часы — clk.s секунд
local function kept_diary()
  local d = point_diary({ lat = 1, lon = 2, source = "wifi", acc = 34, ts = 1 })
  d.terrain = town()
  local m = require("riddle.mapdata").of(nil, nil, nil)
  m.cast = require("fixtures.map_parts").cast()
  d.controller.map = function() return m end
  local clk = { s = os.time({ year = 2026, month = 11, day = 16, hour = 12, min = 0 }) }
  d.map_clock = function() return os.date("*t", clk.s) end
  -- номер открытия (seed расстановки) стартует от настоящих часов (Diary.openMap): без фиксации расстановка героев
  -- плавает от прогона к прогону. Стенд ставит своё число
  Diary.map_opens = 1000
  return d, clk
end

local function heroes_of(d)
  local out = {}
  for _, h in ipairs(d.map:heroes()) do
    local tr = {}
    for _, p in ipairs(h.trail or {}) do tr[#tr + 1] = p[1] .. "," .. p[2] end
    out[#out + 1] = h.name .. "@" .. h.x .. "," .. h.y .. "[" .. table.concat(tr, " ") .. "]"
  end
  return table.concat(out, "; ")
end

-- имена героев открытой карты по алфавиту (срез 14: состав, не места)
local function names_of(d)
  local out = {}
  for _, h in ipairs(d.map:heroes()) do out[#out + 1] = h.name end
  table.sort(out)
  return table.concat(out, ",")
end

-- открыл, карта проявилась и сделала 2 шага -> имена героев, их места и следы
local function open_and_walk(d)
  d:openMap("rose")
  run(5)
  local tick0 = d.map.cast_state and d.map.cast_state.tick or 0
  run(Diary.CFG.map_step_s * 2)
  t.ok(#d.map:heroes() >= 1, "герои расставлены")
  t.ok((d.map.cast_state.tick or 0) >= tick0 + 2, "шаги идут")
  return names_of(d), heroes_of(d)
end

-- герои открытой карты расставлены, как при свежем открытии этих героев сейчас (riddle.cast.place: час открытия,
-- номер открытия, экран сейчас; выходят все): места те же, следов нет, шаги с начала
local function placed_anew(d)
  local v, names = d.map, {}
  for _, h in ipairs(v:heroes()) do names[h.name] = true end
  local rows = {}
  for _, c in ipairs(v.data.cast) do if names[c.name] then rows[#rows + 1] = c end end
  local want = require("riddle.cast").place(rows, v.terrain, d.map_clock(), v.seed, v:heroScreen(), true)
  local got, exp = {}, {}
  for i, h in ipairs(v:heroes()) do got[i] = h.name .. "@" .. h.x .. "," .. h.y .. (h.trail and "+trail" or "") end
  for i, h in ipairs(want) do exp[i] = h.name .. "@" .. h.x .. "," .. h.y end
  return table.concat(got, "; ") == table.concat(exp, "; ") and not v.cast_state.tick
end

function T.test_map_keep_cfg()
  t.eq(Diary.CFG.map_keep_s, 900, "15 минут (владелец 2026-11-16)")
end

-- срез 14 (владелец 2026-11-16: «не надо чтобы они стояли там же где были, надо чтобы они были»): через 2 и через
-- 14 минут — те же герои, расставленные заново, как при свежем открытии
function T.test_reopen_within_keep_same_heroes()
  for _, after in ipairs({ 120, 14 * 60 }) do
    local d, clk = kept_diary()
    local before = open_and_walk(d)
    d:closeMap("rose")
    clk.s = clk.s + after
    d.terrain = copy(d.terrain) -- файл местности прочитан заново
    local placed = count("riddle: map cast n=")
    d:openMap("rose")
    t.eq(names_of(d), before, after .. " с: те же герои")
    t.ok(placed_anew(d), after .. " с: расставлены заново, без прежних мест и следов")
    run(5)
    t.eq(count("riddle: map cast n="), placed, "состав не выбран заново")
    t.eq(count("riddle: map cast kept n="), 1)
    local tick = d.map.cast_state.tick or 0
    run(Diary.CFG.map_step_s)
    t.eq(d.map.cast_state.tick, tick + 1, "шаги идут")
  end
end

-- срез 14: 899 с со сменой часа (12:50 -> 13:04:59) — те же герои, по распорядку нового часа; в логе — новый час
function T.test_reopen_within_keep_other_hour()
  local d, clk = kept_diary()
  clk.s = clk.s + 50 * 60
  local before = open_and_walk(d)
  d:closeMap("rose")
  clk.s = clk.s + Diary.CFG.map_keep_s - 1
  t.eq(d.map_clock().hour, 13, "час сменился")
  local first = #LOG
  d:openMap("rose")
  t.eq(names_of(d), before, "те же герои")
  t.ok(placed_anew(d), "расставлены по 13 часам")
  local line
  for i = first + 1, #LOG do if LOG[i]:find("riddle: map cast", 1, true) then line = LOG[i] end end
  t.ok(line and line:find("riddle: map cast kept n=%d+ visible=%d+ hour=13$"), "строка kept: " .. tostring(line))
end

function T.test_reopen_after_keep_places_anew()
  local d, clk = kept_diary()
  open_and_walk(d)
  d:closeMap("rose")
  clk.s = clk.s + 16 * 60
  local placed = count("riddle: map cast n=")
  d:openMap("rose")
  run(5)
  t.ok(#d.map:heroes() >= 1)
  t.eq(count("riddle: map cast n="), placed + 1, "позже 15 минут — расстановка заново")
  t.eq(count("riddle: map cast kept"), 0)
end

function T.test_sleep_close_keeps_heroes()
  local d, clk = kept_diary()
  local before = open_and_walk(d)
  d:onSuspend()
  t.eq(d.map, nil)
  clk.s = clk.s + 5 * 60
  d:onResume()
  d:openMap("rose")
  t.eq(names_of(d), before, "сон закрыл карту — герои те же")
  t.eq(count("riddle: map cast kept n="), 1)
end

function T.test_clock_back_places_anew()
  local d, clk = kept_diary()
  open_and_walk(d)
  d:closeMap("rose")
  clk.s = clk.s - 3600
  local placed = count("riddle: map cast n=")
  d:openMap("rose")
  run(5)
  t.eq(count("riddle: map cast n="), placed + 1, "часы назад — расстановка заново")
  t.eq(count("riddle: map cast kept"), 0)
end

-- владелец уехал (far, новая местность), закрыл, открыл — герои новой местности, не старой
function T.test_far_move_then_close_keeps_new_terrain()
  local d, clk = kept_diary()
  local _, old_heroes = open_and_walk(d)
  -- новая местность — другой городок: дома и улицы сдвинуты, расстановка на нём не совпадает со старой
  local NEW = town()
  NEW.center = { lat = 1.05, lon = 2 }
  for _, b in ipairs(NEW.buildings) do
    for i = 1, #b.pts, 2 do b.pts[i], b.pts[i + 1] = b.pts[i] + 90, b.pts[i + 1] - 60 end
  end
  for _, st in ipairs(NEW.streets) do
    st[1], st[2], st[3], st[4] = st[1] + 90, st[2] - 60, st[3] + 90, st[4] - 60
  end
  d.point, d.terrain = { lat = 1.05, lon = 2, source = "wifi", acc = 30, ts = 2 }, NEW
  d.runner:done({ point_source = "wifi", acc = 30, aps = 5, write = "ok", terrain = { state = "fetched", ways = 5 } })
  t.eq(d.map.terrain, NEW)
  run(5)
  t.ok(d.map.cast_for == NEW and heroes_of(d) ~= old_heroes, "far: герои новой местности")
  -- места не сверяются с прежними (стоящие на месте герои совпали бы при любой местности того же вида): стоящие —
  -- ровно там, где их ставит riddle.cast.place на новой местности; шагавшие ушли с места, их не сверяем
  local v, names, rows = d.map, {}, {}
  for _, h in ipairs(v:heroes()) do names[h.name] = h end
  for _, c in ipairs(v.data.cast) do if names[c.name] then rows[#rows + 1] = c end end
  local want, standing = require("riddle.cast").place(rows, NEW, d.map_clock(), v.seed, v:heroScreen(), true), 0
  for _, w in ipairs(want) do
    local h = names[w.name]
    if #(h.trail or {}) == 0 then
      standing = standing + 1
      t.ok(h.x == w.x and h.y == w.y, "far: " .. w.name .. " стоит на месте новой местности")
    end
  end
  t.ok(standing >= 1, "far: есть стоящие герои для сверки")
  local new_heroes = names_of(d)
  d:closeMap("rose")
  clk.s = clk.s + 60
  d.terrain = copy(NEW)
  d:openMap("rose")
  t.eq(names_of(d), new_heroes, "открыл снова — герои новой местности")
  t.eq(count("riddle: map cast kept n="), 1)
end

-- карта без местности (blind) своих героев не ставит — закрыта, память о прежних остаётся (ревью среза 12, 3: как
-- закрытие до проявления героев)
function T.test_blind_close_keeps_heroes()
  local d, clk = kept_diary()
  local before = open_and_walk(d)
  d:closeMap("rose")
  t.ok(Diary.map_kept, "закрытие запомнило героев")
  local saved = d.terrain
  d.terrain = nil
  d:openMap("rose")
  run(5)
  d:closeMap("rose")
  t.ok(Diary.map_kept, "blind своих героев не ставил — память осталась")
  d.terrain = copy(saved)
  clk.s = clk.s + 60
  d:openMap("rose")
  t.eq(names_of(d), before, "те же герои")
end

-- ревью среза 12, Б1: карту открыли до генерации героев (map.cast пуст) — пустой состав не запоминается; раздел
-- появился, карта открыта снова в 15 минут — герои расставлены
function T.test_empty_cast_not_kept()
  local d, clk = kept_diary()
  local m = d.controller.map()
  local full = m.cast
  m.cast = {}
  d:openMap("rose")
  run(5)
  t.eq(#d.map:heroes(), 0, "героев нет")
  d:closeMap("rose")
  t.eq(Diary.map_kept, nil, "пустой состав не запомнен")
  m.cast = full
  clk.s = clk.s + 60
  local placed = count("riddle: map cast n=")
  d:openMap("rose")
  t.ok(#d.map:heroes() >= 1, "раздел появился — герои на карте")
  t.eq(count("riddle: map cast n="), placed + 1)
end

-- ревью среза 12, 2: граница окна — ровно map_keep_s после закрытия уже заново, на секунду раньше — те же
function T.test_keep_window_edge()
  for _, c in ipairs({ { Diary.CFG.map_keep_s - 1, true }, { Diary.CFG.map_keep_s, false } }) do
    local d, clk = kept_diary()
    local before = open_and_walk(d)
    d:closeMap("rose")
    clk.s = clk.s + c[1]
    d:openMap("rose")
    local same = names_of(d) == before and count("riddle: map cast kept n=") == 1
    t.eq(same, c[2], c[1] .. " с после закрытия")
  end
end

-- ревью среза 12, 3: карту открыли снова и закрыли, пока проступает тушь (герои ещё не на карте) — память о героях
-- не теряется
function T.test_close_during_reveal_keeps_heroes()
  local d, clk = kept_diary()
  local before = open_and_walk(d)
  d:closeMap("rose")
  clk.s = clk.s + 60
  d:openMap("rose")
  t.eq(d.map.cast_for, nil, "герои ещё не проявились")
  d:closeMap("rose")
  t.ok(Diary.map_kept, "память о героях осталась")
  clk.s = clk.s + 60
  d:openMap("rose")
  t.eq(names_of(d), before, "те же герои")
end

t.run(T)
