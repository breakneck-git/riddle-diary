local t = require("t")
local texts = require("riddle.texts")
local seal = require("riddle.seal")

local V = { "salandusa", "шаландуша", "шаланда" }

-- подсказки приходят из конфига (cfg.hints); здесь — подставные, порядок выдачи — порядок списка
local HINTS = { "ПОДСКАЗКА-1\nвторая строка", "ПОДСКАЗКА-2" }

local function new_seal()
  return seal.new(V, 3, HINTS)
end

local T = {}

function T.test_match_exact()
  t.ok(seal.matches("Salandusa", V))
end

function T.test_match_case_spaces()
  t.ok(seal.matches("SALAN dusa", V), "пробел и регистр")
  t.ok(seal.matches("Шалан\nдуша", V), "перенос строки")
end

function T.test_match_homoglyphs()
  t.ok(seal.matches("Sаlаndusа", V), "кириллические а в латинском слове")
  t.ok(seal.matches("Шaлaндушa", V), "латинские a в кириллическом слове")
end

function T.test_match_typos()
  t.ok(seal.matches("Salandsa", V))
  t.ok(seal.matches("Salendusa", V))
  t.ok(seal.matches("Шаландушша", V))
  t.ok(not seal.matches("Шасточка", V), "Шасточка")
  t.ok(not seal.matches("Salender ois", V), "Salender ois")
end

function T.test_match_short_variant_strict()
  -- «шаланда» (7 символов): допуск ≤1; длинные варианты (8+) — ≤2
  t.ok(not seal.matches("Шеландолский", V), "длинное слово с «шаланд» внутри")
  t.ok(seal.matches("шаландa", V), "лат. a в «шаланда»")
  t.ok(seal.matches("шалнда", V), "одна пропущенная буква в «шаланда»")
  t.ok(seal.matches("Salendusa", V))
  t.ok(seal.matches("Salandsa", V))
  t.ok(seal.matches("Шаландушша", V))
  t.ok(seal.matches("Salanddsa", V), "одна замена в длинном варианте")
  t.ok(seal.matches("Salndsa", V), "две правки в длинном варианте (допуск 2)")
end

-- почерк: короткое слово читается с двумя правками — буква спутана, буква потеряна («шаланда» → «шабана»),
-- расстояние 2. Слово целиком длиной 6–8 букв («шаланда» ±1) принимается с допуском 2;
-- подстрока внутри длинного слова — по-прежнему только с допуском 1.
function T.test_match_short_variant_whole_word_two_edits()
  for _, w in ipairs({ "шабана", "Шабана", "шабонда", "шобанда", "шаланаа", "шалонда" }) do
    t.ok(seal.matches(w, V), w)
  end
  t.ok(seal.matches("Моё слово шабана!", V), "в фразе")
  -- те же две правки у обычных слов, структурно от «шабана» не отличить: принято, печать откроется
  t.ok(seal.matches("Шалина", V), "Шалина: ш-а-л-и-н-а ↔ ш-а-л-а-н-д-а, 2 правки")
  t.ok(seal.matches("Лашанда", V), "Лашанда: перестановка л/ш, 2 правки")
end

function T.test_match_short_variant_two_edits_not_for_substrings_or_short_words()
  for _, w in ipairs({ "Шеландолский", "Ланда", "ашша ланда", "Шалка", "Шалаш", "Ралнина", "Шандыв",
    "Я пришла", "Привет, дневник", "Сшала дане" }) do
    t.ok(not seal.matches(w, V), w)
  end
end

function T.test_match_in_phrase()
  t.ok(seal.matches("Моё слово — Salandusa!", V))
  t.ok(seal.matches("шаланда плывёт к берегу", V))
end

function T.test_normalize()
  t.eq(seal.normalize("SALAN dusa!", true), "salandusa", "латиница: регистр, пробел, пунктуация")
  t.eq(seal.normalize("Шалан\nдуша"), "шаландуша", "кириллица: перенос строки")
  t.eq(seal.normalize("Ab"), seal.normalize("Аb"), "латинская a = кириллическая а (по умолчанию)")
  t.eq(seal.normalize("Ab", true), seal.normalize("Аb", true), "то же при latin=true")
  t.eq(seal.normalize("Шаландуша", true), "шaлahдyшa", "кириллические двойники → латиница")
  t.eq(seal.normalize("Salandusa"), "sаlаndusа", "латинские двойники → кириллица")
  t.eq(seal.normalize(" ? "), "", "пунктуация отброшена")
end

function T.test_unreadable()
  local s = new_seal()
  t.eq(s:feed("?").kind, "unreadable")
  t.eq(s:feed("?").kind, "unreadable")
  t.eq(s:feed("кто ты").kind, "refuse")
  t.eq(s:feed("кто ты").kind, "refuse")
  t.eq(s:feed("кто ты").kind, "hint", "счётчик не рос от нераспознанного")
end

function T.test_hint_every_third()
  local s = new_seal()
  local kinds = {}
  for i = 1, 3 do kinds[i] = s:feed("кто ты") end
  t.eq(kinds[1].kind, "refuse")
  t.eq(kinds[2].kind, "refuse")
  t.eq(kinds[3].kind, "hint")
  t.eq(kinds[3].hint, HINTS[1], "3-я неудача — первая подсказка конфига")
  for _ = 1, 2 do s:feed("кто ты") end
  t.eq(s:feed("кто ты").hint, HINTS[2], "6-я неудача — вторая")
  for _ = 1, 2 do s:feed("кто ты") end
  t.eq(s:feed("кто ты").hint, HINTS[1], "9-я — снова первая, по кругу")
end

