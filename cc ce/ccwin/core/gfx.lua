--- CC-Windows - pixel framebuffer core.
--
-- The screen is drawn into an off-screen buffer of row strings (one byte per
-- pixel, holding a palette index) and pushed to the terminal with
-- term.drawPixels(), only sending the rows that actually changed.
--
-- All coordinates are zero-based pixels, exactly like term.setPixel().
local gfx = {}

local font
local native
local W, H = 0, 0
local back, front = {}, {}
local cx0, cy0, cx1, cy1 = 0, 0, 0, 0
local clipStack = {}
local extras = {}

local floor = math.floor
local abs, max, min = math.abs, math.max, math.min
local rep, sub, byte, char = string.rep, string.sub, string.byte, string.char
local concat = table.concat

-- Fallback bitmap for code points we have no glyph for (a 6x9 open box).
local BOX = char(63, 33, 33, 33, 33, 33, 33, 33, 63)

local function decodeUTF8(s, i, b)
    if b < 0x80 then return b, 1 end
    local len = #s
    if b >= 0xC0 and b < 0xE0 and i + 1 <= len then
        local b2 = byte(s, i + 1)
        if b2 >= 0x80 and b2 < 0xC0 then
            return (b - 0xC0) * 0x40 + (b2 - 0x80), 2
        end
    elseif b >= 0xE0 and b < 0xF0 and i + 2 <= len then
        local b2, b3 = byte(s, i + 1), byte(s, i + 2)
        if b2 >= 0x80 and b2 < 0xC0 and b3 >= 0x80 and b3 < 0xC0 then
            return (b - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), 3
        end
    elseif b >= 0xF0 and i + 3 <= len then
        local b2, b3, b4 = byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
        if b2 >= 0x80 and b2 < 0xC0 and b3 >= 0x80 and b3 < 0xC0 and b4 >= 0x80 and b4 < 0xC0 then
            return (b - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80), 4
        end
    end
    return b, 1
end

local function glyphFor(cp)
    return extras[cp] or font.glyphs[cp] or BOX
end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------

function gfx.attach(f) font = f end

--- Enter 256-colour graphics mode and allocate the buffers.
function gfx.init()
    native = term.native()
    native.setGraphicsMode(2)
    W, H = native.getSize(2)
    back, front = {}, {}
    local blank = rep(char(0), W)
    for y = 1, H do
        back[y] = blank
        front[y] = ""
    end
    cx0, cy0, cx1, cy1 = 0, 0, W, H
    clipStack = {}
end

--- Reallocate after a terminal resize. Returns true when the size changed.
function gfx.resize()
    local nw, nh = native.getSize(2)
    if nw == W and nh == H then return false end
    W, H = nw, nh
    back, front = {}, {}
    local blank = rep(char(0), W)
    for y = 1, H do
        back[y] = blank
        front[y] = ""
    end
    cx0, cy0, cx1, cy1 = 0, 0, W, H
    clipStack = {}
    return true
end

function gfx.size() return W, H end
function gfx.term() return native end

--- Leave graphics mode (used when shutting down).
function gfx.shutdown()
    if not native then return end
    pcall(native.setGraphicsMode, 0)
end

---------------------------------------------------------------------------
-- clipping
---------------------------------------------------------------------------

function gfx.setClip(x, y, w, h)
    cx0, cy0 = max(0, x), max(0, y)
    cx1, cy1 = min(W, x + w), min(H, y + h)
    if cx1 < cx0 then cx1 = cx0 end
    if cy1 < cy0 then cy1 = cy0 end
end

