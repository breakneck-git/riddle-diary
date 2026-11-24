local t = require("t")
local texts = require("riddle.texts")
local seal = require("riddle.seal")
local config = require("riddle.config")

-- правила печати — как их отдаёт config.load (cfg.seal)
local function new_seal(rules)
  return seal.new(config.parse_seal(rules))
end

local T = {}

function T.test_unconfigured_is_open()
  for _, rules in ipairs({ false, {}, { remember = false }, { key = true, off = true } }) do
    local s = new_seal(rules or nil)
    t.eq(s.configured, false)
    t.eq(s.open, true, "печати нет — открыта")
    t.eq(s:lock("sleep"), false, "закрывать нечего")
    t.eq(s.open, true, "lock не закрывает печать, которой нет")
    t.eq(s:closes_on_sleep(), false)
  end
end

function T.test_configured_starts_closed()
  local s = new_seal({ key = true })
  t.eq(s.configured, true)
  t.eq(s.invalid, nil)
  t.eq(s.open, false, "на старте печать закрыта")
  t.eq(s.last_at, nil)
end

function T.test_unlock_lock()
  local s = new_seal({ key = true })
  t.eq(s:unlock(500), true)
  t.eq(s.open, true)
  t.eq(s.last_at, 500, "открытие ключом — последняя запись")
  t.eq(s:lock("key"), true)
  t.eq(s.open, false)
  t.eq(s:unlock(700), true, "снова открывается")
  t.eq(s.open, true)
end

-- простой считается от последней записи: открытие ключом и отвеченная страница
function T.test_touch_marks_last_entry()
  local s = new_seal({ key = true, minutes = 5 })
  s:unlock(100)
  t.eq(s:due(399), false)
  s:touch(250)
  t.eq(s:due(400), false, "запись в 250 отодвинула простой")
  t.eq(s:due(550), true)
end

-- правило minutes (spec §6): N минут без записи — пора закрыть
function T.test_due_after_idle()
  local s = new_seal({ key = true, minutes = 30 })
  s:unlock(500)
  s:touch(1000)
  t.eq(s:due(1000 + 1799), false)
  t.eq(s:due(1000 + 1800), true)
  t.eq(s:left(1000 + 1700), 100, "до закрытия — секунды")
end

-- Review Focus 3: часы прыгнули назад — простой считается заново от нового «сейчас», раньше срока не закрывает
function T.test_due_clock_back()
  local s = new_seal({ key = true, minutes = 30 })
  s:unlock(1000)
  t.eq(s:due(500), false)
  t.eq(s:due(500 + 1799), false, "не раньше срока от прыжка")
  t.eq(s:due(500 + 1800), true)
end

-- закрытой печати, печати без minutes и печати без правил закрывать по простою нечего
function T.test_due_needs_minutes_and_open()
  local closed = new_seal({ key = true, minutes = 30 })
  t.eq(closed:due(10 ^ 9), false, "закрыта")
  t.eq(closed:left(10 ^ 9), nil)
  local no_minutes = new_seal({ key = true })
  no_minutes:unlock(0)
  t.eq(no_minutes:due(10 ^ 9), false, "правила minutes нет")
  t.eq(no_minutes:left(10 ^ 9), nil)
  t.eq(new_seal(nil):due(10 ^ 9), false, "печати нет")
end

function T.test_invalid_never_unlocks()
  local s = new_seal({ minutes = 5 })
  t.eq(s.configured, true)
  t.ok(s.invalid, "правило без key — битый конфиг")
  t.eq(s.open, false)
  t.eq(s:unlock(500), false, "битую печать ключ не открывает")
  t.eq(s.open, false)
  t.eq(s.last_at, nil)
end

function T.test_closes_on_sleep()
  t.eq(new_seal({ key = true, on_sleep = true }):closes_on_sleep(), true)
  t.eq(new_seal({ key = true }):closes_on_sleep(), false, "без on_sleep сон не закрывает")
  t.eq(new_seal({ key = true, on_sleep = false }):closes_on_sleep(), false)
end

-- слово и его нечёткий поиск удалены вместе с подсказками
function T.test_word_api_gone()
  for _, name in ipairs({ "matches", "normalize", "lower" }) do
    t.eq(seal[name], nil, name .. " удалён (нижний регистр — str.lower)")
  end
  t.eq(new_seal({ key = true }).feed, nil)
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