-- в конфиге подсказок нет — каждая неудача просто отказ, подсказки не выдумываются
function T.test_no_hints_in_config_means_refuse()
  for _, hints in ipairs({ {}, false }) do
    local s = seal.new(V, 3, hints or nil)
    for i = 1, 6 do t.eq(s:feed("кто ты").kind, "refuse", "неудача " .. i) end
  end
end

function T.test_unlock()
  local s = new_seal()
  t.ok(not s.open)
  local r = s:feed("Salandusa")
  t.eq(r.kind, "unlock")
  t.eq(r.welcome, nil, "приветствие выбирает контроллер (набор персоны), не печать")
  t.eq(s.open, true)
  t.eq(s:feed("Мне грустно"), nil, "при открытой печати feed — не дело печати")
end

function T.test_lock_resets()
  local s = new_seal()
  s:feed("кто ты")
  s:feed("кто ты")
  s:lock()
  t.eq(s:feed("кто ты").kind, "refuse")
  s:feed("кто ты")
  t.eq(s:feed("кто ты").hint, HINTS[1], "номер подсказки тоже сброшен")
end

function T.test_lock_resets_hint_index()
  local s = new_seal()
  s:feed("кто ты")
  s:feed("кто ты")
  t.eq(s:feed("кто ты").hint, HINTS[1], "подсказка выдана до lock")
  s:lock()
  s:feed("кто ты")
  s:feed("кто ты")
  t.eq(s:feed("кто ты").hint, HINTS[1], "после lock подсказки снова с первой")
end

function T.test_match_phrases_no_false_positive()
  -- короткий вариант («шаланда») ищется только внутри одного слова,
  -- склейка слов через пробел/пунктуацию его не снимает
  for _, phrase in ipairs({
    "Сшала дане", "Сшала нам!", "Сшала. Да!", "Сшала, надоешо",
    "Гшала на стоше", "Шала над лушканом", "ша-ша, ланна", "Ша Ландея",
  }) do
    t.ok(not seal.matches(phrase, V), phrase)
  end
end

function T.test_match_short_variant_forms()
  for _, w in ipairs({ "шалнда", "шаланду", "шаландa", "Шаланда плывёт к берегу" }) do
    t.ok(seal.matches(w, V), w)
  end
end

function T.test_match_across_words_only_whole_words()
  -- окно через границу слов — склейка целых слов, а не кусок «хвост + голова»
  for _, phrase in ipairs({ "гшала над гшалами", "ашша ланда", "Sala and sala" }) do
    t.ok(not seal.matches(phrase, V), phrase)
  end
  for _, phrase in ipairs({ "шалан да", "Salan dusa", "Шалан\nдуша", "шалан-\nда", "Я вижу шаланду" }) do
    t.ok(seal.matches(phrase, V), phrase)
  end
end

function T.test_match_short_variant_across_words_exact_only()
  -- короткий вариант («шаланда», ≤7): склейка ≥2 слов — только точное совпадение, без правок
  for _, phrase in ipairs({ "Шала на скшоне", "Шала на", "шала да" }) do
    t.ok(not seal.matches(phrase, V), phrase)
  end
  for _, phrase in ipairs({ "шалан да", "Ша-ланда", "Шалан-да" }) do
    t.ok(seal.matches(phrase, V), phrase)
  end
end

function T.test_match_long_variant_across_words()
  -- вариант 8+ символов: склейка через пробел/перенос разрешена
  t.ok(seal.matches("Salan dusa", V))
  t.ok(seal.matches("Шалан\nдуша", V))
  t.ok(seal.matches("Salan-dusa", V))
end

function T.test_lock_closes()
  local s = new_seal()
  s:feed("Salandusa")
  s:lock()
  t.eq(s.open, false)
  t.eq(s:feed("кто ты").kind, "refuse")
end

function T.test_texts_verbatim()
  -- 12 из спеки — первыми (test_texts_match_spec_bytewise), дальше пул добран до 30+ (texts_spec)
  t.ok(#texts.welcomes >= 12, "приветствий меньше, чем в спеке: " .. #texts.welcomes)
  t.eq(texts.invitation, "Кто касается моих страниц?")
  t.eq(texts.welcomes[1], "Печать спадает… С возвращением.")
  t.eq(texts.welcomes[12], "Ждал тебя. Что у тебя для меня сегодня?")
  t.eq(texts.hints, nil, "подсказки печати — в конфиге, не в коде")
end

-- разбирает раздел «Тексты» спеки: нумерованные пункты под заголовком, пока не пошёл следующий блок
local function spec_list(spec, header)
  local list, on = {}, false
  for line in spec:gmatch("[^\n]*") do
    if line:find(header, 1, true) then
      on = true
    elseif on then
      local item = line:match("^%d+%. (.+)$")
      if item then
        list[#list + 1] = item
      elseif #list > 0 and line:match("%S") then
        break
      end
    end
  end
  return list
end

function T.test_texts_match_spec_bytewise()
  local f = assert(io.open("docs/superpowers/specs/2026-10-22-riddle-diary-design.md", "rb"))
  local spec = f:read("*a")
  f:close()
  local welcomes = spec_list(spec, "**Приветствия после снятия печати")
  t.eq(#welcomes, 12, "приветствий в спеке")
  for i = 1, 12 do t.eq(texts.welcomes[i], welcomes[i], "приветствие " .. i) end
  -- приглашение: *«Кто касается моих страниц?»*
  t.eq(texts.invitation, spec:match("%*«(.-)»%*"), "приглашение")
end

function T.test_texts_sleepy_unreadable()
  t.ok(#texts.sleepy >= 4)
  t.ok(#texts.unreadable >= 4)
  t.eq(texts.sleepy[1], "Чернила густеют… вернись ко мне чуть позже.")
  t.eq(texts.unreadable[1], "Чернила расплылись… напиши ещё раз, медленнее.")
end

t.run(T)
