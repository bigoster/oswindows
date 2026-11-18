-- CC-Windows boot hook.
--
-- Copy this file and the ccwin/ folder to the root of a computer
-- (CC:CE with CC-Graphics installed) and reboot. This runs from
-- /rom/startup.lua like any other user startup program.

-- The console windows re-run /rom/startup.lua inside their own shell;
-- once the OS is up, never boot it a second time.
if rawget(_G, "_CCWIN_RUNNING") then return end

-- Find ccwin/ next to this file, whatever directory we were started from.
local dir = fs.getDir(shell.getRunningProgram())
if dir == "" or dir == "." then dir = "/" end
CCWIN_DIR = fs.combine(dir, "ccwin")

_CCWIN_RUNNING = true

-- Finish an interrupted update before the OS reads any of its modules. The
-- updater writes a journal before it swaps files and calls update.recover()
-- here on the next boot: old files come back, staging is discarded.
do
    local okMod, update = pcall(dofile, fs.combine(CCWIN_DIR, "core/update.lua"))
    if okMod and type(update) == "table" and type(update.recover) == "function" then
        local ok, restored, journal = pcall(update.recover, CCWIN_DIR)
        if ok and journal then
            pcall(function()
                local logPath = fs.combine(CCWIN_DIR, "last-error.log")
                local old = ""
                if fs.exists(logPath) then
                    local h = fs.open(logPath, "r")
                    if h then old = h.readAll() or ""; h.close() end
                end
                if #old > 32768 then old = old:sub(#old - 32767) end
                local h = fs.open(logPath, "w")
                if h then
                    h.write(old .. "[" .. tostring(os.time()) .. "] update: rolled back "
                        .. tostring(restored or 0) .. " file(s) after an interrupted install\n")
                    h.close()
                end
            end)
        end
    end
end

local ok, err = pcall(dofile, fs.combine(CCWIN_DIR, "main.lua"))
if not ok then
    _CCWIN_RUNNING = nil
    pcall(function() term.redirect(term.native()) end)
    pcall(function() term.setGraphicsMode(0) end)
    error(err, 0)
end
