--- CC-Windows - wallpaper generation.
--
-- Wallpapers are built once as an array of row strings; the desktop then just
-- copies those rows into the framebuffer, which keeps redraws cheap.
local backdrop = {}

local gfx, theme, C, image, picture

-- Wallpapers are pure functions of (mode, path, colour, size), so one
-- decoded copy is kept per combination.  A theme or accent change no
-- longer re-decodes a photograph, and switching back is instant.
local cache, cacheOrder = {}, {}
local CACHE_MAX = 6

--- `img` is the optional image module (ccwin/core/image.lua); `pic` is the
--- picture codec (ccwin/core/picture.lua), which handles NFP / CWP1 / CWP2.
--- The image module stays optional: without it text art still loads.
function backdrop.attach(g, t, img, pic)
    gfx, theme, C, image, picture = g, t, t.C, img, pic
    cache, cacheOrder = {}, {}
end

local char, rep, concat, byte = string.char, string.rep, table.concat, string.byte
local sub = string.sub

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
-- picture wallpapers (.nfp / .cwp text files, PNG / JPEG / WebP images)
---------------------------------------------------------------------------

local MAX_BYTES = 1048576 -- refuse to slurp in anything bigger

--- Publish a decoded photo's palette (slots PHOTO_FIRST..) so its index
--- rows paint with their own colours.  Best effort only: outside
--- graphics mode 2 there is no palette to write to, and a picture must
--- never be able to take the desktop down.
local function installPhoto(pal)
    if type(pal) ~= "table" or type(pal.r) ~= "table" then return end
    pcall(function()
        local t = term
        if t and t.native then t = t.native() end
        if not t or type(t.setPaletteColor) ~= "function" then return end
        for i = 1, #pal.r do
            t.setPaletteColor(pal.first + i - 1,
                pal.r[i] / 255, pal.g[i] / 255, pal.b[i] / 255)
        end
    end)
end
backdrop.installPhoto = installPhoto

--- Load a picture. Returns `rows, w, h` - rows of palette-index bytes -
--- or nil when the file is missing, empty or malformed, in which case
--- the caller falls back to another wallpaper instead of showing an
--- error.  A PNG / JPEG / WebP is decoded and quantized straight to the
--- screen (`tw` x `th`); NFP, CWP1 and CWP2 come through core/picture.lua
--- with their own size and are stretched by the caller.
local function loadPicture(path, tw, th)
    if type(path) ~= "string" or path == "" then return nil end
    if not picture then return nil end
    local data = picture.readFile(path, MAX_BYTES)
    if not data then return nil end

    -- Only the binary formats need the 162 KB image decoder.  A `.cwp`
    -- wallpaper never loads it at all.
    if picture.isRaster(data) then
        if not image then return nil end
        local okDec, rows, pal = pcall(image.decode, data, tw, th)
        if not okDec or type(rows) ~= "table" then return nil end
        installPhoto(pal)
        return rows, tw, th
    end

    local ok, rows, w, h = pcall(picture.decode, data)
    if not ok or type(rows) ~= "table" then return nil end
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
    local ok, rows, iw, ih = pcall(loadPicture, path, w, h)
    if not ok or not rows or not iw or not ih or iw < 1 or ih < 1 then
        return nil
    end
    return buildPicture(w, h, rows, iw, ih)
end

--- Build a wallpaper. Returns an array of `w`-character row strings.
local function buildUncached(w, h, settings)
    local kind = settings.wallpaper or "landscape"
    if kind == "solid" then
        -- a "#RRGGBB" colour from Settings renders from its own palette
        -- slot; a plain number is a legacy palette index and still works
        local col = settings.wallpaperColour
        if type(col) == "string" then
            col = theme.fromHex(col) and C.wpCustom or nil
        end
        return buildSolid(w, h, col or C.wpBlue)
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

local function remember(key, rows)
    if not rows then return rows end
    if cache[key] then return cache[key] end
    if #cacheOrder >= CACHE_MAX then
        local oldest = table.remove(cacheOrder, 1)
        cache[oldest] = nil
    end
    cacheOrder[#cacheOrder + 1] = key
    cache[key] = rows
    return rows
end

--- Build a wallpaper. Returns an array of `w`-character row strings.
-- The result is cached by mode, path, colour, file size and screen size,
-- so applying a theme or accent never decodes the same picture again.
function backdrop.build(w, h, settings)
    settings = settings or {}
    local kind = tostring(settings.wallpaper or "landscape")
    local path = tostring(settings.wallpaperPath or "")
    local size = 0
    if kind == "picture" and path ~= "" then
        local ok, n = pcall(fs.getSize, path)
        if ok and type(n) == "number" then size = n end
    end
    local key = kind .. "|" .. path .. "|" .. tostring(settings.wallpaperColour)
        .. "|" .. size .. "|" .. w .. "x" .. h
    local hit = cache[key]
    if hit then return hit end
    return remember(key, buildUncached(w, h, settings))
end

return backdrop
