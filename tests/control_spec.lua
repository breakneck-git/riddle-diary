-- Знаки управления Kindle (спека 2026-11-28-control-signs): riddle.control — знак -> команда над источниками
-- устройства (dev), итог — текст на месте страницы. Чистые функции; источники — поддельные.
local t = require("t")
local control = require("riddle.control")
local texts = require("riddle.texts")

local T = {}

-- подсветка с журналом установок: уровень get, шкала max
local function light(level, max)
  local l = { level = level, max = max or 25, sets = {} }
  l.get = function() return l.level end
  l.set = function(n) l.sets[#l.sets + 1] = n; l.level = n end
  return l
end

-- выключенная подсветка + ↑ — первый шаг; дальше шагами, не выше шкалы
function T.test_light_up_from_off_first_step()
  t.eq(control.light(0, 25, 1), 5)
  t.eq(control.light(5, 25, 1), 10)
  t.eq(control.light(23, 25, 1), 25)
  t.eq(control.light(25, 25, 1), 25)
end

-- ↓ — шагами до выключения, не ниже нуля
function T.test_light_down_to_off()
  t.eq(control.light(10, 25, -1), 5)
  t.eq(control.light(3, 25, -1), 0)
  t.eq(control.light(0, 25, -1), 0)
end

function T.test_run_up_sets_and_reports()
  local l = light(5)
  local text, note = control.run("up", { light = l })
  t.eq(text, "Подсветка 10 из 25")
  t.eq(#l.sets, 1)
  t.eq(l.sets[1], 10)
  t.ok(note:find("light 5->10", 1, true), note)
end

-- на максимуме ↑ ничего не меняет, но итог виден
function T.test_run_up_at_max_still_visible()
  t.eq((control.run("up", { light = light(25) })), "Подсветка 25 из 25")
end

-- шкала — из источника, не 25 зашитым
function T.test_run_reports_source_scale()
  t.eq((control.run("up", { light = light(0, 10) })), "Подсветка 5 из 10")
end

function T.test_run_down_off_text()
  local l = light(3)
  t.eq((control.run("down", { light = l })), "Подсветка выключена")
  t.eq(l.sets[1], 0)
  t.eq((control.run("down", { light = l })), "Подсветка выключена", "уже выключена — итог тот же")
end

-- источник упал: дневник жив, итог виден, причина — в заметке для лога
function T.test_run_source_error_visible()
  local l = light(5)
  l.get = function() error("lipc gone") end
  local text, note = control.run("up", { light = l })
  t.eq(text, texts.control_failed)
  t.eq(text, "Не вышло.")
  t.ok(note:find("^error"), note)
  t.ok(note:find("lipc gone", 1, true), note)
end

-- у устройства нет подсветки
function T.test_run_missing_source()
  local text, note = control.run("up", {})
  t.eq(text, texts.control_failed)
  t.eq(note, "no source")
end

-- ночной режим: переключение раз на знак, итог — по состоянию после переключения
function T.test_moon_toggles_night()
  local n = { on = false, toggles = 0 }
  n.get = function() return n.on end
  n.toggle = function() n.toggles = n.toggles + 1; n.on = not n.on end
  local text, note = control.run("moon", { night = n })
  t.eq(text, "Ночной режим включён")
  t.eq(n.toggles, 1)
  t.eq(note, "night on")
  t.eq((control.run("moon", { night = n })), "Ночной режим выключен")
  t.eq(n.toggles, 2)
end

-- Wi‑Fi: знак ставит обратное состояние; итог — цель (подключение идёт само, асинхронно)
function T.test_bolt_flips_wifi()
  local w = { on = true, sets = {} }
  w.get = function() return w.on end
  w.set = function(v) w.sets[#w.sets + 1] = v end
  local text, note = control.run("bolt", { wifi = w })
  t.eq(text, "Wi‑Fi выключен")
  t.eq(w.sets[1], false)
  t.eq(note, "wifi on->off")
  w.on = false
  t.eq((control.run("bolt", { wifi = w })), "Wi‑Fi включён")
  t.eq(w.sets[2], true)
end

-- квадрат: полное обновление, текста нет — его итог виден сам
function T.test_square_refreshes_without_text()
  local n = 0
  local text, note = control.run("square", { refresh = function() n = n + 1 end })
  t.eq(text, nil)
  t.eq(note, "refresh")
  t.eq(n, 1)
end

-- у устройства нет источника знака — итог «Не вышло.», не тишина
function T.test_missing_sources_each_command()
  for _, name in ipairs({ "moon", "bolt", "square" }) do
    local text, note = control.run(name, {})
    t.eq(text, texts.control_failed, name)
    t.eq(note, "no source", name)
  end
end

t.run(T)
