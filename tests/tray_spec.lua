-- Значки угла (спека 2026-11-19-corner-icons): факты, тик по минуте и геометрия — чистые функции.
local t = require("t")
local tray = require("riddle.tray")
local status = require("riddle.status")
local layout = require("riddle.layout")

local T = {}

-- значения, которые Task 2 кладёт в CFG.tray
local M = { px = 22, pad_r = 14, pad_b = 10, gap = 8, icon_h = 12, batt_w = 22, nub_w = 2, nub_h = 6, line = 2,
  wifi_r = { 4, 8, 12 }, band = 44 }
local AT = { right = 744, base = 1014, asc = 16, reach = layout.text_reach(0) }
local function measure(s) return #s * 10 end

local function src(over)
  local s = {
    clock = function() return { hour = 21, min = 40, sec = 0 } end,
    power = function() return { pct = 87, charging = false } end,
    net = function() return "up" end,
  }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end
local function boom() error("нет данных") end

-- факты по умолчанию; значение false в over — «поля нет» (nil)
local function facts(over)
  local f = { hm = "21:40", sec = 0, pct = 87, charging = false, wifi = true }
  for k, v in pairs(over or {}) do
    if v == false and k ~= "charging" and k ~= "wifi" then f[k] = nil else f[k] = v end
  end
  return f
end

local function find_text(L, s)
  for _, x in ipairs(L.texts) do if x.s == s then return x end end
end

function T.test_facts_reads_sources()
  local f = tray.facts(src({
    clock = function() return { hour = 21, min = 4, sec = 17 } end,
    power = function() return { pct = 87.4, charging = true } end,
  }))
  t.eq(f.hm, "21:04"); t.eq(f.sec, 17);
  t.eq(tray.facts(src({ clock = function() return { hour = 21, min = 4, sec = 17.9 } end })).sec, 17, "секунды целые")
  t.eq(tray.facts(src({ clock = function() return { hour = 21, sec = 3 } end })).hm, nil, "без минут времени нет")
  t.eq(tray.facts(src({ clock = function() return { min = 5, sec = 3 } end })).hm, nil, "без часов времени нет") t.eq(f.pct, 87); t.eq(f.charging, true); t.eq(f.wifi, true)
end

function T.test_facts_failing_sources()
  local f = tray.facts({ clock = boom, power = boom, net = boom })
  t.eq(f.hm, nil); t.eq(f.sec, nil); t.eq(f.pct, nil); t.eq(f.charging, false); t.eq(f.wifi, false)
  t.eq(tray.facts(src({ power = function() return { pct = "88", charging = false } end })).pct, nil)
  t.eq(tray.facts(src({ net = function() return "down" end })).wifi, false)
  t.eq(tray.facts(src({ net = function() return "off" end })).wifi, false)
  t.eq(tray.facts(src({ power = function() return { pct = 87.6, charging = false } end })).pct, 88, "округление")
  t.eq(tray.facts(src({ power = function() return { pct = 130, charging = false } end })).pct, 100)
  t.eq(tray.facts(src({ power = function() return { pct = -5, charging = false } end })).pct, 0)
end

function T.test_next_tick_aligns_to_minute()
  t.eq(tray.next_tick_s({ sec = 0 }), 60)
  t.eq(tray.next_tick_s({ sec = 17 }), 43)
  t.eq(tray.next_tick_s({ sec = 59 }), 1)
  t.eq(tray.next_tick_s({}), 60)
  t.eq(tray.next_tick_s({ sec = 60 }), 1); t.eq(tray.next_tick_s({ sec = -3 }), 60)
end

function T.test_describe_uses_common_dash()
  t.eq(status.DASH, "—")
  t.eq(tray.describe({ charging = false, wifi = false }), status.DASH .. ":" .. status.DASH .. " " .. status.DASH .. "% nowifi")
end

function T.test_describe()
  t.eq(tray.describe(facts()), "21:40 87% wifi")
  t.eq(tray.describe(facts({ charging = true, wifi = false })), "21:40 87%+ nowifi")
  t.eq(tray.describe({ charging = false, wifi = false }), "—:— —% nowifi")
end

