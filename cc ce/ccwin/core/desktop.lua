--- CC-Windows - desktop, icons, taskbar and start menu.
local desktop = {}

local gfx, theme, widgets, icons, wm, backdrop, C
local state, settings

local wallpaper = {}
local iconGrid = {}
local selectedIcon = nil
local startMenuOpen = false
local clockText = ""
local powerState = nil

local ICON_W, ICON_H = 62, 54
local ICON_PAD = 6
local TASK_START_W = 50
local ROW_H = 15

local DESKTOP_APPS = { "explorer", "console", "editor", "paint", "settings", "system" }

function desktop.attach(d)
    gfx, theme, widgets, icons, wm, backdrop =
        d.gfx, d.theme, d.widgets, d.icons, d.wm, d.backdrop
    C = theme.C
    state, settings = d.state, d.settings
end

local function appDef(appId)
    local ctx = wm.context()
    return ctx and ctx.apps and ctx.apps[appId] or nil
end

local function centreText(dc, x, y, w, text, fg)
    local tw = dc:textWidth(text)
    dc:text(x + math.floor((w - tw) / 2), y, text, fg)
end

local function startApps()
    local list = {}
    for _, appId in ipairs(DESKTOP_APPS) do
        if appDef(appId) then list[#list + 1] = appId end
    end
    return list
end

---------------------------------------------------------------------------
-- layout
---------------------------------------------------------------------------

local function layoutIcons()
    local W, H = gfx.size()
    local areaH = H - wm.TASKBAR_H
    local perColumn = math.max(1, math.floor((areaH - ICON_PAD * 2) / ICON_H))
    iconGrid = {}
    for index, appId in ipairs(DESKTOP_APPS) do
        local column = math.floor((index - 1) / perColumn)
        local row = (index - 1) % perColumn
        iconGrid[index] = {
            appId = appId,
            x = ICON_PAD + column * ICON_W,
            y = ICON_PAD + row * ICON_H,
        }
    end
end

local function iconAt(x, y)
    for i, entry in ipairs(iconGrid) do
        if x >= entry.x and x < entry.x + ICON_W and y >= entry.y and y < entry.y + ICON_H then
            return i, entry
        end
    end
    return nil, nil
end

--- Regenerate the wallpaper and icon grid (after boot, resize or settings change).
function desktop.rebuild()
    local W, H = gfx.size()
    wallpaper = backdrop.build(W, H, settings)
    layoutIcons()
    wm.dirty = true
end

---------------------------------------------------------------------------
-- background: wallpaper + desktop icons
---------------------------------------------------------------------------

function desktop.drawBack(rootDC)
    local W, H = gfx.size()
    local fallback = string.rep(string.char(C.wpNavy), W)
    for y = 1, H do
        local row = wallpaper[y]
        if row and #row == W then
            gfx.setRow(y, row)
        else
            gfx.setRow(y, fallback)
        end
    end

    for i, entry in ipairs(iconGrid) do
        local app = appDef(entry.appId)
        if app then
            local selected = (selectedIcon == i)
            local ix = entry.x + math.floor((ICON_W - 16) / 2)
            local iy = entry.y + 4
            if selected then
                rootDC:fill(entry.x + 2, entry.y + 1, ICON_W - 4, 44, C.accentFaint)
                rootDC:rect(entry.x + 2, entry.y + 1, ICON_W - 4, 44, C.accent)
            end
            icons.draw(rootDC, app.icon, ix, iy, 2)

            -- label: up to two lines of ten characters, with a drop shadow
            local label = app.name
            local line1, line2 = label, nil
            if #label > 10 then
                local cut = 10
                local space = label:sub(1, 10):find(" ")
                if space and space > 5 then cut = space - 1 end
                line1 = label:sub(1, cut)
                line2 = label:sub(cut + 2)
                if line2 and #line2 > 10 then line2 = line2:sub(1, 10) .. "." end
            end
            local ty = entry.y + 24
            local bg = selected and C.accent or nil
            if bg then
                rootDC:fill(entry.x + 3, ty - 2, ICON_W - 6, line2 and 21 or 12, bg)
            end
            local centre = entry.x + math.floor((ICON_W - #line1 * 6) / 2)
            if not bg then rootDC:text(centre + 1, ty + 1, line1, C.black) end
            rootDC:text(centre, ty, line1, C.white)
            if line2 then
                local c2 = entry.x + math.floor((ICON_W - #line2 * 6) / 2)
                if not bg then rootDC:text(c2 + 1, ty + 10, line2, C.black) end
                rootDC:text(c2, ty + 9, line2, C.white)
            end
        end
    end
end

---------------------------------------------------------------------------
-- foreground: taskbar + start menu
---------------------------------------------------------------------------

local function drawLogo(rootDC, x, y, size)
    local q = math.floor((size - 1) / 2)
    rootDC:fill(x, y, q, q, C.accent)
    rootDC:fill(x + q + 1, y, size - q - 1, q, C.accentLight)
    rootDC:fill(x, y + q + 1, q, size - q - 1, C.accentLight)
    rootDC:fill(x + q + 1, y + q + 1, size - q - 1, size - q - 1, C.accentDark)
end

local function taskButtons()
    local W, H = gfx.size()
    local y = H - wm.TASKBAR_H
    local list = {}
    local x = TASK_START_W + 4
    local trayW = gfx.textWidth(clockText) + (powerState ~= nil and 22 or 10)
    local open = wm.list()
    local avail = W - trayW - x - 6
    local width = 88
    if #open > 0 then
        width = math.min(88, math.max(40, math.floor(avail / #open)))
    end
    for _, win in ipairs(open) do
        if x + width > W - trayW then break end
        list[#list + 1] = { win = win, x = x, y = y + 2, w = width, h = wm.TASKBAR_H - 4 }
        x = x + width + 3
    end
    return list
end

local function startMenuRect()
    local W, H = gfx.size()
    local barY = H - wm.TASKBAR_H
    local height = math.min(barY - 2, 190)
    local width = math.min(150, W - 4)
    return 1, barY - height, width, height
end
desktop.startMenuRect = startMenuRect

local function drawStartMenu(rootDC)
    local x, y, width, height = startMenuRect()
    local apps = startApps()

    rootDC:fill(x + 3, y + 3, width, height, C.shadow)
    rootDC:fill(x, y, width, height, C.face)
    rootDC:rect(x, y, width, height, C.accent)

    -- header
    rootDC:fill(x + 1, y + 1, width - 2, 24, C.accent)
    local name = os.getComputerLabel() or ("Computer " .. os.getComputerID())
    rootDC:text(x + 8, y + 4, widgets.ellipsis(name, width - 16), C.white)
    rootDC:text(x + 8, y + 14, os.date("%a %b %d"), C.white)

    -- applications
    local iy = y + 27
    for _, appId in ipairs(apps) do
        local app = appDef(appId)
        icons.draw(rootDC, app.icon, x + 6, iy + 3, 1)
        rootDC:text(x + 18, iy + 3, widgets.ellipsis(app.name, width - 26), C.text)
        iy = iy + ROW_H
    end

    -- power section pinned to the bottom
    local py = y + height - 2 * ROW_H - 4
    rootDC:fill(x + 1, py, width - 2, 1, C.bevelMid)
    rootDC:text(x + 20, py + 5, "Restart", C.text)
    icons.draw(rootDC, "power", x + 7, py + 5, 1)
    icons.draw(rootDC, "power", x + 7, py + ROW_H + 5, 1)
    rootDC:text(x + 20, py + ROW_H + 5, "Shut down", C.text)
end

function desktop.drawFront(rootDC)
    local W, H = gfx.size()
    local y = H - wm.TASKBAR_H

    rootDC:fill(0, y, W, wm.TASKBAR_H, C.taskbar)
    rootDC:fill(0, y, W, 1, C.taskbarHover)

    -- start button
    rootDC:fill(0, y + 1, TASK_START_W, wm.TASKBAR_H - 1,
        startMenuOpen and C.taskbarHover or C.taskbar)
    if startMenuOpen then
        rootDC:rect(0, y + 1, TASK_START_W, wm.TASKBAR_H - 1, C.accent)
    end
    drawLogo(rootDC, 5, y + 3, 11)
    rootDC:text(20, y + 4, "Start", C.white)

    -- task buttons
    local focusedWin = wm.focused()
    for _, button in ipairs(taskButtons()) do
        local win = button.win
        local isActive = (win == focusedWin and win.state ~= "min")
        rootDC:fill(button.x, button.y, button.w, button.h,
            isActive and C.taskbarHover or C.taskbar)
        if isActive then
            rootDC:fill(button.x, button.y, button.w, 1, C.accent)
            rootDC:fill(button.x, button.y + button.h - 1, button.w, 1, C.accent)
        end
        icons.draw(rootDC, win.icon, button.x + 3, button.y + 2, 1)
        local text = widgets.ellipsis(win.title, button.w - 16)
        rootDC:text(button.x + 14, button.y + 2, text, C.white)
    end

    -- tray: clock (and the CC:CE power indicator when one is present)
    local clockW = gfx.textWidth(clockText)
    rootDC:text(W - clockW - 8, y + 4, clockText, C.white)
    if powerState ~= nil then
        local colour = powerState and C.success or C.danger
        rootDC:fill(W - clockW - 18, y + 5, 7, 7, colour)
        rootDC:fill(W - clockW - 18, y + 5, 7, 1, C.white)
        rootDC:fill(W - clockW - 18, y + 11, 7, 1, C.black)
    end

    if startMenuOpen then drawStartMenu(rootDC) end
end

---------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------

function desktop.barClick(x, y, button, double)
    local W, H = gfx.size()
    local barY = H - wm.TASKBAR_H
    local menuX, menuY, menuW, menuH = startMenuRect()

    if y >= barY and x >= 0 and x < TASK_START_W then
        startMenuOpen = not startMenuOpen
        wm.dirty = true
        return true
    end

    if startMenuOpen then
        local inside = x >= menuX and x < menuX + menuW and y >= menuY and y < menuY + menuH
        if inside then
            local apps = startApps()
            local iy = menuY + 27
            for _, appId in ipairs(apps) do
                if y >= iy and y < iy + ROW_H then
                    startMenuOpen = false
                    wm.create(appId)
                    return true
                end
                iy = iy + ROW_H
            end
            local py = menuY + menuH - 2 * ROW_H - 4
            if y >= py and y < py + ROW_H then
                startMenuOpen = false
                if state.onPower then state.onPower("restart") end
                return true
            elseif y >= py + ROW_H and y < py + 2 * ROW_H then
                startMenuOpen = false
                if state.onPower then state.onPower("shutdown") end
                return true
            end
        end
        startMenuOpen = false
        wm.dirty = true
        return true
    end

    if y >= barY then
        for _, button in ipairs(taskButtons()) do
            if x >= button.x and x < button.x + button.w
                and y >= button.y and y < button.y + button.h then
                local win = button.win
                if win.state == "min" then
                    wm.restore(win)
                elseif wm.focused() == win then
                    wm.minimize(win)
                else
                    wm.focus(win)
                end
                return true
            end
        end
        return true
    end
    return false
end

function desktop.barScroll(dir, x, y)
    return false
end

function desktop.iconClick(x, y, button, double)
    local index, entry = iconAt(x, y)
    if entry then
        selectedIcon = index
        wm.dirty = true
        if double and button == 1 then
            startMenuOpen = false
            wm.create(entry.appId)
        end
        return true
    end
    if selectedIcon then
        selectedIcon = nil
        wm.dirty = true
    end
    return false
end

function desktop.scrollIcons(dir) end

function desktop.isStartMenuOpen() return startMenuOpen end

function desktop.closeMenus()
    if startMenuOpen then
        startMenuOpen = false
        wm.dirty = true
    end
end

---------------------------------------------------------------------------
-- clock / tray status
---------------------------------------------------------------------------

function desktop.updateClock()
    local text
    if settings.clockSeconds then
        text = os.date("%H:%M:%S")
    else
        text = os.date("%H:%M")
    end

    local newPower = nil
    if type(cee) == "table" and cee.hasPower then
        local ok, has = pcall(cee.hasPower)
        if ok then newPower = has end
    end
    powerState = newPower

    if text ~= clockText then
        clockText = text
        wm.dirty = true
    end
end

function desktop.powerState() return powerState end

return desktop
