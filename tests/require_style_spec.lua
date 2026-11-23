-- Модули плагина подключаются в одном стиле — require("riddle.x"): package.loaded ключуется строкой
-- имени, и "riddle/x" рядом с "riddle.x" грузит модуль второй раз (вторая копия со своим состоянием),
-- а подмена в тесте через package.loaded["riddle.x"] не доходит до кода, который просит "riddle/x".
local t = require("t")

local T = {}

local function read(path)
  local f = assert(io.open(path, "rb"), path)
  local s = f:read("*a")
  f:close()
  return s
end

local function sources(dir)
  local out = {}
  local p = assert(io.popen("find " .. dir .. " -name '*.lua' -not -path '*/vendor/*' | sort"))
  for path in p:lines() do out[#out + 1] = path end
  p:close()
  return out
end

-- имя модуля riddle через «/» в любой строке: require("riddle/x"), require "riddle/x",
-- pcall(require, "riddle/x"), package.loaded["riddle/x"], список имён для сброса { "riddle/x" }.
-- Пути данных («/mnt/us/riddle/») не ловятся: перед riddle там «/», а не кавычка
local PATTERN = '["\']riddle/'

local function slash_uses(paths)
  local hits = {}
  for _, path in ipairs(paths) do
    local n = 0
    for line in (read(path) .. "\n"):gmatch("(.-)\n") do
      n = n + 1
      if line:find(PATTERN) then hits[#hits + 1] = path .. ":" .. n .. ": " .. line:match("^%s*(.-)%s*$") end
    end
  end
  return hits
end

function T.test_plugin_requires_riddle_with_dots()
  local paths = sources("plugin/riddlediary.koplugin")
  t.ok(#paths > 5, "исходники плагина найдены")
  local hits = slash_uses(paths)
  t.ok(#hits == 0, "require модулей riddle через «/»:\n" .. table.concat(hits, "\n"))
end

-- тесты подменяют модули через package.loaded["riddle.x"]: тот же стиль, иначе подмена мимо
function T.test_tests_require_riddle_with_dots()
  local paths = {}
  for _, path in ipairs(sources("tests")) do
    if path ~= "tests/require_style_spec.lua" then paths[#paths + 1] = path end -- примеры в самом гарде
  end
  t.ok(#paths > 5, "тесты найдены")
  local hits = slash_uses(paths)
  t.ok(#hits == 0, "require модулей riddle через «/»:\n" .. table.concat(hits, "\n"))
end

-- сам гард ловит все формы
function T.test_guard_catches_slash_forms()
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "wb"))
  f:write('local a = require("riddle/x")\nlocal b = require "riddle/y"\nlocal ok, c = pcall(require, "riddle/z")\n' ..
    'package.loaded["riddle/w"] = nil\nfor _, m in ipairs({ "ssl", "riddle/v" }) do end\n' ..
    'local d = require("riddle.ok")\nlocal dir = "/mnt/us/riddle/"\n')
  f:close()
  local hits = slash_uses({ tmp })
  os.remove(tmp)
  t.eq(#hits, 5, table.concat(hits, "\n"))
end

t.run(T)
