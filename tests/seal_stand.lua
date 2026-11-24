-- Печать для тестовых стендов: правила — как их отдаёт config.load (cfg.seal), образец ключа и страница-ключ.
local config = require("riddle.config")
local O = require("fixtures.rose_owner")

local M = {}

-- печать по ключу
function M.key() return config.parse_seal({ key = true }) end

-- печати нет
function M.none() return config.parse_seal(nil) end

-- свои правила
function M.rules(raw) return config.parse_seal(raw) end

-- образец ключа на устройстве (deps.load_key контроллера): две розы владельца
function M.load_key() return { O.owner_01, O.owner_02 } end

-- страница-ключ — третья роза владельца: key_page узнаёт её по образцу load_key. lvl — уровень растворения штрихов
-- (виджет: Diary.CFG.dissolve.steps — чернила уже растворились, фраза ключа не ждёт их)
function M.key_strokes(lvl)
  local out = {}
  for i, s in ipairs(O.owner_03) do out[i] = { p = s.p, lvl = lvl } end
  return out
end

return M
