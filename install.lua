--- CC-Windows installer.
--
-- Fetches every file of the OS from GitHub over HTTP and lays them out on
-- the filesystem. Every Lua file is checked to be really compilable before
-- it is installed; /ccwin/version is plain data (the marker the in-OS
-- updater compares with GitHub). Re-running it upgrades an existing
-- install in place; /ccwin/settings.cfg is never touched.
--
-- Bootstrap on a CraftOS computer (CC:CE + CC-Graphics, http enabled):
--
--   wget https://raw.githubusercontent.com/OWNER/REPO/BRANCH/install.lua install.lua
--   install.lua
--
-- or, without saving a copy:
--
--   wget run https://raw.githubusercontent.com/OWNER/REPO/BRANCH/install.lua
--
-- Why downloads go through a temporary name: the ROM's wget refuses to
-- overwrite an existing file ("File already exists") and every one of its
-- failure paths is a bare `return`, so shell.run() reports success even when
-- the fetch failed. We therefore fetch to <dst>.new, check the bytes really
-- are a compilable Lua chunk, and only then replace the destination.

---------------------------------------------------------------------------
-- Repository: edit these three lines to point at your GitHub repo.
---------------------------------------------------------------------------

local OWNER  = "bigoster"
local REPO   = "oswindows"
local BRANCH = "main"

---------------------------------------------------------------------------

local BASE = "https://raw.githubusercontent.com/"
    .. OWNER .. "/" .. REPO .. "/" .. BRANCH

-- { source path inside the repository, destination on the computer }
local FILES = {
    { "ccwin/startup.lua",   "/startup.lua" },
    { "ccwin/main.lua",      "/ccwin/main.lua" },
    { "ccwin/version",       "/ccwin/version" },

    { "ccwin/core/backdrop.lua", "/ccwin/core/backdrop.lua" },
    { "ccwin/core/dialogs.lua",  "/ccwin/core/dialogs.lua" },
    { "ccwin/core/desktop.lua",  "/ccwin/core/desktop.lua" },
    { "ccwin/core/fabric.lua",   "/ccwin/core/fabric.lua" },
    { "ccwin/core/font.lua",     "/ccwin/core/font.lua" },
    { "ccwin/core/gfx.lua",      "/ccwin/core/gfx.lua" },
    { "ccwin/core/icons.lua",    "/ccwin/core/icons.lua" },
    { "ccwin/core/menu.lua",     "/ccwin/core/menu.lua" },
    { "ccwin/core/programs.lua", "/ccwin/core/programs.lua" },
    { "ccwin/core/theme.lua",    "/ccwin/core/theme.lua" },
    { "ccwin/core/widgets.lua",  "/ccwin/core/widgets.lua" },
    { "ccwin/core/wm.lua",       "/ccwin/core/wm.lua" },

    { "ccwin/apps/console.lua",  "/ccwin/apps/console.lua" },
    { "ccwin/apps/editor.lua",   "/ccwin/apps/editor.lua" },
    { "ccwin/apps/explorer.lua", "/ccwin/apps/explorer.lua" },
    { "ccwin/apps/paint.lua",    "/ccwin/apps/paint.lua" },
    { "ccwin/apps/settings.lua", "/ccwin/apps/settings.lua" },
    { "ccwin/apps/system.lua",   "/ccwin/apps/system.lua" },
    { "ccwin/apps/browser.lua",  "/ccwin/apps/browser.lua" },

    { "ccwin/programs/fabric_agent.lua", "/ccwin/programs/fabric_agent.lua" },
}

local function die(msg)
    error(msg, 0)
end

--- Read a file back. Lua must really compile (so a truncated download or an
--- HTML error page is caught), non-Lua files (ccwin/version) only have to
--- be there and be non-empty - nothing is ever executed here.
local function verify(path, isLua)
    local h = fs.open(path, "r")
    if not h then
        return nil, "cannot read it back"
    end
    local src = h.readAll()
    h.close()

    if not src or src == "" then
        return nil, "it is empty"
    end
    if not isLua then
        return true
    end
    local fn, err = load(src, "@" .. path)
    if not fn then
        return nil, "it does not compile: " .. tostring(err)
    end
    return true
end

--- Fetch one file into place. Returns nothing; raises on failure.
local function install(src, dst, index, total)
    local url = BASE .. "/" .. src
    local tmp = dst .. ".new"

    -- wget will not overwrite, so start from a clean temp name.
    if fs.exists(tmp) then fs.delete(tmp) end

    local dir = dst:match("^(.*)/[^/]*$")
    if dir and dir ~= "" then fs.makeDir(dir) end

    local started = os.clock()
    if not shell.run("wget", url, tmp) then
        die(("wget is missing or failed to start (%s)"):format(url))
    end

    if not fs.exists(tmp) then
        die(("download failed: %s\n" ..
             "  check the repo URL, branch and that http is enabled."):format(url))
    end

    local ok, why = verify(tmp, src:match("%.lua$") ~= nil)
    if not ok then
        fs.delete(tmp)
        die(("bad download: %s\n  %s"):format(url, why))
    end

    if fs.exists(dst) then fs.delete(dst) end
    fs.move(tmp, dst)

    io.write(("  [%2d/%d] %s  (%.1fs)\n"):format(
        index, total, dst, os.clock() - started))
end

local function main()
    io.write("CC-Windows installer\n")
    io.write(("  %s/%s @ %s\n"):format(OWNER, REPO, BRANCH))

    if OWNER == "YOUR_GITHUB_NAME" then
        die("Set OWNER, REPO and BRANCH at the top of install.lua first.")
    end
    if not http then
        die("wget needs the http API.\n" ..
            "  Set http.enabled to true in CC:Tweaked's server config.")
    end
    if not shell or not shell.run then
        die("This program must be run from the shell, not from the Lua REPL.")
    end

    local total = #FILES
    io.write(("  %d files\n\n"):format(total))

    for i = 1, total do
        install(FILES[i][1], FILES[i][2], i, total)
    end

    -- Final sweep: nothing may be left behind.
    for i = 1, total do
        local dst = FILES[i][2]
        if not fs.exists(dst) then
            die("missing after install: " .. dst)
        end
        if fs.exists(dst .. ".new") then
            fs.delete(dst .. ".new")
        end
    end

    io.write(("\nInstalled %d/%d files.\n"):format(total, total))
    io.write("Reboot to start CC-Windows:\n")
    io.write("  reboot\n")
end

main()
