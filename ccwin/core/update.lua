--- Transactional update support.
--
-- The updater never writes a live system file while it is downloading. It
-- stages verified bytes under /ccwin/.update/new, writes a journal, and only
-- then swaps files into place. Each replaced file is moved to
-- /ccwin/.update/old first, so a power cut at any point can be undone:
-- startup.lua calls update.recover() before main.lua runs.
--
-- Journal format (plain text, one destination per line):
--
--   CCWU1
--   /ccwin/main.lua
--   /ccwin/version
--
-- Every path is derived from the destination, so the journal cannot point
-- the recovery code outside /ccwin or the root startup file.

local update = {}

local MARKER = "CCWU1"

local function validDst(p)
    if p == "/startup.lua" then return true end
    if type(p) ~= "string" then return false end
    local rest = p:match("^/ccwin/(.+)$")
    if not rest then return false end
    for seg in rest:gmatch("[^/]+") do
        if seg == "." or seg == ".." or not seg:match("^[%w._-]+$") then
            return false
        end
    end
    local n, slashes = 0, 0
    for _ in rest:gmatch("[^/]+") do n = n + 1 end
    for _ in rest:gmatch("/") do slashes = slashes + 1 end
    return n > 0 and slashes == n - 1
end

function update.validDst(p) return validDst(p) end

local function exists(p)
    local ok, yes = pcall(fs.exists, p)
    return ok and yes == true
end

local function isDir(p)
    local ok, yes = pcall(fs.isDir, p)
    return ok and yes == true
end

function update.exists(p) return exists(p) end
function update.isDir(p) return isDir(p) end

local function parent(p)
    return p:match("^(.*)/[^/]*$")
end

--- fs.makeDir on CraftOS creates parents, but the test filesystem does not.
local function mkdirp(p)
    if not p or p == "" or p == "/" then return true end
    if exists(p) then return isDir(p) end
    mkdirp(parent(p))
    pcall(fs.makeDir, p)
    return isDir(p)
end

function update.mkdirp(p) return mkdirp(p) end

local function readAll(p)
    if not exists(p) or isDir(p) then return nil end
    local okOpen, f = pcall(fs.open, p, "r")
    if not okOpen or not f then return nil end
    local ok, data = pcall(f.readAll)
    pcall(f.close)
    if ok and type(data) == "string" then return data end
    return nil
end

function update.read(p) return readAll(p) end

local function writeAll(p, data)
    if not mkdirp(parent(p)) then return false, "cannot create " .. tostring(parent(p)) end
    local tmp = p .. ".new"
    if exists(tmp) then pcall(fs.delete, tmp) end
    local okOpen, f = pcall(fs.open, tmp, "w")
    if not okOpen or not f then return false, "cannot write " .. tmp end
    local ok, err = pcall(f.write, data)
    if ok then ok, err = pcall(f.close) end
    if not ok then
        pcall(fs.delete, tmp)
        return false, tostring(err)
    end
    if exists(p) then pcall(fs.delete, p) end
    local okMove, why = pcall(fs.move, tmp, p)
    if not okMove or not exists(p) or exists(tmp) then
        pcall(fs.delete, tmp)
        return false, tostring(why or p)
    end
    return true
end

function update.write(p, data) return writeAll(p, data) end

local function moveFile(from, to)
    if not exists(from) or isDir(from) then return false, "missing " .. from end
    if not mkdirp(parent(to)) then return false, "cannot create " .. tostring(parent(to)) end
    if exists(to) then pcall(fs.delete, to) end
    local ok, why = pcall(fs.move, from, to)
    if ok and exists(to) and not exists(from) then return true end
    return false, tostring(why or ("cannot move " .. from))
end

function update.move(from, to) return moveFile(from, to) end

--- Remove a file, or a directory and everything under it.
function update.remove(p)
    if not exists(p) then return true end
    if not isDir(p) then
        pcall(fs.delete, p)
        return not exists(p)
    end
    local ok, names = pcall(fs.list, p)
    if ok and type(names) == "table" then
        for _, name in ipairs(names) do
            update.remove(p .. "/" .. name)
        end
    end
    pcall(fs.delete, p)
    return not exists(p)
end

function update.dir(base) return base .. "/.update" end
function update.journalPath(base) return base .. "/.update/journal" end

