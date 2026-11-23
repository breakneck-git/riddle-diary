-- Ритм напоминаний о задачах: режим ответа из меток реплик сессии (Memory:marks) и выбор 1–3 задач.
-- Ядро: знает только метки и блок задач (tasks.block), откуда задачи — не знает.
-- Метка owner.task: id — запись о задаче, "all" — о делах вообще, "ask" — вопрос не о делах, "" — ни к какой,
-- nil — неизвестно; diary.offer: id через пробел или "themes" — что дневник предложил в этом ответе, nil — ничего.
local rhythm = {}

-- сколько задач назвать за раз (владелец: «не больше трех»)
rhythm.PICK = 3
-- на какой записи подряд без задачи — намёк «отклонились» и предложение (после предложения счёт с нуля)
rhythm.DRIFT_AT = 3
rhythm.OFFER_AT = 6
-- пауза, после которой первая запись — снова «первая» (дела безусловно); сессия при этом та же (memory.lua: 4 ч).
-- Владелец 2026-10-26, 812e
rhythm.PAUSE_S = 3600

-- метки после последней паузы от PAUSE_S (now — время этой записи: пауза перед ней — пустой хвост). Без now или
-- без ts у меток паузы не видно — все метки
local function since_pause(marks, now)
  local prev, from = nil, 1
  for i, m in ipairs(marks) do
    if prev and m.ts and m.ts - prev >= rhythm.PAUSE_S then from = i end
    prev = m.ts or prev
  end
  if now and prev and now - prev >= rhythm.PAUSE_S then from = #marks + 1 end
  if from == 1 then return marks end
  local out = {}
  for i = from, #marks do out[#out + 1] = marks[i] end
  return out
end

-- записи подряд без задачи: о задаче и о делах вообще — 0, "" — +1, неизвестно и вопрос не о делах ("ask") — без
-- изменений; предложение дневника — 0
function rhythm.count(marks)
  local n = 0
  for _, m in ipairs(marks) do
    if m.role == "owner" then
      if m.task == "" then n = n + 1 elseif m.task ~= nil and m.task ~= "ask" then n = 0 end
    elseif m.offer ~= nil then
      n = 0
    end
  end
  return n
end

-- -> mode ("name" | "themes" | "drift" | "none"), conditional, k. Первая запись сессии — безусловно (до неё в
-- сессии только вопросы не о делах: на вопрос напоминания нет, оно ждёт следующей записи); дальше
-- k = count + 1 (эта запись — k-я без задачи, если она не о задаче): условие ставит модель (строка режима).
-- Темы — только без задач; намёка без задач нет; темы без названий — "none".
-- С задачами и now (время этой записи) считается только то, что после последней паузы от PAUSE_S: первая запись
-- после паузы — как первая сессии. Без задач пауза не в счёт: темы — только первой записью сессии
function rhythm.mode(marks, has_tasks, has_titles, now)
  if has_tasks then marks = since_pause(marks, now) end
  local offer = has_tasks and "name" or (has_titles and "themes" or "none")
  local first = true
  for _, m in ipairs(marks) do
    if m.role == "owner" and m.task ~= "ask" then first = false break end
  end
  if first then return offer, false, 1 end
  local k = rhythm.count(marks) + 1
  if k >= rhythm.OFFER_AT then return offer, true, k end
  if k == rhythm.DRIFT_AT and has_tasks then return "drift", true, k end
  return "none", true, k
end

-- id предложенных в сессии задач, каждый один раз, по времени последнего предложения, давние первыми
-- (в одном предложении — в порядке строки offer)
function rhythm.offered(marks)
  local at, list, seq = {}, {}, 0
  for _, m in ipairs(marks) do
    if m.role == "diary" and type(m.offer) == "string" and m.offer ~= "themes" then
      for id in m.offer:gmatch("%S+") do
        seq = seq + 1
        if not at[id] then list[#list + 1] = id end
        at[id] = seq
      end
    end
  end
  table.sort(list, function(a, b) return at[a] < at[b] end)
  return list
end

-- до n задач блока (items — tasks.block.items, порядок open_list): сначала не предлагавшиеся, в порядке
-- блока; таких нет совсем — предлагавшиеся, давние первыми. Задачи вне блока не берутся: у них нет метки
function rhythm.pick(items, offered, n)
  n = n or rhythm.PICK
  local was, by_id = {}, {}
  for _, id in ipairs(offered) do was[id] = true end
  for _, it in ipairs(items) do by_id[it.id] = it end
  local out = {}
  for _, it in ipairs(items) do
    if #out >= n then break end
    if not was[it.id] then out[#out + 1] = it end
  end
  if #out > 0 then return out end
  for _, id in ipairs(offered) do
    if #out >= n then break end
    if by_id[id] then out[#out + 1] = by_id[id] end
  end
  return out
end

return rhythm
