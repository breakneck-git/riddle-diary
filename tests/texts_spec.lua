local t = require("t")
local stand = require("seal_stand")
local texts = require("riddle.texts")
local controller = require("riddle.controller")

local T = {}

-- пулы фраз texts (texts.SETS — их описание для генерации; SETS, FORBIDDEN, INVITATION, neutral, NEUTRAL_FOR — не пулы)
local POOLS = { "greetings", "welcomes", "sleepy", "fail_offline", "fail_slow", "fail_limit", "fail_daily", "fail_other",
  "unreadable", "thinking", "busy", "interrupted", "tasks_source_unclear" }

-- имя -> список: все пулы и строка-приглашение (как одна фраза)
local function each_text()
  local out = { invitation = { texts.invitation } }
  for _, name in ipairs(POOLS) do out[name] = texts[name] end
  return pairs(out)
end

local SIZE = 30
local MAX_CPS = 70
local FORBIDDEN = texts.FORBIDDEN.ru

local UPPER = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
local LOWER = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
local TO_LOWER = {}
do
  local up, lo = {}, {}
  for ch in UPPER:gmatch("[\208\209][\128-\191]") do up[#up + 1] = ch end
  for ch in LOWER:gmatch("[\208\209][\128-\191]") do lo[#lo + 1] = ch end
  for i = 1, #up do TO_LOWER[up[i]] = lo[i] end
end

local function lower(s)
  return (s:lower():gsub("[\208\209][\128-\191]", function(ch) return TO_LOWER[ch] or ch end))
end

local function cps(s)
  return select(2, s:gsub("[^\128-\191]", ""))
end

local function check_list(name)
  local list = texts[name]
  t.ok(#list >= SIZE, name .. ": не меньше " .. SIZE .. ", а не " .. #list)
  local seen = {}
  for i, s in ipairs(list) do
    t.ok(not seen[s], name .. ": повтор #" .. i .. ": " .. s)
    seen[s] = true
    t.ok(cps(s) <= MAX_CPS, name .. ": длиннее " .. MAX_CPS .. " (" .. cps(s) .. "): " .. s)
    t.ok(not s:find("[\240-\247]"), name .. ": эмодзи: " .. s)
    local low = lower(s)
    for _, w in ipairs(FORBIDDEN) do
      t.ok(not low:find(w, 1, true), name .. ": запрещённое «" .. w .. "»: " .. s)
    end
  end
end

function T.test_lower_handles_cyrillic()
  t.eq(lower("ШАЛАНДА Ёж Salandusa"), "шаланда ёж salandusa")
end

function T.test_sleepy_30_unique_short_clean()
  check_list("sleepy")
end

function T.test_unreadable_30_unique_short_clean()
  check_list("unreadable")
end

function T.test_sleepy_and_unreadable_do_not_overlap()
  local seen = {}
  for _, s in ipairs(texts.sleepy) do seen[s] = true end
  for _, s in ipairs(texts.unreadable) do t.ok(not seen[s], "в обоих списках: " .. s) end
end

function T.test_old_phrases_stay_first()
  t.eq(texts.sleepy[1], "Чернила густеют… вернись ко мне чуть позже.")
  t.eq(texts.sleepy[4], "Тени сгустились над чернилами… вернись ко мне позже.")
  t.eq(texts.unreadable[1], "Чернила расплылись… напиши ещё раз, медленнее.")
  t.eq(texts.unreadable[4], "Буквы ускользнули от меня… напиши снова, медленнее.")
end

-- переспрос, когда слово о книге дел не нашло книгу или нашло несколько: как unreadable, одно предложение, без
-- латиницы и без слов о том, откуда книги
function T.test_tasks_source_unclear_pool_clean()
  check_list("tasks_source_unclear")
  for _, s in ipairs(texts.tasks_source_unclear) do
    t.ok(not s:find("%a"), "латиница: " .. s)
    t.ok(not s:sub(1, -2):find("[%.!?]"), "больше одного предложения: " .. s)
    local low = lower(s)
    for _, w in ipairs({ "баз", "notion", "таблиц", "статус", "поле" }) do
      t.ok(not low:find(w, 1, true), "«" .. w .. "»: " .. s)
    end
  end
end

-- _pick: мешок без повторов ---------------------------------------------------

-- детерминированный ГПСЧ: fn(n) -> 1..n
local function lcg(seed)
  local x = seed
  return function(n)
    x = (x * 1103515245 + 12345) % 2147483648
    return x % n + 1
  end
end

local RANDOMS = {
  lcg = function() return lcg(42) end,
  first = function() return function() return 1 end end,
  last = function() return function(n) return n end end,
}

local function ctrl(random)
  return controller.new({ cfg = { seal = stand.none() }, random = random })
end

local LISTS = { "sleepy", "unreadable", "welcomes" }

function T.test_pick_shows_every_phrase_once_per_round()
  for rname, mk in pairs(RANDOMS) do
    for _, lname in ipairs(LISTS) do
      local list, c = texts[lname], ctrl(mk())
      for round = 1, 3 do
        local count = {}
        for _ = 1, #list do
          local s = c:_pick(list)
          count[s] = (count[s] or 0) + 1
        end
        for _, s in ipairs(list) do
          t.eq(count[s], 1, rname .. "/" .. lname .. " круг " .. round .. ": " .. s)
        end
      end
    end
  end
end

function T.test_pick_never_repeats_in_a_row()
  for rname, mk in pairs(RANDOMS) do
    for _, lname in ipairs(LISTS) do
      local list, c = texts[lname], ctrl(mk())
      local prev
      for i = 1, 1000 do
        local s = c:_pick(list)
        t.ok(s ~= prev, rname .. "/" .. lname .. " подряд на шаге " .. i .. ": " .. s)
        prev = s
      end
    end
  end
end

function T.test_pick_keeps_separate_bag_per_list()
  local c = ctrl(lcg(7))
  local count = {}
  for _ = 1, #texts.sleepy do
    local s = c:_pick(texts.sleepy)
    count[s] = (count[s] or 0) + 1
    c:_pick(texts.unreadable)
  end
  for _, s in ipairs(texts.sleepy) do t.eq(count[s], 1, s) end
end

function T.test_pick_single_element_list()
  local c = ctrl(lcg(1))
  t.eq(c:_pick({ "один" }), "один")
  t.eq(c:_pick({ "один" }), "один")
end

-- приветствие после печати тоже идёт через мешок
function T.test_welcome_not_repeated_on_next_unlock()
  local script = {}
  local c = controller.new({
    cfg = { seal = stand.key() },
    random = function() return 1 end,
    llm_call = function() return table.remove(script, 1) end,
    read_file = function() return "png" end,
    b64 = function(b) return b end,
    remove = function() end,
    now = function() return 0 end,
  })
  local w1 = c:seal_toggle()
  c:seal_toggle() -- ключ закрыл печать
  local w2 = c:seal_toggle()
  t.eq(w1, texts.welcomes[1])
  t.ok(w1 ~= w2, "второе приветствие другое: " .. w2)
end

-- понятные сбои голосом дневника (решение владельца 2026-10-24): своя причина — свой пул от SIZE фраз
local FAIL_POOLS = { "fail_offline", "fail_slow", "fail_limit", "fail_daily", "fail_other" }

function T.test_fail_pools_short_clean_unique()
  local seen = {}
  for _, name in ipairs({ "sleepy", "unreadable" }) do
    for _, s in ipairs(texts[name]) do seen[s] = name end
  end
  for _, name in ipairs(FAIL_POOLS) do
    local list = texts[name]
    t.ok(type(list) == "table", name .. ": пула нет")
    t.ok(#list >= SIZE, name .. ": не меньше " .. SIZE .. " фраз, а не " .. #list)
    for _, s in ipairs(list) do
      t.ok(not seen[s], name .. ": уже в " .. tostring(seen[s]) .. ": " .. s)
      seen[s] = name
      t.ok(cps(s) <= MAX_CPS, name .. ": длиннее " .. MAX_CPS .. " (" .. cps(s) .. "): " .. s)
      local low = lower(s)
      for _, w in ipairs(FORBIDDEN) do
        t.ok(not low:find(w, 1, true), name .. ": запрещённое «" .. w .. "»: " .. s)
      end
      t.ok(not low:find("лимит", 1, true), name .. ": «лимит»: " .. s)
      -- «миры» — образ ивента 2026-10-23; голос дневника — чернила, нить, страницы
      t.ok(not low:find("мир", 1, true), name .. ": «мир»: " .. s)
    end
  end
end

-- фраза-раздумье (ответ дольше ponder_s) и отказ на запись во время раздумья: от SIZE фраз, одно
-- предложение, без латиницы и эмодзи, не пересекаются с другими пулами
function T.test_thinking_and_busy_pools()
  local seen = {}
  for name, v in each_text() do
    if name ~= "thinking" and name ~= "busy" then
      for _, s in ipairs(v) do seen[s] = name end
    end
  end
  for _, name in ipairs({ "thinking", "busy" }) do
    local list = texts[name]
    t.ok(type(list) == "table", name .. ": пула нет")
    t.ok(#list >= SIZE, name .. ": не меньше " .. SIZE .. " фраз, а не " .. #list)
    for _, s in ipairs(list) do
      t.ok(not seen[s], name .. ": уже в " .. tostring(seen[s]) .. ": " .. s)
      seen[s] = name
      t.ok(cps(s) <= MAX_CPS, name .. ": длиннее " .. MAX_CPS .. " (" .. cps(s) .. "): " .. s)
      t.ok(not s:find("[\240-\247]"), name .. ": эмодзи: " .. s)
      t.ok(not s:find("%a"), name .. ": латиница: " .. s)
      -- одно предложение: точка, «!» или «?» — только в конце
      t.ok(not s:sub(1, -2):find("[%.!?]"), name .. ": больше одного предложения: " .. s)
      local low = lower(s)
      for _, w in ipairs(FORBIDDEN) do
        t.ok(not low:find(w, 1, true), name .. ": запрещённое «" .. w .. "»: " .. s)
      end
    end
  end
end

-- реплика на перебивание (перо перебило ответ, пока он проявлялся или держался): от SIZE фраз,
-- одно-два предложения, не пересекаются с другими пулами
function T.test_interrupted_pool()
  local list = texts.interrupted
  t.ok(type(list) == "table", "пула interrupted нет")
  t.ok(#list >= SIZE, "не меньше " .. SIZE .. " фраз, а не " .. #list)
  local seen = {}
  for name, v in each_text() do
    if name ~= "interrupted" then
      for _, s in ipairs(v) do seen[s] = name end
    end
  end
  for _, s in ipairs(list) do
    t.ok(not seen[s], "interrupted: уже в " .. tostring(seen[s]) .. ": " .. s)
    seen[s] = "interrupted"
    t.ok(cps(s) <= 90, "interrupted: длиннее 90 (" .. cps(s) .. "): " .. s)
    t.ok(not s:find("[\240-\247]"), "interrupted: эмодзи: " .. s)
    t.ok(not s:find("%a"), "interrupted: латиница: " .. s)
    local _, ends = s:sub(1, -2):gsub("[%.!?]%s", "")
    t.ok(ends <= 1, "interrupted: больше двух предложений: " .. s)
    local low = lower(s)
    for _, w in ipairs(FORBIDDEN) do
      t.ok(not low:find(w, 1, true), "interrupted: запрещённое «" .. w .. "»: " .. s)
    end
  end
end

function T.test_controller_pick_draws_from_list()
  local c = ctrl(function() return 1 end)
  local s = c:pick(texts.thinking)
  local found = false
  for _, x in ipairs(texts.thinking) do if x == s then found = true end end
  t.ok(found, tostring(s))
end

-- печати нет: на чистой странице при открытии и после сна — приветствие Тома Реддла вместо
-- «Кто касается моих страниц?» (владелец 2026-10-25: «пропало приветствие, снова просто белый экран»)
function T.test_greetings_pool()
  local list = texts.greetings
  t.ok(type(list) == "table", "пула greetings нет")
  t.ok(#list >= SIZE, "не меньше " .. SIZE .. " приветствий, а не " .. #list)
  local seen = {}
  for name, v in each_text() do
    if name ~= "greetings" then
      for _, s in ipairs(v) do seen[s] = name end
    end
  end
  for _, s in ipairs(list) do
    t.ok(not seen[s], "уже в " .. tostring(seen[s]) .. ": " .. s)
    seen[s] = "greetings"
    t.ok(cps(s) <= MAX_CPS, "длиннее " .. MAX_CPS .. " (" .. cps(s) .. "): " .. s)
    t.ok(not s:find("[\240-\247]"), "эмодзи: " .. s)
    t.ok(not s:find("%a"), "латиница: " .. s)
    -- понятно, что делать: приветствие зовёт писать
    local low = lower(s)
    t.ok(low:find("пиши", 1, true) or low:find("напиш", 1, true) or low:find("расскажи", 1, true),
      "не зовёт писать: " .. s)
  end
end

-- без печати дневник не говорит о печати, слове и загадке: welcomes и invitation — только с печатью
local SEAL_WORDS = { "печат", "заветн", "загадк", "замок", "замк", "пароль" }

function T.test_pools_without_seal_do_not_mention_seal()
  for name, v in each_text() do
    if name ~= "welcomes" and name ~= "invitation" then
      for _, s in ipairs(v) do
        local low = lower(s)
        for _, w in ipairs(SEAL_WORDS) do
          t.ok(not low:find(w, 1, true), name .. ": «" .. w .. "» без печати: " .. s)
        end
      end
    end
  end
end

-- голос Тома Реддла: вежливый, обаятельный, взрослый; детские образы прежнего «уютного» дневника
-- (овечки, котёнок, сверчок, кузнечик) — остаток старого персонажа (владелец 2026-10-25:
-- «дефолтные ответы всё еще под старого персонажа»)
local NURSERY = { "овеч", "котён", "котен", "сверч", "кузнечик", "рыбк", "лодочк", "клубк", "щекот",
  "пропис", "зевают", "кружев", "паутинк", "стайк", "лапк", "вверх ногами", "песочные часы" }

function T.test_pools_speak_as_tom_riddle_not_nursery()
  for name, v in each_text() do
    for _, s in ipairs(v) do
      local low = lower(s)
      for _, w in ipairs(NURSERY) do
        t.ok(not low:find(w, 1, true), name .. ": детский образ «" .. w .. "»: " .. s)
      end
    end
  end
end

-- Волдеморт в прайме (владелец 2026-10-25): не школьник с Хогвартсом за дверью, не «пятьдесят лет
-- тишины» канонического дневника 1943 года и не тёплый собеседник, которому без пишущего скучно
local OLD_TOM = { "пятьдесят", "пятидесяти", "подземель", "хогвартс", "школ", "тёпл", "тепл",
  "сон о тебе", "меня зовут том", "рад тебя", "рад тебе", "без тебя" }

function T.test_pools_speak_as_prime_voldemort()
  for name, v in each_text() do
    for _, s in ipairs(v) do
      local low = lower(s)
      for _, w in ipairs(OLD_TOM) do
        t.ok(not low:find(w, 1, true), name .. ": старый Том «" .. w .. "»: " .. s)
      end
    end
  end
end

-- фразы сбоя без сети — голосом Тома, без сказочных «оглохших страниц» и «далёких чернил»
function T.test_fail_offline_not_fairy_tale()
  for _, s in ipairs(texts.fail_offline) do
    local low = lower(s)
    for _, w in ipairs({ "оглохл", "далёких чернил", "туман" }) do
      t.ok(not low:find(w, 1, true), "fail_offline: «" .. w .. "»: " .. s)
    end
  end
end

-- каждый пул без модели — от SIZE вариантов (владелец 2026-10-25: «сделай минимум 30 вариантов на каждый
-- ответ, который идёт без ЛЛМ»): ни повторов, ни почти-повторов во всём texts, гарды промпта на каждой
-- фразе — без эмодзи, латиницы и без «ИИ», модели, программы
local NOT_AI = { "модел", "программ", "нейросет", "искусствен", "алгоритм", "компьютер" }

-- слова от 4 букв, обрезанные до 5 (грубая основа): «напиши»/«напишешь» — одно слово
local function stems(s)
  local set, n = {}, 0
  -- знаки «…», «—», «»» тоже из байтов ≥ 128: сначала в пробел
  local words = lower(s):gsub("\226\128[\128-\191]", " "):gsub("\194[\128-\191]", " ")
  for w in words:gmatch("[%a\128-\255]+") do
    if cps(w) >= 4 then
      local cut = w:match("^" .. ("[%z\1-\127\194-\244][\128-\191]*"):rep(5)) or w
      if not set[cut] then set[cut] = true n = n + 1 end
    end
  end
  return set, n
end

local function similar(a, b)
  local sa, na = stems(a)
  local sb, nb = stems(b)
  local both = 0
  for w in pairs(sa) do if sb[w] then both = both + 1 end end
  local union = na + nb - both
  return union > 0 and both / union or 0
end

function T.test_every_pool_has_30_and_texts_has_no_other_pool()
  local known = {}
  for _, name in ipairs(POOLS) do
    known[name] = true
    t.ok(type(texts[name]) == "table" and #texts[name] >= SIZE,
      name .. ": не меньше " .. SIZE .. ", а не " .. tostring(texts[name] and #texts[name]))
  end
  for name, v in pairs(texts) do
    if type(v) == "table" and name ~= "SETS" and name ~= "FORBIDDEN" and name ~= "INVITATION"
        and name ~= "neutral" and name ~= "NEUTRAL_FOR" then
      t.ok(known[name], "пул " .. name .. " не в POOLS — допиши его в проверку")
    end
  end
end

function T.test_all_pools_no_repeats_no_near_repeats_guards()
  local all = {}
  for _, name in ipairs(POOLS) do
    for i, s in ipairs(texts[name]) do all[#all + 1] = { name = name, i = i, s = s } end
  end
  for k, a in ipairs(all) do
    local s = a.s
    local tag = a.name .. "#" .. a.i .. ": "
    t.ok(not s:find("[\240-\247]"), tag .. "эмодзи: " .. s)
    t.ok(not s:find("%a"), tag .. "латиница: " .. s)
    t.ok(not s:find("ИИ", 1, true), tag .. "«ИИ»: " .. s)
    local low = lower(s)
    for w in low:gmatch("[%a\128-\255]+") do t.ok(w ~= "ии", tag .. "«ии»: " .. s) end
    for _, w in ipairs(NOT_AI) do t.ok(not low:find(w, 1, true), tag .. "«" .. w .. "»: " .. s) end
    for j = k + 1, #all do
      local b = all[j]
      t.ok(s ~= b.s, tag .. "повтор в " .. b.name .. "#" .. b.i .. ": " .. s)
      local sim = similar(s, b.s)
      t.ok(sim < 0.6, string.format("%sпочти повтор (%.2f) %s#%d: %s | %s", tag, sim, b.name, b.i, s, b.s))
    end
  end
end

-- наборы для генерации персонажа (план «чей это дневник», задача 2): описание каждого пула, проверка ответа модели

function T.test_sets_describe_every_pool()
  local names, by = {}, {}
  for _, set in ipairs(texts.SETS) do
    names[#names + 1] = set.name
    by[set.name] = set
    t.ok(type(set.about) == "string" and set.about ~= "", set.name .. ": about")
  end
  local want = {}
  for _, n in ipairs(POOLS) do want[#want + 1] = n end
  table.sort(names)
  table.sort(want)
  t.eq(table.concat(names, ","), table.concat(want, ","), "набор на каждый пул")
  t.eq(texts.MIN_POOL, SIZE)
  for _, n in ipairs(POOLS) do t.eq(by[n].max_cps, n == "interrupted" and 90 or MAX_CPS, n .. ": max_cps") end
  for _, n in ipairs({ "thinking", "busy", "tasks_source_unclear" }) do t.eq(by[n].sentences, 1, n) end
  t.eq(by.interrupted.sentences, 2)
end

-- пулы «Методов» проходят проверку генерации без потерь: правила набора не строже того, что уже на экране
function T.test_builtin_pools_pass_clean()
  for _, set in ipairs(texts.SETS) do
    local kept = texts.clean(set.name, texts[set.name], "ru")
    t.eq(#kept, #texts[set.name], set.name)
    t.eq(kept[1], texts[set.name][1], set.name .. ": порядок")
  end
end

function T.test_clean_drops_bad()
  local good = { "Обдумываю твою запись.", "Перелистываю страницы памяти…", "Взвешиваю каждое слово" }
  local list = { good[1], "", "  ", 5, "Думаю 😀 над этим.", "Думаю над ✨ этим.", ("я"):rep(71), good[2], good[1],
    "**Думаю** над этим.", "# Думаю", "Думаю `над` этим.", "Сеть молчит, думаю.", "Думаю. Пишу дальше.",
    "Думаю! Ещё немного", good[3] }
  t.eq(table.concat(texts.clean("thinking", list, "ru"), "|"), table.concat(good, "|"))
  t.eq(#texts.clean("thinking", { ("я"):rep(70) }, "ru"), 1, "70 знаков — можно")
  t.eq(#texts.clean("interrupted", { "Ты перебил меня. Продолжай." }, "ru"), 1, "два предложения у interrupted")
  t.eq(#texts.clean("busy", { "The network is busy.", "Your server hums.", "I am thinking." }, "en"), 1,
    "запрещённые слова языка набора")
  t.eq(#texts.clean("busy", "не список", "ru"), 0)
end

-- ревью ba4087a: запрещённые слова — во всех формах, но целым словом от начала: «посетить» — не «сети»
function T.test_clean_drops_forbidden_word_forms()
  for _, s in ipairs({ "Нет связи, вернись позже.", "Сети нет, приходи потом.", "Без сетей я нем, вернись позже.",
      "Связью не дотянуться, вернись позже.", "Я офлайн, вернись позже.", "Я в оффлайне, вернись позже.",
      "Сетевой голос молчит, вернись.", "Ошибка в чернилах, вернись.", "Сервера молчат, вернись позже." }) do
    t.eq(#texts.clean("fail_offline", { s }, "ru"), 0, "ru: " .. s)
  end
  for _, s in ipairs({ "I am offline, come back later.", "No connections tonight, return later.",
      "The networks sleep, come back.", "Errors cloud my ink, return later." }) do
    t.eq(#texts.clean("fail_offline", { s }, "en"), 0, "en: " .. s)
  end
  for _, s in ipairs({ "Посетитель, вернись ко мне позже.", "Рассеянный свет гаснет, вернись позже.",
      "Сетовать не стану, вернись позже." }) do
    t.eq(#texts.clean("fail_offline", { s }, "ru"), 1, "не запрещено: " .. s)
  end
  for _, s in ipairs({ "A terror of silence, come back later.", "The observer rests, return later." }) do
    t.eq(#texts.clean("fail_offline", { s }, "en"), 1, "не запрещено: " .. s)
  end
end

-- ревью среза 3, п.1: «ошибок», «ошибочно» — формы слова «ошибка», основа «ошибк» их не ловит
function T.test_clean_drops_oshibok_and_oshibochno()
  for _, s in ipairs({ "Нет ошибок, вернись позже.", "Ошибок не счесть, вернись позже.",
      "Это ошибочно, вернись позже.", "Ошибочный путь, вернись позже." }) do
    t.eq(#texts.clean("fail_offline", { s }, "ru"), 0, s)
  end
end

-- ревью среза 3, п.2: язык набора не открывает обход — английские технические слова режутся и при lang = "ru"
function T.test_clean_checks_both_languages_whatever_lang()
  for _, s in ipairs({ "Мой server спит, вернись позже.", "Мой network спит, вернись позже." }) do
    t.eq(#texts.clean("fail_offline", { s }, "ru"), 0, "ru: " .. s)
  end
  t.eq(#texts.clean("fail_offline", { "Сеть молчит, come back later." }, "en"), 0, "en: русское слово")
  t.eq(#texts.clean("fail_offline", { "Мой терминал спит, вернись позже." }, "ru"), 1, "чистая фраза проходит")
end

-- ревью ba4087a: эмодзи вне основных блоков и markdown-курсив, ссылка
function T.test_clean_drops_more_emoji_and_markdown()
  for _, s in ipairs({ "Думаю ⭐ над этим.", "Думаю ⬛ над этим.", "Думаю ⌛ над этим.", "Думаю ▶ над этим.",
      "Думаю ↩ над этим.", "Думаю ℹ над этим.", "Думаю‼", "Думаю⁉", "Думаю 〰 над этим.",
      "Думаю _над_ этим.", "Думаю [над](x) этим.", "Думаю [над этим]." }) do
    t.eq(#texts.clean("thinking", { s }, "ru"), 0, s)
  end
  t.eq(#texts.clean("thinking", { "Думаю… — над этим «словом»." }, "ru"), 1, "многоточие, тире, кавычки — можно")
end

-- нейтральный голос (план, задача 5) ----------------------------------------------------------------------------

local NEUTRAL_POOLS = { "invitation", "ask", "offline", "unreadable", "thinking", "later", "tomorrow", "welcome",
  "source_unclear" }
-- приглашение и вопрос двуязычные, общие для ru и en; остальные — на своём языке
local BILINGUAL = { invitation = true, ask = true }
-- правило формы пула, у которого нет набора в texts.SETS
local NEUTRAL_RULE = { invitation = texts.INVITATION, ask = texts.INVITATION }
local NEUTRAL_NAMES = { "Реддл", "Волдеморт", "Лорд", "Riddle", "Voldemort", "Harry", "Гарри", "Хогвартс", "Hogwarts" }
-- слова, выдающие род говорящего: дневник о себе без рода («ты» и «я» — без прошедшего времени и кратких форм)
local GENDERED = { "понял", "поняла", "ждал", "ждала", "рад", "рада", "готов", "готова", "уверен", "уверена", "смог",
  "смогла", "хотел", "хотела", "должен", "должна", "сам", "сама", "один", "одна", "увидел", "увидела", "услышал",
  "услышала", "разобрал", "разобрала", "забыл", "забыла", "устал", "устала", "занят", "занята" }

-- Правило рода (план, задача 5: «о себе без рода»), а не только список слов. В русской фразе:
-- (1) предложение с «я»/«мы»: любое слово на -л/-ла/-лся/-лась (прошедшее) и краткие/родовые формы — тем, той, сам,
--     сама, один, одна, такой, такая, рад, готов… — выдают род говорящего;
-- (2) предложение, которое начинается глаголом прошедшего времени (-л/-ла/-лся/-лась) без подлежащего: «Задумалась
--     над твоими словами» — подлежащее «я» опущено.
-- Прошедшее у третьих лиц («Нить оборвалась», «Чернила легли») — с подлежащим-существительным, правило его не трогает.
local GENDER_FORMS = { "тем", "той", "сам", "сама", "один", "одна", "такой", "такая", "таким", "рад", "рада",
  "готов", "готова", "уверен", "уверена", "должен", "должна", "согласен", "согласна" }
-- существительные на -ла/-л (не глаголы)
local NOT_VERBS = { ["чернила"] = true, ["чернил"] = true }
local function is_past(w)
  return not NOT_VERBS[w] and (w:find("л$") or w:find("ла$") or w:find("лся$") or w:find("лась$"))
end
local function gender_flaw(s)
  for sentence in (lower(s) .. " "):gmatch("(.-)[%.!?…]+%s") do
    local list, has_i = {}, false
    for w in sentence:gmatch("[^%s%p]+") do
      list[#list + 1] = w
      if w == "я" or w == "мы" then has_i = true end
    end
    -- без подлежащего: -л — чаще существительное («Смысл ускользнул»), поэтому здесь только -ла/-лся/-лась
    local first = list[1]
    if first and not NOT_VERBS[first] and (first:find("ла$") or first:find("лся$") or first:find("лась$")) then
      return first
    end
    if has_i then
      for _, w in ipairs(list) do
        if is_past(w) then return w end
        for _, f in ipairs(GENDER_FORMS) do
          if w == f then return w end
        end
      end
    end
  end
end

function T.test_gender_rule_catches_first_person()
  t.ok(gender_flaw("Страница обдумывает твои слова. Я задумалась над ними."), "я задумалась")
  t.ok(gender_flaw("Поправь строку в конфиге — и я стану тем, кем нужно."), "я стану тем")
  t.ok(gender_flaw("Я стану той, кого ты ждёшь."), "я стану той")
  t.ok(gender_flaw("Задумалась над твоими словами."), "без подлежащего")
  t.ok(gender_flaw("Я сам не знаю, что ответить."), "я сам")
  t.ok(not gender_flaw("Нить оборвалась — загляни позже."), "третье лицо")
  t.ok(not gender_flaw("Давно никто не будил меня этим словом."), "будил — про другого")
  t.ok(not gender_flaw("Я здесь, просто думаю — подожди."), "настоящее время")
  t.ok(not gender_flaw("Тише… я перебираю страницы памяти."), "я + настоящее")
end

local function words_of(s)
  local out = {}
  for w in lower(s):gsub("…", " "):gmatch("[^%s%p]+") do out[w] = true end
  return out
end

local function neutral_list(lang, pool)
  local n = texts.neutral[lang]
  t.ok(type(n) == "table", "texts.neutral." .. lang .. " нет")
  t.ok(type(n[pool]) == "table", "texts.neutral." .. lang .. "." .. pool .. " нет")
  return n[pool]
end

function T.test_neutral_pools_30_clean()
  for _, lang in ipairs({ "ru", "en" }) do
    for _, pool in ipairs(NEUTRAL_POOLS) do
      local list = neutral_list(lang, pool)
      local who = lang .. "." .. pool
      t.ok(#list >= SIZE, who .. ": не меньше " .. SIZE .. ", а не " .. #list)
      local seen = {}
      for i, s in ipairs(list) do
        t.ok(type(s) == "string" and not seen[s], who .. ": повтор #" .. i .. ": " .. tostring(s))
        seen[s] = true
        t.ok(not texts.forbidden(s), who .. ": запрещённое слово: " .. s)
        local low = lower(s)
        for _, name in ipairs(NEUTRAL_NAMES) do
          t.ok(not low:find(lower(name), 1, true), who .. ": имя «" .. name .. "»: " .. s)
        end
        local words = words_of(s)
        for _, w in ipairs(GENDERED) do
          t.ok(not words[w], who .. ": род «" .. w .. "»: " .. s)
        end
        if lang == "ru" then
          local flaw = gender_flaw(s)
          t.ok(not flaw, who .. ": род о себе («" .. tostring(flaw) .. "»): " .. s)
        end
        if not BILINGUAL[pool] then
          local foreign = lang == "ru" and s:find("%a") or lang == "en" and s:find("[\208\209]")
          t.ok(not foreign, who .. ": чужой язык: " .. s)
        end
        local rule = NEUTRAL_RULE[pool]
        if rule then t.ok(texts.fits(rule, s), who .. ": не по правилам формы: " .. s) end
      end
    end
  end
  t.eq(texts.neutral.ru.invitation, texts.neutral.en.invitation, "приглашение общее для языков")
  t.eq(texts.neutral.ru.ask, texts.neutral.en.ask, "вопрос общий для языков")
end

-- нейтральная фраза подставляется вместо любого из 12 наборов: она проходит правила именно этого набора
function T.test_every_set_has_neutral()
  local mapped = 0
  for _, set in ipairs(texts.SETS) do
    local pool = texts.NEUTRAL_FOR[set.name]
    t.ok(pool, set.name .. ": нет нейтрального пула в NEUTRAL_FOR")
    mapped = mapped + 1
    for _, lang in ipairs({ "ru", "en" }) do
      for _, s in ipairs(neutral_list(lang, pool)) do
        t.ok(texts.fits(set, s), lang .. "." .. pool .. " для " .. set.name .. ": не по правилам набора: " .. s)
      end
    end
  end
  local n = 0
  for name, pool in pairs(texts.NEUTRAL_FOR) do
    n = n + 1
    t.ok(texts.neutral.ru[pool], name .. " -> " .. tostring(pool) .. ": пула нет")
  end
  t.eq(n, mapped, "NEUTRAL_FOR без лишних имён")
  t.eq(mapped, 13)
end

-- карта целиком (план, задача 5; решение оркестратора: сбой и «позже» — свой пул, не «думаю»)
function T.test_neutral_for_exact()
  local want = {
    greetings = "invitation", welcomes = "welcome", sleepy = "later", fail_offline = "offline",
    fail_slow = "later", fail_limit = "later", fail_daily = "tomorrow", fail_other = "later", unreadable = "unreadable",
    thinking = "thinking", busy = "thinking", interrupted = "thinking",
    tasks_source_unclear = "source_unclear",
  }
  for name, pool in pairs(want) do t.eq(texts.NEUTRAL_FOR[name], pool, name) end
  for name in pairs(texts.NEUTRAL_FOR) do t.ok(want[name], "лишнее имя в карте: " .. name) end
end

-- «назови собрание точнее» (Notion 41013e60-bc8d-81e4): у tasks_source_unclear нейтральный пул свой, не «не разобрал
-- запись» (unreadable): каждая фраза просит назвать собрание дел — и по-русски, и по-английски
function T.test_source_unclear_neutral_asks_to_name_the_collection()
  local ASKS = { ru = { "назов", "назван", "имя", "имени", "уточн" }, en = { "name", "which", "specify", "precisely" } }
  for _, lang in ipairs({ "ru", "en" }) do
    local pool = neutral_list(lang, "source_unclear")
    t.ok(pool ~= texts.neutral[lang].unreadable, lang .. ": тот же пул, что «не разобрал запись»")
    for _, s in ipairs(pool) do
      local low, ok = lower(s), false
      for _, w in ipairs(ASKS[lang]) do ok = ok or low:find(w, 1, true) ~= nil end
      t.ok(ok, lang .. ": не просит назвать собрание: " .. s)
    end
  end
end

-- суточная квота всей цепочки (Notion 40313e60-bc8d-81a5): «на сегодня всё, приходи завтра». Каждая фраза — о завтра,
-- и никакого времени точнее «завтра»: квота Gemini сбрасывается в полночь по Тихоокеанскому времени, не по часам пишущего
local NOT_BEFORE = { ru = "завтр", en = "tomorrow" }
local EXACT_TIME = { "утр", "вечер", "полноч", "полдн", "полудн", "рассвет", "заре", "зарё", "час", "минут", "ночью",
  "morning", "evening", "midnight", "noon", "dawn", "hour", "minute", "o'clock", "tonight" }

local function daily_ok(who, s, lang)
  local low = lower(s)
  t.ok(low:find(NOT_BEFORE[lang], 1, true), who .. ": не о завтра: " .. s)
  for w in low:gmatch("[^%s%p]+") do
    for _, stem in ipairs(EXACT_TIME) do
      t.ok(w:sub(1, #stem) ~= stem, who .. ": время точнее «завтра» («" .. w .. "»): " .. s)
    end
  end
end

function T.test_daily_pools_say_tomorrow_without_exact_time()
  t.ok(type(texts.fail_daily) == "table" and #texts.fail_daily >= SIZE, "fail_daily «Методов»: от " .. SIZE)
  local set
  for _, x in ipairs(texts.SETS) do if x.name == "fail_daily" then set = x end end
  t.ok(set, "набор fail_daily в texts.SETS")
  for i, s in ipairs(texts.fail_daily or {}) do
    daily_ok("fail_daily#" .. i, s, "ru")
    t.ok(set and texts.fits(set, s), "fail_daily#" .. i .. ": не по правилам набора: " .. s)
  end
  for _, lang in ipairs({ "ru", "en" }) do
    for i, s in ipairs(neutral_list(lang, "tomorrow")) do daily_ok(lang .. ".tomorrow#" .. i, s, lang) end
  end
  t.ok(set and set.about:find("завтра", 1, true), "about набора — о завтра: " .. tostring(set and set.about))
end

-- минутный лимит — короткая передышка, не «на сегодня всё»: сутки — у fail_daily (Notion 40313e60-bc8d-81a5). Запрос
-- генерации набора несёт about как есть
function T.test_fail_limit_about_is_short_pause_not_today()
  local set
  for _, x in ipairs(texts.SETS) do if x.name == "fail_limit" then set = x end end
  local view = { head = "дневник.", body = "Голос.", lang = "ru", lang_name = "русский", gender = "n" }
  local sys = require("riddle.prompt").gen_texts(set, view)[1].content
  t.ok(sys:find(set.about, 1, true), "about в запросе генерации")
  t.ok(not lower(set.about):find("сегодня", 1, true), "без «на сегодня»: " .. set.about)
  t.ok(set.about:find("передышк", 1, true) and set.about:find("чуть позже", 1, true), set.about)
end

-- «позже» не обещает ответа: пишущий не должен ждать того, чего не будет
function T.test_later_never_promises_an_answer()
  for _, lang in ipairs({ "ru", "en" }) do
    for _, s in ipairs(neutral_list(lang, "later")) do
      local words = lower(s)
      for _, stem in ipairs({ "ответ", "отвеч", "answer", "reply", "respond" }) do
        t.ok(not words:find(stem, 1, true), lang .. ".later: «" .. stem .. "»: " .. s)
      end
    end
  end
end

-- двуязычные «по-русски / in English»: кириллица слева, латиница справа, один разделитель
function T.test_bilingual_phrases_ru_left_en_right()
  for _, pool in ipairs({ "invitation", "ask" }) do
    for _, s in ipairs(texts.neutral.ru[pool]) do
      local left, right = s:match("^(.-) / (.+)$")
      t.ok(left and right, pool .. ": нет « / »: " .. s)
      t.ok(not right:find(" / ", 1, true), pool .. ": два разделителя: " .. s)
      t.ok(left:find("[\208\209]") and not left:find("%a"), pool .. ": слева не русский: " .. s)
      t.ok(right:find("%a") and not right:find("[\208\209]"), pool .. ": справа не английский: " .. s)
    end
  end
end

-- вопрос — о хозяине дневника-персонаже, а не о пишущем (ревью задачи 5): пишущего не окликают на «ты»
function T.test_ask_is_about_diary_owner()
  local subject = { "дневник", "страниц", "листы", "хозяин", "владел" }
  for _, s in ipairs(texts.neutral.ru.ask) do
    local left, right = s:match("^(.-) / (.+)$")
    t.ok(left and right, "ask: нет « / »: " .. s)
    local low = lower(left)
    local on_topic = false
    for _, w in ipairs(subject) do on_topic = on_topic or low:find(w, 1, true) ~= nil end
    t.ok(on_topic, "ask: не про дневник и его хозяина: " .. s)
    local words = words_of(left)
    for _, w in ipairs({ "ты", "тебе", "тебя", "тобой", "твой", "твоя", "твои", "тебе" }) do
      t.ok(not words[w], "ask: окликает пишущего «" .. w .. "»: " .. s)
    end
    t.ok(not lower(right):find("%f[%a]you", 1) and not lower(right):find("%f[%a]your"), "ask: you в en: " .. s)
  end
  -- приглашение тоже не просит пишущего назвать себя
  for _, s in ipairs(texts.neutral.ru.invitation) do
    t.ok(not lower(s):find("себя", 1, true) and not lower(s):find("yourself", 1, true), "invitation: " .. s)
  end
end

t.run(T)