--- Where a destination is staged and backed up. `rel` is also the journal
-- key: startup.lua is at the computer root, everything else under ccwin/.
function update.rel(dst)
    if dst == "/startup.lua" then return "startup.lua" end
    return dst:match("^/ccwin/(.+)$")
end

function update.paths(base, dst)
    local rel = update.rel(dst)
    if not rel then return nil end
    return {
        staged = base .. "/.update/new/" .. rel,
        backup = base .. "/.update/old/" .. rel,
    }
end

function update.stage(base, dst)
    local p = update.paths(base, dst)
    return p and p.staged or nil
end

function update.backup(base, dst)
    local p = update.paths(base, dst)
    return p and p.backup or nil
end

--- Drop all staging state. Only safe when no journal exists.
function update.clean(base)
    update.remove(base .. "/.update")
    update.remove(base .. "/.installed-manifest.new")
    return true
end

function update.writeJournal(base, entries)
    local lines = { MARKER }
    for _, e in ipairs(entries) do
        if not validDst(e.dst) then return false, "bad destination " .. tostring(e.dst) end
        lines[#lines + 1] = e.dst
    end
    return writeAll(base .. "/.update/journal", table.concat(lines, "\n") .. "\n")
end

--- Destinations recorded in a journal, or nil when there is no journal.
function update.readJournal(base)
    local data = readAll(base .. "/.update/journal")
    if not data then return nil end
    local line1, rest = data:match("^([^\r\n]*)\r?\n(.*)$")
    if line1 ~= MARKER then return {} end
    local list = {}
    for line in (rest or ""):gmatch("[^\r\n]+") do
        local dst = line:match("^%s*(.-)%s*$")
        if validDst(dst) then list[#list + 1] = dst end
    end
    return list
end

--- Undo the destinations in `list`. Files already committed get their
-- backup back; files never reached are left untouched (their staging file
-- still exists). Returns the number of restored files.
function update.rollback(base, list, journal)
    local restored = 0
    for i = #list, 1, -1 do
        local dst = list[i]
        local p = update.paths(base, dst)
        if p then
            if exists(p.backup) then
                if exists(dst) then pcall(fs.delete, dst) end
                if moveFile(p.backup, dst) then restored = restored + 1 end
            elseif exists(p.staged) then
                -- The swap never started: the live file is the old one.
            elseif exists(dst) then
                -- A new file was created where none existed before.
                pcall(fs.delete, dst)
                restored = restored + 1
            end
            if exists(p.staged) then pcall(fs.delete, p.staged) end
        end
    end
    pcall(fs.delete, base .. "/.update/journal")
    update.remove(base .. "/.update")
    return restored
end

--- Swap every staged file into place, journal first. All or nothing from
-- the caller's point of view: a failure rolls the transaction back.
function update.commit(base, entries)
    local function reached(upto)
        local list = {}
        for j = 1, upto do list[j] = entries[j].dst end
        return list
    end

    local ok, why = update.writeJournal(base, entries)
    if not ok then return false, "cannot write the update journal: " .. tostring(why) end

    for i, e in ipairs(entries) do
        local p = update.paths(base, e.dst)
        if not p then
            update.rollback(base, reached(i))
            return false, "bad destination " .. tostring(e.dst)
        end
        if exists(e.dst) then
            local okB, whyB = moveFile(e.dst, p.backup)
            if not okB then
                update.rollback(base, reached(i))
                return false, "cannot back up " .. e.dst .. ": " .. tostring(whyB)
            end
        end
        local okM, whyM = moveFile(p.staged, e.dst)
        if not okM then
            update.rollback(base, reached(i))
            return false, "cannot install " .. e.dst .. ": " .. tostring(whyM)
        end
    end

    local okJ = pcall(fs.delete, base .. "/.update/journal")
    if not okJ or exists(base .. "/.update/journal") then
        local list = {}
        for i, e in ipairs(entries) do list[i] = e.dst end
        update.rollback(base, list)
        return false, "cannot clear the update journal"
    end
    update.remove(base .. "/.update")
    return true
end

--- Called from startup.lua before main.lua. A journal means a commit was in
-- flight: put the old files back. Without one, only stale staging remains.
function update.recover(base)
    local list = update.readJournal(base)
    if list then
        return update.rollback(base, list), true
    end
    update.clean(base)
    return 0, false
end

return update
