-- Печать: закрыта она или открыта, по правилам cfg.seal (config.parse_seal). Логика без UI и сети.
-- Открывает только ключ (Controller:seal_toggle); закрывают ключ, сон (on_sleep) и простой (minutes: Seal:due).
-- Образец ключа (спека 2026-11-20-seal-key §5) — файл KEY_PATH, его пишет сам дневник: encode/decode — формат,
-- load_key/forget_key — чтение и удаление на устройстве (app.new_controller передаёт их контроллеру).
local glyph = require("riddle.glyph")

local seal = {}

-- рядом с конфигом; в git и в push_config.sh его нет
seal.KEY_PATH = "/mnt/us/riddle/seal_key.lua"

-- просьбы о данных при закрытой печати (spec §7): ASKS за ASKS_SPAN секунд — к ответу фраза texts.key_needed
seal.ASKS = 5
seal.ASKS_SPAN = 600

-- образец: список рисунков, рисунок — список штрихов { p = { x1, y1, … } } -> текст файла. Одни рисунки — один и
-- тот же текст: повтор записи даёт тот же файл
function seal.encode(drawings)
  local out = { "return {\n" }
  for _, d in ipairs(drawings) do
    out[#out + 1] = "{\n"
    for _, s in ipairs(d) do out[#out + 1] = "{p={" .. table.concat(s.p, ",") .. "}},\n" end
    out[#out + 1] = "},\n"
  end
  out[#out + 1] = "}\n"
  return table.concat(out)
end

-- t — список 1..n без дыр и лишних ключей
local function is_list(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

-- штрих годен: { p = { x1, y1, … } }, чётное число конечных чисел, хоть одна точка
local function stroke_ok(s)
  if type(s) ~= "table" or next(s, next(s)) ~= nil or not is_list(s.p) or #s.p < 2 or #s.p % 2 ~= 0 then
    return false
  end
  for _, v in ipairs(s.p) do
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return false end
  end
  return true
end

-- рисунок годен: 1..glyph.MAX_STROKES годных штрихов
local function drawing_ok(d)
  if not is_list(d) or #d < 1 or #d > glyph.MAX_STROKES then return false end
  for _, s in ipairs(d) do
    if not stroke_ok(s) then return false end
  end
  return true
end

-- текст файла -> образец | nil (битый, недописанный, не того вида). Файл — данные: пустое окружение, ни одной
-- глобальной функции. До loadstring — только знаки формата (encode): методы строк доступны и в пустом окружении
-- (("x"):rep(1e9) — память Kindle), поэтому код в файле не исполняется вовсе
function seal.decode(s)
  if type(s) ~= "string" then return nil end
  local body = s:match("^%s*return(.*)$")
  if not body or body:find("[^%d%s{},.%-=p]") then return nil end
  local chunk = loadstring(s, "=seal_key")
  if not chunk then return nil end
  setfenv(chunk, {})
  local ok, drawings = pcall(chunk)
  if not ok or not is_list(drawings) or #drawings < 1 then return nil end
  for _, d in ipairs(drawings) do
    if not drawing_ok(d) then return nil end
  end
  return drawings
end

-- path -> образец | nil, "absent" (файла нет) | nil, "broken" (не читается, битый). Не читается по другой причине,
-- чем «нет файла», — тоже "broken": порча не должна сбрасывать ключ в режим задания
function seal.load_key(path)
  local f, _, code = io.open(path, "rb")
  if not f then return nil, code == 2 and "absent" or "broken" end
  local s = f:read("*a")
  f:close()
  local drawings = seal.decode(s)
  if not drawings then return nil, "broken" end
  return drawings
end

-- удалить образец (флаг off) -> true | nil, err. Файла нет — уже удалён, не ошибка: повтор безопасен
function seal.forget_key(path)
  local ok, err, code = os.remove(path)
  if ok or code == 2 then return true end
  return nil, err
end

local Seal = {}
Seal.__index = Seal

-- rules — cfg.seal: { on, key, minutes, on_sleep, remember, off, invalid }.
-- configured — печать есть; invalid — конфиг битый: печать есть, закрыта и не открывается.
-- Печать есть — на старте закрыта; нет — открыта всегда. last_at — время последней записи (deps.now).
-- drawings — образец ключа | nil; setting — режим «задать ключ»: ключ в правилах, образца нет (key_loaded)
function seal.new(rules)
  return setmetatable({
    rules = rules,
    configured = rules.on,
    invalid = rules.invalid,
    open = not rules.on,
    last_at = nil,
    drawings = nil,
    setting = false,
  }, Seal)
end

-- печать открывается ключом: она есть, конфиг цел и в правилах key — образец ей нужен
function Seal:wants_key()
  return self.configured and not self.invalid and self.rules.key == true
end

-- итог чтения образца (seal.load_key): есть — ключ задан; "absent" — режим «задать ключ»; "broken" — ни то ни
-- другое: печать закрыта, пока образец не починят или off его не удалит
function Seal:key_loaded(drawings, err)
  self.drawings = drawings
  self.setting = drawings == nil and err == "absent"
end

-- образец записан: режим кончился, печать открыта
function Seal:key_saved(drawings, now)
  self.drawings = drawings
  self.setting = false
  return self:unlock(now)
end

-- ключ узнан -> true, если печать открыта; битую не открывает (false)
function Seal:unlock(now)
  if self.invalid then return false end
  self.open = true
  self.last_at = now
  return true
end

-- reason — кто закрыл ("key", "sleep", "idle"), для лога. Печати нет — закрывать нечего (false)
function Seal:lock(reason)
  if not self.configured then return false end
  self.open = false
  self.closed_by = reason
  return true
end

-- отвеченная запись: от неё считается простой
function Seal:touch(now)
  self.last_at = now
end

-- секунды до закрытия по простою (правило minutes, spec §6) | nil: закрывать по времени нечего (правила нет, печать
-- закрыта, записи не было). Часы ушли назад (now < last_at; NTP, ручная правка — Review Focus 3): отсчёт от now —
-- раньше срока печать не закроется. Только вопрос: печать не меняет, сброс запоминает clock
function Seal:left(now)
  local minutes = self.rules.minutes
  if not (minutes and self.open and self.last_at) then return nil end
  return math.min(self.last_at, now) + minutes * 60 - now
end

-- сверить часы: ушли назад (now < last_at) — отсчёт заново от now. Зовут due и Controller:seal_left
function Seal:clock(now)
  if self.last_at and now < self.last_at then self.last_at = now end
end

-- простой истёк — пора закрыть
function Seal:due(now)
  self:clock(now)
  local left = self:left(now)
  return left ~= nil and left <= 0
end

function Seal:closes_on_sleep()
  return self.configured and self.rules.on_sleep == true
end

return seal
