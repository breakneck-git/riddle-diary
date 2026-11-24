--[[--
Riddle diary: a full-screen "Tom Riddle's diary" for KOReader.

Plugin shell: menu entry, autostart flag, opening the diary widget; owns the controller
(seal, memory, LLM chain), which outlives the widget: the seal closes on sleep even when
the diary itself is closed.
@module koplugin.riddlediary
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")

-- monotonic seconds, not the wall clock (NTP on Wi-Fi up jumps it): the one clock of this file
local function monotonic_s() return time.to_s(time.monotonic()) end

local RIDDLE_DIR = "/mnt/us/riddle"
local DB_PATH = RIDDLE_DIR .. "/diary.sqlite3"
-- present at launch: the current persona's generated sections are wiped (Controller:forget_persona)
local FORGET_PATH = RIDDLE_DIR .. "/forget_persona"

-- a flag file in RIDDLE_DIR (watch, devmode, no_autostart): present or not
local function flag_present(name)
    local f = io.open(RIDDLE_DIR .. "/" .. name, "r")
    if not f then return false end
    f:close()
    return true
end

-- the sample of the seal key under devtest "seal=": its own file, the owner's key stays out of the test (app.test_key_path).
-- Read at the controller's build; the testmode file is still there then (the widget's maybeStartTest removes it later).
-- Only on a dev device: devtest is not loaded elsewhere, a stray testmode must not move the owner's key
local function testKeyPath()
    if not flag_present("devmode") then return nil end
    local f = io.open(RIDDLE_DIR .. "/testmode", "r")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    local app = require("riddle.app")
    local path = app.test_key_path(s)
    if path then os.execute('mkdir -p "' .. path:match("^(.*)/[^/]+$") .. '"') end
    return path
end

-- Survives FileManager <-> ReaderUI switches (plugins are re-instantiated, modules are not).
local state = package.loaded["riddlediary/state"] or {}
package.loaded["riddlediary/state"] = state

local RiddleDiary = WidgetContainer:extend{
    name = "riddlediary",
    is_doc_only = false,
}

local function openSettings()
    if not state.settings then
        state.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/riddlediary.lua")
    end
    return state.settings
end

-- once per KOReader process: config, memory, the controller. A failure leaves the diary
-- answering with sleepy phrases only (the widget handles a nil controller).
local function getController()
    if state.controller ~= nil then return state.controller or nil end
    local ok, err = pcall(function()
        local app = require("riddle.app")
        local config = require("riddle.config")
        local http = require("riddle.http")
        local llm = require("riddle.llm")
        http.log = function(msg) logger.warn(msg) end
        local cfg = config.load()
        state.cfg = cfg
        state.hosts = app.hosts(cfg)
        local mem_ok, mem = pcall(require("riddle.memory").open, DB_PATH, function(msg) logger.warn(msg) end)
        if not mem_ok then
            logger.err("riddle: memory open failed", mem)
            mem = nil
        end
        state.controller = app.new_controller{
            cfg = cfg,
            devmode = flag_present("devmode"),
            key_path = testKeyPath(),
            memory = mem,
            http = http,
            clock = monotonic_s,
            wall = os.time,
            log = function(msg) logger.info(msg) end,
            file_mtime = function(path) return lfs.attributes(path, "modification") end,
        }
        -- the developer re-creates the persona: the file wipes the current persona's generated sections (not
        -- the built-in one) and is removed even on a failure -- otherwise every launch would wipe them again
        local fp = io.open(FORGET_PATH, "r")
        if fp then
            fp:close()
            local fok, ferr = pcall(state.controller.forget_persona, state.controller)
            if not fok then logger.warn("riddle: persona forget failed", ferr) end
            os.remove(FORGET_PATH)
        end
        if cfg.legacy_word then
            logger.warn("riddle: config password_variants ignored (seal is a drawn key now)")
        end
        logger.info("riddle: controller ready, providers", #llm.providers(cfg),
            "seal", cfg.seal.on and (cfg.seal.invalid or "on") or "off", "memory", mem and "ok" or "none")
    end)
    if not ok then
        logger.err("riddle: controller init failed", err)
        state.controller = false
    end
    return state.controller or nil
