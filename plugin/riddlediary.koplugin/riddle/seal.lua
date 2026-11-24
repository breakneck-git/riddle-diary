-- Печать: закрыта она или открыта, по правилам cfg.seal (config.parse_seal). Чистая логика, без UI и сети.
-- Открывает только ключ (Controller:seal_toggle); закрывают ключ, сон (on_sleep) и простой (minutes, задача 7).
local seal = {}

local Seal = {}
Seal.__index = Seal

-- rules — cfg.seal: { on, key, minutes, on_sleep, remember, off, invalid }.
-- configured — печать есть; invalid — конфиг битый: печать есть, закрыта и не открывается.
-- Печать есть — на старте закрыта; нет — открыта всегда. last_at — время последней записи (deps.now)
function seal.new(rules)
  return setmetatable({
    rules = rules,
    configured = rules.on,
    invalid = rules.invalid,
    open = not rules.on,
    last_at = nil,
  }, Seal)
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

-- простой истёк — пора закрыть. Тело — задача 7
function Seal:due(now)
  return false
end

function Seal:closes_on_sleep()
  return self.configured and self.rules.on_sleep == true
end

return seal
