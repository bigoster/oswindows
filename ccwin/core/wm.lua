--- CC-Windows - window manager.
--
-- Owns the window list, z-order, focus, dragging/resizing, the title bar
-- chrome, and routes input events to whichever application is interested.
local wm = {}

local gfx, theme, widgets, dialogs, icons, menu, C
local apps, state, desktop, fabric, programs
local storage, picture, image
local rootDC

local rep, sub, char = string.rep, string.sub, string.char
local min, max, floor = math.min, math.max, math.floor

local windows = {}
local focused = nil
local drag = nil
local pressed = nil
local nextId = 1
local cascade = 0

-- Rectangles that need recompositing without rebuilding the whole scene.
-- The clock tray is the main user: once a second it changes two dozen
-- pixels, and a full wallpaper + icons + window redraw for that was both
-- wasteful and visible as a stutter.
local damage = {}

--- Ask for a small area to be recomposited on the next frame.
function wm.markRect(x, y, w, h)
    if w == nil or h == nil or w <= 0 or h <= 0 then return end
    damage[#damage + 1] = { math.floor(x or 0), math.floor(y or 0),
        math.floor(w), math.floor(h) }
end

function wm.hasDamage()
    return #damage > 0
end

--- Force every window to repaint on the next frame (theme changes, and
--- anything else that alters colours outside an app's own draw).
function wm.invalidateSurfaces()
    for i = 1, #windows do windows[i].surfaceDirty = true end
end

local TITLE_H = 13
local BORDER = 1
local TASKBAR_H = 17
local MIN_W, MIN_H = 96, 46
local BTN_W = 16

wm.TITLE_H = TITLE_H
wm.BORDER = BORDER
wm.TASKBAR_H = TASKBAR_H
wm.dirty = true

function wm.attach(d)
    gfx, theme, widgets, dialogs, icons = d.gfx, d.theme, d.widgets, d.dialogs, d.icons
    menu = d.menu
    C = theme.C
    apps, state = d.apps, d.state
    fabric = d.fabric
    programs = d.programs
    storage, picture, image = d.storage, d.picture, d.image
    rootDC = gfx.newDC(0, 0, gfx.size())
end

function wm.setDesktop(d) desktop = d end

---------------------------------------------------------------------------
-- geometry
---------------------------------------------------------------------------

function wm.desktopArea()
    local W, H = gfx.size()
    return 0, 0, W, H - TASKBAR_H
end

local function clampSizes(win)
    local _, _, aw, ah = wm.desktopArea()
    if win.w > aw then win.w = aw end
    if win.h > ah then win.h = ah end
    if win.w < MIN_W then win.w = MIN_W end
    if win.h < MIN_H then win.h = MIN_H end
end

local function layout(win)
    local oldW, oldH = win.content and win.content.w, win.content and win.content.h
    win.content = {
        x = win.x + BORDER,
        y = win.y + BORDER + TITLE_H,
        w = win.w - BORDER * 2,
        h = win.h - TITLE_H - BORDER * 2,
    }
    if win.content.w < 1 then win.content.w = 1 end
    if win.content.h < 1 then win.content.h = 1 end
    local dc = win.dc
    dc.ox, dc.oy = win.content.x, win.content.y
    dc.w, dc.h = win.content.w, win.content.h
    local resized = oldW ~= dc.w or oldH ~= dc.h
    if resized then win.surfaceDirty = true end
    if win.instance and win.instance.resize and resized then
        wm.call(win, "resize", dc.w, dc.h)
    end
end

local function titleButtons(win)
    local by = win.y + BORDER + 1
    local bx = win.x + win.w - BORDER - BTN_W
    local h = TITLE_H - 2
    if win.w < 76 then return {} end
    local list = {}
    list.close = { bx, by, BTN_W, h }
    list.max = { bx - BTN_W, by, BTN_W, h }
    list.min = { bx - BTN_W * 2, by, BTN_W, h }
    return list
end

local function hitRect(r, x, y)
    return r and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
end

wm.hitRect = hitRect

function wm.windowAt(x, y)
    for i = #windows, 1, -1 do
        local win = windows[i]
        if win.state ~= "min" and hitRect({ win.x, win.y, win.w, win.h }, x, y) then
            return win
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- window lifecycle
---------------------------------------------------------------------------

function wm.list() return windows end
function wm.focused() return focused end

function wm.focus(win)
    if not win or win.state == "min" then return end
    for i = #windows, 1, -1 do
        if windows[i] == win then
            table.remove(windows, i)
            windows[#windows + 1] = win
            break
        end
    end
    if focused ~= win then
        focused = win
        wm.dirty = true
        if wm.onFocus then wm.onFocus(focused) end
    end
end

local function refocusTop()
    focused = nil
    for i = #windows, 1, -1 do
        if windows[i].state ~= "min" then
            focused = windows[i]
            break
        end
    end
    wm.dirty = true
    if wm.onFocus then wm.onFocus(focused) end
end

--- Create a window for `appId` (a name in the app registry) or for an
-- app table loaded straight from a program file (see core/programs.lua).
function wm.create(appId, opts)
    local app
    if type(appId) == "table" then
        app = appId
        appId = app.id or "program"
    else
        app = apps[appId]
        if not app then error("unknown app: " .. tostring(appId), 2) end
    end

    local _, _, aw, ah = wm.desktopArea()
    local size = app.defaultSize or { math.floor(aw * 0.6), math.floor(ah * 0.6) }
    local win = {
        id = nextId,
        appId = appId,
        app = app,
        title = app.name,
        icon = app.icon or "file",
        state = "normal",
        x = 0, y = 0, w = math.min(size[1], aw), h = math.min(size[2], ah),
        prev = nil,
        content = nil,
        dc = gfx.newDC(0, 0, 1, 1),
        dialog = nil,
        instance = nil,
        crashed = nil,
    }
    nextId = nextId + 1

    -- cascade placement
    local step = 14
    local ox = 18 + (cascade % 6) * step
    local oy = 12 + (cascade % 6) * step
    cascade = cascade + 1
    if ox + win.w > aw then ox = math.max(0, aw - win.w) end
    if oy + win.h > ah then oy = math.max(0, ah - win.h) end
    win.x, win.y = ox, oy
    clampSizes(win)
    layout(win)

    local ok, instance = pcall(app.create, win, opts or {}, wm.context())
    if not ok then
        win.crashed = tostring(instance)
        win.title = app.name .. " (crashed)"
    else
        win.instance = instance
    end

    windows[#windows + 1] = win
    wm.focus(win)
    wm.dirty = true
    return win
end

function wm.close(win)
    if not win then return end
    if win.instance and win.instance.close then
        pcall(win.instance.close, win.instance)
    end
    for i = #windows, 1, -1 do
        if windows[i] == win then table.remove(windows, i) end
    end
    if focused == win then focused = nil end
    refocusTop()
    wm.dirty = true
end

function wm.minimize(win)
    win.state = "min"
    refocusTop()
    wm.dirty = true
end

function wm.restore(win)
    win.state = "normal"
    wm.focus(win)
    wm.dirty = true
end

function wm.maximize(win)
    if win.state == "max" then
        local prev = win.prev
        win.state = "normal"
        if prev then win.x, win.y, win.w, win.h = prev.x, prev.y, prev.w, prev.h end
        clampSizes(win)
    else
        local _, _, aw, ah = wm.desktopArea()
        win.prev = { x = win.x, y = win.y, w = win.w, h = win.h }
        win.x, win.y, win.w, win.h = 0, 0, aw, ah
        win.state = "max"
    end
    layout(win)
    wm.focus(win)
    wm.dirty = true
end

function wm.setTitle(win, title)
    if win.title ~= title then
        win.title = title
        win.surfaceDirty = true
        wm.dirty = true
    end
end

--- Shown when an application blows up; keeps the rest of the shell alive.
function wm.crash(win, err)
    win.crashed = tostring(err)
    win.instance = nil
    win.title = (win.app and win.app.name or "Program") .. " (crashed)"
    win.surfaceDirty = true
    wm.dirty = true
end

function wm.call(win, method, ...)
    if not win or not win.instance then return end
    local fn = win.instance[method]
    if not fn then return end
    local drawing = (method == "draw")
    local ok, err = pcall(fn, win.instance, ...)
    if not ok then wm.crash(win, err) end
    -- Applications mark their own window dirty (either `win.dirty` or
    -- `self.dirty`); make that reach the shell. A flag raised *during*
    -- draw is ignored: that frame is already being painted, and asking
    -- for another one would repaint the same window forever.
    if win.dirty then
        win.dirty = nil
        if not drawing then
            win.surfaceDirty = true
            wm.dirty = true
        end
    end
    if win.instance and win.instance.dirty then
        win.instance.dirty = nil
        if not drawing then
            win.surfaceDirty = true
            wm.dirty = true
        end
    end
end

--- Shared context handed to applications when they are created.
local context
function wm.context()
    if not context then
        context = {
            state = state,
            wm = wm,
            gfx = gfx,
            theme = theme,
            widgets = widgets,
            dialogs = dialogs,
            icons = icons,
            menu = menu,
            apps = apps,
            -- The CC:CE fabric link and the program loader: Explorer's
            -- "Run on" and "Open", and the System app's Fabric section.
            fabric = fabric,
            programs = programs,
            -- Safe IO and the picture codec, shared with Paint and Notepad.
            storage = storage,
            picture = picture,
            image = image,
            launch = function(appId, opts) return wm.create(appId, opts) end,
            -- The context is built before setDesktop runs, so this closure
            -- reads the upvalue lazily. Explorer uses it for "Create link".
            shortcuts = {
                create = function(spec)
                    if not desktop then return nil end
                    return desktop.createShortcut(spec)
                end,
            },
        }
    end
    return context
end

--- Double click helper (shared across the shell; `tick` comes from the timer).
function wm.doubleClick(x, y)
    local click = state.lastClick
    state.lastClick = { x = x, y = y, tick = state.tick }
    if not click then return false end
    if state.tick - click.tick > 4 then return false end
    return math.abs(click.x - x) <= 6 and math.abs(click.y - y) <= 6
end

---------------------------------------------------------------------------
-- drawing
---------------------------------------------------------------------------

local function drawTitleButton(win, r, kind)
    local hot = pressed and pressed.win == win and pressed.button == kind
    if hot then
        if kind == "close" then
            gfx.fill(r[1], r[2], r[3], r[4], C.danger)
        else
            gfx.fill(r[1], r[2], r[3], r[4], C.accentLight)
        end
    end
    local cx, cy = r[1] + math.floor(r[3] / 2), r[2] + math.floor(r[4] / 2)
    if kind == "min" then
        gfx.fill(cx - 4, cy + 3, 8, 1, C.white)
    elseif kind == "max" then
        if win.state == "max" then
            gfx.rect(cx - 4, cy - 3, 8, 7, C.white)
            gfx.fill(cx - 2, cy - 5, 6, 1, C.white)
            gfx.fill(cx - 6, cy - 1, 1, 5, C.white)
        else
            gfx.rect(cx - 4, cy - 3, 8, 7, C.white)
            gfx.fill(cx - 4, cy - 3, 8, 1, C.white)
        end
    else
        gfx.line(cx - 3, cy - 3, cx + 3, cy + 3, C.white)
        gfx.line(cx + 3, cy - 3, cx - 3, cy + 3, C.white)
    end
end

local function drawCrash(win)
    local c = win.content
    gfx.fill(c.x, c.y, c.w, c.h, C.face)
    gfx.text(c.x + 8, c.y + 8, "This program has stopped.", C.danger)
    local message = tostring(win.crashed or "unknown error")
    local lines = {}
    while #message > 0 do
        local cut = math.min(#message, math.floor((c.w - 16) / 6))
        lines[#lines + 1] = message:sub(1, cut)
        message = message:sub(cut + 1)
        if #lines > 8 then break end
    end
    local y = c.y + 22
    for _, line in ipairs(lines) do
        gfx.text(c.x + 8, y, line, C.text)
        y = y + 10
    end
    local bw, bh = 62, 14
    local bx, by = c.x + math.floor((c.w - bw) / 2), c.y + c.h - bh - 8
    widgets.button(rootDC, bx, by, bw, bh, "Close")
    win._closeBtn = { bx - c.x, by - c.y, bw, bh }
end

function wm.drawWindow(win)
    if win.state == "min" then return end
    local x, y, w, h = win.x, win.y, win.w, win.h
    local active = (win == focused)

    -- frame + title bar
    gfx.fill(x, y, w, h, C.face)
    gfx.rect(x, y, w, h, active and C.accent or C.bevelDark)
    local barColour = active and C.accent or C.titleInactive
    gfx.fill(x + BORDER, y + BORDER, w - BORDER * 2, TITLE_H, barColour)

    icons.draw(rootDC, win.icon, x + BORDER + 3, y + BORDER + 2, 1)
    local titleX = x + BORDER + 14
    local titleW = w - 2 * BORDER - 14 - (w >= 76 and BTN_W * 3 + 2 or 0)
    if titleW > 0 then
        gfx.text(titleX, y + BORDER + 2, widgets.ellipsis(win.title, titleW), C.white)
    end

    local btns = titleButtons(win)
    if btns.close then
        drawTitleButton(win, btns.min, "min")
        drawTitleButton(win, btns.max, "max")
        drawTitleButton(win, btns.close, "close")
    end

    -- client area
    local c = win.content
    if not win.crashed then
        gfx.fill(c.x, c.y, c.w, c.h, C.face)
    end
    gfx.pushClip(c.x, c.y, c.w, c.h)
    if win.crashed then
        drawCrash(win)
    elseif win.instance then
        if win.instance.draw then
            wm.call(win, "draw", win.dc, c.w, c.h)
        end
        if win.dialog then
            dialogs.draw(win, win.dc)
        end
    end
    gfx.popClip()
end

--------------------------------------------------------------------------
-- surfaces and damage
--
-- A window is drawn once into the shared back buffer, then copied into a
-- private rectangle. Moving it or repainting the clock can splice those
-- cached rows back in without calling app.draw again. Surfaces are
-- refreshed in z-order during a full render, before any window above
-- them is drawn, so an occluded window keeps its own pixels rather than
-- a snapshot of whatever covered it.
--------------------------------------------------------------------------

local function surfaceFits(win)
    local s = win.surface
    return s ~= nil and s.valid == true and s.w == win.w and s.h == win.h
end

local function captureWindow(win)
    local W, H = gfx.size()
    local w, h = win.w, win.h
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    local s = win.surface
    if not s or s.w ~= w or s.h ~= h then
        s = { w = w, h = h, rows = {}, valid = false }
        win.surface = s
    end

    -- Parts of a window dragged past the edge are stored as zeroes so
    -- blitting it back at a negative/overflowing position still lines up.
    -- An edge-clipped surface has to be redrawn when it moves back inside:
    -- the pixels that were off-screen were never painted, and blitting
    -- those zeroes would punch a black hole in the window.
    local left = max(0, -win.x)
    local right = max(0, win.x + w - W)
    local vx0, vx1 = max(0, win.x), min(W, win.x + w)
    local clipped = left > 0 or right > 0
    for row = 0, h - 1 do
        local sy = win.y + row
        if sy >= 0 and sy < H and vx1 > vx0 then
            local line = gfx.row(sy + 1)
            s.rows[row + 1] = rep(char(0), left)
                .. sub(line, vx0 + 1, vx1)
                .. rep(char(0), right)
        else
            s.rows[row + 1] = rep(char(0), w)
            clipped = true
        end
    end
    s.clipped = clipped
    s.valid = true
    win.surfaceDirty = false
    win.surfaceActive = (win == focused)
end

local function blitWindow(win)
    local s = win.surface
    if not surfaceFits(win) then return false end
    for row = 1, s.h do
        gfx.blit(win.x, win.y + row - 1, s.rows[row])
    end
    return true
end

local function overlaps(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

local function clampRect(x, y, w, h)
    local W, H = gfx.size()
    if x < 0 then w = w + x; x = 0 end
    if y < 0 then h = h + y; y = 0 end
    if x + w > W then w = W - x end
    if y + h > H then h = H - y end
    if w < 1 or h < 1 then return nil end
    return x, y, w, h
end

--- Repaint only `x,y,w,h`: cached wallpaper, then window surfaces in
--- z-order, then the taskbar when the rectangle reaches it.
local function partialRender(x, y, w, h)
    local _, H = gfx.size()
    x, y, w, h = clampRect(x, y, w, h)
    if not x then return false end

    gfx.resetClip()
    gfx.setClip(x, y, w, h)
    if desktop.restoreRect then desktop.restoreRect(x, y, w, h) end
    for i = 1, #windows do
        local win = windows[i]
        if win.state ~= "min" and surfaceFits(win)
            and overlaps(x, y, w, h, win.x, win.y, win.w, win.h) then
            blitWindow(win)
        end
    end
    if y + h > H - wm.TASKBAR_H then
        desktop.drawFront(rootDC)
    end
    gfx.resetClip()
    return true
end

function wm.render()
    local W, H = gfx.size()
    if rootDC.w ~= W or rootDC.h ~= H then
        rootDC = gfx.newDC(0, 0, W, H)
    end
    gfx.resetClip()

    -- Small updates (the clock, a window move) reuse every cached surface.
    -- Fall back to a full pass when something is invalid, a menu/overlay is
    -- open, or the damage just is not worth tracking.
    if not wm.dirty and #damage > 0 then
        local can = desktop and desktop.restoreRect ~= nil
        if can and menu and menu.isOpen and menu.isOpen() then can = false end
        if can and desktop.canPartial and not desktop.canPartial() then can = false end
        if can then
            for i = 1, #windows do
                local win = windows[i]
                if win.state ~= "min"
                    and (win.surfaceDirty or not surfaceFits(win)) then
                    can = false
                    break
                end
            end
        end
        if can then
            -- One bounding box is cheaper than several clipped passes and
            -- still excludes most of the screen for the usual tray update.
            local x0, y0, x1, y1
            for i = 1, #damage do
                local r = damage[i]
                local rx0, ry0 = r[1], r[2]
                local rx1, ry1 = r[1] + r[3], r[2] + r[4]
                if not x0 or rx0 < x0 then x0 = rx0 end
                if not y0 or ry0 < y0 then y0 = ry0 end
                if not x1 or rx1 > x1 then x1 = rx1 end
                if not y1 or ry1 > y1 then y1 = ry1 end
            end
            damage = {}
            if x0 and partialRender(x0, y0, x1 - x0, y1 - y0) then
                gfx.present()
                wm.dirty = false
                return
            end
            -- partialRender found nothing to do (rect off-screen): continue
            -- into the full pass so a damaged frame is never dropped.
        end
    end

    damage = {}
    if desktop then desktop.drawBack(rootDC) end
    if desktop and desktop.captureBack then desktop.captureBack() end
    for i = 1, #windows do
        local win = windows[i]
        if win.state ~= "min" then
            local active = (win == focused)
            if win.surfaceDirty or not surfaceFits(win)
                or win.surfaceActive ~= active then
                local wasCrashed = win.crashed ~= nil
                wm.drawWindow(win)
                -- A crash can happen halfway through draw; paint the crash
                -- panel before capturing, or its half-drawn pixels would
                -- become the cached surface.
                if not wasCrashed and win.crashed then wm.drawWindow(win) end
                captureWindow(win)
            else
                blitWindow(win)
            end
        end
    end
    if desktop then desktop.drawFront(rootDC) end
    -- Context menus float above everything, including the taskbar.
    if menu then menu.draw(rootDC) end
    gfx.present()
    wm.dirty = false
end

---------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------

local function isDoubleClick(x, y)
    return wm.doubleClick(x, y)
end

local function handleTitleClick(win, x, y, button, double)
    -- Right-clicking a title bar (or its buttons) opens the window menu.
    if button == 2 then
        wm.focus(win)
        if desktop then desktop.windowMenu(win, x, y) end
        return true
    end
    local btns = titleButtons(win)
    if hitRect(btns.close, x, y) then
        if button == 1 then wm.close(win) end
        return true
    elseif hitRect(btns.max, x, y) then
        if button == 1 then wm.maximize(win) end
        return true
    elseif hitRect(btns.min, x, y) then
        if button == 1 then wm.minimize(win) end
        return true
    end
    if y <= win.y + BORDER + TITLE_H - 1 then
        if double and button == 1 then
            wm.maximize(win)
            return true
        end
        if button == 1 and win.state ~= "max" then
            drag = { mode = "move", win = win, offX = x - win.x, offY = y - win.y }
            wm.focus(win)
            return true
        end
        wm.focus(win)
        return true
    end
    return false
end

local function gripRect(win)
    return { win.x + win.w - 10, win.y + win.h - 10, 10, 10 }
end

local function onMouseDown(x, y, button, double)
    state.pointer.x, state.pointer.y = x, y

    -- An open context menu owns the mouse until it is dismissed; the click
    -- is swallowed either way, so nothing underneath reacts to it.
    if menu and menu.isOpen() then
        if button == 2 then
            menu.close()
            wm.dirty = true
            return
        end
        if menu.click(x, y, button) then
            wm.dirty = true
            return
        end
    end

    -- A modal dialog owned by the desktop swallows every click.
    if desktop and desktop.dialogClick(x, y, button, double) then
        wm.dirty = true
        return
    end

    -- taskbar / start menu sit above everything
    if desktop and desktop.barClick(x, y, button, double) then return end

    local win = wm.windowAt(x, y)
    if not win then
        if desktop and desktop.mouseDown(x, y, button, double) then return end
        if focused then focused = nil; wm.dirty = true end
        return
    end

    wm.focus(win)

    if button == 1 and win.state ~= "max" and hitRect(gripRect(win), x, y) then
        drag = { mode = "resize", win = win, startX = x, startY = y, w0 = win.w, h0 = win.h }
        return
    end

    if y < win.y + BORDER + TITLE_H and x >= win.x and x < win.x + win.w then
        handleTitleClick(win, x, y, button, double)
        return
    end

    if y >= win.content.y and y < win.content.y + win.content.h
        and x >= win.content.x and x < win.content.x + win.content.w then
        local cx, cy = x - win.content.x, y - win.content.y
        if win.crashed then
            if win._closeBtn and hitRect({ win._closeBtn[1] + win.content.x, win._closeBtn[2] + win.content.y,
                    win._closeBtn[3], win._closeBtn[4] }, x, y) then
                wm.close(win)
            end
            return
        end
        if win.dialog then
            dialogs.click(win, cx, cy, button, double)
        else
            wm.call(win, "click", cx, cy, button, double)
        end
    end
end

local function onMouseUp(x, y, button)
    state.pointer.x, state.pointer.y = x, y
    if drag then
        local win = drag.win
        drag = nil
        clampSizes(win)
        layout(win)
        wm.dirty = true
        return
    end
    if pressed then
        pressed = nil
        wm.dirty = true
    end
    if desktop and desktop.mouseUp(x, y, button) then return end
    local win = focused
    if win and not win.crashed and win.instance and win.instance.up then
        local cx, cy = x - win.content.x, y - win.content.y
        wm.call(win, "up", cx, cy, button)
    end
end

local function onMouseDrag(x, y, button)
    state.pointer.x, state.pointer.y = x, y
    if drag then
        local win = drag.win
        local oldX, oldY, oldW, oldH = win.x, win.y, win.w, win.h
        if drag.mode == "move" then
            local _, _, aw, ah = wm.desktopArea()
            win.x = x - drag.offX
            win.y = y - drag.offY
            if win.y < 0 then win.y = 0 end
            if win.y > ah - TITLE_H then win.y = ah - TITLE_H end
            if win.x < -win.w + 40 then win.x = -win.w + 40 end
            if win.x > aw - 40 then win.x = aw - 40 end
        else
            win.w = drag.w0 + (x - drag.startX)
            win.h = drag.h0 + (y - drag.startY)
            clampSizes(win)
        end
        layout(win)
        -- Only the old and new window rectangles changed. The window's
        -- cached surface is position-independent, so a move costs a
        -- background restore and a few row blits, not another app.draw.
        -- A surface captured while part of the window was off-screen did
        -- not see those pixels, so it must be painted again instead.
        if win.surface and win.surface.clipped then win.surfaceDirty = true end
        wm.markRect(oldX, oldY, oldW, oldH)
        wm.markRect(win.x, win.y, win.w, win.h)
        return
    end
    if desktop and desktop.mouseDrag(x, y, button) then return end
    local win = focused
    if win and not win.crashed and win.instance and win.instance.drag then
        local cx, cy = x - win.content.x, y - win.content.y
        wm.call(win, "drag", cx, cy, button)
    end
end

local function onMouseScroll(dir, x, y)
    state.pointer.x, state.pointer.y = x, y
    if menu and menu.isOpen() then menu.close() end
    if desktop and desktop.dialogOpen() then return end
    if desktop and desktop.barScroll(dir, x, y) then return end
    local win = wm.windowAt(x, y)
    if not win then
        if desktop then desktop.scrollIcons(dir) end
        return
    end
    wm.focus(win)
    if win.dialog then
        dialogs.scroll(win, dir, x - win.content.x, y - win.content.y)
    elseif not win.crashed then
        wm.call(win, "scroll", x - win.content.x, y - win.content.y, dir)
    end
end

--- Feed a queued event into the shell.
function wm.handle(ev)
    local name = ev[1]
    if name == "mouse_click" then
        local double = isDoubleClick(ev[3], ev[4])
        onMouseDown(ev[3], ev[4], ev[2], double)
        wm.dirty = true
    elseif name == "mouse_up" then
        onMouseUp(ev[3], ev[4], ev[2])
    elseif name == "mouse_drag" then
        onMouseDrag(ev[3], ev[4], ev[2])
    elseif name == "mouse_scroll" then
        onMouseScroll(ev[2], ev[3], ev[4])
        wm.dirty = true
    elseif name == "key" then
        if menu and menu.isOpen() and menu.key(ev[2]) then
            -- consumed by the open menu
        elseif desktop and desktop.dialogOpen() and desktop.key(ev[2]) then
            -- consumed by a modal desktop dialog
        else
            local win = focused
            if win then
                if win.dialog then
                    dialogs.key(win, ev[2])
                elseif not win.crashed then
                    wm.call(win, "key", ev[2])
                end
            elseif desktop then
                desktop.key(ev[2])
            end
        end
        wm.dirty = true
    elseif name == "char" then
        if menu and menu.isOpen() then
            menu.close()
        elseif desktop and desktop.dialogOpen() and desktop.char(ev[2]) then
            -- consumed by a modal desktop dialog
        else
            local win = focused
            if win then
                if win.dialog then
                    dialogs.char(win, ev[2])
                elseif not win.crashed then
                    wm.call(win, "char", ev[2])
                end
            elseif desktop then
                desktop.char(ev[2])
            end
        end
        wm.dirty = true
    elseif name == "key_up" or name == "paste" then
        if menu and menu.isOpen() then
            -- menus swallow typing
        elseif desktop and desktop.dialogOpen() then
            -- a modal desktop dialog swallows key_up, and pasting a path
            -- into its text field is exactly what a user wants
            if name == "paste" then
                for ch in tostring(ev[2]):gmatch(".") do desktop.char(ch) end
            end
        else
            local win = focused
            if win and not win.crashed then
                if name == "paste" then
                    for ch in tostring(ev[2]):gmatch(".") do
                        if win.dialog then
                            dialogs.char(win, ch)
                        else
                            wm.call(win, "char", ch)
                        end
                    end
                elseif not win.dialog then
                    wm.call(win, "key_up", ev[2])
                end
            end
        end
        wm.dirty = true
    elseif name == "term_resize" then
        gfx.resize()
        rootDC = gfx.newDC(0, 0, gfx.size())
        local _, _, aw, ah = wm.desktopArea()
        for _, win in ipairs(windows) do
            if win.state == "max" then
                win.x, win.y, win.w, win.h = 0, 0, aw, ah
            end
            clampSizes(win)
            layout(win)
        end
        if desktop then desktop.rebuild() end
        wm.dirty = true
    elseif name == "cee_fabric_message" then
        -- A peer on the CC:CE fabric: a greeting, a program for us to run,
        -- or the answer to a run we asked for. Programs inside consoles see
        -- the same event (wm.broadcast already forwarded it).
        if fabric and fabric.receive then fabric.receive(ev[2], ev[3]) end
        wm.dirty = true
    elseif name == "timer" then
        for _, win in ipairs(windows) do
            if win.instance and win.instance.timer then
                wm.call(win, "timer", ev[2])
            end
        end
    end
end

--- Forward every event to background children (console windows etc).
function wm.broadcast(ev)
    for _, win in ipairs(windows) do
        if win.instance and win.instance.feed then
            wm.call(win, "feed", ev)
        end
    end
end

return wm
