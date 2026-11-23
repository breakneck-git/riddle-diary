-- Последний штрих страницы тает так же, как остальные. respond синхронный: пока идёт запрос к
-- модели (1.6–2.5 с на живом логе 2026-10-23), цикл UIManager стоит и sinkTick не идёт. Страница
-- кончается через idle_s=2.5 с после последнего отрыва, а штрих тает с 2.0 до 2.9 с — без
-- ожидания последняя буква висела полурастаявшей весь запрос. Запрос уходит, когда растаял весь
-- её штрих (по времени, не по состоянию: перо рядом может задержать таяние — запрос не ждёт его).
local t = require("t")

local NOW = 0
local TASKS = {}
local function stub(name, mod) package.preload[name] = function() return mod end end
local nop = function() end

stub("ffi/blitbuffer", { COLOR_WHITE = 0xFF, COLOR_BLACK = 0, TYPE_BB8 = 1, new = function() return { fill = nop } end })
stub("device", { isKindle = function() return false end, screen = {} })
stub("ffi/freetype", { newFaceSize = function() return {} end })
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/rendertext", {})
stub("ui/uimanager", {
  scheduleIn = function(_, s, fn) TASKS[#TASKS + 1] = { s = s, fn = fn } end,
  unschedule = function(_, fn)
    for i = #TASKS, 1, -1 do if TASKS[i].fn == fn then table.remove(TASKS, i) end end
  end,
  nextTick = nop,
})
stub("ui/widget/widget", { extend = function(_, o) return o end })
stub("logger", { info = nop, warn = nop, err = nop, dbg = nop })
-- fts как в KOReader: целые микросекунды
stub("ui/time", { monotonic = function() return NOW end, to_s = function(x) return x / 1e6 end,
                  to_ms = function(x) return x / 1e3 end, to_us = function(x) return x end })
stub("libs/libkoreader-lfs", { attributes = nop, dir = nop, mkdir = nop })

local Diary = require("riddle_diarywidget")
local S = 1e6

-- страница с одним штрихом, отпущенным age секунд назад; что получил responder
local function page_done(age)
  TASKS = {}
  NOW = 100 * S
  local got = {}
  local st = { p = { 300, 200, 300, 500 }, b = { 300, 200, 300, 500 }, lvl = 1, t_end = NOW - age * S }
  local d = setmetatable({
    canvas = {}, tasks = {}, queue = {}, inflight = 0, strokes = { st }, epoch = 0, w = 758, h = 1024,
    stats = { frames = 0, frame_us = 0, frame_us_max = 0, sink_ticks = 0, sink_us = 0, sink_us_max = 0,
              ans_steps = 0, ans_us_max = 0, grey_px = 0, lost_ink = 0 },
    page = { strokes = { st }, ink = { 300, 200, 300, 500 } },
  }, { __index = Diary })
  d.textFloor = function() return 0 end
  d.saveSample = function() return "/s.png" end
  d.responder = function(png, ...) got.png, got.nargs, got.wait = png, 1 + select("#", ...), select(2, ...) end
  d:onPageDone()
  return got, d
end

local T = {}

function T.test_request_waits_for_last_stroke_to_dissolve()
  local got, d = page_done(2.5) -- idle_s: страница кончилась ровно сейчас
  t.eq(got.png, nil, "запрос не уходит, пока последний штрих не растаял")
  t.eq(d.inflight, 1, "ответ уже ждут (armHold видит его)")
  t.eq(#TASKS, 1, "один отложенный запрос")
  -- последний шаг таяния: 2.0 + 3 * 0.3 = 2.9 с после отрыва, плюс два тика sink (0.1) на отрисовку
  t.ok(math.abs(TASKS[1].s - 0.6) < 1e-6, "через 0.6 с, а не " .. TASKS[1].s)
  TASKS[1].fn()
  t.eq(got.png, "/s.png", "потом — запрос")
end

-- в окне ожидания начат новый штрих: синхронный запрос заморозил бы перо — ждём отрыва
function T.test_request_waits_for_pen_up()
  local got, d = page_done(2.5)
  d.cur = { p = { 400, 400 } }
  TASKS[#TASKS].fn()
  t.eq(got.png, nil, "перо на бумаге — запроса нет")
  t.ok(math.abs(TASKS[#TASKS].s - 0.1) < 1e-6, "переспрос через тик sink")
  TASKS[#TASKS].fn()
  t.eq(got.png, nil, "всё ещё пишет")
  d.cur = nil
  TASKS[#TASKS].fn()
  t.eq(got.png, "/s.png", "перо поднято — запрос")
end

function T.test_old_ink_goes_at_once()
  local got = page_done(3.5)
  t.eq(got.png, "/s.png", "всё растаяло — запрос сразу")
  t.eq(#TASKS, 0)
end

-- responder получает только PNG, колбэк и таблицу ожидания связи (810e): распознавания рун у
-- страницы нет (ивент 2026-10-23 прошёл)
function T.test_responder_gets_png_and_callback_only()
  local got = page_done(3.5)
  t.eq(got.nargs, 3, "аргументы responder")
  t.eq(type(got.wait), "table", "третий — ожидание связи")
  t.eq(Diary.classifyRune, nil, "classifyRune")
  t.eq(Diary.saveStrokes, nil, "saveStrokes")
end

function T.test_closed_meanwhile_drops_the_request()
  local got, d = page_done(2.5)
  d.canvas = nil -- onCloseWidget / после сна виджет не рисует; wrapper schedule молчит
  TASKS[1].fn()
  t.eq(got.png, nil)
end

t.run(T)
