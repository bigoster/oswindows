--- CC-Windows - wallpaper generation.
--
-- Wallpapers are built once as an array of row strings; the desktop then just
-- copies those rows into the framebuffer, which keeps redraws cheap.
local backdrop = {}

local gfx, theme, C

function backdrop.attach(g, t)
    gfx, theme, C = g, t, t.C
end

local char, rep, concat = string.char, string.rep, table.concat

local function makeRow(w, colourAt)
    local parts, last, start = {}, nil, 0
    for x = 0, w - 1 do
        local c = colourAt(x)
        if c ~= last then
            if last then parts[#parts + 1] = rep(char(last), x - start) end
            last, start = c, x
        end
    end
    parts[#parts + 1] = rep(char(last or 0), w - start)
    return concat(parts)
end

local function putPixel(rows, x, y, c)
    local row = rows[y + 1]
    if not row or x < 0 or x >= #row then return end
    rows[y + 1] = row:sub(1, x) .. char(c) .. row:sub(x + 2)
end

local function putRect(rows, x, y, w, h, c)
    local band = rep(char(c), w)
    for yy = y, y + h - 1 do
        local row = rows[yy + 1]
        if row and yy >= 0 then
            local x0 = math.max(0, x)
            local x1 = math.min(#row, x + w)
            if x1 > x0 then
                rows[yy + 1] = row:sub(1, x0) .. band:sub(1, x1 - x0) .. row:sub(x1 + 1)
            end
        end
    end
end

local function noise(x, y)
    local n = (x * 374761393 + y * 668265263 + 1013904223) % 1024
    return n / 1024
end

---------------------------------------------------------------------------
-- wallpapers
---------------------------------------------------------------------------

local function buildLandscape(w, h)
    local rows = {}
    local horizon = math.floor(h * 0.66)
    if horizon < 20 then horizon = math.min(20, math.floor(h / 2)) end

    -- sky
    for y = 0, horizon - 1 do
        local step = math.min(7, math.floor(y / math.max(1, horizon) * 8))
        rows[y + 1] = rep(char(C.sky1 + step), w)
    end

    -- blocky sun
    local sunX, sunSize = math.floor(w * 0.74), math.max(8, math.floor(h * 0.08))
    local sunY = math.max(2, math.floor(horizon * 0.18))
    putRect(rows, sunX, sunY, sunSize, sunSize, C.sun)
    putRect(rows, sunX + 2, sunY + 2, sunSize - 4, sunSize - 4, C.white)

    -- two flat clouds
    local function cloud(cx, cy, cw)
        putRect(rows, cx, cy, cw, 4, C.cloud)
        putRect(rows, cx + 4, cy - 3, cw - 10, 3, C.cloud)
        putRect(rows, cx - 3, cy + 4, cw + 6, 2, C.cloud)
    end
    cloud(math.floor(w * 0.12), math.floor(horizon * 0.30), math.floor(w * 0.16))
    cloud(math.floor(w * 0.52), math.floor(horizon * 0.52), math.floor(w * 0.12))

    -- distant hills
    for x = 0, w - 1 do
        local lift = math.floor(4 + 4 * math.abs(math.sin(x / 31)) + 3 * math.abs(math.sin(x / 11)))
        local top = horizon - lift
        if top < 1 then top = 1 end
        putPixel(rows, x, top, C.grass)
        for y = top + 1, horizon - 1 do
            putPixel(rows, x, y, C.grassDark)
        end
    end

    -- ground
    for y = horizon, h - 1 do
        local depth = y - horizon
        if depth < 2 then
            rows[y + 1] = rep(char(C.grassLight), w)
        elseif depth < 7 then
            rows[y + 1] = makeRow(w, function(x)
                local n = noise(x, y + 3)
                if depth == 2 and n > 0.72 then return C.grassLight end
                if depth > 2 and n > 0.86 then return C.grassDark end
                return C.grass
            end)
        elseif y > h - 6 then
            rows[y + 1] = makeRow(w, function(x)
                return (noise(x, y + 11) > 0.7) and C.dirtDark or C.stone
            end)
        else
            rows[y + 1] = makeRow(w, function(x)
                local n = noise(x, y + 7)
                if n > 0.88 then return C.dirtDark end
                if n < 0.05 then return C.stone end
                return C.dirt
            end)
        end
    end

    -- trees
    local function tree(cx, baseY)
        putRect(rows, cx - 4, baseY - 15, 9, 6, C.grass)
        putRect(rows, cx - 3, baseY - 16, 7, 1, C.grassLight)
        putRect(rows, cx - 5, baseY - 13, 1, 4, C.grass)
        putRect(rows, cx + 5, baseY - 13, 1, 4, C.grass)
        putRect(rows, cx - 2, baseY - 9, 5, 3, C.grassDark)
        putRect(rows, cx - 1, baseY - 10, 3, 10, C.dirtDark)
        putRect(rows, cx - 1, baseY - 10, 1, 10, C.dirt)
    end
    tree(math.floor(w * 0.16), horizon + 1)
    tree(math.floor(w * 0.55), horizon + 3)
    tree(math.floor(w * 0.90), horizon + 1)

    return rows, horizon
end

local function buildGradient(w, h)
    local rows = {}
    for y = 0, h - 1 do
        local step = math.min(7, math.floor(y / math.max(1, h) * 8))
        rows[y + 1] = rep(char(C.sky8 - step), w)
    end
    return rows, h
end

local function buildSolid(w, h, colour)
    local rows = {}
    local band = rep(char(colour), w)
    for y = 0, h - 1 do rows[y + 1] = band end
    return rows, h
end

--- Build a wallpaper. Returns an array of `w`-character row strings.
function backdrop.build(w, h, settings)
    local kind = settings.wallpaper or "landscape"
    if kind == "gradient" then
        return buildGradient(w, h)
    elseif kind == "solid" then
        return buildSolid(w, h, settings.wallpaperColour or C.wpBlue)
    end
    return buildLandscape(w, h)
end

return backdrop
