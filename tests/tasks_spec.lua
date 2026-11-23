local t = require("t")
local tasks = require("riddle.tasks")

local T = {}

local function coll(id, extra)
  local c = { id = id, title = "К-" .. id, source = "notion", items = 1, task_candidate = true, native_tasks = false,
    depth = 3, model_pick = false }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

local function ids(list)
  local out = {}
  for i, r in ipairs(list) do out[i] = r.id end
  return table.concat(out, " ")
end

-- старшинство: слово пользователя → конфиг → native_tasks → model_pick → меньшая depth;
-- убирая старшее правило, получаем следующее
function T.test_pick_order_user_config_native_model_depth()
  local cs = {
    coll("u", { title = "Мои дела" }),
    coll("c", { title = "Список" }),
    coll("n", { native_tasks = true }),
    coll("m", { model_pick = true }),
    coll("d", { depth = 1 }),
    coll("z", { depth = 2 }),
  }
  local steps = {
    { "мои дела", "c", "u", "user" },
    { nil, "c", "c", "config" },
    { nil, nil, "n", "native" },
  }
  for _, s in ipairs(steps) do
    local c, why = tasks.pick_source(cs, s[1], s[2])
    t.eq(c and c.id, s[3], "выбор " .. s[4])
    t.eq(why, s[4])
  end
  table.remove(cs, 3) -- без native
  local c, why = tasks.pick_source(cs, nil, nil)
  t.eq(c and c.id, "m")
  t.eq(why, "model")
  table.remove(cs, 3) -- без model_pick
  c, why = tasks.pick_source(cs, "", "")
  t.eq(c and c.id, "d", "пустые строки — не указано")
  t.eq(why, "depth")
end

-- native и model_pick — только у кандидатов; среди равных — меньшая depth, затем id
function T.test_pick_ignores_flags_of_non_candidates_and_breaks_ties()
  local cs = {
    coll("b", { depth = 2 }),
    coll("a", { depth = 2 }),
    coll("x", { task_candidate = false, native_tasks = true, model_pick = true, depth = 0 }),
    coll("n2", { native_tasks = true, depth = 5 }),
    coll("n1", { native_tasks = true, depth = 4 }),
  }
  local c, why = tasks.pick_source(cs)
  t.eq(c and c.id, "n1", "из двух native — меньшая depth")
  t.eq(why, "native")
  c, why = tasks.pick_source({ cs[1], cs[2], cs[3] })
  t.eq(c and c.id, "a", "равная depth — по id; не-кандидат с флагами не берётся")
  t.eq(why, "depth")
  c, why = tasks.pick_source({ cs[3] })
  t.eq(c, nil, "без кандидатов — нет базы")
  t.eq(why, "none")
  c, why = tasks.pick_source({})
  t.eq(c, nil)
  t.eq(why, "none")
end

-- слово пользователя старше конфига и может назвать не-кандидата; не нашлось — дальше по старшинству
function T.test_user_word_beats_config_and_may_name_non_candidate()
  local cs = {
    coll("k", { title = "Книга желаний", task_candidate = false, depth = 0 }),
    coll("t", { title = "Задачи", native_tasks = true }),
  }
  local c, why = tasks.pick_source(cs, "книга желаний", "Задачи")
  t.eq(c and c.id, "k")
  t.eq(why, "user")
  c, why = tasks.pick_source(cs, "нет такой", "Книга желаний")
  t.eq(c and c.id, "k", "слово не нашлось — конфиг, тоже любой")
  t.eq(why, "config")
  c, why = tasks.pick_source(cs, "нет такой", "и такой")
  t.eq(c and c.id, "t")
  t.eq(why, "native")
end

-- значение конфига — сначала id, потом название
function T.test_config_value_as_id_or_title()
  local cs = {
    coll("2b1f-aa", { title = "Дела" }),
    coll("Дела", { title = "Другое" }), -- id совпадает с чужим названием: id старше
    coll("q", { title = "Покупки" }),
  }
  local c, why = tasks.pick_source(cs, nil, "2b1f-aa")
  t.eq(c and c.id, "2b1f-aa")
  t.eq(why, "config")
  c = tasks.pick_source(cs, nil, "Дела")
  t.eq(c and c.id, "Дела", "id раньше названия")
  c = tasks.pick_source(cs, nil, "  ПОКУПКИ ")
  t.eq(c and c.id, "q", "название через fold")
  c = tasks.pick_source(cs, "q", nil)
  t.eq(c and c.id, "q", "слово пользователя — тоже id")
end

