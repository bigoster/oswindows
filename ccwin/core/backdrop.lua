--- CC-Windows - wallpaper generation.
--
-- Wallpapers are built once as an array of row strings; the desktop then just
-- copies those rows into the framebuffer, which keeps redraws cheap.
local backdrop = {}

local gfx, theme, C

function backdrop.attach(g, t)
    gfx, theme, C = g, t, t.C
end

local char, rep, concat, byte = string.char, string.rep, table.concat, string.byte

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

---------------------------------------------------------------------------
-- picture wallpapers (any .nfp / .cwp file on disk)
---------------------------------------------------------------------------

local MAX_BYTES = 1048576 -- refuse to slurp in anything bigger
local MAX_DIM = 4096       -- and anything claiming to be absurdly large

--- Load an NFP (one CC colour digit per pixel) or CWP (`CCWIN1 w h` header
--- plus two hex digits per pixel) picture. Returns `rows, w, h` - rows of
--- palette-index bytes - or nil when the file is missing, empty or malformed,
--- in which case the caller falls back to another wallpaper instead of
--- showing an error.
local function loadPicture(path)
    if type(path) ~= "string" or path == "" then return nil end
    local okSize, size = pcall(fs.getSize, path)
    if not okSize or type(size) ~= "number" or size > MAX_BYTES then return nil end
    local f = fs.open(path, "r")
    if not f or not f.readLine then return nil end

    local ok, rows, w, h = pcall(function()
        local first = f.readLine()
        if not first then return nil end
        local out = {}
        if first:match("^CCWIN1") then
            local iw, ih = first:match("^CCWIN1%s+(%d+)%s+(%d+)")
            iw, ih = tonumber(iw), tonumber(ih)
            if not iw or not ih or iw < 1 or ih < 1 or iw > MAX_DIM or ih > MAX_DIM then
                return nil
            end
            for _ = 1, ih do
                local line = f.readLine()
                if not line then break end
                local buf = {}
                for i = 1, iw do
                    buf[i] = char(tonumber(line:sub(i * 2 - 1, i * 2), 16) or 15)
                end
                out[#out + 1] = concat(buf)
            end
            if #out == 0 then return nil end
            return out, iw, #out
        end
        -- NFP: one character per pixel, CC colour digits.
        out[1] = first
        while #out < MAX_DIM do
            local line = f.readLine()
            if not line then break end
            out[#out + 1] = line
        end
        local widest = 0
        for y = 1, #out do
            local row = out[y]
            if #row > MAX_DIM then row = row:sub(1, MAX_DIM) end
            local buf = {}
            for x = 1, #row do
                buf[x] = char(tonumber(row:sub(x, x), 16) or 15)
            end
            out[y] = concat(buf)
            if #out[y] > widest then widest = #out[y] end
        end
        if widest == 0 then return nil end
        return out, widest, #out
    end)
    pcall(f.close)
    if not ok or not rows then return nil end
    return rows, w, h
end

--- Nearest-neighbour stretch of a loaded picture to fill the whole screen.
local function buildPicture(w, h, rows, iw, ih)
    local out = {}
    for y = 0, h - 1 do
        local src = rows[math.min(ih - 1, math.floor(y * ih / h)) + 1] or rows[1]
        local len = #src
        out[y + 1] = makeRow(w, function(x)
            local sx = math.floor(x * iw / w) + 1
            if sx > len then sx = len end
            return byte(src, sx) or 0
        end)
    end
    return out, h
end

---------------------------------------------------------------------------
-- built-in wallpapers
---------------------------------------------------------------------------

-- The two wallpapers CC-Windows ships with live as real image files in
-- the wallpaper folder: the Settings app's Image button offers them
-- beside your own pictures, and a fresh install shows the landscape. The
-- procedural renderers above only remain as the fallback for a machine
-- that lost them.
local IMAGES = "/ccwin/images"
local BUILT_IN = {
    landscape = IMAGES .. "/landscape.cwp",
    gradient = IMAGES .. "/gradient.cwp",
}

backdrop.IMAGES = IMAGES
backdrop.DEFAULT_IMAGE = BUILT_IN.landscape

--- The stored image at `path`, stretched over the screen, or nil when the
--- file is missing or malformed.
local function stored(path, w, h)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, rows, iw, ih = pcall(loadPicture, path)
    if not ok or not rows or not iw or not ih or iw < 1 or ih < 1 then
        return nil
    end
    return buildPicture(w, h, rows, iw, ih)
end

--- Build a wallpaper. Returns an array of `w`-character row strings.
function backdrop.build(w, h, settings)
    local kind = settings.wallpaper or "landscape"
    if kind == "solid" then
        return buildSolid(w, h, settings.wallpaperColour or C.wpBlue)
    end

    if kind == "picture" then
        local path = settings.wallpaperPath
        if type(path) ~= "string" or path == "" then path = BUILT_IN.landscape end
        local rows = stored(path, w, h)
        -- a custom picture that went missing falls back to the shipped one
        if not rows and path ~= BUILT_IN.landscape then
            rows = stored(BUILT_IN.landscape, w, h)
        end
        if rows then return rows end
        -- broken or missing everywhere: never leave the desktop bare
        return buildLandscape(w, h)
    end

    -- The default and the two older setting names resolve to the stored
    -- images, with the procedural art of the same kind as the last resort.
    local rows = stored(BUILT_IN[kind] or BUILT_IN.landscape, w, h)
    if rows then return rows end
    if kind == "gradient" then return buildGradient(w, h) end
    return buildLandscape(w, h)
end

return backdrop