function T.test_layout_order_right_to_left()
  local L = tray.layout(facts(), AT, measure, M)
  local tm, pc = find_text(L, "21:40"), find_text(L, "87%")
  t.eq(L.texts[1].s, "21:40"); t.eq(L.texts[2].s, "87%")
  t.eq(tm.x + 50, 744)
  t.eq(pc.x + 30 + M.gap, tm.x)
  local frame_x = math.huge
  for _, r in ipairs(L.rects) do frame_x = math.min(frame_x, r.x) end
  local arc_max = -math.huge
  for _, p in ipairs(L.polys) do
    for i = 1, #p, 2 do arc_max = math.max(arc_max, p[i]) end
  end
  t.ok(arc_max < frame_x, "дуги Wi-Fi левее рамки батареи")
  t.ok(L.rect.x + L.rect.w >= 744, "rect покрывает правый край")
  t.ok(L.rect.y + L.rect.h <= 1014 + AT.reach + 2, "rect не уходит ниже базовой линии больше чем на запас и поле")
end

function T.test_layout_fill_proportional()
  local iw = M.batt_w - 2 * M.line
  local function fill_w(L)
    local x0 = math.huge
    for _, r in ipairs(L.rects) do x0 = math.min(x0, r.x) end
    return L.fill_x1 and L.fill_x1 - (x0 + M.line)
  end
  t.eq(fill_w(tray.layout(facts({ pct = 50 }), AT, measure, M)), math.floor(iw * 50 / 100 + 0.5))
  t.eq(tray.layout(facts({ pct = 0 }), AT, measure, M).fill_x1, nil)
  t.eq(fill_w(tray.layout(facts({ pct = 100 }), AT, measure, M)), iw)
  t.eq(tray.layout(facts({ pct = 50 }), AT, measure, M).fill, nil, "заливка — один раз, в rects")
end