end

-- once per KOReader process: the subprocess runner for answers (riddle.worker). A failure leaves
-- the diary answering synchronously (the widget handles a nil runner).
local function getRunner()
    if state.runner ~= nil then return state.runner or nil end
    local ok, runner = pcall(function()
        local worker = require("riddle.worker")
        return worker.new{
            sys = worker.koreader_sys(),
            schedule = function(s, fn) UIManager:scheduleIn(s, fn) end,
            clock = monotonic_s,
            log = function(msg) logger.info(msg) end,
        }
    end)
    if not ok then logger.warn("riddle: runner init failed, answers block the loop", runner) end
    state.runner = ok and runner or false
    return state.runner or nil
end

-- Notion -> /mnt/us/riddle/knowledge.sqlite3 in the runner's subprocess ("sync"; an answer preempts it,
-- the pen cancels it). No notion_token in the config: nothing starts, the diary works as before.
-- The log carries numbers and the failure reason only: no titles, no texts, no token.
local SYNC_TIMEOUT_S = 600
local SYNC_CHECK_S = 60 -- open/idle: the store is looked at no more often than this

-- parent pid as the child sees it (ffi/posix_h declares getppid); nil off KOReader
local function parentPid()
    local ok, ppid = pcall(function()
        local ffi = require("ffi")
        require("ffi/posix_h")
        return ffi.C.getppid()
    end)
    return ok and ppid or nil
end

local function syncConfig()
    if not state.cfg then state.cfg = require("riddle.config").load() end
    return state.cfg
end

-- RSS parent and child, KB, in one line for the live measurement (the parent's GC steps copy its heap
-- while the child lives); a failure here must not touch the sync
local function logSyncRss(when, child_kb)
    pcall(function()
        logger.info(require("riddle.sync").rss_line(when, require("riddle.worker").rss_kb(), child_kb))
    end)
end

-- the last sync's outcome for the status page (path and line format: riddle.sync); only on_done writes it.
-- Atomic through riddle.file: a failed write (a full FAT disk) leaves the previous outcome in place.
local function writeSyncLast(err)
    local sync = require("riddle.sync")
    local ok, res, werr = pcall(require("riddle.file").write_atomic, sync.LAST_PATH,
        sync.last_line(os.time(), err), { open = io.open, rename = os.rename })
    if not ok or not res then logger.warn("riddle: sync_last not written:", ok and werr or res) end
end

