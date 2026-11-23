-- tools/deploy.sh на поддельных ssh/scp (tests/fakebin): что уходит на устройство и что печатается.
-- На настоящий Kindle тест не ходит.
local t = require("t")

local T = {}

-- io.popen в LuaJIT не отдаёт код возврата: дописываем его в вывод
-- env — строка «VAR=значение …» для сценария поддельного ssh; RESTART_POLL_S=0: без пауз
local function deploy(args, env)
  local dir = io.popen("mktemp -d"):read("*l")
  local p = assert(io.popen(string.format(
    "(FAKE_DIR=%s PATH=tests/fakebin:$PATH RESTART_POLL_S=0 %s sh tools/deploy.sh %s) 2>&1; echo __rc=$?",
    dir, env or "", args or ""), "r"))
  local out = p:read("*a")
  p:close()
  local f = io.open(dir .. "/log", "r")
  local log = f and f:read("*a") or ""
  if f then f:close() end
  os.execute("rm -rf " .. dir)
  return out:gsub("__rc=%d+%s*$", ""), tonumber(out:match("__rc=(%d+)")), log
end

local function touched_devmode(log) return log:find("touch /mnt/us/riddle/devmode", 1, true) ~= nil end

function T.test_default_deploy_does_not_enable_devmode()
  local out, rc, log = deploy()
  t.eq(rc, 0, out)
  t.ok(not touched_devmode(log), "рабочий дневник не должен получать devmode:\n" .. log)
end

function T.test_dev_flag_enables_devmode()
  local out, rc, log = deploy("--dev")
  t.eq(rc, 0, out)
  t.ok(touched_devmode(log), log)
end

-- testmode разбирает devtest, а он грузится только при devmode
function T.test_testmode_argument_implies_devmode()
  local out, rc, log = deploy("'cycles=1 exit=1'")
  t.eq(rc, 0, out)
  t.ok(touched_devmode(log), log)
  t.ok(log:find("cycles=1 exit=1", 1, true), "testmode записан:\n" .. log)
end

function T.test_dev_flag_with_testmode()
  local out, rc, log = deploy("--dev 'cycles=2'")
  t.eq(rc, 0, out)
  t.ok(touched_devmode(log) and log:find("cycles=2", 1, true), log)
end

-- версия сборки: файл status.BUILD_NAME в каталоге плагина, одна строка git describe клона; пишет только deploy.sh
function T.test_deploy_writes_build_version_to_plugin_dir()
  local build = require("riddle.status").BUILD_NAME
  local out, rc, log = deploy()
  t.eq(rc, 0, out)
  local d = io.popen("git describe --always --dirty"):read("*l")
  t.ok(d and d ~= "", "git describe в клоне")
  local want = "put /mnt/us/koreader/plugins/riddlediary.koplugin/" .. build .. ": " .. d
  local found
  for line in log:gmatch("[^\n]+") do if line == want then found = true end end
  t.ok(found, "ждали строку «" .. want .. "»:\n" .. log)
end

local function count(log, needle)
  local n, from = 0, 1
  while true do
    local a, b = log:find(needle, from, true)
    if not a then return n end
    n, from = n + 1, b + 1
  end
end

-- перезапуск подтверждается строкой «dev restart requested» в логе устройства, а не самим touch
function T.test_restart_is_confirmed_by_device_log()
  local out, rc, log = deploy("--dev")
  t.eq(rc, 0, out)
  t.eq(count(log, "touch /mnt/us/riddle/restart"), 1, log)
  t.ok(out:find("restart confirmed", 1, true), out)
end

-- гонка со стартом плагина: свежий restart удалён как «старый» — touch повторяется
function T.test_lost_restart_is_touched_again()
  local out, rc, log = deploy("--dev", "FAKE_LOSE=1")
  t.eq(rc, 0, out)
  t.eq(count(log, "touch /mnt/us/riddle/restart"), 2, log)
  t.ok(out:find("restart confirmed", 1, true), out)
end

-- watcher выключен (KOReader стартовал без devmode): не врём «restart requested»
function T.test_unconfirmed_restart_fails_loudly()
  local out, rc, log = deploy("--dev", "FAKE_LOSE=99")
  t.ok(rc ~= 0, "код возврата ненулевой")
  t.ok(out:find("NOT confirmed", 1, true), out)
  t.ok(not out:find("restart confirmed", 1, true), out)
  t.eq(count(log, "touch /mnt/us/riddle/restart"), 3, log)
end

