-- main.lua: RiddleDiary:maybeStartDevWatch на поддельной ФС (/mnt/us на Mac нет) и поддельном UIManager.
local t = require("t")

local RIDDLE = "/mnt/us/riddle/"

-- поддельные io/os поверх настоящих: /mnt/us/... живёт в таблице files
local function fake_env(files)
  local fio = setmetatable({
    open = function(path, mode)
      if path:find("^/mnt/us/") then
        if (mode or "r"):find("r") and files[path] then return { close = function() end } end
        return nil, path .. ": No such file"
      end
      return io.open(path, mode)
    end,
  }, { __index = io })
  local fos = setmetatable({
    remove = function(path)
      if files[path] then files[path] = nil; return true end
      return nil, path .. ": No such file"
    end,
  }, { __index = os })
  return fio, fos
end

-- extra: дополнительные подмены package.loaded (для openDiary/getController)
local function load_plugin(files, extra)
  local ui = { queue = {}, restarts = 0 }
  function ui:scheduleIn(_, fn) self.queue[#self.queue + 1] = fn end
  function ui:nextTick(fn) self.queue[#self.queue + 1] = fn end
  function ui:restartKOReader() self.restarts = self.restarts + 1 end
  function ui:show() end
  local stubs = {
    ["datastorage"] = {},
    ["luasettings"] = {},
    ["ui/uimanager"] = ui,
    ["ui/widget/container/widgetcontainer"] = { extend = function(_, o) return o end },
    ["libs/libkoreader-lfs"] = {},
    ["logger"] = { info = function() end, warn = function() end },
    ["ui/time"] = {},
  }
  for name, mod in pairs(extra or {}) do stubs[name] = mod end
  for name, mod in pairs(stubs) do package.loaded[name] = mod end
  package.loaded["riddlediary/state"] = nil
  local chunk = assert(loadfile("plugin/riddlediary.koplugin/main.lua"))
  local fio, fos = fake_env(files)
  setfenv(chunk, setmetatable({ io = fio, os = fos }, { __index = _G }))
  return chunk(), ui
end

-- прогнать все отложенные проверки, которые уже стоят в очереди (по одному кругу)
local function tick(ui)
  local q = ui.queue
  ui.queue = {}
  for _, fn in ipairs(q) do fn() end
end

local tests = {}

function tests.test_stale_restart_ignored_when_devmode()
  local files = { [RIDDLE .. "devmode"] = true, [RIDDLE .. "restart"] = true }
  local plugin, ui = load_plugin(files)
  plugin:maybeStartDevWatch()
  tick(ui)
  t.eq(ui.restarts, 0, "рестарт по restart от прошлого процесса")
  t.eq(files[RIDDLE .. "restart"], nil, "старый restart не удалён")
end

function tests.test_stale_restart_removed_without_devmode()
  local files = { [RIDDLE .. "restart"] = true }
  local plugin, ui = load_plugin(files)
  plugin:maybeStartDevWatch()
  tick(ui)
  t.eq(ui.restarts, 0)
  t.eq(files[RIDDLE .. "restart"], nil, "старый restart не удалён")
end

function tests.test_restart_after_start_honoured()
  local files = { [RIDDLE .. "devmode"] = true }
  local plugin, ui = load_plugin(files)
  plugin:maybeStartDevWatch()
  tick(ui)
  t.eq(ui.restarts, 0)
  files[RIDDLE .. "restart"] = true
  tick(ui)
  t.eq(ui.restarts, 1, "запрос рестарта после старта не выполнен")
  t.eq(files[RIDDLE .. "restart"], nil)
end

-- подмены для getController: в app.new_controller видно, что main.lua передал
local function controller_stubs(seen)
  return {
    ["riddle.app"] = { new_controller = function(d) seen.deps = d; return {} end, hosts = function() return {} end },
    ["riddle.config"] = { load = function() return { password_variants = {} } end },
    ["riddle.http"] = {},
    ["riddle.llm"] = { providers = function() return {} end },
    ["riddle.memory"] = { open = function() return {} end },
    ["riddle_diarywidget"] = { new = function(_, o) return o end },
  }
end

local function open_diary_deps(files)
  local seen = {}
  local plugin = load_plugin(files, controller_stubs(seen))
  plugin:openDiary()
  t.ok(seen.deps, "контроллер не собран")
  return seen.deps
end

-- прогрев DNS после подключения к сети берёт хосты из конфига (app.hosts(cfg)), а не только app.HOSTS
function tests.test_warm_dns_uses_hosts_from_config()
  local seen, warmed, cfg_seen = {}, nil, nil
  local stubs = controller_stubs(seen)
  stubs["riddle.app"] = {
    new_controller = function(d) seen.deps = d; return {} end,
    hosts = function(cfg) cfg_seen = cfg; return { "cfg.test" } end,
    HOSTS = { "default.test" },
    when_idle = function(_, _, fn) fn() end,
  }
  stubs["riddle.config"] = { load = function() return { password_variants = {}, marker = "cfg" } end }
  stubs["riddle.http"] = { dns_cache = {}, dns_reset = function() end, warm = function(h) warmed = h end }
  stubs["ui/time"] = { monotonic = function() return 0 end, to_ms = function() return 0 end }
  local plugin, ui = load_plugin({}, stubs)
  plugin:openDiary()
  t.eq(cfg_seen and cfg_seen.marker, "cfg", "app.hosts получил конфиг")
  plugin:onNetworkConnected()
  tick(ui)
  t.eq(warmed and warmed[1], "cfg.test", "греются хосты из конфига")
end

-- прогрев «start» (3 с после запуска) идёт до getController: хосты своих providers берутся из конфига
-- сразу, а не откатываются к app.HOSTS
function tests.test_start_warm_dns_uses_config_hosts_before_controller()
  local seen, warmed, cfg_seen = {}, nil, nil
  local stubs = controller_stubs(seen)
  stubs["riddle.app"] = {
    new_controller = function(d) seen.deps = d; return {} end,
    hosts = function(cfg) cfg_seen = cfg; return { "own.test" } end,
    HOSTS = { "default.test" },
    when_idle = function(_, _, fn) fn() end,
  }
  stubs["riddle.config"] = { load = function() return { password_variants = {}, marker = "cfg" } end }
  stubs["riddle.http"] = { dns_cache = {}, dns_reset = function() end, warm = function(h) warmed = h end }
  stubs["ui/time"] = { monotonic = function() return 0 end, to_ms = function() return 0 end,
                       to_us = function() return 0 end }
  stubs["luasettings"] = { open = function() return { nilOrTrue = function() return false end } end }
  stubs["datastorage"] = { getSettingsDir = function() return "/s" end }
  local plugin, ui = load_plugin({ [RIDDLE .. "no_autostart"] = true }, stubs)
  plugin.init(setmetatable({}, { __index = plugin }))
  tick(ui)
  t.eq(seen.deps, nil, "контроллер не должен собираться до прогрева")
  t.eq(cfg_seen and cfg_seen.marker, "cfg", "app.hosts получил конфиг")
  t.eq(warmed and warmed[1], "own.test", "на старте греются хосты из конфига")
end

-- файл forget_persona (план «чей это дневник», решение 8): при сборке контроллера разделы текущей персоны стираются
-- (Controller:forget_persona), файл удаляется — повтор при следующем запуске не стирает снова
local function forget_run(files, fail)
  local seen, forgot = {}, 0
  local stubs = controller_stubs(seen)
  stubs["riddle.app"].new_controller = function(d)
    seen.deps = d
    return { forget_persona = function() forgot = forgot + 1; if fail then error("db locked") end end }
  end
  load_plugin(files, stubs):openDiary()
  t.ok(seen.deps, "контроллер собран")
  return forgot
end

function tests.test_forget_persona_file_forgets_once_and_is_removed()
  local files = { [RIDDLE .. "forget_persona"] = true }
  t.eq(forget_run(files), 1, "разделы стёрты")
  t.eq(files[RIDDLE .. "forget_persona"], nil, "файл удалён")
  t.eq(forget_run(files), 0, "без файла — не стирает")
end

function tests.test_forget_persona_failure_keeps_controller_removes_file()
  local files = { [RIDDLE .. "forget_persona"] = true }
  t.eq(forget_run(files, true), 1)
  t.eq(files[RIDDLE .. "forget_persona"], nil, "файл удалён и при сбое: иначе стирал бы на каждом запуске")
end

-- имя дневника в меню KOReader — от персонажа (план «чей это дневник», задача 9): text_func берёт его у контроллера,
-- пока не собран (первое открытие меню) — собирает; не собрался — «Дневник / Diary»
function tests.test_menu_title_comes_from_controller()
  local seen = {}
  local stubs = controller_stubs(seen)
  stubs["riddle.app"].new_controller = function(d)
    seen.deps = d
    return { title = function() return "Дневник Гермионы" end }
  end
  local plugin = load_plugin({}, stubs)
  local menu = {}
  plugin:addToMainMenu(menu)
  t.eq(type(menu.riddle_diary.text_func), "function", "text_func")
  t.eq(menu.riddle_diary.text_func(), "Дневник Гермионы")
  t.eq(menu.riddle_diary.sub_item_table[1].text, "Открыть дневник", "остальное меню прежнее")
end

function tests.test_menu_title_default_when_controller_failed()
  local seen = {}
  local stubs = controller_stubs(seen)
  stubs["riddle.config"] = { load = function() error("broken config") end }
  stubs["logger"] = { info = function() end, warn = function() end, err = function() end }
  local plugin = load_plugin({}, stubs)
  local menu = {}
  plugin:addToMainMenu(menu)
  t.eq(menu.riddle_diary.text_func(), "Дневник / Diary")
end

function tests.test_devmode_file_sets_controller_flag()
  t.eq(open_diary_deps({ [RIDDLE .. "devmode"] = true }).devmode, true)
end

function tests.test_no_devmode_file_clears_controller_flag()
  t.eq(open_diary_deps({}).devmode, false)
end

-- ответ в дочернем процессе: main.lua собирает runner один раз на процесс поверх ffi/util и отдаёт виджету
function tests.test_open_diary_passes_runner_to_widget()
  local seen, widgets, made = {}, {}, {}
  local stubs = controller_stubs(seen)
  stubs["riddle_diarywidget"] = { new = function(_, o) widgets[#widgets + 1] = o; return o end }
  stubs["riddle.worker"] = {
    koreader_sys = function() return "SYS" end,
    new = function(o) made[#made + 1] = o; return { marker = "runner" } end,
  }
  local plugin = load_plugin({}, stubs)
  plugin:openDiary()
  t.eq(widgets[1].runner and widgets[1].runner.marker, "runner", "виджет получил runner")
  t.eq(made[1].sys, "SYS", "runner поверх koreader_sys")
  t.eq(type(made[1].schedule), "function")
  t.eq(type(made[1].clock), "function")
  widgets[1].on_close()
  plugin:openDiary()
  t.eq(#made, 1, "runner один на процесс")
  t.eq(widgets[2].runner, widgets[1].runner)
end

function tests.test_devmode_file_starts_restart_watcher()
  local plugin, ui = load_plugin({ [RIDDLE .. "devmode"] = true })
  plugin:maybeStartDevWatch()
  t.eq(#ui.queue, 1, "watcher не поставлен")
end

-- watch — флаг перезапуска без отладки (его ставит deploy.sh): наблюдатель включается и без devmode
function tests.test_watch_file_alone_starts_restart_watcher()
  local plugin, ui = load_plugin({ [RIDDLE .. "watch"] = true })
  plugin:maybeStartDevWatch()
  t.eq(#ui.queue, 1, "watcher не поставлен при одном watch")
end

function tests.test_watch_file_alone_honours_restart_after_start()
  local files = { [RIDDLE .. "watch"] = true, [RIDDLE .. "restart"] = true }
  local plugin, ui = load_plugin(files)
  plugin:maybeStartDevWatch()
  tick(ui)
  t.eq(ui.restarts, 0, "старый restart выполнен")
  files[RIDDLE .. "restart"] = true
  tick(ui)
  t.eq(ui.restarts, 1, "запрос рестарта после старта не выполнен")
end

-- watch не включает отладку: флаг контроллера читает только devmode
function tests.test_watch_file_alone_leaves_controller_debug_off()
  t.eq(open_diary_deps({ [RIDDLE .. "watch"] = true }).devmode, false)
end

function tests.test_no_devmode_file_no_restart_watcher()
  local plugin, ui = load_plugin({})
  plugin:maybeStartDevWatch()
  t.eq(#ui.queue, 0, "watcher поставлен без devmode")
end

t.run(tests)
