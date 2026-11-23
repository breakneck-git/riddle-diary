-- Адаптер Notion → общий формат задач (collections, tasks в knowledge; см. tasks.lua). Знает устройство Notion:
-- глубину базы по parent, закрытость по группе "Complete" свойств status (имя группы — константа API, не слово
-- пользователя), корзину строк и проектов. Названий баз, свойств и вариантов в коде нет: толкование, зависящее
-- от названий (select «готово», чекбокс, архив, проект, срок), приходит правилами классификации (rules_by_id).
local bit = require("bit")
local json = require("dkjson")
local nt = require("riddle.notion_text")

local notion_tasks = {}
notion_tasks.MAX_DEPTH_STEPS = 12
notion_tasks.SOURCE = "notion"

local COMPLETE = "Complete"

-- ссылка на родителя -> kind для GET, id | nil (workspace или незнакомый тип — корень)
local PARENT_KINDS = { page_id = "pages", block_id = "blocks", data_source_id = "data_sources" }

local function parent_of(obj)
  -- у data source родитель в дереве — родитель его database (parent указывает на саму database)
  local p = obj.object == "data_source" and obj.database_parent or obj.parent
  if type(p) ~= "table" then return nil end
  local kind = PARENT_KINDS[p.type]
  local id = kind and p[p.type]
  if type(id) ~= "string" then return nil end
  return kind, id
end

-- глубина data source: сколько предков до корня. Предок берётся из by_id (результаты поиска), нет —
-- fetch(kind, id) один раз (ответ, и пустой тоже, запоминается в by_id); недоступный предок (404) засчитан,
-- дальше — стоп. Не больше MAX_DEPTH_STEPS шагов (защита от цикла).
function notion_tasks.depth(src, by_id, fetch)
  local n, obj = 0, src
  while n < notion_tasks.MAX_DEPTH_STEPS do
    local kind, id = parent_of(obj)
    if not kind then break end
    n = n + 1
    local next_obj = by_id[id]
    if next_obj == nil then
      next_obj = fetch and fetch(kind, id) or false
      if type(next_obj) ~= "table" then next_obj = false end
      by_id[id] = next_obj
    end
    if not next_obj then break end
    obj = next_obj
  end
  return n
end

-- правила по умолчанию: { status = { [свойство] = { [имя варианта группы Complete] = true } } }
function notion_tasks.default_rules(src)
  local rules = { status = {} }
  local props = type(src) == "table" and type(src.properties) == "table" and src.properties or {}
  for prop, p in pairs(props) do
    local s = type(p) == "table" and p.type == "status" and p.status
    if type(s) == "table" then
      local name_of = {}
      for _, o in ipairs(type(s.options) == "table" and s.options or {}) do
        if type(o) == "table" and o.id ~= nil then name_of[o.id] = o.name end
      end
      local done = {}
      for _, g in ipairs(type(s.groups) == "table" and s.groups or {}) do
        if type(g) == "table" and g.name == COMPLETE then
          for _, oid in ipairs(type(g.option_ids) == "table" and g.option_ids or {}) do
            if type(name_of[oid]) == "string" then done[name_of[oid]] = true end
          end
        end
      end
      rules.status[prop] = done
    end
  end
  return rules
end

local function trashed(obj)
  return obj.in_trash == true or obj.archived == true
end

local function prop(row, name)
  local props = type(row.properties) == "table" and row.properties or {}
  local v = name and props[name]
  return type(v) == "table" and v or nil
end

-- имя варианта select или status в строке | nil
local function option(row, name)
  local v = prop(row, name)
  local o = v and (v.type == "select" or v.type == "status") and v[v.type]
  return type(o) == "table" and type(o.name) == "string" and o.name or nil
end

local function checked(row, name)
  local v = prop(row, name)
  return v ~= nil and v.type == "checkbox" and v.checkbox == true
end

-- rule = { prop, options = { [имя варианта] = true } } | nil
local function option_in(row, rule)
  local o = type(rule) == "table" and type(rule.options) == "table" and option(row, rule.prop)
  return o and rule.options[o] == true or false
end

local function closed(row, rules)
  for name, done in pairs(rules.status or {}) do
    local v = prop(row, name)
    local s = v and v.type == "status" and v.status
    if type(s) == "table" and done[s.name] then return true end
  end
  return option_in(row, rules.closed_select) or checked(row, rules.done_checkbox)
end

-- строка в архиве: корзина или правила архива классификации (вариант select/status, чекбокс) —
-- для строки любой базы синхронизации, не только кандидата (база проектов)
function notion_tasks.row_archived(row, rules)
  rules = type(rules) == "table" and rules or {}
  return trashed(row) or option_in(row, rules.archive_select) or checked(row, rules.archive_checkbox)
end

-- задача общего формата из строки базы.
-- look = { title_of = fn(id) -> string | nil, project_archived = fn(task_id, edited, project_id) -> bool }
function notion_tasks.task(row, collection_id, rules, look)
  local edited = type(row.last_edited_time) == "string" and row.last_edited_time or nil
  local project, archived = nil, notion_tasks.row_archived(row, rules)
  local rel = prop(row, rules.project)
  local target = rel and rel.type == "relation" and type(rel.relation) == "table" and rel.relation[1]
  local project_id = type(target) == "table" and type(target.id) == "string" and target.id or nil
  if project_id then
    project = look.title_of(project_id)
    if not archived and look.project_archived(row.id, edited, project_id) then archived = true end
  end
  local date = prop(row, rules.due)
  local due = date and date.type == "date" and type(date.date) == "table" and date.date.start
  return {
    id = row.id,
    collection_id = collection_id,
    title = nt.title(row),
    open = not closed(row, rules),
    archived = archived,
    project = project ~= "" and project or nil,
    due = type(due) == "string" and due or nil,
    edited = edited,
  }