local function startSync(why)
    local ok, err = pcall(function()
        local token = syncConfig().notion_token
        local tasks_source = syncConfig().tasks_source
        if not token then return end
        local runner = getRunner()
        if not runner or runner:busy() then return end
        local started, serr = runner:start("sync", function()
            -- the child: worker's child_main stops the GC (fine for a seconds-long answer), but a sync
            -- reads hundreds of pages (~0.5 MB of garbage each) — without the GC the Kindle runs out of RAM
            collectgarbage("restart")
            -- its own store connection, the parent's SQLite handles are not touched
            local util = require("ffi/util")
            local http = require("riddle.http")
            local ppid0 = parentPid()
            local deadline = monotonic_s() + SYNC_TIMEOUT_S
            local client = require("riddle.notion").new{
                token = token,
                -- KOReader quits (exit, restart) without telling plugins, the runner's deadline dies with
                -- the parent: an orphaned child (reparented) or one past its own deadline stops here
                request = function(...)
                    if ppid0 and parentPid() ~= ppid0 then return nil, "parent gone" end
                    if monotonic_s() > deadline then return nil, "deadline" end
                    return http.request(...)
                end,
                -- usleep takes whole microseconds; seconds go to sleep so a long Retry-After fits
                sleep = function(s)
                    local whole = math.floor(s)
                    if whole > 0 then util.sleep(whole) end
                    local us = math.floor((s - whole) * 1e6 + 0.5)
                    if us > 0 then util.usleep(us) end
                end,
                clock = monotonic_s,
            }
            local clock = monotonic_s
            return require("riddle.sync").run{
                client = client,
                store_path = require("riddle.knowledge").PATH,
                wall = os.time,
                clock = clock,
                tasks_source = tasks_source,
                -- classifying the bases: a fresh LLM chain in this child (its dead keys stay here),
                -- the chain's log lines are masked and ride back in the payload
                classify = function(messages)
                    local chain = require("riddle.app").chain{ cfg = syncConfig(), http = http, clock = clock }
                    local res = chain:remote_fn(messages, false, { max_tokens = 1500, temperature = 0 })()
                    local logs = {}
                    for i, line in ipairs(res.logs or {}) do logs[i] = chain.mask(line) end
                    return res.result and res.result.text, res.err, logs
                end,
            }
        end, {
            timeout_s = SYNC_TIMEOUT_S,
            on_done = function(st, rerr)
                st = st or { updated = 0, err = rerr }
                writeSyncLast(st.err)
                if st.err then
                    logger.info(string.format("riddle: sync stopped: %s (updated=%d)", tostring(st.err),
                        tonumber(st.updated) or 0))
                else
                    logger.info(string.format("riddle: sync done seen=%d updated=%d deleted=%d chars=%d in %d ms" ..
                        " collections=%d tasks=%d open=%d child_rss_kb=%s",
                        tonumber(st.seen) or 0, tonumber(st.updated) or 0, tonumber(st.deleted) or 0,
                        tonumber(st.chars) or 0, tonumber(st.ms) or 0, tonumber(st.collections) or 0,
                        tonumber(st.tasks) or 0, tonumber(st.open) or 0, tostring(tonumber(st.rss_kb) or "?")))
                end
                logSyncRss("done", tonumber(st.rss_kb))
                for _, line in ipairs(type(st.llm_logs) == "table" and st.llm_logs or {}) do
                    logger.info(tostring(line))
                end
                if st.classify then logger.info(require("riddle.sync").classify_line(st)) end
            end,
        })
        if started then
            logger.info(string.format("riddle: sync start (%s)", why))
            logSyncRss("start", nil)
        else
            logger.warn("riddle: sync not started:", serr)
        end
    end)
    if not ok then logger.warn("riddle: sync start failed", err) end
end

-- read(K) with the parent's own short-lived connection to the store (open -> read -> close); a store that fails
-- raises. It runs on the UI thread (the status page, maybeSync), so a busy store is not waited for (busy_ms 0): the
-- read fails at once
local function readStore(read)
    local knowledge = require("riddle.knowledge")
    local K = knowledge.open(knowledge.PATH, 0)
    local rok, v = pcall(read, K)
    pcall(K.close, K)
    if not rok then error(v, 0) end
    return v
end

-- the last good read: the store's meta, a string | nil
local function readLastOk()
    return readStore(function(K) return K:meta("last_ok") end)
end

-- the status page, once per opening: the last good read and how many Notion documents and databases the store holds
-- -> { last_ok, docs, collections }, one connection
local function readStoreFacts()
    return readStore(function(K)
        local s = K:stats()
        return { last_ok = K:meta("last_ok"), docs = s.docs, collections = s.collections }
    end)
end

-- diary open, widget idle: sync only if the last good read is older than sync.STALE_S
local function maybeSync()
    local ok, err = pcall(function()
        if not syncConfig().notion_token then return end
        local now_s = monotonic_s()
        if state.sync_checked and now_s - state.sync_checked < SYNC_CHECK_S then return end
        state.sync_checked = now_s
        local runner = getRunner()
        if not runner or runner:busy() then return end
        local sok, last_ok = pcall(readLastOk)
        if not sok then
            logger.warn("riddle: sync skipped, store", last_ok)
            return
        end
        if require("riddle.sync").should_start(os.time(), last_ok, false) then startSync("stale") end
    end)
    if not ok then logger.warn("riddle: sync check failed", err) end
