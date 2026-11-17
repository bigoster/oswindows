--- CC-Windows - boot sequence and event loop.
--
-- Loaded by /startup.lua. Wires the modules together, loads settings,
-- then pumps events forever. A failure while booting leaves the boot
-- marker behind, so the next start comes up in safe mode instead of
-- repeating the same crash. The event loop itself is fault isolated: one
-- bad redraw or input handler can never take the whole desktop down.

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
-- safe IO, boot marker and error log
----------------------------------------------------------------------

local storage = dofile(path("core/storage.lua"))

local SETTINGS_PATH = path("settings.cfg")
local BOOT_MARKER = path("booting")
local LOG_PATH = path("last-error.log")
local SETTINGS_MAX = 65536

local crashedLastBoot = storage.exists(BOOT_MARKER)
storage.write(BOOT_MARKER, tostring(os.time()), { backup = false })

local lastFault, sameFaults = nil, 0

--- Record a fault without flooding the disk. Repeats are written every
--- twentieth time; the first one always lands in the log.
local function logFault(where, err)
    local msg = tostring(err or "unknown error"):gsub("[\r\n]+", " ")
    if msg == lastFault then
        sameFaults = sameFaults + 1
    else
        lastFault, sameFaults = msg, 0
    end
    if sameFaults > 0 and sameFaults % 20 ~= 0 then return end
    storage.append(LOG_PATH, "[" .. tostring(os.time()) .. "] " .. where .. ": " .. msg .. "\n",
        storage.LOG_MAX)
end

----------------------------------------------------------------------
-- settings (schema v2: bounded read, validated values, migrations)
----------------------------------------------------------------------

local DEFAULTS = {
    theme = "light",
    wallpaper = "picture",
    wallpaperPath = "/ccwin/images/landscape.cwp",
    wallpaperColour = "#3A6EA5",
    accentColour = "#0078D4",
    clockSeconds = false,
    lastPath = "/",
    iconSize = "medium",
}

local settingsWarnings = {}

local function isHexColour(v)
    return type(v) == "string" and v:match("^#%x%x%x%x%x%x$") ~= nil
end

local function isColour(v)
    if isHexColour(v) then return true end
    return type(v) == "number" and v >= 0 and v <= 255 and v == math.floor(v)
end

local function isPath(v)
    return type(v) == "string" and v ~= "" and #v <= 255 and not v:find("%c")
end

