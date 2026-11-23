-- Форма пера одна: riddle_ink.lua. Таяние чернил (paintRegion) перерисовывает штрихи сквозь маску тем же
-- пером — при снятой маске пиксели холста совпадают с ink.stamp / ink.line на таком же холсте, в том числе
-- у краёв холста и на границе перерисовываемого окна (клип). Правка формы в одном месте ломает этот тест,
-- если второе место с копией формы осталось.
local t = require("t")

local NOW = 0
local function stub(name, mod) package.preload[name] = function() return mod end end
local nop = function() end

local ffi = require("ffi")

-- холст BB8, как в KOReader: data/stride, paintRect с клипом
local BB = {}
BB.__index = BB
function BB:getWidth() return self.w end
function BB:getHeight() return self.h end
function BB:fill(c) ffi.fill(self.data, self.w * self.h, c) end
function BB:free() end
function BB:paintRect(x, y, w, h, c)
  for yy = math.max(y, 0), math.min(y + h, self.h) - 1 do
    for xx = math.max(x, 0), math.min(x + w, self.w) - 1 do self.data[yy * self.w + xx] = c end
  end
end
local function newbb(w, h)
  local bb = setmetatable({ w = w, h = h, stride = w, data = ffi.new("uint8_t[?]", w * h) }, BB)
  bb:fill(0xFF)
  return bb
end

stub("ffi/blitbuffer", { COLOR_WHITE = 0xFF, COLOR_BLACK = 0, TYPE_BB8 = 1, new = newbb })
stub("device", { isKindle = function() return false end, screen = {} })
stub("ffi/freetype", { newFaceSize = function() return {} end })
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/rendertext", {})
stub("ui/uimanager", { scheduleIn = nop, unschedule = nop, nextTick = nop })
stub("ui/widget/widget", { extend = function(_, o) return o end })
stub("logger", { info = nop, warn = nop, err = nop, dbg = nop })
stub("ui/time", { monotonic = function() return NOW end, to_s = function(x) return x / 1e6 end,
                  to_ms = function(x) return x / 1e3 end, to_us = function(x) return x end })
stub("libs/libkoreader-lfs", { attributes = nop, dir = nop, mkdir = nop })

local Diary = require("riddle_diarywidget")
local ink = require("riddle_ink")

local W, H = 40, 30

local function same(a, b, msg)
  for i = 0, W * H - 1 do
    if a.data[i] ~= b.data[i] then
      error(string.format("%s: пиксель (%d,%d): %d вместо %d", msg, i % W, math.floor(i / W), a.data[i], b.data[i]), 2)
    end
  end
end

-- страница из одних штрихов (points — плоский список x,y), все на уровне lvl
local function page(strokes, lvl)
  local sts = {}
  for i, p in ipairs(strokes) do
    sts[i] = { p = p, b = { 0, 0, W, H }, lvl = lvl }
  end
  return setmetatable({ canvas = newbb(W, H), strokes = sts, prompt = {} }, { __index = Diary })
end

local STROKES = {
  { 10, 10 },                       -- точка
  { 0, 0 },                         -- угол холста: перо вылезает за край
  { W - 1, H - 1 },                 -- противоположный угол
  { 5, 20, 30, 24, 33, 5 },         -- ломаная
  { 20, 0, 20, H - 1 },             -- вертикаль через весь холст
}

-- то же перо на таком же холсте: ink.stamp, ink.line
local function reference()
  local ref = newbb(W, H)
  for _, p in ipairs(STROKES) do
    local px, py = p[1], p[2]
    ink.stamp(ref, px, py, 0)
    for i = 3, #p, 2 do
      ink.line(ref, px, py, p[i], p[i + 1], 0, ink.stamp)
      px, py = p[i], p[i + 1]
    end
  end
  return ref
end

local T = {}

function T.test_dissolve_pen_is_the_ink_pen_whole_canvas()
  local d = page(STROKES, -1) -- bucket > -1 всегда: маска пропускает всё
  d:paintRegion(0, 0, W, H)
  same(d.canvas, reference(), "штрихи на холсте и ink.stamp/ink.line")
end

-- окно перерисовки режет перо по своей границе: внутри окна — ink, снаружи — белое
function T.test_dissolve_pen_is_clipped_to_the_repaint_window()
  local d = page(STROKES, -1)
  d:paintRegion(8, 6, 17, 15)
  local want = reference()
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      if x < 8 or x >= 8 + 17 or y < 6 or y >= 6 + 15 then want.data[y * W + x] = 0xFF end
    end
  end
  same(d.canvas, want, "в окне 8,6 17x15")
