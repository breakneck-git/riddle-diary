local t = require("t")
local window = require("riddle.window")

local T = {}

-- окно событий: добавить now, отбросить старше span, вернуть сколько осталось
function T.test_push_counts_within_span()
  local list = {}
  t.eq(window.push(list, 0, 600), 1)
  t.eq(window.push(list, 300, 600), 2)
  t.eq(window.push(list, 599, 600), 3, "событие на 0 ещё в окне")
  t.eq(window.push(list, 600, 600), 3, "событие на 0 вышло из окна ровно через span")
  t.eq(list[1], 300, "ушло старое, осталось новое")
end

-- часы ушли назад (NTP, ручная правка): события «из будущего» отбрасываются — окно не держит их сколь угодно долго
function T.test_clock_back_drops_future()
  local list = {}
  window.push(list, 5000, 600)
  window.push(list, 5100, 600)
  t.eq(window.push(list, 1000, 600), 1, "после прыжка назад — только новое")
  t.eq(list[1], 1000)
end

t.run(T)
