--- CC-Windows - boot splash.
--
-- The desktop takes a noticeable moment to load on a real computer,
-- especially with a photo wallpaper: hundreds of kilobytes of Lua, then a
-- palette install, then the picture decode. Without a splash the screen
-- looks blank, as if the OS had crashed. This module paints a small,
-- self-contained progress panel immediately and steps it forward while
-- the rest of the boot runs.
--
-- It deliberately uses only core/gfx.lua: widgets, dialogs and the
-- desktop are not loaded yet when it first draws, and a splash must never
-- be able to take the boot down with it.
local loading = {}

local gfx, theme, C
local active = false
local frames, progress = 0, 0

local function colours()
    if C then
        return C.face or 18, C.text or 27, C.accent or 29, C.bevelMid or 22
    end
    -- Fallback to the stock CC palette indices when the theme module
    -- failed: light grey panel, near-black text, blue accent.
    return 18, 27, 29, 22
end

local function draw(label, fraction)
    local W, H = gfx.size()
    local bg, fg, accent, track = colours()

    gfx.resetClip()
    gfx.clear(bg)

    local title = "CC-Windows"
    local titleScale = W >= 120 and 2 or 1
    local tw = gfx.textWidth(title, titleScale)
    gfx.text(math.floor((W - tw) / 2), math.floor(H / 2) - 34,
        title, fg, nil, titleScale)

    local sub = tostring(label or "Starting")
    if #sub > 34 then sub = sub:sub(1, 31) .. "..." end
    local sw = gfx.textWidth(sub)
    gfx.text(math.floor((W - sw) / 2), math.floor(H / 2) - 8, sub, fg)

    local bw = math.min(180, math.max(40, W - 40))
    local bx = math.floor((W - bw) / 2)
    local by = math.floor(H / 2) + 10
    gfx.fill(bx, by, bw, 7, track)
    gfx.rect(bx, by, bw, 7, accent)
    fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
    local fillW = math.floor((bw - 2) * fraction)
    if fillW > 0 then gfx.fill(bx + 1, by + 1, fillW, 5, accent) end

    gfx.present()
end

--- Show the splash. Safe to call without a theme: stock CC colours are
--- used instead.
function loading.begin(g, t)
    gfx, theme = g, t
    C = t and t.C or nil
    active = gfx ~= nil and type(gfx.present) == "function"
    if active then loading.step("Starting CC-Windows", 0) end
end

--- Advance the splash. Every call is guarded: a broken palette or a
--- terminal without mode 2 must not turn a cosmetic screen into a boot
--- failure.
function loading.step(label, fraction)
    if not active or not gfx then return end
    local ok = pcall(draw, label, fraction)
    if ok then
        frames = frames + 1
        progress = math.max(0, math.min(1, tonumber(fraction) or 0))
    else
        active = false
    end
end

--- The desktop is on screen; stop drawing the splash.
function loading.finish()
    active = false
end

function loading.active()
    return active
end

-- Read-only test hooks: the headless harness checks that boot really
-- pushed splash frames and that the bar reached the desktop.
function loading.frames() return frames end
function loading.progress() return progress end

return loading
