-- Скользящее окно событий: список времён в секундах (deps.now). Чистая функция, без UI и часов.
local window = {}

-- добавить now в list, отбросить старше span (now - x >= span) и «из будущего» (x > now: часы ушли назад — NTP,
-- ручная правка; иначе такое событие держалось бы в окне сколь угодно долго) -> сколько событий в окне. list меняется
-- на месте
function window.push(list, now, span)
  local kept = {}
  for _, x in ipairs(list) do
    if x <= now and now - x < span then kept[#kept + 1] = x end
  end
  kept[#kept + 1] = now
  for i = #list, 1, -1 do list[i] = nil end
  for i, x in ipairs(kept) do list[i] = x end
  return #list
end

return window
