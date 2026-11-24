-- Тестовый харнес дневника (спайк, Task 6): синтетические страницы через тот же хук feedEvent,
-- что и живой палец, снимки экрана, замеры обновлений. Грузится виджетом только при
-- /mnt/us/riddle/devmode; на рабочем дневнике файла нет — модуль не загружается.
--
-- /mnt/us/riddle/testmode: "cycles=N exit=1 shots=0 samples=1 full=1 offline=dns|tcp".
-- samples=1 — вместо PNG из синтетических штрихов в контроллер уходят образцы
-- /mnt/us/riddle/devsamples/*.png по кругу (по имени; копия, оригиналы не трогаются) — для живых
-- замеров LLM на настоящем почерке. full=1 — синтетика на всю страницу (размер PNG).
-- offline — имитация Wi‑Fi без интернета в процессе: dns — nameserver в никуда и пустой кэш IP,
-- tcp — кэш IP провайдеров (в т.ч. своих из конфига) указывает в никуда (connect висит).
--
-- Без экрана: "feed=N gap=S full=1 new=1 offline=dns|tcp" — N образцов devsamples (или full=1:
-- синтетика на всю страницу, отрисованная только в PNG) идут прямо в controller:on_page раз в
-- gap с; на экране ничего не рисуется и не меняется, приглашение остаётся. В конце печать
-- закрывается. Строки "riddle: FEED ..." и сводка p50/p90.
--
-- Карта без пальца: "rose=N" — N раз подряд роза ветров пером на странице (через feedEvent, как живой палец) →
-- ждём открытия карты → через 5 с роза на пергаменте → ждём закрытия → пауза. Печать должна быть открыта (иначе
-- роза на странице — обычное сообщение). Строки "riddle: ROSE cycle i open=<мс> close=<мс>" (мс от подъёма пера
-- розы; -1 — не дождались за 30 с) и "riddle: ROSE done n=N opened=K closed=M".
-- Страница состояния без пальца: "triangle=N" — N раз треугольник пером на странице (через feedEvent) → ждём открытия
-- страницы → через 5 с касание пером → ждём закрытия → пауза. Печать любая (треугольник — не сообщение модели). Строки
-- "riddle: TRIANGLE cycle i open=<мс>" и "… cycle i close=<мс>" (мс от подъёма пера; -1 — не дождались за 30 с; при
-- промахе открытия одна строка "open=-1 close=-1") и итог "riddle: TRIANGLE n=N opened=K closed=M".
-- Знак печати без пера: "seal=A,B,A,A2,triangle,tiny" — список фигур через запятую, каждая — одна страница пером (через
-- feedEvent), после каждой ждём ответа. A — знак 1 штрих (Z), A2 — тот же с дрожанием (совпадает с A), B — другой знак
-- (N), tiny — мелкий (меньше glyph.SIZE, но не случайное касание), triangle — треугольник. Образец ключа в этом режиме
-- лежит отдельно: /mnt/us/riddle/test/seal_key.lua (app.test_key_path), ключ владельца не трогается. В лог на каждую
-- страницу "riddle: devtest seal page <имя> -> <первые слова фразы | nil>" (штрихов и PNG в логе нет).
-- new=1 — перед первым образцом начинается новая сессия разговора, как после паузы > 4 ч (память
-- видит «сейчас» на 5 ч позже последней записи); история прошлой сессии цела, но в recent не идёт.

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local lfs = require("libs/libkoreader-lfs")
local now = time.monotonic
local Screen = Device.screen

local devtest = {}

-- "offline=dns|tcp" in the testmode string: Wi‑Fi without internet, inside this process only
-- (until the next KOReader restart)
function devtest.simulateOffline(s)
    local offline = s:match("offline=(%a+)")
    if not offline then return end
    local http = require("riddle.http")
    local BLACKHOLE = "10.255.255.1"
    -- http.warm / http.nameservers are replaced on the shared module and never restored:
    -- the stub lives until KOReader restarts. Acceptable only because this file is loaded
    -- in a devmode process alone (riddle_diarywidget.lua:1065-1068).
    http.warm = function() end
    http.dns_reset()
    http.dns_cache = {}
    if offline == "dns" then
        http.nameservers = function() return { BLACKHOLE } end
    else
        -- хосты по умолчанию и своих providers из конфига: иначе свой провайдер ходит в живую сеть
        local app = require("riddle.app")
        for _, host in ipairs(app.hosts(require("riddle.config").load())) do http.dns_cache[host] = BLACKHOLE end
    end
    logger.info("riddle: TEST offline simulation:", offline)
end

local function listSamples(dir)
    local out = {}
    local ok, iter, d = pcall(lfs.dir, dir)
    if ok then
        for name in iter, d do
            if name:match("%.png$") then out[#out + 1] = name end
        end
    end
    table.sort(out)
    return out
end

local function copyFile(src_path, dst_path)
    local src = io.open(src_path, "rb")
    if not src then return nil end
    local data = src:read("*a")
    src:close()
    local dst = io.open(dst_path, "wb")
    if not dst then return nil end
    dst:write(data)
    dst:close()
    return #data
end

local function percentile(sorted, q)
    if #sorted == 0 then return -1 end
    return sorted[math.max(1, math.ceil(#sorted * q))]
end

-- "rose=N" in the testmode string -> N | nil
function devtest.parseRose(s)
    return tonumber(s:match("rose=(%d+)"))
end

-- a rose of the winds in the widget's stroke format { p = { x1, y1, x2, y2, … } }: a circle in one stroke (365°,
-- counter-clockwise, overlapping) and two near-straight bars crossing inside it. Own synthetic: the tests' fixtures
-- (tests/fixtures/rose_strokes.lua) do not travel to the device. Deterministic wobble instead of math.random.
function devtest.roseStrokes()
    local function wob(i, a) return math.floor(a * math.sin(i * 1.7) + 0.5) end
    local circle = {}
    for i = 0, 73 do -- 365° in 5° steps
        local a = math.rad(-5 * i)
        circle[#circle + 1] = math.floor(380 + 150 * math.cos(a) + wob(i, 3) + 0.5)
        circle[#circle + 1] = math.floor(500 + 140 * math.sin(a) + wob(i + 5, 3) + 0.5)
    end
    local function bar(x0, y0, x1, y1)
        local p = {}
        for i = 0, 50 do
            p[#p + 1] = math.floor(x0 + (x1 - x0) * i / 50 + wob(i, 2) + 0.5)
            p[#p + 1] = math.floor(y0 + (y1 - y0) * i / 50 + wob(i + 9, 2) + 0.5)
        end
        return { p = p }
    end
    return { { p = circle }, bar(380, 330, 385, 670), bar(215, 505, 545, 495) }
end

-- "triangle=N" in the testmode string -> N | nil
function devtest.parseTriangle(s)
    return tonumber(s:match("triangle=(%d+)"))
end

-- an equilateral triangle in the widget's stroke format: one closed line, 3 corners, the pen comes back past its start
-- (the closing overshoots a little, as a hand does). Own synthetic, like roseStrokes. Deterministic wobble.
function devtest.triangleStrokes()
    local function wob(i, a) return math.floor(a * math.sin(i * 1.7) + 0.5) end
    local V = { { 380, 330 }, { 540, 610 }, { 220, 610 }, { 380, 330 }, { 440, 435 } }
    local p = {}
    for k = 1, #V - 1 do
        local a, b = V[k], V[k + 1]
        local m = math.max(2, math.floor(math.max(math.abs(b[1] - a[1]), math.abs(b[2] - a[2])) / 6))
        for i = (k == 1) and 0 or 1, m do
            p[#p + 1] = math.floor(a[1] + (b[1] - a[1]) * i / m + wob(i + k, 2) + 0.5)
            p[#p + 1] = math.floor(a[2] + (b[2] - a[2]) * i / m + wob(i + k + 9, 2) + 0.5)
        end
    end
    return { { p = p } }
end

-- seal=<names>: the names of the pages, comma separated -> list | nil (no seal= in the line)
function devtest.parseSeal(s)
    local list = s:match("seal=([%w_,]+)")
    if not list then return nil end
    local out = {}
    for name in list:gmatch("[^,]+") do out[#out + 1] = name end
    return out
end

-- a polyline through the corners V (every ~6 px a point, a deterministic wobble of amp px instead of math.random)
local function line(V, amp, phase)
    local function wob(i, a) return math.floor(a * math.sin(i * 1.7 + phase) + 0.5) end
    local p = {}
    for k = 1, #V - 1 do
        local a, b = V[k], V[k + 1]
        local m = math.max(2, math.floor(math.max(math.abs(b[1] - a[1]), math.abs(b[2] - a[2])) / 6))
        for i = (k == 1) and 0 or 1, m do
            p[#p + 1] = math.floor(a[1] + (b[1] - a[1]) * i / m + wob(i + k, amp) + 0.5)
            p[#p + 1] = math.floor(a[2] + (b[2] - a[2]) * i / m + wob(i + k + 9, amp) + 0.5)
        end
    end
    return p
end

-- the pages of "seal=": own synthetic signs, one stroke each, not a triangle and not a rose; the tests check what the
-- checklist expects of them (tests/devtest_seal_spec.lua). A and A2 are one sign drawn twice (glyph.match), B another;
-- tiny is under glyph.SIZE but no accidental touch (png.tiny); triangle is the status page's own. nil — no such name
local SEAL_FIGURES = {
    A = function() return { { p = line({ { 230, 340 }, { 540, 340 }, { 230, 620 }, { 540, 620 } }, 2, 0) } } end,
    A2 = function() return { { p = line({ { 236, 335 }, { 534, 345 }, { 226, 626 }, { 546, 615 } }, 4, 2) } } end,
    B = function() return { { p = line({ { 230, 620 }, { 230, 340 }, { 540, 620 }, { 540, 340 } }, 2, 1) } } end,
    tiny = function() return { { p = line({ { 330, 500 }, { 430, 500 }, { 330, 590 }, { 430, 590 } }, 1, 0) } } end,
    triangle = function() return devtest.triangleStrokes() end,
}

function devtest.sealFigure(name)
    local make = SEAL_FIGURES[name]
    return make and make() or nil
end

-- a touch of the pen: one point (on the status page it closes it, no ink)
function devtest.touchStrokes()
    return { { p = { 380, 500 } } }
end

-- widget strokes -> lists of { x, y } (what feedStrokes walks)
local function toPoints(strokes)
    local out = {}
    for si, s in ipairs(strokes) do
        local list = {}
        for i = 1, #s.p - 1, 2 do list[#list + 1] = { s.p[i], s.p[i + 1] } end
        out[si] = list
    end
    return out
end

function devtest.install(Diary, h)
    local pixels, clampRect, rssKB, RIDDLE_DIR = h.pixels, h.clampRect, h.rssKB, h.RIDDLE_DIR
    local near = require("riddle.layout").near

    -- test only: pixels of the rect that are neither pure black nor pure white
    function Diary:countGrey(x, y, w, h)
        local bb = self.canvas
        x, y, w, h = clampRect(bb, x, y, w, h)
        if w <= 0 or h <= 0 then return 0 end
        local p, stride = pixels(bb)
        local n = 0
        for yy = y, y + h - 1 do
            local row = yy * stride
            for xx = row + x, row + x + w - 1 do
                local v = p[xx]
                if v ~= 0x00 and v ~= 0xFF then n = n + 1 end
            end
        end
        return n
    end

    -- dev only: the text of every answer goes to the log (seal replies, welcomes, sleepy phrases)
    local revealAnswer = Diary.revealAnswer
    function Diary:revealAnswer(text, top, unlocked, kind, ...)
        logger.info("riddle: TEST answer text:", text, unlocked and "(unlocked)" or "")
        -- seal=: the first phrase of the page being drawn (not the thinking phrase, the refusal, the interjection)
        local run = self.seal_run
        if run and not run.phrase and kind ~= "think" and kind ~= "busy" and kind ~= "interject" then run.phrase = text end
        return revealAnswer(self, text, top, unlocked, kind, ...)
    end

    -- samples=1: the page's PNG is replaced by the next devsample before it goes to the controller
    local saveSample = Diary.saveSample
    function Diary:saveSample(pg)
        local path = saveSample(self, pg)
        local t = self.test
        if not (t and t.samples and path) then return path end
        if not t.sample_files then
            t.sample_files = {}
            local ok, iter, dir = pcall(lfs.dir, RIDDLE_DIR .. "/devsamples")
            if ok then
                for name in iter, dir do
                    if name:match("%.png$") then t.sample_files[#t.sample_files + 1] = name end
                end
            end
            logger.info("riddle: TEST devsamples:", #t.sample_files)
            table.sort(t.sample_files)
            t.sample_i = 0
        end
        local n = #t.sample_files
        if n == 0 then return path end
        t.sample_i = t.sample_i % n + 1
        local name = t.sample_files[t.sample_i]
        local src = io.open(RIDDLE_DIR .. "/devsamples/" .. name, "rb")
        local dst = io.open(path, "wb")
        if src and dst then
            local data = src:read("*a")
            dst:write(data)
            logger.info(string.format("riddle: TEST page PNG <- devsample %s (%d bytes)", name, #data))
        end
        if src then src:close() end
        if dst then dst:close() end
        return path
    end

    -- test mode: /mnt/us/riddle/testmode with "cycles=N" -> N synthetic pages through the same
    -- hooked feedEvent path a real finger uses, each next page written over the previous answer:
    -- page 2 while it appears, page 3 while it holds, page 4 while it dissolves, and so on.
    -- File content: "cycles=N exit=1 shots=0". One-shot: the file is removed.

    -- every sleep is counted: a devtest run that began before it is over (runSignRounds: awake)
    local onSuspend = Diary.onSuspend
    function Diary:onSuspend(...)
        self.slept = (self.slept or 0) + 1
        return onSuspend(self, ...)
    end

    function Diary:maybeStartTest()
        local f = io.open(RIDDLE_DIR .. "/testmode", "r")
        if not f then return end
        local s = f:read("*a") or ""
        f:close()
        os.remove(RIDDLE_DIR .. "/testmode")
        if s:match("feed=%d+") then
            self:testFeed(s)
            return
        end
        if devtest.parseRose(s) then
            self:testRose(s)
            return
        end
        if devtest.parseTriangle(s) then
            self:testTriangle(s)
            return
        end
        if devtest.parseSeal(s) then
            self:testSeal(s)
            return
        end
        if not s:match("cycles=%d+") then return end
        self.test = {
            cycles = tonumber(s:match("cycles=(%d+)")) or 1,
            exit = s:match("exit=1") ~= nil,
            shots = s:match("shots=0") == nil,
            samples = s:match("samples=1") ~= nil,
            full = s:match("full=1") ~= nil,
            n = 0,        -- pages started
            answers = 0,  -- answers revealed
            shot_dir = RIDDLE_DIR .. "/shots",
        }
        os.execute("mkdir -p " .. self.test.shot_dir)
        devtest.simulateOffline(s)
        self:instrumentRefresh()
        logger.info("riddle: TEST start cycles=", self.test.cycles, "RSS KB", rssKB())
        self:schedule(2, function() self:testWrite() end)
    end

    -- test only: time every refresh ioctl path per waveform (shows whether anything blocks the loop)
    function Diary:instrumentRefresh()
        local orig = Screen.mech_refresh
        if not orig then return end
        local acc = {}
        self.refresh_acc = acc
        Screen.mech_refresh = function(fb, flash, wf, ...)
            local t0 = now()
            orig(fb, flash, wf, ...)
            local us = time.to_us(now() - t0)
            local a = acc[wf]
            if not a then a = { n = 0, sum = 0, max = 0 } acc[wf] = a end
            a.n, a.sum = a.n + 1, a.sum + us
            if us > a.max then a.max = us end
        end
        self.restore_refresh = function() Screen.mech_refresh = orig end
    end

    function Diary:logRefresh(tag)
        local acc = self.refresh_acc
        if not acc then return end
        local parts = {}
        for wf, a in pairs(acc) do
            parts[#parts + 1] = string.format("wf%d n=%d avg_us=%d max_us=%d", wf, a.n, a.sum / a.n, a.max)
            acc[wf] = nil
        end
        logger.info("riddle: refresh calls " .. tag .. ": " .. table.concat(parts, "; "))
    end

    function Diary:testShot(name)
        local t = self.test
        if not t or not t.shots or t.n > 4 then return end
        local path = string.format("%s/p%d_%s.png", t.shot_dir, t.n, name)
        -- defer until the queued refresh has been pushed to Screen.bb
        UIManager:nextTick(function() Screen:shot(path) end)
    end

    -- test only: ink pixels lost in a rect: every point of a fully visible stroke must be black
    function Diary:countLostInk(x, y, w, h)
        local p, stride = pixels(self.canvas)
        local box = { x, y, x + w - 1, y + h - 1 }
        local n = 0
        for _, s in ipairs(self.strokes) do
            if s.lvl == 0 and near(s.b, box, 0) then
                local pts = s.p
                for i = 1, #pts, 2 do
                    local px, py = pts[i], pts[i + 1]
                    if px >= x and px < x + w and py >= y and py < y + h and p[py * stride + px] ~= 0x00 then
                        n = n + 1
                    end
                end
            end
        end
        return n
    end

    -- answer k's phase starts: the next page goes over it, the phase rotating with k
    local NEXT_PAGE_AT = { [1] = { "reveal", 0.3 }, [2] = { "hold", 1.0 }, [0] = { "fade", 0.05 } }
    -- the thinking phrase, the refusal and the interjection are not answers of the cycle (kind "think" /
    -- "busy" / "interject", riddle.hold): the next synthetic page must not go over them, it would get a
    -- refusal and never reach the model
    function Diary:testOnAnswer(phase)
        local t = self.test
        local a = self.answer
        if a and (a.kind == "think" or a.kind == "busy" or a.kind == "interject") then return end
        if phase == "reveal" then t.answers = t.answers + 1 end
        local k = t.answers
        local at = NEXT_PAGE_AT[k % 3]
        if t.n == k and t.n < t.cycles and at[1] == phase then
            logger.info(string.format("riddle: TEST page %d goes over answer %d while it is in '%s'", k + 1, k, phase))
            t.over = phase
            self:schedule(at[2], function() self:testWrite() end)
        end
        -- the last answer of the round stands like in life (no timer): the run ends when it holds
        if phase == "hold" and k >= t.cycles and t.n >= t.cycles
            and not (self.page or self.cur or #self.queue > 0 or self.inflight > 0) then
            self:testFinish()
        end
    end

    function Diary:testAnswerGone()
        local t = self.test
        logger.info(string.format("riddle: TEST answer %d/%d gone, RSS KB %d", t.answers, t.cycles, rssKB()))
        self:logRefresh("answer")
    end

    function Diary:testIdle()
        local t = self.test
        if t.n == 1 then self:testShot("clean") end
        if t.n < t.cycles then
            -- the chained page was not started (its answer phase got skipped): keep going
            logger.info("riddle: TEST blank page before all pages were written, writing the next one")
            self:schedule(1, function() self:testWrite() end)
            return
        end
        self:testFinish()
    end

    function Diary:testFinish()
        local t = self.test
        logger.info(string.format("riddle: TEST finished, %d pages, %d answers, RSS KB %d", t.n, t.answers, rssKB()))
        self.test = nil
        if t.exit then
            -- synthetic 3 s hold in the top-right corner
            local tev = { slot = 0, id = 7, x = self.w - 40, y = 40, timev = now() }
            self.gd:feedEvent({ tev })
            logger.info("riddle: TEST corner hold started")
            local dir = t.shot_dir
            UIManager:scheduleIn(5, function() Screen:shot(dir .. "/c_after_exit.png") end)
        end
    end

    -- build a few lines of looping "handwriting" as a list of strokes (points)
    local function synthStrokes(seed, full)
        local strokes = {}
        local lines = { 230, 330, 430 }
        if full then
            lines = {}
            for y = 90, 990, 60 do lines[#lines + 1] = y end
        end
        for li, base in ipairs(lines) do
            local x = (full and 20 or 60) + ((seed + li) % 3) * 12
            while x < (full and 700 or 640) do
                local len = 70 + ((x * 7 + seed * 13 + li * 29) % 90)
                local pts = {}
                for t = 0, len, 3 do
                    local px = x + t + 10 * math.sin(t * 0.30)
                    local py = base - 22 * math.abs(math.sin(t * 0.11 + li)) + 8 * math.cos(t * 0.30)
                    pts[#pts + 1] = { math.floor(px), math.floor(py) }
                end
                strokes[#strokes + 1] = pts
                x = x + len + 28
            end
        end
        return strokes
    end

    -- feed: PNGs straight into the controller; nothing is drawn, the screen never changes
    function Diary:testFeed(s)
        local ctl = self.controller
        if not ctl then
            logger.warn("riddle: FEED no controller")
            return
        end
        devtest.simulateOffline(s)
        local n = tonumber(s:match("feed=(%d+)")) or 1
        local gap = tonumber(s:match("gap=([%d.]+)")) or 8
        local full = s:match("full=1") ~= nil
        if s:match("new=1") then
            -- штатный разрыв сессии — пауза больше memory.lua SESSION_GAP_S (4 ч): спрашиваем у памяти
            -- «сейчас» на 5 ч вперёд, она заводит сессию; реплики потом пишутся с настоящим временем
            ctl.deps.memory:session(ctl.deps.now() + 5 * 3600)
        end
        local files = listSamples(RIDDLE_DIR .. "/devsamples")
        local times, i = {}, 0
        local rss0 = rssKB()
        logger.info(string.format("riddle: FEED start n=%d gap=%s full=%s samples=%d RSS KB %d", n, gap,
            tostring(full), #files, rss0))
        local function one()
            if self.cur then -- a real finger is writing: never block under it
                self:schedule(1, one)
                return
            end
            i = i + 1
            if i > n then
                table.sort(times)
                ctl:on_sleep()
                logger.info(string.format("riddle: FEED done %d requests p50=%d p90=%d max=%d ms, RSS KB %d -> %d, seal locked",
                    #times, percentile(times, 0.5), percentile(times, 0.9), times[#times] or -1, rss0, rssKB()))
                return
            end
            local path, what
            if full then
                local pg = { strokes = {} }
                for _, pts in ipairs(synthStrokes(i, true)) do
                    local p = {}
                    for _, xy in ipairs(pts) do
                        p[#p + 1], p[#p + 2] = xy[1], xy[2]
                        local b = pg.ink
                        if not b then pg.ink = { xy[1], xy[2], xy[1], xy[2] } else
                            b[1], b[2] = math.min(b[1], xy[1]), math.min(b[2], xy[2])
                            b[3], b[4] = math.max(b[3], xy[1]), math.max(b[4], xy[2])
                        end
                    end
                    pg.strokes[#pg.strokes + 1] = { p = p }
                end
                path = self:saveSample(pg) -- offscreen bitmap only; logs the PNG size
                what = "full page"
            elseif #files > 0 then
                local name = files[(i - 1) % #files + 1]
                path = string.format("%s/samples/feed-%03d.png", RIDDLE_DIR, i)
                local size = copyFile(RIDDLE_DIR .. "/devsamples/" .. name, path)
                what = string.format("%s %s bytes", name, tostring(size))
            end
            if not path then
                logger.warn("riddle: FEED no PNG for request", i)
                return
            end
            logger.info(string.format("riddle: FEED %d/%d start: %s", i, n, what))
            local t0 = now()
            local text = ctl:on_page(path)
            local ms = time.to_ms(now() - t0)
            times[#times + 1] = ms
            logger.info(string.format("riddle: FEED %d/%d %d ms, seal %s, png left %s: %s", i, n, ms,
                ctl.seal_open and "open" or "closed", tostring(lfs.attributes(path, "mode") ~= nil), text))
            self:schedule(gap, one)
        end
        self:schedule(3, one)
    end

    -- strokes (lists of { x, y }) through the hooked feedEvent like a finger: ~80 Hz, a lift between strokes.
    -- onStroke(si, n) before the first point of stroke si; done() right after the last lift.
    -- alive() (optional) is asked before every next point: false -> the feed stops where it is (done is not called)
    -- and logs one line, so the tail of an abandoned round never reaches the page
    function Diary:feedStrokes(strokes, onStroke, done, alive, tag)
        local si, pi = 1, 0
        local tev = { slot = 0, id = 1 }
        local frame = { tev }
        local function tick()
            if alive and not alive() then
                logger.info(string.format("riddle: %s feed stopped, round is over (stroke %d/%d)", tag or "ROSE", si, #strokes))
                return
            end
            local st = strokes[si]
            if not st then
                if done then done() end
                return
            end
            if pi == 0 and onStroke then onStroke(si, #strokes) end
            pi = pi + 1
            local p = st[pi]
            if p then
                tev.id, tev.x, tev.y, tev.timev = 1, p[1], p[2], now()
                self.gd:feedEvent(frame)            -- goes through our hook
                self:schedule(0.012, tick)          -- ~80 Hz, like the panel
            else
                tev.id = -1
                self.gd:feedEvent(frame)
                si, pi = si + 1, 0
                self:schedule(0.15, tick)           -- pen lift between "words"
            end
        end
        tick()
    end

    function Diary:testWrite()
        local t = self.test
        if not t then return end
        t.n = t.n + 1
        local over = t.over
        t.over = nil
        local strokes = synthStrokes(t.n, t.full)
        self:feedStrokes(strokes, function(si)
            if si == math.floor(#strokes * 2 / 3) then
                self:testShot(over and ("over_answer_" .. over) or "midwriting")
            end
        end)
    end

    -- rose=N / triangle=N: N rounds of "sign on the page -> its mode opens (the map / the status page) -> a second feed
    -- (a rose on the parchment / a touch) -> the mode closes". One runner for both (o: tag, noun, n, first / second —
    -- point lists, is_open(), close(), needs_seal, steps).
    -- Waits are polls of the mode every 0.25 s, 30 s at most (a miss is logged as -1, the round goes on).
    -- A round that finds the mode still open (the last close missed) closes it and counts as a miss.
    -- Sleep (Diary.slept, counted since the run began) aborts the run, in every mode: it closes the mode, the round must not
    -- count that as its close nor feed the pen over the screensaver. needs_seal (the rose: under a closed seal her page is a
    -- message to the model): a closed seal aborts the mode too. The triangle goes past the model under any seal — no seal check.
    -- Sleep in the middle of a feed drops the feed's self:schedule ticks (resetPage), so every feed has a watchdog on
    -- a round timer: it logs "<tag> aborted" instead of a silent end.
    -- n = 0 is logged as a zero run; a mode left open by the last round is closed when the run ends.
    -- steps (the triangle): the open and the close are logged as separate lines "cycle i open=<ms>" / "cycle i close=<ms>";
    -- without it one line "cycle i open=<ms> close=<ms>" after the close.
    -- The round's own timers (waits, pauses) are not self:schedule tasks: openMap/closeMap/openStatus call resetPage,
    -- which unschedules every one of those, so the round would die at the first opening. Like self:schedule, a timer of
    -- a closed widget (no canvas) does nothing
    local ROSE_WAIT_S, ROSE_STAY_S, ROSE_PAUSE_S = 30, 5, 4
    function Diary:roseSchedule(s, fn)
        UIManager:scheduleIn(s, function()
            if self.canvas then fn() end
        end)
    end

    -- the watchdog of a feed: the time it needs plus a margin (a feed that outlives it is lost: sleep dropped its ticks)
    local function feedBudget(points)
        local s = 5
        for _, st in ipairs(points) do s = s + #st * 0.012 * 1.5 + 0.15 end
        return s
    end

    -- poll every 0.25 s until want() holds: cb(ms since the call) or cb(-1) after ROSE_WAIT_S
    function Diary:waitFor(want, cb)
        local t0 = now()
        local function poll()
            local ms = time.to_ms(now() - t0)
            if want() then
                cb(math.floor(ms))
            elseif ms >= ROSE_WAIT_S * 1000 then
                cb(-1)
            else
                self:roseSchedule(0.25, poll)
            end
        end
        poll()
    end

    function Diary:runSignRounds(o)
        local tag, n, ctl = o.tag, o.n, self.controller
        -- asleep: a sleep since this run began (Diary.slept counts them; sleep closes the mode and the round's own
        -- timers outlive it), or — the rose only — the seal is shut
        local slept0 = self.slept or 0
        local function awake() return (self.slept or 0) == slept0 and (not o.needs_seal or ctl.seal_open) end
        logger.info(string.format("riddle: %s start n=%d", tag, n))
        local i, opened, closed = 0, 0, 0
        local dead = false -- the round is over (aborted): a late callback of a feed that was given up on goes nowhere
        -- the run ends with the mode closed, whatever the last round did; true if it had to be closed
        local function closeLeftOpen()
            if not o.is_open() then return false end
            o.close()
            return true
        end
        local function aborted()
            dead = true
            logger.info(string.format("riddle: %s aborted (%s)", tag, awake() and "feed lost" or "sleep"))
            closeLeftOpen()
        end
        -- feedStrokes(points) -> then_(); the feed's ticks are cancelled by sleep, a dead feed is reported once
        local function feed(points, then_)
            local finished = false
            self:feedStrokes(points, nil, function()
                finished = true
                if not dead then then_() end
            end, function() return not dead and awake() end, tag)
            self:roseSchedule(feedBudget(points), function()
                if not finished then aborted() end
            end)
        end
        local function cycle()
            if self.cur then -- a real finger is writing: never write under it
                self:roseSchedule(1, cycle)
                return
            end
            if dead then return end
            if not awake() then -- asleep: the next rose would be a message to the model
                aborted()
                return
            end
            i = i + 1
            if i > n then
                local note = n == 0 and " (zero run)" or ""
                if closeLeftOpen() then note = " (" .. o.noun .. " left open, closed)" end
                logger.info(string.format("riddle: %s %sn=%d opened=%d closed=%d%s", tag, o.steps and "" or "done ", n,
                    opened, closed, note))
                return
            end
            if o.is_open() then
                -- the previous round did not get the mode closed: a sign fed into an open mode is no opening
                logger.info(string.format("riddle: %s cycle %d open=-1 close=-1", tag, i))
                o.close()
                self:roseSchedule(ROSE_PAUSE_S, cycle)
                return
            end
            feed(o.first, function()
                self:waitFor(o.is_open, function(open_ms)
                    if open_ms < 0 then
                        logger.info(string.format("riddle: %s cycle %d open=-1 close=-1", tag, i))
                        self:roseSchedule(ROSE_PAUSE_S, cycle)
                        return
                    end
                    opened = opened + 1
                    if o.steps then logger.info(string.format("riddle: %s cycle %d open=%d", tag, i, open_ms)) end
                    self:roseSchedule(ROSE_STAY_S, function()
                        feed(o.second, function()
                            self:waitFor(function() return not o.is_open() end, function(close_ms)
                                if not awake() then
                                    -- sleep closed the mode, not the sign: not counted as a close
                                    logger.info(string.format("riddle: %s cycle %d open=%d close=-1 (sleep)", tag, i, open_ms))
                                    aborted()
                                    return
                                end
                                if close_ms >= 0 then closed = closed + 1 end
                                if o.steps then
                                    logger.info(string.format("riddle: %s cycle %d close=%d", tag, i, close_ms))
                                else
                                    logger.info(string.format("riddle: %s cycle %d open=%d close=%d", tag, i, open_ms, close_ms))
                                end
                                self:roseSchedule(ROSE_PAUSE_S, cycle)
                            end)
                        end)
                    end)
                end)
            end)
        end
        self:roseSchedule(2, cycle)
    end

    -- rose=N: the rose of the winds on the page opens the map, the rose on the parchment closes it
    function Diary:testRose(s)
        local n = devtest.parseRose(s)
        local ctl = self.controller
        if not (ctl and ctl.seal_open) then
            -- the rose on a page under a closed seal is a message: it would go to the model n times
            logger.err("riddle: ROSE seal closed - rose=" .. n .. " aborted, nothing was drawn")
            return
        end
        local strokes = toPoints(devtest.roseStrokes())
        self:runSignRounds({
            tag = "ROSE", noun = "map", n = n, needs_seal = true,
            first = strokes, second = strokes,
            is_open = function() return self.map ~= nil end,
            close = function() self:closeMap("devtest") end,
        })
    end

    -- triangle=N: the triangle on the page opens the status page, a touch closes it. The triangle is no message under
    -- any seal (onPageDone: its check comes first), so a closed seal is no reason to stop
    function Diary:testTriangle(s)
        self:runSignRounds({
            tag = "TRIANGLE", noun = "status", n = devtest.parseTriangle(s), steps = true,
            first = toPoints(devtest.triangleStrokes()), second = toPoints(devtest.touchStrokes()),
            is_open = function() return self.status ~= nil end,
            close = function() self:closeStatus("devtest") end,
        })
    end

    -- seal=<names>: the pages of the checklist, one pen page per name. A page is over when its phrase is on screen (or
    -- the status page opened -- it is closed by a touch's way: closeStatus), a quiet page (tiny: nobody answers it) --
    -- after SEAL_QUIET_S. A phrase that never comes is logged as nil after ROSE_WAIT_S. Names are checked before the
    -- first stroke: a typo draws nothing. Sleep aborts the run, as in runSignRounds
    local SEAL_QUIET_S, SEAL_PAUSE_S = 8, 3
    function Diary:testSeal(s)
        -- the controller is built once per process, at launch; the sample's path is fixed then (main.lua testKeyPath). A
        -- testmode written after the launch finds the owner's controller: its "set the key" mode would write the owner's file
        local ctl = self.controller
        if not (ctl and ctl.key_path == require("riddle.app").TEST_KEY_PATH) then
            logger.err("riddle: devtest seal: контроллер на ключе владельца — перезапусти KOReader после записи testmode, nothing was drawn")
            return
        end
        local names = devtest.parseSeal(s)
        for _, name in ipairs(names) do
            if not devtest.sealFigure(name) then
                logger.err("riddle: devtest seal unknown page " .. name .. " - aborted, nothing was drawn")
                return
            end
        end
        local run = {}
        self.seal_run = run
        local slept0 = self.slept or 0
        local function awake() return (self.slept or 0) == slept0 end
        local i, dead = 0, false
        local function over(note)
            dead = true
            self.seal_run = nil
            logger.info(string.format("riddle: devtest seal %s pages=%d", note, i))
        end
        local function words(text)
            local out = {}
            for w in text:gmatch("%S+") do
                out[#out + 1] = w
                if #out == 5 then break end
            end
            return table.concat(out, " ")
        end
        local function page()
            if dead then return end
            if self.cur then -- a real finger is writing: never write under it
                self:roseSchedule(1, page)
                return
            end
            if not awake() then return over("aborted (sleep)") end
            i = i + 1
            if i > #names then
                i = #names
                return over("done")
            end
            local name = names[i]
            run.phrase = nil
            local points = toPoints(devtest.sealFigure(name))
            local finished = false
            local function logged()
                logger.info(string.format("riddle: devtest seal page %s -> %s", name, run.phrase and words(run.phrase) or "nil"))
                self:roseSchedule(SEAL_PAUSE_S, page)
            end
            -- the phrase is on screen (or the page was a sign): wait for the reveal to end, close what opened
            local function settled()
                if self.status then self:closeStatus("devtest") end
                self:waitFor(function() return not (self.answer and self.answer.phase == "reveal") end, logged)
            end
            self:feedStrokes(points, nil, function()
                finished = true
                if name == "tiny" then
                    return self:roseSchedule(SEAL_QUIET_S, settled)
                end
                self:waitFor(function() return run.phrase ~= nil or self.status ~= nil end, function()
                    -- the page is over, the sign's mode needs its moment on screen before it is closed
                    self:roseSchedule(self.status and ROSE_PAUSE_S or 0, settled)
                end)
            end, function() return not dead and awake() end, "SEAL")
            self:roseSchedule(feedBudget(points), function()
                if not finished and not dead then over("aborted (feed lost)") end
            end)
        end
        logger.info(string.format("riddle: devtest seal start pages=%d", #names))
        self:roseSchedule(2, page)
    end

end

return devtest
