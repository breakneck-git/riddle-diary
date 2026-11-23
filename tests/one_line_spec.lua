-- Текст в одну строку (str.one_line): одно правило на промпт (prompt.one_line), сравнение названий (tasks.fold),
-- переспрос мира (persona.decode_resolve), имя пишущего (llm.parse, ключ name) и строку лога ошибки модели (app_spec).
-- Правило: пробельные знаки подряд — %s и неразрывный пробел U+00A0 — один пробел, по краям срезаны. Тесты идут через
-- публичные входы. Ключ персонажа (persona.key) — не по этому правилу: он хранится в базе.
local t = require("t")
local json = require("dkjson")
local llm = require("riddle.llm")
local persona = require("riddle.persona")
local prompt = require("riddle.prompt")
local str = require("riddle.str")
local tasks = require("riddle.tasks")

local T = {}

local NBSP = "\194\160"

function T.test_str_one_line_rule()
  t.eq(str.one_line(" a \t\n b\r\n"), "a b", "%s подряд — один пробел, края срезаны")
  t.eq(str.one_line(NBSP .. "a" .. NBSP .. NBSP .. " b" .. NBSP), "a b", "NBSP — тоже пробел")
  t.eq(str.one_line(NBSP), "", "из одних пробелов — пусто")
  t.eq(str.one_line("Том Реддл"), "Том Реддл", "без лишних пробелов не меняется")
  t.eq(str.one_line("\208\160\208\176"), "\208\160\208\176", "кириллица с байтом \\160 внутри буквы — не пробел")
  for _, v in ipairs({ true, {}, false }) do
    t.eq(str.one_line(v), "", "не строка: " .. tostring(v))
  end
end

function T.test_prompt_roll_text_nbsp()
  t.eq(prompt.roll_text("Гарри" .. NBSP .. NBSP .. "пришёл" .. NBSP), "Гарри пришёл")
end

function T.test_prompt_mode_line_nbsp()
  local line = prompt.mode_line("name", false, { { title = "Купить" .. NBSP .. " хлеб" } })
  t.ok(line and line:find("Купить хлеб", 1, true), tostring(line))
end

function T.test_tasks_fold_nbsp()
  t.eq(tasks.fold(" Купить" .. NBSP .. "Хлеб "), "купить хлеб")
end

-- ревью пачки 5: ключ персонажа хранится в базе (personas.key) — NBSP в нём остаётся, как до str.one_line (261a436):
-- иначе персона, сохранённая со строкой с U+00A0, не нашлась бы по ключу
function T.test_persona_key_keeps_nbsp()
  t.eq(persona.key("Том" .. NBSP .. "Реддл"), "том" .. NBSP .. "реддл", "NBSP внутри — не пробел")
  t.eq(persona.key(NBSP .. " Том \t\n Реддл " .. NBSP), NBSP .. " том реддл " .. NBSP, "NBSP по краям остаётся, %s внутри — один")
  t.eq(persona.key("  Том \t Реддл\n"), "том реддл", "%s по краям срезан")
end

function T.test_persona_resolve_ask_nbsp()
  local ask = "So this is the diary of R2-D2" .. NBSP .. NBSP .. "from Star Wars?"
  local obj = { who = "R2-D2", world = "Star Wars", world_named = false, lang = "en", ask = ask }
  local r = persona.decode_resolve("```json\n" .. json.encode(obj) .. "\n```", "R2-D2")
  t.eq(r.state, "confirm")
  t.eq(r.ask, "So this is the diary of R2-D2 from Star Wars?")
end

function T.test_llm_name_nbsp()
  local function name_of(v)
    local body = json.encode({ choices = { { message = { content = json.encode({ read = "r", reply = "x", name = v }) } } } })
    return llm.parse(200, body, true).name
  end
  t.eq(name_of("Гарри" .. NBSP .. "Поттер"), "Гарри Поттер")
  t.eq(name_of(NBSP .. "Гарри" .. NBSP), "Гарри", "NBSP по краям срезан")
  t.eq(name_of(NBSP .. NBSP), nil, "из одних NBSP — не имя")
end

t.run(T)