end

-- маска по-прежнему решает: уровень выше всех корзин (маска не построена, все корзины 0) — холст белый
function T.test_dissolve_mask_still_gates_the_pen()
  local d = page(STROKES, 0) -- bucket > 0 ложно у всех пикселей
  d:paintRegion(0, 0, W, H)
  same(d.canvas, newbb(W, H), "уровень 0, пустая маска")
end

-- форма пера закреплена пикселями: крест из 12 — вертикаль 2×4 и горизонталь 4×2 вокруг точки (x, y); тесты выше сверяют
-- перо только с самим ink.stamp, правка формы их не краснит
function T.test_stamp_is_a_cross_of_12_pixels_around_the_point()
  local x, y = 10, 10
  local bb = newbb(W, H)
  ink.stamp(bb, x, y, 0)
  local want = {}
  for _, dx in ipairs({ -1, 0 }) do for dy = -2, 1 do want[(y + dy) * W + (x + dx)] = true end end
  for dx = -2, 1 do for _, dy in ipairs({ -1, 0 }) do want[(y + dy) * W + (x + dx)] = true end end
  local n = 0
  for _ in pairs(want) do n = n + 1 end
  t.eq(n, 12, "в ожидании крест из 12 пикселей")
  for i = 0, W * H - 1 do
    t.eq(bb.data[i] == 0, want[i] == true, string.format("пиксель (%d,%d)", i % W, math.floor(i / W)))
  end
end

-- образец страницы для модели (saveSample): те же штрихи малым пером на холсте вдвое меньше — пиксели совпадают с
-- ink.stamp_small / ink.line по точкам floor(p / 2)
function T.test_sample_is_the_small_pen_on_halved_points()
  local saved
  BB.writePNG = function(self) saved = self end
  local d = page(STROKES, 0)
  d.w, d.h = W, H
  local path = d:saveSample({ ink = { 0, 0, W - 1, H - 1 }, strokes = d.strokes })
  BB.writePNG = nil
  t.ok(path, "образец сохранён")
  local sw, sh = math.floor((W - 1) / 2) + 1, math.floor((H - 1) / 2) + 1
  t.eq(saved.w, sw)
  t.eq(saved.h, sh)
  local ref = newbb(sw, sh)
  for _, p in ipairs(STROKES) do
    local px, py = math.floor(p[1] / 2), math.floor(p[2] / 2)
    ink.stamp_small(ref, px, py, 0)
    for i = 3, #p, 2 do
      local nx, ny = math.floor(p[i] / 2), math.floor(p[i + 1] / 2)
      ink.line(ref, px, py, nx, ny, 0, ink.stamp_small)
      px, py = nx, ny
    end
  end
  for i = 0, sw * sh - 1 do
    if saved.data[i] ~= ref.data[i] then
      error(string.format("образец: пиксель (%d,%d): %d вместо %d", i % sw, math.floor(i / sw), saved.data[i],
        ref.data[i]))
    end
  end
end

-- страница на карте (MapView:paintPage, после перерисовки поля): те же пиксели, что ink.stamp / ink.line
function T.test_map_page_is_the_ink_pen()
  local MapView = require("riddle_mapview")
  local d = { w = W, h = H, canvas = newbb(W, H) }
  local v = MapView.new(d, {}, nil)
  local d2 = page(STROKES, 0)
  v.page = { strokes = d2.strokes }
  v:paintPage()
  same(d.canvas, reference(), "страница карты и ink.stamp/ink.line")
end

-- ломаная пера (одна на все места: таяние, образец, карта): перо в первой точке, ink.line между соседними, точки
-- через at (x, y) -> x, y, когда он есть
function T.test_polyline_is_stamp_then_lines()
  local got = newbb(W, H)
  for _, p in ipairs(STROKES) do ink.polyline(got, p, 0, ink.stamp) end
  same(got, reference(), "ink.polyline и ink.stamp/ink.line")
  local calls = {}
  local rec = { paintRect = function(_, x, y) calls[#calls + 1] = x .. "," .. y end }
  ink.polyline(rec, { 4, 6, 8, 6 }, 0, ink.stamp_small, function(x, y) return x / 2, y / 2 end)
  t.eq(table.concat(calls, " "), "2,3 2,3 3,3 4,3", "точки через at: перо в 2,3, черта 2,3 → 4,3")
end

t.run(T)
