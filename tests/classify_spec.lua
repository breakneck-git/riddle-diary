-- Классификация баз моделью: запрос несёт только схему (свойства и варианты, без строк), ответ проверяется
-- по схеме — чужие свойства и варианты, pick не кандидат отбрасываются, мусор — ошибка.
local t = require("t")
local json = require("dkjson")
local classify = require("riddle.classify")

-- схема базы — как её отдаёт notion_tasks.schema (+ id, title, items, depth от синхронизации)
local function schemas()
  return {
    { id = "ds-tasks", title = "Дела", items = 12, depth = 1, props = {
      { name = "Готово", type = "checkbox" },
      { name = "Проект", type = "relation" },
      { name = "Срок", type = "date" },
      { name = "Тип", type = "select", options = { "Срочно", "Отменена", "Сделано" } },
      { name = "Этап", type = "status", options = { "Не начато", "В работе", "Архив" },
        groups = { { name = "To-do", options = { "Не начато" } }, { name = "In progress", options = { "В работе" } },
          { name = "Complete", options = { "Архив" } } } },
    } },
    { id = "ds-proj", title = "Проекты", items = 3, depth = 0, props = {
      { name = "Состояние", type = "select", options = { "Активен", "Архив" } },
      { name = "Скрыт", type = "checkbox" },
    } },
  }
end

local function user_json(messages)
  return json.decode(messages[#messages].content)
end

local T = {}

function T.test_messages_carry_schema_not_rows()
  local m = classify.messages(schemas())
  t.eq(#m, 2)
  t.eq(m[1].role, "system")
  t.eq(m[2].role, "user")
  t.ok(m[1].content:find('"collections"', 1, true), "формат ответа в system")
  local u = user_json(m)
  t.eq(#u, 2)
  t.eq(u[1].c, "c1")
  t.eq(u[1].title, "Дела")
  t.eq(u[1].items, 12)
  t.eq(u[1].depth, 1, "глубина — для выбора из нескольких: выше в иерархии — приоритетнее")
  t.eq(u[2].c, "c2")
  t.eq(#u[1].props, 5)
  local all = m[1].content .. m[2].content
  t.ok(not all:find("ds-tasks", 1, true), "id баз модели не уходят — только метки c<N>")
  t.ok(all:find("Отменена", 1, true), "варианты select — в запросе")
end

local function answer(obj) return json.encode(obj) end

function T.test_parse_valid_answer()
  local text = "```json\n" .. answer({
    collections = {
      { c = "c1", tasks = true, closed_select = { prop = "Тип", options = { "Отменена", "Сделано" } },
        done_checkbox = "Готово", archive_select = { prop = "Этап", options = { "Архив" } },
        project = "Проект", due = "Срок" },
      { c = "c2", tasks = false, archive_select = { prop = "Состояние", options = { "Архив" } },
        archive_checkbox = "Скрыт" },
    },
    pick = "c1",
  }) .. "\n```"
  local res, err = classify.parse(text, schemas())
  t.eq(err, nil)
  local r = res.rules_by_id["ds-tasks"]
  t.eq(r.tasks, true)
  t.eq(r.closed_select.prop, "Тип")
  t.eq(r.closed_select.options["Отменена"], true)
  t.eq(r.closed_select.options["Сделано"], true)
  t.eq(r.closed_select.options["Срочно"], nil)
  t.eq(r.done_checkbox, "Готово")
  t.eq(r.archive_select.prop, "Этап", "архив по варианту status тоже можно")
  t.eq(r.project, "Проект")
  t.eq(r.due, "Срок")
  local p = res.rules_by_id["ds-proj"]
  t.eq(p.tasks, false)
  t.eq(p.archive_select.options["Архив"], true)
  t.eq(p.archive_checkbox, "Скрыт")
  t.eq(res.pick_id, "ds-tasks")
end

function T.test_parse_drops_unknown_props_and_options()
  local res = classify.parse(answer({
    collections = {
      { c = "c1", tasks = true,
        closed_select = { prop = "Тип", options = { "Сделано", "Выдумано", 3 } },
        done_checkbox = "Нет такого",
        archive_select = { prop = "Готово", options = { "Архив" } }, -- checkbox, не select
        archive_checkbox = "Тип", -- select, не checkbox
        project = "Срок", -- date, не relation
        due = "Проект" }, -- relation, не date
      { c = "c2", closed_select = { prop = "Состояние", options = { "Нету" } } },
      { c = "c9", tasks = true },
    },
  }), schemas())
  local r = res.rules_by_id["ds-tasks"]
  t.eq(r.closed_select.options["Сделано"], true)
  t.eq(r.closed_select.options["Выдумано"], nil)
  t.eq(r.done_checkbox, nil)
  t.eq(r.archive_select, nil)
  t.eq(r.archive_checkbox, nil)
  t.eq(r.project, nil)
  t.eq(r.due, nil)
  t.eq(res.rules_by_id["ds-proj"].closed_select, nil, "ни одного варианта из схемы — правила нет")
  t.eq(res.rules_by_id["ds-proj"].tasks, false, "tasks не true — не кандидат")
  local n = 0
  for _ in pairs(res.rules_by_id) do n = n + 1 end
  t.eq(n, 2, "чужая метка c9 отброшена")
  t.eq(res.pick_id, nil)
end

function T.test_parse_pick_must_be_candidate()
  local function pick(p)
    return classify.parse(answer({ collections = { { c = "c1", tasks = true }, { c = "c2", tasks = false } },
      pick = p }), schemas()).pick_id
  end
  t.eq(pick("c1"), "ds-tasks")
  t.eq(pick("c2"), nil, "не кандидат")
  t.eq(pick("c7"), nil, "нет такой")
  t.eq(pick(""), nil)
  t.eq(pick(1), nil)
end

function T.test_parse_garbage_is_error()
  for _, text in ipairs({ "", "не знаю", "[1,2]", answer({ pick = "c1" }), answer({ collections = "c1" }) }) do
    local res, err = classify.parse(text, schemas())
    t.eq(res, nil, text)
    t.ok(type(err) == "string", "ошибка строкой: " .. text)
  end
  local res, err = classify.parse(nil, schemas())
  t.eq(res, nil)
  t.ok(err)
end

t.run(T)
