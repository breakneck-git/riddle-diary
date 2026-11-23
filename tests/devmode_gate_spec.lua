-- Виджет: Diary.devmode и riddle/devtest включает только файл /mnt/us/riddle/devmode. Файл watch (его ставит любой
-- деплой ради слежения за рестартом) — не включает. Виджет грузится заново на поддельной ФС (/mnt/us на Mac нет).
local t = require("t")

local nop = function() end
local bb_stub = { fill = nop, free = nop }

local function stub(name, mod) package.preload[name] = function() return mod end end

stub("ffi/blitbuffer", { COLOR_WHITE = 0xFF, COLOR_BLACK = 0, TYPE_BB8 = 1, new = function() return bb_stub end })
stub("device", { isKindle = function() return false end, screen = {} })
stub("ffi/freetype", {})
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/rendertext", { getGlyph = nop })
stub("ui/uimanager", { scheduleIn = nop, unschedule = nop, nextTick = nop })
stub("ui/widget/widget", { extend = function(_, o) return o end })
stub("logger", { info = nop, warn = nop, err = nop, dbg = nop })
stub("ui/time", { monotonic = function() return 0 end, to_ms = function(x) return x * 1000 end,
                  to_us = function(x) return x * 1e6 end, to_s = function(x) return x end })
stub("libs/libkoreader-lfs", { attributes = nop, dir = nop })

local RIDDLE = "/mnt/us/riddle/"

-- виджет заново с набором флаг-файлов -> Diary, сколько раз подключён и установлен devtest
local function load_widget(files)
  local installs = 0
  package.loaded["riddle.devtest"] = nil
  package.preload["riddle.devtest"] = function() return { install = function() installs = installs + 1 end } end
  local fio = setmetatable({
    open = function(path, mode)
      if path:find("^/mnt/us/") then
        if (mode or "r"):find("r") and files[path] then return { close = nop } end
        return nil, path .. ": No such file"
      end
      return io.open(path, mode)
    end,
  }, { __index = io })
  local chunk = assert(loadfile("plugin/riddlediary.koplugin/riddle_diarywidget.lua"))
  setfenv(chunk, setmetatable({ io = fio }, { __index = _G }))
  local Diary = chunk("riddle_diarywidget")
  local loaded = package.loaded["riddle.devtest"] ~= nil
  package.preload["riddle.devtest"] = nil
  package.loaded["riddle.devtest"] = nil
  return Diary, installs, loaded
end

local T = {}

function T.test_devmode_file_enables_devmode_and_devtest()
  local Diary, installs, loaded = load_widget({ [RIDDLE .. "devmode"] = true })
  t.eq(Diary.devmode, true)
  t.ok(loaded, "devtest подключён")
  t.eq(installs, 1, "devtest установлен")
end

function T.test_watch_alone_does_not_enable_devmode()
  local Diary, installs, loaded = load_widget({ [RIDDLE .. "watch"] = true })
  t.eq(Diary.devmode, nil, "watch без devmode")
  t.ok(not loaded, "devtest не подключён")
  t.eq(installs, 0, "devtest не установлен")
end

function T.test_no_flag_files_no_devmode()
  local Diary, installs, loaded = load_widget({})
  t.eq(Diary.devmode, nil)
  t.ok(not loaded, "devtest не подключён")
  t.eq(installs, 0)
end

t.run(T)
