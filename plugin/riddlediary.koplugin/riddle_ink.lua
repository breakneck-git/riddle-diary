--[[--
The diary's pen: one place for the ink of the page, the PNG sample and the map.
bb — any Blitbuffer (or a table with paintRect); c — the colour; pen — stamp or stamp_small.
--]]

local ink = {}

-- 4px round-ish pen (spec: 3-4 px line)
function ink.stamp(bb, x, y, c)
    bb:paintRect(x - 1, y - 2, 2, 4, c)
    bb:paintRect(x - 2, y - 1, 4, 2, c)
end

-- 2px pen for the half-size sample
function ink.stamp_small(bb, x, y, c)
    bb:paintRect(x, y, 2, 2, c)
end

-- the pen at every pixel step from (x0, y0) to (x1, y1), both ends included
function ink.line(bb, x0, y0, x1, y1, c, pen)
    local dx, dy = x1 - x0, y1 - y0
    local n = math.max(math.abs(dx), math.abs(dy))
    if n == 0 then pen(bb, x0, y0, c) return end
    for i = 0, n do
        pen(bb, math.floor(x0 + dx * i / n + 0.5), math.floor(y0 + dy * i / n + 0.5), c)
    end
end

-- a stroke's polyline p = { x1, y1, x2, y2, … }: the pen at its first point, then ink.line to every next one; at(x, y)
-- -> x, y moves the points first (the sample's halved canvas), none — as they are. One walk for the page's ink under
-- dissolve, the sample and the map's page
function ink.polyline(bb, p, c, pen, at)
    local px, py = p[1], p[2]
    if at then px, py = at(px, py) end
    pen(bb, px, py, c)
    for i = 3, #p - 1, 2 do
        local nx, ny = p[i], p[i + 1]
        if at then nx, ny = at(nx, ny) end
        ink.line(bb, px, py, nx, ny, c, pen)
        px, py = nx, ny
    end
end

return ink