function gfx.pushClip(x, y, w, h)
    clipStack[#clipStack + 1] = { cx0, cy0, cx1, cy1 }
    gfx.setClip(x, y, w, h)
end

function gfx.popClip()
    local prev = clipStack[#clipStack]
    if not prev then return end
    clipStack[#clipStack] = nil
    cx0, cy0, cx1, cy1 = prev[1], prev[2], prev[3], prev[4]
end

function gfx.resetClip()
    clipStack = {}
    cx0, cy0, cx1, cy1 = 0, 0, W, H
end

local function clipRect(x, y, w, h)
    local x0, y0 = max(x, cx0), max(y, cy0)
    local x1, y1 = min(x + w, cx1), min(y + h, cy1)
    if x1 < x0 then x1 = x0 end
    if y1 < y0 then y1 = y0 end
    return x0, y0, x1, y1
end

---------------------------------------------------------------------------
-- primitives
---------------------------------------------------------------------------

function gfx.fill(x, y, w, h, c)
    local x0, y0, x1, y1 = clipRect(x, y, w, h)
    if x1 <= x0 or y1 <= y0 then return end
    local row = rep(char(c), x1 - x0)
    for yy = y0, y1 - 1 do
        local s = back[yy + 1]
        back[yy + 1] = sub(s, 1, x0) .. row .. sub(s, x1 + 1)
    end
end

function gfx.pixel(x, y, c)
    if x < cx0 or x >= cx1 or y < cy0 or y >= cy1 then return end
    local s = back[y + 1]
    back[y + 1] = sub(s, 1, x) .. char(c) .. sub(s, x + 2)
end

function gfx.getPixel(x, y)
    if x < 0 or x >= W or y < 0 or y >= H then return nil end
    return byte(back[y + 1], x + 1)
end

function gfx.rect(x, y, w, h, c)
    if w <= 0 or h <= 0 then return end
    gfx.fill(x, y, w, 1, c)
    gfx.fill(x, y + h - 1, w, 1, c)
    if h > 2 then
        gfx.fill(x, y + 1, 1, h - 2, c)
        gfx.fill(x + w - 1, y + 1, 1, h - 2, c)
    end
end

function gfx.hline(x, y, w, c) gfx.fill(x, y, w, 1, c) end
function gfx.vline(x, y, h, c) gfx.fill(x, y, 1, h, c) end

function gfx.line(x0, y0, x1, y1, c)
    local dx, dy = abs(x1 - x0), abs(y1 - y0)
    local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
    local err = dx - dy
    while true do
        gfx.pixel(x0, y0, c)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x0 = x0 + sx end
        if e2 < dx then err = err + dx; y0 = y0 + sy end
    end
end

--- Splice a raw row of palette bytes onto the buffer (clipped).
function gfx.blit(x, y, str)
    if y < cy0 or y >= cy1 then return end
    local len = #str
    local x0, x1 = max(x, cx0), min(x + len, cx1)
    if x1 <= x0 then return end
    local s = back[y + 1]
    back[y + 1] = sub(s, 1, x0) .. str:sub(x0 - x + 1, x1 - x) .. sub(s, x1 + 1)
end

--- Replace a whole buffer row (used for the desktop wallpaper).
function gfx.setRow(y, str)
    if y >= 1 and y <= H and #str == W then back[y] = str end
end

function gfx.row(y) return back[y] end

function gfx.clear(c)
    gfx.fill(0, 0, W, H, c or 0)
end

---------------------------------------------------------------------------
-- text
---------------------------------------------------------------------------

--- Width in pixels of a string (decodes UTF-8, so multibyte text measures right).
function gfx.textWidth(str, scale)
    scale = scale or 1
    str = tostring(str or "")
    local n, i, len = 0, 1, #str
    while i <= len do
        local _, clen = decodeUTF8(str, i, byte(str, i))
        n = n + 1
        i = i + clen
    end
    return n * font.width * scale
end

--- Draw text with the embedded bitmap font. `bg` may be nil for transparent text.
function gfx.text(x, y, str, fg, bg, scale)
    scale = scale or 1
    str = tostring(str or "")
    local gw, gh = font.width, font.height
    local adv = gw * scale
    local th = gh * scale

    local codes, nCodes = {}, 0
    local i, len = 1, #str
    while i <= len do
        local b = byte(str, i)
        local cp, clen = decodeUTF8(str, i, b)
        nCodes = nCodes + 1
        codes[nCodes] = cp
        i = i + clen
    end
    local total = nCodes * adv
    if nCodes == 0 then return 0 end

    local rx0, ry0 = max(x, cx0), max(y, cy0)
    local rx1, ry1 = min(x + total, cx1), min(y + th, cy1)
    if rx1 <= rx0 or ry1 <= ry0 then return total end

    local fgCh = char(fg)

    if bg then
        -- Build each scan line of the whole run, then splice it once.
        local bgCh = char(bg)
        for r = 0, gh - 1 do
            local ytop = y + r * scale
            if ytop + scale > ry0 and ytop < ry1 then
                local parts = {}
                for k = 1, nCodes do
                    local g = glyphFor(codes[k])
                    local bits = g and byte(g, r + 1) or 0
                    local seg = {}
                    for sx = 0, gw - 1 do
                        local on = floor(bits / 2 ^ sx) % 2 == 1
                        local ch = on and fgCh or bgCh
                        seg[#seg + 1] = scale == 1 and ch or rep(ch, scale)
                    end
                    parts[#parts + 1] = concat(seg)
                end
                local line = concat(parts)
                for sy = 0, scale - 1 do
                    local yy = ytop + sy
                    if yy >= ry0 and yy < ry1 then
                        local s = back[yy + 1]
                        back[yy + 1] = sub(s, 1, rx0) .. line:sub(rx0 - x + 1, rx1 - x) .. sub(s, rx1 + 1)
                    end
                end
            end
        end
    else
        local cx = x
        for k = 1, nCodes do
            local g = glyphFor(codes[k])
            if g and cx + adv > rx0 and cx < rx1 then
                for r = 0, gh - 1 do
                    local bits = byte(g, r + 1)
                    if bits ~= 0 then
                        local ytop = y + r * scale
                        local sx = 0
                        while sx < gw do
                            if floor(bits / 2 ^ sx) % 2 == 1 then
                                local run = 1
                                while sx + run < gw and floor(bits / 2 ^ (sx + run)) % 2 == 1 do
                                    run = run + 1
                                end
                                gfx.fill(cx + sx * scale, ytop, run * scale, scale, fg)
                                sx = sx + run
                            else
                                sx = sx + 1
                            end
                        end
                    end
                end
            end
            cx = cx + adv
        end
    end
    return total
end

--- Register a glyph bitmap for a Unicode code point (9 bytes, same format as font.lua).
function gfx.registerGlyph(cp, bitmap) extras[cp] = bitmap end

---------------------------------------------------------------------------
-- presenting
---------------------------------------------------------------------------

--- Push every changed row to the terminal (batched into contiguous runs).
function gfx.present()
    if H == 0 or not native then return end
    native.setFrozen(true)
    local ok, err = pcall(function()
        local y = 1
        while y <= H do
            if back[y] ~= front[y] then
                local startY, rows = y, {}
                while y <= H and back[y] ~= front[y] do
                    rows[#rows + 1] = back[y]
                    front[y] = back[y]
                    y = y + 1
                end
                native.drawPixels(0, startY - 1, rows)
            else
                y = y + 1
            end
        end
    end)
    native.setFrozen(false)
    if not ok then error(err, 0) end
end

---------------------------------------------------------------------------
-- draw context
---------------------------------------------------------------------------

--- A draw context translates window-relative coordinates into screen pixels.
function gfx.newDC(ox, oy, w, h)
    local dc = { ox = ox, oy = oy, w = w, h = h }

    function dc:fill(x, y, cw, ch, c) gfx.fill(self.ox + x, self.oy + y, cw, ch, c) end
    function dc:rect(x, y, cw, ch, c) gfx.rect(self.ox + x, self.oy + y, cw, ch, c) end
    function dc:pixel(x, y, c) gfx.pixel(self.ox + x, self.oy + y, c) end
    function dc:getPixel(x, y) return gfx.getPixel(self.ox + x, self.oy + y) end
    function dc:line(x0, y0, x1, y1, c) gfx.line(self.ox + x0, self.oy + y0, self.ox + x1, self.oy + y1, c) end
    function dc:blit(x, y, str) gfx.blit(self.ox + x, self.oy + y, str) end
    function dc:text(x, y, str, fg, bg, scale)
        return gfx.text(self.ox + x, self.oy + y, str, fg, bg, scale)
    end
    function dc:textWidth(str, scale) return gfx.textWidth(str, scale) end
    function dc:pushClip(x, y, cw, ch) gfx.pushClip(self.ox + x, self.oy + y, cw, ch) end
    function dc:popClip() gfx.popClip() end
    return dc
end

--- True when (x, y) lies inside a rectangle.
function gfx.inside(x, y, rx, ry, rw, rh)
    return x >= rx and x < rx + rw and y >= ry and y < ry + rh
end

return gfx
