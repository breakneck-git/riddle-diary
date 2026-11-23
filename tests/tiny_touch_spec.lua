-- Случайное касание (владелец 2026-10-25: «оч маленькая картинка похоже на случайные касания,
-- их же мы не будем отдавать в ллм»): страница, чей PNG меньше 32 px по обеим сторонам, в модель
-- не уходит — ни фразы-раздумья, ни ответа, inflight не растёт, во время раздумья это не отказ.
-- Одна узкая сторона (тире) — как прежде: дополнение до 32 и в модель. Харнес — как ponder_spec.lua.
local t = require("t")
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
               lore_text = function() return "" end, recent = function() return {} end, add = nop,
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
  clock, timeline, LOG = 0, {}, {}
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

-- страница дописана: strokes — её штрихи (по умолчанию нет — чернила уже растворились)

-- ink — рамка чернил в пикселях экрана; PNG = (рамка + 8 px полей) / sample_scale 2
local TINY = { 300, 300, 302, 301 }   -- точка: PNG 10x9
local DASH = { 10, 200, 100, 210 }    -- тире: PNG 54x14, узкая сторона одна
local WORD = { 10, 200, 100, 260 }    -- слово: PNG 54x39

-- Diary.CFG общий для всех тестов файла: правки возвращаются и когда fn упала посередине
local function with_cfg(over, fn)
  local saved = {}
  for k, v in pairs(over) do saved[k] = Diary.CFG[k] Diary.CFG[k] = v end
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do Diary.CFG[k] = v end
  if not ok then error(err, 0) end
end

local function page_done(d, ink, strokes)
  d.page = { strokes = strokes or {}, ink = ink or WORD }
  d:onPageDone()
end

local function counting_responder(d)
  d.calls = 0
  local real = d.responder
  d.responder = function(png, cb) d.calls = d.calls + 1 return real(png, cb) end
end

local T = {}

