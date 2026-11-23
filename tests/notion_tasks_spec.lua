-- Адаптер Notion → общий формат: глубина базы по parent, закрытость по группе Complete свойств status,
-- снимок коллекций и задач. Фикстуры — формы ответов API 2025-09-03 из живой проверки (план, «Проверка
-- ASSUMPTION»): data source с database_parent и properties.status.status.groups, страницы с parent.
local t = require("t")
local nk = require("riddle.notion_tasks")

local function rt(s) return { { plain_text = s } } end

local function ds(id, title, database_parent, properties)
  return { object = "data_source", id = id, title = rt(title),
    parent = { type = "database_id", database_id = "db-" .. id },
    database_parent = database_parent or { type = "workspace", workspace = true },
    properties = properties or { ["Имя"] = { id = "title", name = "Имя", type = "title", title = {} } } }
end

local function in_page(id) return { type = "page_id", page_id = id } end
local function in_ds(id) return { type = "data_source_id", data_source_id = id, database_id = "db-" .. id } end
local WS = { type = "workspace", workspace = true }

local function page(id, title, parent)
  return { object = "page", id = id, parent = parent or WS, last_edited_time = "2026-10-25T10:00:00.000Z",
    properties = { ["Имя"] = { id = "title", type = "title", title = rt(title) } } }
end

