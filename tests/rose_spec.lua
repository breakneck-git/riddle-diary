-- Роза ветров пальцем открывает и закрывает карту (план карты, срез 1; решения, п.1): круг и две черты накрест.
-- Чистая функция rose.detect(strokes) -> ok, score; фикстуры — tests/fixtures/rose_strokes.lua.
local t = require("t")
local rose = require("riddle.rose")
local F = require("fixtures.rose_strokes")

local T = {}

function T.test_detect_roses()
  for _, name in ipairs(F.ROSES) do
    local ok, score = rose.detect(F[name])
    t.eq(type(score), "number", name .. ": score — число")
    t.ok(ok == true, name .. ": роза не узнана, score=" .. tostring(score))
  end
end

-- живые розы владельца (Kindle, 2026-11-16): каждая — роза; на 5d12171 узнавались 3 из 12
function T.test_detect_owner_roses()
  local O = require("fixtures.rose_owner")
  t.eq(#O.ROSES, 12)
  for _, name in ipairs(O.ROSES) do
    local ok, score = rose.detect(O[name])
    t.ok(ok == true, name .. ": роза владельца не узнана, score=" .. tostring(score))
  end
end

function T.test_detect_non_roses()
  for _, name in ipairs(F.NON_ROSES) do
    local ok, score = rose.detect(F[name])
    t.eq(type(score), "number", name .. ": score — число")
    t.ok(ok == false, name .. ": не роза узнана розой, score=" .. tostring(score))
  end
end

local function reversed_points(s)
  local p, q = s.p, {}
  for i = #p - 1, 1, -2 do
    q[#q + 1] = p[i]
    q[#q + 1] = p[i + 1]
  end
  return { p = q }
end

-- порядок штрихов и направление каждого не важны: все перестановки, каждый штрих задом наперёд
function T.test_stroke_order_irrelevant()
  local function perms(list, k, out)
    k = k or 1
    if k > #list then
      local copy = {}
      for i, s in ipairs(list) do copy[i] = s end
      out[#out + 1] = copy
      return out
    end
    for i = k, #list do
      list[k], list[i] = list[i], list[k]
      perms(list, k + 1, out)
      list[k], list[i] = list[i], list[k]
    end
    return out
  end
  for _, name in ipairs(F.ROSES) do
    local strokes = {}
    for i, s in ipairs(F[name]) do strokes[i] = s end
    for n, order in ipairs(perms(strokes, 1, {})) do
      t.ok(rose.detect(order), name .. ": перестановка " .. n)
      local back = {}
      for i, s in ipairs(order) do back[i] = reversed_points(s) end
      t.ok(rose.detect(back), name .. ": перестановка " .. n .. ", штрихи задом наперёд")
    end
  end
end

-- каждый порог держит своя не-роза: ослабь порог — она становится розой (ревью ui: SWEEP 280 -> 200 и BEND 0.12 ->
-- 0.5 проходили все тесты). Сам порог при этом остаётся отклоняющим: без мутации она не роза
function T.test_each_threshold_held()
  local held = {
    { "SWEEP", 280, "undershoot_75_cross" }, { "SWEEP", 200, "c_open_120_plus" }, { "BEND", 0.5, "arcs_cross" },
    { "SPREAD", 1.0, "hash_in_circle" }, { "CORNER", 5, "x_in_square" }, { "LAP", 400, "spiral" },
    { "SIZE", 10, "small_circled_plus" }, { "OVAL", 4, "zero_crossed" }, { "LENGTH", 0.1, "small_x_in_big_o" },
    { "ANGLE_MIN", 10, "circle_shallow_x" },
    -- пограничные: единственный непройденный критерий — тот, что в строке; ослабление порога делает их розой
    { "LAP", 270, "spiral_16_cross" }, { "SIZE", 100, "o_120_big_cross" }, { "LENGTH", 0.4, "short_cross_in_circle" },
  }
  for _, h in ipairs(held) do
    local key, loose, name = h[1], h[2], h[3]
    t.ok(not rose.detect(F[name]), name .. ": не роза при rose." .. key .. "=" .. tostring(rose[key]))
    local keep = rose[key]
    rose[key] = loose
    local ok = rose.detect(F[name])
    rose[key] = keep
    t.ok(ok, name .. ": rose." .. key .. "=" .. tostring(loose) .. " должен сделать её розой — порог не держит")
  end
end

-- числа-пороги читаются: константа rose.X, которую в rose.lua никто не читает, — мёртвый порог (ANGLE_MAX был таким)
function T.test_every_constant_is_read()
  local f = assert(io.open("plugin/riddlediary.koplugin/riddle/rose.lua"))
  local src = f:read("*a")
  f:close()
  local n = 0
  for key, v in pairs(rose) do
    if type(v) == "number" and key:match("^[A-Z_]+$") then
      n = n + 1
      local _, uses = src:gsub("rose%." .. key .. "%f[^%w_]", "")
      t.ok(uses >= 2, "rose." .. key .. " не читается нигде, кроме определения")
    end
  end
  t.ok(n >= 16, "констант найдено " .. n)
end

-- разбор лучшего кандидата: каждый критерий — доля своего порога (≤ 1 — пройден), наихудший равен score
function T.test_detect_parts()
  local keys = rose.CRITERIA
  t.eq(#keys, 10, "критериев: 6 круга, 4 черт")
  for _, name in ipairs(F.ROSES) do
    local _, score, parts = rose.detect(F[name])
    t.eq(type(parts), "table", name .. ": разбор есть")
    local worst = 0
    for _, k in ipairs(keys) do
      t.eq(type(parts[k]), "number", name .. ": " .. k)
      t.ok(parts[k] <= 1, name .. ": " .. k .. "=" .. tostring(parts[k]))
      worst = math.max(worst, parts[k])
    end
    t.ok(math.abs(worst - score) < 1e-9, name .. ": наихудший критерий = score")
  end
  -- круг без черт: разбор круга есть, черт — нет
  local _, _, parts = rose.detect(F.circle_only)
  t.eq(type(parts), "table", "circle_only: разбор круга")
  t.eq(type(parts.spread), "number")
  t.eq(parts.tilt, nil)
  t.eq((select(3, rose.detect({}))), nil, "пусто — разбора нет")
end

-- пустая страница, точка, штрих из одной точки — не роза и не падение
function T.test_degenerate_input()
  t.eq((rose.detect({})), false)
  t.eq((rose.detect({ { p = { 10, 10 } } })), false)
  t.eq((rose.detect({ { p = { 10, 10 } }, { p = { 10, 10, 10, 10 } }, { p = {} } })), false)
end

-- страница, исписанная словами (десятки штрихов): не роза, и ответ сразу — перебор кандидатов квадратичен по числу
-- штрихов, на PW2 400 штрихов шли бы секунды в цикле интерфейса. Больше штрихов, чем у розы бывает, — сразу false
local function many(n)
  local s = {}
  for i = 1, n do
    local p = {}
    for k = 0, 29 do
      p[#p + 1] = 100 + (i % 20) * 30 + k
      p[#p + 1] = 100 + math.floor(i / 20) * 30 + (k % 5)
    end
    s[i] = { p = p }
  end
  return s
end

function T.test_many_strokes_not_rose_at_once()
  t.eq((rose.detect(many(50))), false, "50 штрихов")
  local t0 = os.clock()
  t.eq((rose.detect(many(400))), false, "400 штрихов")
  local dt = os.clock() - t0
  t.ok(dt < 0.05, string.format("400 штрихов разобраны за %.3f с", dt))
end

t.run(T)
