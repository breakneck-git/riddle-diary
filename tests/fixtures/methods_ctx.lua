-- Контекст «со всеми разделами» для снимка промптов персоны «Методов» (tests/fixtures/methods_prompts.lua):
-- лор, знание, задачи, названия книг, пересказы, свёртка, история. Снимок снят этим же контекстом.
local tasks = require("riddle.tasks")

local M = {}

function M.open_ctx(sealed)
  local list = {}
  for i = 1, 3 do
    list[i] = { id = "id" .. i, title = "ДЕЛО-" .. i, due = i == 1 and "2026-10-30" or nil,
      project = i == 2 and "ПРОЕКТ" or nil }
  end
  return {
    sealed = sealed,
    lore = "## Раздел\nЛОР-МАРКЕР",
    knowledge = "ЗНАНИЕ-МАРКЕР",
    tasks = tasks.block(list),
    titles = { "КНИГА-1", "КНИГА-2" },
    summaries = { "ПЕРЕСКАЗ-1", "ПЕРЕСКАЗ-2" },
    rolling = "СВЁРТКА-МАРКЕР",
    recent = { { role = "owner", text = "ЗАПИСЬ-1" }, { role = "diary", text = "ОТВЕТ-1" } },
    mode_line = "ПОМЕТКА",
  }
end

M.entries = { { role = "owner", text = "ЗАПИСЬ" }, { role = "diary", text = "ОТВЕТ" } }

return M
