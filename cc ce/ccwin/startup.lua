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

local ok, err = pcall(dofile, fs.combine(CCWIN_DIR, "main.lua"))
if not ok then
    _CCWIN_RUNNING = nil
    pcall(function() term.redirect(term.native()) end)
    pcall(function() term.setGraphicsMode(0) end)
    error(err, 0)
end
