-- Цикл ответа в виджете на заглушках KOReader: проявление -> удержание -> растворение -> следующий.
-- Последний ответ стоит до касания (владелец 2026-10-23); в тест-режиме devtest ("cycles=N") ждущий
-- лишний ответ добавлен, только пока раунд не последний, а TEST finished пишется, когда последний встал.
-- Часы и планировщик — свои: UIManager:scheduleIn кладёт задачу в очередь, run() крутит время.
local t = require("t")

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
                  to_us = function(x) return x * 1e6 end })
stub("libs/libkoreader-lfs", { attributes = nop, dir = nop })

local Diary = require("riddle_diarywidget")
require("riddle.devtest").install(Diary, { rssKB = function() return 0 end, RIDDLE_DIR = "/nonexistent",
                                          pixels = nop, near = nop, clampRect = nop })

-- крутит время до clock + s, выполняя задачи по порядку
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

local function diary(test)
  clock, timeline, LOG = 0, {}, {}
  local d = setmetatable({
    canvas = {}, tasks = {}, queue = {}, inflight = 0, strokes = {}, epoch = 0, w = 758, h = 1024,
    prompt = { rect = { x = 0, y = 0, w = 0, h = 0 } },
    face_answer = { ftsize = { getHeightAndAscender = function() return 52, 40 end } },
    stats = { frames = 0, frame_us = 0, frame_us_max = 0, sink_ticks = 0, sink_us = 0, sink_us_max = 0,
              ans_steps = 0, ans_us_max = 0, grey_px = 0, lost_ink = 0 },
    test = test,
  }, { __index = Diary })
  d.renderRegion = nop
  d.penNear = function() return false end
  d.countLostInk = function() return 0 end
  return d
end