function T.test_layout_no_wifi_no_arcs()
  local on = tray.layout(facts(), AT, measure, M)
  local off = tray.layout(facts({ wifi = false }), AT, measure, M)
  t.eq(#off.polys, 0)
  t.ok(#on.polys > 0)
  t.ok(off.rect.w < on.rect.w)
end

function T.test_layout_wifi_arcs_dense()
  local L = tray.layout(facts(), AT, measure, M)
  local dense = 0
  for _, p in ipairs(L.polys) do
    if #p >= 8 then dense = dense + 1 end
    for i = 3, #p - 1, 2 do
      local d = math.sqrt((p[i] - p[i - 2]) ^ 2 + (p[i + 1] - p[i - 1]) ^ 2)
      t.ok(d <= 2.0001, "соседние точки ≤ 2 px, а тут " .. d)
    end
  end
  t.ok(dense >= 3, "три дуги")
end

-- точки дуг и молнии уходят в paintRect через перо: только целые пиксели
function T.test_layout_points_are_integers()
  local L = tray.layout(facts({ charging = true }), AT, measure, M)
  local lists = { L.bolt }
  for _, p in ipairs(L.polys) do lists[#lists + 1] = p end
  t.ok(#lists >= 5, "молния, три дуги и точка")
  for _, p in ipairs(lists) do
    for i = 1, #p do t.eq(p[i], math.floor(p[i]), "целое: " .. tostring(p[i])) end
  end
end

function T.test_layout_charging_has_bolt()
  local L = tray.layout(facts({ charging = true }), AT, measure, M)
  t.ok(L.bolt and #L.bolt >= 6, "молния — минимум 3 точки")
  -- внешний бокс рамки: объединение прямоугольников рамки (всё, что не выступ и не заливка)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, r in ipairs(L.rects) do
    if r.w ~= M.nub_w or r.h ~= M.nub_h then
      x0, y0 = math.min(x0, r.x), math.min(y0, r.y)
      x1, y1 = math.max(x1, r.x + r.w), math.max(y1, r.y + r.h)
    end
  end
  t.eq(x1 - x0, M.batt_w); t.eq(y1 - y0, M.icon_h)
  for i = 1, #L.bolt, 2 do
    t.ok(L.bolt[i] > x0 and L.bolt[i] < x1 and L.bolt[i + 1] > y0 and L.bolt[i + 1] < y1, "точка молнии внутри рамки")
  end
  t.eq(tray.layout(facts({ charging = false }), AT, measure, M).bolt, nil)
end

function T.test_layout_missing_parts()
  local L = tray.layout(facts({ hm = false }), AT, measure, M)
  t.eq(find_text(L, "21:40"), nil); t.ok(find_text(L, "87%"))
  local N = tray.layout(facts({ pct = false }), AT, measure, M)
  t.eq(find_text(N, "87%"), nil); t.ok(find_text(N, "21:40"))
  t.eq(N.fill_x1, nil)
  t.ok(#N.rects >= 5, "рамка (4 стороны) и выступ есть")
  for _, x in ipairs(N.texts) do t.ok(not x.s:find("%%"), "нет процентов") end
end

function T.test_union()
  local u = tray.union({ x = 0, y = 0, w = 10, h = 10 }, { x = 5, y = 5, w = 10, h = 10 })
  t.eq(u.x, 0); t.eq(u.y, 0); t.eq(u.w, 15); t.eq(u.h, 15)
  local r = { x = 1, y = 2, w = 3, h = 4 }
  t.eq(tray.union(nil, r), r); t.eq(tray.union(r, nil), r); t.eq(tray.union(nil, nil), nil)
end

-- одно правило «ответ power() -> батарея»: страница состояния и угол читают одинаково
function T.test_battery_rule_shared_with_status()
  local cases = { { pct = 87.4, charging = true }, { pct = 130, charging = false }, { pct = -5 }, { pct = 0 },
    { pct = 99.5 }, { pct = 0 / 0 }, { pct = "88" }, { charging = true }, {}, 5, "x" }
  for i, p in ipairs(cases) do
    local b = status.collect({ power = function() return p end }).battery
    local f = tray.facts(src({ power = function() return p end }))
    t.eq(f.pct, b and b.pct, "pct, случай " .. i)
    t.eq(f.charging, b and b.charging or false, "charging, случай " .. i)
  end
end

-- перебор: всё нарисованное внутри L.rect, L.rect внутри экрана, координаты целые, заливка и молния внутри рамки
function T.test_layout_invariants_exhaustive()
  local W, H = 758, 1024
  local function inside(x, y, R) return x >= R.x and x <= R.x + R.w and y >= R.y and y <= R.y + R.h end
  local function int(v, what) t.eq(v, math.floor(v), "целое: " .. what) end
  for _, hm in ipairs({ false, "9:05", "21:40" }) do
    for pct = -1, 100 do
      for _, wifi in ipairs({ true, false }) do
        for _, ch in ipairs({ true, false }) do
          local f = { hm = hm or nil, pct = pct >= 0 and pct or nil, wifi = wifi, charging = ch }
          local L = tray.layout(f, AT, measure, M)
          local R = L.rect
          local tag = string.format("hm=%s pct=%d wifi=%s ch=%s", tostring(hm), pct, tostring(wifi), tostring(ch))
          t.ok(R.x >= 0 and R.y >= 0 and R.x + R.w <= W and R.y + R.h <= H, "в экране: " .. tag)
          for _, v in ipairs({ R.x, R.y, R.w, R.h }) do int(v, "rect " .. tag) end
          local fx0, fx1 = math.huge, -math.huge
          for _, r in ipairs(L.rects) do
            for _, v in ipairs({ r.x, r.y, r.w, r.h }) do int(v, "rects " .. tag) end
            t.ok(inside(r.x, r.y, R) and inside(r.x + r.w, r.y + r.h, R), "rect в L.rect: " .. tag)
            fx0, fx1 = math.min(fx0, r.x), math.max(fx1, r.x + r.w)
          end
          for _, p in ipairs(L.polys) do
            for i = 1, #p, 2 do
              int(p[i], "poly " .. tag); int(p[i + 1], "poly " .. tag)
              t.ok(inside(p[i], p[i + 1], R), "poly в L.rect: " .. tag)
              t.ok(p[i] < fx0, "Wi-Fi левее рамки: " .. tag)
            end
          end
          local tx0 = math.huge
          for _, x in ipairs(L.texts) do
            int(x.x, "text.x " .. tag)
            local reach = AT.reach
            t.ok(inside(x.x - reach, AT.base - AT.asc - reach, R) and inside(x.x + measure(x.s) + reach, AT.base + reach, R),
              "текст с запасом reach в L.rect: " .. tag)
            tx0 = math.min(tx0, x.x)
          end
          if #L.texts > 0 then t.eq(tx0 - fx1, M.gap, "между рамкой с выступом и цифрами ровно gap: " .. tag) end
          local pmax = -math.huge
          for _, p in ipairs(L.polys) do for i = 1, #p, 2 do pmax = math.max(pmax, p[i]) end end
          if wifi then
            t.ok(fx0 - pmax >= M.gap and fx0 - pmax <= M.gap + M.wifi_r[3], "Wi-Fi в gap..gap+r левее рамки: " .. tag)
          end
          -- выступ по центру высоты рамки
          for _, r in ipairs(L.rects) do
            if r.w == M.nub_w and r.h == M.nub_h then
              t.eq(r.y - (AT.base - M.icon_h), math.floor((M.icon_h - M.nub_h) / 2), "выступ по центру: " .. tag)
              t.eq(r.x, fx0 + M.batt_w, "выступ у правой стенки: " .. tag)
            end
          end
          -- рамка: batt_w × icon_h от fx0; выступ торчит справа
          local ix0, ix1 = fx0 + M.line, fx0 + M.batt_w - M.line
          local iy0, iy1 = AT.base - M.icon_h + M.line, AT.base - M.line
          local want = f.pct and math.floor((ix1 - ix0) * f.pct / 100 + 0.5) or 0
          if want > 0 then
            t.ok(L.fill_x1 > ix0 and L.fill_x1 <= ix1, "заливка внутри рамки: " .. tag)
            t.eq(L.fill_x1 - ix0, want, "заливка пропорциональна: " .. tag)
            local found
            for _, r in ipairs(L.rects) do
              if r.x == ix0 and r.y == iy0 and r.w == want and r.h == iy1 - iy0 then found = true end
            end
            t.ok(found, "заливка — прямоугольник внутри рамки: " .. tag)
          else
            t.eq(L.fill_x1, nil, "пустая заливка не рисуется: " .. tag)
          end
          if L.bolt then
            local bmin, bmax = math.huge, -math.huge
            for i = 1, #L.bolt, 2 do bmin, bmax = math.min(bmin, L.bolt[i]), math.max(bmax, L.bolt[i]) end
            t.ok(math.abs((bmin + bmax) / 2 - (fx0 + M.batt_w / 2)) <= 2, "молния по центру рамки: " .. tag)
            for i = 1, #L.bolt, 2 do
              local x, y = L.bolt[i], L.bolt[i + 1]
              -- точка — левый верхний угол штампа 2 × 2: весь штамп внутри рамки
              t.ok(x >= ix0 and x + 1 < ix1 and y >= iy0 and y + 1 < iy1, "молния внутри рамки: " .. tag)
            end
          end
          for _, sec in ipairs({ 0, 59, 60, 61, -3 }) do
            local n = tray.next_tick_s({ sec = sec })
            t.ok(n >= 1 and n <= 60, "next_tick_s в [1,60]: " .. sec)
          end
        end
      end
    end
  end
end

-- дробная ширина текста: L.rect всё равно целый и охватывает всё нарисованное
function T.test_layout_rect_whole_with_fractional_measure()
  local L = tray.layout(facts(), AT, function(s) return #s * 7.5 end, M)
  for _, v in ipairs({ L.rect.x, L.rect.y, L.rect.w, L.rect.h }) do t.eq(v, math.floor(v), "целое: " .. v) end
  for _, x in ipairs(L.texts) do t.ok(x.x - AT.reach >= L.rect.x, "текст внутри") end
end

-- запас вокруг цифр берётся у вызывающего (at.reach): без него rect теснее, с ним — шире на reach с каждой стороны
function T.test_layout_reach_widens_rect()
  local a = { right = 744, base = 1014, asc = 16 }
  local b = { right = 744, base = 1014, asc = 16, reach = 8 }
  local La, Lb = tray.layout(facts(), a, measure, M), tray.layout(facts(), b, measure, M)
  t.ok(Lb.rect.w > La.rect.w and Lb.rect.h > La.rect.h)
  t.ok(Lb.rect.y <= 1014 - 16 - 8 - 2 and Lb.rect.y + Lb.rect.h >= 1014 + 8 + 2)
end

t.run(T)
