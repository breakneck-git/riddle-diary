-- Сведения карты мародёров о текущей персоне (план карты, раздел 2): единственное место, откуда виджет и вид карты
-- их читают (mapdata.of), и формат разделов map/map.cast — значения, по которым их просит генерация (prompt.gen_map,
-- gen_cast) и проверяет ответ (persona.MAP_SECTIONS). Разделы проверены при сохранении: здесь им доверяют.
local json = require("dkjson")

local mapdata = {}

-- канон Роулинг: у мира Поттера фразы открытия и закрытия — эти, сгенерированные не берутся (спека, раздел 1).
-- Заголовка у карты нет: на экране его не рисуют (владелец 2026-11-16)
mapdata.POTTER = {
  ru = { open = "Торжественно клянусь, что замышляю шалость, и только шалость", close = "Шалость удалась" },
  en = { open = "I solemnly swear that I am up to no good", close = "Mischief managed" },
}

-- ключевые слова клятвы мира Поттера на обоих языках: опора чтения открывашки (prompt.MAP_FORMAT) — владелец
-- 2026-10-31: «не конкретно, вся фраза целиком, обязательно, чтобы это были ключевые слова в этой фразе»
mapdata.POTTER_WORDS = { "замышляю", "шалость", "клянусь", "solemnly swear", "up to no good" }

-- надпись на пергаменте, когда карта не знает, где она (нет сети, гео, данных); до генерации раздела map
mapdata.BLIND = {
  ru = "Карта не видит, где ты.",
  en = "The map cannot see where you are.",
}

-- имена разделов persona_parts: их пишет генерация (persona.MAP_SECTIONS), читает mapdata.of
mapdata.SECTION_MAP = "map"
mapdata.SECTION_CAST = "map.cast"

-- раздел map.cast: героев годных меньше MIN_CAST — раздел не сохраняется, больше MAX_CAST — лишние отброшены
mapdata.MIN_CAST = 6
mapdata.MAX_CAST = 15
-- потолки в знаках: имя героя, название места (значение places)
mapdata.NAME_MAX = 30
mapdata.PLACE_MAX = 40
-- значения полей героя: роль, где днём в будни, где ночью
mapdata.ROLES = { "student", "teacher", "guard", "villain", "townsfolk" }
mapdata.DAY = { "school", "work", "street", "home" }
mapdata.NIGHT = { "home", "street" }

-- persona требует prompt, а prompt — этот модуль (значения формата): persona здесь — при вызове, не в шапке
local function methods_id() return require("riddle.persona").METHODS_ID end
local function short(v, max) return require("riddle.persona").short(v, max) end

-- имя, которым владелец назвался дневнику (Controller:owner_name; запись — Controller:_answer): без пробелов по краям,
-- пустое или длиннее NAME_MAX знаков (как имя героя) — nil. Одно правило на запись в базу и на книгу на карте
function mapdata.owner(v)
  return short(v, mapdata.NAME_MAX)
end

local function lang_of(view, row)
  local l = (view and view.lang) or (row and row.lang)
  return (l == "ru" or l == "en") and l or "en"
end

local function decoded(text)
  local v = type(text) == "string" and json.decode(text)
  return type(v) == "table" and v or nil
end

-- view, row, parts — как у Controller:_current; любой из них может быть nil (персоны нет, сбой чтения); owner — имя,
-- которым владелец представился дневнику (Controller:owner_name), или nil
-- -> { potter, blind, open?, close?, places = { [kind] = name }, cast = { {name, role, day, night} }, owner? }.
-- Мир Поттера — «Методов» или признак раздела map: фразы открытия и закрытия канонические; blind, места и герои — всегда из
-- разделов, если они есть. owner — по mapdata.owner; негодное — nil: книга на карте без имени (срез 13а)
function mapdata.of(view, row, parts, owner)
  local lang = lang_of(view, row)
  local map = decoded(parts and parts[mapdata.SECTION_MAP])
  local potter = (row ~= nil and row.id == methods_id()) or (map ~= nil and map.potter == true)
  local m = { potter = potter, blind = map and map.blind or mapdata.BLIND[lang], places = map and map.places or {},
    cast = decoded(parts and parts[mapdata.SECTION_CAST]) or {}, owner = mapdata.owner(owner) }
  if potter then
    local canon = mapdata.POTTER[lang]
    m.open, m.close = canon.open, canon.close
  elseif map then
    m.open, m.close = map.open, map.close
  end
  return m
end

-- подпись здания типа kind (terrain.KINDS) на карте: место вселенной из словаря раздела map (mapdata.of) или nil —
-- жилые дома не подписываются (их много, подпись «Нора» у каждого — шум), тип без слова в словаре — тоже
function mapdata.label(data, kind)
  if kind == nil or kind == "house" then return nil end
  local name = data.places[kind]
  return type(name) == "string" and name ~= "" and name or nil
end

return mapdata