function T.test_no_koreader_process_launches_it_without_restart_file()
  local out, rc, log = deploy("--dev", "FAKE_PIDOF=1")
  t.eq(rc, 0, out)
  t.eq(count(log, "touch /mnt/us/riddle/restart"), 0, log)
  -- как загрузочный job (/etc/upstart/koreader-boot.conf): без оболочки Amazon
  t.ok(log:find("koreader.sh --framework_stop", 1, true), log)
  t.ok(not log:find("--kual", 1, true), log)
end

-- watch ставит любой деплой, поэтому совет при неподтверждённом рестарте — «перезапусти руками и деплой снова»;
-- --dev включает отладку (текст страницы в лог) и в совете не нужен
function T.test_unconfirmed_restart_hint_does_not_push_dev_flag()
  local out, rc = deploy("--dev", "FAKE_LOSE=99")
  t.ok(rc ~= 0)
  t.ok(out:find("deploy again", 1, true), out)
  t.ok(not out:find("--dev", 1, true), out)
end

-- обрыв ssh посреди опроса (пустой вывод) — не подтверждение
function T.test_ssh_failure_while_polling_is_not_confirmation()
  local out, rc = deploy("--dev", "FAKE_LOSE=99 FAKE_GREP_FAIL_AFTER=1")
  t.ok(rc ~= 0, "код возврата ненулевой")
  t.ok(not out:find("restart confirmed", 1, true), out)
end

-- обрыв ssh на самом первом чтении счётчика: перезапуск не начинаем
function T.test_ssh_failure_before_first_count_stops()
  local out, rc, log = deploy("--dev", "FAKE_GREP_FAIL_AFTER=0")
  t.ok(rc ~= 0, "код возврата ненулевой")
  t.ok(not out:find("restart confirmed", 1, true), out)
  t.eq(count(log, "touch /mnt/us/riddle/restart"), 0, log)
end

-- код 255 на pidof — сбой связи, а не «KOReader не запущен»: второй koreader.sh не стартуем
function T.test_ssh_failure_on_pidof_launches_nothing()
  local out, rc, log = deploy("--dev", "FAKE_PIDOF=255")
  t.ok(rc ~= 0, "код возврата ненулевой")
  t.ok(not log:find("koreader.sh", 1, true), "второй koreader.sh при живом:\n" .. log)
  t.eq(count(log, "touch /mnt/us/riddle/restart"), 0, log)
end

-- koreader.sh при каждом старте срезает голову crash.log (tail -c 500000): старых строк «dev restart
-- requested» становится меньше, их число не растёт, хотя перезапуск был
function T.test_restart_is_confirmed_when_log_head_is_truncated_on_restart()
  local out, rc, log = deploy("--dev", "FAKE_TRUNCATE=1")
  t.eq(rc, 0, out)
  t.ok(out:find("restart confirmed", 1, true), out)
  t.eq(count(log, "touch /mnt/us/riddle/restart"), 1, log)
end

-- строка лога ssh, где впервые встречается needle (0 — нет)
local function line_of(log, needle)
  local i = 0
  for l in log:gmatch("[^\n]+") do
    i = i + 1
    if l:find(needle, 1, true) then return i end
  end
  return 0
end

-- флаг перезапуска watch ставится всегда и до запроса перезапуска: наблюдатель включается и без devmode
function T.test_watch_flag_is_set_before_restart_request()
  for _, args in ipairs({ "", "--dev", "'cycles=1'" }) do
    local out, rc, log = deploy(args)
    t.eq(rc, 0, out)
    local w, r = line_of(log, "touch /mnt/us/riddle/watch"), line_of(log, "touch /mnt/us/riddle/restart")
    t.ok(w > 0 and r > 0 and w < r, "watch до restart (" .. args .. "):\n" .. log)
  end
end

-- без --dev отладка выключается до запроса перезапуска: новый процесс стартует без devmode
function T.test_default_deploy_removes_devmode_before_restart_request()
  local out, rc, log = deploy()
  t.eq(rc, 0, out)
  local d, r = line_of(log, "rm -f /mnt/us/riddle/devmode"), line_of(log, "touch /mnt/us/riddle/restart")
  t.ok(d > 0 and d < r, "devmode не снят до restart:\n" .. log)
end

function T.test_dev_deploy_keeps_devmode()
  for _, args in ipairs({ "--dev", "'cycles=1'" }) do
    local out, rc, log = deploy(args)
    t.eq(rc, 0, out)
    t.ok(not log:find("rm -f /mnt/us/riddle/devmode", 1, true), "devmode снят при " .. args .. ":\n" .. log)
    t.ok(touched_devmode(log), log)
  end
end

t.run(T)
