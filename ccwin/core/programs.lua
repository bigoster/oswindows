--- CC-Windows - programs: is this file one of ours, and how do we open it?
--
-- Two rules, in this order:
--
--   1. A program is written for CC-Windows when its FIRST LINE says so:
--
--        --- CC-Windows - Solitaire
--
--      That is all detection is: looking at a file never runs it, so
--      dropping scripts into ccwin/apps (or onto the desktop) cannot fire
--      off code just by being scanned.
--
--   2. Opening one happens in two stages. The header'd file is loaded in
--      a sandbox first - no fs writes, no timers, print is a no-op - just
--      to see whether it returns an app table (id, name, create: the
--      same contract ccwin/apps/*.lua follows). If it does, the file is
--      loaded again, for real this time, with the full environment the
--      OS's own programs get, and that app is given a real window with
--      a title bar and a taskbar button. The sandboxed probe means the
--      *decision* never causes side effects, and the real run happens
--      exactly once either way: an app is loaded once for real, and a
--      non-app is handed straight to the console (never loaded twice).
--      If the file has no header at all, it just runs in the console.
--
-- A program opened this way is handed the shared context, wherever it
-- lives: one on a disc still reaches every core app and module through
-- `ctx` (and through the `ccwin` global that main.lua installs), so a
-- copy on a drive is exactly as powerful as one in /ccwin/apps.
local programs = {}

local wm

local function noop() end

--- The shallow copy keeps a loading program from scribbling on the
-- tables the OS itself is using while we look at it.
local function copyOf(t)
    if type(t) ~= "table" then return nil end
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

--- Globals a program module may touch while it is only being inspected.
-- Everything that can change the machine (fs writes, os timers, shell,
-- term, peripherals, dofile/load) is simply not here: touching it raises
-- an error, the load fails, and the program is treated as an ordinary
-- one instead.
local sandbox
local function safeEnv()
    if sandbox then return sandbox end
    sandbox = {
        print = noop, write = noop, printError = noop,
        math = copyOf(math), string = copyOf(string), table = copyOf(table),
        bit32 = copyOf(bit32), colors = copyOf(colors), colours = copyOf(colours),
        keys = copyOf(keys), textutils = copyOf(textutils),
        vector = copyOf(vector), coroutine = copyOf(coroutine),
        tonumber = tonumber, tostring = tostring, type = type,
        ipairs = ipairs, pairs = pairs, next = next, select = select,
        pcall = pcall, xpcall = xpcall, error = error, assert = assert,
        setmetatable = setmetatable, getmetatable = getmetatable,
        rawget = rawget, rawset = rawset, rawequal = rawequal,
        rawlen = rawlen,
        os = {
            clock = os.clock, time = os.time, date = os.date,
            getComputerID = os.getComputerID,
            getComputerLabel = os.getComputerLabel,
            version = os.version,
        },
        fs = {
            combine = fs.combine, getName = fs.getName, getDir = fs.getDir,
            exists = fs.exists, isDir = fs.isDir, list = fs.list,
            getSize = fs.getSize, getFreeSpace = fs.getFreeSpace,
            getCapacity = fs.getCapacity,
        },
    }
    sandbox._G = sandbox
    -- The OS entry point as an inspection run sees it: where the OS
    -- lives and how to build a path inside it - but deliberately *not*
    -- launch/open, so a file being looked at cannot open windows just by
    -- being loaded. The real run (loadReal below) gets the full global.
    local real = rawget(_G, "ccwin")
    sandbox.ccwin = {
        dir = (type(real) == "table" and real.dir) or "/ccwin",
        path = (type(real) == "table" and real.path)
            or function(p) return fs.combine("/ccwin", tostring(p)) end,
    }
    return sandbox
end

function programs.attach(d)
    wm = d and d.wm or nil
end

local function firstLine(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local line = f.readLine()
    f.close()
    return line
end

--- True when the file's first line claims to be a CC-Windows program.
-- Purely textual: nothing is executed to find this out.
function programs.isOS(path)
    if type(path) ~= "string" or path == "" then return false end
    if fs.isDir(path) then return false end
    local line = firstLine(path)
    if not line then return false end
    line = line:gsub("^%s+", "")
    return line:match("^%-%-+%s*CC%-Windows") ~= nil
end

--- Load the file in the sandbox and see if it really is an app.
-- Returns the app table, or nil plus the reason it is not one.
function programs.loadApp(path)
    local f = fs.open(path, "r")
    if not f then return nil, "cannot read it" end
    local src = f.readAll()
    f.close()
    if type(src) ~= "string" or src == "" then return nil, "it is empty" end

    local fn, err = load(src, "@" .. path, "t", safeEnv())
    if not fn then return nil, tostring(err) end
    local ok, value = pcall(fn)
    if not ok then return nil, tostring(value) end
    if type(value) ~= "table" then return nil, "it returns nothing" end
    if type(value.create) ~= "function" then return nil, "it has no create()" end
    if type(value.name) ~= "string" then return nil, "it has no name" end
    return value
end

--- The same file, loaded the way it will really run.
-- Full environment - fs, dofile, the `ccwin` global, everything - so a
-- program on a disc can pull in its own libraries exactly like one in
-- ccwin/apps. Only called after the sandboxed probe said "yes, this is an
-- app", so the real side effects of the top level happen exactly once.
-- Returns the app table, or nil plus the reason.
function programs.loadReal(path)
    local f = fs.open(path, "r")
    if not f then return nil, "cannot read it" end
    local src = f.readAll()
    f.close()
    if type(src) ~= "string" or src == "" then return nil, "it is empty" end

    local fn, err = load(src, "@" .. path, "t", _G)
    if not fn then return nil, tostring(err) end
    local ok, value = pcall(fn)
    if not ok then return nil, tostring(value) end
    if type(value) ~= "table" or type(value.create) ~= "function"
        or type(value.name) ~= "string" then
        return nil, "it stopped being an app"
    end
    return value
end

--- Open a program the way the OS means it.
-- Our own programs get a window, everything else runs in the console.
-- Returns the window that was created (nil when there is no window
-- manager yet).
function programs.open(path, opts)
    if not wm or type(path) ~= "string" then return nil end
    if fs.isDir(path) then return wm.create("explorer", { path = path }) end

    if programs.isOS(path) then
        local app = programs.loadApp(path)   -- sandbox: is it really one?
        if app then
            app = programs.loadReal(path)    -- yes: load it for real
        end
        if app then
            opts = opts or {}
            if opts.path == nil then opts.path = path end
            -- the program can find its own folder (and its own libs, even
            -- on a disc) the same way a shell-run program does
            if type(shell) == "table" and shell.setRunningProgram then
                pcall(shell.setRunningProgram, path)
            end
            return wm.create(app, opts)
        end
        -- claims to be ours but returns no app: run it like anything else
    end
    return wm.create("console", { program = path })
end

--- The CC-Windows programs sitting in `dir` (used to link them on the
-- desktop). Sorted by name so links appear in a stable order.
function programs.scan(dir)
    local out = {}
    if type(dir) ~= "string" or dir == "" then return out end
    if not fs.exists(dir) or not fs.isDir(dir) then return out end
    local ok, list = pcall(fs.list, dir)
    if not ok or type(list) ~= "table" then return out end
    table.sort(list)
    for _, name in ipairs(list) do
        if name:match("%.lua$") then
            local path = fs.combine(dir, name)
            if programs.isOS(path) then out[#out + 1] = path end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- picture icons
--
-- A program may ship the picture its desktop link shows - inside itself, as
-- a run of comment lines, or beside it, as <name>.nfp / <name>.cwp (the two
-- formats Paint writes). Resolving an icon only ever reads text, so looking
-- at a program to find its picture never runs it.
--
--     --- icon:
--     --- 000f000
--     --- 00ff f00        (one comment line per picture row, one hex
--     --- ...              digit per pixel, the same digits as NFP)
---------------------------------------------------------------------------

local MAX_ICON = 64    -- desktop icons are small; a bigger picture is not one

--- Picture rows, checked: rectangular, hex digits, tiny.
-- The rows themselves are what gets stored in a .lnk, so this doubles as
-- the check on a picture read back from disk. Returns the rows or nil.
function programs.iconRows(rows)
    if type(rows) ~= "table" then return nil end
    local h = #rows
    if h < 1 or h > MAX_ICON then return nil end
    local w = type(rows[1]) == "string" and #rows[1] or 0
    if w < 1 or w > MAX_ICON then return nil end
    for i = 1, h do
        local r = rows[i]
        if type(r) ~= "string" or #r ~= w or not r:match("^%x+$") then
            return nil
        end
    end
    return rows
end

--- A picture file (NFP: one hex digit per pixel; CWP: Paint's "CCWIN1"
-- header plus two hex digits per pixel). Returns its rows or nil.
local function pictureFile(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local rows = {}
    local first = f.readLine()
    if not first then
        f.close()
        return nil
    end
    if first:match("^CCWIN1") then
        local w = tonumber(first:match("^CCWIN1%s+(%d+)"))
        local h = tonumber(first:match("^CCWIN1%s+%d+%s+(%d+)"))
        if not w or not h or w < 1 or h < 1 or w > MAX_ICON or h > MAX_ICON then
            f.close()
            return nil
        end
        for _ = 1, h do
            local line = f.readLine()
            if not line then break end
            local out = {}
            for x = 1, math.min(w, math.floor(#line / 2)) do
                -- a canvas byte is the palette index itself, i.e. exactly
                -- the digit NFP uses for that colour
                local v = tonumber(line:sub(x * 2 - 1, x * 2), 16) or 15
                if v > 15 then v = 15 end
                out[x] = string.format("%x", v)
            end
            rows[#rows + 1] = table.concat(out)
        end
    else
        rows[1] = first
        while true do
            local line = f.readLine()
            if not line then break end
            rows[#rows + 1] = line
        end
    end
    f.close()
    return programs.iconRows(rows)
end

--- The picture written into the program as comment lines:
--     --- icon:
--     --- 00f
-- The block ends at the first line that is not a hex comment row, so the
-- program stays ordinary Lua either way.
local function embeddedIcon(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local rows, reading = nil, false
    while true do
        local line = f.readLine()
        if not line then break end
        local body = line:match("^%-%-%-?%s*(.*)$")
        if not body then
            if reading then break end
        elseif not reading then
            if body:lower():match("^icon:%s*$") then
                reading, rows = true, {}
            end
        elseif body:match("^%x+$") then
            rows[#rows + 1] = body
        else
            break
        end
    end
    f.close()
    return programs.iconRows(rows)
end

--- A picture sitting beside the program: mine.lua -> mine.nfp / mine.cwp.
local function siblingIcon(path)
    local dir = fs.getDir(path)
    local name = fs.getName(path)
    local stem = name:match("(.+)%.[^%.]+$") or name
    for _, suffix in ipairs { ".nfp", ".cwp" } do
        local pic = fs.combine(dir, stem .. suffix)
        if fs.exists(pic) and not fs.isDir(pic) then
            local rows = pictureFile(pic)
            if rows then return rows end
        end
    end
    return nil
end

--- The picture a program ships for its desktop link, or nil when it has
-- none (the link then keeps the usual glyph icon).
function programs.icon(path)
    if type(path) ~= "string" or path == "" or fs.isDir(path) then
        return nil
    end
    local ok, rows = pcall(function()
        return embeddedIcon(path) or siblingIcon(path)
    end)
    if ok then return rows end
    return nil
end

return programs