function T.test_fold()
  t.eq(tasks.fold("  ЗАДАЧИ  на   Неделю "), "задачи на неделю")
  t.eq(tasks.fold("АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"), "абвгдеежзийклмнопрстуфхцчшщъыьэюя")
  t.eq(tasks.fold("ёлка Ёж"), "елка еж")
  t.eq(tasks.fold("To-Do List"), "to-do list")
  t.eq(tasks.fold("\tдела\n"), "дела")
  t.eq(tasks.fold("\194\160Дела\194\160\194\160 дом\194\160"), "дела дом", "NBSP — пробел")
end

-- регистр кириллицы, ё/е, пробелы по краям: одна база
function T.test_match_title_folds_cyrillic_case()
  local cs = { coll("t", { title = "Задачи" }), coll("e", { title = "Ёлки" }) }
  for _, name in ipairs({ "ЗАДАЧИ", "задачи", "Задачи ", "  зАдАчИ" }) do
    local c, err = tasks.match_title(cs, name)
    t.eq(c and c.id, "t", name .. ": " .. tostring(err))
  end
  t.eq((tasks.match_title(cs, "Елки") or {}).id, "e", "ёлки = Елки")
  t.eq((tasks.match_title({ coll("e2", { title = "елки" }) }, "ЁЛКИ") or {}).id, "e2")
end

-- слово модели (поле tasks_source): равенство fold, иначе только целыми словами — «нет» не находит «Интернет-покупки»
-- (ревью: подстрокой match_title молча выбирал эту книгу); несколько — "many", ни одной — "none"
function T.test_match_word_whole_words_only()
  local cs = { coll("i", { title = "Интернет-покупки" }), coll("f", { title = "Фильмы" }), coll("m", { title = "Мои задачи" }) }
  for _, name in ipairs({ "Мои задачи", "мои ЗАДАЧИ", "  Мои  задачи ", "МОИ ЗАДАЧИ" }) do
    t.eq((tasks.match_word(cs, name) or {}).id, "m", name)
  end
  t.eq((tasks.match_word(cs, "интернет-покупки") or {}).id, "i", "точное с дефисом")
  t.eq((tasks.match_word(cs, "покупки") or {}).id, "i", "целое слово названия")
  t.eq((tasks.match_word(cs, "«Фильмы»") or {}).id, "f", "кавычки — не часть слова")
  for _, name in ipairs({ "нет", "net", "задач", "фильм", "мои дела", "" }) do
    local c, why = tasks.match_word(cs, name)
    t.eq(c, nil, name .. ": не найдено")
    t.eq(why, "none", name)
  end
  local two = { coll("a", { title = "Покупки дом" }), coll("b", { title = "Покупки дача" }) }
  local c, why = tasks.match_word(two, "покупки")
  t.eq(c, nil)
  t.eq(why, "many")
  -- match_title (конфиг, слово пользователя) — прежний: подстрока
  t.eq((tasks.match_title(cs, "нет") or {}).id, "i", "match_title не тронут")
end

-- равенство раньше подстроки; несколько — "many", ни одной — "none"
function T.test_match_title_many_and_none()
  local cs = {
    coll("a", { title = "Дела" }),
    coll("b", { title = "Дела по дому" }),
    coll("c", { title = "Дела работы" }),
    coll("f", { title = "Фильмы" }),
  }
  t.eq((tasks.match_title(cs, "дела") or {}).id, "a", "равенство раньше подстроки")
  local c, err = tasks.match_title(cs, "по дому")
  t.eq(c and c.id, "b", "единственная содержит")
  c, err = tasks.match_title(cs, "дела по")
  t.eq(c, nil, "«дела по» содержит «дела» и входит в «дела по дому»")
  t.eq(err, "many")
  c, err = tasks.match_title(cs, "мои фильмы на вечер")
  t.eq(c and c.id, "f", "название внутри слова пользователя")
  c, err = tasks.match_title({ cs[2], cs[3] }, "дела")
  t.eq(c, nil)
  t.eq(err, "many")
  c, err = tasks.match_title(cs, "поездки")
  t.eq(c, nil)
  t.eq(err, "none")
  c, err = tasks.match_title(cs, "  ")
  t.eq(c, nil, "пустое слово — ничего")
  t.eq(err, "none")
  c, err = tasks.match_title({ coll("x", { title = "Дела" }), coll("y", { title = "ДЕЛА" }) }, "дела")
  t.eq(c, nil, "два равных названия — неоднозначно")
  t.eq(err, "many")
  c, err = tasks.match_title({ coll("e", { title = "" }), coll("f", { title = "Фильмы" }) }, "фильмы")
  t.eq(c and c.id, "f", "пустое название не содержится во всём")
