-- devtest feed new=1: перед первым образцом начинается новая сессия разговора (как после паузы > 4 ч),
-- история прошлой сессии остаётся в базе, но не попадает в recent; без new=1 подача идёт в текущую сессию.
require("sqlite_shim")
local t = require("t")

local function stub(name, mod) package.preload[name] = function() return mod end end
stub("device", { screen = {} })
stub("ui/uimanager", {})
stub("logger", { info = function() end, warn = function() end, err = function() end })
stub("ui/time", { monotonic = function() return 0 end, to_ms = function(x) return x end })
stub("libs/libkoreader-lfs", {
  dir = function(path)
    local list = {}
    for name in io.popen('ls "' .. path .. '"'):lines() do list[#list + 1] = name end
    local i = 0
    return function() i = i + 1; return list[i] end
  end,
  attributes = function() return nil end,
})

local Memory = require("riddle.memory")
local devtest = require("riddle.devtest")

local NOW = 1000000
local DIR = os.tmpname()
os.remove(DIR)
os.execute('mkdir -p "' .. DIR .. '/devsamples" "' .. DIR .. '/samples"')
local f = io.open(DIR .. "/devsamples/a.png", "wb"); f:write("png"); f:close()

local Diary = {}
function Diary:schedule(_, fn) self.queue[#self.queue + 1] = fn end
devtest.install(Diary, { rssKB = function() return 0 end, RIDDLE_DIR = DIR })

-- база с прошлой сессией (минуту назад — внутри окна 4 ч); on_page пишет реплику в сессию на момент NOW
local function setup()
  local path = os.tmpname()
  local memory = Memory.open(path)
  local old = memory:session(NOW - 60)
  memory:add(old, "owner", "СТАРЫЙ-ВОПРОС", NOW - 60)
  local sids = {}
  local ctl = {
    deps = { memory = memory, now = function() return NOW end },
    on_sleep = function() end,
    on_page = function(self)
      local sid = self.deps.memory:session(self.deps.now())
      sids[#sids + 1] = sid
      self.deps.memory:add(sid, "owner", "НОВЫЙ-" .. #sids, NOW)
      return "ответ"
    end,
  }
  local d = setmetatable({ controller = ctl, queue = {} }, { __index = Diary })
  return d, memory, old, sids, path
end

local function drain(d)
  local guard = 0
  while #d.queue > 0 and guard < 50 do
    guard = guard + 1
    table.remove(d.queue, 1)()
  end
end

local T = {}

function T.test_new_session_before_first_sample()
  local d, memory, old, sids, path = setup()
  d:testFeed("feed=2 gap=1 new=1")
  drain(d)
  t.eq(#sids, 2, "оба образца поданы")
  t.ok(sids[1] ~= old, "первый образец — в новой сессии")
  t.eq(sids[2], sids[1], "второй — в той же новой, не в ещё одной")
  for _, r in ipairs(memory:recent(sids[1], 20)) do
    t.ok(not tostring(r.text):find("СТАРЫЙ", 1, true), "старая реплика не в recent")
  end
  t.eq(#memory:entries(old), 1, "история прошлой сессии цела")
  os.remove(path)
end

function T.test_without_new_continues_current_session()
  local d, _, old, sids, path = setup()
  d:testFeed("feed=2 gap=1")
  drain(d)
  t.eq(sids[1], old, "без new=1 — текущая сессия")
  t.eq(sids[2], old)
  os.remove(path)
end

t.run(T)
