-- Приглашение «Кто касается моих страниц?» исчезает только от настоящего касания (владелец
-- 2026-10-23: «приветственную фразу не убирай пока нет взаимодействий»). Виджет без KOReader не
-- поднять, поэтому храповик по тексту исходника: кто зовёт fadeInvitation и кто освобождает слой.
local t = require("t")

local T = {}

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local WIDGET = read("plugin/riddlediary.koplugin/riddle_diarywidget.lua")
local DEVTEST = read("plugin/riddlediary.koplugin/riddle/devtest.lua")
local MAIN = read("plugin/riddlediary.koplugin/main.lua")

-- имя функции Diary:..., внутри которой стоит позиция pos
local function enclosing(src, pos)
  local name
  for start, fname in src:gmatch("()function Diary:([%w_]+)") do
    if start > pos then break end
    name = fname
  end
  return name
end

local function callers(src, needle)
  local out = {}
  local from = 1
  while true do
    local s, e = src:find(needle, from, true)
    if not s then break end
    -- определение самой функции — не вызов
    if src:sub(math.max(1, s - 14), s - 1) ~= "function Diary" then out[#out + 1] = enclosing(src, s) end
    from = e + 1
  end
  return out
end

function T.test_fade_invitation_only_from_pen_down()
  local c = callers(WIDGET, ":fadeInvitation()")
  t.eq(#c, 1, "один вызов")
  t.eq(c[1], "penDown", "только касание пера")
end

function T.test_pen_down_only_from_raw_touch()
  local c = callers(WIDGET, ":penDown(")
  t.eq(#c, 1)
  t.eq(c[1], "onRawTouch", "penDown — только из сырого касания")
end

function T.test_invitation_layer_dropped_only_by_fade_reset_close()
  local allowed = { fadeInvitation = true, resetPage = true, onCloseWidget = true }
  for _, needle in ipairs({ "pr.layer = nil", "pr.layer, pr.fading", "prompt.layer = nil" }) do
    for _, fname in ipairs(callers(WIDGET, needle)) do
      t.ok(allowed[fname], needle .. " в Diary:" .. tostring(fname))
    end
  end
end

-- и карта мародёров, и страница состояния: их открывает знак пером (приглашение уже растворяется), закрывает — чистая
-- страница с новым приглашением (план карты, раздел 2, «Закрытие»; план состояния, Task 5) — backToDiary
function T.test_reset_page_only_on_sleep_and_wake()
  local c = {}
  for _, needle in ipairs({ ":resetPage()", ":resetPage(keep)" }) do
    for _, fname in ipairs(callers(WIDGET, needle)) do c[#c + 1] = fname end
  end
  table.sort(c)
  t.eq(table.concat(c, ","), "backToDiary,onResume,onSuspend,openMap,openStatus")
end

function T.test_resume_brings_invitation_back()
  local body = WIDGET:match("function Diary:onResume%(%)(.-)\nend")
  t.ok(body and body:find("self:showInvitation(false)", 1, true), "onResume -> showInvitation")
end

-- печати нет (слова в конфиге нет) — на чистой странице приветствие (invitationText), а не пустота:
-- showInvitation не выходит раньше построения слоя (владелец 2026-10-25: «снова просто белый экран»)
function T.test_seal_off_still_shows_a_line()
  local body = WIDGET:match("function Diary:showInvitation%(push%)(.-)\nend")
  t.ok(body, "showInvitation найден")
  t.ok(not body:find("sealed == false", 1, true), "выход без печати убран")
  t.ok(body:find("self:invitationText()", 1, true), "текст строки — из invitationText")
end

function T.test_followup_flag_comes_from_controller_when_seal_is_off()
  local body = WIDGET:match("function Diary:respond%(png, cb, wait%)(.-)\nend")
  t.ok(body and body:find("take_followup", 1, true), "respond берёт хвост у контроллера")
end

-- о закрытии сном пишет только контроллер и только по факту (Controller:_close, «seal closed by sleep»): у плагина
-- своей строки нет — она писалась и про уже закрытую печать (ревью Task 7)
function T.test_suspend_leaves_seal_log_to_controller()
  local body = MAIN:match("function RiddleDiary:onSuspend%(%)(.-)\nend")
  t.ok(body, "onSuspend найден")
  t.ok(body:find("ctl:on_sleep()", 1, true), "сон — контроллеру")
  t.ok(not body:find("seal locked", 1, true), "своей строки о печати нет")
end

function T.test_nothing_outside_widget_touches_invitation()
  for name, src in pairs({ devtest = DEVTEST, main = MAIN }) do
    t.ok(not src:find("fadeInvitation", 1, true), name .. ": fadeInvitation")
    t.ok(not src:find("prompt.layer", 1, true), name .. ": prompt.layer")
    t.ok(not src:find(":penDown(", 1, true), name .. ": penDown")
  end
end

function T.test_feed_mode_never_draws()
  local body = DEVTEST:match("function Diary:testFeed%(s%)(.-)\n    end\n")
  t.ok(body, "testFeed найден")
  for _, needle in ipairs({ "feedEvent", "testWrite", "revealAnswer", "renderRegion", "push(" }) do
    t.ok(not body:find(needle, 1, true), "feed не рисует: " .. needle)
  end
end

t.run(T)
