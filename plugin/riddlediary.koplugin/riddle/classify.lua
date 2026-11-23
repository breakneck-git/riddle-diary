-- Классификация баз Notion моделью (адаптер, дочерний процесс синхронизации): какие базы — списки дел,
-- какие варианты select/status и чекбоксы значат «сделано» и «архив», какое свойство — проект и срок, какая
-- база — база задач (pick). Модели уходит только схема (названия баз и свойств, варианты, число строк,
-- глубина) — ни строк, ни текстов. Базы — метками c<N>, id наружу не идут. Ответ проверяется по схеме:
-- свойства и варианты не из схемы, свойства не того типа, pick не кандидат — отбрасываются.
local json = require("dkjson")
local llm = require("riddle.llm")

local classify = {}

local SYSTEM = table.concat({
  "Ты разбираешь собрания записей пользователя только по их устройству: название, число записей (items), " ..
    "глубина в дереве (depth, 0 — корень) и свойства (props) с вариантами. Самих записей нет.",
  "Для каждого собрания определи:",
  "- tasks: true, если это список дел, которые выполняют и закрывают; иначе false;",
  "- closed_select: свойство типа select или status и его варианты, означающие «сделано» или «отменено»;",
  "- done_checkbox: свойство типа checkbox, отметка которого значит «сделано»;",
  "- archive_select: свойство типа select или status и варианты, означающие «в архиве»;",
  "- archive_checkbox: свойство типа checkbox, отметка которого значит «в архиве»;",
  "- project: свойство типа relation, указывающее проект записи;",
  "- due: свойство типа date со сроком.",
  "Правила архива определи для всех собраний, не только для списков дел. Чего нет — поле не пиши.",
  "pick — собрание, которое пользователь ведёт как свой список дел; из нескольких подходящих — с меньшей " ..
    "глубиной. Такого нет — \"pick\":\"\".",
  "Названия свойств и вариантов — точно как в схеме. Ответ — только JSON такого вида:",
  '{"collections":[{"c":"c1","tasks":true,"closed_select":{"prop":"…","options":["…"]},"done_checkbox":"…",' ..
    '"archive_select":{"prop":"…","options":["…"]},"archive_checkbox":"…","project":"…","due":"…"}],"pick":"c1"}',
}, "\n")

-- schemas = { { id, title, items, depth, props } … } (props — notion_tasks.schema) -> messages
function classify.messages(schemas)
  local list = {}
  for i, s in ipairs(schemas) do
    list[i] = { c = "c" .. i, title = s.title or "", items = s.items or 0, depth = s.depth, props = s.props }
  end
  return {
    { role = "system", content = SYSTEM },
    { role = "user", content = json.encode(list, { keyorder = { "c", "title", "items", "depth", "props",
      "name", "type", "options", "groups" } }) },
  }
end

-- { [имя свойства] = { type, options = { [имя] = true } } }
local function props_of(schema)
  local out = {}
  for _, p in ipairs(type(schema.props) == "table" and schema.props or {}) do
    local opts = {}
    for _, o in ipairs(type(p.options) == "table" and p.options or {}) do opts[o] = true end
    out[p.name] = { type = p.type, options = opts }
  end
  return out
end

local SELECT_TYPES = { select = true, status = true }

-- {"prop","options":[…]} -> { prop, options = { [имя] = true } } | nil: только варианты этого свойства
local function option_rule(v, props)
  if type(v) ~= "table" or type(v.prop) ~= "string" then return nil end
  local p = props[v.prop]
  if not p or not SELECT_TYPES[p.type] or type(v.options) ~= "table" then return nil end
  local set, any = {}, false
  for _, o in ipairs(v.options) do
    if type(o) == "string" and p.options[o] then set[o] = true; any = true end
  end
  return any and { prop = v.prop, options = set } or nil
end

local function prop_of_type(v, props, t)
  return type(v) == "string" and props[v] and props[v].type == t and v or nil
end

-- text ответа модели -> { rules_by_id = { [id] = rules }, pick_id = id | nil } | nil, err
function classify.parse(text, schemas)
  if type(text) ~= "string" then return nil, "no text" end
  local obj = llm.find_object(text)
  if type(obj) ~= "table" or type(obj.collections) ~= "table" then return nil, "not json" end
  local by_label = {}
  for i, s in ipairs(schemas) do by_label["c" .. i] = s end
  local rules_by_id = {}
  for _, e in ipairs(obj.collections) do
    local s = type(e) == "table" and by_label[e.c]
    if s then
      local props = props_of(s)
      rules_by_id[s.id] = {
        tasks = e.tasks == true,
        closed_select = option_rule(e.closed_select, props),
        done_checkbox = prop_of_type(e.done_checkbox, props, "checkbox"),
        archive_select = option_rule(e.archive_select, props),
        archive_checkbox = prop_of_type(e.archive_checkbox, props, "checkbox"),
        project = prop_of_type(e.project, props, "relation"),
        due = prop_of_type(e.due, props, "date"),
      }
    end
  end
  local picked = by_label[obj.pick]
  local pick_id = picked and rules_by_id[picked.id] and rules_by_id[picked.id].tasks and picked.id or nil
  return { rules_by_id = rules_by_id, pick_id = pick_id }
end

return classify
