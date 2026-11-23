-- Реплика на перебивание (владелец 2026-10-25: «пусть реддл реагирует, когда пишу пока он думает»):
-- перо перебило ответ, пока он проявлялся или держался по таймеру (за ним кто-то ждёт), — в конце новой страницы сразу, без модели,
-- реплика из texts.interrupted; ответ модели на эту страницу — после неё. Одна на перебивание; ответ,
-- который уже уходит, и случайное касание реплики не дают; реплика — не ответ (не в память, не в
-- devtest). Харнес — как ponder_spec.lua, страницы пишутся настоящими penDown/penMove/penUp.
local t = require("t")
local texts = require("riddle.texts")
local controller = require("riddle.controller")

local clock, timeline, LOG, ADDS = 0, {}, {}, {}

local function stub(name, mod) package.preload[name] = function() return mod end end

local nop = function() end
local bb_stub = { fill = nop, free = nop, paintRect = nop }
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

local function ctl(cfg)
  return controller.new{
    cfg = cfg or { password_variants = { "salandusa" } },
    -- открытая печать собирает контекст и пишет реплики: память без базы
    memory = { use_persona = function() return true end, session = function() return 1 end, summaries = function() return {} end,
               lore_text = function() return "" end, recent = function() return {} end,
               add = function(_, _, who, text) ADDS[#ADDS + 1] = who .. ":" .. tostring(text) end,
               lore_mtime = nop, import_lore = nop },
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
end

local function reply(read, text) return { result = { read = read, reply = text } } end

local function diary(cfg)
  clock, timeline, LOG, ADDS = 0, {}, {}, {}
  local d = setmetatable({
    canvas = bb_stub, tasks = {}, queue = {}, asks = {}, inflight = 0, strokes = {}, epoch = 0, w = 758, h = 1024,
    prompt = { rect = { x = 0, y = 0, w = 0, h = 0 } },
    face_answer = { ftsize = { getHeightAndAscender = function() return 52, 40 end } },
    stats = { frames = 0, frame_us = 0, frame_us_max = 0, sink_ticks = 0, sink_us = 0, sink_us_max = 0,
              ans_steps = 0, ans_us_max = 0, grey_px = 0, lost_ink = 0 },
    controller = ctl(cfg),
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
  d.responder = function(png, cb) d:respond(png, cb) end
  return d
end

local T = {}

local CFG_HOLD = Diary.CFG.answer_hold_s

local LONG = "Первый ответ дневника, длинный и неторопливый, чтобы перо успело его перебить."
local INTERJECTION = "riddle: page after interrupted answer -> interjection"

-- штрих пером: от (x0, y0) к (x1, y1); без второй точки — касание точкой
local function stroke(d, x0, y0, x1, y1)
  d:penDown(x0, y0)
  if x1 then d:penMove(x1, y1) end
  d:penUp()
end

local function write(d) stroke(d, 100, 400, 400, 500) end

-- идти по времени, пока ответ на экране не окажется в фазе phase
local function until_phase(d, phase)
  for _ = 1, 2000 do
    if d.answer and d.answer.phase == phase then return end
    run(0.01)
  end
  error("фаза " .. phase .. " не наступила")
end

-- первая страница и её ответ на экране в фазе phase
local function answer_on_screen(d, phase)
  write(d)
  run(3)
  t.eq(d.runner.started, 1, "первая страница ушла в модель")
  d.runner:done(reply("кто ты", LONG))
  until_phase(d, phase)
  t.eq(d.revealed[1], LONG)
end

local function interjections(d)
  local n = 0
  for _, s in ipairs(d.revealed) do if in_list(texts.interrupted, s) then n = n + 1 end end
  return n
end

local function interrupted_during(phase, cfg)
  local d = diary(cfg)
  answer_on_screen(d, phase)
  write(d)
  t.eq(count("riddle: answer hurried by the pen during " .. phase), 1, table.concat(LOG, "\n"))
  run(3)
  t.eq(d.runner.started, 2, "новая страница ушла в модель")
  t.eq(count(INTERJECTION), 1, table.concat(LOG, "\n"))
  d.runner:done(reply("и ещё", "второй"))
  run(120)
  t.ok(in_list(texts.interrupted, d.revealed[2]), "реплика: " .. tostring(d.revealed[2]))
  t.eq(d.revealed[3], "второй", "ответ модели — после реплики")
  t.eq(#d.revealed, 3, table.concat(d.revealed, " | "))
  return d
end

function T.test_pen_during_reveal_gives_interjection_then_answer()
  interrupted_during("reveal")
end

-- удержание с таймером (за ответом кто-то ждёт): ответ ещё идёт — перебивание
function T.test_pen_during_timed_hold_gives_interjection_then_answer()
  local d = diary()
  answer_on_screen(d, "hold")
  d.queue[#d.queue + 1] = { text = "следом", top = 100, page = { strokes = {} } }
  d:nextAnswer()
  t.ok(d.answer.task, "за ответом очередь — удержание по таймеру")
  write(d)
  t.eq(count("riddle: answer hurried by the pen during hold"), 1)
  run(3)
  t.eq(d.runner.started, 2)
  t.eq(count(INTERJECTION), 1, table.concat(LOG, "\n"))
  d.runner:done(reply("и ещё", "второй"))
  run(120)
  t.eq(d.revealed[2], "следом")
  t.ok(in_list(texts.interrupted, d.revealed[3]), "реплика: " .. tostring(d.revealed[3]))
  t.eq(d.revealed[4], "второй", "ответ модели — после реплики")
  t.eq(#d.revealed, 4, table.concat(d.revealed, " | "))
end

-- последний ответ стоит до касания: прочитал и пишешь дальше — это не перебивание, реплики нет
function T.test_pen_during_endless_hold_gives_no_interjection()
  local d = diary()
  answer_on_screen(d, "hold")
  t.eq(d.answer.task, nil, "последний ответ — без таймера")
  write(d)
  run(3)
  t.eq(d.runner.started, 2, "страница ушла в модель")
  d.runner:done(reply("и ещё", "второй"))
  run(120)
  t.eq(count(INTERJECTION), 0, table.concat(LOG, "\n"))
  t.eq(interjections(d), 0, table.concat(d.revealed, " | "))
  t.eq(d.revealed[2], "второй")
  t.eq(#d.revealed, 2)
end

-- перо поверх самой реплики, пока ответ модели на перебившую страницу ещё в пути: прежний отказ,
-- второй реплики нет, ответ не теряется
function T.test_pen_over_interjection_while_answer_in_flight_gets_refusal()
  local d = diary()
  answer_on_screen(d, "reveal")
  write(d)
  run(3)
  t.eq(d.runner.started, 2)
  until_phase(d, "reveal")
  t.ok(in_list(texts.interrupted, d.revealed[2]), "реплика проявляется: " .. tostring(d.revealed[2]))
  t.eq(d.inflight, 1, "ответ модели ещё в пути")
  write(d)
  run(3)
  t.eq(count("riddle: page during ponder -> refusal"), 1, table.concat(LOG, "\n"))
  t.eq(d.runner.started, 2, "третья страница в модель не ушла")
  d.runner:done(reply("и ещё", "второй"))
  run(120)
  t.eq(count(INTERJECTION), 1)
  -- ответ дольше ponder_s: за погашенной репликой — раздумье, отказ на третью, потом ответ
  t.ok(in_list(texts.thinking, d.revealed[3]), "раздумье: " .. tostring(d.revealed[3]))
  t.ok(in_list(texts.busy, d.revealed[4]), "отказ: " .. tostring(d.revealed[4]))
  t.eq(d.revealed[5], "второй", "ответ на перебившую страницу не потерян")
  t.eq(#d.revealed, 5, table.concat(d.revealed, " | "))
end

-- ответ модели пришёл, пока реплика ещё проявляется: ждёт её конца и не теряется
function T.test_answer_before_interjection_ends_waits_for_it()
  local d = diary()
  answer_on_screen(d, "reveal")
  write(d)
  run(2.6) -- страница кончилась, чернила ещё не догорели: реплика в очереди
  t.eq(count(INTERJECTION), 1)
  d.runner:done(reply("и ещё", "второй"))
  until_phase(d, "reveal")
  t.ok(in_list(texts.interrupted, d.revealed[2]), "проявляется реплика: " .. tostring(d.revealed[2]))
  t.eq(#d.queue, 1, "ответ ждёт в очереди")
  run(120)
  t.eq(d.revealed[3], "второй")
  t.eq(#d.revealed, 3)
end

-- ответ уже уходит (за ним очередь или таймер удержания): касание его не перебивает, реплики нет
function T.test_pen_during_fade_gives_no_interjection()
  local d = diary()
  answer_on_screen(d, "hold")
  d:fadeAnswer()
  write(d)
  run(3)
  t.eq(d.runner.started, 2)
  d.runner:done(reply("и ещё", "второй"))
  run(120)
  t.eq(count(INTERJECTION), 0)
  t.eq(interjections(d), 0, table.concat(d.revealed, " | "))
  t.eq(d.revealed[2], "второй")
end

-- случайное касание гасит ответ, но это не запись: ни модели, ни реплики
function T.test_tiny_touch_over_answer_gives_no_interjection()
  local d = diary()
  answer_on_screen(d, "reveal")
  stroke(d, 300, 600)
  run(120)
  t.eq(count("riddle: page too small"), 1, table.concat(LOG, "\n"))
  t.eq(count(INTERJECTION), 0)
  t.eq(interjections(d), 0)
  t.eq(d.runner.started, 1)
  -- и следующая страница на чистом экране — без реплики: перебивание ушло с тем касанием
  write(d)
  run(3)
  d.runner:done(reply("и ещё", "второй"))
  run(120)
  t.eq(count(INTERJECTION), 0)
  t.eq(d.revealed[2], "второй")
end

-- одно перебивание — одна реплика: ни второй штрих той же страницы, ни перо поверх самой реплики
-- новых реплик не дают
function T.test_one_interjection_per_interruption()
  local d = diary()
  answer_on_screen(d, "reveal")
  write(d)
  stroke(d, 120, 520, 380, 560)
  run(3)
  t.eq(count(INTERJECTION), 1)
  d.runner:done(reply("и ещё", "второй"))
  until_phase(d, "reveal")
  t.ok(in_list(texts.interrupted, d.revealed[2]), "реплика: " .. tostring(d.revealed[2]))
  write(d) -- перо поверх реплики
  t.eq(count("riddle: answer hurried by the pen during reveal"), 2, table.concat(LOG, "\n"))
  run(3)
  t.eq(d.runner.started, 3, "третья страница ушла в модель")
  d.runner:done(reply("третье", "третий"))
  run(120)
  t.eq(count(INTERJECTION), 1, table.concat(LOG, "\n"))
  t.eq(interjections(d), 1, table.concat(d.revealed, " | "))
  t.eq(d.revealed[#d.revealed], "третий")
end

-- реплика — не ответ: в память сессии (история диалога и пересказ берутся из неё) идут только
-- записи и ответы модели. Печати нет — дневник открыт и пишет память
function T.test_interjection_not_in_memory()
  interrupted_during("reveal", {})
  t.eq(#ADDS, 4, table.concat(ADDS, " | "))
  for _, s in ipairs(ADDS) do
    for _, x in ipairs(texts.interrupted) do t.ok(not s:find(x, 1, true), "реплика в памяти: " .. s) end
  end
  t.eq(ADDS[4], "diary:второй")
end

-- Notion 40413e60: контроллер счёл перебившую страницу случайным касанием (ответ nil) — за репликой
-- ответа не будет, и она растворяется по обычному таймеру удержания, а не висит до касания
local function accidental_after_interjection(phase_of_interjection)
  local d = diary()
  local cbs = {}
  d.responder = function(png, cb) cbs[#cbs + 1] = cb end
  write(d)
  run(3)
  cbs[1](LONG, false) -- ответ на первую страницу: сразу на экран
  until_phase(d, "reveal")
  write(d) -- перо перебило
  run(3)
  t.eq(count(INTERJECTION), 1, table.concat(LOG, "\n"))
  t.eq(#cbs, 2, "страница ушла в модель")
  if phase_of_interjection == "hold" then
    until_phase(d, "hold")
    t.ok(in_list(texts.interrupted, d.revealed[2]), "реплика на экране")
  end
  return d, cbs
end

function T.test_accidental_after_interjection_released_when_shown()
  local d, cbs = accidental_after_interjection("hold")
  t.eq(d.inflight, 1)
  cbs[2](nil) -- случайное касание: ответа не будет
  t.eq(d.inflight, 0)
  run(CFG_HOLD + 4)
  t.eq(d.answer, nil, "реплика растворилась сама")
  t.eq(d.revealed[2] ~= nil and in_list(texts.interrupted, d.revealed[2]), true)
  t.eq(#d.revealed, 2, table.concat(d.revealed, " | "))
end

-- ответ nil пришёл, пока реплика ещё проявляется: по концу проявления — тот же таймер
function T.test_accidental_after_interjection_released_while_revealing()
  local d, cbs = accidental_after_interjection("reveal")
  until_phase(d, "reveal")
  t.ok(in_list(texts.interrupted, d.revealed[2]), "реплика проявляется")
  cbs[2](nil)
  run(CFG_HOLD + 6)
  t.eq(d.answer, nil, "реплика растворилась сама")
  t.eq(#d.revealed, 2, table.concat(d.revealed, " | "))
end

-- реплика ещё в очереди (чернила не догорели), когда пришло nil: показывается и уходит по таймеру
function T.test_accidental_after_interjection_released_while_queued()
  local d = diary()
  local cbs = {}
  d.responder = function(png, cb) cbs[#cbs + 1] = cb end
  write(d)
  run(3)
  cbs[1](LONG, false)
  until_phase(d, "reveal")
  write(d)
  run(2.6)
  t.eq(count(INTERJECTION), 1, table.concat(LOG, "\n"))
  cbs[2](nil)
  run(CFG_HOLD + 20)
  t.ok(in_list(texts.interrupted, d.revealed[2]), "реплика показалась: " .. tostring(d.revealed[2]))
  t.eq(d.answer, nil, "и ушла сама")
  t.eq(#d.revealed, 2, table.concat(d.revealed, " | "))
end

-- прежний бессрочный hold не сломан: настоящий ответ на перебившую страницу — как был, и последний
-- ответ стоит до касания
function T.test_real_answer_after_interjection_still_endless()
  local d = interrupted_during("reveal")
  t.eq(d.answer and d.answer.phase, "hold", "последний ответ стоит")
  t.eq(d.answer.task, nil, "без таймера")
end

t.run(T)