local settings
do
    local t = {}
    local src = storage.read(SETTINGS_PATH, SETTINGS_MAX)
    if src then
        local ok, data = pcall(textutils.unserialise, src)
        if ok and type(data) == "table" then
            t = data
        else
            settingsWarnings[#settingsWarnings + 1] =
                "settings.cfg is unreadable; defaults restored in memory"
        end
    elseif storage.exists(SETTINGS_PATH) then
        settingsWarnings[#settingsWarnings + 1] =
            "settings.cfg is too large; defaults restored in memory"
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

    local function repair(key, fallback, valid)
        local v = t[key]
        if v == nil then
            t[key] = fallback
        elseif not valid(v) then
            settingsWarnings[#settingsWarnings + 1] = "settings." .. key .. " repaired"
            t[key] = fallback
        end
    end

    repair("theme", DEFAULTS.theme, function(v) return v == "light" or v == "dark" end)
    repair("wallpaper", DEFAULTS.wallpaper,
        function(v) return v == "picture" or v == "solid" end)
    repair("wallpaperPath", DEFAULTS.wallpaperPath, isPath)
    repair("wallpaperColour", DEFAULTS.wallpaperColour, isColour)
    repair("accentColour", DEFAULTS.accentColour, isColour)
    repair("clockSeconds", DEFAULTS.clockSeconds, function(v) return type(v) == "boolean" end)
    repair("lastPath", DEFAULTS.lastPath, isPath)
    repair("iconSize", DEFAULTS.iconSize,
        function(v) return v == "small" or v == "medium" or v == "large" end)

    -- Unknown keys are kept: a newer build may have written them and an
    -- older one must not throw them away.
    t.schema = 2
    settings = t

    if crashedLastBoot then
        -- Never repeat a boot that crashed halfway: use known-good values
        -- in memory only. The user's file is left untouched until they
        -- change something themselves.
        for k, v in pairs(DEFAULTS) do settings[k] = v end
        settings.schema = 2
        settingsWarnings[#settingsWarnings + 1] =
            "previous boot did not finish; safe defaults in use"
    end

    for i = 1, #settingsWarnings do
        storage.append(LOG_PATH, "[boot] " .. settingsWarnings[i] .. "\n", storage.LOG_MAX)
    end
end

local function saveSettings()
    local ok, data = pcall(textutils.serialise, settings)
    if not ok or type(data) ~= "string" then return false end
    return storage.write(SETTINGS_PATH, data .. "\n", { backup = true })
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
local picture = dofile(path("core/picture.lua"))

-- The 162 KB PNG/JPEG/WebP decoder is only needed when a raster wallpaper
-- is actually chosen, so it loads on first use behind this proxy.
local image = {}
do
    local real
    local function ensure()
        if real then return real end
        local ok, mod = pcall(dofile, path("core/image.lua"))
        if ok and type(mod) == "table" then real = mod end
        return real
    end
    function image.loaded() return real ~= nil end
    function image.load() return ensure() end
    function image.sniff(data)
        local m = ensure()
        if not m then return nil end
        return m.sniff(data)
    end
    function image.decode(...)
        local m = ensure()
        if not m then error("the image decoder is missing", 0) end
        return m.decode(...)
    end
end

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
    local ok, err = pcall(theme.install, settings.theme, settings.accentColour,
        settings.wallpaperColour)
    if not ok then
        logFault("theme", err)
        pcall(theme.install, DEFAULTS.theme, DEFAULTS.accentColour, DEFAULTS.wallpaperColour)
    end
    local ok2, err2 = pcall(desktop.rebuild)
    if not ok2 then logFault("desktop.rebuild", err2) end
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
    -- Older builds stored colours as palette indices; Settings speaks hex
    -- now, so carry the same colours over before installing the palette.
    if type(settings.wallpaperColour) == "number" then
        settings.wallpaperColour = theme.hexOf(settings.wallpaperColour) or DEFAULTS.wallpaperColour
        saveSettings()
    end
    if type(settings.accentColour) == "number" then
        settings.accentColour = theme.hexOf(settings.accentColour) or DEFAULTS.accentColour
        saveSettings()
    end
    local okTheme, themeErr = pcall(theme.install, settings.theme, settings.accentColour,
        settings.wallpaperColour)
    if not okTheme then
        logFault("theme", themeErr)
        pcall(theme.install, DEFAULTS.theme, DEFAULTS.accentColour, DEFAULTS.wallpaperColour)
    end

    widgets.attach(gfx, theme, icons)
    dialogs.attach(gfx, theme, widgets, icons)
    backdrop.attach(gfx, theme, image, picture)
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
    fabric.attach { wm = wm, storage = storage }
    programs.attach { wm = wm, picture = picture }

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
        storage = storage,
        picture = picture,
        image = image,
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
        storage = storage,
        picture = picture,
        image = image,
        safeMode = crashedLastBoot,
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

    -- The first frame reached the screen: this boot is no longer suspect.
    storage.delete(BOOT_MARKER)

    if crashedLastBoot then
        pcall(desktop.alert, "Recovery",
            "CC-Windows did not finish starting last time.\n"
                .. "It is running with safe default settings; your\n"
                .. "settings file has not been changed.")
    end

    -- Test hook: expose internals so the headless test harness can poke
    -- at window geometry without simulating every pixel of a click.
    if rawget(_G, "CCWIN_DEBUG") then
        _G.CCWIN_DEBUG_STATE = {
            wm = wm, desktop = desktop, apps = apps, menu = menu,
            state = state, gfx = gfx, theme = theme, native = native,
            fabric = fabric, programs = programs,
            storage = storage, picture = picture, image = image,
        }
    end

    --------------------------------------------------------------------
    -- event loop
    --------------------------------------------------------------------

    local tickTimer = os.startTimer(0.25)
    local clockTimer = os.startTimer(1)
    local frameTimer
    local renderFaults = 0

    --- Render at most once per drag burst. Immediate for every other
    --- event, so clicks and typing still echo at full speed.
    local function renderNow()
        if frameTimer then
            pcall(os.cancelTimer, frameTimer)
            frameTimer = nil
        end
        if not wm.dirty then return true end
        local ok, err = pcall(wm.render)
        if ok then
            renderFaults = 0
            return true
        end
        logFault("render", err)
        wm.dirty = true
        renderFaults = renderFaults + 1
        if renderFaults == 5 then
            -- Last-resort recovery: known-good palette and wallpaper.
            pcall(theme.install, DEFAULTS.theme, DEFAULTS.accentColour,
                DEFAULTS.wallpaperColour)
            pcall(desktop.rebuild)
            pcall(gfx.resetClip)
        end
        return false
    end

    while true do
        -- A shell prompt may have stolen the redirect while unfocused;
        -- put it back before anything can draw through it.
        local win = wm.focused()
        local target = (win and win.instance and win.instance.redirectTarget) or native
        if term.current() ~= target then pcall(term.redirect, target) end

        -- pullEventRaw: "terminate" (Ctrl+T) belongs to the focused
        -- console, it must not kill the window manager.
        local ev = table.pack(os.pullEventRaw())
        local name = ev[1]
        local internalFrame = false

        if name == "timer" then
            if frameTimer and ev[2] == frameTimer then
                -- Our own coalescing timer: draw and do not wake apps.
                frameTimer = nil
                internalFrame = true
            elseif ev[2] == tickTimer then
                tickTimer = os.startTimer(0.25)
                state.tick = state.tick + 1
            elseif ev[2] == clockTimer then
                clockTimer = os.startTimer(1)
                local ok, err = pcall(desktop.updateClock)
                if not ok then logFault("clock", err) end
                -- greet fabric peers we have not met yet; a failure here
                -- must never take the desktop down with it
                pcall(fabric.poll)
            end
        end

        if internalFrame then
            renderNow()
        else
            local okB, errB = pcall(wm.broadcast, ev)
            if not okB then
                logFault("broadcast", errB)
                wm.dirty = true
            end
            local okH, errH = pcall(wm.handle, ev)
            if not okH then
                logFault("handle", errH)
                wm.dirty = true
            end

            if (name == "mouse_drag" or name == "mouse_move") and wm.dirty then
                if not frameTimer then frameTimer = os.startTimer(0.03) end
            else
                renderNow()
            end
        end
    end
end

local ok, err = pcall(boot)
if not ok then
    storage.append(LOG_PATH, "[" .. tostring(os.time()) .. "] boot: "
        .. tostring(err):gsub("[\r\n]+", " ") .. "\n", storage.LOG_MAX)
    _CCWIN_RUNNING = nil
    pcall(function()
        if term.current() ~= native then term.redirect(native) end
    end)
    gfx.shutdown()
    error(err, 0)
end
