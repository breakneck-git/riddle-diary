-- Даль по сети до экрана (riddle.cast, cast.reach): ленивый обход отвечает теми же далями и тем же запасом, что полный
-- обход Дейкстры по всей сети (Notion 41b13e60-bc8d-8189). Эталон — полный обход здесь же, простым выбором ближайшего.
local t = require("t")
local cast = require("riddle.cast")

local T = {}

local function len(x0, y0, x1, y1) return math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2) end
local function key(x, y) return x .. "," .. y end

-- точки, где может стоять гуляющий, как у улиц: через step px вдоль каждого отрезка { x, y, s, i } (целые пиксели);
-- extra — точки без пути (s nil), как точка парка без путей
local function points_of(lines, step, extra)
  local out = {}
  for s, q in ipairs(lines) do
    for i = 1, #q - 2, 2 do
      local x0, y0, x1, y1 = q[i], q[i + 1], q[i + 2], q[i + 3]
      local n = math.max(1, math.floor(len(x0, y0, x1, y1) / step))
      for k = 0, n - 1 do
        out[#out + 1] = { math.floor(x0 + (x1 - x0) * k / n + 0.5), math.floor(y0 + (y1 - y0) * k / n + 0.5), s, i }
      end
    end
  end
  for _, p in ipairs(extra or {}) do out[#out + 1] = { p[1], p[2] } end
  return out
end

-- эталон: полный обход от точек pts на экране (каждая — к обоим концам своего отрезка) по всем отрезкам lines ->
-- { ["x,y"] = даль } по всем узлам, до которых дойти
local function full(lines, pts, screen)
  local dist, adj, done = {}, {}, {}
  local function relax(k, d) if not dist[k] or d < dist[k] then dist[k] = d end end
  for _, q in ipairs(lines) do
    for i = 1, #q - 3, 2 do
      local a, b, w = key(q[i], q[i + 1]), key(q[i + 2], q[i + 3]), len(q[i], q[i + 1], q[i + 2], q[i + 3])
      adj[a] = adj[a] or {}
      adj[b] = adj[b] or {}
      table.insert(adj[a], { b, w })
      table.insert(adj[b], { a, w })
    end
  end
  for _, p in ipairs(pts) do
    if cast.on_screen(screen, p[1], p[2]) and p[3] then
      local q, i = lines[p[3]], p[4]
      relax(key(q[i], q[i + 1]), len(p[1], p[2], q[i], q[i + 1]))
      relax(key(q[i + 2], q[i + 3]), len(p[1], p[2], q[i + 2], q[i + 3]))
    end
  end
  while true do
    local best, bd
    for k, d in pairs(dist) do
      if not done[k] and (not bd or d < bd) then best, bd = k, d end
    end
    if not best then break end
    done[best] = true
    for _, e in ipairs(adj[best] or {}) do relax(e[1], bd + e[2]) end
  end
  return dist
end

-- все узлы сети (точки ломаных) в перемешанном порядке (генератор seed): ленивый обход отвечает на вопрос о дальнем
-- узле раньше, чем о ближнем, и наоборот
local function nodes_shuffled(lines, seed)
  local seen, out = {}, {}
  for _, q in ipairs(lines) do
    for i = 1, #q - 1, 2 do
      local k = key(q[i], q[i + 1])
      if not seen[k] then seen[k], out[#out + 1] = true, { q[i], q[i + 1] } end
    end
  end
  math.randomseed(seed)
  for i = #out, 2, -1 do
    local j = math.random(i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

-- сеть lines и её точки pts на экране screen: даль каждого узла (в перемешанном порядке) и запас — те же, что у
-- полного обхода; -> узлов с далью, узлов вне досягаемости
local function check(lines, pts, screen, seed, what)
  local ref = full(lines, pts, screen)
  local r = cast.reach(lines, pts, screen)
  local got, none = 0, 0
  for _, n in ipairs(nodes_shuffled(lines, seed)) do
    local want = ref[key(n[1], n[2])]
    t.eq(r.reaches(n[1], n[2]), want ~= nil, what .. ": дойти до экрана от узла " .. key(n[1], n[2]))
    t.eq(r.far(n[1], n[2]), want, what .. ": даль узла " .. key(n[1], n[2]))
    if want then got = got + 1 else none = none + 1 end
  end
  t.eq(r.far(-12345, -54321), nil, what .. ": точка не узел сети — даль nil")
  local on, off = r.sides()
  local won, woff = {}, {}
  for _, p in ipairs(pts) do
    if cast.on_screen(screen, p[1], p[2]) then won[#won + 1] = p
    elseif p[3] then
      local q = lines[p[3]]
      if ref[key(q[p[4]], q[p[4] + 1])] then woff[#woff + 1] = p end
    end
  end
  t.eq(#on, #won, what .. ": точек на экране")
  for k = 1, #won do t.ok(on[k] == won[k], what .. ": точка на экране " .. k .. " — та же и на том же месте") end
  t.eq(#off, #woff, what .. ": точек запаса, откуда экран достать")
  for k = 1, #woff do t.ok(off[k] == woff[k], what .. ": точка запаса " .. k .. " — та же и на том же месте") end
  return got, none
end

-- сетка G × G отрезков по step px (у узлов много путей одной длины) и кусок сети, не связанный с ней (вне
-- досягаемости), с тупиком
local function grid(G, step, ox, oy)
  local lines = {}
  for i = 0, G do
    for j = 0, G do
      local x, y = ox + i * step, oy + j * step
      if i < G then lines[#lines + 1] = { x, y, x + step, y } end
      if j < G then lines[#lines + 1] = { x, y, x, y + step } end
    end
  end
  return lines
end

function T.test_grid_ties_and_unreachable_piece()
  local lines = grid(8, 100, 0, 0)
  lines[#lines + 1] = { 1200, 100, 1300, 100, 1300, 250, 1450, 300 } -- отдельный кусок справа
  lines[#lines + 1] = { 1300, 250, 1300, 400 }
  local pts = points_of(lines, 40, { { 1250, 900 } })
  local screens = {
    { 0, 0, 380, 380 }, { 250, 250, 650, 650 }, { 620, 0, 1000, 330 }, { 1180, 80, 1460, 320 },
    { 1500, 1500, 1600, 1600 }, -- на экране ни одной точки: дали нет ни у кого
    { 0, 0, 1600, 1600 },
  }
  local got, none = 0, 0
  for k, scr in ipairs(screens) do
    local g, n = check(lines, pts, scr, k, "сетка, экран " .. k)
    got, none = got + g, none + n
  end
  t.ok(got > 0 and none > 0, "есть и узлы с далью, и вне досягаемости: " .. got .. " / " .. none)
  -- тот же экран после других: даль снова та же
  check(lines, pts, screens[2], 99, "сетка, экран 2 снова")
end

-- ломаные со скосами: дали — суммы корней, равенство путей ловит последний бит
function T.test_slanted_polylines()
  math.randomseed(17)
  local lines = {}
  local P = {}
  for i = 0, 6 do for j = 0, 6 do P[#P + 1] = { i * 230 + math.random(0, 60), j * 290 + math.random(0, 60) } end end
  local function at(i, j) return P[i * 7 + j + 1] end
  for i = 0, 6 do
    for j = 0, 6 do
      local a = at(i, j)
      if i < 6 and math.random() < 0.7 then local b = at(i + 1, j); lines[#lines + 1] = { a[1], a[2], b[1], b[2] } end
      if j < 6 and math.random() < 0.7 then local b = at(i, j + 1); lines[#lines + 1] = { a[1], a[2], b[1], b[2] } end
      if i < 6 and j < 6 and math.random() < 0.25 then
        local b, c = at(i + 1, j + 1), at(i + 1, j)
        lines[#lines + 1] = { a[1], a[2], b[1], b[2], c[1], c[2] }
      end
    end
  end
  local pts = points_of(lines, 40)
  for k, scr in ipairs({ { 0, 0, 758, 1024 }, { 600, 900, 1358, 1924 }, { 300, 400, 700, 800 } }) do
    check(lines, pts, scr, 100 + k, "скосы, экран " .. k)
  end
end

-- первый найденный путь до узла длиннее кратчайшего: ответ — кратчайший, не первая даль
function T.test_first_found_path_is_not_shortest()
  -- экран у (0, 0). X = (1000, 400): через (0, 400) — 400 + 1000, найден первым; через (500, 0) — 500 + 640,3
  local lines = { { 0, 0, 0, 400 }, { 0, 400, 1000, 400 }, { 0, 0, 500, 0 }, { 500, 0, 1000, 400 } }
  local pts = points_of(lines, 40)
  local scr = { -5, -5, 20, 20 }
  t.eq(cast.reach(lines, pts, scr).far(1000, 400), 500 + len(500, 0, 1000, 400), "X — по короткому пути")
  check(lines, pts, scr, 1, "первый путь не кратчайший")
end

-- разные точки — разные узлы сети: (1, 0) у экрана и точки (0, 2^k) — отдельные куски, от них экран не достать
-- (ключ точки, сливший бы их в один узел, соединил бы куски)
function T.test_distinct_points_are_distinct_nodes()
  local lines = { { 1, 0, 1, 10 } }
  for k = 8, 21 do lines[#lines + 1] = { 0, 2 ^ k, 0, 2 ^ k + 10 } end
  local pts = points_of(lines, 40)
  local scr = { -5, -5, 20, 20 }
  local r = cast.reach(lines, pts, scr)
  for k = 8, 21 do t.eq(r.reaches(0, 2 ^ k), false, "точка (0, 2^" .. k .. ") — не узел (1, 0)") end
  check(lines, pts, scr, 3, "разные точки")
end

-- запас и даль в одном обходе: сначала запас (все точки), потом дали — и наоборот
function T.test_sides_before_and_after_far()
  local lines = grid(5, 120, 0, 0)
  lines[#lines + 1] = { 900, 900, 1000, 900 }
  local pts = points_of(lines, 40)
  local scr = { 100, 100, 400, 400 }
  local ref = full(lines, pts, scr)
  local r = cast.reach(lines, pts, scr)
  local on, off = r.sides()
  t.ok(#on > 0 and #off > 0, "есть точки на экране и в запасе")
  for _, n in ipairs(nodes_shuffled(lines, 5)) do t.eq(r.far(n[1], n[2]), ref[key(n[1], n[2])], "даль после запаса") end
  local on2, off2 = cast.reach(lines, pts, scr).sides()
  t.ok(on2 == on and off2 == off, "тот же экран — тот же расчёт, не новый")
end

t.run(T)
