--[[--
The marauder's map: a mode of the diary widget (plan of the map, section 2). The diary keeps the input,
the canvas, the timers and push; the view draws the parchment on the diary's canvas and decides what
the ink on it means.

Slice 1: an empty parchment — white, a double frame, the "blind" line (no place is known yet). The map fills the
screen (owner, 2026-11-16): no title on top, no "© OpenStreetMap" line at the bottom. Ink on the map is a page of
its own: idle_s after its last pen-up a rose (riddle.rose) closes the map, anything else is wiped. No touch for
map_idle_s closes it as well.

Slice 3: a page on the map that is not a rose goes to the model (the diary's readMapPage): the closing phrase
("Mischief managed", the persona's own) closes the map.

Slice 4: the owner's point (riddle.mapjob.read_point). The "map" job brings one -> setPoint
repaints the parchment.

Slice 5: the terrain around the point (riddle.terrain, the file the "map" job writes; read through the diary's
map_terrain()). Streets and building outlines in ink (riddle_ink) from the inner frame to the inner frame
(INK_PAD from it); the screen is centered on the point, shifted inside the terrain's field.
No terrain -> no ink, the "blind" line instead. A terrain saved earlier stays when a new fetch fails, and it is
drawn even when it does not cover the point (or there is none): around its own center (MapView:anchor; spec, section
3: offline — the last saved terrain).

Slice 6: the terrain comes out like ink — the parchment first, then the lines in CFG.map_ink_batches batches (nearest to
the point first), the labels of the buildings (riddle.mapdata.label: the universe's places, no houses) with the last.
Each name stands once on the screen (named — the largest of the visible buildings of its kind, no name for a small park),
straight over the lines in blacker, bolder ink (no plate: owner 2026-11-16).

Slice 7: the heroes of the universe (riddle.cast: the hour, the weekday, the season and the kind of building) stand in
the field as a pair of footprints with the name under it; they ride with the field when it moves (slice 9), and a name
that would cross a label or another name is skipped, not the hero.

Slice 8: the heroes walk (riddle.cast.step) — a step every map_step_s while the map is open: the walkers go
20–40 px along the streets or the paths of their park (from the reserve towards the screen), the older footprints fade after map_trail steps. Only
the places whose footprints or names changed are painted again (lines, labels, heroes, the owner's page on top) and
refreshed with INK_WF; the step waits while the ink comes out, a finger lies in a zone or the pen is on the glass.
Closing the map stops it and logs the open's steps once (plan's A12).

Slice 9: the field moves under the finger (spec, decision 2). A stroke begun in the strip at any edge (map_edge_px)
moves the field by its vector on pen-up; the bottom strip (map_pad_px) is a touchpad: while the finger lies there the
map follows it, repainted at most once per map_drag_s (A2). The screen never leaves the terrain's field. Touches in
these zones are neither ink nor the map's page.

Slice 10: the map follows the owner. It opens on the saved point and terrain at once; the "map" job runs behind it
(MapView:setPoint): a point the same terrain covers moves the field by the difference like a finger does (the heroes
ride along, their steps go on); a new terrain far away replaces the old one on a full refresh (the names and heroes
placed anew); a far point without a new terrain leaves the old map as it is.

Slice 13a: the owner's book (spec, added 2026-11-16, decision 3). An open book at the owner's point — the screen's middle
when the map opens, riding with the field — and under it the name the owner gave the diary (data.owner; unknown — the
book alone). No book when the terrain does not cover the point (the anchor of slice 10 stands elsewhere). Laid out first:
the labels and the heroes' footprints and names keep off the book and the name.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ink = require("riddle_ink")
local terrain = require("riddle.terrain")
local mapdata = require("riddle.mapdata")
local cast = require("riddle.cast")
local layout = require("riddle.layout")
local logger = require("logger")
local time = require("ui/time")

local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK

local MapView = {}
MapView.__index = MapView

-- the frame: outer line FRAME_W px thick at FRAME_INSET px from the screen edge, a 1 px line FRAME_GAP inside it
local FRAME_INSET, FRAME_W, FRAME_GAP = 14, 3, 7
local INNER = FRAME_INSET + FRAME_W + FRAME_GAP -- the inner frame line
local INK_PAD = 4                                -- ink keeps this far from the inner frame
-- pens: streets — 2 px (plan); buildings — the same 2 px pen until riddle_ink has a 1 px one
MapView.STREET_PEN, MapView.BUILDING_PEN = ink.stamp_small, ink.stamp_small
local PEN_PX = 2
-- the ink appears in CFG.map_ink_batches batches, one every INK_STEP_S, each refreshed with INK_WF (partial, no flash)
MapView.INK_STEP_S, MapView.INK_WF = 0.3, "DU"
-- labels: the face's px (MarckScript readable on a 758 px wide screen), the width they wrap at; LABEL_GAP — the least
-- space between two of them. No plate under them (owner 2026-11-16: the white plates hid the map): the lines stay, the
-- text reads through blacker and bolder ink — LABEL_THRESHOLD (more of the glyph's AA goes black than on the page's
-- 0x80) and LABEL_BOLD (Diary:paintText's bold: the glyph drawn again 1 px to the right); LABEL_HALO — a line under a
-- text stops this many px from its letters (Diary:paintText's halo: white only around the ink, not a plate)
MapView.LABEL_PX, MapView.LABEL_W = 32, 240
MapView.LABEL_THRESHOLD, MapView.LABEL_BOLD, MapView.LABEL_HALO = 0xC0, { 1, 0 }, 2
local LABEL_GAP = 4

-- Diary:paintText's opts of a text on the map (a place's label, a hero's name) in px centered on cx (dry — only
-- measured)
local function labelOpts(px, cx, dry)
    return { px = px, cx = cx, maxw = MapView.LABEL_W, threshold = MapView.LABEL_THRESHOLD, bold = MapView.LABEL_BOLD,
             halo = MapView.LABEL_HALO, dry = dry }
end
-- a park smaller than this share of the screen's area is a square, not a place: no name (owner 2026-11-16: the forbidden
-- forest "almost everywhere")
MapView.PARK_MIN = 1 / 40

-- the diary's terrain reader (main.lua: riddle.mapjob.read_terrain); no reader or a failed read -> nil
local function readTerrain(diary)
    if not diary.map_terrain then return nil end
    local ok, t = pcall(diary.map_terrain)
    if not ok then
        logger.warn("riddle: map terrain read failed", t)
        return nil
    end
    return t
end

-- diary: the Diary widget (canvas, w, h, CFG, schedule/cancel, push, paintText, closeMap, map_terrain);
-- data: riddle.mapdata.of; point: the saved point or nil; seed: the open's number (the heroes rotate between opens);
-- kept: the cast of a map closed a moment ago (MapView:kept, slice 12/14) or nil — MapView:heroes places the same
-- heroes anew instead of picking the cast if they stood on the same terrain and the persona still has them all
function MapView.new(diary, data, point, seed, kept)
    return setmetatable({ diary = diary, data = data, point = point, seed = seed, terrain = readTerrain(diary),
                          kept_cast = kept, page = { strokes = {} }, shift = { 0, 0 } }, MapView)
end

local round = terrain.round

-- where a size px long thing centered on c starts, shifted to stay within lo..hi (a text in the ink box)
local function fit(lo, hi, c, size)
    return math.max(lo, math.min(hi - size, round(c - size / 2)))
end

-- the screen's top left in the terrain's field: the screen (sw × sh) centered on the point
local function origin(t, point, sw, sh)
    local dx, dy = terrain.offset(t, point)
    return t.w / 2 + dx - sw / 2, t.h / 2 + dy - sh / 2
end

local bounds = terrain.bounds

-- one way (a street or a building outline, field pixels) onto bb in pen, shifted by the screen's origin (ox, oy)
-- and clipped to box = { left, top, right, bottom } (screen pixels)
local function drawWay(bb, pts, pen, ox, oy, box)
    local l, tp, r, b = box[1], box[2], box[3] - PEN_PX, box[4] - PEN_PX
    for i = 1, #pts - 2, 2 do
        local x0, y0, x1, y1 = pts[i] - ox, pts[i + 1] - oy, pts[i + 2] - ox, pts[i + 3] - oy
        local t0, t1 = terrain.clip(x0, y0, x1, y1, l, tp, r, b)
        if t0 then
            ink.line(bb, round(x0 + (x1 - x0) * t0), round(y0 + (y1 - y0) * t0),
                round(x0 + (x1 - x0) * t1), round(y0 + (y1 - y0) * t1), BLACK, pen)
        end
    end
end

local function frame(bb, x, y, w, h, t, c)
    bb:paintRect(x, y, w, t, c)
    bb:paintRect(x, y + h - t, w, t, c)
    bb:paintRect(x, y, t, h, c)
    bb:paintRect(x + w - t, y, t, h, c)
end

-- the parchment without the terrain onto the diary's canvas (no refresh): white, the frame, and either nothing more
-- (a terrain to draw: self.box — where its ink goes, self.ox/oy — the screen's top left in its field) or the "blind"
-- line (self.box = nil)
function MapView:paintParchment()
    local d = self.diary
    local bb = d.canvas
    bb:fill(WHITE)
    local i, j = FRAME_INSET, INNER
    frame(bb, i, i, d.w - 2 * i, d.h - 2 * i, FRAME_W, BLACK)
    frame(bb, j, j, d.w - 2 * j, d.h - 2 * j, 1, BLACK)
    self.box = nil
    local view = self:viewPoint() -- the point the screen is centered on: the anchor, moved by the finger (slice 9)
    if not view then
        -- nothing to draw: no terrain saved yet (offline or Overpass failed on the first open)
        d:paintText(self.data.blind, math.floor(d.h / 2))
        return
    end
    self.box = { j + 1 + INK_PAD, j + 1 + INK_PAD, d.w - j - INK_PAD, d.h - j - INK_PAD }
    self.ox, self.oy = origin(self.terrain, view, d.w, d.h)
end

-- the terrain's streets and buildings whose bounds reach into the ink box, nearest to its middle first (the ink spreads
-- from where the owner is) -> { { pts, pen, bld?, cx, cy, b }, … } (pts — field pixels, as in the terrain; bld — the
-- building, nil for a street; cx, cy — the middle of the bounds on screen; b — the bounds, field pixels)
function MapView:visibleWays()
    local box, ox, oy = self.box, self.ox, self.oy
    if not box then return {} end
    local l, tp, r, b = box[1] + ox, box[2] + oy, box[3] + ox, box[4] + oy
    local mx, my = (l + r) / 2, (tp + b) / 2
    local ways = {}
    local function add(pts, pen, bld)
        local x0, y0, x1, y1 = bounds(pts)
        if x1 < l or x0 > r or y1 < tp or y0 > b then return end
        local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        ways[#ways + 1] = { pts = pts, pen = pen, bld = bld, cx = cx - ox, cy = cy - oy, b = { x0, y0, x1, y1 },
                            dist = (cx - mx) ^ 2 + (cy - my) ^ 2, n = #ways + 1 }
    end
    for _, bld in ipairs(self.terrain.buildings) do add(bld.pts, MapView.BUILDING_PEN, bld) end
    for _, s in ipairs(self.terrain.streets) do add(s, MapView.STREET_PEN) end
    table.sort(ways, function(p, q)
        if p.dist ~= q.dist then return p.dist < q.dist end
        return p.n < q.n
    end)
    return ways
end

-- the ink of the terrain in CFG.map_ink_batches batches (the lines come out like ink: plan of the map, slice 6),
-- every way on screen in exactly one, nearest first -> { { way, … }, … } (no terrain on screen -> {}).
-- ways — self:visibleWays(), when the caller has them already
function MapView:inkSteps(ways)
    ways = ways or self:visibleWays()
    local size = math.ceil(#ways / math.max(1, self.diary.CFG.map_ink_batches))
    local steps = {}
    for k, way in ipairs(ways) do
        local n = math.floor((k - 1) / size) + 1
        steps[n] = steps[n] or {}
        table.insert(steps[n], way)
    end
    return steps
end

-- the area of an outline {x1,y1,…} (closed or not), px²
local function area(pts)
    local s, n = 0, #pts
    for i = 1, n - 1, 2 do
        local j = i + 2 > n - 1 and 1 or i + 2
        s = s + pts[i] * pts[j + 1] - pts[j] * pts[i + 1]
    end
    return math.abs(s) / 2
end

-- which building on screen carries which name, once on the screen (owner 2026-11-16: "several Hogwarts"): of the
-- buildings whose middle is in the ink box with the same place's name (riddle.mapdata.label) — the largest outline, on a
-- tie the one nearer the screen's middle (ways come nearest first); a park under PARK_MIN of the screen gets none. Chosen
-- among the visible ones, not on the whole field: the largest of the field lay off screen and took its name with it
-- (live terrain 2026-11-16: one label of twelve) -> { [building] = name }
local function named(self, ways)
    local d, box = self.diary, self.box
    local best = {} -- name -> { bld, area }
    for _, way in ipairs(ways) do
        local bld = way.bld
        local text = bld and cast.on_screen(box, way.cx, way.cy) and mapdata.label(self.data, bld.kind)
        local a = text and area(bld.pts)
        if a and not (bld.kind == "park" and a < d.w * d.h * MapView.PARK_MIN) then
            local b = best[text]
            if not b or a > b.area then best[text] = { bld = bld, area = a } end
        end
    end
    local names = {}
    for text, b in pairs(best) do names[b.bld] = text end
    return names
end

-- the names on the map (the heroes', the owner's) in px: half the answer's
local function namePx(d)
    return math.floor(d.CFG.answer_px / 2)
end

---------------------------------------------------------------------------
-- slice 13a: the owner's book and name

-- the book's half width, px (its half height — two thirds of it); its pen — the lines' 2 px one
MapView.BOOK = 12
local BOOK_PEN = ink.stamp_small
-- the air between the book and its name
local NAME_PAD = 4

-- the open book centered on the screen pixel (x, y): two pages slanting from the spine, a line of writing on each ->
-- its polylines { { x1, y1, x2, y2, … }, … } (screen px), its edges { x0, y0, x1, y1 } (the pen's pixels included)
local function book(x, y)
    local b = MapView.BOOK
    local h = math.floor(b * 2 / 3)
    local lines = {
        { x, y - h + 2, x - b, y - h, x - b, y + h - 2, x, y + h }, -- the left page
        { x, y - h + 2, x + b, y - h, x + b, y + h - 2, x, y + h }, -- the right page
        { x, y - h + 2, x, y + h },                                 -- the spine
        { x - b + 3, y - 3, x - 3, y - 2 }, { x - b + 3, y + 1, x - 3, y + 2 },
        { x + 3, y - 2, x + b - 3, y - 3 }, { x + 3, y + 2, x + b - 3, y + 1 },
    }
    return lines, { x - b, y - h, x + b + PEN_PX - 1, y + h + PEN_PX - 1 }
end

-- the owner's mark on screen now: the book at the owner's point (the finger's shift included) and the name
-- (data.owner) under it — above it at the bottom of the ink box, none when wider than the ink box, the heroes' names' px
-- and ink -> { book = edges, lines (book's), name = { text, rect = { x, y, w, h }, edges } | nil } | nil: no ink box, no
-- point the terrain covers (MapView:anchor stands elsewhere: as the anchor of slice 10), the book not whole in the ink box
function MapView:ownerMark()
    local box, p, t = self.box, self.point, self.terrain
    if not box or not p or self:anchor() ~= p then return nil end
    local dx, dy = terrain.offset(t, p)
    local x, y = round(t.w / 2 + dx - self.ox), round(t.h / 2 + dy - self.oy)
    local lines, e = book(x, y)
    if e[1] < box[1] or e[2] < box[2] or e[3] >= box[3] or e[4] >= box[4] then return nil end
    local mark = { book = e, lines = lines }
    local text = self.data.owner
    if not text then return mark end
    local size = self.diary:paintText(text, 0, labelOpts(namePx(self.diary), x, true))
    if size.w > box[3] - box[1] then return mark end
    local top = e[4] + 1 + NAME_PAD
    if top + size.h > box[4] then top = e[2] - NAME_PAD - size.h end
    if top < box[2] then return mark end
    local r = { x = fit(box[1], box[3], x, size.w), y = top, w = size.w, h = size.h }
    mark.name = { text = text, rect = r, edges = { r.x, r.y, r.x + r.w - 1, r.y + r.h - 1 } }
    return mark
end

-- the screen the mark keeps for itself: the book and the name, each grown by the reach of a text's ink (a label's or a
-- hero's name's letters and halo never reach them) -> { { x0, y0, x1, y1 }, … } ({} without a mark)
local function ownerBlocks(mark)
    if not mark then return {} end
    local m = layout.text_reach(MapView.LABEL_HALO)
    local function grow(e) return { e[1] - m, e[2] - m, e[3] + m, e[4] + m } end
    local out = { grow(mark.book) }
    if mark.name then out[2] = grow(mark.name.edges) end
    return out
end

-- the labels of the buildings on screen: the name the building carries on screen (named) centered on the outline,
-- shifted inside the ink box; one that would cross the owner's mark (laid out first) or a label placed before it is
-- skipped (nearest first) -> { { text, rect = { x, y, w, h } }, … }; ways — as for inkSteps; mark — the owner's mark
-- when the caller has it (MapView:ownerMark)
function MapView:labels(ways, mark)
    local d, box = self.diary, self.box
    local out = {}
    if not box then return out end
    ways = ways or self:visibleWays()
    local taken = ownerBlocks(mark or self:ownerMark())
    local names = named(self, ways)
    for _, way in ipairs(ways) do
        local text = way.bld and names[way.bld]
        if text then
            local m = d:paintText(text, 0, labelOpts(MapView.LABEL_PX, way.cx, true))
            if m.w <= box[3] - box[1] and m.h <= box[4] - box[2] then
                local r = { x = fit(box[1], box[3], way.cx, m.w), y = fit(box[2], box[4], way.cy, m.h), w = m.w,
                            h = m.h }
                local edges, free = { r.x, r.y, r.x + r.w - 1, r.y + r.h - 1 }, true
                for _, e in ipairs(taken) do
                    if layout.near(edges, e, LABEL_GAP) then free = false break end
                end
                for _, o in ipairs(out) do
                    if layout.near(edges, o.edges, LABEL_GAP) then free = false break end
                end
                if free then out[#out + 1] = { text = text, rect = r, edges = edges } end
            end
        end
    end
    return out
end

local function drawBatch(self, batch)
    local bb = self.diary.canvas
    for _, way in ipairs(batch) do drawWay(bb, way.pts, way.pen, self.ox, self.oy, self.box) end
end

-- items ({ { text, rect = { x, y, w, h } }, … }) appended to into as texts in px -> into
local function texts(into, items, px)
    for _, l in ipairs(items) do into[#into + 1] = { text = l.text, rect = l.rect, px = px } end
    return into
end

-- the map's texts (texts: the labels, the owner's name, the heroes' names) straight over the ink (no plate: owner
-- 2026-11-16, the white plates hid the map) in the labels' ink (labelOpts), all in one Diary:paintTexts: every halo
-- before any text's ink — a halo never whitens a neighbour's letters (MarckScript's Latin reaches past its rect); the
-- halo whitens only inside clip (default the ink box — the frame stays; a step's repaint — its rect)
local function inkTexts(self, items, clip)
    local list = {}
    for i, l in ipairs(items) do
        local opts = labelOpts(l.px, l.rect.x + l.rect.w / 2)
        opts.clip = clip or self.box
        list[i] = { l.text, l.rect.y, opts }
    end
    if #list > 0 then self.diary:paintTexts(list) end
end

-- the owner's mark of a full paint (MapView:ownerMark); the log gets whether the book and the name are there when that
-- changes (a pan paints the same again) — no name, no coordinates
local function markOwner(self)
    local mark = self:ownerMark()
    local line = string.format("riddle: map owner book=%d name=%d", mark and 1 or 0, mark and mark.name and 1 or 0)
    if line ~= self.owner_line then
        logger.info(line)
        self.owner_line = line
    end
    return mark
end

-- the owner's book onto the canvas, after the texts (their halos never whiten it)
local function drawBook(self, mark)
    local bb = self.diary.canvas
    for _, l in ipairs(mark.lines) do drawWay(bb, l, BOOK_PEN, 0, 0, self.box) end -- the book is whole in the ink box
end

---------------------------------------------------------------------------
-- slice 7: the heroes of the universe (riddle.cast) — a pair of footprints and the name under it

-- the footprints reach FOOT px from the hero's point; FEET — the riddle_ink.stamp's of them: the left foot a step behind
-- the right one, two stamps a foot
MapView.FOOT = 6
-- the air between a hero's footprints and a label, and between the footprints and the hero's own name
local HERO_PAD = 4
local FEET = { { -4, 0 }, { -4, 4 }, { 4, -4 }, { 4, 0 } }

-- the part of the field where a hero's footprints are on screen now (the ink box less FOOT, field pixels):
-- riddle.cast.on_screen's screen
function MapView:heroScreen()
    local box, f = self.box, MapView.FOOT
    return { box[1] + f + self.ox, box[2] + f + self.oy, box[3] - f + self.ox, box[4] - f + self.oy }
end

-- the rows of the persona's cast (data.cast) with these names -> the rows | nil (one of the names is gone from it)
local function castOf(names, list)
    local want, out = {}, {}
    for _, n in ipairs(names) do want[n] = true end
    for _, c in ipairs(list) do
        if want[c.name] then
            out[#out + 1] = c
            want[c.name] = nil
        end
    end
    if next(want) then return nil end
    return out
end

-- the heroes on the field (riddle.cast.place: the hour, the weekday, the season now — diary.map_clock(); the open's
-- seed), placed once per terrain, where the screen is at that moment; they ride with the field when it moves and walk
-- a step every map_step_s (MapView:step). Slice 12/14: the first terrain of the open takes the kept heroes' names
-- (the same cast, placed anew the way a fresh open places them: the hour now, the screen now, no footprints) if they
-- stood on the same terrain and the persona still has them all; kept is tried once — a later terrain (far) picks the
-- cast anew. The kept cast stays the cast even when some of them have nowhere to stand this hour (no streets, no
-- homes: riddle.cast leaves them out) — MapView:kept gives all of them, so a row of opens does not lose them. The log
-- gets how many, how many on screen and the local hour (plan's A6), "kept" for the kept cast — no names, no coordinates
function MapView:heroes()
    local t = self.terrain
    if self.cast_for == t then return self.cast_state.heroes end
    local screen, kept = self:heroScreen(), self.kept_cast
    self.kept_cast = nil
    local list = kept and MapView.sameTerrain(kept.terrain, t) and castOf(kept.names, self.data.cast)
    local now = self.diary.map_clock()
    local state = { heroes = cast.place(list or self.data.cast, t, now, self.seed or 1, screen, list and true),
                    screen = screen, trail = self.diary.CFG.map_trail }
    local line = (list and "riddle: map cast kept" or "riddle: map cast") .. " n=%d visible=%d hour=" .. now.hour
    local v = 0
    for _, h in ipairs(state.heroes) do
        if cast.on_screen(screen, h.x, h.y) then v = v + 1 end
    end
    logger.info(string.format(line, #state.heroes, v))
    local names = {}
    for i, h in ipairs(list or state.heroes) do names[i] = h.name end
    self.cast_for, self.cast_state, self.cast_names = t, state, names
    return state.heroes
end

-- the cast to keep when the map closes (slice 12/14; Diary:closeMap): { terrain, names } — the terrain they stand on
-- and the names of the heroes on it (not their places, footprints or tick: a map opened again places them anew); a
-- kept cast — all its names, those with nowhere to stand this hour too (MapView:heroes); nil while none are placed on
-- the terrain on screen (blind, not painted yet) or there are none (the persona's map.cast not generated yet: they
-- come with it)
function MapView:kept()
    local t = self.terrain
    if not t or self.cast_for ~= t or #self.cast_names == 0 then return nil end
    return { terrain = t, names = self.cast_names }
end

-- a rect { x0, y0, x1, y1 } with the edges included (as edges everywhere here) -> the same with the right and bottom
-- excluded (riddle_ink's boxes, Diary:paintText's clip)
local function exclusive(r)
    return { r[1], r[2], r[3] + 1, r[4] + 1 }
end

-- the heroes' ink on screen now, after the labels and the owner's mark: a pair of footprints at every point of a hero on
-- screen — the hero's place now and trail (riddle.cast.step: the older points fade) — never under a label or the mark
-- (moved just below it, or above at the bottom of the screen); the name (namePx, the labels' ink) under the footprints
-- of the place now, skipped — not the hero — when it would cross a label, the mark, a name placed before it or someone
-- else's footprints. mark — MapView:ownerMark's (nil: none).
-- -> { { key, rect = { x0, y0, x1, y1 } (the screen it inks, edges included), feet = { x, y } | name =
-- { text, rect = { x, y, w, h } } }, … } (all the footprints first, then the names), how many heroes on screen
local function heroInk(self, labels, mark)
    local d, box, f = self.diary, self.box, MapView.FOOT
    local items = {}
    if not box then return items, 0 end
    local pad = HERO_PAD
    local screen = self:heroScreen()
    local taken = ownerBlocks(mark) -- the screen the footprints and the names keep off: the mark, the labels
    for _, l in ipairs(labels) do taken[#taken + 1] = l.edges end
    -- the block of the taken screen a footprint pair at the screen point (x, y) would touch | nil
    local function hit(x, y)
        for _, e in ipairs(taken) do
            if layout.near({ x - f, y - f, x + f - 1, y + f - 1 }, e, pad) then return e end
        end
    end
    -- a footprint pair at the field point (fx, fy) on screen -> its screen point, kept off the taken screen | nil (off
    -- screen; no free place). On a block it goes just below it, or above it; when that is taken too (the book at the
    -- bottom, its name above it) — just below or above any other block: the first place free and inside the ink box
    local function foot(fx, fy)
        if not cast.on_screen(screen, fx, fy) then return nil end
        local x, y = round(fx - self.ox), round(fy - self.oy)
        local first = hit(x, y)
        if not first then return x, y end
        local blocks = { first }
        for _, e in ipairs(taken) do blocks[#blocks + 1] = e end
        for _, e in ipairs(blocks) do
            for _, cy in ipairs({ e[4] + pad + f + 1, e[2] - pad - f - 1 }) do
                if cy - f >= box[2] and cy + f <= box[4] and not hit(x, cy) then return x, cy end
            end
        end
        return nil
    end
    local feet, shown = {}, {}
    for _, h in ipairs(self:heroes()) do
        local pts = {}
        for _, p in ipairs(h.trail or {}) do pts[#pts + 1] = p end
        local here = not h.gone -- gone (riddle.cast.step): only the fading trail, no place now and no name
        if here then pts[#pts + 1] = { h.x, h.y } end
        for k, p in ipairs(pts) do
            local x, y = foot(p[1], p[2])
            if x then
                local e = { owner = h.name, x = x, y = y, edges = { x - f, y - f, x + f - 1, y + f - 1 } }
                feet[#feet + 1] = e
                items[#items + 1] = { key = "f" .. x .. "," .. y, feet = { x, y }, rect = e.edges }
                if here and k == #pts then shown[#shown + 1] = e end
            end
        end
    end
    local px = namePx(d)
    local m = layout.text_reach(MapView.LABEL_HALO) -- the name's ink reaches past its measured rect
    -- the name's letters overhang its rect sideways (MarckScript): kept inside the ink box, since a step whitens only
    -- inside it — a name at the side would leave its letters there when it goes
    local o = layout.TEXT_OVERHANG
    for _, s in ipairs(shown) do
        local size = d:paintText(s.owner, 0, labelOpts(px, s.x, true))
        local top = s.y + f + pad -- a little air under its own footprints
        if size.w <= box[3] - box[1] - 2 * o and top + size.h <= box[4] then
            local r = { x = fit(box[1] + o, box[3] - o, s.x, size.w), y = top, w = size.w, h = size.h }
            local edges, free = { r.x, r.y, r.x + r.w - 1, r.y + r.h - 1 }, true
            for _, e in ipairs(taken) do
                if layout.near(edges, e, LABEL_GAP) then free = false break end
            end
            for _, other in ipairs(feet) do
                if free and other.owner ~= s.owner and layout.near(edges, other.edges, LABEL_GAP) then free = false end
            end
            if free then
                items[#items + 1] = { key = "n" .. s.owner .. "," .. r.x .. "," .. r.y, name = { text = s.owner, rect = r },
                                      rect = { edges[1] - m, edges[2] - m, edges[3] + m, edges[4] + m } }
                taken[#taken + 1] = edges
            end
        end
    end
    return items, #shown
end

-- a heroInk item is drawn by a paint with clip: all of them (clip nil), or those meeting it (a step's repaint, edges
-- included)
local function meets(it, clip)
    return not clip or layout.near(it.rect, clip, 0)
end

-- the hero names of heroInk's items drawn with clip (meets) -> texts (into)
local function heroNames(self, items, clip, into)
    local names = {}
    for _, it in ipairs(items) do
        if it.name and meets(it, clip) then names[#names + 1] = it.name end
    end
    return texts(into, names, namePx(self.diary))
end

-- the footprints of heroInk's items drawn with clip (meets) onto the canvas
local function drawFeet(self, items, clip)
    local bb = self.diary.canvas
    for _, it in ipairs(items) do
        if it.feet and meets(it, clip) then
            for _, o in ipairs(FEET) do ink.stamp(bb, it.feet[1] + o[1], it.feet[2] + o[2], BLACK) end
        end
    end
end

-- the labels, the owner's mark and the heroes onto the canvas over the lines (a full paint, the reveal's last batch):
-- the mark laid out first, the labels and the heroes keep off it; all the texts at once (inkTexts), then the book and
-- the footprints. What is drawn is kept for the steps (MapView:step) -> the labels
local function drawMarks(self, ways)
    local mark = markOwner(self)
    local ls = self:labels(ways, mark)
    local items = heroInk(self, ls, mark)
    local all = texts({}, ls, MapView.LABEL_PX)
    if mark and mark.name then texts(all, { mark.name }, namePx(self.diary)) end
    inkTexts(self, heroNames(self, items, nil, all))
    if mark then drawBook(self, mark) end
    drawFeet(self, items)
    self.drawn = { ways = ways, labels = ls, ink = items, owner = mark }
    return ls
end

-- the ink appearing step by step stops (the map closes, or is painted whole) -> it was still going
function MapView:stopReveal()
    local task = self.reveal_task
    self.reveal_task = nil
    if task then self.diary:cancel(task) end
    return task ~= nil
end

-- the whole parchment onto the diary's canvas at once (no refresh); an appearing ink stops ->
-- true when it was cut short or the owner moved meanwhile (setPoint: self.stale) — the caller's refresh has to cover the
-- whole screen
function MapView:paint()
    local cut = self:stopReveal() or self.stale == true
    self.stale = nil
    self:paintParchment()
    local ways = self:visibleWays()
    for _, batch in ipairs(self:inkSteps(ways)) do drawBatch(self, batch) end
    if self.box then
        drawMarks(self, ways)
    else
        self.drawn = nil -- "blind": nothing for the steps
    end
    return cut
end

-- the parchment on screen now (mode), the terrain's lines come out of it like ink: a batch every INK_STEP_S (DU),
-- the labels with the last one; the log gets the time from the parchment to the last line (plan's A7)
function MapView:reveal(mode)
    self:stopReveal()
    local d = self.diary
    local t0 = time.monotonic()
    self:paintParchment()
    self.drawn = nil -- the heroes step again once the ink is out
    d:push(0, 0, d.w, d.h, mode)
    if not self.box then return end
    local visible = self:visibleWays()
    local steps = self:inkSteps(visible)
    local n, k, ways = math.max(#steps, 1), 0, 0
    local function step()
        if d.cur then
            -- never refresh under the moving pen (its A2 ink would collide): the batch waits a step
            self.reveal_task = d:schedule(MapView.INK_STEP_S, step)
            return
        end
        self.reveal_task = nil
        k = k + 1
        local batch = steps[k] or {}
        drawBatch(self, batch)
        ways = ways + #batch
        local labels
        if k == n then
            labels = #drawMarks(self, visible)
            -- the owner's strokes written during the reveal stay on top of the labels and names, as in pan()
            self:paintPage()
        end
        local box = self.box
        d:push(box[1], box[2], box[3] - box[1], box[4] - box[2], MapView.INK_WF)
        if k < n then
            self.reveal_task = d:schedule(MapView.INK_STEP_S, step)
        else
            logger.info(string.format("riddle: map drawn ways=%d labels=%d in %d ms", ways, labels,
                round(time.to_ms(time.monotonic() - t0))))
        end
    end
    self.reveal_task = d:schedule(MapView.INK_STEP_S, step)
end

-- the same terrain on screen: no terrain on both sides, or the same field (a new one is fetched only around a new
-- center) and as many ways. One rule for setPoint and for the kept heroes (MapView:heroes)
function MapView.sameTerrain(a, b)
    if not a or not b then return a == b end
    return a.center.lat == b.center.lat and a.center.lon == b.center.lon and a.w == b.w and a.h == b.h
        and a.m_per_px == b.m_per_px and #a.streets == #b.streets and #a.buildings == #b.buildings
end

-- the point's pixel on the terrain (nil without one of them)
local function pixel(t, point)
    if not (t and point) then return nil end
    local dx, dy = terrain.offset(t, point)
    return round(dx) .. "," .. round(dy)
end

-- the "map" job is back (slice 10: the owner moved). fetched: the job wrote a new terrain (riddle.mapjob.fetched) —
-- only then the file is read again (once an open else). On a map with ink on it:
-- * the same terrain covers the new point (near) -> the field moves by the difference the way a finger moves it (the
--   whole map at once, A2: MapView:repaint), the heroes ride with it and keep walking;
-- * a new terrain (far) -> it replaces the old one: the finger's shift goes, the ink comes out again on a full refresh,
--   the names and the heroes are placed anew; the step timer goes on;
-- * the new point is off the terrain and no new one came (offline, Overpass failed) -> the old map stays as it is.
-- A "blind" map: a point where there was none or a new terrain -> the terrain's ink comes out (reveal). Ink on the map
-- (its page, or the pen on the glass) is not wiped: the move waits for the next paint (onPageDone), which then
-- refreshes the whole screen (self.stale). The log gets "near" or "far" — no coordinates
function MapView:setPoint(point, fetched)
    local had, old = self.point, self.terrain
    local t = old
    if fetched then
        local fresh = readTerrain(self.diary)
        -- the same terrain read again stays the same table: the heroes on it (and its names) keep their places; a
        -- failed read keeps the terrain on screen (never "blind" with one)
        if fresh and not MapView.sameTerrain(old, fresh) then t = fresh end
    end
    local inked = old ~= nil -- a terrain is never "blind" (MapView:anchor)
    if point and inked and t == old and not terrain.covers(old, point) then return end -- far, no new terrain
    self.point, self.terrain = point, t
    if not point then return end
    if had and t == old and pixel(old, had) == pixel(t, point) then return end
    local d = self.diary
    local near = inked and t == old
    if inked then
        if not near then self.shift = { 0, 0 } end -- the finger moved the old field
        logger.info("riddle: map moved " .. (near and "near" or "far"))
    end
    if #self.page.strokes > 0 or d.cur then
        self.stale = true
        -- the old terrain coming out would end with the new one's names and heroes on the old screen
        if not near then self:stopReveal() end
        return
    end
    if near then
        self:repaint()
    else
        self:reveal(inked and "full" or d.CFG.dissolve.wf)
    end
end

function MapView:open()
    self.steps = { n = 0, px = 0, ms = 0 }
    self:reveal("full")
    self:touch()
    self:stepLater()
end

-- a touch on the map: the autoclose counts again, the page of ink on it is still being written
function MapView:touch()
    local d = self.diary
    d:cancel(self.idle_task)
    d:cancel(self.page_task)
    self.page_task = nil
    self.idle_task = d:schedule(d.CFG.map_idle_s, function()
        self.idle_task = nil
        d:closeMap("idle")
    end)
end

-- the pen lifted: the stroke joins the map's page (its ink box grows by the stroke's), idle_s of silence ends the page
function MapView:onStrokeDone(stroke)
    local pg, sb = self.page, stroke.b
    pg.strokes[#pg.strokes + 1] = stroke
    local b = pg.ink
    pg.ink = b and { math.min(b[1], sb[1]), math.min(b[2], sb[2]), math.max(b[3], sb[3]), math.max(b[4], sb[4]) }
        or { sb[1], sb[2], sb[3], sb[4] }
    self:touch()
    self:pageLater()
end

-- the map's page ends idle_s from now
function MapView:pageLater()
    local d = self.diary
    self.page_task = d:schedule(d.CFG.idle_s, function()
        self.page_task = nil
        self:onPageDone()
    end)
end

-- a straight stroke from the edge is a pan, but may be a rose's bar written near the edge: the last few are kept
-- (EDGE_PANS) for the page's rose check
local EDGE_PANS = 8

-- an edge pan: its points, from t0 (the finger down) to now (lifted)
function MapView:rememberEdgePan(p, t0)
    local list = self.edge_pans or {}
    self.edge_pans = list
    list[#list + 1] = { p = p, t0 = t0, t1 = time.monotonic() }
    if #list > EDGE_PANS then table.remove(list, 1) end
end

-- the page's strokes plus the edge pans chained to them: a pan joins when idle_s or less lies between it and a stroke
-- of the page or a pan already joined, before or after it (each from its pen-down to its pen-up) — a rose with its
-- bars begun at the edge is still a rose: drawn before a slow circle, or one after another after it (the owner's roses:
-- both bars from the strips, review of batch 4); a pan farther than idle_s from all of them is not part of the page.
-- Only pans after the page's first stroke extend the chain: one before it joins only near a stroke itself, so a few
-- finger pans just before a rose do not hang on to it (review of batch 4)
local function roseWithEdgePans(self, pg)
    if not self.edge_pans or #pg.strokes == 0 then return false end
    local d = self.diary
    local spans = {} -- { t0, t1 } of the page's strokes and the joined pans
    local first = math.huge -- the page's first pen-down
    for _, s in ipairs(pg.strokes) do
        if s.t0 and s.t_end then
            spans[#spans + 1] = { s.t0, s.t_end }
            first = math.min(first, s.t0)
        end
    end
    local function near(e)
        for _, sp in ipairs(spans) do
            if time.to_s(math.max(sp[1] - e.t1, e.t0 - sp[2])) <= d.CFG.idle_s then return true end
        end
        return false
    end
    local all, joined = {}, {}
    for i, s in ipairs(pg.strokes) do all[i] = s end
    local grew = true
    while grew do
        grew = false
        for k, e in ipairs(self.edge_pans) do
            if not joined[k] and near(e) then
                joined[k], grew = true, true
                -- a pan before the page joins only directly: finger panning before a rose does not chain to it
                if e.t0 >= first then spans[#spans + 1] = { e.t0, e.t1 } end
                all[#all + 1] = { p = e.p }
            end
        end
    end
    return #all > #pg.strokes and d:isRose(all)
end

function MapView:onPageDone()
    local pg = self.page
    self.page = { strokes = {} }
    local d = self.diary
    local rose = d:isRose(pg.strokes) or roseWithEdgePans(self, pg)
    self.edge_pans = nil
    if rose then
        d:closeMap("rose")
        return
    end
    -- not a rose: the model reads the page for the closing phrase (slice 3, Diary:readMapPage); the ink goes, the
    -- parchment stays
    local b = pg.ink
    if not b then return end
    d:readMapPage(pg)
    if self:paint() then
        -- the terrain was still coming out: the rest of it is on the canvas only
        d:push(0, 0, d.w, d.h, d.CFG.dissolve.wf)
        return
    end
    d:push(b[1] - 4, b[2] - 4, b[3] - b[1] + 9, b[4] - b[2] + 9, d.CFG.dissolve.wf)
end

function MapView:close()
    local d = self.diary
    d:cancel(self.idle_task)
    d:cancel(self.page_task)
    d:cancel(self.drag_task)
    d:cancel(self.step_task)
    self.idle_task, self.page_task, self.drag_task, self.drag, self.step_task = nil, nil, nil, nil, nil
    self:stopReveal()
    -- the tester's measure (plan's A12): the steps of this open, the px they refreshed, the longest — no names, no points
    local st = self.steps
    if st then
        logger.info(string.format("riddle: map steps n=%d dirty_px=%d max_ms=%d", st.n, st.px, round(st.ms)))
        self.steps = nil
    end
end

---------------------------------------------------------------------------
-- slice 8: the footprints walk (spec, section 2: step by step, partial e-ink refresh)

-- the next step in map_step_s, while the map is open (close cancels it)
function MapView:stepLater()
    local d = self.diary
    self.step_task = d:schedule(d.CFG.map_step_s, function()
        self.step_task = nil
        self:step()
        self:stepLater()
    end)
end

-- the rects of the screen whose hero ink changed between two heroInk's (an item gone or new), inside the ink box,
-- those that meet merged -> { { x0, y0, x1, y1 }, … } (edges included)
local function changed(box, old, new)
    local had, has = {}, {}
    for _, it in ipairs(old) do had[it.key] = true end
    for _, it in ipairs(new) do has[it.key] = true end
    local rects = {}
    local function add(r)
        r = { math.max(box[1], r[1]), math.max(box[2], r[2]), math.min(box[3] - 1, r[3]), math.min(box[4] - 1, r[4]) }
        if r[1] > r[3] or r[2] > r[4] then return end
        local i = 1
        while i <= #rects do -- swallow every rect it meets, then look again
            local q = rects[i]
            if layout.near(r, q, 0) then
                r = { math.min(r[1], q[1]), math.min(r[2], q[2]), math.max(r[3], q[3]), math.max(r[4], q[4]) }
                table.remove(rects, i)
                i = 1
            else
                i = i + 1
            end
        end
        rects[#rects + 1] = r
    end
    for _, it in ipairs(old) do if not has[it.key] then add(it.rect) end end
    for _, it in ipairs(new) do if not had[it.key] then add(it.rect) end end
    return rects
end

-- one rect of the screen (edges included) painted again from the parchment up, as paint() lays it: white, the lines
-- through it, the labels, the heroes' ink, the owner's page on top. Around it a band of PEN_PX is inked again the same
-- way (nothing whitened there), so a line passing just outside keeps its pixels inside
function MapView:repaintRect(r)
    local d, box, dr = self.diary, self.box, self.drawn
    local bb = d.canvas
    bb:paintRect(r[1], r[2], r[3] - r[1] + 1, r[4] - r[2] + 1, WHITE)
    local g = { math.max(box[1], r[1] - PEN_PX), math.max(box[2], r[2] - PEN_PX), math.min(box[3] - 1, r[3] + PEN_PX),
                math.min(box[4] - 1, r[4] + PEN_PX) }
    local gx = exclusive(g)
    local ox, oy = self.ox, self.oy
    for _, way in ipairs(dr.ways) do
        local b = way.b
        if layout.near({ b[1] - ox, b[2] - oy, b[3] - ox + PEN_PX - 1, b[4] - oy + PEN_PX - 1 }, g, 0) then
            drawWay(bb, way.pts, way.pen, ox, oy, gx)
        end
    end
    -- the texts whose ink reaches the band, all at once as in paint(): the labels, the owner's name, the heroes' names;
    -- then the book (whole — black over black outside the band: nothing outside it was whitened) and the footprints
    local m = layout.text_reach(MapView.LABEL_HALO)
    local ls = {}
    for _, l in ipairs(dr.labels) do
        if layout.near(l.edges, g, m) then ls[#ls + 1] = l end
    end
    local all = texts({}, ls, MapView.LABEL_PX)
    local o = dr.owner
    if o and o.name and layout.near(o.name.edges, g, m) then texts(all, { o.name }, namePx(d)) end
    inkTexts(self, heroNames(self, dr.ink, g, all), gx)
    if o and layout.near(o.book, g, 0) then drawBook(self, o) end
    drawFeet(self, dr.ink, g)
    self:paintPage()
end

-- a step of the heroes (riddle.cast.step) on screen: only the places whose footprints or names changed are painted
-- again and refreshed (INK_WF), in the screen's pixels at the field's shift now. Waits — no step at all — while the ink
-- comes out, a finger lies in a zone (the pan repaints the whole map) or the pen is on the glass
function MapView:step()
    local d, dr = self.diary, self.drawn
    if self.reveal_task or self.drag or d.cur or not dr or self.cast_for ~= self.terrain then return end
    local t0 = time.monotonic()
    local moved
    -- the screen now: moved since the last step (pan, near setPoint) -> riddle.cast.step re-seats or lets go the heroes
    -- who cannot reach it
    self.cast_state, moved = cast.step(self.cast_state, self.terrain, d.CFG.map_step_s, self:heroScreen())
    local px = 0
    if moved > 0 then
        local items = heroInk(self, dr.labels, dr.owner)
        local rects = changed(self.box, dr.ink, items)
        dr.ink = items
        for _, r in ipairs(rects) do self:repaintRect(r) end
        for _, r in ipairs(rects) do
            local w, h = r[3] - r[1] + 1, r[4] - r[2] + 1
            d:push(r[1], r[2], w, h, MapView.INK_WF)
            px = px + w * h
        end
    end
    local stat = self.steps
    if stat then
        stat.n, stat.px = stat.n + 1, stat.px + px
        stat.ms = math.max(stat.ms, time.to_ms(time.monotonic() - t0))
    end
end

---------------------------------------------------------------------------
-- slice 9: the field under the finger

MapView.PAN_WF = "A2" -- the pan's repaint: black lines on white, fast

-- where a touch at (x, y) on a w × h screen lands: "pad" — the bottom strip (cfg.map_pad_px, its corners too), "edge" —
-- the strip at any other edge (cfg.map_edge_px; at the sides and the top wider by cfg.map_edge_extra of the screen's width
-- and height), nil — the middle (ink)
function MapView.zone(x, y, w, h, cfg)
    if y >= h - cfg.map_pad_px then return "pad" end
    local e = cfg.map_edge_px
    local side, top = e + round(cfg.map_edge_extra * w), e + round(cfg.map_edge_extra * h)
    if x < side or x >= w - side or y < top or y >= h - e then return "edge" end
    return nil
end

-- the shift (sx, sy: screen pixels the screen's center moved from the point, east and down) held inside the field: the
-- screen's offset from the terrain's center stays within half the field minus half the screen — also with no shift,
-- when the point sits farther out (offline, no new terrain: review of slice 10, B3) the screen stands at the field's edge
local function clampShift(t, point, sx, sy, sw, sh)
    local bx, by = terrain.offset(t, point)
    local function clamp(base, s, field, screen)
        local lim = (field - screen) / 2
        return math.max(-lim, math.min(lim, base + s)) - base
    end
    return clamp(bx, sx, t.w, sw), clamp(by, sy, t.h, sh)
end

-- where the map is centered before the finger moves it: the owner's point when the terrain covers it, else the
-- terrain's own center — spec, section 3: offline, the last saved terrain (the owner went far and its new terrain did
-- not come, or the point is gone); "blind" only without a terrain -> the point | nil (no terrain)
function MapView:anchor()
    local t, p = self.terrain, self.point
    if not t then return nil end
    if p and terrain.covers(t, p) then return p end
    return { lat = t.center.lat, lon = t.center.lon }
end

-- something to move: a terrain on screen (else the parchment is "blind")
function MapView:movable()
    return self.terrain ~= nil
end

-- the point the screen is centered on: the anchor moved by the shift | nil ("blind")
function MapView:viewPoint()
    local t, a = self.terrain, self:anchor()
    if not a then return nil end
    local bx, by = terrain.offset(t, a)
    local sx, sy = clampShift(t, a, self.shift[1], self.shift[2], self.diary.w, self.diary.h)
    if sx == 0 and sy == 0 then return a end
    return terrain.at(t, bx + sx, by + sy)
end

-- the map's page (strokes not yet read) back onto the canvas after a repaint: the ink stays where it was written
function MapView:paintPage()
    local bb = self.diary.canvas
    for _, s in ipairs(self.page.strokes) do ink.polyline(bb, s.p, BLACK, ink.stamp) end
end

-- the field moves by (dx, dy) screen pixels after the finger, held inside the field; moved -> the parchment repainted
-- (the page's ink kept) and pushed. -> moved, the repaint's ms
function MapView:pan(dx, dy)
    if not self:movable() then return false end
    local d = self.diary
    -- from where the screen stands now (the stored shift may reach past the field's edge)
    local t, a = self.terrain, self:anchor()
    local ox, oy = clampShift(t, a, self.shift[1], self.shift[2], d.w, d.h)
    local sx, sy = clampShift(t, a, ox - dx, oy - dy, d.w, d.h)
    if math.abs(sx - ox) < 0.5 and math.abs(sy - oy) < 0.5 then return false end
    self.shift = { sx, sy }
    return true, self:repaint()
end

-- the whole map painted again at once (the page's ink kept) and pushed with PAN_WF: the field moved under the finger
-- (pan) or with the owner (setPoint, near) -> the repaint's ms
function MapView:repaint()
    local d = self.diary
    local t0 = time.monotonic()
    self:paint()
    self:paintPage()
    d:push(0, 0, d.w, d.h, MapView.PAN_WF)
    return time.to_ms(time.monotonic() - t0)
end

-- the pen down at (x, y): in a zone of a map that can move -> the gesture starts there (no ink) -> true; the middle,
-- or a "blind" map (nothing to move) -> nil (ink)
function MapView:dragStart(x, y)
    local d = self.diary
    local zone = MapView.zone(x, y, d.w, d.h, d.CFG)
    if not zone or not self:movable() then return nil end
    self:touch()
    self.drag = { zone = zone, x0 = x, y0 = y, x = x, y = y, tx = x, ty = y, p = zone == "edge" and { x, y } or nil,
                  t0 = time.monotonic() }
    return true
end

-- the touchpad: the map goes to the finger now, then waits map_drag_s; a move meanwhile is taken when it ends
function MapView:dragStep()
    local g = self.drag
    local dx, dy = g.tx - g.x, g.ty - g.y
    if dx == 0 and dy == 0 then return end
    g.x, g.y = g.tx, g.ty
    local moved, ms = self:pan(dx, dy)
    if moved then g.ms = math.max(g.ms or 0, ms) end
    local d = self.diary
    self.drag_task = d:schedule(d.CFG.map_drag_s, function()
        self.drag_task = nil
        if self.drag == g then self:dragStep() end
    end)
end

-- the finger left the jitter square around where it landed (map_pan_slop_px): from now on it is a pan
local function beyondSlop(g, slop)
    return math.max(math.abs(g.tx - g.x0), math.abs(g.ty - g.y0)) >= slop
end

function MapView:dragMove(x, y)
    local g = self.drag
    g.tx, g.ty = x, y
    if g.p then g.p[#g.p + 1], g.p[#g.p + 2] = x, y end
    if not g.live then g.live = beyondSlop(g, self.diary.CFG.map_pan_slop_px) end
    if g.zone == "pad" and g.live and not self.drag_task then self:dragStep() end
end

-- chord / path length of a stroke's points (1 — a straight line, 0 — a closed loop); a point or no way — 1
function MapView.straightness(p)
    local len = 0
    for i = 3, #p, 2 do len = len + math.sqrt((p[i] - p[i - 2]) ^ 2 + (p[i + 1] - p[i - 1]) ^ 2) end
    if len == 0 then return 1 end
    return math.sqrt((p[#p - 1] - p[1]) ^ 2 + (p[#p] - p[2]) ^ 2) / len
end

-- the finger lifted: an edge stroke that is nearly straight moves the field by its vector, the touchpad takes the last
-- move; a curved stroke from the edge is not a pan — it is ink (a rose may begin anywhere): its points come back, and
-- the diary writes them as the map's page, as if the edge were not there (-> the points, when the finger came down). The
-- map's page, if one is being written, ends idle_s from now
function MapView:dragEnd()
    local g = self.drag
    local d = self.diary
    d:cancel(self.drag_task)
    self.drag_task, self.drag = nil, nil
    if g.live and g.zone == "edge" and MapView.straightness(g.p) < d.CFG.map_edge_straight then
        self:touch()
        return g.p, g.t0
    end
    if g.live then -- else a tap (the finger only trembled): nothing moves
        local moved, ms
        if g.zone == "edge" then
            self:rememberEdgePan(g.p, g.t0)
            moved, ms = self:pan(g.tx - g.x0, g.ty - g.y0)
        else
            moved, ms = self:pan(g.tx - g.x, g.ty - g.y)
        end
        if moved then g.ms = math.max(g.ms or 0, ms) end
        -- the tester's measure: the repaint's time (the touchpad: its longest one in the gesture)
        if g.ms then logger.info(string.format("riddle: map pan %s in %d ms", g.zone, round(g.ms))) end
    end
    self:touch()
    if #self.page.strokes > 0 then self:pageLater() end
end

return MapView
