-- Раздумье и отказ на запись (срез 2): ответ дольше ponder_s прикрыт фразой из texts.thinking,
-- которая уходит, как только пришёл ответ; страница, законченная, пока ответ в пути, в модель не
-- уходит — на неё отказ из texts.busy. Харнес — как async_answer_spec.lua (заглушки KOReader, свои
-- часы, поддельный runner с ручным on_done, настоящий контроллер).
local t = require("t")
local stand = require("seal_stand")
local texts = require("riddle.texts")
local controller = require("riddle.controller")

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
-- сеть по умолчанию есть; тесты ожидания связи переключают NET
local NET = { on = true, up = true }
stub("ui/network/manager", { isWifiOn = function() return NET.on end, isConnected = function() return NET.up end })

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

local function ctl(cfg, random)
  return controller.new{
    cfg = cfg or { seal = stand.key() },
    -- открытая печать собирает контекст и пишет реплики: память без базы
    memory = { use_persona = function() return true end, session = function() return 1 end, summaries = function() return {} end,
               lore_text = function() return "" end, recent = function() return {} end, add = nop,
               lore_mtime = nop, import_lore = nop },
    read_file = function() return "PNG" end,
    b64 = function(s) return "B64" .. s end,
    remove = nop,
    now = function() return 1000 end,
    random = random or function() return 1 end,
    log = nop,
    llm_call = function() error("синхронный путь не должен вызываться") end,
    remote_fn = function() return function() return {} end end,
    absorb = function(payload) return payload.result, payload.err end,
  }
end

local function reply(read, text) return { result = { read = read, reply = text } } end

-- тесты меняют шаги раздумья; каждый дневник начинает с настоящих
local STEPS = { ponder_every_s = Diary.CFG.ponder_every_s, offline_step = Diary.CFG.offline_step,
                think_hold_s = Diary.CFG.think_hold_s }

