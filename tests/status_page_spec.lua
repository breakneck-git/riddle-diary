-- Страница состояния Kindle (план 2026-11-19-status-triangle, Task 5): треугольник пером открывает её в любом состоянии
-- печати, касание закрывает — дневник на прежнем месте; сон и выход закрывают без рисования; ответ в пути — страница
-- после него (mode_due, как карта). Стенд — как в async_answer_spec.lua: заглушки KOReader, часы, поддельный runner,
-- контроллер настоящий на поддельных deps.
require("sqlite_shim") -- riddle.sync тянет хранилище
local t = require("t")
local stand = require("seal_stand")
local controller = require("riddle.controller")
local texts = require("riddle.texts")
local status = require("riddle.status")
local sync = require("riddle.sync")

local clock, timeline, LOG = 0, {}, {}

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
  setDirty = nop, close = nop,
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
stub("libs/libkoreader-lfs", { attributes = nop, dir = nop, mkdir = nop })

local Diary = require("riddle_diarywidget")
local TF = require("fixtures.triangle_strokes")
local RF = require("fixtures.rose_strokes")

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
  function r:done(payload, err, i)
    local job = self.jobs[i or #self.jobs]
    if self.cur == job then self.cur = nil end
    job.opts.on_done(payload, err)
  end
  return r
end

-- extra — свои deps поверх стенда (образец ключа: load_key, write_key)
local function ctl(extra)
  local deps = {
    cfg = { seal = stand.key() },
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

local function reply(read, text) return { result = { read = read, reply = text } } end

-- здоровое устройство: все источники отвечают, поломок нет
local NOW = 1763500000
local function healthy()
  return {
    read = function(path)
      if path == "/proc/net/tcp" then
        return "  sl  local_address rem_address   st\n   0: 00000000:08AE 00000000:0000 0A 00000000:00000000\n"
      end
      if path == "/proc/meminfo" then return "MemFree: 25380 kB\nBuffers: 40272 kB\nCached: 100212 kB\n" end
      if path == "/proc/uptime" then return "2208707.90 285648.98" end
    end,
    build = function() return "21171e3" end,
    power = function() return { pct = 88, charging = false } end,
    net = function() return "up" end,
    wifi = function() return { essid = "home", ip = "192.0.2.220" } end,
    disk = function() return { free_kb = 784000, total_kb = 1360000 } end,
    sync_last = function() return { at = NOW - 60 } end,
    store = function() return { ok_at = NOW - 60, docs = 3, collections = 1 } end,
    now = function() return NOW end,
  }
end

-- виджет с холстом; печать закрыта; тексты страницы — в d.painted, обновления экрана — в d.pushes
local function diary(extra)
  clock, timeline, LOG = 0, {}, {}
  Diary.map_kept = nil
  local d = setmetatable({
    canvas = bb_stub, tasks = {}, queue = {}, asks = {}, inflight = 0, strokes = {}, epoch = 0, w = 758, h = 1024,
    prompt = { rect = { x = 0, y = 0, w = 0, h = 0 } },
    face_answer = { ftsize = { getHeightAndAscender = function() return 52, 40 end } },
    stats = { frames = 0, frame_us = 0, frame_us_max = 0, sink_ticks = 0, sink_us = 0, sink_us_max = 0,
              ans_steps = 0, ans_us_max = 0, grey_px = 0, lost_ink = 0 },
    controller = ctl(extra),
    runner = fake_runner(),
    revealed = {},
  }, { __index = Diary })
  d.face_prompt = d.face_answer
  d.renderRegion = nop
  d.penNear = function() return false end
  d.countLostInk = function() return 0 end
  d.saveSample = function() return "/tmp/page.png" end
  d.revealAnswer = function(self, text, ...)
    self.revealed[#self.revealed + 1] = text
    return Diary.revealAnswer(self, text, ...)
  end
  d.responder = function(png, cb) d:respond(png, cb) end
  d.steps, d.invite = 0, 0
  d.answerStep = function() d.steps = d.steps + 1 end
  d.showInvitation = function() d.invite = d.invite + 1 end
  d.pushes, d.push_rects = {}, {}
  d.push = function(_, x, y, w, h, mode)
    d.pushes[#d.pushes + 1] = mode
    d.push_rects[#d.push_rects + 1] = { x = x, y = y, w = w, h = h }
  end
  d.painted = {}
  d.paintText = function(_, text, top)
    d.painted[#d.painted + 1] = text
    return { x = 0, y = top, w = 100, h = 40 }
  end
  d.paintTexts = function(self, list)
    local out = {}
    for i, it in ipairs(list) do out[i] = self:paintText(it[1], it[2], it[3]) end
    return out
  end
  d.statusSources = function() return healthy() end
  d.controller.seal.open = false
  return d
end

local function strokes_of(F, name)
  local out = {}
  for i, s in ipairs(F[name]) do out[i] = { p = s.p, lvl = Diary.CFG.dissolve.steps } end
  return out
end

local function page_done(d, strokes)
  d.page = { strokes = strokes or {}, ink = { 10, 200, 100, 260 } }
  d:onPageDone()
end

-- задачи раннера этого вида (проба модели страницы — "probe")
local function jobs_of(d, kind)
  local n = 0
  for _, job in ipairs(d.runner.jobs) do if job.kind == kind then n = n + 1 end end
  return n
end

-- задачи раннера, кроме пробы модели: ответ, хвост, синхронизация
local function not_probe(d) return #d.runner.jobs - jobs_of(d, "probe") end

local function painted(d, text)
  for _, s in ipairs(d.painted) do if s == text then return true end end
  return false
end

local function painted_prefix(d, prefix)
  for _, s in ipairs(d.painted) do if s:sub(1, #prefix) == prefix then return true end end
  return false
end

local function tmpdir()
  local h = io.popen("mktemp -d")
  local dir = h:read("*l")
  h:close()
  return dir
end

local function files(dir)
  local out = {}
  local h = io.popen('ls "' .. dir .. '"')
  for name in h:lines() do out[#out + 1] = name end
  h:close()
  return out
end

local T = {}

-- закрытая печать (решение оркестратора: «во всех случаях»): треугольник — страница состояния, не попытка слова
function T.test_triangle_under_closed_seal_opens_status()
  local d = diary()
  page_done(d, strokes_of(TF, "equilateral"))
  run(1)
  t.ok(d.status, "страница состояния открыта")
  t.eq(not_probe(d), 0, "страница-треугольник не ушла ни в модель, ни в печать")
  t.eq(d.inflight, 0)
  t.eq(#d.revealed, 0, "Реддл молчит")
  t.ok(painted(d, "Всё в порядке"), "шапка: " .. table.concat(d.painted, " | "))
  t.ok(painted(d, "Wi‑Fi: на связи, сеть home, IP 192.0.2.220"), "строки фактов напечатаны")
  t.ok(not painted_prefix(d, "Батарея:"), table.concat(d.painted, " | "))
  t.eq(d.pushes[#d.pushes], "full", "страница — полным обновлением")
  t.eq(count("riddle: status open (triangle)"), 1)
end

-- открытая печать: треугольник проверяется первым — страница состояния, не карта и не ответ
function T.test_triangle_under_open_seal_opens_status()
  local d = diary()
  d.controller.seal.open = true
  page_done(d, strokes_of(TF, "start_mid_side"))
  run(1)
  t.ok(d.status, "страница состояния")
  t.eq(d.map, nil)
  t.eq(not_probe(d), 0)
end

-- роза под открытой печатью — карта, как раньше
function T.test_rose_under_open_seal_still_opens_map()
  local d = diary()
  d.controller.seal.open = true
  page_done(d, strokes_of(RF, "rose_tilted_30")) -- роза, не совпавшая с ключом: прошла сверку промахом
  run(1)
  t.ok(d.map, "карта")
  t.eq(d.status, nil)
end

-- касание закрывает: чернил нет, дневник — чистая страница с приглашением, полным обновлением
function T.test_touch_closes_status_without_ink()
  local d = diary()
  page_done(d, strokes_of(TF, "equilateral"))
  run(1)
  local invites = d.invite
  d:penDown(300, 500)
  d:penMove(320, 520)
  d:penUp()
  t.eq(d.status, nil, "закрыта")
  t.eq(#d.strokes, 0, "касание не оставило чернил")
  t.eq(d.page, nil, "и не начало страницу")
  t.eq(count("riddle: status close (touch)"), 1)
  t.eq(d.invite, invites + 1, "приглашение")
  t.eq(d.pushes[#d.pushes], "full")
  -- следующее касание — уже письмо в дневник
  d:penDown(300, 500)
  t.eq(#d.strokes, 1, "дневник на прежнем месте")
end

-- сон при открытой странице: режим снят, ничего не рисуется (экран у заставки)
function T.test_sleep_closes_status_without_drawing()
  local d = diary()
  page_done(d, strokes_of(TF, "equilateral"))
  run(1)
  local pushes, invites = #d.pushes, d.invite
  d:onSuspend()
  t.eq(d.status, nil)
  t.eq(#d.pushes, pushes, "push не вызван")
  t.eq(d.invite, invites)
  t.eq(count("riddle: status close (sleep)"), 1)
end

-- выход из дневника при открытой странице: снята, ничего не рисуется
function T.test_exit_closes_status_without_drawing()
  local d = diary()
  page_done(d, strokes_of(TF, "equilateral"))
  run(1)
  local pushes = #d.pushes
  d:onCloseWidget()
  t.eq(d.status, nil)
  t.eq(#d.pushes, pushes)
  t.eq(count("riddle: status close (exit)"), 1)
end

-- ответ в пути: страница ждёт его (mode_due) и открывается после; ответ не теряется, треугольник — не отказ
function T.test_triangle_during_answer_opens_after_it()
  local d = diary()
  local shown_before
  d.openStatus = function(self, ...)
    shown_before = self.revealed[#self.revealed]
    return Diary.openStatus(self, ...)
  end
  page_done(d) -- обычная страница: ответ в пути
  t.eq(d.inflight, 1)
  page_done(d, strokes_of(TF, "equilateral"))
  t.eq(d.runner.started, 1, "треугольник не в модель")
  t.eq(count("page during ponder -> refusal"), 0, "треугольник — не отказ")
  t.ok(d.mode_due, "страница ждёт ответа")
  run(4)
  t.eq(d.status, nil, "ответ в пути: страница ждёт")
  d.runner:done(reply("кто ты", "Я Том"))
  run(60)
  t.ok(d.status, "после ответа — страница")
  t.eq(shown_before, "Я Том", "ответ проявился до страницы")
end

-- перо после треугольника, до открытия страницы: она отменяется, как карта
function T.test_pen_cancels_status_due()
  local d = diary()
  page_done(d)
  page_done(d, strokes_of(TF, "equilateral"))
  t.ok(d.mode_due)
  d:penDown(300, 800)
  t.eq(d.mode_due, nil, "перо отменило страницу")
  t.eq(count("riddle: status cancelled (pen)"), 1)
end

-- фраза карты, пока треугольник ждёт ответа: карта занимает место страницы, сброс — строкой в лог (как «cancelled (pen)»)
function T.test_map_phrase_drops_status_due_logged()
  local d = diary()
  page_done(d)
  page_done(d, strokes_of(TF, "equilateral"))
  t.eq(d.mode_due.kind, "status", "страница ждёт ответа")
  d:phraseOpensMap(d.mode_due.page)
  t.eq(d.mode_due.kind, "map", "карта заняла место страницы")
  t.eq(count("riddle: status dropped (map phrase)"), 1, table.concat(LOG, "\n"))
end

-- ждёт карта, не страница: сбрасывать нечего — строки нет
function T.test_map_phrase_over_map_due_not_logged()
  local d = diary()
  page_done(d)
  d:phraseOpensMap({})
  d:phraseOpensMap({})
  t.eq(count("dropped (map phrase)"), 0)
end

-- ответа в пути нет: страница стоит в очереди, пока растворяются чернила треугольника; перо снимает её и оттуда
function T.test_pen_cancels_status_queued()
  local d = diary()
  local fresh = {}
  for i, s in ipairs(TF.equilateral) do fresh[i] = { p = s.p, lvl = 0 } end -- чернила ещё не растворились
  page_done(d, fresh)
  t.eq(d.mode_due, nil, "ответа в пути нет — не mode_due")
  t.eq(#d.queue, 1, "страница ждёт в очереди")
  t.eq(d.queue[1].kind, "status")
  t.eq(d.status, nil, "чернила не растворились — не открыта")
  d:penDown(300, 800)
  for _, q in ipairs(d.queue) do t.ok(q.kind ~= "status", "перо сняло страницу из очереди") end
  t.eq(count("riddle: status cancelled (pen)"), 1)
  for _, s in ipairs(fresh) do s.lvl = Diary.CFG.dissolve.steps end
  d:nextAnswer()
  t.eq(d.status, nil, "чернила растворились — страница не открылась")
end

-- пока страница открыта, синхронизация (on_idle) и хвост не стартуют: экран и раннер — у страницы
function T.test_no_idle_or_followup_while_status_open()
  local d = diary({ load_key = stand.load_key })
  local idles = 0
  d.on_idle = function() idles = idles + 1 end
  d.controller.deps.memory = {
    use_persona = function() return true end, session = function() return 2, 1 end,
    entries = function() return { { role = "owner", text = "запись" }, { role = "diary", text = "ответ" } } end,
    set_summary = nop,
  }
  page_done(d, stand.key_strokes(Diary.CFG.dissolve.steps)) -- страница-ключ: печать открыта без модели
  t.ok(d.followup_task, "хвост назначен до страницы")
  idles = 0
  d:openStatus("triangle")
  t.ok(d.status)
  run(120)
  t.eq(jobs_of(d, "summary"), 0, "пока страница открыта, хвост не стартует")
  d:maybeIdle()
  t.eq(idles, 0, "и синхронизация")
  d:penDown(300, 500)
  d:penUp()
  run(120)
  t.eq(jobs_of(d, "summary"), 1, "страница закрыта: хвост ушёл")
  t.ok(idles > 0, "как после ответа")
end

-- источники фактов падают все: страница всё равно открывается, неизвестное — «—»
function T.test_failing_sources_still_open_page()
  local d = diary()
  d.statusSources = function()
    local boom = function() error("нет") end
    return { read = boom, build = boom, power = boom, net = boom, wifi = boom, disk = boom, sync_last = boom,
             store = boom, now = boom }
  end
  page_done(d, strokes_of(TF, "equilateral"))
  run(1)
  t.ok(d.status, "открыта")
  t.ok(not painted_prefix(d, "Батарея:"), table.concat(d.painted, " | "))
  t.ok(painted(d, "Сборка: —"))
  t.ok(painted(d, "Notion: —"), "база знаний недоступна — «—»")
end

-- провод на устройстве: сборка — файл status.BUILD_NAME в каталоге плагина, итог синхронизации — sync.LAST_PATH через
-- sync.parse_last (ошибка — фразой по классу), удачная и числа Notion — store открывателя (метка хранилища — строкой); недоступное (powerd, util) — «—»
function T.test_device_sources_read_build_and_sync_files()
  local d = diary()
  d.statusSources = Diary.statusSources
  local asked, now = {}, os.time()
  d.read_file = function(path)
    asked[#asked + 1] = path
    if path:sub(-#status.BUILD_NAME - 1) == "/" .. status.BUILD_NAME then return "21171e3-dirty\n" end
    if path == sync.LAST_PATH then return sync.last_line(now - 120, "unauthorized") end
    if path == "/proc/net/tcp" then
      return "  sl  local_address rem_address   st\n   0: 00000000:08AE 00000000:0000 0A 00000000:00000000\n"
    end
  end
  local store_calls = 0
  d.store = function()
    store_calls = store_calls + 1
    return { last_ok = tostring(now - 3600), docs = 1234, collections = 12 }
  end
  page_done(d, strokes_of(TF, "equilateral"))
  run(1)
  t.ok(d.status, "открыта")
  t.eq(store_calls, 1, "хранилище — одно чтение на открытие страницы")
  t.ok(painted(d, "Notion: 1 234 документа, 12 баз"), table.concat(d.painted, " | "))
  t.ok(painted(d, "Сборка: 21171e3-dirty"), table.concat(d.painted, " | "))
  -- ошибка — фразой по классу, сырой текст из sync_last на страницу не попадает
  t.ok(painted(d, "Синхронизация: Notion не пускает — проверь ключ"), "шапка: " .. table.concat(d.painted, " | "))
  t.ok(painted(d, "Синхронизация: удачная 1 ч назад; последняя попытка — 2 мин назад, Notion не пускает — проверь ключ"),
       table.concat(d.painted, " | "))
  t.ok(not table.concat(d.painted, " | "):find("unauthorized", 1, true), "сырого текста нет")
  t.ok(painted(d, "ssh: слушает порт 2222"))
  t.ok(not painted_prefix(d, "Батарея:"), "строки батареи нет")
end

-- провод на устройстве: заряд страницы состояния — powerd устройства (getCapacity, isCharging); подменён только powerd,
-- источники — настоящие Diary.statusSources. Низкий заряд без зарядки — поломка в шапке, на зарядке — нет
function T.test_device_sources_read_powerd()
  local Device = require("device")
  local function page(pct, charging)
    Device.getPowerDevice = function()
      return { getCapacity = function() return pct end, isCharging = function() return charging end }
    end
    local d = diary()
    d.statusSources = Diary.statusSources
    d.read_file = nop
    page_done(d, strokes_of(TF, "equilateral"))
    run(1)
    t.ok(d.status, "открыта")
    return d
  end
  local ok, err = pcall(function()
    local d = page(9, false)
    t.ok(painted(d, "Батарея 9%"), table.concat(d.painted, " | "))
    d = page(9, true)
    t.ok(not painted_prefix(d, "Батарея"), "на зарядке не поломка: " .. table.concat(d.painted, " | "))
  end)
  Device.getPowerDevice = nil
  t.ok(ok, tostring(err))
end

-- devmode: страница с треугольником — одна строка оценки и один файл штрихов
function T.test_devmode_triangle_logged_and_recorded_once()
  local d = diary()
  d.devmode, d.rose_dir = true, tmpdir()
  page_done(d, strokes_of(TF, "equilateral"))
  t.eq(count("riddle: triangle yes score="), 1, table.concat(LOG, "\n"))
  t.eq(count("riddle: rose "), 0, "треугольник узнан — роза не проверяется")
  local names = files(d.rose_dir)
  t.eq(#names, 1, "один файл штрихов")
  t.eq(count("file=" .. names[1]), 1)
end

-- devmode: страницу проверили оба знака — файл штрихов один, обе строки называют его
function T.test_devmode_both_signs_one_file()
  local d = diary()
  d.devmode, d.rose_dir = true, tmpdir()
  d.controller.seal.open = true
  page_done(d, strokes_of(TF, "square"))
  t.eq(count("riddle: triangle no"), 1, table.concat(LOG, "\n"))
  t.eq(count("riddle: rose no"), 1)
  local names = files(d.rose_dir)
  t.eq(#names, 1, "страница записана один раз")
  t.eq(count("file=" .. names[1]), 2)
end

-- devmode, закрытая печать: попытка написать слово-печать из 1–2 штрихов — не попытка знака, в roses не пишется;
-- треугольник пишется; под открытой печатью не-треугольник пишется, как раньше
function T.test_devmode_closed_seal_records_only_triangle()
  local function attempt(open, name)
    local d = diary()
    d.devmode, d.rose_dir = true, tmpdir()
    d.controller.seal.open = open
    page_done(d, strokes_of(TF, name))
    return #files(d.rose_dir)
  end
  t.eq(attempt(false, "letter_a"), 0, "закрытая печать, буква из двух штрихов — файла нет")
  t.eq(attempt(false, "square"), 0, "закрытая печать, квадрат одним штрихом — файла нет")
  t.eq(count("riddle: triangle no"), 1, "оценка в журнале остаётся: " .. table.concat(LOG, "\n"))
  t.eq(attempt(false, "equilateral"), 1, "закрытая печать, треугольник — файл есть")
  t.eq(attempt(true, "letter_a"), 1, "открытая печать, не треугольник — файл есть, как раньше")
end

-- devmode без контроллера (только сон, печати нет): страница-не-треугольник не длиннее треугольника — попытка знака,
-- файл в roses пишется, как до печати
function T.test_devmode_no_controller_records_non_triangle()
  local d = diary()
  d.devmode, d.rose_dir, d.controller = true, tmpdir(), nil
  page_done(d, strokes_of(TF, "letter_a"))
  t.eq(count("riddle: triangle no"), 1, table.concat(LOG, "\n"))
  t.eq(#files(d.rose_dir), 1, "без контроллера не-треугольник записан")
end

-- devtest triangle=N на настоящем виджете: треугольник харнеса идёт через onRawTouch, страницу открывает и закрывает
-- настоящий openStatus/closeStatus (openStatus зовёт resetPage, а он снимает все задачи self:schedule). Счёт циклов
-- не теряется, касание харнеса закрывает страницу, не оставив чернил
function T.test_devtest_triangle_counts_cycles_through_real_open_and_close()
  local devtest = require("riddle.devtest")
  local Dev = setmetatable({}, { __index = Diary }) -- харнес ставится в подкласс: остальные тесты его не видят
  devtest.install(Dev, { rssKB = function() return 0 end, RIDDLE_DIR = "/nonexistent" })
  local d = diary()
  setmetatable(d, { __index = Dev })
  d.toScreen = function(_, x, y) return x, y end
  d.keepAwake = nop
  d.gd = { feedEvent = function(_, tevs) d:onRawTouch(tevs) end, dropContacts = nop }
  d:testTriangle("triangle=2") -- печать закрыта: треугольник идёт всё равно
  run(120)
  t.eq(count("riddle: status open (triangle)"), 2, "треугольник харнеса дважды открыл страницу")
  t.eq(count("riddle: status close (touch)"), 2, "и касание дважды закрыло её")
  for i = 1, 2 do
    t.eq(count("riddle: TRIANGLE cycle " .. i .. " open="), 1, table.concat(LOG, "\n"))
    t.eq(count("riddle: TRIANGLE cycle " .. i .. " close="), 1)
  end
  t.eq(count("open=-1"), 0, "ни одного промаха")
  t.eq(count("close=-1"), 0)
  t.eq(count("riddle: TRIANGLE n=2 opened=2 closed=2"), 1, table.concat(LOG, "\n"))
  t.eq(d.status, nil)
  t.eq(#d.strokes, 0, "касания харнеса не оставили чернил")
  t.eq(not_probe(d), 0, "ни одной страницы в модель")
end

-- ---- «модель отвечает» в фоне (Task 6): проба — задача раннера "probe", страница её не ждёт ----

local function open_status(d)
  page_done(d, strokes_of(TF, "equilateral"))
  run(1)
  t.ok(d.status, "страница открыта")
end

local function probe_job(d, i)
  local n = 0
  for _, job in ipairs(d.runner.jobs) do
    if job.kind == "probe" then
      n = n + 1
      if n == (i or 1) then return job end
    end
  end
end

-- последний push — только строка модели (частичный), не весь экран
local function model_row_pushed(d)
  local r, p = d.status.rects[status.MODEL_ROW], d.push_rects[#d.push_rects]
  return d.pushes[#d.pushes] ~= "full" and p.y == r.y and p.h >= r.h and p.h < d.h
end

-- страница выведена до ответа пробы, строка модели — «проверяю…»; ответ — частичный refresh одной этой строки
function T.test_probe_page_shown_before_answer_then_row_written()
  local d = diary()
  local shown_at_start
  local start = d.runner.start
  d.runner.start = function(self, kind, fn, opts)
    shown_at_start = { at = clock, last = d.pushes[#d.pushes], checking = painted(d, "Модель: проверяю…") }
    return start(self, kind, fn, opts)
  end
  open_status(d)
  local job = probe_job(d)
  t.ok(job, "проба стартовала")
  t.eq(job.opts.timeout_s, Diary.CFG.probe_ceil_s, "таймаут задачи — CFG.probe_ceil_s")
  t.ok(type(job.fn) == "function", "в дочерний — функция")
  t.eq(shown_at_start.last, "full", "страница выведена до старта пробы")
  t.ok(shown_at_start.checking, "строка модели на странице — «проверяю…»: " .. table.concat(d.painted, " | "))
  t.ok(not painted(d, "Модель: —"), "прочерка нет: проба идёт")
  local pushes = #d.pushes
  clock = shown_at_start.at + 0.25 -- ответ через 250 мс после старта пробы
  d.runner:done({ result = { text = "ok" } })
  t.ok(painted(d, "Модель отвечает (250 мс)"), table.concat(d.painted, " | "))
  t.eq(#d.pushes, pushes + 1, "один refresh")
  t.ok(model_row_pushed(d), "частичный, только строка модели")
  t.eq(count("riddle: probe start"), 1, table.concat(LOG, "\n"))
  t.eq(count("riddle: probe done ms=250"), 1, table.concat(LOG, "\n"))
end

-- раннер убил пробу по таймауту: строка — ошибка
function T.test_probe_timeout_written()
  local d = diary()
  open_status(d)
  d.runner:done(nil, "timeout")
  t.ok(painted(d, "Модель: timeout"), table.concat(d.painted, " | "))
  t.ok(model_row_pushed(d))
  t.eq(count("riddle: probe failed timeout"), 1, table.concat(LOG, "\n"))
  t.eq(count("riddle: probe not started"), 0, "стартовала — не «не стартовала»")
end

-- модель ответила ошибкой (payload дошёл, результата нет): строка — её ошибка, payload — через absorb контроллера
function T.test_probe_model_error_written()
  local d = diary()
  local absorbed = 0
  local absorb = d.controller.deps.absorb
  d.controller.deps.absorb = function(payload)
    absorbed = absorbed + 1
    return absorb(payload)
  end
  open_status(d)
  d.runner:done({ err = "gemini: http 429" })
  t.eq(absorbed, 1, "логи и мёртвые ключи дочернего — в цепочку")
  t.ok(painted(d, "Модель: gemini: http 429"), table.concat(d.painted, " | "))
end

-- сон закрыл страницу, проба снята; ответ, пришедший всё же, ничего не рисует
function T.test_probe_answer_after_sleep_draws_nothing()
  local d = diary()
  open_status(d)
  local job = probe_job(d)
  d:onSuspend()
  t.eq(d.status, nil)
  t.ok(table.concat(d.runner.cancels, ","):find("probe", 1, true), "проба снята: " .. table.concat(d.runner.cancels, ","))
  local pushes, n = #d.pushes, #d.painted
  job.opts.on_done({ result = { text = "ok" } })
  t.eq(#d.pushes, pushes, "push не вызван")
  t.eq(#d.painted, n, "ничего не нарисовано")
  t.eq(count("riddle: probe late (page closed)"), 1, table.concat(LOG, "\n"))
  t.eq(count("riddle: probe done"), 0, "итог закрытой странице не пишется как свой")
end

-- страница закрыта касанием и открыта снова до ответа старой пробы: старый ответ в новую страницу не пишет
function T.test_old_probe_answer_does_not_write_into_reopened_page()
  local d = diary()
  open_status(d)
  local old = probe_job(d, 1)
  d:penDown(300, 500)
  d:penUp()
  t.eq(d.status, nil, "закрыта касанием")
  t.ok(table.concat(d.runner.cancels, ","):find("probe", 1, true), "проба снята")
  d:openStatus("triangle")
  local fresh = probe_job(d, 2)
  t.ok(fresh and fresh ~= old, "новая страница — новая проба")
  local pushes = #d.pushes
  old.opts.on_done({ result = { text = "ok" } }, nil)
  t.eq(#d.pushes, pushes, "старая проба не трогает экран")
  t.eq(count("riddle: probe late (page closed)"), 1, table.concat(LOG, "\n"))
  t.ok(not painted(d, "Модель отвечает (0 мс)"), table.concat(d.painted, " | "))
  fresh.opts.on_done(nil, "timeout")
  t.ok(painted(d, "Модель: timeout"), "своя проба пишет")
end

-- раннер занят синхронизацией: проба не стартует, строка — чем занят
function T.test_probe_busy_runner_row()
  local d = diary()
  d.runner.cur = { kind = "sync" }
  open_status(d)
  t.ok(painted(d, "Модель: не проверена (занято: sync)"), table.concat(d.painted, " | "))
  t.eq(d.runner.started, 0, "start не зовётся")
  t.eq(d.runner.cur.kind, "sync", "синхронизация не вытеснена")
  t.eq(count("riddle: probe skipped busy:sync"), 1, table.concat(LOG, "\n"))
end

-- сети нет: «нет сети» сразу, раннер не трогается
function T.test_probe_offline_row()
  local d = diary()
  d.statusSources = function()
    local s = healthy()
    s.net = function() return "off" end
    return s
  end
  open_status(d)
  t.ok(painted(d, "Модель: нет сети"), table.concat(d.painted, " | "))
  t.eq(d.runner.started, 0, "раннер не трогается")
  t.ok(not painted(d, "Модель: проверяю…"))
  t.eq(count("riddle: probe skipped нет сети"), 1, table.concat(LOG, "\n"))
end

-- ошибка пробы в логе — одна короткая строка: переводы строк схлопнуты, длинный хвост (тело ответа) обрезан
function T.test_probe_failed_log_is_one_short_line()
  local d = diary()
  open_status(d)
  d.runner:done({ err = "gemini:\194\160http 500\n" .. string.rep("x", 400) })
  local line
  for _, l in ipairs(LOG) do if l:find("riddle: probe failed", 1, true) then line = l end end
  t.ok(line, table.concat(LOG, "\n"))
  t.ok(not line:find("\n", 1, true), "одна строка")
  t.ok(line:find("riddle: probe failed gemini: http 500 x", 1, true), line)
  t.ok(#line <= #"riddle: probe failed " + 120, "короткая: " .. #line)
end

-- обрезка ошибки в логе — по знакам, не по байтам: кириллица не рвётся посреди знака
function T.test_probe_failed_log_cut_keeps_utf8()
  local d = diary()
  open_status(d)
  d.runner:done({ err = "a" .. string.rep("я", 200) })
  local tail
  for _, l in ipairs(LOG) do tail = l:match("^riddle: probe failed (.*)$") or tail end
  t.eq(tail, "a" .. string.rep("я", 119), "ровно 120 знаков, последний «я» целый")
end

-- раннер отказал в старте пробы (не «занят»): строка — его ошибка, не вечное «проверяю…»; частичный refresh строки
function T.test_probe_not_started_row_shows_error()
  local d = diary()
  d.runner.start = function(self) self.started = self.started + 1; return false, "spawn failed" end
  open_status(d)
  t.eq(d.runner.started, 1, "старт был")
  t.ok(painted(d, "Модель: spawn failed"), table.concat(d.painted, " | "))
  t.ok(model_row_pushed(d), "частичный, только строка модели")
  t.eq(count("riddle: probe not started spawn failed"), 1, table.concat(LOG, "\n"))
  t.eq(count("riddle: probe failed"), 0, "не стартовала — не «упала»")
  t.eq(count("riddle: probe start"), 0, "не стартовала — «start» не пишется")
end

-- раннер занялся между проверкой страницы и стартом (гонка): строка — чем занят, а не ошибка «busy»
function T.test_probe_start_refused_busy_row()
  local d = diary()
  d.runner.start = function(self)
    self.cur = { kind = "sync" }
    return false, "busy"
  end
  open_status(d)
  t.ok(painted(d, "Модель: не проверена (занято: sync)"), table.concat(d.painted, " | "))
  t.ok(not painted(d, "Модель: busy"), "не сырая ошибка")
  t.eq(count("riddle: probe skipped busy:sync"), 1, table.concat(LOG, "\n"))
  t.ok(model_row_pushed(d))
end

-- контроллер не смог собрать пробу (probe_job -> nil, ошибка): раннер не трогается, строка — ошибка
function T.test_probe_job_unavailable_row_shows_error()
  local d = diary()
  d.controller.probe_job = function() return nil, "no keys" end
  open_status(d)
  t.eq(d.runner.started, 0, "start не зовётся")
  t.ok(painted(d, "Модель: no keys"), table.concat(d.painted, " | "))
  t.ok(model_row_pushed(d))
  t.eq(count("riddle: probe not started no keys"), 1, table.concat(LOG, "\n"))
  t.eq(count("riddle: probe failed"), 0)
end

-- потолок пробы — свой (CFG.probe_ceil_s), не потолок ответа (CFG.ceil_s): значения подменены разными
function T.test_probe_timeout_is_probe_ceiling_not_answer_ceiling()
  local d = diary()
  local CFG = Diary.CFG
  local old_probe, old_ceil = CFG.probe_ceil_s, CFG.ceil_s
  CFG.probe_ceil_s, CFG.ceil_s = 7, 91
  local ok, err = pcall(open_status, d)
  CFG.probe_ceil_s, CFG.ceil_s = old_probe, old_ceil
  assert(ok, err)
  local job = probe_job(d)
  t.ok(job, "проба стартовала")
  t.eq(job.opts.timeout_s, 7, "таймаут пробы — probe_ceil_s, не ceil_s")
end

-- режим «задать ключ» (план seal-key, задача 5): образца нет; writes — записи образца
local SQUARE = TF.square
local SQUARE_AGAIN = { { p = { 230, 320, 560, 310, 545, 660, 215, 640, 230, 320 } } }

local function setting_diary()
  local writes = {}
  local d = diary({
    load_key = function() return nil, "absent" end,
    write_key = function(path, s)
      writes[#writes + 1] = { path = path, s = s }
      return true
    end,
  })
  return d, writes
end

local function dissolved(strokes)
  local out = {}
  for i, s in ipairs(strokes) do out[i] = { p = s.p, lvl = Diary.CFG.dissolve.steps } end
  return out
end

-- попытка знака — не сообщение: модель её не видит, ответ — фраза режима; страница со словами — обычный разговор
function T.test_key_page_not_sent()
  local d, writes = setting_diary()
  page_done(d, dissolved(SQUARE))
  run(1)
  t.eq(not_probe(d), 0, "первый рисунок не ушёл в модель")
  t.eq(d.inflight, 0)
  t.eq(d.revealed[#d.revealed], texts.key_again)
  page_done(d, dissolved(SQUARE_AGAIN))
  run(120) -- «Ещё раз» уступает экран следующей фразе по таймеру
  t.eq(not_probe(d), 0, "второй рисунок не ушёл в модель")
  t.eq(d.revealed[#d.revealed], texts.key_saved)
  t.eq(#writes, 1, "образец записан")
  t.eq(d.controller.seal_open, true, "ключ задан — печать открыта")
end

function T.test_words_page_in_setting_goes_to_model()
  local d = setting_diary()
  page_done(d) -- страница без знака (штрихов больше MAX_STROKES в жизни; здесь — пустой список)
  t.eq(not_probe(d), 1, "страница ушла в модель")
  t.eq(d.inflight, 1)
end

-- в режиме задания треугольник — попытка знака («этот знак занят»), не страница состояния (спека §5: ключ — первым)
function T.test_triangle_in_setting_is_taken()
  local d = setting_diary()
  page_done(d, strokes_of(TF, "equilateral"))
  run(1)
  t.eq(d.status, nil, "страница состояния не открыта")
  t.eq(d.revealed[#d.revealed], texts.key_taken)
  t.eq(not_probe(d), 0)
end

-- случайное касание в режиме задания — молчит, как всегда (не «Крупнее»), и не считается рисунком
function T.test_tiny_touch_in_setting_silent()
  local d = setting_diary()
  d.page = { strokes = dissolved({ { p = { 300, 300, 304, 302 } } }), ink = { 300, 300, 304, 302 } }
  d:onPageDone()
  run(1)
  t.eq(#d.revealed, 0, "касание без ответа")
  t.eq(not_probe(d), 0)
  page_done(d, dissolved(SQUARE))
  run(1)
  t.eq(d.revealed[#d.revealed], texts.key_again, "касание не стало первым рисунком")
end

-- B4: фраза режима ключа — не ответ модели: перо, оборвавшее её, не делает следующую страницу «перебиванием»
function T.test_pen_over_key_phrase_no_interjection()
  local d = setting_diary()
  page_done(d, dissolved(SQUARE))
  run(0)
  t.eq(d.answer and d.answer.phase, "reveal", "фраза ключа проявляется")
  d.page = { strokes = {}, ink = { 10, 200, 100, 260 } }
  d:hurryAnswer()
  t.ok(not d.page.interrupted, "страница не помечена перебитой")
  d:onPageDone()
  for _, q in ipairs(d.queue) do t.ok(q.kind ~= "interject", "реплики на перебивание нет") end
end

-- ключ задан: образец — две розы владельца
local O = require("fixtures.rose_owner")

local function keyed_diary()
  return diary({ load_key = function() return { O.owner_01, O.owner_02 } end })
end

-- Proposal 41d13e60-bc8d-81a8: devmode, закрытая печать, образец есть — ни промах ключа, ни сам ключ в roses не
-- пишутся (на закрытом Kindle файл штрихов показал бы знак)
function T.test_closed_seal_no_record_of_failed_sign()
  local d = keyed_diary()
  d.devmode, d.rose_dir = true, tmpdir()
  page_done(d, strokes_of(TF, "letter_a"))
  t.eq(#files(d.rose_dir), 0, "промах из двух штрихов — файла нет")
  t.eq(d.controller.seal_open, false)
  page_done(d, dissolved(O.owner_03))
  t.eq(d.controller.seal_open, true, "ключ открыл печать")
  t.eq(#files(d.rose_dir), 0, "ключ — файла нет")
end

-- Task 42313e60-bc8d-8110: devmode, закрытая печать, образец есть — страница, ушедшая на сверку ключа, в roses не
-- пишется, даже если она ещё и треугольник (рисунок ключа на диске — секрет владельца); страница состояния при этом
-- открывается, оценка в журнале остаётся. Под открытой печатью роза пишется, как раньше
function T.test_closed_keyed_seal_no_record_of_triangle_key_try()
  local d = keyed_diary()
  d.devmode, d.rose_dir = true, tmpdir()
  page_done(d, strokes_of(TF, "equilateral"))
  t.eq(d.controller.seal_open, false, "треугольник не ключ")
  t.eq(count("riddle: triangle yes"), 1, "оценка в журнале: " .. table.concat(LOG, "\n"))
  t.eq(#files(d.rose_dir), 0, "попытка ключа, узнанная треугольником, — файла нет")
  run(1)
  t.ok(d.status, "страница состояния открыта")
end

function T.test_open_keyed_seal_still_records_rose()
  local d = keyed_diary()
  d.devmode, d.rose_dir = true, tmpdir()
  page_done(d, dissolved(O.owner_03))
  t.eq(d.controller.seal_open, true, "ключ открыл печать")
  page_done(d, strokes_of(RF, "rose_tilted_30")) -- роза, не совпавшая с ключом: прошла сверку промахом
  t.eq(count("riddle: rose yes"), 1, table.concat(LOG, "\n"))
  t.eq(#files(d.rose_dir), 1, "открытая печать, роза — файл есть")
end

-- ключ открывает и закрывает печать со страницы; модель не зовётся
function T.test_key_page_toggles_seal()
  local d = keyed_diary()
  page_done(d, dissolved(O.owner_03))
  run(1)
  t.eq(d.controller.seal_open, true)
  local welcome = false
  for _, w in ipairs(texts.welcomes) do welcome = welcome or d.revealed[1] == w end
  t.ok(welcome, "приветствие на экране: " .. tostring(d.revealed[1]))
  page_done(d, dissolved(O.owner_04))
  run(120)
  t.eq(d.controller.seal_open, false)
  t.eq(d.revealed[#d.revealed], texts.seal_closed)
  t.eq(not_probe(d), 0, "модель не звали")
end

-- ответ в пути, а ключ сдвинул печать (Review Focus 1): ответ не показывается
function T.test_answer_in_flight_not_shown_after_key()
  local d = keyed_diary()
  page_done(d) -- страница при закрытой печати: ответ в пути
  t.eq(d.inflight, 1)
  page_done(d, dissolved(O.owner_03))
  t.eq(d.controller.seal_open, true, "ключ сработал и во время ответа")
  d.runner:done(reply("кто ты", "СТАРЫЙ ОТВЕТ"), nil, 1)
  run(300)
  for _, s in ipairs(d.revealed) do t.ok(s ~= "СТАРЫЙ ОТВЕТ", "ответ закрытой печати не показан") end
  t.eq(d.inflight, 0, "страница больше не ждёт")
end

-- Простой печати на карте и странице состояния (Notion 42213e60-bc8d-8131; владелец 2026-11-25: «да» — таймер идёт и
-- там, по сроку печать закрыта, на экране чистая страница дневника). Часы контроллера идут с планировщиком, сон уводит
-- их вперёд (slept). Печать открывает страница-ключ, режим — знак пером. Ключ — «буква А», не роза (образец стенда —
-- роза владельца: роза пером сдвинула бы печать, а не открыла карту)
local slept = 0
local function sealed(raw)
  slept = 0
  local d = diary({ cfg = { seal = stand.rules(raw) }, load_key = function() return { TF.letter_a, TF.letter_a } end,
                    now = function() return 1000 + math.floor(clock) + slept end })
  page_done(d, strokes_of(TF, "letter_a"))
  t.ok(d.controller.seal_open, "ключ открыл печать")
  return d
end

-- режим открывается в свою очередь — после приветствия ключа
local function draw_sign(d, F, name)
  page_done(d, strokes_of(F, name))
  run(30)
end

-- карта закрывается сама через map_idle_s без касаний: срок печати — меньше, чтобы его было видно
function T.test_map_closes_on_seal_idle()
  t.ok(60 < Diary.CFG.map_idle_s, "срок печати раньше автозакрытия карты")
  local d = sealed({ key = true, minutes = 1 })
  draw_sign(d, RF, "rose_ccw")
  t.ok(d.map, "карта открыта")
  local invites, pushes = d.invite, #d.pushes
  run(60 - clock - 1)
  t.ok(d.map, "до срока стоит")
  t.ok(d.controller.seal_open)
  run(2)
  t.eq(d.map, nil, "по сроку карта закрыта")
  t.ok(not d.controller.seal_open, "печать закрыта")
  t.eq(d.invite, invites + 1, "на экране первая строка чистой страницы")
  t.ok(#d.pushes > pushes and d.pushes[#d.pushes] == "full", "дневник — полным обновлением")
  t.eq(count("riddle: map close (seal)"), 1)
  run(3600)
  t.eq(d.invite, invites + 1, "первая строка одна")
end

function T.test_status_closes_on_seal_idle()
  local d = sealed({ key = true, minutes = 30 })
  draw_sign(d, TF, "equilateral")
  t.ok(d.status, "страница состояния открыта")
  local invites = d.invite
  run(1800 - clock - 1)
  t.ok(d.status, "до срока стоит")
  t.ok(d.controller.seal_open)
  run(2)
  t.eq(d.status, nil, "по сроку закрыта")
  t.ok(not d.controller.seal_open, "печать закрыта")
  t.eq(d.invite, invites + 1, "на экране первая строка чистой страницы")
  t.eq(d.pushes[#d.pushes], "full")
  t.eq(count("riddle: status close (seal)"), 1)
end

-- правило minutes двигает только запись: страница-режим открыта по-прежнему до своего закрытия
function T.test_map_stays_without_minutes()
  local d = sealed({ key = true })
  draw_sign(d, RF, "rose_ccw")
  run(Diary.CFG.map_idle_s - 31) -- карта открылась не раньше 30 с назад
  t.ok(d.map, "карта стоит до своего автозакрытия")
  t.ok(d.controller.seal_open)
end

function T.test_status_stays_without_minutes()
  local d = sealed({ key = true })
  draw_sign(d, TF, "equilateral")
  run(10 * 3600)
  t.ok(d.status, "страница стоит")
  t.ok(d.controller.seal_open)
end

-- сон на карте и пробуждение после срока: таймеры во сне не идут — пробуждение само закрывает печать, на экране
-- первая строка чистой страницы, карты нет
function T.test_resume_after_idle_on_map()
  local d = sealed({ key = true, minutes = 1 })
  draw_sign(d, RF, "rose_ccw")
  t.ok(d.map)
  local invites = d.invite
  d:onSuspend()
  slept = 2 * 3600
  d:onResume()
  t.eq(d.map, nil, "карты нет")
  t.ok(not d.controller.seal_open, "печать закрыта")
  t.eq(d.invite, invites + 1, "первая строка чистой страницы")
  run(3600)
  t.eq(d.invite, invites + 1, "одна")
end

t.run(T)
