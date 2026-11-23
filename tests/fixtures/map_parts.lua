-- Годные ответы модели на разделы карты map и map.cast (план карты, срез 2): объекты — для правок в тестах,
-- *_json — как приходит от модели (в ```-обёртке)
local json = require("dkjson")

local M = {}

M.map = {
  potter = false,
  open = "Скажи, друг, и войди",
  close = "Дорога уходит вдаль",
  blind = "Туман скрыл тропы, путник.",
  places = { school = "Палаты знаний", pub = "Гарцующий пони", house = "Нора" },
}

local CAST = {
  { "Фродо", "townsfolk", "home", "home" },
  { "Сэм", "townsfolk", "work", "home" },
  { "Гэндальф", "teacher", "street", "street" },
  { "Арагорн", "guard", "street", "street" },
  { "Леголас", "guard", "work", "street" },
  { "Гимли", "guard", "work", "home" },
  { "Мерри", "student", "school", "home" },
  { "Пиппин", "student", "school", "home" },
  { "Саруман", "villain", "work", "street" },
  { "Голлум", "villain", "street", "street" },
}

-- n первых героев (по умолчанию все 10)
function M.cast(n)
  local out = {}
  for i = 1, n or #CAST do
    local c = CAST[i]
    out[i] = { name = c[1], role = c[2], day = c[3], night = c[4] }
  end
  return out
end

function M.wrap(v) return "```json\n" .. json.encode(v) .. "\n```" end

M.map_json = M.wrap(M.map)
M.cast_json = M.wrap(M.cast())

-- данные карты персоны id (по умолчанию «Методов») уже сгенерированы, как это делает хвост генерации: тестам пересказа
-- и свёртки генерация карты не мешает
function M.seed(mem, id, now)
  local persona = require("riddle.persona")
  id = id or persona.METHODS_ID
  mem:set_part(id, "map", persona.section("map").decode(M.map_json), now or 0)
  mem:set_part(id, "map.cast", persona.section("map.cast").decode(M.cast_json), now or 0)
end

return M
