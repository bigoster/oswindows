--- CC-Windows - boot sequence and event loop.
--
-- Loaded by /startup.lua. Wires the modules together, loads settings,
-- then pumps events forever. Any error here unwinds to the shell, but
-- only after the terminal has been put back into text mode.

-- Never boot twice: a console shell may re-run /rom/startup.lua.
_CCWIN_RUNNING = true

local BASE = rawget(_G, "CCWIN_DIR")
if type(BASE) ~= "string" or BASE == "" then BASE = "/ccwin" end

local function path(rel)
    return fs.combine(BASE, rel)
end

local native = term.native()

-- Fail early and clearly when CC-Graphics is missing.
if type(native.setGraphicsMode) ~= "function" or type(native.drawPixels) ~= "function" then
    _CCWIN_RUNNING = nil
    error("CC-Windows requires the CC-Graphics mod (term.setGraphicsMode is missing)", 0)
end

----------------------------------------------------------------------
-- settings
----------------------------------------------------------------------

local DEFAULTS = {
    theme = "light",
    wallpaper = "picture",
    wallpaperPath = "/ccwin/images/landscape.cwp",
    clockSeconds = false,
    lastPath = "/",
    iconSize = "medium",
}

local SETTINGS_PATH = path("settings.cfg")

local settings
do
    local t = {}
    if fs.exists(SETTINGS_PATH) then
        local f = fs.open(SETTINGS_PATH, "r")
        if f then
            local src = f.readAll()
            f.close()
            local ok, data = pcall(textutils.unserialise, src)
            if ok and type(data) == "table" then t = data end
        end
    end
    for k, v in pairs(DEFAULTS) do
        if t[k] == nil then t[k] = v end
    end
    -- Older builds kept the two built-in wallpapers as setting names;
    -- both are image files now, so the choice carries over as the file
    -- showing the very same picture.
    if t.wallpaper == "landscape" then
        t.wallpaper = "picture"
        t.wallpaperPath = "/ccwin/images/landscape.cwp"
    elseif t.wallpaper == "gradient" then
        t.wallpaper = "picture"
        t.wallpaperPath = "/ccwin/images/gradient.cwp"
    end
    settings = t
end

local function saveSettings()
    local f = fs.open(SETTINGS_PATH, "w")
    if not f then return end
    local ok, data = pcall(textutils.serialise, settings)
    if ok then f.writeLine(data) end
    f.close()
end

----------------------------------------------------------------------
-- modules
----------------------------------------------------------------------

local font = dofile(path("core/font.lua"))
local gfx = dofile(path("core/gfx.lua"))
local theme = dofile(path("core/theme.lua"))
local icons = dofile(path("core/icons.lua"))
local widgets = dofile(path("core/widgets.lua"))
local dialogs = dofile(path("core/dialogs.lua"))
local backdrop = dofile(path("core/backdrop.lua"))
local menu = dofile(path("core/menu.lua"))
local wm = dofile(path("core/wm.lua"))
local desktop = dofile(path("core/desktop.lua"))
local fabric = dofile(path("core/fabric.lua"))
local programs = dofile(path("core/programs.lua"))

local APP_LIST = { "console", "explorer", "editor", "paint", "settings", "system", "browser" }
local apps = {}
for _, id in ipairs(APP_LIST) do
    local app = dofile(path("apps/" .. id .. ".lua"))
    apps[app.id or id] = app
end

----------------------------------------------------------------------
-- shared state
----------------------------------------------------------------------

local state = {
    tick = 0,
    pointer = { x = 0, y = 0 },
    lastClick = { x = -1000, y = -1000, tick = -1000 },
    settings = settings,
}

local function applySettings()
    theme.install(settings.theme)
    desktop.rebuild()
    state.onSettingsChanged = nil
    wm.dirty = true
end

state.save = saveSettings
state.applySettings = applySettings

----------------------------------------------------------------------
-- power
----------------------------------------------------------------------

local function leaveGraphics()
    pcall(function()
        if term.current() ~= native then term.redirect(native) end
    end)
    gfx.shutdown()
end

local realShutdown = os.shutdown
local realReboot = os.reboot

local function onPower(action)
    saveSettings()
    leaveGraphics()
    if action == "restart" then
        realReboot()
    else
        realShutdown()
    end
