--- CC-Windows - colour palette and visual style.
--
-- Everything is drawn with palette indices: mode 2 of CC-Graphics gives us
-- 256 slots. Indices 0-15 stay ComputerCraft's own colours (so programs and
-- paintutils keep working), 16-143 are ours. Re-installing the palette with
-- different values is how the Light/Dark theme switch works - the drawing code
-- only ever refers to a colour by name.
local theme = {}

local C = {
    -- chrome
    black = 16, white = 17,
    face = 18, faceHover = 19, faceDown = 20,
    bevelLight = 21, bevelMid = 22, bevelDark = 23, bevelShadow = 24,
    taskbar = 25, taskbarHover = 26,
    text = 27, textMuted = 28,
    accent = 29, accentDark = 30, accentLight = 31, accentFaint = 32,
    titleInactive = 33,
    danger = 34, success = 35, warning = 36, shadow = 37,
    fieldBg = 83, hover = 93, listAlt = 94, dangerDark = 95,

    -- wallpaper: solid choices
    wpBlue = 38, wpTeal = 39, wpPurple = 40, wpNavy = 41,
    wpGray = 42, wpRed = 43, wpGreen = 44,

    -- wallpaper: landscape
    sky1 = 45, sky2 = 46, sky3 = 47, sky4 = 48,
    sky5 = 49, sky6 = 50, sky7 = 51, sky8 = 52,
    grassLight = 53, grass = 54, grassDark = 55,
    dirt = 56, dirtDark = 57, stone = 58, water = 59,
    sun = 60, cloud = 61,

    -- icons
    iconFolder = 62, iconFolderDark = 63, iconPaper = 64, iconLine = 65,
    iconBlack = 66, iconGreen = 67, iconRed = 68, iconBlue = 69,
    iconGear = 70, iconGearHole = 71, iconChip = 72, iconChipDie = 73,
    iconPin = 74, iconYellow = 75, iconOrange = 76, iconPurple = 77,
    iconCyan = 78, iconGray = 79, iconGrayDark = 80, iconPink = 81,
    iconWhite = 82,

    -- scrollbars
    track = 90, thumb = 91, thumbHover = 92,

    -- generated paint palette
    paintFirst = 96, paintCount = 48,
}
theme.C = C

-- Colours that do not change between themes.
local PAL_COMMON = {
    [16] = 0x000000, [17] = 0xFFFFFF,
    [25] = 0x1F1F1F, [26] = 0x3A3A3A,
    [29] = 0x0078D4, [30] = 0x005A9E, [31] = 0x3AA0F0,
    [34] = 0xE81123, [36] = 0xFFB900, [37] = 0x000000,

    [38] = 0x3A6EA5, [39] = 0x17756E, [40] = 0x4B3F72, [41] = 0x12233A,
    [42] = 0x40484F, [43] = 0x7A2E2E, [44] = 0x2E5C3A,

    [45] = 0x14498A, [46] = 0x1E5FA8, [47] = 0x2A76C4, [48] = 0x3E8DDC,
    [49] = 0x57A3EC, [50] = 0x74B9F3, [51] = 0x96CDF8, [52] = 0xB8E0FC,

    [53] = 0x7BC66B, [54] = 0x57A63A, [55] = 0x3E7D2B,
    [56] = 0x8A6244, [57] = 0x6B4A31, [58] = 0x7E7E7E,
    [59] = 0x3E6FD0, [60] = 0xFFF6C0, [61] = 0xF2F7FB,

    [62] = 0xF5C542, [63] = 0xD89A1E, [64] = 0xFFFFFF, [65] = 0x3B7BE0,
    [66] = 0x141414, [67] = 0x2ECC40, [68] = 0xE0455A, [69] = 0x2F80ED,
    [70] = 0xC9C9C9, [71] = 0x5A5A5A, [72] = 0x2E7D32, [73] = 0x9BE8A0,
    [74] = 0xC9C9C9, [75] = 0xFFD34D, [76] = 0xF2803C, [77] = 0x9B59D0,
    [78] = 0x41D6E0, [79] = 0x9A9A9A, [80] = 0x606060, [81] = 0xE86FA8,
    [82] = 0xFFFFFF,
}

local PAL_LIGHT = {
    [18] = 0xF0F0F0, [19] = 0xE4E4E4, [20] = 0xD4D4D4,
    [21] = 0xFFFFFF, [22] = 0xC8C8C8, [23] = 0x9B9B9B, [24] = 0x6E6E6E,
    [27] = 0x1A1A1A, [28] = 0x6B6B6B,
    [32] = 0xD6EAFB, [33] = 0x6E6E6E, [35] = 0x107C10,
    [83] = 0xFFFFFF, [90] = 0xECECEC, [91] = 0xC4C4C4, [92] = 0x9E9E9E,
    [93] = 0xDFEAF7, [94] = 0xE9E9E9, [95] = 0xB03024,
}

local PAL_DARK = {
    [18] = 0x262626, [19] = 0x333333, [20] = 0x1C1C1C,
    [21] = 0x4A4A4A, [22] = 0x3A3A3A, [23] = 0x151515, [24] = 0x0D0D0D,
    [27] = 0xE8E8E8, [28] = 0xA0A0A0,
    [32] = 0x0E3A5C, [33] = 0x3D3D3D, [35] = 0x2E9E2E,
    [83] = 0x141414, [90] = 0x2E2E2E, [91] = 0x5A5A5A, [92] = 0x767676,
    [93] = 0x2C3E50, [94] = 0x2C2C2C, [95] = 0xE74C3C,
}

