-- Дочерний процесс KOReader для медленной работы (ответ модели, синхронизация): цикл интерфейса не
-- ждёт сеть. Один дочерний за раз (RAM Kindle); "answer" вытесняет идущую фоновую задачу ("sync", "summary").
-- Среда (fork/pipe, планировщик, часы) приходит снаружи (sys, schedule, clock), поэтому модуль
-- тестируется на Mac настоящими fork/pipe (tests/subprocess_shim.lua).
-- Дочерний не трогает соединения SQLite родителя: fn получает только то, что замкнуло само.
-- Результат fn (таблица) идёт по pipe одним JSON-конвертом: { ok = payload } | { err = msg } |
-- { too_big = true }; родитель читает его опросом каждые POLL_S, дедлайн timeout_s — kill.

local json = require("dkjson")

local worker = {}

worker.MAX_PAYLOAD = 32768
worker.POLL_S = 0.2

-- RSS дочернего в КБ (Linux); на Mac /proc нет — nil
local function rss_kb()
  local f = io.open("/proc/self/status", "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return tonumber(s:match("VmRSS:%s*(%d+)"))
end
worker.rss_kb = rss_kb

-- выполняется в дочернем: fn -> конверт -> pipe. Любой сбой — тоже конверт, чтобы родитель отличал
-- ошибку fn от смерти процесса без вывода ("crashed")
local function child_main(fn, write, wfd)
  -- сборка мусора в дочернем пометила бы каждый объект унаследованной кучи и тем скопировала бы её
  -- страницы (copy-on-write) — ещё одна куча KOReader в RAM; дочерний живёт секунды, мусор не важен
  collectgarbage("stop")
  local ok, res = pcall(fn)
  local env
  if not ok then
    env = { err = tostring(res) }
  elseif type(res) ~= "table" then
    env = { err = "result is " .. type(res) }
  else
    res.rss_kb = rss_kb()
    env = { ok = res }
  end
  local enc_ok, s = pcall(json.encode, env)
  if not enc_ok or type(s) ~= "string" then
    s = json.encode({ err = "encode: " .. tostring(s) })
  elseif #s > worker.MAX_PAYLOAD then
    s = json.encode({ too_big = true })
  end
  write(wfd, s)
end

-- конверт из pipe -> payload | nil, err
local function decode(s)
  if s == "" then return nil, "crashed" end
  if #s > worker.MAX_PAYLOAD + 64 then return nil, "payload" end
  local ok, env = pcall(json.decode, s)
  if not ok or type(env) ~= "table" then return nil, "decode" end
  if env.too_big then return nil, "payload" end
  if env.err ~= nil then return nil, "child: " .. tostring(env.err) end
  if type(env.ok) ~= "table" then return nil, "decode" end
  return env.ok
end

local Runner = {}
Runner.__index = Runner

-- o: sys (см. koreader_sys), schedule(s, fn), clock() -> s, log(msg) (необязательно)
function worker.new(o)
  return setmetatable({ sys = o.sys, schedule = o.schedule, clock = o.clock,
                        log = o.log or function() end, cur = nil }, Runner)
end

function Runner:busy()
  return self.cur and self.cur.kind or nil
end

-- дожать процесс до waitpid (без зомби) и закрыть его конец pipe. kill повторяется на каждом шаге:
-- setpgid дочернего мог ещё не случиться к первому kill(-pid). fd читаем только после смерти
-- процесса — тогда read_all не блокирует (EOF)
function Runner:_reap(pid, fd, kill)
  local sys = self.sys
  local function step()
    if sys.done(pid) then
      if fd then sys.read_all(fd) end
      return
    end
    if kill then sys.kill(pid) end
    self.schedule(worker.POLL_S, step)
  end
  if kill then sys.kill(pid) end
  step()
end

function Runner:_finish(job, payload, err)
  local ok, e = pcall(job.on_done, payload, err)
  if not ok then self.log("riddle: worker " .. job.kind .. " on_done failed: " .. tostring(e)) end
end

function Runner:_poll(job)
  if self.cur ~= job then return end -- отменён или вытеснен
  local sys = self.sys
  -- сначала done, потом has_data: если процесс уже вышел, всё, что он написал, уже в pipe
  local exited = sys.done(job.pid)
  if exited or sys.has_data(job.fd) then
    -- вышел: писателей нет, read_all не блокирует (пусто — "crashed"). Жив, но ответ уже написал:
    -- дочитываем до EOF и убиваем — runner свободен, второго живого дочернего быть не должно
    local s = sys.read_all(job.fd)
    self.cur = nil
    if not exited then self:_reap(job.pid, nil, true) end
    local payload, err = decode(s)
    self:_finish(job, payload, err)
  elseif self.clock() >= job.deadline then
    self.cur = nil
    self:_reap(job.pid, job.fd, true)
    self.log(string.format("riddle: worker %s killed after %.1f s", job.kind, self.clock() - job.t0))
    self:_finish(job, nil, "timeout")
  else
    self.schedule(worker.POLL_S, function() self:_poll(job) end)
  end
end

-- kind: "answer" | "sync" | "summary"; fn() выполняется в дочернем и возвращает таблицу;
-- opts: timeout_s, on_done(payload | nil, err). -> true | nil, err ("busy", "spawn: …")
function Runner:start(kind, fn, opts)
  local cur = self.cur
  if cur then
    if not (kind == "answer" and cur.kind ~= "answer") then return nil, "busy" end
    self.cur = nil
    self:_reap(cur.pid, cur.fd, true)
    self.log("riddle: worker " .. cur.kind .. " preempted by answer")
    self:_finish(cur, nil, "cancelled")
  end
  local sys = self.sys
  local pid, fd = sys.spawn(function(wfd) child_main(fn, sys.write, wfd) end)
  if not pid then return nil, "spawn: " .. tostring(fd) end
  local t0 = self.clock()
  local job = { kind = kind, pid = pid, fd = fd, t0 = t0, deadline = t0 + opts.timeout_s, on_done = opts.on_done }
  self.cur = job
  self.schedule(worker.POLL_S, function() self:_poll(job) end)
  return true
end

-- убить текущий (только этого вида, если kind задан); его on_done не зовётся
function Runner:cancel(kind)
  local cur = self.cur
  if not cur or (kind and cur.kind ~= kind) then return end
  self.cur = nil
  self:_reap(cur.pid, cur.fd, true)
  self.log("riddle: worker " .. cur.kind .. " cancelled")
end

-- sys поверх KOReader ffi/util (v2025.08)
function worker.koreader_sys()
  local util = require("ffi/util")
  return {
    spawn = function(child_fn)
      -- дочерний KOReader выходит os.exit(0), т.е. exit() с выталкиванием буферов stdio: без flush
      -- недописанный буфер родителя попал бы в crash.log второй раз
      io.stdout:flush()
      io.stderr:flush()
      return util.runInSubProcess(function(_, wfd) child_fn(wfd) end, true)
    end,
    -- nil — ioctl не сработал: считаем «нет данных», ответ заберём, когда дочерний выйдет
    has_data = function(fd) return (util.getNonBlockingReadSize(fd) or 0) > 0 end,
    done = function(pid) return util.isSubProcessDone(pid) end,
    read_all = function(fd) return util.readAllFromFD(fd) end,
    kill = function(pid) util.terminateSubProcess(pid) end,
    write = function(fd, data) return util.writeToFD(fd, data, true) end,
  }
end

return worker