-- свойство status: варианты с названиями на любом языке, группы — константы API
local function status_prop(name, done_names)
  local options, todo, complete = {}, {}, {}
  local all = { "Не начато", "В работе" }
  for _, n in ipairs(done_names) do all[#all + 1] = n end
  for i, n in ipairs(all) do
    local id = name .. "-o" .. i
    options[i] = { id = id, name = n, color = "default", description = nil }
    if i <= 2 then todo[#todo + 1] = id else complete[#complete + 1] = id end
  end
  return { id = name .. "-id", name = name, type = "status", status = {
    options = options,
    groups = {
      { id = "g1", name = "To-do", color = "gray", option_ids = { todo[1] } },
      { id = "g2", name = "In progress", color = "blue", option_ids = { todo[2] } },
      { id = "g3", name = "Complete", color = "green", option_ids = complete },
    },
    default_option = options[1].id,
  } }
end

local function task_source(id, title, parent)
  return ds(id, title, parent, {
    ["Имя"] = { id = "title", name = "Имя", type = "title", title = {} },
    ["Этап"] = status_prop("Этап", { "Готово", "Отменена" }),
  })
end

-- строка базы со значением status
local function row(id, title, src_id, values)
  local r = page(id, title, in_ds(src_id))
  for prop, v in pairs(values or {}) do r.properties[prop] = v end
  return r
end
local function st(name) return { id = "x", type = "status", status = { id = "o", name = name, color = "default" } } end

local function by_id(list)
  local m = {}
  for _, o in ipairs(list) do m[o.id] = o end
  return m
end

local function counting_fetch(objs)
  local calls = {}
  local fetch = function(kind, id)
    calls[#calls + 1] = kind .. "/" .. id
    local o = objs and objs[id]
    if o then return o end
    return nil, "http 404 object_not_found"
  end
  return fetch, calls
end

local function look()
  return { title_of = function() return nil end, project_archived = function() return false end }
end

local T = {}

-- data source → page_id → data_source_id → page_id → workspace: 3 предка, все в результатах поиска
function T.test_depth_from_search_objects_without_fetch()
  local objs = by_id({
    page("A", "Раздел", in_ds("B")),
    ds("B", "Проекты", in_page("C")),
    page("C", "Корень", WS),
  })
  local fetch, calls = counting_fetch()
  t.eq(nk.depth(ds("X", "Задачи", in_page("A")), objs, fetch), 3)
  t.eq(nk.depth(ds("R", "Корневая", WS), objs, fetch), 0)
  t.eq(#calls, 0, "лишних вызовов нет")
end

-- предка нет в поиске — один GET по его типу; второй база с тем же предком его не повторяет
function T.test_depth_fetches_missing_ancestor_once()
  local objs = {}
  local fetch, calls = counting_fetch({ P = page("P", "Скрытая", in_page("Q")), Q = page("Q", "Корень", WS) })
  t.eq(nk.depth(ds("X1", "А", in_page("P")), objs, fetch), 2)
  t.eq(nk.depth(ds("X2", "Б", in_page("P")), objs, fetch), 2)
  t.eq(table.concat(calls, ","), "pages/P,pages/Q")
  local b = { object = "block", id = "K", parent = in_page("C") }
  local fetch2, calls2 = counting_fetch({ K = b })
  t.eq(nk.depth(ds("X3", "В", { type = "block_id", block_id = "K" }), { C = page("C", "Корень", WS) }, fetch2), 2)
  t.eq(table.concat(calls2, ","), "blocks/K", "блок — GET /v1/blocks")
end

-- 404 (нет доступа) — глубина считается до него: шаг к недоступному предку засчитан, дальше — стоп
function T.test_depth_stops_on_404()
  local fetch, calls = counting_fetch()
  local objs = {}
  t.eq(nk.depth(ds("X", "А", in_page("P")), objs, fetch), 1)
  t.eq(nk.depth(ds("Y", "Б", in_page("P")), objs, fetch), 1)
  t.eq(#calls, 1, "404 тоже запоминается")
end

function T.test_depth_cycle_is_capped()
  local objs = by_id({ page("A", "А", in_page("B")), page("B", "Б", in_page("A")) })
  local fetch = counting_fetch()
  t.eq(nk.depth(ds("X", "Х", in_page("A")), objs, fetch), nk.MAX_DEPTH_STEPS)
end

function T.test_default_rules_take_complete_group_names()
  local rules = nk.default_rules(task_source("S", "Дела"))
  t.ok(rules.status["Этап"], "правило по свойству status")
  t.eq(rules.status["Этап"]["Готово"], true)
  t.eq(rules.status["Этап"]["Отменена"], true)
  t.eq(rules.status["Этап"]["В работе"], nil)
  t.eq(rules.status["Имя"], nil, "не status — правила нет")
  t.eq(next(nk.default_rules(ds("F", "Фильмы")).status), nil, "без status — пусто")
end

function T.test_status_in_complete_group_is_closed()
  local rules = nk.default_rules(task_source("S", "Дела"))
  for _, name in ipairs({ "Готово", "Отменена" }) do
    local tk = nk.task(row("r", "Купить хлеб", "S", { ["Этап"] = st(name) }), "S", rules, look())
    t.eq(tk.open, false, name)
    t.eq(tk.archived, false)
    t.eq(tk.title, "Купить хлеб")
    t.eq(tk.collection_id, "S")
    t.eq(tk.edited, "2026-10-25T10:00:00.000Z")
  end
end

function T.test_status_in_progress_is_open()
  local rules = nk.default_rules(task_source("S", "Дела"))
  for _, name in ipairs({ "Не начато", "В работе" }) do
    t.eq(nk.task(row("r", "Х", "S", { ["Этап"] = st(name) }), "S", rules, look()).open, true, name)
  end
  t.eq(nk.task(row("r", "Х", "S", { ["Этап"] = { type = "status", status = nil } }), "S", rules, look()).open, true,
    "status пуст — незакрыта")
end

function T.test_two_status_props_closed_if_any_closed()
  local src = task_source("S", "Дела")
  src.properties["Ревью"] = status_prop("Ревью", { "Принято" })
  local rules = nk.default_rules(src)
  local function open(a, b)
    return nk.task(row("r", "Х", "S", { ["Этап"] = st(a), ["Ревью"] = st(b) }), "S", rules, look()).open
  end
  t.eq(open("В работе", "В работе"), true)
  t.eq(open("Готово", "В работе"), false)
  t.eq(open("В работе", "Принято"), false)
end

-- корзина строки — архив, а не «закрыта»
function T.test_trashed_row_is_archived()
  local r = row("r", "Х", "S", { ["Этап"] = st("В работе") })
  r.in_trash = true
  local tk = nk.task(r, "S", nk.default_rules(task_source("S", "Дела")), look())
  t.eq(tk.archived, true)
  t.eq(tk.open, true)
end

-- снимок: все data source — коллекции; задачи — у кандидатов (правила классификации) и у выбранной
local function snap_input()
  local tasks_src = task_source("S", "Дела", in_page("C"))
  local films = ds("F", "Фильмы", WS)
  local notes = ds("N", "Заметки", WS)
  local rows = {
    S = { row("s1", "Купить хлеб", "S", { ["Этап"] = st("В работе") }), row("s2", "Позвонить", "S", { ["Этап"] = st("Готово") }) },
    F = { row("f1", "Дюна", "F"), row("f2", "Сталкер", "F") },
    N = { row("n1", "Мысль", "N") },
  }
  return {
    sources = { tasks_src, films, notes },
    rows_by_source = rows,
    by_id = by_id({ tasks_src, films, notes, page("C", "Корень", WS) }),
    docs_titles = {},
    rules_by_id = {},
    fetch = counting_fetch(),
  }
end

local function ids(list)
  local out = {}
  for i, x in ipairs(list) do out[i] = x.id end
  table.sort(out)
  return table.concat(out, " ")
end

function T.test_snapshot_collections_with_depth_and_items()
  local d = snap_input()
  local cols, tks = nk.snapshot(d)
  t.eq(ids(cols), "F N S")
  local m = by_id(cols)
  t.eq(m.S.title, "Дела")
  t.eq(m.S.source, "notion")
  t.eq(m.S.items, 2)
  t.eq(m.S.depth, 1)
  t.eq(m.F.depth, 0)
  t.eq(m.N.items, 1)
  t.eq(m.S.native_tasks, false, "признака «база задач» в API нет")
  t.eq(m.S.task_candidate, false, "без классификации кандидатов нет")
  t.eq(m.S.model_pick, false)
  t.eq(#tks, 0, "ни кандидатов, ни выбранной — задач нет")
end

function T.test_candidate_rows_become_tasks()
  local d = snap_input()
  d.rules_by_id = { S = { tasks = true } }
  local cols, tks = nk.snapshot(d)
  t.eq(by_id(cols).S.task_candidate, true)
  t.eq(ids(tks), "s1 s2")
  local m = by_id(tks)
  t.eq(m.s1.open, true)
  t.eq(m.s2.open, false, "status по группе Complete — и без правил классификации")
end

-- выбранная словом или конфигом база без status и без правил: все строки незакрыты
function T.test_chosen_non_candidate_rows_are_open_without_rules()
  local d = snap_input()
  d.chosen_id = "F"
  local cols, tks = nk.snapshot(d)
  t.eq(by_id(cols).F.task_candidate, false, "флаг кандидата — только от классификации")
  t.eq(ids(tks), "f1 f2")
  for _, tk in ipairs(tks) do
    t.eq(tk.open, true)
    t.eq(tk.archived, false)
    t.eq(tk.collection_id, "F")
  end
end

-- проект и срок — по правилам источника (rules.project, rules.due; задаёт классификация, срез 6)
function T.test_project_and_due_by_rules()
  local d = snap_input()
  d.rules_by_id = { S = { tasks = true, project = "Проект", due = "Срок" } }
  local r = d.rows_by_source.S[1]
  r.properties["Проект"] = { type = "relation", relation = { { id = "P1" } } }
  r.properties["Срок"] = { type = "date", date = { start = "2026-10-30", ["end"] = nil } }
  d.docs_titles = { P1 = "Ремонт" }
  local _, tks = nk.snapshot(d)
  local m = by_id(tks)
  t.eq(m.s1.project, "Ремонт")
  t.eq(m.s1.due, "2026-10-30")
  t.eq(m.s2.project, nil)
  t.eq(m.s2.due, nil)
end

-- проект в архиве: цель relation среди строк синхронизации — по её in_trash/archived; задачи — архивные
function T.test_project_archived_by_synced_row()
  local d = snap_input()
  d.rules_by_id = { S = { tasks = true, project = "Проект" } }
  local proj = page("P1", "Старое", in_ds("F"))
  proj.archived = true
  d.rows_by_source.F[3] = proj
  d.rows_by_source.S[1].properties["Проект"] = { type = "relation", relation = { { id = "P1" } } }
  d.rows_by_source.S[2].properties["Проект"] = { type = "relation", relation = { { id = "f1" } } }
  local _, tks = nk.snapshot(d)
  local m = by_id(tks)
  t.eq(m.s1.archived, true, "проект в архиве — задача в архиве")
  t.eq(m.s2.archived, false)
end

-- цели relation нет среди строк синхронизации: пока не архив и без запроса к API
-- (GET /v1/pages для таких — шаг 3b плана, ждёт решения владельца)
function T.test_project_missing_from_sync_is_not_archived_without_fetch()
  local d = snap_input()
  local fetch, calls = counting_fetch({ P9 = { object = "page", id = "P9", in_trash = true } })
  d.fetch = fetch
  d.rules_by_id = { S = { tasks = true, project = "Проект" } }
  d.rows_by_source.S[1].properties["Проект"] = { type = "relation", relation = { { id = "P9" } } }
  local _, tks = nk.snapshot(d)
  t.eq(by_id(tks).s1.archived, false)
  t.eq(#calls, 0)
end

-- закрытость — по правилу status, а не по словам: вариант «Готово» вне группы Complete — незакрыта
function T.test_closed_only_by_group_not_by_word()
  local src = task_source("S", "Дела")
  local g = src.properties["Этап"].status.groups
  g[2].option_ids = { g[3].option_ids[1] } -- «Готово» перенесли в «In progress»
  g[3].option_ids = { "Этап-o4" }
  local rules = nk.default_rules(src)
  t.eq(nk.task(row("r", "Х", "S", { ["Этап"] = st("Готово") }), "S", rules, look()).open, true)
  t.eq(nk.task(row("r", "Х", "S", { ["Этап"] = st("Отменена") }), "S", rules, look()).open, false)
end

-- срез 6: правила классификации — select «сделано/отменено», чекбокс, архив, проект, срок
local function sel(name) return { type = "select", select = { id = "x", name = name } } end
local function cb(v) return { type = "checkbox", checkbox = v } end

local CLS = {
  tasks = true,
  closed_select = { prop = "Тип", options = { ["Сделано"] = true } },
  done_checkbox = "Готово",
  archive_select = { prop = "Тип", options = { ["Архив"] = true } },
  archive_checkbox = "Убрано",
}

function T.test_closed_select_option_closes()
  local function open(v) return nk.task(row("r", "Х", "S", { ["Тип"] = sel(v) }), "S", CLS, look()).open end
  t.eq(open("Сделано"), false)
  t.eq(open("Срочно"), true)
  t.eq(nk.task(row("r", "Х", "S", { ["Тип"] = { type = "select", select = nil } }), "S", CLS, look()).open, true)
end

function T.test_done_checkbox_closes()
  t.eq(nk.task(row("r", "Х", "S", { ["Готово"] = cb(true) }), "S", CLS, look()).open, false)
  t.eq(nk.task(row("r", "Х", "S", { ["Готово"] = cb(false) }), "S", CLS, look()).open, true)
  t.eq(nk.task(row("r", "Х", "S", {}), "S", CLS, look()).open, true, "свойства нет — незакрыта")
end

function T.test_archive_option_archives_task()
  local tk = nk.task(row("r", "Х", "S", { ["Тип"] = sel("Архив") }), "S", CLS, look())
  t.eq(tk.archived, true)
  t.eq(tk.open, true, "архив — не «закрыта»")
  t.eq(nk.task(row("r", "Х", "S", { ["Убрано"] = cb(true) }), "S", CLS, look()).archived, true)
  t.eq(nk.task(row("r", "Х", "S", { ["Тип"] = sel("Срочно") }), "S", CLS, look()).archived, false)
  t.eq(nk.row_archived(row("r", "Х", "S", { ["Тип"] = sel("Архив") }), CLS), true)
  t.eq(nk.row_archived(row("r", "Х", "S", {}), {}), false)
  -- архив по варианту status (модель может так ответить: «Архив» в группе Complete у базы проектов)
  local by_status = { archive_select = { prop = "Этап", options = { ["Архив"] = true } } }
  t.eq(nk.row_archived(row("r", "Х", "S", { ["Этап"] = st("Архив") }), by_status), true)
end

-- м13: status «В работе» (In progress), но отмечен чекбокс «сделано» — закрыта
function T.test_status_open_checkbox_done_is_closed()
  local rules = nk.default_rules(task_source("S", "Дела"))
  rules.done_checkbox = "Готово"
  local tk = nk.task(row("r", "Х", "S", { ["Этап"] = st("В работе"), ["Готово"] = cb(true) }), "S", rules, look())
  t.eq(tk.open, false)
end

function T.test_due_from_rules()
  local r = row("r", "Х", "S", { ["Срок"] = { type = "date", date = { start = "2026-11-01" } },
    ["Тип"] = sel("Срочно") })
  t.eq(nk.task(r, "S", { due = "Срок" }, look()).due, "2026-11-01")
  t.eq(nk.task(r, "S", { due = "Тип" }, look()).due, nil, "свойство не date — срока нет")
  t.eq(nk.task(r, "S", {}, look()).due, nil)
end

-- м6: база проектов — не кандидат, у неё только правило архива; строка проекта в архиве по варианту →
-- задачи кандидата с relation на неё — архивные
function T.test_project_row_archived_archives_its_tasks()
  local d = snap_input()
  local projects = ds("P", "Проекты", WS)
  d.sources[#d.sources + 1] = projects
  d.by_id.P = projects
  local live, old = row("p1", "Ремонт", "P", { ["Состояние"] = sel("Активен") }),
    row("p2", "Переезд", "P", { ["Состояние"] = sel("Архив") })
  d.rows_by_source.P = { live, old }
  d.rules_by_id = {
    S = { tasks = true, project = "Проект" },
    P = { tasks = false, archive_select = { prop = "Состояние", options = { ["Архив"] = true } } },
  }
  d.rows_by_source.S[1].properties["Проект"] = { type = "relation", relation = { { id = "p2" } } }
  d.rows_by_source.S[2].properties["Проект"] = { type = "relation", relation = { { id = "p1" } } }
  local cols, tks = nk.snapshot(d)
  local m = by_id(tks)
  t.eq(m.s1.archived, true, "проект в архиве по варианту")
  t.eq(m.s1.project, "Переезд")
  t.eq(m.s2.archived, false)
  t.eq(m.p1, nil, "строки не-кандидата — не задачи")
  t.eq(by_id(cols).P.task_candidate, false)
end

function T.test_snapshot_marks_model_pick()
  local d = snap_input()
  d.rules_by_id = { S = { tasks = true } }
  d.pick_id = "S"
  local m = by_id((nk.snapshot(d)))
  t.eq(m.S.model_pick, true)
  t.eq(m.F.model_pick, false)
end

-- схема для классификации: только status/select/checkbox/relation/date; базы без status/select/checkbox — nil
function T.test_schema_keeps_only_classifiable_props()
  local src = task_source("S", "Дела")
  src.properties["Тип"] = { id = "t", name = "Тип", type = "select", select = { options = {
    { id = "a", name = "Срочно", color = "red" }, { id = "b", name = "Сделано", color = "green" } } } }
  src.properties["Проект"] = { id = "p", name = "Проект", type = "relation", relation = {} }
  src.properties["Оценка"] = { id = "n", name = "Оценка", type = "number", number = {} }
  local sch = nk.schema(src)
  local names = {}
  for i, p in ipairs(sch.props) do names[i] = p.name .. ":" .. p.type end
  t.eq(table.concat(names, " "), "Проект:relation Тип:select Этап:status", "по имени, без title/number")
  t.eq(table.concat(sch.props[2].options, ","), "Срочно,Сделано")
  t.eq(sch.props[3].groups[3].name, "Complete")
  t.eq(table.concat(sch.props[3].groups[3].options, ","), "Готово,Отменена")
  t.eq(nk.schema(ds("F", "Фильмы")), nil, "без status/select/checkbox — не в классификации")
  local only_rel = ds("R", "Связи")
  only_rel.properties["Проект"] = { type = "relation", relation = {} }
  t.eq(nk.schema(only_rel), nil)
end

-- м8: items и title в хэш не входят; новое свойство или вариант — меняют
function T.test_schema_hash_ignores_items_and_title()
  local function list(title, items, extra_option)
    local src = task_source("S", title)
    if extra_option then
      local s = src.properties["Этап"].status
      s.options[#s.options + 1] = { id = "z", name = "Пауза" }
    end
    local sch = nk.schema(src)
    return { { id = "S", title = title, items = items, depth = 1, props = sch.props } }
  end
  local h = nk.schema_hash(list("Дела", 3))
  t.ok(h:match("^%x%x%x%x%x%x%x%x$"), h)
  t.eq(nk.schema_hash(list("Мои дела", 300)), h, "переименование и новые строки — тот же хэш")
  t.ok(nk.schema_hash(list("Дела", 3, true)) ~= h, "новый вариант — другой хэш")
  local other = list("Дела", 3)
  other[1].id = "S2"
  t.ok(nk.schema_hash(other) ~= h, "другая база — другой хэш")
  t.eq(nk.schema_hash({}), nk.schema_hash({}))
end

t.run(T)