end

-- the marauder's map: the owner's point (riddle.mapjob) in the runner's subprocess ("map"; an answer preempts
-- it, closing the map cancels it). The job is the only writer of MAP_DIR; this process only reads the point.
local MAP_DIR = RIDDLE_DIR .. "/map"

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- a shell command's stdout (wpa_cli); only in the subprocess: io.popen blocks until the command exits
local function runCommand(cmd)
    local p = io.popen(cmd .. " 2>/dev/null", "r")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    return out
end

-- runs in the child (riddle.worker): the network only through riddle.http
local function mapJob()
    local util = require("ffi/util")
    local Screen = require("device").screen
    return require("riddle.mapjob").run{
        screen = { w = Screen:getWidth(), h = Screen:getHeight() },
        clock = monotonic_s, -- not the wall clock: NTP on Wi-Fi up jumps it
        log = function(line) logger.info(line) end,
        rss = require("riddle.worker").rss_kb,
        dir = MAP_DIR,
        run = runCommand,
        sleep = function(s) util.sleep(s) end,
        request = function(...) return require("riddle.http").request(...) end,
        read_file = readFile,
        write_file = require("riddle.mapjob").write_file,
        rename = os.rename,
        mkdir = function(dir) lfs.mkdir(dir) end,
        now = os.time,
    }
end

local function mapPoint()
    return require("riddle.mapjob").read_point(readFile, MAP_DIR)
end

-- the terrain around the point (riddle.terrain, written by the job); invalid -> nil. Read by the map view
-- (riddle_mapview) through the diary's map_terrain
local function mapTerrain()
    return (require("riddle.mapjob").read_terrain(readFile, MAP_DIR))
end

-- hosts to warm: known after getController; before it (the "start" warm runs 3 s after launch, the
-- controller is built on the first diary open) they come from the config, so hosts of the own
-- providers are warm from the start
local function warmHosts(app)
    if not state.hosts then
        state.hosts = app.hosts(require("riddle.config").load())
    end
    return state.hosts
end

-- DNS of every provider into http's cache while nobody waits for an answer (blocks ≤ 3 s);
-- never under the moving pen: with the finger down it waits for the pen-up
local function doWarmDns(why)
    local ok, err = pcall(function()
        local http = require("riddle.http")
        local t0 = time.monotonic()
        http.dns_reset()
        local app = require("riddle.app")
        http.warm(warmHosts(app))
        local n = 0
        for _ in pairs(http.dns_cache) do n = n + 1 end
        logger.info(string.format("riddle: dns warm (%s): %d hosts cached in %d ms", why, n,
            time.to_ms(time.monotonic() - t0)))
    end)
    if not ok then logger.warn("riddle: dns warm failed", err) end
end

local function warmDns(why)
    local ok, app = pcall(require, "riddle.app")
    if not ok then
        logger.warn("riddle: dns warm skipped", app)
        return
    end
    app.when_idle(function() return state.diary ~= nil and state.diary.cur ~= nil end,
        function(delay, fn) UIManager:scheduleIn(delay, fn) end,
        function() doWarmDns(why) end, 1)
end

function RiddleDiary:init()
    self.settings = openSettings()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if not state.autostart_done then
        state.autostart_done = true
        math.randomseed(os.time() + time.to_us(time.monotonic()) % 1000000)
        math.random(); math.random()
        UIManager:scheduleIn(3, function() warmDns("start") end)
        self:maybeStartDevWatch()
        -- Escape hatch: touch /mnt/us/riddle/no_autostart to skip autostart without editing settings.
        if flag_present("no_autostart") then
            logger.info("riddle: autostart skipped (no_autostart file)")
        elseif self.settings:nilOrTrue("autostart") then
            UIManager:nextTick(function() self:openDiary() end)
        end
    end
