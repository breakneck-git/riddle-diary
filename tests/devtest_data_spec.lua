-- devtest для живой проверки просьб о данных (spec §7): feed=N set=<имя> берёт образцы из devsamples/<имя>/ (без set —
-- как раньше, из devsamples/), а в dev-лог на каждый ответ закрытой печати идёт «riddle: needs_data=<true|false>» —
-- без текста записи и ответа. Контроллер в тесте настоящий: лог вешается на его разбор ответа, сценарий модели — свой.
require("sqlite_shim") -- настоящая память контроллера
local t = require("t")
local Memory = require("riddle.memory")
local controller = require("riddle.controller")
local texts = require("riddle.texts")
local stand = require("seal_stand")

local log = {}
local function stub(name, mod) package.preload[name] = function() return mod end end
stub("device", { screen = {} })
stub("ui/uimanager", {})
stub("logger", {
  info = function(...) log[#log + 1] = table.concat({ ... }, " ") end,
  warn = function(...) log[#log + 1] = "WARN " .. table.concat({ ... }, " ") end,
  err = function(...) log[#log + 1] = "ERROR " .. table.concat({ ... }, " ") end,
})
stub("ui/time", { monotonic = function() return 0 end, to_ms = function(x) return x end })
stub("libs/libkoreader-lfs", {
  dir = function(path)
    local list = {}
    for name in io.popen('ls "' .. path .. '" 2>/dev/null'):lines() do list[#list + 1] = name end
    local i = 0
    return function() i = i + 1; return list[i] end
  end,
  attributes = function() return nil end,
})

local devtest = require("riddle.devtest")

local function lines(prefix)
  local out = {}
  for _, l in ipairs(log) do
    if l:find(prefix, 1, true) then out[#out + 1] = l end
  end
  return out
end

local function put(path, bytes)
  local f = assert(io.open(path, "wb"))
  f:write(bytes)
  f:close()
end

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- каталог устройства: devsamples/ с образцом в корне и набором data/ из двух образцов
local DIR = os.tmpname()
os.remove(DIR)
os.execute('mkdir -p "' .. DIR .. '/devsamples/data" "' .. DIR .. '/samples"')
put(DIR .. "/devsamples/a.png", "ROOT-A")
put(DIR .. "/devsamples/data/01_b.png", "SET-B")
put(DIR .. "/devsamples/data/02_c.png", "SET-C")

local Diary = {}
function Diary:schedule(_, fn) self.queue[#self.queue + 1] = fn end
devtest.install(Diary, { rssKB = function() return 0 end, RIDDLE_DIR = DIR })

-- виджет без экрана с поддельным контроллером: on_page запоминает, какой образец до него дошёл
local function feed(s)
  log = {}
  local got = {}
  local ctl = { on_sleep = function() end, deps = {} }
  function ctl:on_page(path) got[#got + 1] = slurp(path); return "ответ" end
  local d = setmetatable({ controller = ctl, queue = {} }, { __index = Diary })
  d:testFeed(s)
  local guard = 0
  while #d.queue > 0 and guard < 50 do
    guard = guard + 1
    table.remove(d.queue, 1)()
  end
  return got
end

local T = {}

-- разбор ключей feed — одно место -------------------------------------------

function T.test_parse_feed_absent()
  t.eq(devtest.parseFeed("cycles=3 exit=1"), nil)
end

function T.test_parse_feed_defaults()
  local o = devtest.parseFeed("feed=4")
  t.eq(o.n, 4)
  t.eq(o.gap, 8)
  t.eq(o.full, false)
  t.eq(o.new, false)
  t.eq(o.set, nil, "без set — корень devsamples")
end

function T.test_parse_feed_all_keys()
  local o = devtest.parseFeed("feed=9 gap=60 full=1 new=1 set=data")
  t.eq(o.n, 9)
  t.eq(o.gap, 60)
  t.eq(o.full, true)
  t.eq(o.new, true)
  t.eq(o.set, "data")
end

-- имя набора — только буквы, цифры, «_» и «-»: путь вне devsamples (../, /) не собирается
function T.test_parse_feed_bad_set()
  for _, bad in ipairs({ "set=../x", "set=a/b", "set=" }) do
    local o = devtest.parseFeed("feed=2 " .. bad)
    t.ok(o.bad_set, "отказ на «" .. bad .. "»")
    t.eq(o.set, nil, bad)
  end
end

-- подача образцов -----------------------------------------------------------

function T.test_feed_with_set_takes_set_samples_in_order()
  local got = feed("feed=3 gap=1 set=data")
  t.eq(#got, 3)
  t.eq(got[1], "SET-B")
  t.eq(got[2], "SET-C")
  t.eq(got[3], "SET-B", "по кругу внутри набора")
  t.eq(#lines("set=data"), 1, "набор назван в строке FEED start:\n" .. table.concat(log, "\n"))
end

function T.test_feed_without_set_unchanged()
  local got = feed("feed=2 gap=1")
  t.eq(#got, 2)
  t.eq(got[1], "ROOT-A", "только PNG корня, каталог набора не образец")
  t.eq(got[2], "ROOT-A")
end

function T.test_feed_bad_set_does_not_start()
  local got = feed("feed=2 gap=1 set=../x")
  t.eq(#got, 0, "ни одного образца")
  t.eq(#lines("WARN riddle: FEED bad set"), 1, table.concat(log, "\n"))
end

function T.test_feed_missing_set_feeds_nothing()
  local got = feed("feed=2 gap=1 set=nope")
  t.eq(#got, 0)
  t.eq(#lines("riddle: FEED no PNG"), 1, table.concat(log, "\n"))
end

-- needs_data в dev-лог --------------------------------------------------------

local PNG = "/mnt/us/riddle/samples/1.png"
local WHOSE = "Том Реддл из «Методов рационального мышления»"
local READ = "МЕТКА-ЗАПИСЬ что я писал вчера"
local REPLY = "МЕТКА-ОТВЕТ сними печать"

local function ctl(seal_cfg)
  local env = { now = 1000, script = {} }
  local memory = Memory.open(os.tmpname())
  env.ctrl = controller.new{
    cfg = { whose = WHOSE, seal = seal_cfg }, -- «Методов»: встроенная персона, генерации нет
    memory = memory,
    llm_call = function() return assert(table.remove(env.script, 1), "сценарий кончился") end,
    read_file = function() return "PNGBYTES" end,
    b64 = function(b) return "B64:" .. b end,
    remove = function() end,
    now = function() return env.now end,
    lore_path = "/mnt/us/riddle/lore.md",
    file_mtime = function() return nil end,
    random = function() return 1 end,
    log = function(msg) log[#log + 1] = msg end,
  }
  function env:page(needs, at)
    env.now = at or env.now
    env.script[#env.script + 1] = { read = READ, reply = REPLY, needs_data = needs }
    log = {}
    local text = env.ctrl:on_page(PNG)
    return text, log
  end
  return env
end

function T.test_closed_seal_logs_needs_data()
  local env = ctl(stand.key())
  t.ok(not env.ctrl.seal_open, "печать закрыта")
  local text, l = env:page(true)
  t.eq(text, REPLY, table.concat(l, "\n"))
  t.eq(#lines("riddle: needs_data=true"), 1, table.concat(l, "\n"))
  env:page(false)
  t.eq(#lines("riddle: needs_data=false"), 1, table.concat(log, "\n"))
  env:page(nil)
  t.eq(#lines("riddle: needs_data=false"), 1, "нет поля — false:\n" .. table.concat(log, "\n"))
end

function T.test_needs_data_line_has_no_entry_or_reply_text()
  local env = ctl(stand.key())
  env:page(true)
  local got = lines("needs_data")
  t.eq(#got, 1, table.concat(log, "\n"))
  t.eq(got[1], "riddle: needs_data=true", "строка — только флаг")
  t.eq(#lines("МЕТКА"), 0, "ни записи, ни ответа в логе:\n" .. table.concat(log, "\n"))
end

function T.test_open_seal_logs_nothing()
  local env = ctl(stand.none())
  t.ok(env.ctrl.seal_open, "печати нет — данные открыты")
  env:page(true)
  t.eq(#lines("needs_data"), 0, table.concat(log, "\n"))
end

-- лог не меняет разбора: пятая просьба за 10 минут — по-прежнему с фразой texts.key_needed, строка лога одна
function T.test_log_keeps_key_hint()
  local env = ctl(stand.key())
  for i = 0, 3 do t.eq(env:page(true, 1000 + i * 60), REPLY) end
  local text = env:page(true, 1300)
  t.eq(text, REPLY .. " " .. texts.key_needed)
  t.eq(#lines("riddle: needs_data=true"), 1, table.concat(log, "\n"))
end

-- install дважды (повторный запуск харнеса в процессе) — строка всё равно одна
function T.test_install_twice_logs_once()
  devtest.install({}, { rssKB = function() return 0 end, RIDDLE_DIR = DIR })
  local env = ctl(stand.key())
  env:page(true)
  t.eq(#lines("riddle: needs_data=true"), 1, table.concat(log, "\n"))
end

t.run(T)