function T.test_tiny_page_never_reaches_model()
  local d = diary()
  counting_responder(d)
  page_done(d, TINY)
  t.eq(d.inflight, 0, "inflight не вырос")
  run(30)
  t.eq(d.calls, 0, "responder не вызван")
  t.eq(d.runner.started, 0, "runner не запущен")
  t.eq(d.saves, 0, "PNG не сохранён")
  t.eq(#d.revealed, 0, "ни раздумья, ни ответа: " .. table.concat(d.revealed, " | "))
  t.eq(#d.queue, 0)
  t.eq(count("riddle: page too small 10x9 -> skipped"), 1, table.concat(LOG, "\n"))
end

function T.test_narrow_page_still_goes_to_model()
  local d = diary()
  page_done(d, DASH)
  t.eq(d.runner.started, 1, "тире уходит в модель")
  t.eq(d.saves, 1)
  t.eq(count("riddle: page too small"), 0)
end

-- касание во время раздумья — не отказ «я ещё думаю»: молча пропущено
function T.test_tiny_page_during_ponder_is_not_refusal()
  local d = diary()
  page_done(d, WORD)
  run(3)
  page_done(d, TINY)
  t.eq(count("riddle: page during ponder"), 0, table.concat(LOG, "\n"))
  t.eq(d.inflight, 1)
  t.eq(d.runner.started, 1)
  t.eq(d.saves, 1)
  d.runner:done(reply("кто ты", "первый"))
  run(60)
  t.ok(in_list(texts.thinking, d.revealed[1]), tostring(d.revealed[1]))
  t.eq(d.revealed[2], "первый")
  t.eq(#d.revealed, 2, table.concat(d.revealed, " | "))
  -- после касания следующая страница идёт как обычно
  page_done(d, WORD)
  t.eq(d.runner.started, 2)
end

-- без runner (ответ блокирует цикл) и без контроллера (сонный дневник) — то же
function T.test_tiny_page_sync_and_sleepy_paths()
  for _, mode in ipairs({ "sync", "sleepy" }) do
    local d = diary()
    d.runner = nil
    if mode == "sleepy" then d.controller = nil end
    counting_responder(d)
    page_done(d, TINY)
    run(30)
    t.eq(d.calls, 0, mode .. ": responder не вызван")
    t.eq(d.inflight, 0, mode)
    t.eq(#d.revealed, 0, mode)
  end
end

-- после сна (страница сброшена) касание тоже пропускается, слово уходит
function T.test_tiny_page_after_sleep_reset()
  local d = diary()
  page_done(d, WORD)
  run(3)
  d:resetPage()
  page_done(d, TINY)
  t.eq(d.inflight, 0)
  t.eq(d.runner.started, 1, "касание после сна не ушло")
  page_done(d, WORD)
  t.eq(d.runner.started, 2, "слово после сна уходит в модель")
end

-- контроллер вернул nil (PNG оказался касанием, напр. подменённый devsample): ничего не
-- проявляется, раздумье на экране уходит, будто пришёл ответ, следующая страница идёт в модель
function T.test_nil_text_from_responder_dropped()
  local d = diary()
  local cbs = {}
  d.responder = function(_, cb) cbs[#cbs + 1] = cb end
  page_done(d, WORD)
  run(5)
  t.ok(in_list(texts.thinking, d.revealed[1]), "раздумье на экране")
  cbs[1](nil, false)
  run(60)
  t.eq(d.inflight, 0)
  t.eq(#d.revealed, 1, table.concat(d.revealed, " | "))
  t.eq(d.answer, nil, "раздумье растворилось само, без касания")
  page_done(d, WORD)
  t.eq(#cbs, 2, "следующая страница ушла")
end

-- nil пришёл раньше раздумья: в очереди и на экране ничего
function T.test_nil_text_before_ponder()
  local d = diary()
  d.responder = function(_, cb) cb(nil, false) end
  page_done(d, WORD)
  run(30)
  t.eq(d.inflight, 0)
  t.eq(#d.revealed, 0, table.concat(d.revealed, " | "))
  t.eq(#d.queue, 0)
end

-- чернила касания уже растворились (sinkTick звал maybeIdle при открытой странице): пустой экран —
-- on_idle сразу после пропуска; и после nil-ответа тоже
function T.test_idle_after_tiny_page_and_nil_text()
  local d = diary()
  local n = 0
  d.on_idle = function() n = n + 1 end
  page_done(d, TINY)
  t.eq(n, 1, "on_idle после касания")
  d.responder = function(_, cb) cb(nil, false) end
  page_done(d, WORD)
  t.eq(n, 2, "on_idle после nil-ответа")
end

-- 4.1 граница png.MIN_SIDE = 32: обе стороны < 32 — пропуск; одна сторона ≥ 32 — в модель.
-- Рамка чернил → PNG: ширина = floor((dx + 16) / 2) + 1 (поля 8 px, масштаб 2); dx = 44 → 31, 46 → 32
local function ink_for(w, h)
  local function side(n) return n == 31 and 44 or 46 end
  return { 300, 300, 300 + side(w), 300 + side(h) }
end

function T.test_boundary_31x31_is_skipped()
  local d = diary()
  page_done(d, ink_for(31, 31))
  t.eq(d.runner.started, 0)
  t.eq(d.saves, 0)
  t.eq(count("riddle: page too small 31x31 -> skipped"), 1, table.concat(LOG, "\n"))
end

function T.test_boundary_32x31_and_31x32_go_to_model()
  for _, wh in ipairs({ { 32, 31 }, { 31, 32 }, { 32, 32 } }) do
    local d = diary()
    page_done(d, ink_for(wh[1], wh[2]))
    t.eq(d.runner.started, 1, wh[1] .. "x" .. wh[2] .. " уходит в модель")
    t.eq(count("riddle: page too small"), 0, wh[1] .. "x" .. wh[2])
  end
end

-- 4.2 синхронный путь Diary:respond: касание (nil из on_page) не тратит хвост разблокировки —
-- он ждёт настоящего ответа
function T.test_sync_respond_nil_keeps_followup()
  local d = diary({})                      -- печати нет: хвост положен с самого начала
  d.runner = nil
  local f = assert(io.open("tests/fixtures/png/b2_13x9_dynamic.png", "rb"))
  local bytes = f:read("*a")
  f:close()
  d.controller.deps.read_file = function() return bytes end
  t.eq(d.controller.followup_due, true, "хвост ждёт первого ответа")
  local called, text, unlocked
  d:respond("/tmp/page.png", function(a, b) called, text, unlocked = true, a, b end)
  t.ok(called, "cb вызван сразу")
  t.eq(text, nil, "текста нет")
  t.eq(unlocked, false, "не разблокировка")
  t.eq(d.controller.followup_due, true, "касание хвост не потратило")
  t.eq(d.controller:take_followup(), true, "хвост достанется настоящему ответу")
end

-- 4.3 nil из responder, когда фраза-раздумье уже в фазе hold: растворяется без касания
function T.test_nil_text_with_think_in_hold_dissolves_without_touch()
  local d = diary()
  local cbs = {}
  d.responder = function(_, cb) cbs[#cbs + 1] = cb end
  -- одна фраза: на 8 с её сменил бы следующий шаг раздумья
  with_cfg({ ponder_every_s = 60 }, function()
    page_done(d, WORD)
    run(10)
  end)
  t.eq(d.answer and d.answer.phase, "hold", "фраза проявилась и стоит")
  t.eq(#d.fades, 0, "сама не уходит")
  cbs[1](nil, false)
  run(30)
  t.eq(d.answer, nil, "растворилась без касания")
  t.eq(#d.fades, 1)
end

function T.test_with_cfg_restores_after_failure()
  local every = Diary.CFG.ponder_every_s
  -- значение заведомо не исходное: иначе «не вернули» от «вернули» не отличить
  local other = every + 1
  local ok, err = pcall(with_cfg, { ponder_every_s = other }, function()
    t.eq(Diary.CFG.ponder_every_s, other, "внутри обёртки правка действует")
    error("тест упал посередине")
  end)
  t.eq(ok, false)
  t.ok(tostring(err):find("тест упал посередине", 1, true), "ошибка не проглочена: " .. tostring(err))
  t.eq(Diary.CFG.ponder_every_s, every, "настройка вернулась")
end

t.run(T)
