-- Команды знаков управления (спека 2026-11-28-control-signs): знак (riddle.signs) -> действие устройства и итог —
-- короткий текст на месте страницы (без итога владелец не видит, что знак понят). Чистые функции: устройство —
-- внедрёнными источниками dev (виджет: Diary:controlSources; тесты — поддельные):
--   dev.light = { get = fn() -> уровень, set = fn(уровень), max = верх шкалы }  (уровень 0 — выключена)
--   dev.night = { get = fn() -> включён ли ночной режим, toggle = fn() }
--   dev.wifi = { get = fn() -> включён ли Wi‑Fi, set = fn(вкл) }
--   dev.refresh = fn()  — полное обновление экрана
-- Источника нет или он бросил ошибку — итог «Не вышло.», причина — в заметке для лога.
local texts = require("riddle.texts")

local control = {}

-- шаг подсветки по шкале устройства (PW2 — 0..25); выключенная + ↑ — сразу на первый шаг
control.LIGHT_STEP = 5

-- уровень подсветки, шкала, направление (1 — ярче, −1 — тусклее) -> новый уровень в 0..max
function control.light(cur, max, dir)
  return math.max(0, math.min(max, cur + dir * control.LIGHT_STEP))
end

local function light_step(dev, dir)
  local l = dev.light
  if not l then return nil, "no source" end
  local cur = l.get()
  local new = control.light(cur, l.max, dir)
  l.set(new)
  local text = new > 0 and string.format(texts.control_light, new, l.max) or texts.control_light_off
  return text, string.format("light %d->%d", cur, new)
end

-- знак -> команда: function(dev) -> итог | nil (итог виден сам), заметка для лога | nil, "no source"
control.COMMANDS = {
  up = function(dev) return light_step(dev, 1) end,
  down = function(dev) return light_step(dev, -1) end,
  moon = function(dev)
    local n = dev.night
    if not n then return nil, "no source" end
    n.toggle()
    local on = n.get()
    return on and texts.control_night_on or texts.control_night_off, on and "night on" or "night off"
  end,
  square = function(dev)
    if not dev.refresh then return nil, "no source" end
    dev.refresh()
    return nil, "refresh"
  end,
  bolt = function(dev)
    local w = dev.wifi
    if not w then return nil, "no source" end
    local on = w.get()
    w.set(not on)
    return on and texts.control_wifi_off or texts.control_wifi_on, on and "wifi on->off" or "wifi off->on"
  end,
}

-- знак, источники -> итог | nil, заметка для лога («light 5->10», «no source», «error: …»)
function control.run(name, dev)
  local ok, text, note = pcall(control.COMMANDS[name], dev)
  if not ok then return texts.control_failed, "error: " .. tostring(text) end
  if note == "no source" then return texts.control_failed, note end
  return text, note
end

return control
