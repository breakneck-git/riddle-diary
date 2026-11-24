--[[--
Full-screen diary page: finger ink, sinking ink, handwritten answer.

Input: while open, the widget replaces GestureDetector:feedEvent on the live
Input instance, so it sees every raw touch frame (slot/id/x/y) and KOReader
gets no gestures at all (no menus, no page turns). Restored on close.

Screen: one 8bpp canvas the size of the screen is what gets pushed, and it only
ever holds pure black (0x00) and white (0xFF): glyph antialiasing is thresholded
away. Ink goes canvas -> Screen.bb -> "a2" refresh of the touched rectangle only.
Ink and the answer vanish by dissolving: a fixed per-pixel mask splits the page
into N buckets, step k turns bucket k white. Dissolve and the answer use direct
A2/DU partial updates (no grey levels, no GL16, no flash).

Layers: any canvas rect can be rebuilt from three sources: the invitation (a
black/white bitmap, shown on a clean page at open and dissolved by the first
touch), the answer (a black/white bitmap of the glyphs revealed so far) and the
strokes (vectors); each is seen through the mask at its own level. Strokes always
win, so text appearing or dissolving never eats fresh ink.

The pen is never blocked: pages, answers and dissolving are independent.
A touch while an answer is on screen makes the answer start dissolving at once.
A page ends idle_s after its last pen-up; its answer waits until that page's own
ink has dissolved and the previous answer is gone. No step of the answer, the
invitation or the sink repaints near the moving finger: it waits for the pen-up.

Answers: the controller (seal, memory) prepares the request in the UI loop, the LLM
round-trip runs in a KOReader subprocess (riddle.worker, one at a time, killed after
ceil_s), so the pen keeps drawing meanwhile. A request slower than ponder_s is covered by a
thinking phrase (texts.thinking), then by another one every ponder_every_s; a phrase that has
revealed stands at least think_hold_s before the next thinking phrase replaces it, the answer
sends it away at once. With the radio on but no link the request waits for the link (it
goes when the link is back); none by ponder step offline_step, or no channel on at all, gives
fail_offline instead (riddle.net). A page finished while
a request is on its way never reaches the model: it gets a refusal (texts.busy); once the last
refusal has dissolved and the answer is still on its way, a new thinking phrase comes back. A page whose pen
cut short an answer being revealed or held on a timer goes to the model as usual, but a canned
interjection (texts.interrupted) shows first, its answer after it. The summary of the previous
session after the welcome goes to the subprocess too ("summary"); an answer preempts it, the pen
and sleep kill it (not saved: the next followup asks again).
Without a runner the controller is called synchronously and blocks the UI loop for up
to the 8 s budget. Sleep (Suspend) kills the request, drops pending answers, the queue and the
strokes; the page is wiped and wake-up (Resume) shows a clean page with the invitation -- unless
the diary has no seal and a reply waits for a touch (riddle.hold survives_sleep): that reply stays
whole on the page and no invitation covers it. With a seal sleep wipes everything.

Test harness: riddle/devtest.lua, loaded only when /mnt/us/riddle/devmode exists.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Freetype = require("ffi/freetype")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local time = require("ui/time")
local lfs = require("libs/libkoreader-lfs")
local now = time.monotonic -- time.now is *coarse* (jiffies); we want µs
local Screen = Device.screen
local ffi = require("ffi")

-- waveforms we drive directly (Kindle mxcfb only); elsewhere fall back to the UIManager modes.
-- Both are non-UI waveforms in framebuffer_mxcfb: no wait for the previous marker, the loop never stalls.
-- DU additionally gets EPDC_FLAG_FORCE_MONOCHROME there (refresh_k51 on PW2).
local DIRECT_WAVEFORMS = {}
local FALLBACK_MODES = { A2 = "a2", DU = "fast" }
if Device:isKindle() and pcall(require, "ffi/mxcfb_kindle_h") then
    DIRECT_WAVEFORMS.A2 = ffi.C.WAVEFORM_MODE_A2
    DIRECT_WAVEFORMS.DU = ffi.C.WAVEFORM_MODE_DU
end

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "plugins/riddlediary.koplugin"
local FONT_PATH = PLUGIN_DIR .. "/fonts/MarckScript-Regular.ttf"
local RIDDLE_DIR = "/mnt/us/riddle"
local SAMPLE_DIR = RIDDLE_DIR .. "/samples"

local texts = require("riddle.texts")
local layout = require("riddle.layout")
local hold = require("riddle.hold")
local png = require("riddle.png")
local net = require("riddle.net")
local rose = require("riddle.rose")
local triangle = require("riddle.triangle")
local glyph = require("riddle.glyph")
local status = require("riddle.status")
local str = require("riddle.str")
local prompt = require("riddle.prompt")
local mapdata = require("riddle.mapdata")
local ink = require("riddle_ink")
local MapView = require("riddle_mapview")
local mapjob = require("riddle.mapjob")
local tray = require("riddle.tray")

-- Tunables (spike: constants; later: settings).
local CFG = {
    idle_s = 2.5,              -- pause after the last pen-up that ends a page (-> PNG -> answer)
    ink_mode = "a2",           -- refresh for live ink (UIManager, coalesced per touch frame)
    -- the owner's pick of three on the device (2026-10-23): DU, 4 steps x 0.3 s ("slower: definitely not").
    --   wf: waveform of every dissolve step and of the answer reveal; steps: mask buckets; step_s: s per step.
    dissolve = { wf = "DU", steps = 4, step_s = 0.3 },
    grain = 1,                 -- mask cells are (2^grain)^2 px: 2x2 specks read as scattering, not as grey
    ink_threshold = 0x80,      -- glyph AA below this -> black, else white
    sink_delay_s = 2.0,        -- THE knob: a stroke starts dissolving this long after its pen-up (owner: 2 s)
    sink_tick_s = 0.1,         -- sink timer period (runs only while ink is visible)
    gc_tick_s = 0.05,          -- incremental GC step period on a blank page
    gc_step_kb = 128,          -- collectgarbage("step", n) size
    -- GC pause while the diary is open (Lua default 200: the heap doubles before a new cycle).
    -- A page may never be blank while she keeps writing, so the blank-page steps alone don't bound it.
    gc_pause = 110,
    sink_guard = 24,           -- px: strokes this close to the moving finger wait
    think_s = 1.0,             -- no controller (init failed): sleepy phrase after this pause
    ceil_s = 30,               -- hard ceiling of one answer in the subprocess (from its start): killed after this
    gen_ceil_s = 60,           -- the same for one section of the persona generation (riddle.app GEN_BUDGET_S = 50)
    -- runner, the owner's steps (2026-10-26): no answer this long after the page went -> thinking phrase
    -- (step 1); still none -> another phrase every ponder_every_s (steps 2, 3, ...), never the same twice
    ponder_s = 3.0,
    ponder_every_s = 5.0,      -- the steps' pace (a new phrase is planned, offline_step counts); not how long a phrase stands
    think_hold_s = 10,         -- a thinking phrase, revealed whole, stands this long before the next one (owner 2026-11-05)
    offline_step = 3,          -- radio on, no link yet: this ponder step ends the wait with fail_offline
    net_poll_s = 1.0,          -- radio on, no link yet: the link is checked this often before the request goes
    followup_s = 1.5,          -- after the welcome is revealed: lore sync + summary of the last session
    autosuspend_s = 30 * 60,   -- KOReader autosuspend while the diary is open (spec: 30 min idle)
    keepawake_s = 2,           -- touches reset the autosuspend timer at most this often
    t1_reset_s = 240,          -- Kindle: touches reset powerd's own 10 min screensaver timer this often
    reveal_char_s = 0.06,
    reveal_space_s = 0.12,
    answer_hold_s = 6,
    corner = 150,              -- exit zone: top-right square, px (live: the finger lands at x 635-740)
    corner_hold_s = 3,
    corner_slop = 40,
    corner_trace_s = 6,        -- devmode: raw touch log after a touch in the corner
    margin = 44,
    prompt_px = 36,
    answer_px = 42,
    sample_scale = 2,          -- PNG is downscaled by this factor
    map_idle_s = 180,          -- the map closes by itself after this long without a touch (plan of the map, decision 4)
    map_ink_batches = 4,       -- the terrain's lines come out on the map in this many batches (riddle_mapview.reveal)
    -- the heroes walk (riddle_mapview.step, slice 8; spec: a step every 2–3 s, partial refresh)
    map_step_s = 2.5,          -- a step of the footprints every this long while the map is open (20–40 px: riddle.cast)
    map_trail = 4,             -- a pair of footprints fades this many steps after it was printed
    map_keep_s = 900,          -- a map opened again this soon after it closed shows the same heroes, placed anew (owner 2026-11-16: «персонажей нужно сделать консистентными хотябы на 10-15 мин», «не надо чтобы они стояли там же где были, надо чтобы они были»)
    map_ceil_s = 85,          -- hard ceiling of the "map" job in the subprocess (scan + BeaconDB + IP + Overpass)
    probe_ceil_s = 30,         -- hard ceiling of the status page's model probe ("probe"; the chain's own budget: riddle.app ANSWER_BUDGET_S = 25)
    -- the field under the finger (riddle_mapview, slice 9; owner 2026-11-06: a centimetre at the edges, two at the bottom)
    map_edge_px = 83,          -- a stroke begun this close to any edge moves the field (≈ 1 cm at 212 ppi)
    map_edge_extra = 0.10,     -- the sides and the top: the strip is wider by this share of the screen (owner 2026-11-16: «расширь зону управления картой на 10% (от размера экрана) по левой правой и верхней границам»)
    map_edge_straight = 0.75,  -- a stroke from the edge is a pan if chord / path ≥ this, else ink (roses' arcs ≤ 0.65, swipes ≥ 0.85)
    map_pad_px = 167,          -- the bottom strip: a touchpad, the map follows the finger (≈ 2 cm)
    map_drag_s = 0.4,          -- the touchpad repaints the map at most this often
    map_pan_slop_px = 10,      -- a finger that moved less than this from where it landed is a tap, not a pan (jitter)
    -- the corner icons (spec 2026-11-19-corner-icons; riddle.tray.layout): the time, the battery, the Wi-Fi arcs in the
    -- bottom-right corner of the diary's page. px: the digits' face; pad_r/pad_b: from the right edge / to the baseline
    -- from the bottom; gap between the parts; icon_h: the battery and the arcs; batt_w, nub_w x nub_h: the battery's
    -- frame and its nub; line: the frame's stroke; wifi_r: the arcs' radii; band: the strip at the bottom kept for it;
    -- pen_wait_s: the longest a tick waits for the pen's lift (a lost pen-up must not keep it polling), then it draws.
    -- Starting values: the tester checks them against KOReader's status bar on a screenshot, only this table changes
    tray = { px = 22, pad_r = 14, pad_b = 10, gap = 8, icon_h = 12, batt_w = 22, nub_w = 2, nub_h = 6, line = 2,
             wifi_r = { 4, 8, 12 }, band = 44, pen_wait_s = 10 },
}

local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK

---------------------------------------------------------------------------
-- helpers

local function rssKB()
    local f = io.open("/proc/self/status", "r")
    if not f then return -1 end
    local s = f:read("*a")
    f:close()
    return tonumber(s:match("VmRSS:%s*(%d+)")) or -1
end

-- queue entries that open a mode of the diary instead of an answer (Diary:queueMode, nextAnswer) -> the opener
local MODES = { map = "openMap", status = "openStatus" }

-- the Kindle's IPv4 on the Wi-Fi (the status page): a short local command, no network (L3 of the plan)
local IP_CMD = "/sbin/ip -4 -o addr show wlan0 2>/dev/null"

local faces = {}
local function getFace(px)
    local key = FONT_PATH .. "|" .. px
    if faces[key] then return faces[key] end
    local ok, ftsize = pcall(Freetype.newFaceSize, FONT_PATH, px)
    if not ok then
        logger.err("riddle: cannot load font", FONT_PATH, ftsize)
        return require("ui/font"):getFace("cfont", px)
    end
    faces[key] = { orig_font = FONT_PATH, realname = FONT_PATH, size = px, orig_size = px,
                   ftsize = ftsize, hash = "riddle" .. key }
    return faces[key]
end

local codepoints = str.codepoints

-- a word's advance in face: -> its width, the advance of each glyph (layoutText and the corner icons measure with it)
local function advance(face, word)
    local adv, ww = {}, 0
    for i, cp in ipairs(codepoints(word)) do
        local g = RenderText:getGlyph(face, cp)
        adv[i] = g and g.ax or 0
        ww = ww + adv[i]
    end
    return ww, adv
end

-- the battery for status.collect and the corner icons: one read of powerd per call
local function readPower()
    local pd = Device:getPowerDevice()
    return { pct = pd:getCapacity(), charging = pd:isCharging() }
end

-- Word-wrapped layout (\n = forced line break, see riddle.layout.flow): list of {cp, x, base}; plus bounding rect.
-- max_bottom: the rect must end at or above it -- the lines that do not fit are dropped (riddle.layout.clip);
-- block.clipped is then the number of lines left
local function layoutText(face, text, x0, top, maxw, max_bottom)
    local line_h, ascender = face.ftsize:getHeightAndAscender()
    line_h = math.floor(line_h + 0.5)
    local space = math.floor(RenderText:getGlyph(face, 32).ax * 0.6) -- Marck Script's space is very wide
    local glyphs = {}
    local base0 = top + math.floor(ascender + 0.5)
    -- the rect's height for n lines: the glyphs' overhang (8 px) kept around them
    local function heightOf(n) return base0 + (n - 1) * line_h - top + line_h + 16 end
    local function measure(word) return (advance(face, word)) end
    local items, nlines = layout.flow(text, measure, space, x0, maxw)
    local clipped
    if max_bottom then
        local fit = nlines
        while fit > 1 and top - 8 + heightOf(fit) > max_bottom do fit = fit - 1 end
        items, nlines, clipped = layout.clip(items, nlines, fit, measure, x0, maxw)
    end
    for _, it in ipairs(items) do
        local x, base = it.x, base0 + it.line * line_h
        local _, adv = advance(face, it.word)
        for i, cp in ipairs(codepoints(it.word)) do
            glyphs[#glyphs + 1] = { cp = cp, x = x, base = base, word_start = (i == 1) }
            x = x + adv[i]
        end
    end
    local block = { face = face, glyphs = glyphs, clipped = clipped and nlines or nil }
    block.rect = Geom:new{ x = x0 - 8, y = top - 8, w = maxw + 16, h = heightOf(nlines) }
    return block
end

-- draw one glyph into bb, whose (0, 0) is at page position (ox, oy); returns the bb rect touched
local function drawGlyph(bb, face, g, color, ox, oy)
    local glyph = RenderText:getGlyph(face, g.cp)
    if not glyph then return end
    local gw, gh = glyph.bb:getWidth(), glyph.bb:getHeight()
    if gw == 0 or gh == 0 then return end
    local x, y = g.x + glyph.l - (ox or 0), g.base - glyph.t - (oy or 0)
    bb:colorblitFrom(glyph.bb, x, y, 0, 0, gw, gh, color)
    return x, y, gw, gh
end

-- the pen: riddle_ink (stamp 4 px, stamp_small 2 px for the sample, line)
local stamp, stampSmall, line = ink.stamp, ink.stamp_small, ink.line

local near = layout.near

---------------------------------------------------------------------------
-- dissolve mask: a 64x64 tile of cells, each cell in bucket 1..steps, equal counts,
-- deterministic shuffle (same scatter every run). A pixel of something at level L
-- is black iff bucket(x, y) > L, so step L+1 whitens exactly bucket L+1.

local bit = require("bit")
local band, rshift = bit.band, bit.rshift
local MASK_SIDE = 64
local mask = ffi.new("uint8_t[?]", MASK_SIDE * MASK_SIDE)
local mask_steps = 0

local function buildMask(steps)
    if steps == mask_steps then return end
    local n = MASK_SIDE * MASK_SIDE
    local order = {}
    for i = 0, n - 1 do order[i + 1] = i end
    local seed = 20261023
    for i = n, 2, -1 do -- Fisher-Yates with a fixed LCG
        seed = (seed * 1103515245 + 12345) % 2147483648
        local j = seed % i + 1
        order[i], order[j] = order[j], order[i]
    end
    for k = 1, n do mask[order[k]] = (k - 1) % steps + 1 end
    mask_steps = steps
end

local function bucket(x, y)
    local g = CFG.grain
    return mask[band(rshift(y, g), MASK_SIDE - 1) * MASK_SIDE + band(rshift(x, g), MASK_SIDE - 1)]
end

-- raw access to an unrotated BB8 buffer
local function pixels(bb)
    return ffi.cast("uint8_t*", bb.data), tonumber(bb.stride)
end

local function clampRect(bb, x, y, w, h)
    local bw, bh = bb:getWidth(), bb:getHeight()
    if x < 0 then w = w + x; x = 0 end
    if y < 0 then h = h + y; y = 0 end
    if x + w > bw then w = bw - x end
    if y + h > bh then h = bh - y end
    return x, y, w, h
end

-- crush glyph antialiasing: every pixel of the rect becomes pure black or white (below thr, default
-- CFG.ink_threshold, -> black)
local function binarize(bb, x, y, w, h, thr)
    x, y, w, h = clampRect(bb, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    local p, stride = pixels(bb)
    thr = thr or CFG.ink_threshold
    for yy = y, y + h - 1 do
        local row = yy * stride
        for xx = row + x, row + x + w - 1 do
            p[xx] = p[xx] < thr and 0x00 or 0xFF
        end
    end
end

-- A layer: a black/white bitmap placed at page rect {x, y, w, h}.
local function newLayer(rect)
    local bb = Blitbuffer.new(rect.w, rect.h, Blitbuffer.TYPE_BB8)
    bb:fill(WHITE)
    return { bb = bb, x = rect.x, y = rect.y, w = rect.w, h = rect.h }
end

local function layerDrawGlyph(layer, face, g)
    local x, y, w, h = drawGlyph(layer.bb, face, g, BLACK, layer.x, layer.y)
    if not x then return end
    binarize(layer.bb, x, y, w, h)
    return x + layer.x, y + layer.y, w, h
end

-- black pixels of the layer inside page rect [x0,x1)x[y0,y1) onto dst, through the mask at lvl (nil: no mask)
local function composite(dst, layer, x0, y0, x1, y1, lvl)
    if x0 < layer.x then x0 = layer.x end
    if y0 < layer.y then y0 = layer.y end
    if x1 > layer.x + layer.w then x1 = layer.x + layer.w end
    if y1 > layer.y + layer.h then y1 = layer.y + layer.h end
    if x1 <= x0 or y1 <= y0 then return end
    local lp, ls = pixels(layer.bb)
    local dp, ds = pixels(dst)
    local lx, ly = layer.x, layer.y
    for y = y0, y1 - 1 do
        local lrow, drow = (y - ly) * ls - lx, y * ds
        for x = x0, x1 - 1 do
            if lp[lrow + x] == 0x00 and (not lvl or bucket(x, y) > lvl) then dp[drow + x] = 0x00 end
        end
    end
end

-- the halo of the layer's black pixels on bb: every pixel of bb within r (a disc) of one goes white — only inside clip
-- { x0, y0, x1, y1 } (exclusive right/bottom; default the whole bb); the black ones themselves come after (composite):
-- the lines under a text stop right at its letters (the map's labels)
local function haloWhite(bb, layer, r, clip)
    local lp, ls = pixels(layer.bb)
    local p, stride = pixels(bb)
    local bw, bh = bb:getWidth(), bb:getHeight()
    local x0, y0, x1, y1 = 0, 0, bw, bh
    if clip then
        x0, y0, x1, y1 = math.max(x0, clip[1]), math.max(y0, clip[2]), math.min(x1, clip[3]), math.min(y1, clip[4])
    end
    local disc = {}
    for dy = -r, r do
        for dx = -r, r do
            if dx * dx + dy * dy <= r * r then disc[#disc + 1] = { dx, dy } end
        end
    end
    for yy = 0, layer.h - 1 do
        for xx = 0, layer.w - 1 do
            if lp[yy * ls + xx] == 0x00 then
                local x, y = layer.x + xx, layer.y + yy
                for _, o in ipairs(disc) do
                    local hx, hy = x + o[1], y + o[2]
                    if hx >= x0 and hy >= y0 and hx < x1 and hy < y1 then p[hy * stride + hx] = 0xFF end
                end
            end
        end
    end
end

-- clip window and canvas pointer for the dissolve pen (exclusive right/bottom)
local cx0, cy0, cx1, cy1 = 0, 0, 0, 0
local cpx, cstride = nil, 0
-- what ink.stamp paints onto: a "bb" whose paintRect blackens only the pixels inside the clip window
-- where bucket > c (c is the stroke's dissolve level, passed as the colour)
local maskedBB = {}
function maskedBB:paintRect(x, y, w, h, lvl)
    for yy = math.max(y, cy0), math.min(y + h, cy1) - 1 do
        local row = yy * cstride
        for xx = math.max(x, cx0), math.min(x + w, cx1) - 1 do
            if bucket(xx, yy) > lvl then cpx[row + xx] = 0x00 end
        end
    end
end
-- the pen of ink.line for strokes under dissolve: the shape is ink.stamp's, only the target differs
local function stampMasked(_bb, x, y, lvl)
    if x < cx0 - 1 or x > cx1 + 1 or y < cy0 - 1 or y > cy1 + 1 then return end
    stamp(maskedBB, x, y, lvl)
end

---------------------------------------------------------------------------

local Diary = Widget:extend{
    name = "riddlediary",
    covers_fullscreen = true,
    on_close = nil,
    -- riddle.controller instance (on_page, on_unlocked_followup, on_sleep, seal_open); nil: sleepy only
    controller = nil,
    -- the autosuspend plugin instance, if any: its timeout is raised while the diary is open
    autosuspend = nil,
    -- responder(png_path, callback(text, unlocked), wait); default: the controller. wait: the page's
    -- table, wait.give_up set while the request waits for the link (the ponder step ends that wait)
    responder = nil,
    -- riddle.worker runner: the LLM round-trip in a subprocess; nil: the controller blocks the loop
    runner = nil,
    -- called when nothing is on screen and nothing is pending (the plugin may start the Notion sync)
    on_idle = nil,
    -- the map's point: map_job() runs in the subprocess (riddle.mapjob.run, the only writer of map/),
    -- map_point() -> the saved point | nil reads it in this process; nil: no job, no point
    map_job = nil,
    map_point = nil,
    -- the local time the map's heroes stand by (riddle.cast.clock): os.date("*t"), no time zone parsed (plan's A6)
    map_clock = function() return os.date("*t") end,
    -- set below when /mnt/us/riddle/devmode exists: corner diagnostics in the log
    devmode = nil,
}
Diary.CFG = CFG -- the tunables (tests change them)

function Diary:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.canvas = Blitbuffer.new(self.w, self.h, Blitbuffer.TYPE_BB8)
    self.canvas:fill(WHITE)
    buildMask(CFG.dissolve.steps)
    self.face_prompt = getFace(CFG.prompt_px)
    self.face_answer = getFace(CFG.answer_px)
    self.prompt = {}   -- the invitation; laid out on a random line at every show (showInvitation)
    self:showInvitation(false) -- the widget's first paint is a full refresh, nothing to push yet
    self.strokes = {}  -- everything still visible, each at its own dissolve level
    self.page = nil    -- the page being written: { strokes = {...}, ink = bbox } (the PNG record)
    self.answer = nil  -- the answer on screen
    self.queue = {}    -- answers waiting for their page's ink and for the previous answer
    self.inflight = 0  -- pages sent to the responder, no answer yet
    self.asks = {}     -- runner: pages waiting for the answer in flight (one subprocess at a time)
    self.tasks = {}
    self.epoch = 0     -- bumped by a page reset (sleep): answers of older pages are dropped
    -- the corner icons (trayShow): only a widget built by init has them; after the strokes and the tasks exist
    self.tray = {}
    self:trayShow("open")
    self.stats = { frames = 0, frame_us = 0, frame_us_max = 0, sink_ticks = 0, sink_us = 0, sink_us_max = 0,
                   ans_steps = 0, ans_us_max = 0, grey_px = 0, lost_ink = 0 }
    self.responder = self.responder or function(png, cb, wait) self:respond(png, cb, wait) end
    self.saved_gc_pause = collectgarbage("setpause", CFG.gc_pause)
    -- the new pause only applies from the next GC cycle on: finish one now, hidden by the
    -- full-screen refresh of the opening diary (otherwise the heap first doubles under the old pause)
    collectgarbage()
    self:hookInput()
    self:raiseAutosuspend()
    logger.info("riddle: diary open, RSS KB", rssKB())
    self:maybeStartGen()
    self:maybeStartTest()
end

-- the persona of "whose diary" (riddle.persona) is not generated yet: start it at open, in the background,
-- without waiting for a page (each section is one followup; finish_followup chains the next one)
function Diary:maybeStartGen()
    local ctl = self.controller
    if ctl and self.runner and ctl:gen_due() then self:scheduleFollowup() end
end

-- the page ends -> controller -> cb(text, unlocked, action); action "map": the page was the map's opening phrase
-- (text nil). With a runner the LLM round-trip runs in a subprocess and
-- cb comes from its poll timer; without one it blocks the loop (≤ 8 s budget).
-- With a runner the request goes only with a link (riddle.net): no channel on -> fail_offline at
-- once; a channel on but no link -> the request waits, polled every net_poll_s, and goes when the
-- link is back; wait.give_up (the ponder step offline_step) or the channel turned off ends the wait
-- with fail_offline. The ceiling ceil_s counts from the request's start, not from the wait.
function Diary:respond(png, cb, wait)
    local ctl = self.controller
    if not ctl then
        if png then os.remove(png) end
        self:schedule(CFG.think_s, function() cb(texts.sleepy[math.random(#texts.sleepy)]) end)
        return
    end
    local was_open = ctl.seal_open
    if self.runner and png then
        local job, text = ctl:begin(png)
        if not job then
            -- no request (a fail phrase, the persona not ready yet): only the generation may be due; the summary
            -- and the rolling summary wait for a real answer
            cb(text, text ~= nil and ctl:take_followup(true))
            return
        end
        local t0 = now()
        local function done(payload, err)
            if payload then
                logger.info(string.format("riddle: worker answer done in %d ms (child RSS KB %s)",
                    time.to_ms(now() - t0), tostring(payload.rss_kb)))
            else
                logger.info("riddle: worker answer failed: " .. tostring(err))
            end
            local answer, action = ctl:finish(job, payload, err)
            if action then
                -- the page opened the map (riddle.prompt.MAP_FORMAT): no answer, no followup taken for it
                logger.info(string.format("riddle: on_page -> %s in %d ms", action, time.to_ms(now() - t0)))
                cb(nil, false, action)
                return
            end
            local unlock = not was_open and ctl.seal_open
            local unlocked = unlock or ctl:take_followup()
            -- the followup raised by the rolling summary alone is not an unlock
            local tag = unlocked and ((not unlock and ctl.roll_tail) and " (roll)" or " (unlocked)") or ""
            logger.info(string.format("riddle: on_page -> text in %d ms, seal %s%s", time.to_ms(now() - t0),
                ctl.seal_open and "open" or "closed", tag))
            cb(answer, unlocked)
        end
        local function start()
            local ok, err = self.runner:start("answer", job.run, { timeout_s = CFG.ceil_s, on_done = done })
            if not ok then done(nil, err) end
        end
        local state = net.state()
        if state == "up" then
            start()
        elseif state == "off" or not wait then
            logger.info("riddle: no network channel on -> offline")
            done(nil, "offline")
        else
            logger.info("riddle: radio on, no link -> waiting for it")
            local poll
            local function offline(why)
                wait.give_up = nil
                self:cancel(poll)
                logger.info("riddle: " .. why .. " -> offline")
                done(nil, "offline")
            end
            local function check()
                poll = nil
                local s = net.state()
                if s == "up" then
                    wait.give_up = nil
                    logger.info(string.format("riddle: link up after %d ms -> request goes", time.to_ms(now() - t0)))
                    start()
                elseif s == "off" then
                    offline("radio turned off while waiting")
                else
                    poll = self:schedule(CFG.net_poll_s, check)
                end
            end
            wait.give_up = function() offline("no link by ponder step " .. CFG.offline_step) end
            poll = self:schedule(CFG.net_poll_s, check)
        end
        return
    end
    local t0 = now()
    local text
    if png then
        local action
        text, action = ctl:on_page(png)
        -- an accidental touch: nothing to show, the followup waits for a real answer; the map's opening phrase:
        -- the action instead of an answer
        if text == nil then
            cb(nil, false, action)
            return
        end
    else
        local sleepy = ctl:texts("sleepy")
        text = sleepy[math.random(#sleepy)]
    end
    local unlocked = (not was_open and ctl.seal_open) or ctl:take_followup()
    logger.info(string.format("riddle: on_page -> text in %d ms, seal %s%s", time.to_ms(now() - t0),
        ctl.seal_open and "open" or "closed", unlocked and " (unlocked)" or ""))
    cb(text, unlocked)
end

-- after the welcome: lore and the summary of the previous session (one more LLM call).
-- Set when the welcome starts; runs on its own timer once the welcome has stopped appearing
-- (revealed, or hurried away by the pen) and never under the moving pen, nor while a page is being
-- written (idle_task: its answer would preempt the summary at once). With a runner the summary's
-- LLM call goes to the subprocess ("summary") and the loop does not wait for it; a busy runner (an
-- answer, a Notion read) is waited for, not cancelled. A failed, timed-out, preempted or killed (pen,
-- sleep: cancelSummary) summary is not saved. A cancelled one is asked again by the next answer's
-- followup; a failed one waits for the next wake-up (the controller, finish_followup).
-- A closed diary (no canvas) schedules nothing: a followup finished after the close (its on_done) has
-- already told the controller, and the next open raises what is still due (maybeStartGen, the next page)
function Diary:scheduleFollowup()
    local ctl = self.controller
    if not ctl or not self.canvas then return end
    local function run()
        if self.cur or self.idle_task or (self.answer and self.answer.phase == "reveal")
            or (self.runner and self.runner:busy()) or self.map or self.status then
            self.followup_task = self:schedule(CFG.followup_s, run)
            return
        end
        self.followup_task = nil
        if self.runner then
            self:startSummary()
            return
        end
        local t0 = now()
        local ok, err = pcall(ctl.on_unlocked_followup, ctl)
        logger.info(string.format("riddle: unlocked followup %s in %d ms", ok and "done" or ("failed: " .. tostring(err)),
            time.to_ms(now() - t0)))
    end
    self:cancel(self.followup_task)
    self.followup_task = self:schedule(CFG.followup_s, run)
end

-- the followup through the runner: lore and the request here, the LLM call in the subprocess, the
-- summary saved by on_done (the controller and its memory outlive the widget)
function Diary:startSummary()
    local ctl = self.controller
    local job = ctl:begin_followup()
    if not job then
        logger.info("riddle: unlocked followup done, no summary to ask")
        return
    end
    local t0 = now()
    -- the persona generation: one more section due (or the cancelled one again) -> the next followup
    local timeout_s = job.kind == "gen" and CFG.gen_ceil_s or CFG.ceil_s
    local ok, err = self.runner:start("summary", job.run, { timeout_s = timeout_s, on_done = function(payload, perr)
        if payload then
            logger.info(string.format("riddle: worker summary done in %d ms", time.to_ms(now() - t0)))
        else
            logger.info("riddle: worker summary failed: " .. tostring(perr))
        end
        if ctl:finish_followup(job, payload, perr) then self:scheduleFollowup() end
    end })
    if not ok then
        logger.info("riddle: worker summary failed: " .. tostring(err))
        if ctl:finish_followup(job, nil, err) then self:scheduleFollowup() end
    end
end

-- the pen and sleep kill the running followup: the runner does not call its on_done (riddle.worker
-- Runner:cancel), so the controller hears the cancellation from here (Controller:cancel_followup: the
-- running followup lives there, as long as the runner, not the widget) — its reason goes back to the
-- next answer. The next followup is not scheduled: the next page (or wake-up) raises it
function Diary:cancelSummary()
    if not self.runner then return end
    self.runner:cancel("summary")
    if self.controller then self.controller:cancel_followup() end
end

-- KOReader's autosuspend: CFG.autosuspend_s while the diary is open, the owner's value back on close
function Diary:raiseAutosuspend()
    local as = self.autosuspend
    if not as or type(as.auto_suspend_timeout_seconds) ~= "number" then
        logger.warn("riddle: no autosuspend plugin, the device sleeps on its own terms")
        return
    end
    self.saved_autosuspend = as.auto_suspend_timeout_seconds
    as.auto_suspend_timeout_seconds = CFG.autosuspend_s
    if self.saved_autosuspend <= 0 then
        -- it was off: its timers never started
        if as._start then pcall(as._start, as) end
        if as._start_kindle then pcall(as._start_kindle, as) end
    end
    logger.info("riddle: autosuspend", self.saved_autosuspend, "->", CFG.autosuspend_s, "s")
end

function Diary:restoreAutosuspend()
    local as = self.autosuspend
    if as and self.saved_autosuspend then
        as.auto_suspend_timeout_seconds = self.saved_autosuspend
        self.saved_autosuspend = nil
    end
end

-- our feedEvent hook returns no gestures, so UIManager never fires the "InputEvent" hook that
-- resets autosuspend: fire it ourselves, at most every keepawake_s
function Diary:keepAwake(t)
    if self.keepawake_t and time.to_s(t - self.keepawake_t) < CFG.keepawake_s then return end
    self.keepawake_t = t
    UIManager.event_hook:execute("InputEvent")
    -- AutoSuspend resets powerd's t1 only after 5 min without input; synthetic touches never
    -- reach powerd (seen live: screensaver 10:00 into a devtest session), real ones may not
    -- either — so reset it from here while she writes
    local pd = Device.powerd
    if Device:isKindle() and pd and pd.resetT1Timeout
        and not (self.t1_t and time.to_s(t - self.t1_t) < CFG.t1_reset_s) then
        self.t1_t = t
        local ok, err = pcall(pd.resetT1Timeout, pd)
        if not ok then logger.warn("riddle: t1 reset failed", err) end
    end
end

function Diary:paintTo(bb, x, y)
    bb:blitFrom(self.canvas, x, y, 0, 0, self.w, self.h)
end

function Diary:onCloseWidget()
    self:closeMap("exit")
    self:closeStatus("exit")
    self:unhookInput()
    self:restoreAutosuspend()
    if self.restore_refresh then self.restore_refresh() end
    for fn in pairs(self.tasks) do UIManager:unschedule(fn) end
    self.tasks = {}
    self.gc_task = nil
    -- the pending followup's timer is gone with the tasks: the controller forgets the followup taken for it
    if self.controller then self.controller:on_close() end
    self:dropAsks()
    if self.saved_gc_pause then collectgarbage("setpause", self.saved_gc_pause) end
    if self.answer then self.answer.layer.bb:free() self.answer = nil end
    if self.prompt.layer then self.prompt.layer.bb:free() self.prompt.layer = nil end
    self:trayDrop()
    if self.canvas then self.canvas:free() self.canvas = nil end
    self.strokes, self.page, self.queue = nil, nil, nil
    logger.info("riddle: diary closed, RSS KB", rssKB())
    if self.on_close then self.on_close() end
end

function Diary:exit()
    logger.info("riddle: exit gesture")
    UIManager:close(self, "full")
end

-- Sleep: the seal closes (the plugin locks it too), the page is wiped, pending answers and
-- every timer are dropped. Nothing is pushed: the screensaver owns the screen now.
-- Without a seal the reply that waits for a touch survives (riddle.hold): it is drawn whole and
-- stands after wake-up until a finger or the pen touches the page.
function Diary:onSuspend()
    if not self.canvas then return end
    self:closeMap("sleep")
    self:closeStatus("sleep")
    if self.controller then self.controller:on_sleep() end
    -- the plugin's sync on Suspend needs a free runner (main.lua); the summary is asked again after wake-up
    self:cancelSummary()
    local keep = self:replySurvivesSleep()
    if keep then self:finishReveal(self.answer) end
    self:resetPage(keep)
    logger.info("riddle: suspend, page wiped, RSS KB", rssKB(), keep and "(reply kept)" or "")
end

-- Wake-up: the kept reply back on the canvas, or a clean page + invitation. KOReader repaints
-- everything after the screensaver (nextTick full); ours goes in the same tick, so the two merge
-- into one refresh -- the reply goes onto the canvas before it.
function Diary:onResume()
    if not self.canvas then return end
    local a = self.answer
    if a then
        local r = a.block.rect
        self:paintRegion(r.x, r.y, r.w, r.h)
    else
        self:resetPage()
        self:showInvitation(false)
    end
    self:trayShow("resume")
    UIManager:nextTick(function()
        if self.canvas then UIManager:setDirty(self, "full") end
    end)
    logger.info("riddle: resume,", a and "reply kept" or "clean page + invitation")
end

function Diary:replySurvivesSleep()
    local a = self.answer
    if not a then return false end
    local ctl = self.controller
    local timed = self:holdFor(a, 0) ~= nil
    return hold.survives_sleep(ctl ~= nil and ctl.seal.configured, a.kind, a.phase, timed)
end

-- the sleep caught the reply being revealed: the rest of its glyphs go into the layer at once
function Diary:finishReveal(a)
    for i = a.i + 1, #a.block.glyphs do layerDrawGlyph(a.layer, a.block.face, a.block.glyphs[i]) end
    a.i, a.wait, a.phase = #a.block.glyphs, nil, "hold"
    a.task = nil -- the page reset unschedules it; nothing waits behind the reply any more
end

-- keep_answer: the reply on screen stays (its layer is not freed); the rest of the page is reset
function Diary:resetPage(keep_answer)
    self.epoch = self.epoch + 1
    for fn in pairs(self.tasks) do UIManager:unschedule(fn) end
    self.tasks = {}
    self.sink_task, self.idle_task, self.corner_task, self.gc_task, self.followup_task = nil, nil, nil, nil, nil
    self.gc = nil
    self.cur, self.active_slot, self.corner_from, self.dirty = nil, nil, nil, nil
    if self.gd then self.gd:dropContacts() end
    if self.answer and not keep_answer then self.answer.layer.bb:free() self.answer = nil end
    local pr = self.prompt
    if pr.layer then pr.layer.bb:free() end
    pr.layer, pr.fading, pr.lvl = nil, nil, nil
    self:trayDrop()
    self.strokes, self.page, self.queue, self.inflight = {}, nil, {}, 0
    self.rethink, self.mode_due = nil, nil
    self:dropAsks()
    self.canvas:fill(WHITE)
end

-- the answer in flight belongs to a wiped page: kill its subprocess, forget the waiting pages
function Diary:dropAsks()
    if self.runner then self.runner:cancel("answer") end
    self.asks, self.asking = {}, nil
end

-- runner: one page at a time; the next one goes when the previous answer has come back
function Diary:pumpAsks()
    if self.asking then return end
    local ask = table.remove(self.asks, 1)
    if not ask then return end
    self.asking = true
    ask()
end

-- scheduleIn wrapper that we can cancel on close
function Diary:schedule(s, fn)
    local wrapper
    wrapper = function()
        self.tasks[wrapper] = nil
        if self.canvas then fn() end
    end
    self.tasks[wrapper] = true
    UIManager:scheduleIn(s, wrapper)
    return wrapper
end

function Diary:cancel(wrapper)
    if wrapper and self.tasks[wrapper] then
        UIManager:unschedule(wrapper)
        self.tasks[wrapper] = nil
    end
end

-- push a canvas rect to the screen and refresh exactly that rect.
-- mode: "A2"/"DU" -> direct waveform; anything else -> UIManager refresh mode.
function Diary:push(x, y, w, h, mode)
    x, y, w, h = clampRect(self.canvas, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    if self.test then self.stats.grey_px = self.stats.grey_px + self:countGrey(x, y, w, h) end
    Screen.bb:blitFrom(self.canvas, x, y, x, y, w, h)
    local wf = DIRECT_WAVEFORMS[mode]
    if wf and Screen.mech_refresh then
        -- immediate, partial, no UIManager queue (so it never merges with the a2 ink rects)
        Screen:mech_refresh(false, wf, Screen:calculateRealCoordinates(x, y, w, h))
    else
        UIManager:setDirty(nil, FALLBACK_MODES[mode] or mode, Geom:new{ x = x, y = y, w = w, h = h })
    end
end

-- Rebuild a canvas rect from the layers: white, prompt, answer through the mask at its level, the corner icons
-- (no mask), every visible stroke through the mask at its level (strokes last: ink always wins). No refresh.
-- -> the clamped rect, nil if nothing is left of it
function Diary:paintRegion(x, y, w, h)
    x, y, w, h = clampRect(self.canvas, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    local x1, y1 = x + w, y + h
    self.canvas:paintRect(x, y, w, h, WHITE)
    local pl = self.prompt.layer
    if pl then composite(self.canvas, pl, x, y, x1, y1, self.prompt.lvl) end
    local a = self.answer
    if a then composite(self.canvas, a.layer, x, y, x1, y1, a.lvl) end
    local tl = self.tray and self.tray.layer
    if tl then composite(self.canvas, tl, x, y, x1, y1) end
    cx0, cy0, cx1, cy1 = x, y, x1, y1
    cpx, cstride = pixels(self.canvas)
    local box = { x, y, x1, y1 }
    for _, s in ipairs(self.strokes) do
        if near(s.b, box, 3) then ink.polyline(nil, s.p, s.lvl, stampMasked) end
    end
    return x, y, w, h
end

-- paintRegion + refresh exactly that rect
function Diary:renderRegion(x, y, w, h)
    x, y, w, h = self:paintRegion(x, y, w, h)
    if x then self:push(x, y, w, h, CFG.dissolve.wf) end
end

-- would a repaint of this rect land near the moving finger? (same rule as the sink)
function Diary:penNear(x, y, w, h)
    local cb = self.cur and self.cur.b
    return cb ~= nil and near({ x, y, x + w - 1, y + h - 1 }, cb, CFG.sink_guard)
end

---------------------------------------------------------------------------
-- invitation: on a clean page at open (and after wake-up, via showInvitation), gone at the first touch

-- the controller picks it (Controller:opening_text): no seal -- a greeting of the diary's persona (no
-- repeats in a row), with a seal -- its invitation; without a controller, the built-in invitation
function Diary:invitationText()
    local ctl = self.controller
    if ctl then return ctl:opening_text() end
    return texts.invitation
end

function Diary:showInvitation(push)
    if self.prompt.layer then return end
    -- a random line 2-5 each time it shows (open, wake-up), not always the first
    local n = layout.invitation_line(math.random)
    local line_h = math.floor(self.face_prompt.ftsize:getHeightAndAscender() + 0.5)
    local pr = layoutText(self.face_prompt, self:invitationText(), CFG.margin,
        layout.line_top(CFG.margin, line_h, n), self.w - 2 * CFG.margin)
    self.prompt = pr
    logger.info("riddle: invitation at line", n)
    pr.layer = newLayer(pr.rect)
    pr.lvl = 0
    for _, g in ipairs(pr.glyphs) do layerDrawGlyph(pr.layer, self.face_prompt, g) end
    local r = pr.rect
    if push == false then
        composite(self.canvas, pr.layer, r.x, r.y, r.x + r.w, r.y + r.h)
    else
        self:renderRegion(r.x, r.y, r.w, r.h)
    end
end

-- dissolves through the mask like the answer, then frees its layer
function Diary:fadeInvitation()
    local pr = self.prompt
    if not pr.layer or pr.fading then return end
    pr.fading = true
    local function step()
        local r = pr.rect
        if self:penNear(r.x, r.y, r.w, r.h) then
            self:schedule(CFG.sink_tick_s, step)
            return
        end
        pr.lvl = pr.lvl + 1
        self:renderRegion(r.x, r.y, r.w, r.h)
        if pr.lvl < CFG.dissolve.steps then
            self:schedule(CFG.dissolve.step_s, step)
            return
        end
        pr.layer.bb:free()
        pr.layer, pr.fading = nil, nil
        logger.info("riddle: invitation gone")
    end
    step()
end

-- answers go below the invitation while it is on screen
function Diary:textFloor()
    local r = self.prompt.rect
    return self.prompt.layer and (r.y + r.h + 10) or CFG.margin
end

---------------------------------------------------------------------------
-- the corner icons (spec 2026-11-19-corner-icons): the time, the battery, the Wi-Fi arcs in the bottom-right corner
-- of the diary's page. A layer of its own (paintRegion puts it under the strokes), so dissolving ink over it never
-- eats it. Shown with the page (open, wake-up, back from a mode) without a push: a full refresh follows each of them.
-- Repainted at the start of every minute: only its rect (the old one and the new one together), a partial refresh;
-- the pen on the page delays it until the pen-up. resetPage drops it (sleep, the map, the status page): none there.
-- self.tray: { layer, rect, facts, task, wait_t0 }; no self.tray (a widget not built by init) -> no corner.

-- the corner's sources (tests replace them): the widget's clock, powerd, the network's state
function Diary:traySources()
    return { clock = self.map_clock, power = readPower, net = net.state }
end

-- the facts f drawn onto a new layer of the corner (the old one freed); its rect and facts remembered
function Diary:trayDraw(f)
    local tr, M = self.tray, CFG.tray
    local face = getFace(M.px)
    local _, ascender = face.ftsize:getHeightAndAscender()
    local asc = math.floor(ascender + 0.5)
    -- reach: room around the digits for the glyphs' overhang (one place with the other text layers)
    local at = { right = self.w - M.pad_r, base = self.h - M.pad_b, asc = asc, reach = layout.text_reach(0) }
    -- whole pixels: the parts' rects go to paintRect
    local L = tray.layout(f, at, function(s) return math.ceil((advance(face, s))) end, M)
    if tr.layer then tr.layer.bb:free() end
    local layer = newLayer(L.rect)
    local bb, ox, oy = layer.bb, layer.x, layer.y
    for _, r in ipairs(L.rects) do bb:paintRect(r.x - ox, r.y - oy, r.w, r.h, BLACK) end
    local function shift(x, y) return x - ox, y - oy end
    for _, p in ipairs(L.polys) do ink.polyline(bb, p, BLACK, stampSmall, shift) end
    if L.bolt then
        -- the bolt shows on the fill (white) and on the empty part (black) alike
        local fill_x1 = L.fill_x1
        ink.polyline(bb, L.bolt, nil, function(b, x, y)
            stampSmall(b, x, y, (fill_x1 and x + ox < fill_x1) and WHITE or BLACK)
        end, shift)
    end
    for _, tx in ipairs(L.texts) do
        local block = layoutText(face, tx.s, tx.x, at.base - asc, self.w)
        for _, g in ipairs(block.glyphs) do layerDrawGlyph(layer, face, g) end
    end
    tr.layer, tr.rect, tr.facts = layer, L.rect, f
end

-- the corner's next tick in s seconds (the one planned before goes)
function Diary:trayPlan(s)
    local tr = self.tray
    self:cancel(tr.task)
    tr.task = self:schedule(s, function()
        tr.task = nil
        self:trayTick()
    end)
end

-- why: "open" | "resume" | "back". The corner onto the canvas, no push (the caller's full refresh shows it)
function Diary:trayShow(why)
    local tr = self.tray
    if not tr then return end
    local old = tr.rect
    self:trayDrop()
    local f = tray.facts(self:traySources())
    self:trayDraw(f)
    local r = tr.rect
    local u = tray.union(old, r)
    self:paintRegion(u.x, u.y, u.w, u.h)
    logger.info(string.format("riddle: tray show %s %s rect=%d,%d,%d,%d", why, tray.describe(f), r.x, r.y, r.w, r.h))
    self:trayPlan(tray.next_tick_s(f))
end

-- a minute is over: the facts again, the old and the new rect of the corner repainted with a partial refresh. The pen
-- on the page: wait for its lift (checked every sink tick), then draw; still down after CFG.tray.pen_wait_s — draw anyway
function Diary:trayTick()
    local tr = self.tray
    if not (tr and tr.layer) then return end
    if self.cur then
        tr.wait_t0 = tr.wait_t0 or now()
        if time.to_s(now() - tr.wait_t0) < CFG.tray.pen_wait_s then
            self:trayPlan(CFG.sink_tick_s)
            return
        end
    end
    local waited = tr.wait_t0 and math.floor(time.to_ms(now() - tr.wait_t0) + 0.5)
    local held = self.cur ~= nil
    tr.wait_t0 = nil
    local old, prev = tr.rect, tr.facts
    local f = tray.facts(self:traySources())
    self:trayDraw(f)
    local u = tray.union(old, tr.rect)
    self:renderRegion(u.x, u.y, u.w, u.h)
    local d = tray.describe(f)
    if waited then
        logger.info(string.format("riddle: tray tick %s %d ms %s", held and "pen still down" or "after pen", waited, d))
    elseif self.devmode then
        logger.info("riddle: tray tick " .. d)
    end
    if prev and prev.wifi ~= f.wifi then logger.info("riddle: tray wifi " .. (f.wifi and "on" or "off")) end
    if prev and prev.charging ~= f.charging then
        logger.info("riddle: tray charging " .. (f.charging and "on" or "off"))
    end
    self:trayPlan(tray.next_tick_s(f))
end

-- the corner goes: its layer freed, its tick cancelled (resetPage, onCloseWidget); nothing repainted
function Diary:trayDrop()
    local tr = self.tray
    if not tr then return end
    if tr.layer then tr.layer.bb:free() end
    self:cancel(tr.task)
    tr.layer, tr.rect, tr.facts, tr.task, tr.wait_t0 = nil, nil, nil, nil, nil
end

---------------------------------------------------------------------------
-- input

function Diary:hookInput()
    local gd = Device.input and Device.input.gesture_detector
    if not gd then logger.warn("riddle: no gesture detector, input not hooked") return end
    self.gd = gd
    gd:dropContacts()
    gd.feedEvent = function(_gd, tevs)
        local ok, err = pcall(self.onRawTouch, self, tevs)
        if not ok then logger.err("riddle: touch handler error", err) end
        return {}
    end
end

function Diary:unhookInput()
    if self.gd then
        self.gd.feedEvent = nil -- back to GestureDetector.feedEvent
        self.gd:dropContacts()
        self.gd = nil
    end
end

function Diary:toScreen(x, y)
    if Screen:getTouchRotation() == 0 then return x, y end
    local ges = { ges = "touch", pos = Geom:new{ x = x, y = y, w = 0, h = 0 } }
    self.gd:adjustGesCoordinate(ges)
    return ges.pos.x, ges.pos.y
end

function Diary:onRawTouch(tevs)
    local t0 = now()
    self:keepAwake(t0)
    self.dirty = nil
    for _, tev in ipairs(tevs) do
        local slot = tev.slot
        if not self.canvas then return end -- the corner exit closed us mid-batch
        if tev.id == -1 then
            if self.active_slot == slot then
                self.active_slot = nil
                self:penUp(tev.timev)
            end
        elseif tev.x and tev.y then
            local x, y = self:toScreen(tev.x, tev.y)
            if self.active_slot == nil then
                self.active_slot = slot
                self:penDown(x, y, tev.timev)
            elseif self.active_slot == slot then
                self:penMove(x, y)
            end
        end
        if self.corner_trace then self:traceCorner(tev) end
    end
    local d = self.dirty
    if d then
        self:push(d[1] - 3, d[2] - 3, d[3] - d[1] + 7, d[4] - d[2] + 7, CFG.ink_mode)
        local us = time.to_us(now() - t0)
        local st = self.stats
        st.frames = st.frames + 1
        st.frame_us = st.frame_us + us
        if us > st.frame_us_max then st.frame_us_max = us end
    end
end

function Diary:markDirty(x0, y0, x1, y1)
    if x0 > x1 then x0, x1 = x1, x0 end
    if y0 > y1 then y0, y1 = y1, y0 end
    local d = self.dirty
    if not d then self.dirty = { x0, y0, x1, y1 } return end
    if x0 < d[1] then d[1] = x0 end
    if y0 < d[2] then d[2] = y0 end
    if x1 > d[3] then d[3] = x1 end
    if y1 > d[4] then d[4] = y1 end
end

function Diary:growInk(x, y)
    local pg = self.page
    local b = pg.ink
    if not b then pg.ink = { x, y, x, y } return end
    if x < b[1] then b[1] = x end
    if y < b[2] then b[2] = y end
    if x > b[3] then b[3] = x end
    if y > b[4] then b[4] = y end
end

-- A stroke: { p = {x1,y1,x2,y2,...}, b = {x0,y0,x1,y1}, t_end = fts|nil, lvl = 0..steps } (on the map also t0 = fts:
-- the pen down — riddle_mapview counts the edge pans of a rose from it).
-- It sits in self.strokes (the screen) until fully dissolved, and in its page's record
-- (goes to the PNG, never fades).

function Diary:penDown(x, y, tv)
    -- secret exit: hold still in the top-right corner (tv: the kernel's touch time, see penUp)
    if x >= self.w - CFG.corner and y <= CFG.corner then
        self.corner_from = { x, y, tv }
        if self.devmode and tv then self.corner_trace = tv end
        self.corner_task = self:schedule(CFG.corner_hold_s, function()
            self.corner_task = nil
            if self.devmode then logger.info("riddle: corner timer fired, still down:", self.corner_from ~= nil) end
            if self.corner_from then self:exit() end
        end)
    end
    self:stopGcSteps()
    self:cancel(self.idle_task)
    self.idle_task = nil
    -- the pen comes first: the background Notion read and the summary give way (one core on the PW2;
    -- an answer preempts them in the runner)
    if self.runner then self.runner:cancel("sync") end
    self:cancelSummary()
    -- on the map a touch at an edge or in the bottom strip moves the field: no ink, no page (riddle_mapview)
    if self.map and self.map:dragStart(x, y) then return end
    if self.map then
        self:mapInkDown(x, y)
        return
    end
    -- the status page: a touch closes it and leaves no ink (the diary as it was)
    if self.status then
        self:closeStatus("touch")
        return
    end
    self.cur = { p = { x, y }, b = { x, y, x, y }, lvl = 0 }
    -- she writes on after the rose (the triangle): she changed her mind, the map (the status page) waiting for its turn
    -- goes (what she writes now must not be wiped by its opening); a new sign brings it back
    self:cancelMap()
    if not self.page then -- a new page starts with this stroke
        self.page = { strokes = {} }
    end
    self.strokes[#self.strokes + 1] = self.cur
    self.page.strokes[#self.page.strokes + 1] = self.cur
    -- after self.cur: their first step must already see the finger (penNear)
    self:fadeInvitation()
    self:hurryAnswer()
    self:growInk(x, y)
    self:inkStamp(x, y)
end

-- ink on the map: the map's own page (riddle_mapview), never dissolved by the sink; t0 — when the pen came down (a
-- curved stroke from the edge is written at the lift), default now
function Diary:mapInkDown(x, y, t0)
    self.cur = { p = { x, y }, b = { x, y, x, y }, lvl = 0, t0 = t0 or now() }
    self.map:touch()
    self:inkStamp(x, y)
end

function Diary:inkStamp(x, y)
    stamp(self.canvas, x, y, BLACK)
    self:markDirty(x, y, x, y)
    self.lx, self.ly = x, y
end

-- devmode: raw touch events for corner_trace_s (kernel time) after a touch lands in the corner,
-- every slot, the lift and whatever comes after it (live 07:47-07:48: lifts ~1.5 s in, cause unknown)
function Diary:traceCorner(tev)
    local t0 = self.corner_trace
    if not tev.timev or time.to_s(tev.timev - t0) > CFG.corner_trace_s then
        self.corner_trace = nil
        return
    end
    logger.info(string.format("riddle: corner tev slot=%s id=%s x=%s y=%s +%.3f", tostring(tev.slot),
        tostring(tev.id), tostring(tev.x), tostring(tev.y), time.to_s(tev.timev - t0)))
end

function Diary:penMove(x, y)
    local cf = self.corner_from
    if cf and (math.abs(x - cf[1]) > CFG.corner_slop or math.abs(y - cf[2]) > CFG.corner_slop) then
        self.corner_from = nil
        self:cancel(self.corner_task)
        self.corner_task = nil
    end
    if self.map and self.map.drag then
        self.map:dragMove(x, y)
        return
    end
    self:inkMove(x, y)
end

function Diary:inkMove(x, y)
    local cur = self.cur
    if not cur then return end
    local lx, ly = self.lx, self.ly
    if math.abs(x - lx) + math.abs(y - ly) < 2 then return end
    line(self.canvas, lx, ly, x, y, BLACK, stamp)
    local p, b = cur.p, cur.b
    p[#p + 1] = x
    p[#p + 1] = y
    if x < b[1] then b[1] = x end
    if y < b[2] then b[2] = y end
    if x > b[3] then b[3] = x end
    if y > b[4] then b[4] = y end
    if not self.map then self:growInk(x, y) end
    self:markDirty(lx, ly, x, y)
    self.lx, self.ly = x, y
end

function Diary:penUp(tv)
    local cf = self.corner_from
    self.corner_from = nil
    self:cancel(self.corner_task)
    self.corner_task = nil
    -- the hold by the kernel's touch times: while the loop is blocked (respond waits for the LLM)
    -- the whole touch sits in the input buffer and comes as one batch, penUp right after penDown,
    -- so the timer never gets its turn
    if cf and cf[3] and tv then
        local held = time.to_s(tv - cf[3])
        if self.devmode then logger.info(string.format("riddle: corner lift, held %.2f s", held)) end
        if held >= CFG.corner_hold_s then
            self:exit()
            return
        end
    end
    if self.map and self.map.drag then
        local p, t0 = self.map:dragEnd()
        if p then -- a curved stroke begun at the edge: ink after all (the pen has been lifted, the stroke is drawn now)
            self:mapInkDown(p[1], p[2], t0)
            for i = 3, #p, 2 do self:inkMove(p[i], p[i + 1]) end
            self:inkUp()
        end
        return
    end
    self:inkUp()
end

function Diary:inkUp()
    local cur = self.cur
    if not cur then return end
    cur.t_end = now()
    self.cur = nil
    if self.map then
        self.map:onStrokeDone(cur)
        return
    end
    self:ensureSinkTicker()
    self.idle_task = self:schedule(CFG.idle_s, function()
        self.idle_task = nil
        self:onPageDone()
    end)
end

---------------------------------------------------------------------------
-- rolling sink: every stroke starts dissolving sink_delay_s after its pen-up,
-- one mask bucket per dissolve.step_s, while the person keeps writing.
-- One timer, alive only while some ink is still visible.

function Diary:ensureSinkTicker()
    if self.sink_task then return end
    self.sink_task = self:schedule(CFG.sink_tick_s, function()
        self.sink_task = nil
        self:sinkTick()
    end)
end

function Diary:sinkTick()
    local t0 = now()
    local last = CFG.dissolve.steps
    local cb = self.cur and self.cur.b
    local pending = false
    local changed
    for _, s in ipairs(self.strokes) do
        if s.t_end and s.lvl < last then
            local age = time.to_s(t0 - s.t_end)
            local want = math.floor((age - CFG.sink_delay_s) / CFG.dissolve.step_s) + 1
            if want > s.lvl then
                -- never repaint under the moving finger: dissolve refreshes there would collide
                -- with the a2 ink updates and add latency. Wait for the pen-up.
                if not (cb and near(s.b, cb, CFG.sink_guard)) then
                    s.lvl = s.lvl + 1 -- at most one step per tick: gradual even after a stall
                    changed = changed or {}
                    changed[#changed + 1] = s
                end
            end
        end
        if s.lvl < last then pending = true end
    end
    if changed then
        for _, s in ipairs(changed) do
            local b = s.b
            self:renderRegion(b[1] - 4, b[2] - 4, b[3] - b[1] + 9, b[4] - b[2] + 9)
        end
        -- gone strokes leave the screen list (their page record keeps them for the PNG)
        local keep = {}
        for _, s in ipairs(self.strokes) do
            if s.lvl < last then keep[#keep + 1] = s end
        end
        self.strokes = keep
        local us = time.to_us(now() - t0)
        local st = self.stats
        st.sink_ticks = st.sink_ticks + 1
        st.sink_us = st.sink_us + us
        if us > st.sink_us_max then st.sink_us_max = us end
        if self.test and not self.test.shot_dissolve and changed[1].lvl == 2 then
            self.test.shot_dissolve = true
            self:testShot("dissolving")
        end
    end
    if #self.queue > 0 then self:nextAnswer() end
    if pending then
        self:ensureSinkTicker()
    else
        self:maybeIdle()
    end
end

---------------------------------------------------------------------------
-- the cycle: idle_s of silence after the last pen-up -> PNG from the page record -> responder;
-- the answer comes on screen once that page's ink has dissolved and the previous answer is gone,
-- appears letter by letter, holds, dissolves. The last answer holds until a touch; a touch at any
-- point makes it dissolve now.

function Diary:onPageDone()
    local pg = self.page
    if not pg or self.cur then return end
    self.page = nil
    local st = self.stats
    logger.info(string.format("riddle: page done, strokes=%d ink_frames=%d avg_frame_us=%d max_frame_us=%d sink_ticks=%d avg_sink_us=%d max_sink_us=%d grey_px=%d RSS_KB=%d",
        #pg.strokes, st.frames, st.frames > 0 and st.frame_us / st.frames or 0, st.frame_us_max,
        st.sink_ticks, st.sink_ticks > 0 and st.sink_us / st.sink_ticks or 0, st.sink_us_max, st.grey_px, rssKB()))
    st.frames, st.frame_us, st.frame_us_max, st.sink_ticks, st.sink_us, st.sink_us_max, st.grey_px = 0, 0, 0, 0, 0, 0, 0
    if self.test then
        self:logRefresh("page")
        if self.test.n == 1 then self:testShot("silence") end
    end
    -- a sign is not a message: the page reaches neither the model nor the memory, nobody answers it; its mode opens in
    -- its turn in the queue, after the answer in flight. The triangle first and under any seal (the status page shows
    -- nothing of the diary; owner: «во всех случаях»); a rose of the winds only under an open seal (plan of the map).
    -- Under a closed seal a page of 1–2 strokes is mostly a try at the seal word, not at a sign: no stroke file for it
    local ctl = self.controller
    -- an accidental touch (owner 2026-10-25): its PNG would be under png.MIN_SIDE on both sides
    local _, _, w, h = self:sampleBox(pg)
    local tiny = png.tiny(w, h)
    local top = math.max(pg.ink[2] - 10, self:textFloor())
    -- the seal's key goes first, before the triangle (spec 2026-11-20-seal-key §5): a try at the sign (up to
    -- glyph.MAX_STROKES strokes; never an accidental touch) is not a message either -- its phrase takes the page's
    -- place in the queue, without the model
    if ctl and not tiny and #pg.strokes <= glyph.MAX_STROKES then
        local was_open = ctl.seal_open
        local phrase = ctl:key_page(pg.strokes)
        if phrase then
            logger.info("riddle: key page")
            -- kind "key": not the model's answer -- the pen over it marks no interruption (hurryAnswer)
            self.queue[#self.queue + 1] = { text = phrase, top = top, page = pg, kind = "key",
                                            unlocked = ctl.seal_open and not was_open }
            self:nextAnswer()
            return
        end
    end
    local sealed = ctl and not ctl.seal_open
    if self:isSign(triangle, "triangle", pg.strokes, not sealed) then
        self:queueMode("status", pg, "triangle")
        return
    end
    if ctl and ctl.seal_open and self:isRose(pg.strokes) then
        self:queueMode("map", pg, "rose")
        return
    end
    -- an accidental touch never reaches the model, even during the ponder (no refusal for it): no PNG, no answer,
    -- inflight unchanged; its ink dissolves as usual
    if tiny then
        logger.info(string.format("riddle: page too small %dx%d -> skipped", w, h))
        self:maybeIdle() -- the sink may have found the ink gone while the page was still open
        return
    end
    local async = self.runner ~= nil
    -- an answer is on its way: this page never reaches the model (no PNG, inflight unchanged),
    -- it gets a refusal in its place in the queue
    if async and ctl and self.inflight > 0 then
        logger.info("riddle: page during ponder -> refusal")
        self.queue[#self.queue + 1] = { text = ctl:pick(ctl:texts("busy")), top = top, page = pg, kind = "busy" }
        self:nextAnswer()
        return
    end
    -- the pen cut short an answer (owner 2026-10-25: «пусть реддл реагирует, когда пишу»): a canned
    -- interjection takes the page's place in the queue at once, the page still goes to the model
    -- and its answer comes after the interjection. Not an answer: never reaches the controller
    if async and ctl and pg.interrupted then
        logger.info("riddle: page after interrupted answer -> interjection")
        self.queue[#self.queue + 1] = { text = ctl:pick(ctl:texts("interrupted")), top = top, page = pg, kind = "interject" }
        self:nextAnswer()
    end
    local sample = self:saveSample(pg)
    local epoch = self.epoch
    self.inflight = self.inflight + 1
    local function ask()
        -- a new stroke began meanwhile: the blocked loop would freeze the pen mid-stroke.
        -- Wait for its pen-up, however long: a stroke always ends, a cap would freeze it anyway
        if not async and self.cur then
            self:schedule(CFG.sink_tick_s, ask)
            return
        end
        -- the answer is late: a thinking phrase takes its place in the queue until it comes, step by
        -- step (ponder_s, then every ponder_every_s), a new phrase each time. The request still waiting
        -- for the link at step offline_step: that step is fail_offline (wait.give_up -> the callback)
        local ponder
        local wait = {}
        if async and ctl then
            local t0, step, used = now(), 0, {}
            local function think()
                -- a long phrase reveals and dissolves longer than ponder_every_s: the one still waiting
                -- in the queue is stale, the new one takes its place
                self:dropThinking()
                self.queue[#self.queue + 1] = { text = ctl:pick(ctl:texts("thinking"), used), top = top, page = pg,
                                                kind = "think", t0 = t0 }
            end
            local function tick()
                ponder = nil
                step = step + 1
                if step >= CFG.offline_step and wait.give_up then
                    wait.give_up()
                    return
                end
                logger.info(string.format("riddle: ponder step %d", step))
                think()
                ponder = self:schedule(CFG.ponder_every_s, tick)
                self:nextAnswer()
            end
            ponder = self:schedule(CFG.ponder_s, tick)
            -- the last refusal dissolved, the answer is still on its way: fadeAnswer asks for a phrase
            self.rethink = function() logger.info("riddle: ponder again after refusal") think() end
        end
        self.responder(sample, function(text, unlocked, action)
            -- the diary was closed or put to sleep meanwhile: this answer belongs to a wiped page
            if not self.canvas or epoch ~= self.epoch then
                logger.info("riddle: answer dropped, its page is gone")
                return
            end
            self:cancel(ponder)
            self.rethink = nil
            self:dropThinking()
            self.inflight = self.inflight - 1
            if text == nil then
                -- the controller found the PNG an accidental touch: nothing to show; a thinking
                -- phrase on screen goes as if the answer had come
                local a = self.answer
                if a and a.kind == "think" then
                    a.answered = true
                    if a.phase == "hold" then self:armHold(a) end
                end
                -- the interjection for this page has no answer behind it: it goes on the ordinary
                -- hold timer, whether it is on screen, revealing or still in the queue. A refusal
                -- belongs to a page written while this one waited (it never reached the model, its
                -- page is never pg): the answer it waited behind is not coming either
                local function lonely(x)
                    return x.kind == "busy" or (x.kind == "interject" and x.page == pg)
                end
                if a and lonely(a) then
                    a.release = true
                    if a.phase == "hold" and not a.task then self:armHold(a) end
                end
                for _, q in ipairs(self.queue) do
                    if lonely(q) then q.release = true end
                end
            else
                self.queue[#self.queue + 1] = { text = text, top = top, page = pg, unlocked = unlocked }
            end
            if action == "map" then self:phraseOpensMap(pg) end
            -- a sign drawn while this answer was on its way: its mode goes right behind it
            local due = self.mode_due
            if due and self.inflight == 0 then
                self.mode_due = nil
                self:queueMode(due.kind, due.page, due.why)
            end
            if async then
                self.asking = nil
                self:pumpAsks()
            end
            self:nextAnswer()
            if text == nil then self:maybeIdle() end
        end, wait)
    end
    -- the subprocess leaves the loop free: the page goes at once (or after the answer in flight)
    if async then
        self.asks[#self.asks + 1] = ask
        self:pumpAsks()
        return
    end
    -- the responder blocks the loop for the LLM round-trip and the sink stops with it: the page's
    -- last stroke (pen-up idle_s ago) would hang half-dissolved through the whole request
    local wait = self:inkLeft(pg)
    if wait > 0 then self:schedule(wait, ask) else ask() end
end

-- the answer came: a thinking phrase still waiting in the queue is not shown at all
-- (the one on screen goes by itself: riddle.hold releases it once a follower is queued)
function Diary:dropThinking()
    for i = #self.queue, 1, -1 do
        if self.queue[i].kind == "think" then table.remove(self.queue, i) end
    end
end

-- seconds until the sink has drawn the last dissolve step of the page's youngest stroke.
-- By the clock, not by the strokes' levels: the pen nearby may hold the dissolve, never the answer.
function Diary:inkLeft(pg)
    local young
    for _, s in ipairs(pg.strokes) do
        if s.t_end and (not young or s.t_end > young) then young = s.t_end end
    end
    if not young then return 0 end
    local d = CFG.dissolve
    -- two ticks: the ticker's phase drifts against the pen-up, one tick may land just after us
    local gone = CFG.sink_delay_s + (d.steps - 1) * d.step_s + 2 * CFG.sink_tick_s
    return gone - time.to_s(now() - young)
end

-- seconds the answer stays before dissolving by itself, nil: it waits for a touch (riddle.hold);
-- waiting: answers counted behind it besides the queue
function Diary:holdFor(a, waiting)
    -- a thinking phrase owes the screen think_hold_s from its full reveal to the next thinking phrase
    -- (only while nothing but thinking phrases waits: an answer, a refusal or an interjection
    -- anywhere in the queue sends it away at once)
    local owed
    if a.kind == "think" and #self.queue > 0 and a.held_at then
        local only_thinking = true
        for _, q in ipairs(self.queue) do
            if q.kind ~= "think" then only_thinking = false break end
        end
        if only_thinking then owed = CFG.think_hold_s - time.to_s(now() - a.held_at) end
    end
    return hold.seconds(CFG.answer_hold_s, #self.queue + waiting, self.inflight, a.kind, a.release, owed)
end

-- the answer on screen dissolves by itself only while others wait behind it (riddle.hold);
-- the last one stays until a touch. Test mode (devtest cycles=N) counts one more waiting answer
-- (not for the thinking phrase, the refusal and the interjection) while the round is not the last:
-- the next page chains on the dissolve. The last answer of the round stands like in life, the run
-- ends when it holds (devtest testOnAnswer)
function Diary:armHold(a)
    self:cancel(a.task)
    -- the thinking phrase, the refusal and the interjection are not the cycle's answers: no extra
    -- waiting one for them
    local chained = self.test and self.test.answers < self.test.cycles
        and a.kind ~= "think" and a.kind ~= "busy" and a.kind ~= "interject"
    local s = a.answered and 0 or self:holdFor(a, chained and 1 or 0)
    a.task = s and self:schedule(s, function() a.task = nil self:fadeAnswer() end) or nil
end

function Diary:nextAnswer()
    local q = self.queue[1]
    if self.answer then
        -- a follower arrived behind an answer that waits for a touch: now it gets its timer
        local a = self.answer
        -- a thinking phrase's timer is the minimum stand: an answer behind it cuts that short
        if q and a.phase == "hold" and (not a.task or a.kind == "think") then self:armHold(a) end
        return
    end
    if not q then return end
    local last = CFG.dissolve.steps
    for _, s in ipairs(q.page.strokes) do
        if s.lvl < last then return end -- sinkTick calls again
    end
    table.remove(self.queue, 1)
    local open = MODES[q.kind]
    if open then
        self[open](self, q.why)
        return
    end
    if q.kind == "think" then
        logger.info(string.format("riddle: ponder shown after %d ms", time.to_ms(now() - q.t0)))
    end
    self:revealAnswer(q.text, q.top, q.unlocked, q.kind, q.release, q.page)
end

-- the page's crop in the PNG: the ink's box plus a margin, on screen -> x0, y0; downscaled -> w, h
function Diary:sampleBox(pg)
    local b = pg.ink
    local pad, s = 8, CFG.sample_scale
    local x0, y0 = math.max(0, b[1] - pad), math.max(0, b[2] - pad)
    local x1, y1 = math.min(self.w - 1, b[3] + pad), math.min(self.h - 1, b[4] + pad)
    return x0, y0, math.floor((x1 - x0) / s) + 1, math.floor((y1 - y0) / s) + 1
end

function Diary:saveSample(pg)
    local t0 = now()
    local s = CFG.sample_scale
    local x0, y0, w, h = self:sampleBox(pg)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(WHITE)
    local function at(x, y) return math.floor((x - x0) / s), math.floor((y - y0) / s) end
    for _, st in ipairs(pg.strokes) do ink.polyline(bb, st.p, BLACK, stampSmall, at) end
    local t1 = now()
    local path = string.format("%s/%s-%03d.png", SAMPLE_DIR, os.date("%Y%m%d-%H%M%S"), (time.to_ms(t0) % 1000))
    local ok, err = pcall(bb.writePNG, bb, path)
    bb:free()
    local t2 = now()
    if not ok then
        logger.err("riddle: PNG save failed", err)
        return nil
    end
    local size = lfs.attributes(path, "size")
    logger.info(string.format("riddle: sample %s %dx%d %d bytes, draw_ms=%d png_ms=%d",
        path, w, h, size or -1, time.to_ms(t1 - t0), time.to_ms(t2 - t1)))
    return path
end

-- one answer step on screen: rebuild the rect, time it (and, in test mode, check no ink was lost)
function Diary:answerStep(x, y, w, h)
    local t0 = now()
    self:renderRegion(x, y, w, h)
    local us = time.to_us(now() - t0)
    local st = self.stats
    st.ans_steps = st.ans_steps + 1
    if us > st.ans_us_max then st.ans_us_max = us end
    if self.test then st.lost_ink = st.lost_ink + self:countLostInk(x, y, w, h) end
end

-- kind: nil (an answer), "think" (thinking phrase), "busy" (refusal), "interject" (interjection), "key" (the seal key's
-- phrase; holds like an answer) — riddle.hold
-- release: an interjection whose page turned out an accidental touch — no answer follows, it holds on a timer
-- page: the page the phrase answers (the answer callback matches an interjection on screen by it)
function Diary:revealAnswer(text, top, unlocked, kind, release, page)
    local block = layoutText(self.face_answer, text, CFG.margin, top, self.w - 2 * CFG.margin)
    -- the bottom strip belongs to the corner icons: an answer must not run into it -- laid out again higher up,
    -- and what does not fit even there is cut off (riddle.layout.clip); the persona's memory keeps it whole
    local limit = self.h - CFG.tray.band
    if block.rect.y + block.rect.h > limit then
        block = layoutText(self.face_answer, text, CFG.margin, self:textFloor() + 10, self.w - 2 * CFG.margin, limit)
        if block.clipped then logger.info(string.format("riddle: answer clipped to %d lines", block.clipped)) end
    end
    local a = { block = block, layer = newLayer(block.rect), lvl = 0, i = 0, phase = "reveal", t0 = now(), kind = kind, release = release, page = page }
    self.answer = a
    if unlocked then self:scheduleFollowup() end
    if self.test then self:testOnAnswer("reveal") end
    local function step()
        a.task = nil
        local r = a.wait -- a glyph already in the layer, its repaint held back by the pen
        if r then
            if self:penNear(r[1], r[2], r[3], r[4]) then
                a.task = self:schedule(CFG.sink_tick_s, step)
                return
            end
            a.wait = nil
            self:answerStep(r[1], r[2], r[3], r[4])
        else
            a.i = a.i + 1
            local g = block.glyphs[a.i]
            if not g then
                logger.info(string.format("riddle: answer revealed in %.0f ms", time.to_ms(now() - a.t0)))
                if self.test and self.test.answers == 1 then self:testShot("answer") end
                a.phase = "hold"
                a.held_at = now()
                self:armHold(a)
                if self.test then self:testOnAnswer("hold") end
                return
            end
            local x, y, w, h = layerDrawGlyph(a.layer, block.face, g)
            if x then
                if self:penNear(x, y, w, h) then
                    a.wait = { x, y, w, h }
                    a.task = self:schedule(CFG.sink_tick_s, step)
                    return
                end
                self:answerStep(x, y, w, h)
            end
        end
        local nxt = block.glyphs[a.i + 1]
        a.task = self:schedule((nxt and nxt.word_start) and CFG.reveal_space_s or CFG.reveal_char_s, step)
    end
    step()
end

-- a touch while the answer is on screen: stop revealing / holding, dissolve now.
-- A real answer cut short while still going (revealing, or held on a timer: others wait behind it)
-- marks the page being written: it gets an interjection (onPageDone). The last answer waits for a
-- touch: writing on after it is no interruption
function Diary:hurryAnswer()
    local a = self.answer
    if not a or a.phase == "fade" then return end
    if not a.kind and self.page and (a.phase == "reveal" or a.task) then self.page.interrupted = true end
    self:cancel(a.task)
    a.task = nil
    logger.info("riddle: answer hurried by the pen during", a.phase, "glyphs shown", a.i)
    self:fadeAnswer()
end

-- the answer dissolves through the mask; renderRegion keeps every stroke on top
function Diary:fadeAnswer()
    local a = self.answer
    if not a or a.phase == "fade" then return end
    a.phase = "fade"
    if self.test then self:testOnAnswer("fade") end
    local d = CFG.dissolve
    local function step()
        a.task = nil
        local r = a.block.rect
        if self:penNear(r.x, r.y, r.w, r.h) then
            a.task = self:schedule(CFG.sink_tick_s, step)
            return
        end
        a.lvl = a.lvl + 1
        self:answerStep(r.x, r.y, r.w, r.h)
        if a.lvl < d.steps then
            a.task = self:schedule(d.step_s, step)
            return
        end
        a.layer.bb:free()
        self.answer = nil
        local st = self.stats
        logger.info(string.format("riddle: answer gone, steps=%d max_step_us=%d grey_px=%d lost_ink_px=%d, lua heap KB %d, RSS KB %d",
            st.ans_steps, st.ans_us_max, st.grey_px, st.lost_ink, collectgarbage("count"), rssKB()))
        st.ans_steps, st.ans_us_max, st.lost_ink = 0, 0, 0
        if self.test then self:testAnswerGone() end
        -- the last refusal is gone and the answer is still in flight (up to ceil_s): an empty screen
        -- looks like a hang, the thinking phrase comes back
        if a.kind == "busy" and self.rethink and self.inflight > 0 and #self.queue == 0 then self.rethink() end
        self:nextAnswer()
        self:maybeIdle()
    end
    step()
end

-- Nothing on screen, nothing pending: walk the GC forward in small steps so the heap
-- (touch-frame tables, closures) never ratchets RSS up, without the 190 ms stall of a
-- full collect. Stops at the end of a GC cycle or at the next touch.
function Diary:maybeIdle()
    if self.page or self.cur or #self.strokes > 0 or self.answer or #self.queue > 0 or self.inflight > 0 or self.map
        or self.status then
        return
    end
    if self.on_idle then
        local ok, err = pcall(self.on_idle)
        if not ok then logger.warn("riddle: on_idle failed", err) end
    end
    if self.gc_task then return end
    self:startGcSteps()
    if self.test then self:testIdle() end
end

function Diary:startGcSteps()
    self:stopGcSteps()
    local g = { n = 0, max_us = 0, heap0 = collectgarbage("count"), t0 = now() }
    self.gc = g
    local function tick()
        self.gc_task = nil
        local t0 = now()
        local done = collectgarbage("step", CFG.gc_step_kb)
        local us = time.to_us(now() - t0)
        g.n = g.n + 1
        if us > g.max_us then g.max_us = us end
        if done or g.n >= 400 then
            self:stopGcSteps(done and "cycle done" or "step cap")
            return
        end
        self.gc_task = self:schedule(CFG.gc_tick_s, tick)
    end
    self.gc_task = self:schedule(CFG.gc_tick_s, tick)
end

function Diary:stopGcSteps(why)
    self:cancel(self.gc_task)
    self.gc_task = nil
    local g = self.gc
    if not g then return end
    self.gc = nil
    logger.info(string.format("riddle: gc %s: steps=%d max_step_us=%d heap KB %d -> %d in %d ms, RSS KB %d",
        why or "interrupted by pen", g.n, g.max_us, g.heap0, collectgarbage("count"), time.to_ms(now() - g.t0), rssKB()))
end

---------------------------------------------------------------------------
-- the marauder's map (plan of the map): a mode of the diary. While it is open the pen draws on the map
-- (riddle_mapview), the diary's page, answers and queue are gone, the followup and the Notion sync wait.

-- a sign drawn with the pen? mod — its recognizer (riddle.rose, riddle.triangle: detect, CRITERIA, MAX_STROKES), name —
-- its word in the log. Devmode only, for tuning the thresholds on the owner's hand (A10): its score and each criterion
-- (a share of its threshold) go to the log, and a page with no more strokes than the sign can have is written as a
-- stroke file <rose_dir>/<time>-<n>.lua (the fixtures' format), so live attempts become fixtures. misses == false: only
-- a recognized sign is written (the page was not meant as a sign attempt), the log line stays
function Diary:isSign(mod, name, strokes, misses)
    local ok, score, why = mod.detect(strokes)
    if not self.devmode then return ok end
    local file = (ok or misses ~= false) and #strokes <= mod.MAX_STROKES and self:recordStrokes(strokes)
    local parts = {}
    for _, k in ipairs(mod.CRITERIA) do
        if why and why[k] then parts[#parts + 1] = string.format("%s=%.2f", k, why[k]) end
    end
    logger.info(string.format("riddle: %s %s score=%.2f %s n=%d%s", name, ok and "yes" or "no", score,
        table.concat(parts, " "), #strokes, file and (" file=" .. file) or ""))
    return ok
end

function Diary:isRose(strokes)
    return self:isSign(rose, "rose", strokes)
end

-- every live attempt of a sign in one place (rose_dir); a page checked by both signs is written once
function Diary:recordStrokes(strokes)
    local last = self.recorded
    if last and last.strokes == strokes then return last.name end
    local dir = self.rose_dir or (RIDDLE_DIR .. "/roses")
    lfs.mkdir(dir)
    Diary.rose_n = (Diary.rose_n or 0) + 1
    local name = string.format("%s-%d.lua", os.date("%Y%m%d-%H%M%S"), Diary.rose_n)
    local f = io.open(dir .. "/" .. name, "w")
    if not f then return nil end
    f:write("return {\n")
    for _, s in ipairs(strokes) do f:write("{p={", table.concat(s.p or {}, ","), "}},\n") end
    f:write("}\n")
    f:close()
    self.recorded = { strokes = strokes, name = name }
    return name
end

-- a mode's turn in the queue (kind: "map" | "status"): right away when no answer is on its way, else behind that
-- answer (the callback queues it, mode_due); its page's ink dissolves first (nextAnswer)
function Diary:queueMode(kind, pg, why)
    if self.inflight > 0 then
        self.mode_due = { kind = kind, page = pg, why = why }
        return
    end
    self.queue[#self.queue + 1] = { kind = kind, page = pg, why = why }
    self:nextAnswer()
end

-- the page was the map's opening phrase (riddle.prompt.MAP_FORMAT; the model read it, plan of the map, slice 3): like a
-- rose, the map takes its turn once the page's ink is gone. A sign drawn while the phrase was being read gives way to
-- the map: it opens once
function Diary:phraseOpensMap(pg)
    if self.mode_due and self.mode_due.kind == "status" then logger.info("riddle: status dropped (map phrase)") end
    self.mode_due = nil
    self:queueMode("map", pg, "phrase")
end

-- a page written on the map, not a rose: the model reads it (riddle.prompt.map_read, the runner's "answer"); the
-- closing phrase closes the map. Only with a link: offline the phrase does not close it (the rose and the autoclose
-- do). The read preempts the "map" job (point, terrain): it goes again after the read while the map is open
function Diary:readMapPage(pg)
    local ctl = self.controller
    if not (ctl and self.runner and pg.ink) then return end
    local state = net.state()
    if state ~= "up" then
        logger.info("riddle: map read skipped, network " .. state)
        return
    end
    local _, _, w, h = self:sampleBox(pg)
    if png.tiny(w, h) then return end
    local sample = self:saveSample(pg)
    if not sample then return end
    local job = ctl:map_read_job(sample)
    if not job then return end
    local view, preempts = self.map, self.runner:busy() == "map"
    local ok, err = self.runner:start("answer", job.run, { timeout_s = CFG.ceil_s, on_done = function(payload, perr)
        local _, action = ctl:finish(job, payload, perr)
        if self.map ~= view then return end -- closed (or closed and opened again) meanwhile
        if action == "map" then
            self:closeMap("phrase")
        elseif preempts then
            self:startMapJob()
        end
    end })
    if not ok then logger.info("riddle: map read not started: " .. tostring(err)) end
end

-- the pen after a sign, before its mode has opened: any mode waiting behind an answer (mode_due) or in the queue goes
function Diary:cancelMap()
    local gone = {}
    if self.mode_due then gone[self.mode_due.kind] = true end
    self.mode_due = nil
    for i = #self.queue, 1, -1 do
        local kind = self.queue[i].kind
        if MODES[kind] then
            table.remove(self.queue, i)
            gone[kind] = true
        end
    end
    for kind in pairs(gone) do logger.info("riddle: " .. kind .. " cancelled (pen)") end
end

-- the diary's page goes (like a sleep wipes it), the parchment comes with a full refresh. A followup already
-- planned keeps waiting (scheduleFollowup) until the map is closed
function Diary:openMap(why)
    local ctl = self.controller
    local followup = self.followup_task ~= nil
    self:resetPage()
    -- the heroes rotate between opens (riddle.cast.place's seed); counted from the wall clock, so a restarted KOReader
    -- does not begin with the same cast again
    Diary.map_opens = (Diary.map_opens or os.time()) + 1
    -- slice 12/14: the cast of the map closed less than map_keep_s ago (the clock gone back: the cast picked anew)
    local kept, age = Diary.map_kept, nil
    if kept then age = os.time(self.map_clock()) - kept.at end
    if not (age and age >= 0 and age < CFG.map_keep_s) then kept = nil end
    self.map = MapView.new(self, ctl and ctl:map() or mapdata.of(nil, nil, nil), self:mapPoint(), Diary.map_opens,
                           kept)
    self.map:open()
    if followup then self:scheduleFollowup() end
    logger.info("riddle: map open (" .. tostring(why) .. ")")
    self:startMapJob()
end

function Diary:mapPoint()
    if not self.map_point then return nil end
    local ok, point = pcall(self.map_point)
    if not ok then logger.warn("riddle: map point read failed", point) end
    return ok and point or nil
end

-- the "map" job (riddle.mapjob) in the subprocess: only with a link (no link -> the saved point or "blind");
-- an answer preempts it, the pen on the map does not cancel it, closeMap does
function Diary:startMapJob()
    if not (self.runner and self.map_job) then return end
    local state = net.state()
    if state ~= "up" then
        logger.info("riddle: map point skipped, network " .. state)
        return
    end
    local view, t0 = self.map, now()
    local ok, err = self.runner:start("map", self.map_job, { timeout_s = CFG.map_ceil_s, on_done = function(payload, perr)
        logger.info(mapjob.log_line(payload, perr, time.to_ms(now() - t0)))
        if self.map ~= view or not payload then return end
        view:setPoint(self:mapPoint(), mapjob.fetched(payload))
    end })
    if not ok then logger.info("riddle: map job not started: " .. tostring(err)) end
end

-- why: "rose" | "phrase" | "idle" | "devtest" -> a clean diary page with the invitation, a full refresh, then as after an answer
-- (the followup goes on, maybeIdle); "sleep" | "exit" -> nothing drawn (the screensaver, KOReader own the screen)
function Diary:closeMap(why)
    local view = self.map
    if not view then return end
    view:close()
    self.map = nil
    -- slice 12/14: the cast on the map now (names, not places), for a map opened again soon (Diary:openMap); in the
    -- module's table like map_opens (a restarted KOReader picks anew). The only writer: every close, a sleep or an exit
    -- too. Closed before its heroes came out (the ink still coming): the cast it was given is kept on
    local kept = view:kept() or view.kept_cast
    Diary.map_kept = kept and { terrain = kept.terrain, names = kept.names, at = os.time(self.map_clock()) }
    if self.runner then self.runner:cancel("map") end
    logger.info("riddle: map close (" .. why .. ")")
    if why == "sleep" or why == "exit" then return end
    self:backToDiary()
end

-- a mode closed (not by a sleep or an exit): a clean diary page with the invitation, a full refresh, then as after an
-- answer (the followup goes on, maybeIdle)
function Diary:backToDiary()
    local followup = self.followup_task ~= nil
    self:resetPage()
    self:showInvitation(false)
    self:trayShow("back")
    self:push(0, 0, self.w, self.h, "full")
    if followup then self:scheduleFollowup() end
    self:maybeIdle()
end

---------------------------------------------------------------------------
-- the status page (plan 2026-11-19-status-triangle): a mode like the map — the triangle opens it, a touch closes it.
-- The facts are read once, at the open, from the device itself; a failed source is «—» (status.collect), never a
-- page that does not open. Nothing here waits for the network.

-- the device's sources for status.collect (L1–L6 of the plan); read_file(path) -> whole file | nil — the plugin's
-- reader (main.lua); without it every file is unknown («—»)
function Diary:statusSources()
    local read = self.read_file
    return {
        read = read,
        build = function() return read(PLUGIN_DIR .. "/" .. status.BUILD_NAME) end,
        power = readPower,
        net = net.state,
        wifi = function()
            local essid
            local ok, mgr = pcall(require, "ui/network/manager")
            -- declared only on some Kindles (device/kindle/device.lua): absent -> no network name
            if ok and type(mgr) == "table" and type(mgr.getCurrentNetwork) == "function" then
                local nok, nw = pcall(mgr.getCurrentNetwork, mgr)
                if nok and type(nw) == "table" then essid = nw.ssid end
            end
            local h = io.popen(IP_CMD)
            local out = h and h:read("*a")
            if h then h:close() end
            return { essid = essid, ip = status.ip(out) }
        end,
        disk = function(path) -- util.diskUsage: bytes
            local u = require("util").diskUsage(path)
            return u and { free_kb = u.available / 1024, total_kb = u.total / 1024 }
        end,
        sync_last = function()
            local sync = require("riddle.sync") -- the store's module: loaded with the page, not with the diary
            return sync.parse_last(read(sync.LAST_PATH))
        end,
        store = function() -- one read of the store: its meta is a string
            local s = self.store()
            return { ok_at = tonumber(s.last_ok), docs = s.docs, collections = s.collections }
        end,
        now = os.time,
    }
end

-- the diary's page goes (like the map's open), the facts are printed in the prompt's face top-down: the head (all
-- well | what is broken), a gap, a row per fact (their rects: the model's row is written again later), a full refresh.
-- Then the model's probe goes to the runner ("probe"): the page does not wait for it, its answer rewrites the model's
-- row (startProbe). No link (the facts' net) -> «нет сети» at once; a busy runner -> what it is busy with, no probe
function Diary:openStatus(why)
    local followup = self.followup_task ~= nil
    self:resetPage()
    local facts = status.collect(self:statusSources())
    local l = status.lines(facts)
    local ctl, model = self.controller, nil
    if ctl and self.runner then
        if facts.net ~= "up" then
            model = { state = "offline" }
            logger.info("riddle: probe skipped нет сети")
        elseif self.runner:busy() then
            model = { state = "busy", kind = self.runner:busy() }
            logger.info("riddle: probe skipped busy:" .. tostring(model.kind))
        else
            model = { state = "checking" }
        end
        l.rows[status.MODEL_ROW] = status.model_line(model)
    end
    local top = CFG.margin
    for _, text in ipairs(l.head) do
        local r = self:paintText(text, top)
        top = r.y + r.h
    end
    top = top + math.floor(self.face_prompt.ftsize:getHeightAndAscender() / 2 + 0.5)
    local rects = {}
    for i, text in ipairs(l.rows) do
        rects[i] = self:paintText(text, top)
        top = rects[i].y + rects[i].h
    end
    local view = { facts = facts, rects = rects }
    self.status = view
    self:push(0, 0, self.w, self.h, "full")
    if followup then self:scheduleFollowup() end
    logger.info("riddle: status open (" .. tostring(why) .. ")")
    if model and model.state == "checking" then self:startProbe(view) end
end

-- an error text for the log: one line, at most LOG_ERR_CHARS characters (not bytes: a Cyrillic letter is not cut in half)
local LOG_ERR_CHARS = 120
local function logLine(err)
    return prompt.utf8_head(str.one_line(tostring(err)), LOG_ERR_CHARS)
end

-- the model's probe (Controller:probe_job) in the subprocess; its answer goes onto the page it was started for only
-- (closed, or closed and opened again meanwhile -> nothing drawn; closeStatus cancels it anyway)
function Diary:startProbe(view)
    local ctl, t0 = self.controller, now()
    local job, jerr = ctl:probe_job()
    local ok, err = false, jerr
    if job then
        ok, err = self.runner:start("probe", job.run, { timeout_s = CFG.probe_ceil_s, on_done = function(payload, perr)
            local pok, rerr = ctl:probe_finish(payload, perr)
            if self.status ~= view then
                logger.info("riddle: probe late (page closed)")
                return
            end
            local ms = math.floor(time.to_ms(now() - t0) + 0.5)
            logger.info(pok and string.format("riddle: probe done ms=%d", ms) or ("riddle: probe failed " .. logLine(rerr)))
            self:statusModelRow(pok and { state = "ok", ms = ms } or { state = "err", err = rerr })
        end })
        if ok then logger.info("riddle: probe start") end
    end
    if not ok then
        local busy = err == "busy"
        logger.info(busy and ("riddle: probe skipped busy:" .. tostring(self.runner:busy())) or ("riddle: probe not started " .. logLine(err)))
        self:statusModelRow(busy and { state = "busy", kind = self.runner:busy() } or { state = "err", err = err })
    end
end

-- the open page's model row written again (status.model_line): its band whitened across the page, the new text at the
-- same top, a partial refresh of that band only. The row is the page's last: a longer text grows downwards freely
function Diary:statusModelRow(model)
    local r = self.status.rects[status.MODEL_ROW]
    self.canvas:paintRect(0, r.y, self.w, r.h, WHITE)
    local nr = self:paintText(status.model_line(model), r.y)
    self.status.rects[status.MODEL_ROW] = nr
    self:push(0, r.y, self.w, math.max(r.h, nr.h), "ui")
end

-- why: "touch" -> back to the diary (backToDiary); "sleep" | "exit" -> nothing drawn (the screensaver, KOReader own
-- the screen). The model's probe goes with the page
function Diary:closeStatus(why)
    if not self.status then return end
    self.status = nil
    if self.runner then self.runner:cancel("probe") end
    logger.info("riddle: status close (" .. why .. ")")
    if why == "sleep" or why == "exit" then return end
    self:backToDiary()
end

-- a text block, every line centered, in the invitation's face onto the canvas at `top`; pure black/white. No refresh.
-- -> the block's rect (layoutText). opts (the map's labels): px — the face's size, cx — the middle of the lines (default:
-- the page's), maxw — the width they wrap at (default: the page's), dry — only measure; threshold — the glyph AA below
-- it goes black (default CFG.ink_threshold), bold = { dx, dy } — each glyph drawn again shifted by every (i ≤ dx, j ≤ dy)
-- before the threshold (thicker, darker); halo = r — the canvas goes white within r px of the text's ink before the
-- ink, only inside clip { x0, y0, x1, y1 } (haloWhite); -> the lines' own rect { x, y = top, w = the widest + dx,
-- h = lines × line height + dy }
function Diary:paintText(text, top, opts)
    return self:paintTexts({ { text, top, opts } })[1]
end

-- texts { { text, top, opts }, … } (as paintText) onto the canvas together: the halos of all of them first, then the
-- ink of all — a text's halo never whitens a neighbour's letters (a glyph reaches past its rect: MarckScript's Latin up
-- to 5 px; the map's texts stand LABEL_GAP apart) -> their rects, in order
function Diary:paintTexts(list)
    local rects, layers = {}, {}
    for i, it in ipairs(list) do
        local opts = it[3]
        local layer
        rects[i], layer = self:textInk(it[1], it[2], opts)
        if layer then layers[#layers + 1] = { layer = layer, halo = opts.halo, clip = opts.clip } end
    end
    local bb = self.canvas
    for _, l in ipairs(layers) do haloWhite(bb, l.layer, l.halo, l.clip) end
    for _, l in ipairs(layers) do
        composite(bb, l.layer, 0, 0, bb:getWidth(), bb:getHeight())
        l.layer.bb:free()
    end
    return rects
end

-- paintText's measure and glyphs: with opts.halo the glyphs go onto a layer of their own (-> it; the caller whitens
-- the halo, composites and frees it), without — straight onto the canvas -> the rect (paintText's), the layer | nil
function Diary:textInk(text, top, opts)
    local face = opts and opts.px and getFace(opts.px) or self.face_prompt
    local maxw = opts and opts.maxw or self.w - 2 * CFG.margin
    local x0 = opts and opts.cx and math.floor(opts.cx - maxw / 2) or CFG.margin
    local block = layoutText(face, text, x0, top, maxw)
    local right = {} -- line (base) -> its right end
    for _, g in ipairs(block.glyphs) do
        local gl = RenderText:getGlyph(face, g.cp)
        local r = g.x + (gl and gl.ax or 0)
        if not right[g.base] or r > right[g.base] then right[g.base] = r end
    end
    local bdx, bdy = 0, 0
    if opts and opts.bold then bdx, bdy = opts.bold[1], opts.bold[2] end
    local widest, lines = 0, 0
    for _, r in pairs(right) do
        widest, lines = math.max(widest, r - x0), lines + 1
    end
    local line_h = math.floor(face.ftsize:getHeightAndAscender() + 0.5)
    local own = { x = x0 + math.floor((maxw - widest) / 2), y = top, w = widest + bdx, h = lines * line_h + bdy }
    local layer
    if not (opts and opts.dry) then
        -- with a halo the glyphs go onto a layer of their own first: the lines' own rect (a word wider than maxw too)
        -- and the glyphs' overhang and the halo around it (layout.text_reach)
        local halo = opts and opts.halo
        local m = halo and layout.text_reach(halo)
        layer = halo and newLayer({ x = own.x - m, y = own.y - m, w = own.w + 2 * m, h = own.h + 2 * m })
        local bb, ox, oy = self.canvas, nil, nil
        if layer then bb, ox, oy = layer.bb, layer.x, layer.y end
        for _, g in ipairs(block.glyphs) do
            local shift = math.floor((maxw - (right[g.base] - x0)) / 2)
            local x, y, w, h
            for i = 0, bdx do
                for j = 0, bdy do
                    local at = { cp = g.cp, x = g.x + shift + i, base = g.base + j }
                    x, y, w, h = drawGlyph(bb, face, at, BLACK, ox, oy)
                end
            end
            if x then binarize(bb, x - bdx, y - bdy, w + bdx, h + bdy, opts and opts.threshold) end
        end
    end
    if not opts then return block.rect end
    return own, layer or nil
end

---------------------------------------------------------------------------
-- test harness: only on a dev device (the file /mnt/us/riddle/devmode); without it
-- maybeStartTest is a no-op and nothing of riddle/devtest.lua is loaded.

function Diary:maybeStartTest() end

do
    local f = io.open(RIDDLE_DIR .. "/devmode", "r")
    if f then
        f:close()
        Diary.devmode = true
        local ok, devtest = pcall(require, "riddle.devtest")
        if ok then
            devtest.install(Diary, { pixels = pixels, clampRect = clampRect, rssKB = rssKB,
                                     RIDDLE_DIR = RIDDLE_DIR })
        else
            logger.warn("riddle: devtest not loaded", devtest)
        end
    end
end

return Diary
