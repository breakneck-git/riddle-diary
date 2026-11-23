-- Текст документа знания из страницы Notion: свойства по типам (developers.notion.com/reference/page-property-values).
local t = require("t")
local nt = require("riddle.notion_text")

local function rt(s) return { { type = "text", plain_text = s } } end

-- страница с одним свойством name = { type = typ, [typ] = value } рядом со свойством-title
local function page_with(typ, value)
  return {
    object = "page",
    properties = {
      ["Название"] = { id = "title", type = "title", title = rt("Дюна") },
      ["П"] = { id = "p1", type = typ, [typ] = value },
    },
  }
end

-- значение свойства «П» или nil, если пропущено
local function prop(typ, value, titles)
  for _, kv in ipairs(nt.props(page_with(typ, value), titles or {})) do
    if kv[1] == "П" then return kv[2] end
  end
end

local tests = {}

function tests.test_title()
  local items = nt.props(page_with("number", 1), {})
  t.eq(items[1][1], "Название", "свойство-title первым")
  t.eq(items[1][2], "Дюна")
  t.eq(nt.title(page_with("number", 1)), "Дюна")
end

function tests.test_title_of_data_source_and_multi_segment()
  t.eq(nt.title({ object = "data_source", title = { { plain_text = "Фил" }, { plain_text = "ьмы" } } }), "Фильмы")
  t.eq(nt.title({ object = "page", properties = {} }), "")
end

-- data source в ответе search несёт схему: у свойства-title там "title": {} — название берётся из obj.title
function tests.test_title_of_data_source_with_schema()
  local ds = {
    object = "data_source", id = "ds1",
    title = { { type = "text", plain_text = "Фильмы" } },
    properties = {
      ["Название"] = { id = "title", name = "Название", type = "title", title = {} },
      ["Оценка"] = { id = "abc", name = "Оценка", type = "number", number = { format = "number" } },
    },
  }
  t.eq(nt.title(ds), "Фильмы")
  t.eq(nt.title({ object = "database", title = rt("База"), properties = { x = { type = "title", title = {} } } }),
    "База")
end

function tests.test_rich_text()
  t.eq(prop("rich_text", { { plain_text = "раз " }, { plain_text = "два" } }), "раз два")
end

function tests.test_number()
  t.eq(prop("number", 9), "9")
  t.eq(prop("number", 9.5), "9.5")
  t.eq(prop("number", nil), nil, "пустое число пропущено")
end

function tests.test_select()
  t.eq(prop("select", { name = "Фантастика" }), "Фантастика")
  t.eq(prop("select", nil), nil)
end

function tests.test_multi_select()
  t.eq(prop("multi_select", { { name = "а" }, { name = "б" } }), "а, б")
  t.eq(prop("multi_select", {}), nil)
end

function tests.test_status()
  t.eq(prop("status", { name = "Готово" }), "Готово")
end

function tests.test_date()
  t.eq(prop("date", { start = "2026-10-25" }), "2026-10-25")
  t.eq(prop("date", { start = "2026-10-25", ["end"] = "2026-10-27" }), "2026-10-25 – 2026-10-27")
end

function tests.test_checkbox()
  t.eq(prop("checkbox", true), "да")
  t.eq(prop("checkbox", false), "нет")
end

function tests.test_url()
  t.eq(prop("url", "https://x.test"), "https://x.test")
end

function tests.test_email()
  t.eq(prop("email", "a@b.test"), "a@b.test")
end

function tests.test_phone_number()
  t.eq(prop("phone_number", "+7 900"), "+7 900")
end

function tests.test_formula()
  t.eq(prop("formula", { type = "string", string = "строка" }), "строка")
  t.eq(prop("formula", { type = "number", number = 3 }), "3")
  t.eq(prop("formula", { type = "boolean", boolean = true }), "да")
  t.eq(prop("formula", { type = "date", date = { start = "2026-01-01" } }), "2026-01-01")
  t.eq(prop("formula", { type = "number", number = nil }), nil, "пустая формула пропущена")
end

function tests.test_rollup()
  t.eq(prop("rollup", { type = "number", number = 12, ["function"] = "sum" }), "12")
  t.eq(prop("rollup", { type = "date", date = { start = "2026-02-02" } }), "2026-02-02")
  t.eq(prop("rollup", { type = "array", array = {
    { type = "title", title = rt("Один") }, { type = "number", number = 2 }, { type = "button", button = {} },
  } }), "Один, 2")
  t.eq(prop("rollup", { type = "unsupported", unsupported = {} }), nil)
end

function tests.test_relation()
  local titles = { r1 = "Вильнёв", r2 = "Херберт" }
  t.eq(prop("relation", { { id = "r1" }, { id = "zz" }, { id = "r2" } }, titles), "Вильнёв, Херберт",
    "неизвестный id пропущен")
  t.eq(prop("relation", { { id = "zz" } }, titles), nil)
end

function tests.test_people()
  t.eq(prop("people", { { object = "user", id = "u1", name = "Аня" }, { object = "user", id = "u2" } }), "Аня",
    "без name — пропущен")
end

function tests.test_files()
  t.eq(prop("files", { { name = "a.pdf", type = "file", file = { url = "https://s3.test/x" } } }), "a.pdf")
end

function tests.test_unique_id()
  t.eq(prop("unique_id", { prefix = "TASK", number = 12 }), "TASK-12")
  t.eq(prop("unique_id", { prefix = nil, number = 7 }), "7")
end

function tests.test_unknown_property_type_skipped()
  t.eq(prop("button", {}), nil)
  t.eq(prop("verification", { state = "verified" }), nil)
  t.eq(prop("future_type", { anything = "x" }), nil)
  local items = nt.props(page_with("future_type", { a = 1 }), {})
  t.eq(#items, 1, "осталось только название")
end

function tests.test_props_sorted_by_name_after_title()
  local page = { properties = {
    ["Я"] = { type = "number", number = 1 },
    ["Б"] = { type = "number", number = 2 },
    ["Имя"] = { type = "title", title = rt("Т") },
    ["А"] = { type = "number", number = 3 },
  } }
  local names = {}
  for _, kv in ipairs(nt.props(page, {})) do names[#names + 1] = kv[1] end
  t.eq(table.concat(names, ","), "Имя,А,Б,Я")
end

function tests.test_row_text_format()
  local page = { properties = {
    ["Название"] = { type = "title", title = rt("Дюна") },
    ["Оценка"] = { type = "number", number = 9 },
  } }
  t.eq(nt.doc("Фильмы", page, "тело", {}), "Фильмы\nНазвание: Дюна\nОценка: 9\n\nтело")
end

function tests.test_row_without_body()
  local page = { properties = { ["Название"] = { type = "title", title = rt("Дюна") } } }
  t.eq(nt.doc("Фильмы", page, "", {}), "Фильмы\nНазвание: Дюна")
end

function tests.test_page_outside_database()
  local page = { properties = { title = { type = "title", title = rt("Заметки") } } }
  t.eq(nt.doc(nil, page, "тело", {}), "Заметки\n\nтело")
  t.eq(nt.doc(nil, page, "", {}), "Заметки")
end

function tests.test_page_without_properties_does_not_crash()
  t.eq(nt.doc(nil, { object = "page" }, "тело", {}), "тело", "без названия — только тело")
  t.eq(#nt.props({}, {}), 0)
end

t.run(tests)
