-- Печать для тестовых стендов: правила — как их отдаёт config.load (cfg.seal), и страница-ключ.
local config = require("riddle.config")

local M = {}

-- печать по ключу
function M.key() return config.parse_seal({ key = true }) end

-- печати нет
function M.none() return config.parse_seal(nil) end

-- свои правила
function M.rules(raw) return config.parse_seal(raw) end

-- следующая отвеченная страница — ключ: ответ на неё — seal_toggle (как у key_page, задача 6), ответ модели не
-- показывается. Распознаватель рисунка в стенде не нужен — важно, что страница открыла или закрыла печать
function M.next_page_is_key(ctl)
  ctl._answer = function(self)
    rawset(self, "_answer", nil)
    return self:seal_toggle()
  end
end

return M