local function diary(cfg, random)
  clock, timeline, LOG = 0, {}, {}
  NET.on, NET.up = true, true
  for k, v in pairs(STEPS) do Diary.CFG[k] = v end
  local d = setmetatable({
    canvas = bb_stub, tasks = {}, queue = {}, asks = {}, inflight = 0, strokes = {}, epoch = 0, w = 758, h = 1024,
    prompt = { rect = { x = 0, y = 0, w = 0, h = 0 } },
    face_answer = { ftsize = { getHeightAndAscender = function() return 52, 40 end } },
    stats = { frames = 0, frame_us = 0, frame_us_max = 0, sink_ticks = 0, sink_us = 0, sink_us_max = 0,
              ans_steps = 0, ans_us_max = 0, grey_px = 0, lost_ink = 0 },
    controller = ctl(cfg, random),
    runner = fake_runner(),
    revealed = {}, fades = {}, holds = {}, saves = 0,
  }, { __index = Diary })
  d.renderRegion = nop
  d.penNear = function() return false end
  d.countLostInk = function() return 0 end
  d.saveSample = function(self) self.saves = self.saves + 1 return "/tmp/page.png" end
  d.revealAnswer = function(self, text, ...)
    self.revealed[#self.revealed + 1] = text
    return Diary.revealAnswer(self, text, ...)
  end
  -- когда фраза на экране начала растворяться и когда закончила проявляться
  d.fadeAnswer = function(self)
    if self.answer and self.answer.phase ~= "fade" then self.fades[#self.fades + 1] = clock end
    return Diary.fadeAnswer(self)
  end
  d.armHold = function(self, a)
    if a.phase == "hold" and not a.held then a.held = true self.holds[#self.holds + 1] = clock end
    return Diary.armHold(self, a)
  end
  d.responder = function(png, cb, wait) d:respond(png, cb, wait) end
  return d
end

-- страница дописана: strokes — её штрихи (по умолчанию нет — чернила уже растворились)
local function page_done(d, strokes)
  d.page = { strokes = strokes or {}, ink = { 10, 200, 100, 260 } }
  d:onPageDone()
end

local T = {}

local function only_in(list, xs)
  for _, x in ipairs(xs) do if not in_list(list, x) then return false end end
  return true
end

function T.test_fast_answer_has_no_ponder()
  local d = diary()
  page_done(d)
  run(1.5)
  d.runner:done(reply("кто ты", "Мои страницы молчат."))
  run(30)
  t.eq(#d.revealed, 1, table.concat(d.revealed, " | "))
  t.eq(d.revealed[1], "Мои страницы молчат.")
  t.eq(count("riddle: ponder shown"), 0)
end

-- владелец 2026-10-25: раздумье — через 3 с после ухода страницы, не раньше
function T.test_ponder_waits_three_seconds()
  local d = diary()
  page_done(d)
  run(2.9)
  t.eq(#d.revealed, 0, "до 3 с фразы нет: " .. table.concat(d.revealed, " | "))
  t.eq(count("riddle: ponder shown"), 0)
  run(0.2)
  t.ok(in_list(texts.thinking, d.revealed[1]), "после 3 с — раздумье: " .. tostring(d.revealed[1]))
  t.eq(count("riddle: ponder shown after 3000 ms"), 1, table.concat(LOG, "\n"))
end

function T.test_slow_answer_ponder_then_answer()
  local d = diary()
  page_done(d)
  run(5)
  t.ok(in_list(texts.thinking, d.revealed[1]), "первой — фраза-раздумье: " .. tostring(d.revealed[1]))
  t.eq(count("riddle: ponder shown after 3000 ms"), 1, table.concat(LOG, "\n"))
  d.runner:done(reply("кто ты", "Мои страницы молчат."))
  local arrived = clock
  run(30)
  t.eq(d.revealed[2], "Мои страницы молчат.")
  t.eq(#d.revealed, 2)
  -- фраза растворяется сразу по приходу ответа (или по концу своего проявления), без answer_hold_s
  local start = math.max(d.holds[1], arrived)
  t.ok(d.fades[1] <= start + 0.1, string.format("растворение в %.2f, а ответ/проявление в %.2f", d.fades[1], start))
end

function T.test_queued_ponder_dropped_when_answer_arrives()
  local d = diary()
  local stroke = { t_end = 0, lvl = 0, p = { 20, 220 } }
  page_done(d, { stroke })
  run(4)
  t.eq(#d.revealed, 0, "чернила страницы не растворились — фраза ждёт")
  t.eq(#d.queue, 1, "фраза в очереди")
  t.eq(d.queue[1].kind, "think")
  d.runner:done(reply("кто ты", "Мои страницы молчат."))
  stroke.lvl = 4
  d:nextAnswer()
  run(30)
  t.eq(d.revealed[1], "Мои страницы молчат.", "фраза не проявлялась")
  t.eq(#d.revealed, 1)
end

function T.test_page_during_ponder_gets_refusal_without_model()
  local d = diary()
  page_done(d)
  run(4)
  page_done(d)
  t.eq(d.runner.started, 1, "вторая страница в модель не ушла")
  t.eq(d.saves, 1, "PNG только первой")
  t.eq(d.inflight, 1)
  t.eq(count("riddle: page during ponder -> refusal"), 1, table.concat(LOG, "\n"))
  for _, line in ipairs(LOG) do
    if line:find("page during ponder", 1, true) then t.eq(line, "riddle: page during ponder -> refusal", "без текста") end
  end
  d.runner:done(reply("кто ты", "первый"))
  run(60)
  t.ok(in_list(texts.thinking, d.revealed[1]), tostring(d.revealed[1]))
  t.ok(in_list(texts.busy, d.revealed[2]), "отказ: " .. tostring(d.revealed[2]))
  t.eq(d.revealed[3], "первый", "ответ на первую — после отказа")
  t.eq(#d.revealed, 3)
end

function T.test_three_pages_during_ponder_three_refusals_one_call()
  local d = diary()
  page_done(d)
  run(4)
  for _ = 1, 3 do
    page_done(d)
    run(1)
  end
  t.eq(d.runner.started, 1, "модель вызвана один раз")
  t.eq(d.saves, 1)
  -- отказы держатся по answer_hold_s и уходят сами: очередь не растёт, пока ответ в пути; на
  -- экране остаётся раздумье очередного шага, в очереди — не больше одной фразы шага
  run(60)
  t.ok(#d.queue == 0 or (#d.queue == 1 and d.queue[1].kind == "think"), "отказы не копятся")
  t.eq(d.answer and d.answer.kind, "think", "последний отказ растворился, стоит раздумье")
  d.runner:done(reply("кто ты", "первый"))
  run(60)
  t.ok(in_list(texts.thinking, d.revealed[1]))
  t.ok(only_in(texts.busy, { d.revealed[2], d.revealed[3], d.revealed[4] }), table.concat(d.revealed, " | "))
  local busy = 0
  for _, s in ipairs(d.revealed) do if in_list(texts.busy, s) then busy = busy + 1 end end
  t.eq(busy, 3, table.concat(d.revealed, " | "))
  t.eq(d.revealed[#d.revealed], "первый", "ответ последним")
  t.eq(count("riddle: page during ponder -> refusal"), 3)
end

function T.test_ceiling_gives_slow_phrase_and_frees_runner()
  local d = diary()
  page_done(d)
  run(30)
  d.runner:done(nil, "timeout")
  run(60)
  t.ok(in_list(texts.thinking, d.revealed[1]), tostring(d.revealed[1]))
  local last = d.revealed[#d.revealed]
  t.ok(in_list(texts.fail_slow, last), "медленно — последней, после шагов раздумья: " .. tostring(last))
  t.eq(d.inflight, 0)
  page_done(d)
  t.eq(d.runner.started, 2, "следующая страница уходит в модель")
end

-- без слова в конфиге дневник открыт сразу: раздумье и отказы работают и там
function T.test_ponder_and_refusal_without_seal()
  local d = diary({ seal = stand.none() })
  t.ok(d.controller.seal_open, "печати нет")
  page_done(d)
  run(4)
  page_done(d)
  t.eq(d.runner.started, 1)
  d.runner:done(reply("кто ты", "открытый"))
  run(60)
  t.ok(in_list(texts.thinking, d.revealed[1]), tostring(d.revealed[1]))
  t.ok(in_list(texts.busy, d.revealed[2]), tostring(d.revealed[2]))
  t.eq(d.revealed[3], "открытый")
end

-- сон во время раздумья: фраза и таймер раздумья пропадают вместе со страницей
function T.test_suspend_drops_ponder()
  local d = diary()
  page_done(d)
  run(1)
  d:onSuspend()
  run(10)
  t.eq(#d.revealed, 0)
  t.eq(count("riddle: ponder shown"), 0)
end

-- страница заканчивается, когда фраза-раздумье уже полностью на экране и ждёт ответа (hold без
-- таймера): отказ встаёт в очередь, и nextAnswer в onPageDone будит фразу — она уходит, отказ
-- проявляется. Без этого вызова фраза висит до касания
function T.test_busy_while_think_holds_wakes_think()
  local d = diary()
  Diary.CFG.ponder_every_s = 60 -- одна фраза: её сменил бы следующий шаг, а не отказ
  page_done(d)
  run(10)
  t.eq(d.answer and d.answer.phase, "hold", "фраза стоит")
  t.eq(#d.fades, 0, "сама не уходит")
  page_done(d)
  run(10)
  t.ok(#d.fades >= 1, "фраза ушла за отказом")
  t.ok(in_list(texts.busy, d.revealed[2]), "отказ проявился: " .. tostring(d.revealed[2]))
  t.eq(d.runner.started, 1, "в модель отказ не ушёл")
end

-- сколько фраз-раздумий проявилось и все ли разные
local function thinking_shown(d)
  local n, seen, distinct = 0, {}, true
  for _, s in ipairs(d.revealed) do
    if in_list(texts.thinking, s) then
      n = n + 1
      if seen[s] then distinct = false end
      seen[s] = true
    end
  end
  return n, distinct
end

-- владелец 2026-10-26: «я думаю» шагами — первый через 3 с, дальше каждые 5 с, пока нет ответа
function T.test_ponder_steps_three_then_every_five()
  local d = diary()
  page_done(d)
  for n, at in ipairs({ 3, 8, 13, 18 }) do
    run(at - 0.1 - clock)
    t.eq(count("riddle: ponder step " .. n), 0, string.format("шаг %d не раньше %d с", n, at))
    run(0.2)
    t.eq(count("riddle: ponder step " .. n), 1, string.format("шаг %d на %d с", n, at))
  end
  d.runner:done(reply("кто ты", "Мои страницы молчат."))
  run(60)
  t.eq(count("riddle: ponder step 5"), 0, "после ответа шагов нет")
  t.eq(d.revealed[#d.revealed], "Мои страницы молчат.")
  local n, distinct = thinking_shown(d)
  t.ok(n >= 2, "фраз проявилось " .. n) -- каждая стоит не меньше think_hold_s: не по фразе на шаг
  t.ok(distinct, "фразы разные: " .. table.concat(d.revealed, " | "))
end

-- владелец 2026-11-05: «когда дневник думает, он очень быстро меняет фразы» — проявившаяся целиком
-- фраза «думаю» стоит не меньше 10 с, прежде чем её сменит следующая «думаю»
function T.test_thinking_phrase_stands_ten_seconds_before_next_thinking()
  local d = diary()
  page_done(d)
  run(45)
  t.ok(#d.holds >= 2, "фраз проявилось " .. #d.holds)
  t.ok(#d.fades >= 2, "фраз сменилось " .. #d.fades)
  for i = 1, #d.fades do
    local stood = d.fades[i] - d.holds[i]
    t.ok(stood >= 10 - 1e-6, string.format("фраза %d стояла %.2f с после проявления", i, stood))
    t.ok(stood <= 10.5, string.format("фраза %d висела %.2f с — дольше положенного", i, stood))
  end
  t.eq(count("riddle: ponder step 3"), 1, "шаги раздумья идут своим ходом: " .. table.concat(LOG, "\n"))
end

-- отказ на страницу, написанную во время «думаю», не ждёт остатка удержания: в очереди за стоящей
-- фразой [следующая «думаю», отказ] — фраза уходит сразу, как и перед ответом
function T.test_refusal_does_not_wait_for_thinking_hold()
  local d = diary()
  page_done(d)
  run(9) -- первая фраза проявилась, вторая шагом на 8 с ждёт в очереди
  t.eq(#d.holds, 1, "первая фраза проявилась")
  t.eq(#d.fades, 0, "до отказа она стоит")
  local came = clock
  page_done(d)
  run(0.5)
  t.eq(#d.fades, 1, "отказ в очереди — фраза уходит")
  t.ok(d.fades[1] - came <= 0.1, string.format("ушла через %.2f с", d.fades[1] - came))
end

-- пришёл ответ — фраза, уже стоящая, уходит сразу, не ждёт своих 10 с
function T.test_answer_does_not_wait_for_thinking_hold()
  local d = diary()
  page_done(d)
  run(9) -- первая фраза проявилась, вторая шагом на 8 с ждёт в очереди
  t.eq(#d.holds, 1, "первая фраза проявилась")
  t.eq(#d.fades, 0, "до 10 с она стоит")
  local came = clock
  d.runner:done(reply("кто ты", "Мои страницы молчат."))
  run(0.5)
  t.eq(#d.fades, 1, "ответ пришёл — фраза уходит")
  t.ok(d.fades[1] - came <= 0.1, string.format("ушла через %.2f с", d.fades[1] - came))
  run(30)
  t.eq(d.revealed[#d.revealed], "Мои страницы молчат.")
end

-- фраза шага, ещё не показанная, к следующему шагу устарела: в очереди не копятся (длинная
-- фраза проявляется и растворяется дольше ponder_every_s)
function T.test_new_step_replaces_waiting_phrase()
  local d = diary()
  local stroke = { t_end = 0, lvl = 0, p = { 20, 220 } }
  page_done(d, { stroke })
  run(19)
  t.eq(count("riddle: ponder step 4"), 1)
  t.eq(#d.revealed, 0, "чернила не растворились — ничего не показано")
  t.eq(#d.queue, 1, "в очереди одна фраза")
  t.eq(d.queue[1].kind, "think")
end

-- «отбивки не повторять»: и когда мешок фраз пересыпается посреди ожидания. random(n) = n берёт
-- последнюю из мешка; 29 фраз уже вынуто — в мешке две, пересыпка на 3-м шаге, без учёта ожидания
-- 4-й шаг повторил бы 2-й
function T.test_ponder_phrases_never_repeat_in_one_wait()
  local d = diary(nil, function(n) return n end)
  for _ = 1, #texts.thinking - 2 do d.controller:pick(texts.thinking) end
  page_done(d)
  run(44)
  t.eq(count("riddle: ponder step 9"), 1, "9 шагов до 43 с")
  d.runner:done(nil, "timeout")
  run(60)
  local n, distinct = thinking_shown(d)
  t.ok(n >= 3, "фраз проявилось " .. n) -- шагов 9, но каждая показанная фраза стоит think_hold_s
  t.ok(distinct, "повтор: " .. table.concat(d.revealed, " | "))
end

-- радио включено, связи нет: запрос ждёт связь, раздумье идёт; связь вернулась — запрос уходит,
-- потолок ответа — свои ceil_s от старта
function T.test_radio_on_waits_for_link_then_asks()
  local d = diary()
  NET.up = false
  page_done(d)
  run(5.5)
  t.eq(d.runner.started, 0, "связи нет — запрос не ушёл")
  t.ok(in_list(texts.thinking, d.revealed[1]), "раздумье идёт, пока ждём связь: " .. tostring(d.revealed[1]))
  NET.up = true
  run(1.1)
  t.eq(d.runner.started, 1, "связь вернулась — запрос ушёл")
  t.eq(d.runner.jobs[1].opts.timeout_s, 30, "потолок — целиком от старта")
  -- запрос в пути дольше 3-го шага: ожидание связи уже снято, шаг — обычное раздумье
  run(8)
  t.eq(count("riddle: ponder step 3"), 1, "3-й шаг — раздумье")
  t.eq(d.inflight, 1, "ответ ещё ждём")
  d.runner:done(reply("кто ты", "Мои страницы молчат."))
  run(60)
  t.eq(d.revealed[#d.revealed], "Мои страницы молчат.")
  for _, s in ipairs(d.revealed) do t.ok(not in_list(texts.fail_offline, s), "без «гонца нет»: " .. s) end
  t.eq(d.inflight, 0)
end

-- связи нет и к 3-му шагу: вместо 3-й фразы — «гонца нет», ожидание снято (поздняя связь запрос
-- не запускает), следующая страница уходит как обычно
function T.test_no_link_by_third_step_gives_offline()
  local d = diary()
  NET.up = false
  page_done(d)
  run(12.9)
  t.eq(count("riddle: ponder step 2"), 1)
  t.eq(d.inflight, 1)
  run(0.2)
  t.eq(count("riddle: ponder step 3"), 0, "3-й шаг — не раздумье")
  t.eq(d.inflight, 0, "ожидание кончилось")
  run(30)
  t.eq(d.runner.started, 0)
  t.ok(in_list(texts.fail_offline, d.revealed[#d.revealed]), "гонца нет: " .. tostring(d.revealed[#d.revealed]))
  -- вторая фраза ждёт, пока первая отстоит think_hold_s; отказ приходит раньше — она не показана
  t.eq((thinking_shown(d)), 1, "одна фраза до отказа: " .. table.concat(d.revealed, " | "))
  NET.up = true
  run(30)
  t.eq(d.runner.started, 0, "связь после отказа запрос не запускает")
  t.eq(count("riddle: ponder step"), 2, "новых шагов нет")
  page_done(d)
  t.eq(d.runner.started, 1, "следующая страница уходит")
end

-- отказ привязан к номеру шага, а не ко времени
function T.test_offline_follows_step_number()
  local d = diary()
  Diary.CFG.offline_step = 2
  NET.up = false
  page_done(d)
  run(7.9)
  t.eq(d.inflight, 1, "до 2-го шага ждём")
  run(0.2)
  t.eq(d.inflight, 0, "2-й шаг — отказ")
  t.eq(count("riddle: ponder step"), 1)
  run(30)
  t.ok(in_list(texts.fail_offline, d.revealed[#d.revealed]), tostring(d.revealed[#d.revealed]))
end

-- не включено ничего, что даёт интернет: «гонца нет» сразу, без раздумья и без запроса
function T.test_no_channel_on_gives_offline_at_once()
  local d = diary()
  NET.on, NET.up = false, false
  page_done(d)
  t.eq(d.inflight, 0, "сразу")
  t.eq(d.runner.started, 0)
  run(30)
  t.eq(#d.revealed, 1, table.concat(d.revealed, " | "))
  t.ok(in_list(texts.fail_offline, d.revealed[1]), tostring(d.revealed[1]))
  t.eq(count("riddle: ponder step"), 0)
end

-- радио выключили, пока ждали связь: ждать нечего — «гонца нет» сразу
function T.test_radio_off_during_link_wait_gives_offline_now()
  local d = diary()
  NET.up = false
  page_done(d)
  run(4)
  NET.on = false
  run(1.1)
  t.eq(d.inflight, 0)
  t.eq(d.runner.started, 0)
  run(30)
  t.ok(in_list(texts.fail_offline, d.revealed[#d.revealed]), tostring(d.revealed[#d.revealed]))
  t.eq(count("riddle: ponder step"), 1)
end

-- сон и закрытие во время ожидания связи снимают опрос: связь потом запрос не запускает
function T.test_suspend_during_link_wait_drops_poll()
  local d = diary()
  NET.up = false
  page_done(d)
  run(4)
  d:onSuspend()
  run(10)
  t.eq(#timeline, 0, "таймеров не осталось")
  NET.up = true
  run(30)
  t.eq(d.runner.started, 0)
  t.eq(#d.revealed, 1, "только раздумье до сна: " .. table.concat(d.revealed, " | "))
end

function T.test_close_during_link_wait_drops_poll()
  local d = diary()
  NET.up = false
  page_done(d)
  run(4)
  d:onCloseWidget()
  NET.up = true
  run(30)
  t.eq(d.runner.started, 0)
  t.eq(count("riddle: ponder step"), 1)
end

-- то же в первую секунду ожидания связи, до первого срабатывания опроса: он уже стоит в очереди и тоже снимается
function T.test_suspend_in_first_poll_second_drops_poll()
  local d = diary()
  NET.up = false
  page_done(d)
  run(0.5)
  d:onSuspend()
  t.eq(#timeline, 0, "опрос снят и до первого срабатывания")
  NET.up = true
  run(30)
  t.eq(d.runner.started, 0)
end

function T.test_close_in_first_poll_second_drops_poll()
  local d = diary()
  NET.up = false
  page_done(d)
  run(0.5)
  d:onCloseWidget()
  NET.up = true
  run(30)
  t.eq(d.runner.started, 0)
end

-- Notion 40313e60: отказы растворились, а ответ ещё в пути (ждать можно до ceil_s) — экран не
-- остаётся пустым: снова новая фраза-раздумье, не дожидаясь следующего шага
function T.test_thinking_returns_after_refusal_while_answer_in_flight()
  local d = diary()
  Diary.CFG.ponder_every_s = 60 -- шагов раздумья нет: фразу вернул бы только отказ-уход
  page_done(d)
  run(4)
  t.ok(in_list(texts.thinking, d.revealed[1]), "раздумье: " .. tostring(d.revealed[1]))
  page_done(d)
  run(40)
  t.eq(d.inflight, 1, "ответ ещё в пути")
  t.ok(in_list(texts.busy, d.revealed[2]), "отказ: " .. tostring(d.revealed[2]))
  t.ok(in_list(texts.thinking, d.revealed[3]), "после отказа снова раздумье: " .. tostring(d.revealed[3]))
  t.ok(d.revealed[3] ~= d.revealed[1], "фраза новая: " .. tostring(d.revealed[3]))
  t.eq(#d.revealed, 3, table.concat(d.revealed, " | "))
  t.eq(d.answer and d.answer.kind, "think", "на экране раздумье")
  d.runner:done(reply("кто ты", "первый"))
  run(60)
  t.eq(d.revealed[4], "первый", "ответ показывается как обычно")
  t.eq(#d.revealed, 4, table.concat(d.revealed, " | "))
end

-- несколько отказов подряд: раздумье возвращается только после последнего
function T.test_thinking_returns_only_after_last_refusal()
  local d = diary()
  Diary.CFG.ponder_every_s = 60
  page_done(d)
  run(4)
  page_done(d)
  page_done(d)
  run(40)
  local busy, last_busy = 0, 0
  for i, s in ipairs(d.revealed) do if in_list(texts.busy, s) then busy = busy + 1 last_busy = i end end
  t.eq(busy, 2, table.concat(d.revealed, " | "))
  t.eq(#d.revealed, last_busy + 1, "после последнего отказа — ровно одна фраза: " .. table.concat(d.revealed, " | "))
  t.ok(in_list(texts.thinking, d.revealed[#d.revealed]))
  t.eq(d.answer and d.answer.kind, "think")
end

-- ответ пришёл вместе с растворением отказа: раздумье не возвращается
function T.test_no_thinking_after_refusal_when_answer_already_came()
  local d = diary()
  Diary.CFG.ponder_every_s = 60
  page_done(d)
  run(4)
  page_done(d)
  run(2)
  d.runner:done(reply("кто ты", "первый"))
  run(60)
  t.eq(d.revealed[#d.revealed], "первый", table.concat(d.revealed, " | "))
  t.eq(thinking_shown(d), 1, "раздумье было одно: " .. table.concat(d.revealed, " | "))
end

-- Notion 40613e60: контроллер счёл первую страницу случайным касанием (ответ nil), а отказ на вторую,
-- что писалась в ожидании, уже показывается или ждёт показа: ответа не будет, и отказ растворяется по
-- обычному таймеру удержания, а не висит до касания
local CFG_HOLD = Diary.CFG.answer_hold_s

local function refusal_with_pending_answer()
  local d = diary()
  local cbs = {}
  d.responder = function(png, cb) cbs[#cbs + 1] = cb end
  Diary.CFG.ponder_every_s = 60
  page_done(d)
  run(4)
  t.ok(in_list(texts.thinking, d.revealed[1]), "раздумье: " .. tostring(d.revealed[1]))
  page_done(d)
  t.eq(count("riddle: page during ponder -> refusal"), 1, table.concat(LOG, "\n"))
  return d, cbs
end

function T.test_refusal_released_when_accidental_nil_comes_while_revealing()
  local d, cbs = refusal_with_pending_answer()
  for _ = 1, 2000 do
    if d.answer and d.answer.kind == "busy" and d.answer.phase == "reveal" then break end
    run(0.01)
  end
  t.eq(d.answer and d.answer.kind, "busy", "отказ проявляется")
  cbs[1](nil)
  run(CFG_HOLD + 10)
  t.eq(d.answer, nil, "отказ растворился сам")
  t.eq(#d.revealed, 2, table.concat(d.revealed, " | "))
end

function T.test_refusal_released_when_accidental_nil_comes_while_queued()
  local d, cbs = refusal_with_pending_answer()
  t.eq(#d.queue, 1, "отказ ждёт в очереди")
  cbs[1](nil)
  run(CFG_HOLD + 20)
  t.ok(in_list(texts.busy, d.revealed[2]), "отказ показался: " .. tostring(d.revealed[2]))
  t.eq(d.answer, nil, "и ушёл сам")
  t.eq(#d.revealed, 2, table.concat(d.revealed, " | "))
end

-- отказ уже держится на таймере, когда пришло nil: растворяется по нему, не зависает
function T.test_refusal_on_timer_goes_after_accidental_nil()
  local d, cbs = refusal_with_pending_answer()
  for _ = 1, 2000 do
    if d.answer and d.answer.kind == "busy" and d.answer.phase == "hold" then break end
    run(0.01)
  end
  t.eq(d.answer and d.answer.kind, "busy", "отказ держится")
  cbs[1](nil)
  run(CFG_HOLD + 6)
  t.eq(d.answer, nil, "отказ растворился сам")
end

-- Notion 41013e60: страница, дописанная, пока дневник думает, ждёт в очереди вместе со следующим
-- шагом раздумья: отказ стоит впереди, новая фраза-раздумье — за ним; их порядок на экране тот же
function T.test_queue_keeps_refusal_before_next_thinking_phrase()
  local d = diary()
  Diary.CFG.ponder_every_s = 4
  page_done(d)
  run(3.5)
  t.eq(d.answer and d.answer.kind, "think", "первая фраза проявляется")
  page_done(d)
  local seen = {}
  for _ = 1, 100 do
    local kinds = {}
    for _, x in ipairs(d.queue) do kinds[#kinds + 1] = x.kind or "answer" end
    seen[table.concat(kinds, ",")] = true
    run(0.25)
  end
  t.ok(seen["busy,think"], "в очереди были отказ и за ним раздумье")
  t.ok(not seen["think,busy"], "раздумье не обгоняет отказ")
  t.ok(in_list(texts.thinking, d.revealed[1]), "первое: раздумье")
  t.ok(in_list(texts.busy, d.revealed[2]), "второе: отказ: " .. tostring(d.revealed[2]))
  t.ok(in_list(texts.thinking, d.revealed[3]), "третье: новое раздумье: " .. tostring(d.revealed[3]))
  t.ok(d.revealed[3] ~= d.revealed[1], "фраза другая")
  t.eq(d.runner.started, 1, "в модель страница-отказ не ушла")
end

t.run(T)