theme.mode = "light"

local function hsv(h, s, v)
    local i = math.floor(h / 60) % 6
    local f = h / 60 - math.floor(h / 60)
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    local r, g, b
    if i == 0 then r, g, b = v, t, p
    elseif i == 1 then r, g, b = q, v, p
    elseif i == 2 then r, g, b = p, v, t
    elseif i == 3 then r, g, b = p, q, v
    elseif i == 4 then r, g, b = t, p, v
    else r, g, b = v, p, q end
    return r, g, b
end

--- Install the whole palette for the given theme ("light" or "dark").
function theme.install(mode)
    mode = (mode == "dark") and "dark" or "light"
    theme.mode = mode
    local custom = (mode == "dark") and PAL_DARK or PAL_LIGHT
    -- Always talk to the native terminal: a console window may own the
    -- global `term` redirect, and its palette entry points are CC colour
    -- bits rather than raw mode-2 indices.
    local t = (term.native and term.native()) or term
    for index, hex in pairs(PAL_COMMON) do
        t.setPaletteColor(index, hex)
    end
    for index, hex in pairs(custom) do
        t.setPaletteColor(index, hex)
    end
    -- Paint palette: 12 hues x 3 shades plus 12 greys.
    local i = C.paintFirst
    for step = 0, 11 do
        local v = 0.62
        for _, s in ipairs { 0.95, 0.62, 0.34 } do
            local r, g, b = hsv(step * 30, s, v)
            t.setPaletteColor(i, r, g, b)
            i = i + 1
            v = v + 0.16
        end
    end
    for step = 0, 11 do
        local v = 1 - step / 11
        t.setPaletteColor(i, v, v, v)
        i = i + 1
    end
end

--- The 48 palette indices of the paint tool's colour box.
function theme.paintColours()
    local list = {}
    for i = C.paintFirst, C.paintFirst + C.paintCount - 1 do
        list[#list + 1] = i
    end
    return list
end

---------------------------------------------------------------------------
-- style helpers (all take a draw context)
---------------------------------------------------------------------------

function theme.raise(dc, x, y, w, h)
    dc:fill(x, y, w, 1, C.bevelLight)
    dc:fill(x, y, 1, h, C.bevelLight)
    dc:fill(x, y + h - 1, w, 1, C.bevelDark)
    dc:fill(x + w - 1, y, 1, h, C.bevelDark)
end

function theme.sunken(dc, x, y, w, h)
    dc:fill(x, y, w, 1, C.bevelDark)
    dc:fill(x, y, 1, h, C.bevelDark)
    dc:fill(x, y + h - 1, w, 1, C.bevelLight)
    dc:fill(x + w - 1, y, 1, h, C.bevelLight)
end

--- Flat, Windows-10 style push button.
function theme.button(dc, x, y, w, h, state)
    local face = C.face
    if state == "hover" or state == "hot" then face = C.faceHover end
    if state == "down" then face = C.faceDown end
    if state == "disabled" then face = C.faceDown end
    dc:fill(x, y, w, h, face)
    local border = C.bevelDark
    if state == "hover" then border = C.accent end
    if state == "down" then border = C.accentDark end
    dc:rect(x, y, w, h, border)
    if state == "down" then dc:pixel(x + 1, y + 1, C.bevelShadow) end
end

--- Text inside a button (or any centred label).
function theme.buttonLabel(dc, x, y, w, h, label, colour, scale)
    scale = scale or 1
    local tw = dc:textWidth(label, scale)
    local tx = x + math.floor((w - tw) / 2)
    local ty = y + math.floor((h - 9 * scale) / 2)
    dc:text(tx, ty, label, colour or C.text, nil, scale)
end

function theme.field(dc, x, y, w, h, focused)
    dc:fill(x, y, w, h, C.fieldBg)
    dc:rect(x, y, w, h, focused and C.accent or C.bevelDark)
end

function theme.panel(dc, x, y, w, h)
    dc:fill(x, y, w, h, C.face)
    dc:rect(x, y, w, h, C.bevelMid)
end

function theme.band(dc, x, y, w, h, text)
    dc:fill(x, y, w, h, C.face)
    dc:fill(x, y + h - 1, w, 1, C.bevelMid)
    if text then dc:text(x + 4, y + math.floor((h - 9) / 2), text, C.textMuted) end
end

--- Vertical scrollbar. fracStart/fracLen are 0..1 fractions of the track.
function theme.scrollbarV(dc, x, y, w, h, fracStart, fracLen, hot)
    dc:fill(x, y, w, h, C.track)
    local th = math.max(12, math.floor(h * fracLen))
    if th > h then th = h end
    local ty = y + math.floor((h - th) * math.min(1, math.max(0, fracStart)))
    dc:fill(x, ty, w, th, hot and C.thumbHover or C.thumb)
    dc:fill(x, ty, w, 1, C.bevelLight)
    dc:fill(x, ty + th - 1, w, 1, C.bevelDark)
end

function theme.scrollbarH(dc, x, y, w, h, fracStart, fracLen, hot)
    dc:fill(x, y, w, h, C.track)
    local tw = math.max(12, math.floor(w * fracLen))
    if tw > w then tw = w end
    local tx = x + math.floor((w - tw) * math.min(1, math.max(0, fracStart)))
    dc:fill(tx, y, tw, h, hot and C.thumbHover or C.thumb)
    dc:fill(tx, y, 1, h, C.bevelLight)
    dc:fill(tx + tw - 1, y, 1, h, C.bevelDark)
end

return theme
