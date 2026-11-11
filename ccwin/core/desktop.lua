--- CC-Windows - desktop, icons, taskbar and start menu.
--
-- Desktop icons are *shortcuts*: one small serialised table per file in
-- /desktop, the CC equivalent of a Windows .lnk file. The OS seeds that
-- folder on first boot so every installed program gets a link; after that the
-- folder is the source of truth, which is what makes delete, rename and
-- arrange survive a reboot.
local desktop = {}

local gfx, theme, widgets, icons, wm, backdrop, dialogs, menu, C
local state, settings, programs

local wallpaper = {}
local iconGrid = {}
local entries = {}
local selectedFile = nil
local press = nil              -- icon press / drag in progress
local startMenuOpen = false
local desktopDialog = nil      -- modal dialog owned by the desktop itself
local clockText = ""
local powerState = nil
local seedAndLoad              -- defined below, called by desktop.attach

local ICON_PAD = 6
local TASK_START_W = 50
local ROW_H = 15

local DESKTOP_APPS = { "explorer", "console", "editor", "paint", "settings", "system" }

-- Icon views, the desktop equivalent of Windows' Large/Medium/Small icons.
-- `medium` is the default and must keep the original 62x54 grid: the shell's
-- own layout and the test harness both depend on it.
local SIZES = {
    small = { scale = 1, w = 44, h = 38 },
    medium = { scale = 2, w = 62, h = 54 },
    large = { scale = 3, w = 78, h = 68 },
}

local SHORTCUT_DIR = "/desktop"
-- Programs dropped here get a desktop link of their own (see
-- linkPrograms), which is what makes "copy a program in, reboot, there it
-- is" work without an installer.
local PROGRAMS_DIR = "/programs"
local BASE = (rawget(_G, "CCWIN_DIR") ~= nil and rawget(_G, "CCWIN_DIR") ~= "")
    and rawget(_G, "CCWIN_DIR") or "/ccwin"
local SEED_FLAG = fs.combine(BASE, "desktop.seeded")

function desktop.attach(d)
    gfx, theme, widgets, icons, wm, backdrop =
        d.gfx, d.theme, d.widgets, d.icons, d.wm, d.backdrop
    dialogs, menu = d.dialogs, d.menu
    C = theme.C
    state, settings = d.state, d.settings
    programs = d.programs
    seedAndLoad()
end

local function appDef(appId)
    local ctx = wm.context()
    return ctx and ctx.apps and ctx.apps[appId] or nil
end

