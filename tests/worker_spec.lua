-- riddle.worker: дочерний процесс на настоящих fork/pipe (tests/subprocess_shim.lua), часы и
-- планировщик — настоящие, поэтому таймауты — в долях секунды.
local t = require("t")
local shim = require("subprocess_shim")
local worker = require("riddle.worker")

local T = {}

-- runner поверх шима; env.pids — pid каждого spawn; clock — часы runner'а (по умолчанию настоящие)
local function make(clock)
  local env = { pids = {}, loop = shim.loop(), logs = {} }
  local sys = shim.sys()
  local spawn = sys.spawn
  sys.spawn = function(child_fn)
    local pid, fd = spawn(child_fn)
    if pid then env.pids[#env.pids + 1] = pid end
    return pid, fd
  end
  env.sys = sys
  env.runner = worker.new{ sys = sys, schedule = env.loop.schedule, clock = clock or shim.clock,
                           log = function(msg) env.logs[#env.logs + 1] = msg end }
  return env
end

-- on_done, которая запоминает вызовы
local function recorder()
  local r = { calls = 0 }
  r.fn = function(payload, err)
    r.calls = r.calls + 1
    r.payload, r.err, r.at = payload, err, shim.clock()
  end
  return r
end

function T.test_child_result_comes_back_through_pipe()
  local env = make()
  local r = recorder()
  t.ok(env.runner:start("answer", function() return { a = 1, s = "ё" } end, { timeout_s = 5, on_done = r.fn }))
  env.loop.run(1)
  t.eq(r.calls, 1)
  t.eq(r.err, nil)
  t.eq(r.payload.a, 1)
  t.eq(r.payload.s, "ё")
  t.eq(env.runner:busy(), nil, "после ответа runner свободен")
  t.ok(shim.gone(env.pids[1]), "дочерний собран")
end

-- «start не ждёт дочерний» — по факту, не по стене времени: дочерний стоит на файле-воротах, который
-- тест создаёт уже после возврата start. Если start дождался дочернего (ворота закрыты — он ждёт
-- до потолка 3 с), к моменту проверки дочерний уже завершён, и тест падает.
function T.test_parent_free_while_child_works()
  local env = make()
  local r = recorder()
  local gate = os.tmpname()
  os.remove(gate)
  local function wait_gate() -- в дочернем
    local t0 = shim.clock()
    while not io.open(gate, "r") and shim.clock() - t0 < 3 do shim.sleep(0.01) end
    return { ok = true }
  end
  env.runner:start("answer", wait_gate, { timeout_s = 5, on_done = r.fn })
  local alive = not env.sys.done(env.pids[1])
  local busy, calls_at_return = env.runner:busy(), r.calls
  io.open(gate, "w"):close() -- открыть ворота после возврата start
  env.loop.run(1.2)
  os.remove(gate)
  t.ok(alive, "дочерний ещё работает в момент возврата start")
  t.eq(busy, "answer")
  t.eq(calls_at_return, 0)
  t.eq(r.calls, 1)
  t.eq(r.payload.ok, true)
end

function T.test_timeout_kills_child()
  local env = make()
  local r = recorder()
  local t0 = shim.clock()
  env.runner:start("answer", function() shim.sleep(5) return { late = true } end, { timeout_s = 0.3, on_done = r.fn })
  env.loop.run(1.5)
  t.eq(r.calls, 1)
  t.eq(r.err, "timeout")
  t.ok(r.at - t0 < 1, "таймаут меньше секунды")
  t.ok(shim.gone(env.pids[1]), "дочерний убит и собран runner'ом, не зомби")
  t.eq(env.runner:busy(), nil)
end

-- дедлайн — ровно start + timeout_s по часам runner'а, не по стене времени: часы стоят за миг до дедлайна —
-- опросы идут, а таймаута нет; часы на дедлайне — следующий опрос убивает
function T.test_timeout_at_deadline_by_runner_clock()
  local now = 100
  local env = make(function() return now end)
  local r = recorder()
  env.runner:start("answer", function() shim.sleep(5) return { late = true } end, { timeout_s = 0.3, on_done = r.fn })
  now = 100 + 0.3 - 0.01
  env.loop.run(2.5 * worker.POLL_S)
  t.eq(r.calls, 0, "до дедлайна — не убит")
  t.eq(env.runner:busy(), "answer")
  now = 100 + 0.3
  env.loop.run(2.5 * worker.POLL_S)
  t.eq(r.calls, 1, "на дедлайне — убит")
  t.eq(r.err, "timeout")
  env.loop.run(2.5 * worker.POLL_S)
  t.ok(shim.gone(env.pids[1]), "дочерний собран")
end

function T.test_child_error_reported()
  local env = make()
  local r = recorder()
  env.runner:start("answer", function() error("boom") end, { timeout_s = 5, on_done = r.fn })
  env.loop.run(1)
  t.eq(r.payload, nil)
  t.ok(r.err and r.err:sub(1, 7) == "child: ", tostring(r.err))
  t.ok(r.err:find("boom", 1, true), r.err)
end

function T.test_child_exit_without_output_is_crashed()
  local env = make()
  local r = recorder()
  env.runner:start("answer", function() require("ffi").C._exit(0) end, { timeout_s = 5, on_done = r.fn })
  env.loop.run(1)
  t.eq(r.calls, 1)
  t.eq(r.err, "crashed")
  t.ok(shim.gone(env.pids[1]))
end

function T.test_payload_over_cap_is_error()
  local env = make()
  local r = recorder()
  env.runner:start("answer", function() return { s = string.rep("x", 40000) } end, { timeout_s = 5, on_done = r.fn })
  env.loop.run(1)
  t.eq(r.payload, nil)
  t.eq(r.err, "payload")
end

function T.test_answer_preempts_sync()
  local env = make()
  local sync, ans = recorder(), recorder()
  env.runner:start("sync", function() shim.sleep(5) return { synced = true } end, { timeout_s = 60, on_done = sync.fn })
  env.loop.run(0.1)
  t.ok(env.runner:start("answer", function() return { answered = true } end, { timeout_s = 5, on_done = ans.fn }))
  t.eq(sync.calls, 1, "вытесненный sync узнаёт сразу")
  t.eq(sync.err, "cancelled")
  env.loop.run(1)
  t.eq(ans.calls, 1)
  t.eq(ans.payload.answered, true)
  t.eq(sync.calls, 1, "поздний sync не приходит")
  t.ok(shim.gone(env.pids[1]), "sync убит и собран")
end

-- пересказ сессии (фоновый, как sync) ответ тоже вытесняет: страница не ждёт и не получает "busy"
function T.test_answer_preempts_summary()
  local env = make()
  local sum, ans = recorder(), recorder()
  env.runner:start("summary", function() shim.sleep(5) return { text = "x" } end, { timeout_s = 60, on_done = sum.fn })
  env.loop.run(0.1)
  t.ok(env.runner:start("answer", function() return { answered = true } end, { timeout_s = 5, on_done = ans.fn }))
  t.eq(sum.calls, 1, "вытесненный пересказ узнаёт сразу")
  t.eq(sum.err, "cancelled")
  env.loop.run(1)
  t.eq(ans.calls, 1)
  t.eq(ans.payload.answered, true)
  t.ok(shim.gone(env.pids[1]), "пересказ убит и собран")
end

-- ответ ответ не вытесняет
function T.test_answer_does_not_preempt_answer()
  local env = make()
  local a1, a2 = recorder(), recorder()
  env.runner:start("answer", function() shim.sleep(0.3) return { n = 1 } end, { timeout_s = 5, on_done = a1.fn })
  local ok, err = env.runner:start("answer", function() return { n = 2 } end, { timeout_s = 5, on_done = a2.fn })
  t.eq(ok, nil)
  t.eq(err, "busy")
  env.loop.run(1)
  t.eq(a1.calls, 1)
  t.eq(a2.calls, 0)
end

function T.test_sync_refused_while_answer_busy()
  local env = make()
  local ans, sync = recorder(), recorder()
  env.runner:start("answer", function() shim.sleep(0.3) return { answered = true } end, { timeout_s = 5, on_done = ans.fn })
  local ok, err = env.runner:start("sync", function() return {} end, { timeout_s = 5, on_done = sync.fn })
  t.eq(ok, nil)
  t.eq(err, "busy")
  env.loop.run(1)
  t.eq(ans.calls, 1)
  t.eq(sync.calls, 0)
  t.eq(#env.pids, 1, "sync не запускался")
end

function T.test_cancel_drops_on_done()
  local env = make()
  local r = recorder()
  env.runner:start("answer", function() shim.sleep(3) return { late = true } end, { timeout_s = 5, on_done = r.fn })
  env.loop.run(0.05)
  env.runner:cancel("sync")
  t.eq(env.runner:busy(), "answer", "cancel чужого вида не трогает ответ")
  env.runner:cancel("answer")
  t.eq(env.runner:busy(), nil)
  env.loop.run(1)
  t.eq(r.calls, 0, "отменённый ответ не приходит")
  t.ok(shim.gone(env.pids[1]), "отменённый убит и собран")
end

-- GC в дочернем стоит: иначе пометка унаследованной кучи копирует её страницы (copy-on-write)
function T.test_child_runs_without_gc_parent_keeps_it()
  local env = make()
  local r = recorder()
  env.runner:start("answer", function() return { gc = collectgarbage("isrunning") } end,
    { timeout_s = 5, on_done = r.fn })
  env.loop.run(1)
  t.eq(r.payload.gc, false, "в дочернем GC остановлен")
  t.eq(collectgarbage("isrunning"), true, "в родителе GC работает")
end

-- дочерний записал ответ, но не вышел: runner свободен — значит дочерний должен быть убит и собран,
-- иначе следующий start даст второй живой дочерний
function T.test_child_alive_after_answer_is_killed()
  local env = make()
  local spawn = env.sys.spawn
  env.sys.spawn = function(child_fn)
    return spawn(function(wfd) child_fn(wfd) shim.sleep(5) end)
  end
  local r = recorder()
  env.runner:start("answer", function() return { ok = true } end, { timeout_s = 5, on_done = r.fn })
  env.loop.run(1)
  t.eq(r.payload and r.payload.ok, true)
  t.eq(env.runner:busy(), nil)
  t.ok(shim.gone(env.pids[1]), "дочерний после ответа убит и собран")
end

-- конец pipe убитого дочернего закрывается: на каждый таймаут иначе течёт fd
function T.test_timeout_closes_pipe_fd()
  local env = make()
  local fds, closed = {}, {}
  local spawn, read_all = env.sys.spawn, env.sys.read_all
  env.sys.spawn = function(child_fn)
    local pid, fd = spawn(child_fn)
    fds[#fds + 1] = fd
    return pid, fd
  end
  env.sys.read_all = function(fd) closed[fd] = true return read_all(fd) end
  local r = recorder()
  env.runner:start("answer", function() shim.sleep(5) return {} end, { timeout_s = 0.3, on_done = r.fn })
  env.loop.run(1.5)
  t.eq(r.err, "timeout")
  t.ok(closed[fds[1]], "fd убитого закрыт")
  t.ok(shim.fd_closed(fds[1]), "fd закрыт и в ОС")
end

-- поддельный sys: процесс, который умирает только со второго kill (гонка kill(-pid) с setpgid)
local function stubborn_sys()
  local s = { kills = 0, closed = false }
  s.spawn = function() return 101, 7 end
  s.has_data = function() return false end
  s.done = function() return s.kills >= 2 end
  s.read_all = function() s.closed = true return "" end
  s.kill = function() s.kills = s.kills + 1 end
  s.write = function() end
  return s
end

function T.test_kill_repeats_until_child_is_reaped()
  local loop = shim.loop()
  local sys = stubborn_sys()
  local runner = worker.new{ sys = sys, schedule = loop.schedule, clock = shim.clock }
  local r = recorder()
  runner:start("answer", function() return {} end, { timeout_s = 0.1, on_done = r.fn })
  loop.run(1.5)
  t.eq(r.err, "timeout")
  t.ok(sys.kills >= 2, "kill повторён: " .. sys.kills)
  t.ok(sys.closed, "процесс собран, fd закрыт")
end

-- getNonBlockingReadSize не работает (ioctl): ответ всё равно забирается, когда дочерний вышел
function T.test_answer_read_after_exit_without_has_data()
  local loop = shim.loop()
  local sys = { exited = false }
  sys.spawn = function() return 101, 7 end
  sys.has_data = function() return false end
  sys.done = function() return sys.exited end
  sys.read_all = function() return '{"ok":{"a":1}}' end
  sys.kill = function() end
  sys.write = function() end
  local runner = worker.new{ sys = sys, schedule = loop.schedule, clock = shim.clock }
  local r = recorder()
  runner:start("answer", function() return {} end, { timeout_s = 5, on_done = r.fn })
  sys.exited = true
  loop.run(0.5)
  t.eq(r.err, nil)
  t.eq(r.payload and r.payload.a, 1)
end

function T.test_spawn_failure_is_error()
  local env = make()
  env.sys.spawn = function() return false, "fork failed" end
  local ok, err = env.runner:start("answer", function() return {} end, { timeout_s = 5, on_done = function() end })
  t.eq(ok, nil)
  t.eq(err, "spawn: fork failed")
  t.eq(env.runner:busy(), nil)
end

-- koreader_sys — тонкая обёртка ffi/util: проверяем соответствие вызовов
function T.test_koreader_sys_maps_ffi_util()
  local seen = {}
  package.loaded["ffi/util"] = {
    runInSubProcess = function(func, with_pipe)
      seen.with_pipe = with_pipe
      func(4242, 7) -- как дочерний KOReader: func(pid, write_fd)
      return 4242, 6
    end,
    getNonBlockingReadSize = function(fd) seen.size_fd = fd return 0 end,
    isSubProcessDone = function(pid) seen.done_pid = pid return true end,
    readAllFromFD = function(fd) seen.read_fd = fd return "x" end,
    terminateSubProcess = function(pid) seen.killed = pid end,
    writeToFD = function(fd, data, close) seen.write = { fd, data, close } return true end,
  }
  local sys = worker.koreader_sys()
  package.loaded["ffi/util"] = nil
  local real_stdout = io.stdout
  local flushed = 0
  io.stdout = setmetatable({ flush = function() flushed = flushed + 1 end }, { __index = real_stdout })
  local pid, fd = sys.spawn(function(wfd) seen.child_wfd = wfd end)
  io.stdout = real_stdout
  t.eq(flushed, 1, "stdout вытолкнут до fork")
  t.eq(pid, 4242); t.eq(fd, 6); t.eq(seen.with_pipe, true); t.eq(seen.child_wfd, 7)
  t.eq(sys.has_data(6), false); t.eq(seen.size_fd, 6)
  -- ioctl не сработал: getNonBlockingReadSize -> nil; это «нет данных», а не блокирующее чтение
  package.loaded["ffi/util"] = nil
  local util_nil = { getNonBlockingReadSize = function() return nil end }
  package.loaded["ffi/util"] = util_nil
  t.eq(worker.koreader_sys().has_data(6), false, "nil от ioctl — нет данных")
  package.loaded["ffi/util"] = nil
  t.eq(sys.done(4242), true); t.eq(sys.read_all(6), "x"); sys.kill(4242); t.eq(seen.killed, 4242)
  sys.write(7, "d")
  t.eq(seen.write[1], 7); t.eq(seen.write[2], "d"); t.eq(seen.write[3], true)
end

-- payload дочернего несёт rss_kb: child_main зовёт локальную rss_kb, подмена worker.rss_kb её не достаёт, поэтому
-- /proc/self/status подменяется в самом дочернем (io.open) — на Mac /proc нет, ключа без подмены не было бы
function T.test_child_payload_carries_rss_kb()
  local env = make()
  local r = recorder()
  t.ok(env.runner:start("answer", function()
    io.open = function(path)
      if path ~= "/proc/self/status" then return nil end
      return { read = function() return "Name:\tkoreader\nVmRSS:\t   12345 kB\n" end, close = function() end }
    end
    return { a = 1 }
  end, { timeout_s = 5, on_done = r.fn }))
  env.loop.run(1)
  t.eq(r.calls, 1)
  t.eq(r.err, nil)
  t.eq(r.payload.a, 1)
  t.eq(r.payload.rss_kb, 12345, "RSS дочернего дописан в payload")
end

-- RSS процесса для журнала sync: число КБ там, где есть /proc (Linux), иначе nil
function T.test_rss_kb_is_exported_number_or_nil()
  t.eq(type(worker.rss_kb), "function")
  local v = worker.rss_kb()
  local f = io.open("/proc/self/status", "r")
  if f then
    f:close()
    t.ok(type(v) == "number" and v > 0, tostring(v))
  else
    t.eq(v, nil)
  end
end

t.run(T)