end

-- d = { sources, rows_by_source, by_id (объекты поиска), docs_titles, rules_by_id, chosen_id, pick_id, fetch }
-- -> collections, tasks. Задачи — строки кандидатов (rules_by_id[id].tasks) и выбранной словом/конфигом базы;
-- pick_id — база, которую классификация выбрала базой задач (model_pick).
-- Проект в архиве — только если цель relation есть среди строк синхронизации (row_archived по правилам её базы);
-- цель вне синхронизации пока не архив (GET /v1/pages для неё — отдельным шагом, см. план, шаг 3b).
function notion_tasks.snapshot(d)
  local by_id = d.by_id or {}
  local rules_by_id = d.rules_by_id or {}
  local pages, rules_of = {}, {}
  for id, o in pairs(by_id) do if type(o) == "table" then pages[id] = o end end
  for src_id, rows in pairs(d.rows_by_source or {}) do
    for _, r in ipairs(rows) do
      if type(r) == "table" and type(r.id) == "string" then
        pages[r.id] = r
        rules_of[r.id] = rules_by_id[src_id]
      end
    end
  end
  local look = {
    title_of = function(id)
      local s = d.docs_titles and d.docs_titles[id]
      if s == nil and pages[id] then s = nt.title(pages[id]) end
      return s
    end,
    project_archived = function(_, _, project_id)
      local p = pages[project_id]
      return p ~= nil and notion_tasks.row_archived(p, rules_of[project_id])
    end,
  }
  local collections, tasks = {}, {}
  for _, src in ipairs(d.sources or {}) do
    local rows = d.rows_by_source and d.rows_by_source[src.id] or {}
    local cls = rules_by_id[src.id]
    local candidate = type(cls) == "table" and cls.tasks == true
    collections[#collections + 1] = {
      id = src.id,
      title = nt.title(src),
      source = notion_tasks.SOURCE,
      items = #rows,
      task_candidate = candidate,
      native_tasks = false, -- признака «база задач» в API нет (database_type у обычных баз — null)
      depth = notion_tasks.depth(src, by_id, d.fetch),
      model_pick = d.pick_id ~= nil and src.id == d.pick_id,
    }
    if candidate or src.id == d.chosen_id then
      local rules = {}
      for k, v in pairs(type(cls) == "table" and cls or {}) do rules[k] = v end
      rules.status = rules.status or notion_tasks.default_rules(src).status
      for _, r in ipairs(rows) do
        if type(r) == "table" and type(r.id) == "string" then
          tasks[#tasks + 1] = notion_tasks.task(r, src.id, rules, look)
        end
      end
    end
  end
  return collections, tasks
end

-- свойства, которые видит классификация; без status/select/checkbox база не классифицируется
local SCHEMA_TYPES = { status = true, select = true, checkbox = true, relation = true, date = true }
local CLOSABLE = { status = true, select = true, checkbox = true }

local function option_names(list)
  local out = {}
  for _, o in ipairs(type(list) == "table" and list or {}) do
    if type(o) == "table" and type(o.name) == "string" then out[#out + 1] = o.name end
  end
  return out
end

-- схема базы для классификации -> { props = { { name, type, options?, groups? } … } } (по имени) | nil.
-- Варианты и группы — именами (id вариантов модели не нужны); строк и значений нет.
function notion_tasks.schema(src)
  local props = type(src) == "table" and type(src.properties) == "table" and src.properties or {}
  local out, closable = {}, false
  for name, p in pairs(props) do
    if type(name) == "string" and type(p) == "table" and SCHEMA_TYPES[p.type] then
      closable = closable or CLOSABLE[p.type] == true
      local e = { name = name, type = p.type }
      local body = type(p[p.type]) == "table" and p[p.type] or {}
      if p.type == "select" or p.type == "status" then e.options = option_names(body.options) end
      if p.type == "status" then
        local name_of = {}
        for _, o in ipairs(type(body.options) == "table" and body.options or {}) do
          if type(o) == "table" and o.id ~= nil then name_of[o.id] = o.name end
        end
        e.groups = {}
        for _, g in ipairs(type(body.groups) == "table" and body.groups or {}) do
          if type(g) == "table" and type(g.name) == "string" then
            local names = {}
            for _, oid in ipairs(type(g.option_ids) == "table" and g.option_ids or {}) do
              if type(name_of[oid]) == "string" then names[#names + 1] = name_of[oid] end
            end
            e.groups[#e.groups + 1] = { name = g.name, options = names }
          end
        end
      end
      out[#out + 1] = e
    end
  end
  if not closable then return nil end
  table.sort(out, function(a, b) return a.name < b.name end)
  return { props = out }
end

local HASH_KEYS = { keyorder = { "id", "props", "name", "type", "options", "groups" } }

-- FNV-1a 32 по json.encode схем (id базы и props, порядок ключей задан): items и title не входят —
-- новые строки и переименование базы не запускают классификацию. list = { { id, props, … } … } -> hex
function notion_tasks.schema_hash(list)
  local canon = {}
  for i, e in ipairs(list) do canon[i] = { id = e.id, props = e.props } end
  table.sort(canon, function(a, b) return a.id < b.id end)
  local s = json.encode(canon, HASH_KEYS)
  local h = bit.tobit(2166136261)
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i))
    -- h * 16777619 по модулю 2^32 без потери точности double: 16777619 = 2^24 + 403
    h = bit.tobit(bit.lshift(h, 24) + h % 4294967296 * 403)
  end
  return bit.tohex(h)
end

return notion_tasks
