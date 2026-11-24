-- Сон и реплика дневника (Notion 40813e60-bc8d-8129): без печати последняя реплика переживает сон
-- и после пробуждения стоит на экране целиком, пока кто-то не коснётся пальцем; приглашение —
-- только на чистой странице. С печатью, фраза-раздумье, ответ на таймере — сон стирает страницу.
-- Виджет на заглушках KOReader, как в answer_cycle_spec: часы и планировщик — свои.
local t = require("t")

local clock, timeline, LOG = 0, {}, {}

local function stub(name, mod) package.preload[name] = function() return mod end end

local nop = function() end
local FREED = 0
local bb_stub = { fill = nop, free = function() FREED = FREED + 1 end }
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
  setDirty = nop,
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

local controller = require("riddle.controller")
local stand = require("seal_stand")

-- настенные часы контроллера (deps.now): идут с планировщиком, сон их уводит вперёд (slept), таймеры KOReader — нет
local slept = 0
local function wall() return 1000 + math.floor(clock) + slept end

-- rules: nil — контроллера нет; false — печати нет; таблица — правила печати (cfg.seal). Контроллер настоящий,
-- on_sleep помечает сон (ctl.slept) и делает своё
local function diary(rules)
  clock, timeline, LOG, FREED, slept = 0, {}, {}, 0, 0
  local ctl
  if rules ~= nil then
    ctl = controller.new{ cfg = { seal = rules and stand.rules(rules) or stand.none() }, now = wall,
                          random = function() return 1 end, log = nop }
    ctl.on_sleep = function(self)
      self.slept = true
      return controller.on_sleep(self)
    end
  end
  local d = setmetatable({
    canvas = bb_stub, tasks = {}, queue = {}, inflight = 0, strokes = {}, epoch = 0, w = 758, h = 1024,
    prompt = { rect = { x = 0, y = 0, w = 0, h = 0 } },
    face_answer = { ftsize = { getHeightAndAscender = function() return 52, 40 end } },
    stats = { frames = 0, frame_us = 0, frame_us_max = 0, sink_ticks = 0, sink_us = 0, sink_us_max = 0,
              ans_steps = 0, ans_us_max = 0, grey_px = 0, lost_ink = 0 },
    controller = ctl, asks = {}, painted = {},
  }, { __index = Diary })
  d.renderRegion = nop
  d.paintRegion = function(self, x, y, w, h) self.painted[#self.painted + 1] = { x, y, w, h } end
  d.showInvitation = function() LOG[#LOG + 1] = "SHOWN invitation" end
  d.penNear = function() return false end
  d.countLostInk = function() return 0 end
  return d, ctl
end

-- ответ пришёл от контроллера (как в onPageDone)
local function arrive(d, text, kind)
  d.queue[#d.queue + 1] = { text = text, top = 100, page = { strokes = {} }, kind = kind, t0 = clock }
  d:nextAnswer()
end

-- сон и пробуждение подряд, как отдаёт KOReader; контроллер — заглушка с печатью или без
local function sleep_and_wake(d)
  d:onSuspend()
  d:onResume()
  run(1)
end

local T = {}

function T.test_unsealed_sleep_keeps_the_held_reply_without_invitation()
  local d, ctl = diary(false)
  arrive(d, "Я помню")
  run(60)
  t.eq(d.answer.phase, "hold")
  sleep_and_wake(d)
  t.ok(d.answer and d.answer.phase == "hold", "реплика стоит после пробуждения")
  t.eq(FREED, 0, "её слой не освобождён")
  t.eq(count("SHOWN invitation"), 0, "приглашения поверх нет")
  t.eq(#d.painted, 1, "реплика попала в холст до общей перерисовки")
  t.eq(d.painted[1][1], d.answer.block.rect.x)
  run(3600)
  t.ok(d.answer, "и стоит дальше, пока не коснутся")
  t.eq(count("answer gone"), 0)
  t.ok(ctl.slept, "контроллер о сне знает")
end

function T.test_touch_after_wake_dissolves_the_kept_reply()
  local d = diary(false)
  arrive(d, "Я помню")
  run(60)
  sleep_and_wake(d)
  d:hurryAnswer()
  run(30)
  t.eq(d.answer, nil)
  t.eq(count("answer gone"), 1, "уходит от касания, как днём")
end

function T.test_sleep_during_reveal_shows_the_reply_whole_after_wake()
  local d = diary(false)
  arrive(d, "Я помню тебя")
  run(0.2)
  t.eq(d.answer.phase, "reveal", "сон застал проявление")
  sleep_and_wake(d)
  t.eq(d.answer.phase, "hold")
  t.eq(d.answer.i, #d.answer.block.glyphs, "все буквы в слое")
  run(3600)
  t.ok(d.answer, "и стоит без таймера")
end

function T.test_sleep_drops_unfinished_page_and_requests_but_not_the_reply()
  local d = diary(false)
  arrive(d, "Я помню")
  run(60)
  d.strokes = { { lvl = 0 } }
  d.page = { strokes = {} }
  d.asks = { nop }
  sleep_and_wake(d)
  t.eq(#d.strokes, 0, "недописанные штрихи сброшены")
  t.eq(d.page, nil)
  t.eq(#d.asks, 0, "очередь запросов пуста")
  t.ok(d.answer, "реплика осталась")
end

function T.test_sealed_sleep_wipes_the_reply_and_shows_invitation()
  local d, ctl = diary({ key = true, on_sleep = true })
  ctl:seal_toggle() -- ключ узнан: печать открыта
  arrive(d, "Я помню")
  run(60)
  sleep_and_wake(d)
  t.eq(d.answer, nil, "сон закрывает печать — страница чистая")
  t.eq(count("SHOWN invitation"), 1, "и приглашение")
  t.ok(not ctl.seal_open)
end

-- печать есть, но сон её не закрывает (on_sleep нет, spec §6): реплика переживает сон, как без печати
function T.test_sleep_keeps_reply_when_sleep_does_not_close()
  local d, ctl = diary({ key = true, minutes = 30 })
  ctl:seal_toggle()
  arrive(d, "Я помню")
  run(60)
  slept = 600 -- десять минут сна: простой не истёк
  sleep_and_wake(d)
  t.ok(d.answer and d.answer.phase == "hold", "реплика стоит после пробуждения")
  t.eq(count("SHOWN invitation"), 0)
  t.ok(ctl.seal_open)
end

-- таймеры KOReader во сне не идут: пробуждение само проверяет простой — истёк, печать закрыта, на экране первая
-- строка чистой страницы
function T.test_resume_checks_idle()
  local d, ctl = diary({ key = true, minutes = 30 })
  ctl:seal_toggle()
  arrive(d, "Я помню")
  run(60)
  slept = 2 * 3600
  d:onSuspend()
  d:onResume()
  -- сразу, до первого тика: реплика не должна попасть в перерисовку после заставки
  t.ok(not ctl.seal_open, "простой во сне закрыл печать")
  t.eq(d.answer, nil, "реплика открытой печати стёрта")
  t.eq(#d.painted, 0, "реплика не вернулась на холст")
  t.eq(count("SHOWN invitation"), 1, "первая строка чистой страницы")
  run(1)
  t.eq(count("SHOWN invitation"), 1, "одна")
end

-- сон снимает таймер простоя: срок, наставший во сне, не рисует ничего до пробуждения (экран у заставки) — проверяет
-- его onResume
function T.test_sleep_drops_idle_timer()
  local d, ctl = diary({ key = true, minutes = 30 })
  ctl:seal_toggle()
  arrive(d, "Я помню")
  run(60)
  d:onSuspend()
  run(3600)
  t.eq(count("SHOWN invitation"), 0, "во сне не рисуется")
  t.eq(count("seal idle"), 0)
  t.ok(d.answer, "реплика ждёт пробуждения")
  d:onResume()
  t.eq(d.answer, nil, "пробуждение стёрло реплику")
  t.eq(count("SHOWN invitation"), 1)
end

-- таймер простоя после ответа: N минут без записи — печать закрыта, ответ стёрт, на экране первая строка
-- простой закрыл печать раньше таймера — её прочёл кто-то другой (часы ушли вперёд, seal_open): таймер, сработав,
-- всё равно стирает реплику открытой печати
function T.test_idle_timer_wipes_after_reader_closed()
  local d, ctl = diary({ key = true, minutes = 30 })
  ctl:seal_toggle()
  arrive(d, "Я помню")
  run(60)
  slept = 3600 -- часы вперёд без сна
  t.ok(not ctl.seal_open, "читатель увидел простой и закрыл печать")
  t.ok(d.answer, "реплика ещё на экране")
  run(1800)
  t.eq(d.answer, nil, "таймер стёр реплику открытой печати")
  t.eq(count("SHOWN invitation"), 1)
end

-- ревью Task 7 (M5): таймер простоя один — новый взвод снимает прошлый
function T.test_one_idle_timer()
  local d, ctl = diary({ key = true, minutes = 30 })
  ctl:seal_toggle()
  arrive(d, "Я помню")
  local first = d.seal_task
  t.ok(first and d.tasks[first], "таймер взведён ответом")
  d:armSeal()
  t.ok(d.seal_task and d.seal_task ~= first, "новый таймер")
  t.eq(d.tasks[first], nil, "прошлый снят")
  local n = 0
  for _, task in ipairs(timeline) do if task.fn == first then n = n + 1 end end
  t.eq(n, 0, "прошлого нет в планировщике")
end

function T.test_idle_timer_wipes_the_reply()
  local d, ctl = diary({ key = true, minutes = 30 })
  ctl:seal_toggle()
  arrive(d, "Я помню")
  run(1799 - clock)
  t.ok(ctl.seal_open, "до срока открыта")
  t.ok(d.answer, "ответ стоит")
  run(2)
  t.ok(not ctl.seal_open, "через 30 минут без записи закрыта")
  t.eq(d.answer, nil, "ответ стёрт")
  t.eq(FREED, 1, "слой ответа освобождён")
  t.eq(count("SHOWN invitation"), 1, "первая строка чистой страницы")
end

-- часы прыгнули назад (Review Focus 3): таймер сработал, а простой по часам не истёк — печать открыта, таймер
-- взведён заново на остаток
function T.test_idle_timer_rearms_after_clock_back()
  local d, ctl = diary({ key = true, minutes = 30 })
  ctl:seal_toggle()
  arrive(d, "Я помню")
  run(100)
  slept = -600 -- часы назад на 10 минут
  run(1800 - clock + 1)
  t.ok(ctl.seal_open, "раньше срока не закрыта")
  t.ok(d.answer, "ответ стоит")
  run(1800)
  t.ok(not ctl.seal_open, "по новому отсчёту закрыта")
  t.eq(d.answer, nil)
end

-- печати без minutes таймер не нужен: ответ стоит сколько угодно
function T.test_no_idle_timer_without_minutes()
  local d, ctl = diary({ key = true })
  ctl:seal_toggle()
  arrive(d, "Я помню")
  run(10 * 3600)
  t.ok(ctl.seal_open)
  t.ok(d.answer)
end

function T.test_no_controller_counts_as_no_seal()
  local d = diary(nil)
  arrive(d, "Я помню")
  run(60)
  sleep_and_wake(d)
  t.ok(d.answer, "печати нет — реплика остаётся")
end

function T.test_sleep_wipes_the_thinking_phrase()
  local d = diary(false)
  d.inflight = 1
  arrive(d, "Думаю", "think")
  run(60)
  sleep_and_wake(d)
  t.eq(d.answer, nil, "фраза-раздумье — не реплика")
  t.eq(count("SHOWN invitation"), 1)
end

function T.test_sleep_wipes_a_reply_that_goes_by_timer()
  local d = diary(false)
  arrive(d, "первый")
  d.queue[#d.queue + 1] = { text = "второй", top = 100, page = { strokes = {} } }
  run(0.1)
  d:onSuspend()
  t.eq(d.answer, nil, "за ответом ждали следующих — сон их уронил, ответ уходит с ними")
  t.eq(#d.queue, 0, "очередь сброшена")
end

t.run(T)
