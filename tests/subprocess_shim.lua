-- Настоящие fork/pipe через FFI на Mac — тот же контракт sys, что worker.koreader_sys() поверх
-- KOReader ffi/util (runInSubProcess, isSubProcessDone, terminateSubProcess, getNonBlockingReadSize,
-- readAllFromFD, writeToFD). Отличие от KOReader одно: дочерний выходит _exit(0), а родитель делает
-- io.stdout:flush() до fork — иначе буфер вывода теста печатался бы дважды.
local ffi = require("ffi")

ffi.cdef([[
int pipe(int fildes[2]);
int fork(void);
int close(int fd);
void _exit(int status);
int setpgid(int pid, int pgid);
int waitpid(int pid, int *stat_loc, int options);
int kill(int pid, int sig);
int ioctl(int fd, unsigned long request, ...);
long read(int fd, void *buf, size_t nbyte);
long write(int fd, const void *buf, size_t nbyte);
int usleep(unsigned int useconds);
int fcntl(int fd, int cmd, ...);
struct timeval { long tv_sec; int tv_usec; };
int gettimeofday(struct timeval *tp, void *tzp);
]])

local C = ffi.C
local WNOHANG = 1
local FIONREAD = 0x4004667f -- macOS: _IOR('f', 127, int)

local shim = {}

function shim.sys()
  local sys = {}

  function sys.spawn(child_fn)
    local p = ffi.new("int[2]", { -1, -1 })
    if C.pipe(p) ~= 0 then return false, "pipe failed" end
    io.stdout:flush()
    io.stderr:flush()
    local pid = C.fork()
    if pid == 0 then
      C.setpgid(0, 0)
      C.close(p[0])
      pcall(child_fn, p[1])
      C._exit(0)
    end
    C.close(p[1])
    if pid < 0 then
      C.close(p[0])
      return false, "fork failed"
    end
    return pid, p[0]
  end

  function sys.has_data(fd)
    local n = ffi.new("int[1]")
    if C.ioctl(fd, FIONREAD, n) ~= 0 then return true end
    return n[0] ~= 0
  end

  function sys.done(pid)
    local st = ffi.new("int[1]")
    local ret = C.waitpid(pid, st, WNOHANG)
    return ret == pid or ret == -1
  end

  function sys.read_all(fd)
    local buf = ffi.new("char[8192]")
    local out = {}
    while true do
      local n = tonumber(C.read(fd, buf, 8192))
      if n <= 0 then break end
      out[#out + 1] = ffi.string(buf, n)
    end
    C.close(fd)
    return table.concat(out)
  end

  function sys.kill(pid)
    if not sys.done(pid) then C.kill(-pid, 9) end
  end

  function sys.write(fd, data)
    local ok = C.write(fd, data, #data) == #data
    C.close(fd)
    return ok
  end

  return sys
end

-- настоящие часы и планировщик: schedule кладёт задачу, run(s) спит до ближайшей и выполняет
function shim.clock()
  local tv = ffi.new("struct timeval")
  C.gettimeofday(tv, nil)
  return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
end

function shim.loop()
  local L = { tasks = {} }
  function L.schedule(s, fn) L.tasks[#L.tasks + 1] = { at = shim.clock() + s, fn = fn } end
  function L.run(s)
    local stop = shim.clock() + s
    while true do
      local k
      for i, task in ipairs(L.tasks) do
        if task.at <= stop and (not k or task.at < L.tasks[k].at) then k = i end
      end
      if not k then break end
      local task = table.remove(L.tasks, k)
      local wait = task.at - shim.clock()
      if wait > 0 then C.usleep(math.floor(wait * 1e6)) end
      task.fn()
    end
    local wait = stop - shim.clock()
    if wait > 0 then C.usleep(math.floor(wait * 1e6)) end
  end
  return L
end

function shim.sleep(s) C.usleep(math.floor(s * 1e6)) end

-- процесс собран (не зомби и не жив): kill(pid, 0) по собранному pid — ошибка ESRCH
function shim.gone(pid) return C.kill(pid, 0) ~= 0 end

-- fd закрыт в этом процессе: fcntl(F_GETFD) по закрытому — ошибка EBADF
function shim.fd_closed(fd) return C.fcntl(fd, 1) == -1 end

return shim