-- ответ пришёл от контроллера (как в onPageDone)
local function arrive(d, text)
  d.queue[#d.queue + 1] = { text = text, top = 100, page = { strokes = {} } }
  d:nextAnswer()
end

local T = {}

function T.test_last_answer_stays_on_screen_without_touch()
  local d = diary(nil)
  arrive(d, "Я помню")
  run(3600)
  t.ok(d.answer, "через час ответ всё ещё на экране")
  t.eq(d.answer.phase, "hold")
  t.eq(count("answer gone"), 0)
end

function T.test_touch_dissolves_the_held_answer()
  local d = diary(nil)
  arrive(d, "Я помню")
  run(60)
  d:hurryAnswer()
  run(30)
  t.eq(d.answer, nil, "касание растворило ответ")
  t.eq(count("answer gone"), 1)
end

function T.test_first_of_two_answers_goes_by_timer_second_stays()
  local d = diary(nil)
  arrive(d, "первый")
  d.queue[#d.queue + 1] = { text = "второй", top = 100, page = { strokes = {} } }
  run(3600)
  t.eq(count("answer revealed"), 2, "оба проявились")
  t.eq(count("answer gone"), 1, "первый ушёл сам")
  t.ok(d.answer and d.answer.phase == "hold", "второй — последний — стоит")
end

function T.test_follower_arriving_later_releases_the_held_answer()
  local d = diary(nil)
  arrive(d, "первый")
  run(600)
  t.eq(count("answer gone"), 0, "пока один — стоит")
  arrive(d, "второй")
  run(600)
  t.eq(count("answer gone"), 1, "за ним пришёл следующий — первый ушёл по таймеру")
  t.eq(count("answer revealed"), 2)
  t.ok(d.answer and d.answer.phase == "hold", "второй стоит")
end

function T.test_answer_with_page_in_flight_goes_by_timer()
  local d = diary(nil)
  d.inflight = 1
  arrive(d, "первый")
  run(600)
  t.eq(count("answer gone"), 1, "страница в пути — текущий ответ не вечный")
end

-- devtest "cycles=N": последний ответ раунда стоит, как в жизни (до касания), а прогон заканчивается
-- (TEST finished), когда он встал на удержание; лишний ждущий ответ — только пока раунд не последний
function T.test_test_mode_last_answer_stays_and_run_finishes_when_it_holds()
  local d = diary({ cycles = 1, n = 1, answers = 0, exit = false, shots = false })
  arrive(d, "Я помню")
  run(120)
  t.eq(count("TEST finished"), 1, "прогон дошёл до конца, когда ответ встал")
  t.eq(count("TEST finished, 1 pages, 1 answers"), 1, "числа те же: страниц и ответов")
  t.eq(count("answer gone"), 0, "последний ответ не растворился сам")
  t.ok(d.answer and d.answer.phase == "hold" and not d.answer.task, "стоит без таймера")
  t.eq(d.test, nil)
end

function T.test_test_mode_not_last_answer_goes_by_timer()
  local d = diary({ cycles = 2, n = 1, answers = 0, exit = false, shots = false })
  d.testWrite = function() end
  arrive(d, "первый")
  run(120)
  t.eq(count("answer gone"), 1, "ответ не последнего раунда уходит по таймеру")
  t.eq(count("TEST finished"), 0, "раунд не последний — прогон идёт")
end

function T.test_test_mode_second_of_two_answers_stays_and_run_finishes()
  local d = diary({ cycles = 2, n = 1, answers = 0, exit = false, shots = false })
  d.testWrite = function() end
  arrive(d, "первый")
  run(120)
  d.test.n = 2
  arrive(d, "второй")
  run(120)
  t.eq(count("TEST finished, 2 pages, 2 answers"), 1)
  t.ok(d.answer and d.answer.phase == "hold", "последний стоит")
  t.eq(count("answer gone"), 1, "ушёл только первый")
end

-- ответы в devtest "cycles=N": фраза-раздумье и отказ — не ответ цикла. Следующая синтетическая страница
-- идёт поверх настоящего ответа, а не поверх фразы (иначе она получила бы отказ и в модель не ушла),
-- и фраза в тест-режиме ждёт ответа так же, как в рабочем
local function test_diary()
  local d = diary({ cycles = 3, n = 1, answers = 0, exit = false, shots = false })
  d.writes = 0
  d.testWrite = function(self) self.writes = self.writes + 1 end
  return d
end

local function arrive_kind(d, text, kind)
  d.queue[#d.queue + 1] = { text = text, top = 100, page = { strokes = {} }, kind = kind, t0 = clock }
  d:nextAnswer()
end

function T.test_test_mode_think_is_not_an_answer()
  local d = test_diary()
  d.inflight = 1
  arrive_kind(d, "Думаю", "think")
  run(30)
  t.eq(d.test.answers, 0, "фраза-раздумье не считается ответом")
  t.eq(d.writes, 0, "следующая страница поверх фразы не пошла")
  t.eq(count("TEST page"), 0)
end

function T.test_test_mode_busy_is_not_an_answer()
  local d = test_diary()
  d.inflight = 1
  arrive_kind(d, "Не сейчас", "busy")
  run(30)
  t.eq(d.test.answers, 0, "отказ не считается ответом")
  t.eq(d.writes, 0)
  t.eq(count("TEST page"), 0)
end

-- реплика на перебивание — тоже не ответ цикла: страница поверх неё не идёт, «+1» к очереди ей нет
function T.test_test_mode_interject_is_not_an_answer()
  local d = test_diary()
  d.inflight = 1
  arrive_kind(d, "Ты перебиваешь меня", "interject")
  run(30)
  t.eq(d.test.answers, 0, "реплика не считается ответом")
  t.eq(d.writes, 0)
  t.eq(count("TEST page"), 0)
end

function T.test_test_mode_interject_alone_stays_like_in_work()
  local d = test_diary()
  arrive_kind(d, "Ты перебиваешь меня", "interject")
  run(600)
  t.ok(d.answer and d.answer.phase == "hold", "реплика стоит")
  t.eq(count("answer gone"), 0, "без добавки к очереди таймера нет")
end

-- отказ в тест-режиме — без «+1» к очереди: один, без страниц в пути, он стоит до касания, как в рабочем,
-- а не уходит по таймеру
function T.test_test_mode_busy_alone_stays_like_in_work()
  local d = test_diary()
  arrive_kind(d, "Не сейчас", "busy")
  run(600)
  t.ok(d.answer and d.answer.phase == "hold", "отказ стоит")
  t.eq(count("answer gone"), 0, "без добавки к очереди таймера нет")
  t.eq(d.test.answers, 0)
end

function T.test_test_mode_think_waits_for_the_answer_like_in_work()
  local d = test_diary()
  d.inflight = 1
  arrive_kind(d, "Думаю", "think")
  run(600)
  t.ok(d.answer and d.answer.phase == "hold", "фраза стоит")
  t.eq(count("answer gone"), 0, "в тест-режиме она не гаснет сразу из-за добавки к очереди")
end

function T.test_test_mode_answer_after_think_is_answer_one()
  local d = test_diary()
  d.inflight = 1
  arrive_kind(d, "Думаю", "think")
  run(5)
  arrive(d, "Я помню")
  d.inflight = 0
  run(5)
  t.eq(count("answer gone"), 1, "фраза ушла, как пришёл ответ")
  t.eq(d.test.answers, 1, "ответ — первый")
  t.eq(d.writes, 1, "страница 2 пошла поверх ответа")
  t.eq(count("TEST page 2 goes over answer 1 while it is in 'reveal'"), 1, table.concat(LOG, "\n"))
end

-- рабочий режим (self.test == nil) не меняется: строка armHold с «+1» вычисляется только в тест-режиме
function T.test_work_mode_think_alone_stays_and_goes_when_follower_queued()
  local d = diary(nil)
  d.inflight = 1
  arrive_kind(d, "Думаю", "think")
  run(600)
  t.ok(d.answer and d.answer.phase == "hold", "одинокая фраза стоит")
  t.eq(count("answer gone"), 0)
  arrive(d, "Я помню")
  run(5)
  t.eq(count("answer gone"), 1, "за ней пришёл ответ — фраза ушла")
end

t.run(T)