end
state.onPower = onPower

-- Console programs may call these directly; clean up first either way.
os.shutdown = function(...)
    leaveGraphics()
    return realShutdown(...)
end
os.reboot = function(...)
    leaveGraphics()
    return realReboot(...)
end

----------------------------------------------------------------------
-- wiring (the boot itself, guarded so failures restore text mode)
----------------------------------------------------------------------

local function boot()
    gfx.attach(font)
    gfx.init()

    -- The palette must be installed while graphics mode 2 is active.
    theme.install(settings.theme)

    widgets.attach(gfx, theme, icons)
    dialogs.attach(gfx, theme, widgets, icons)
    backdrop.attach(gfx, theme)
    menu.attach {
        gfx = gfx,
        theme = theme,
        widgets = widgets,
        icons = icons,
        wm = wm,
    }

    -- The fabric link needs the window manager to open a console for an
    -- incoming program, and the window manager needs it to route
    -- cee_fabric_message: attach it first, hand it over inside wm.attach.
    fabric.attach { wm = wm }
    programs.attach { wm = wm }

    wm.attach {
        gfx = gfx,
        theme = theme,
        widgets = widgets,
        dialogs = dialogs,
        icons = icons,
        menu = menu,
        apps = apps,
        state = state,
        fabric = fabric,
        programs = programs,
    }

    desktop.attach {
        gfx = gfx,
        theme = theme,
        widgets = widgets,
        icons = icons,
        wm = wm,
        backdrop = backdrop,
        dialogs = dialogs,
        menu = menu,
        state = state,
        settings = settings,
        programs = programs,
    }

    wm.setDesktop(desktop)
    desktop.rebuild()

    -- The OS API for programs running outside a window: a program on a
    -- disc can reach the core apps and modules through this wherever it
    -- lives (ccwin.launch("editor", {path = ...}), dofile(ccwin.path(
    -- "core/widgets.lua")) and so on).
    _G.ccwin = {
        dir = BASE,
        path = path,
        launch = function(appId, opts) return wm.create(appId, opts) end,
        open = function(p, opts) return programs.open(p, opts) end,
    }

    -- The global term redirect follows the focused window: consoles own
    -- it while focused, everything else draws through the native term.
    wm.onFocus = function(win)
        local target = native
        if win and win.instance and win.instance.redirectTarget then
            target = win.instance.redirectTarget
        end
        if term.current() ~= target then
            pcall(term.redirect, target)
        end
    end

    desktop.updateClock()
    wm.render()

    -- Test hook: expose internals so the headless test harness can poke
    -- at window geometry without simulating every pixel of a click.
    if rawget(_G, "CCWIN_DEBUG") then
        _G.CCWIN_DEBUG_STATE = {
            wm = wm, desktop = desktop, apps = apps, menu = menu,
            state = state, gfx = gfx, theme = theme, native = native,
            fabric = fabric, programs = programs,
        }
    end

    --------------------------------------------------------------------
    -- event loop
    --------------------------------------------------------------------

    local tickTimer = os.startTimer(0.25)
    local clockTimer = os.startTimer(1)

    while true do
        -- A shell prompt may have stolen the redirect while unfocused;
        -- put it back before anything can draw through it.
        local win = wm.focused()
        local target = (win and win.instance and win.instance.redirectTarget) or native
        if term.current() ~= target then pcall(term.redirect, target) end

        -- pullEventRaw: "terminate" (Ctrl+T) belongs to the focused
        -- console, it must not kill the window manager.
        local ev = table.pack(os.pullEventRaw())

        if ev[1] == "timer" then
            if ev[2] == tickTimer then
                tickTimer = os.startTimer(0.25)
                state.tick = state.tick + 1
            elseif ev[2] == clockTimer then
                clockTimer = os.startTimer(1)
                desktop.updateClock()
                -- greet fabric peers we have not met yet; a failure here
                -- must never take the desktop down with it
                pcall(fabric.poll)
            end
        end

        wm.broadcast(ev)
        wm.handle(ev)
        if wm.dirty then wm.render() end
    end
end

local ok, err = pcall(boot)
if not ok then
    _CCWIN_RUNNING = nil
    pcall(function()
        if term.current() ~= native then term.redirect(native) end
    end)
    gfx.shutdown()
    error(err, 0)
end