end

-- поиск подстроки — обычный текст, не шаблон Lua: «-», «(», «%», «.» в названии
function T.test_match_title_plain_find_with_magic_chars()
  local cs = {
    coll("a", { title = "To-Do (2026) 100%" }),
    coll("b", { title = "a.b" }),
  }
  local c, err = tasks.match_title(cs, "to-do (2026)")
  t.eq(c and c.id, "a", tostring(err))
  c, err = tasks.match_title(cs, "100%")
  t.eq(c and c.id, "a", tostring(err))
  c, err = tasks.match_title(cs, "(")
  t.eq(c and c.id, "a", tostring(err))
  c, err = tasks.match_title(cs, "axb")
  t.eq(c, nil, "«.» — не любой символ")
  t.eq(err, "none")
  c, err = tasks.match_title(cs, "мой список to-do (2026) 100% на год")
  t.eq(c and c.id, "a", "название внутри слова: " .. tostring(err))
end

-- в extra NONE — поле nil (pairs пропускает nil)
local NONE = {}
local function task(id, extra)
  local r = { id = id, collection_id = "c", title = "З-" .. id, open = true, archived = false,
    edited = "2026-10-20T10:00:00.000Z" }
  for k, v in pairs(extra or {}) do r[k] = v ~= NONE and v or nil end
  return r
end

function T.test_open_list_drops_closed_archived_untitled()
  local list = tasks.open_list({
    task("ok"),
    task("closed", { open = false }),
    task("arch", { archived = true }),
    task("both", { open = false, archived = true }),
    task("empty", { title = "" }),
    task("blank", { title = "  \t" }),
    task("nil", { title = NONE }),
  })
  t.eq(ids(list), "ok")
end

-- по due возр. (без срока — после), затем edited убыв., затем id
function T.test_open_list_order_due_then_edited()
  local list = tasks.open_list({
    task("nodue_old", { edited = "2026-10-01T00:00:00.000Z" }),
    task("nodue_new", { edited = "2026-10-24T00:00:00.000Z" }),
    task("due_late", { due = "2026-12-01" }),
    task("due_soon_b", { due = "2026-11-01", edited = "2026-10-02T00:00:00.000Z" }),
    task("due_soon_a", { due = "2026-11-01", edited = "2026-10-02T00:00:00.000Z" }),
    task("due_soon_new", { due = "2026-11-01", edited = "2026-10-23T00:00:00.000Z" }),
    task("emptydue", { due = "", edited = "2026-10-24T00:00:00.000Z" }),
    task("noedit", { edited = NONE }),
  })
  t.eq(ids(list), "due_soon_new due_soon_a due_soon_b due_late emptydue nodue_new nodue_old noedit")
end

function T.test_block_caps_at_30_and_counts_total()
  t.eq(tasks.LIMIT, 30)
  local rows = {}
  for i = 1, 45 do rows[i] = task(string.format("id%02d", i), { project = i == 1 and "Дом" or nil,
    due = i == 1 and "2026-11-01" or nil }) end
  local b = tasks.block(tasks.open_list(rows))
  t.eq(#b.items, 30)
  t.eq(b.total, 45)
  t.eq(b.items[1].label, "t1")
  t.eq(b.items[1].id, "id01")
  t.eq(b.items[1].title, "З-id01")
  t.eq(b.items[1].due, "2026-11-01")
  t.eq(b.items[1].project, "Дом")
  t.eq(b.items[30].label, "t30")
  t.eq(b.by_label.t1, "id01")
  t.eq(b.by_label.t30, b.items[30].id)
  t.eq(b.by_label.t31, nil)
  local n = 0
  for _ in pairs(b.by_label) do n = n + 1 end
  t.eq(n, 30)
  local empty = tasks.block({})
  t.eq(#empty.items, 0)
  t.eq(empty.total, 0)
end

-- ядро знает только общий формат: модули источника не подключаются
function T.test_core_requires_no_source_module()
  local f = assert(io.open("plugin/riddlediary.koplugin/riddle/tasks.lua", "rb"))
  local src = f:read("*a")
  f:close()
  for _, name in ipairs({ "riddle.notion", "riddle.sync", "riddle.classify" }) do
    t.ok(not src:find(name, 1, true), "tasks.lua упоминает " .. name)
  end
  for name in pairs(package.loaded) do
    t.ok(not (name:find("^riddle%.notion") or name == "riddle.sync" or name == "riddle.classify"),
      "загружен " .. name)
  end
end

t.run(T)