end

-- Restart watcher (enabled at startup by the file /mnt/us/riddle/watch or /mnt/us/riddle/devmode): every 2 s
-- look for /mnt/us/riddle/restart and do a graceful in-place restart (exit code 85: koreader.sh
-- loops without handing the screen back to the Kindle framework). watch = restart only (tools/deploy.sh
-- sets it on every deploy); devmode = restart plus debug (read in the controller, widget, devtest).
function RiddleDiary:maybeStartDevWatch()
    -- A restart file present at process start was meant for an earlier process (left by
    -- tools/deploy.sh while the watcher was off): drop it, or this fresh start restarts once more.
    os.remove(RIDDLE_DIR .. "/restart")
    if not (flag_present("watch") or flag_present("devmode")) then return end
    logger.info("riddle: restart watcher on")
    local function check()
        local r = io.open(RIDDLE_DIR .. "/restart", "r")
        if r then
            r:close()
            os.remove(RIDDLE_DIR .. "/restart")
            logger.info("riddle: dev restart requested")
            -- the sync child would outlive the restart (no deadline without the parent's runner)
            if state.runner then state.runner:cancel("sync") end
            UIManager:restartKOReader()
            return
        end
        UIManager:scheduleIn(2, check)
    end
    UIManager:scheduleIn(2, check)
end

function RiddleDiary:openDiary()
    if state.diary then return end
    local st = io.open("/proc/self/status", "r")
    if st then
        logger.info("riddle: before diary open, RSS KB", (st:read("*a"):match("VmRSS:%s*(%d+)")))
        st:close()
    end
    local DiaryWidget = require("riddle_diarywidget")
    local diary
    diary = DiaryWidget:new{
        controller = getController(),
        runner = getRunner(),
        autosuspend = self.ui and self.ui.autosuspend,
        on_idle = maybeSync,
        map_job = mapJob,
        map_point = mapPoint,
        map_terrain = mapTerrain,
        store = readStoreFacts, -- the status page: when the last good read was, what the store holds
        read_file = readFile, -- and its files (the build, the sync's last run, /proc)
        on_close = function()
            if state.diary == diary then state.diary = nil end
        end,
    }
    state.diary = diary
    UIManager:show(diary, "full")
    maybeSync()
end

-- sleep closes the seal by the on_sleep rule, diary open or not (the widget also resets its page on Suspend);
-- no seal in the config: nothing to close, on_sleep only re-arms the followup. The controller logs a real close
-- itself ("seal closed by sleep")
function RiddleDiary:onSuspend()
    local ctl = state.controller
    if ctl then ctl:on_sleep() end
    -- the diary widget (above the plugin in the window stack) got Suspend first and freed the runner
    startSync("suspend")
end

function RiddleDiary:onNetworkConnected()
    -- every plugin instance gets the event; warm once per connection
    if state.warm_task then return end
    state.warm_task = function()
        state.warm_task = nil
        warmDns("network connected")
    end
    UIManager:scheduleIn(1, state.warm_task)
end

-- the menu name is the character's (Controller:title): "Дневник Реддла" for the built-in persona. The first
-- menu draw builds the controller, as the first diary open does; if it could not be built -- the neutral name
local function menuTitle()
    local ctl = getController()
    if ctl then return ctl:title() end
    local ok, persona = pcall(require, "riddle.persona")
    return ok and persona.DEFAULT_TITLE or "Дневник"
end

function RiddleDiary:addToMainMenu(menu_items)
    menu_items.riddle_diary = {
        text_func = menuTitle,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = "Открыть дневник",
                callback = function() self:openDiary() end,
            },
            {
                text = "Открывать при запуске KOReader",
                checked_func = function() return self.settings:nilOrTrue("autostart") end,
                callback = function()
                    self.settings:flipNilOrTrue("autostart")
                    self.settings:flush()
                end,
            },
        },
    }
end

return RiddleDiary