local function startApps()
    local list = {}
    for _, appId in ipairs(DESKTOP_APPS) do
        if appDef(appId) then list[#list + 1] = appId end
    end
    return list
end

local function metrics()
    local id = settings and settings.iconSize or "medium"
    return SIZES[id] or SIZES.medium
end

local function areaSize()
    local W, H = gfx.size()
    return W, H - wm.TASKBAR_H
end

local function mark()
    wm.dirty = true
end

---------------------------------------------------------------------------
-- shortcuts (.lnk files)
---------------------------------------------------------------------------

--- File names must survive a Windows filesystem (the test harness stores the
-- sandbox on disk) and stay readable in Explorer.
local function sanitise(name)
    name = tostring(name or "shortcut"):gsub('[\\/:*?"<>|]', "-")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "shortcut" end
    if #name > 40 then name = name:sub(1, 40) end
    return name
end

local function shortcutPath(file)
    return fs.combine(SHORTCUT_DIR, file)
end

local function freeFileName(label)
    local base = sanitise(label)
    local name = base .. ".lnk"
    local n = 2
    while fs.exists(shortcutPath(name)) do
        name = string.format("%s (%d).lnk", base, n)
        n = n + 1
        if n > 500 then break end
    end
    return name
end

local function writeShortcut(e)
    local f = fs.open(shortcutPath(e.file), "w")
    if not f then return false end
    f.writeLine(textutils.serialise({
        kind = e.kind,
        target = e.target,
        label = e.label,
        icon = e.icon,
        x = e.x,
        y = e.y,
    }))
    f.close()
    return true
end

local function loadEntries()
    entries = {}
    if not fs.exists(SHORTCUT_DIR) or not fs.isDir(SHORTCUT_DIR) then return end
    local ok, list = pcall(fs.list, SHORTCUT_DIR)
    if not ok or not list then return end
    for _, name in ipairs(list) do
        if name:match("%.lnk$") then
            local f = fs.open(shortcutPath(name), "r")
            if f then
                local src = f.readAll()
                f.close()
                local ok2, data = pcall(textutils.unserialise, src)
                if ok2 and type(data) == "table" and data.target then
                    entries[#entries + 1] = {
                        file = name,
                        kind = data.kind == "file" and "file" or "app",
                        target = data.target,
                        label = tostring(data.label or data.target),
                        icon = data.icon or "file",
                        x = data.x,
                        y = data.y,
                    }
                end
            end
        end
    end
    table.sort(entries, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
end

local function cellPos(col, row)
    local m = metrics()
    return ICON_PAD + col * m.w, ICON_PAD + row * m.h
end

--- First free grid slot, column-major, skipping anything already placed.
local function nextFreeSlot()
    local m = metrics()
    local _, ah = areaSize()
    local perColumn = math.max(1, math.floor((ah - ICON_PAD * 2) / m.h))
    local used = {}
    for _, e in ipairs(entries) do
        local col = math.floor(((e.x or 0) - ICON_PAD) / m.w)
        local row = math.floor(((e.y or 0) - ICON_PAD) / m.h)
        used[col .. "," .. row] = true
    end
    for col = 0, 999 do
        for row = 0, perColumn - 1 do
            if not used[col .. "," .. row] then
                return cellPos(col, row)
            end
        end
    end
    return cellPos(0, 0)
end

local function iconFor(path)
    if fs.isDir(path) then return "folder" end
    local ext = (path:match("%.([%w]+)$") or ""):lower()
    if ext == "lua" then return "terminal" end
    if ext == "nfp" or ext == "png" then return "paint" end
    if ext == "txt" or ext == "md" or ext == "cfg" then return "editor" end
    return "file"
end

local function createShortcut(spec)
    local e = {
        kind = spec.kind == "file" and "file" or "app",
        target = spec.target,
        label = sanitise(spec.label),
        icon = spec.icon or "file",
    }
    e.file = freeFileName(e.label)
    e.x, e.y = nextFreeSlot()
    entries[#entries + 1] = e
    writeShortcut(e)
    return e
end

--- First boot only: give every installed program a link on the desktop.
-- The flag lives outside /desktop so deleting every shortcut stays deleted.
seedAndLoad = function()
    if not fs.exists(SEED_FLAG) then
        fs.makeDir(SHORTCUT_DIR)
        for _, appId in ipairs(DESKTOP_APPS) do
            local app = appDef(appId)
            if app then
                createShortcut {
                    kind = "app",
                    target = appId,
                    label = app.name,
                    icon = app.icon,
                }
            end
        end
        local f = fs.open(SEED_FLAG, "w")
        if f then f.writeLine("1") f.close() end
    end
    loadEntries()
end

--- True while a desktop-owned modal dialog is up (it swallows all input).
function desktop.dialogOpen()
    return desktopDialog ~= nil and desktopDialog.dialog ~= nil
end

---------------------------------------------------------------------------
-- layout
---------------------------------------------------------------------------

local function buildGrid()
    iconGrid = {}
    for _, e in ipairs(entries) do
        iconGrid[#iconGrid + 1] = { entry = e, x = e.x, y = e.y }
    end
end

local function layoutIcons()
    local m = metrics()
    local aw, ah = areaSize()
    for _, e in ipairs(entries) do
        if type(e.x) ~= "number" or type(e.y) ~= "number" then
            e.x, e.y = nextFreeSlot()
        end
        if e.x > aw - m.w then e.x = math.max(0, aw - m.w) end
        if e.y > ah - m.h then e.y = math.max(0, ah - m.h) end
        if e.x < 0 then e.x = 0 end
        if e.y < 0 then e.y = 0 end
    end
    buildGrid()
end

local function iconAt(x, y)
    local m = metrics()
    for i, g in ipairs(iconGrid) do
        if x >= g.x and x < g.x + m.w and y >= g.y and y < g.y + m.h then
            return i, g
        end
    end
    return nil, nil
end

local function selectedEntry()
    if not selectedFile then return nil end
    for _, e in ipairs(entries) do
        if e.file == selectedFile then return e end
    end
    return nil
end

local function entryByFile(file)
    for _, e in ipairs(entries) do
        if e.file == file then return e end
    end
    return nil
end

--- Give every CC-Windows program a desktop link of its own.
-- Two folders are scanned: /programs, and any loose .lua dropped straight
-- onto the desktop (the desktop only lists .lnk files, so without this
-- such a program would be invisible). Only a file whose first line says
-- `--- CC-Windows - ...` qualifies - looking at a file never runs it -
-- and a program that already has a link is skipped, so this is cheap
-- enough to run on every rebuild.
local function linkPrograms()
    if not programs then return end
    -- The programs folder belongs to the OS: keep it present so "copy a
    -- program into /programs" always has somewhere to land.
    if not fs.exists(PROGRAMS_DIR) then pcall(fs.makeDir, PROGRAMS_DIR) end
    local made = false
    local function scan(dir)
        for _, target in ipairs(programs.scan(dir)) do
            local known = false
            for _, e in ipairs(entries) do
                if e.target == target then
                    known = true
                    break
                end
            end
            if not known then
                createShortcut {
                    kind = "file",
                    target = target,
                    label = fs.getName(target):gsub("%.[%w]+$", ""),
                    icon = iconFor(target),
                }
                made = true
            end
        end
    end
    scan(PROGRAMS_DIR)
    scan(SHORTCUT_DIR)
    if made then
        loadEntries()
        layoutIcons()
        mark()
    end
end

--- Regenerate the wallpaper and icon grid (after boot, resize or settings change).
function desktop.rebuild()
    linkPrograms()
    local W, H = gfx.size()
    wallpaper = backdrop.build(W, H, settings)
    layoutIcons()
    mark()
end

---------------------------------------------------------------------------
-- opening targets
---------------------------------------------------------------------------

local function openFile(path)
    local ext = (path:match("%.([%w]+)$") or ""):lower()
    if fs.isDir(path) then
        wm.create("explorer", { path = path })
    elseif ext == "lua" then
        -- a program: ours opens as a real window, anything else runs in
        -- the CraftOS console (both decided by core/programs.lua)
        if programs then
            programs.open(path)
        else
            wm.create("console", { program = path })
        end
    elseif ext == "nfp" or ext == "png" then
        wm.create("paint", { path = path })
    else
        wm.create("editor", { path = path })
    end
end

local function openEntry(e)
    startMenuOpen = false
    if not e then return end
    if e.kind == "app" then
        if appDef(e.target) then
            wm.create(e.target)
        else
            -- the program is gone; drop the dead link
            fs.delete(shortcutPath(e.file))
            loadEntries()
            layoutIcons()
            mark()
        end
    else
        openFile(e.target)
    end
end

---------------------------------------------------------------------------
-- desktop-owned modal dialogs
--
-- Dialogs belong to a window, but the desktop is not one. This fake window
-- gives dialogs a client area covering the desktop; wm routes input here
-- while it is open, and drawFront paints it above everything else.
---------------------------------------------------------------------------

local function openDesktopDialog(spec)
    if desktopDialog and desktopDialog.dialog then return end
    local W, H = gfx.size()
    desktopDialog = {
        content = { x = 0, y = 0, w = W, h = H - wm.TASKBAR_H },
        dialog = nil,
    }
    dialogs.open(desktopDialog, spec)
    mark()
end

--- True while a desktop dialog is open (it is modal: everything is swallowed).
function desktop.dialogClick(x, y, button, double)
    if not desktopDialog or not desktopDialog.dialog then return false end
    local c = desktopDialog.content
    dialogs.click(desktopDialog, x - c.x, y - c.y, button, double)
    mark()
    return true
end

---------------------------------------------------------------------------
-- icon operations
---------------------------------------------------------------------------

local function refresh()
    linkPrograms()
    loadEntries()
    layoutIcons()
    if selectedFile and not selectedEntry() then selectedFile = nil end
    mark()
end

--- Create a shortcut on the desktop, select it and redraw.
-- Public so applications can drop a link here (Explorer's "Create link");
-- the label and the icon are derived from the target when omitted.
function desktop.createShortcut(spec)
    spec = spec or {}
    if not spec.target then return nil end
    local kind = spec.kind == "app" and "app" or "file"
    local label, icon = spec.label, spec.icon
    if kind == "app" then
        local app = appDef(spec.target)
        if not label then label = (app and app.name) or spec.target end
        if not icon then icon = (app and app.icon) or "file" end
    else
        if not label then label = fs.getName(spec.target):gsub("%.[%w]+$", "") end
        if not icon then icon = iconFor(spec.target) end
    end
    -- the folder may have been emptied (or deleted) by the user
    fs.makeDir(SHORTCUT_DIR)
    local e = createShortcut {
        kind = kind, target = spec.target, label = label, icon = icon,
    }
    selectedFile = e.file
    layoutIcons()
    mark()
    return e
end

local function setIconSize(id)
    if not SIZES[id] or settings.iconSize == id then return end
    settings.iconSize = id
    if state and state.save then state.save() end
    layoutIcons()
    mark()
end

local function sortByNames()
    table.sort(entries, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
    local aw, ah = areaSize()
    local m = metrics()
    local perColumn = math.max(1, math.floor((ah - ICON_PAD * 2) / m.h))
    for i, e in ipairs(entries) do
        local col = math.floor((i - 1) / perColumn)
        local row = (i - 1) % perColumn
        e.x, e.y = cellPos(col, row)
        if e.x > aw - m.w then e.x = math.max(0, aw - m.w) end
        writeShortcut(e)
    end
    layoutIcons()
    mark()
end

local function newShortcut()
    openDesktopDialog {
        type = "file",
        title = "New Shortcut",
        path = "/",
        onPick = function(path)
            desktop.createShortcut { kind = "file", target = path }
        end,
    }
end

local function renameEntry(e)
    if not e then return end
    local file = e.file
    openDesktopDialog {
        type = "prompt",
        title = "Rename",
        label = "New name:",
        initial = e.label,
        onSubmit = function(text)
            local live = entryByFile(file)
            if not live then return end
            text = sanitise(text)
            if text == live.label then return end
            local oldFile = live.file
            local newFile = freeFileName(text)
            live.label = text
            live.file = newFile
            if writeShortcut(live) then
                fs.delete(shortcutPath(oldFile))
                if selectedFile == oldFile then selectedFile = newFile end
                loadEntries()
                layoutIcons()
                mark()
            else
                live.label = oldFile:gsub("%.lnk$", "")
                live.file = oldFile
            end
        end,
    }
end

local function deleteEntry(e)
    if not e then return end
    local file = e.file
    openDesktopDialog {
        type = "confirm",
        title = "Delete Shortcut",
        message = 'Delete shortcut "' .. e.label .. '"?',
        buttons = { "Delete", "Cancel" },
        onResult = function(n)
            if n ~= 1 then return end
            local live = entryByFile(file)
            if not live then return end
            fs.delete(shortcutPath(live.file))
            if selectedFile == live.file then selectedFile = nil end
            refresh()
        end,
    }
end

local function showProperties(e)
    if not e then return end
    local kind = e.kind == "app" and "Program" or "File"
    openDesktopDialog {
        type = "confirm",
        title = "Shortcut Properties",
        message = "Target: " .. e.target .. "\nType: " .. kind
            .. "\nLocation: " .. SHORTCUT_DIR,
        buttons = { "OK" },
        onResult = function() end,
    }
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

    local m = metrics()
    local iconPx = 8 * m.scale
    for _, g in ipairs(iconGrid) do
        local e = g.entry
        local selected = (selectedFile == e.file)
        local ix = g.x + math.floor((m.w - iconPx) / 2)
        local iy = g.y + 4
        local selH = iconPx + 28

        if selected then
            rootDC:fill(g.x + 2, g.y + 1, m.w - 4, selH, C.accentFaint)
            rootDC:rect(g.x + 2, g.y + 1, m.w - 4, selH, C.accent)
        end
        icons.draw(rootDC, e.icon, ix, iy, m.scale)

        -- label: up to two lines of ten characters, with a drop shadow
        local label = e.label
        local line1, line2 = label, nil
        if #label > 10 then
            local cut = 10
            local space = label:sub(1, 10):find(" ")
            if space and space > 5 then cut = space - 1 end
            line1 = label:sub(1, cut)
            line2 = label:sub(cut + 2)
            if line2 and #line2 > 10 then line2 = line2:sub(1, 10) .. "." end
        end
        local ty = g.y + 4 + iconPx + 4
        local bg = selected and C.accent or nil
        if bg then
            rootDC:fill(g.x + 3, ty - 2, m.w - 6, line2 and 21 or 12, bg)
        end
        local centre = g.x + math.floor((m.w - #line1 * 6) / 2)
        if not bg then rootDC:text(centre + 1, ty + 1, line1, C.black) end
        rootDC:text(centre, ty, line1, C.white)
        if line2 then
            local c2 = g.x + math.floor((m.w - #line2 * 6) / 2)
            if not bg then rootDC:text(c2 + 1, ty + 10, line2, C.black) end
            rootDC:text(c2, ty + 9, line2, C.white)
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

    -- a dialog owned by the desktop paints above the taskbar
    if desktopDialog and desktopDialog.dialog then
        dialogs.draw(desktopDialog, rootDC)
    end
end

---------------------------------------------------------------------------
-- context menus
---------------------------------------------------------------------------

local function closeStartMenu()
    if startMenuOpen then
        startMenuOpen = false
        mark()
    end
end

local function viewItems()
    local current = settings.iconSize or "medium"
    local function item(id, label)
        return {
            label = label,
            checked = current == id,
            onPick = function() setIconSize(id) end,
        }
    end
    return {
        item("large", "Large icons"),
        item("medium", "Medium icons"),
        item("small", "Small icons"),
    }
end

local function openDesktopMenu(x, y)
    closeStartMenu()
    if not menu then return end
    menu.open {
        x = x, y = y,
        items = {
            { label = "View", submenu = viewItems() },
            { label = "Sort by", submenu = {
                { label = "Name", onPick = sortByNames },
            } },
            { sep = true },
            { label = "Refresh", onPick = refresh },
            { sep = true },
            { label = "New", submenu = {
                { label = "Shortcut", icon = "file", onPick = newShortcut },
            } },
            { sep = true },
            { label = "Personalize", icon = "settings",
              onPick = function() wm.create("settings") end },
        },
    }
end

local function openIconMenu(g, x, y)
    closeStartMenu()
    if not menu then return end
    local file = g.entry.file
    local function live() return entryByFile(file) end

    local items = {
        { label = "Open", icon = g.entry.icon,
          onPick = function() openEntry(live()) end },
    }
    if g.entry.kind == "file" then
        items[#items + 1] = {
            label = "Edit", icon = "editor",
            onPick = function()
                local e = live()
                if e then wm.create("editor", { path = e.target }) end
            end,
        }
    end
    items[#items + 1] = { sep = true }
    items[#items + 1] = { label = "Rename",
        onPick = function() renameEntry(live()) end }
    items[#items + 1] = { label = "Delete",
        onPick = function() deleteEntry(live()) end }
    items[#items + 1] = { sep = true }
    items[#items + 1] = { label = "Properties", icon = "info",
        onPick = function() showProperties(live()) end }

    menu.open { x = x, y = y, items = items }
end

--- Right-click menu for a window's title bar (and its taskbar button).
function desktop.windowMenu(win, x, y)
    if not menu or not win then return end
    local items = {}
    if win.state == "max" then
        items[#items + 1] = { label = "Restore",
            onPick = function() wm.maximize(win) end }
    elseif win.state == "min" then
        items[#items + 1] = { label = "Restore",
            onPick = function() wm.restore(win) end }
    else
        items[#items + 1] = { label = "Minimize",
            onPick = function() wm.minimize(win) end }
        items[#items + 1] = { label = "Maximize",
            onPick = function() wm.maximize(win) end }
    end
    items[#items + 1] = { sep = true }
    items[#items + 1] = { label = "Close",
        onPick = function() wm.close(win) end }
    menu.open { x = x, y = y, items = items }
end

---------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------

function desktop.barClick(x, y, button, double)
    local W, H = gfx.size()
    local barY = H - wm.TASKBAR_H
    local menuX, menuY, menuW, menuH = startMenuRect()

    if y >= barY and x >= 0 and x < TASK_START_W then
        if button == 1 then
            if menu and menu.isOpen() then menu.close() end
            startMenuOpen = not startMenuOpen
            mark()
        end
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
        mark()
        return true
    end

    if y >= barY then
        for _, button2 in ipairs(taskButtons()) do
            if x >= button2.x and x < button2.x + button2.w
                and y >= button2.y and y < button2.y + button2.h then
                local win = button2.win
                if button == 2 then
                    desktop.windowMenu(win, x, y - button2.h)
                    return true
                end
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
        if button == 2 then
            desktop.windowMenu(wm.focused(), x, y - 60)
        end
        return true
    end
    return false
end

function desktop.barScroll(dir, x, y)
    return false
end

--- Mouse press on the desktop. Returns true when it was handled here.
function desktop.mouseDown(x, y, button, double)
    local _, g = iconAt(x, y)

    if button == 2 then
        if g then
            selectedFile = g.entry.file
            openIconMenu(g, x, y)
        else
            selectedFile = nil
            openDesktopMenu(x, y)
        end
        mark()
        return true
    end

    if button == 1 then
        if g then
            selectedFile = g.entry.file
            press = {
                grid = g, x0 = x, y0 = y,
                ex = g.x, ey = g.y, moved = false, double = double,
            }
            mark()
            return true
        end
        if selectedFile then
            selectedFile = nil
            mark()
        end
        return false
    end

    return g ~= nil
end

--- Drag an icon around the workspace. Returns true while an icon is held.
function desktop.mouseDrag(x, y, button)
    if not press or button ~= 1 then return false end
    local dx, dy = x - press.x0, y - press.y0
    if not press.moved then
        -- ignore the tiny jitter of a plain click
        if math.abs(dx) < 4 and math.abs(dy) < 4 then return true end
        press.moved = true
    end
    local m = metrics()
    local aw, ah = areaSize()
    local nx = press.ex + dx
    local ny = press.ey + dy
    if nx > aw - m.w then nx = math.max(0, aw - m.w) end
    if nx < 0 then nx = 0 end
    if ny > ah - m.h then ny = math.max(0, ah - m.h) end
    if ny < 0 then ny = 0 end
    if press.grid.x ~= nx or press.grid.y ~= ny then
        press.grid.x, press.grid.y = nx, ny
        press.grid.entry.x, press.grid.entry.y = nx, ny
        mark()
    end
    return true
end

--- Release: either commit the new position or fire the click action.
function desktop.mouseUp(x, y, button)
    if not press then return false end
    local p = press
    press = nil
    if button ~= 1 then
        mark()
        return true
    end
    if p.moved then
        writeShortcut(p.grid.entry)
        mark()
        return true
    end
    if p.double then
        openEntry(p.grid.entry)
    end
    mark()
    return true
end

--- Keyboard on the desktop (no window focused).
function desktop.key(key)
    if desktopDialog and desktopDialog.dialog then
        if dialogs.key(desktopDialog, key) then mark() end
        return true
    end
    local e = selectedEntry()
    if key == keys.delete and e then
        deleteEntry(e)
        return true
    elseif key == keys.f2 and e then
        renameEntry(e)
        return true
    elseif key == keys.enter and e then
        openEntry(e)
        return true
    elseif key == keys.escape then
        -- Escape unwinds one layer at a time: start menu, then selection.
        if startMenuOpen then
            closeStartMenu()
            return true
        end
        if selectedFile then
            selectedFile = nil
            mark()
            return true
        end
    end
    return false
end

function desktop.char(ch)
    if desktopDialog and desktopDialog.dialog then
        if dialogs.char(desktopDialog, ch) then mark() end
        return true
    end
    return false
end

function desktop.scrollIcons(dir) end

function desktop.isStartMenuOpen() return startMenuOpen end

function desktop.closeMenus()
    closeStartMenu()
    if menu then menu.close() end
    if desktopDialog and desktopDialog.dialog then
        dialogs.close(desktopDialog)
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
        mark()
    end
end

function desktop.powerState() return powerState end

---------------------------------------------------------------------------
-- test hooks
--
-- The headless harness drives the real event path; these only expose state
-- it cannot otherwise observe (there is no API for "which shortcut is at
-- pixel 192,6").
---------------------------------------------------------------------------

if rawget(_G, "CCWIN_DEBUG") then
    --- Snapshot of the loaded shortcuts, in label order.
    function desktop.debugEntries()
        local out = {}
        for _, e in ipairs(entries) do
            out[#out + 1] = {
                file = e.file, kind = e.kind, target = e.target,
                label = e.label, icon = e.icon, x = e.x, y = e.y,
            }
        end
        return out
    end

    --- The icon view currently in effect (cells, in pixels).
    function desktop.debugMetrics()
        local m = metrics()
        return { scale = m.scale, w = m.w, h = m.h }
    end

    --- The modal dialog owned by the desktop, if any.
    function desktop.debugDialog() return desktopDialog end
end

return desktop
