--- CC-Windows - safe file input/output.
--
-- Every write that matters goes through this module: the bytes land in a
-- ".new" sibling first, are read back to prove they all arrived, and only
-- then replace the real file.  A previous copy is kept as ".bak" when the
-- caller asks for one, so a power cut can never truncate a document.
--
-- Nothing here may ever throw: callers treat `false, why` as a normal
-- outcome (a full disk, a read-only mount, a missing folder).
local storage = {}

storage.LOG_MAX = 32768
storage.CACHE_MAX = 131072

--- Size of a file, or nil when it is missing or unreadable.
function storage.size(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, n = pcall(fs.getSize, path)
    if ok and type(n) == "number" then return n end
    return nil
end

function storage.exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok, yes = pcall(fs.exists, path)
    return ok and yes == true
end

function storage.isDir(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok, yes = pcall(fs.isDir, path)
    return ok and yes == true
end

--- Read at most `maxBytes` from a file.  Files that claim to be larger are
--- refused before they can exhaust the heap.
function storage.read(path, maxBytes)
    if type(path) ~= "string" or path == "" then return nil end
    local n = storage.size(path)
    if not n then return nil end
    if maxBytes and n > maxBytes then return nil, "file is too large" end
    local okOpen, f, why = pcall(fs.open, path, "r")
    if not okOpen or not f then return nil, why end
    if type(f.readAll) ~= "function" then
        pcall(f.close)
        return nil, "not a file"
    end
    local ok, data = pcall(f.readAll)
    pcall(f.close)
    if not ok or type(data) ~= "string" then return nil end
    if maxBytes and #data > maxBytes then return nil, "file is too large" end
    return data
end

local function copyFile(from, to)
    local ok = pcall(fs.copy, from, to)
    return ok and storage.exists(to)
end

local function moveFile(from, to)
    local ok = pcall(fs.move, from, to)
    -- A successful move is proved by where the bytes ended up, not by a
    -- return value: some hosts return true, some return nothing.
    if ok and storage.exists(to) and not storage.exists(from) then return true end
    if copyFile(from, to) then
        pcall(fs.delete, from)
        return true
    end
    return false
end

--- Replace `path` with `data`, atomically from the reader's point of view.
-- Options: `backup = true` keeps the old contents in `path .. ".bak"`.
-- Returns true, or false plus a short reason.
function storage.write(path, data, opts)
    if type(path) ~= "string" or path == "" then return false, "bad path" end
    if type(data) ~= "string" then return false, "bad data" end
    opts = opts or {}
    local tmp = path .. ".new"
    local bak = path .. ".bak"

    local okOpen, f, why = pcall(fs.open, tmp, "w")
    if not okOpen or not f then
        return false, why or ("cannot write " .. tmp)
    end
    local ok, err = pcall(f.write, data)
    if ok then ok, err = pcall(f.close) end
    if not ok then
        pcall(fs.delete, tmp)
        return false, tostring(err)
    end
    if storage.size(tmp) ~= #data then
        pcall(fs.delete, tmp)
        return false, "short write"
    end

    local had = storage.exists(path) and not storage.isDir(path)
    if had and opts.backup then
        pcall(fs.delete, bak)
        if not copyFile(path, bak) then
            pcall(fs.delete, tmp)
            return false, "cannot keep a backup"
        end
    end
    if had then pcall(fs.delete, path) end
    if not moveFile(tmp, path) then
        -- Put the old file back when the swap failed halfway through.
        if had and opts.backup and storage.exists(bak) then
            copyFile(bak, path)
        end
        return false, "cannot replace " .. path
    end
    return true
end

--- Append to a log-like file, keeping only the newest `maxBytes` bytes.
function storage.append(path, data, maxBytes)
    if type(data) ~= "string" or data == "" then return true end
    maxBytes = maxBytes or storage.LOG_MAX
    local old = storage.read(path, maxBytes) or ""
    local out = old .. data
    if #out > maxBytes then out = out:sub(#out - maxBytes + 1) end
    return storage.write(path, out, { backup = false })
end

--- Cut a log file down to its newest `maxBytes` bytes. Unlike append(),
-- this also trims a file someone else wrote (or an older build grew).
function storage.trim(path, maxBytes)
    local n = storage.size(path)
    if not n then return false end
    maxBytes = maxBytes or storage.LOG_MAX
    if n <= maxBytes then return false end
    local data = storage.read(path, n)
    if not data then return false end
    return storage.write(path, data:sub(#data - maxBytes + 1), { backup = false })
end

--- Every file under `dir`, as { path, size } records.
function storage.listFiles(dir, out)
    out = out or {}
    if not storage.isDir(dir) then return out end
    local ok, names = pcall(fs.list, dir)
    if not ok or type(names) ~= "table" then return out end
    for _, name in ipairs(names) do
        local p = dir .. "/" .. name
        if storage.isDir(p) then
            storage.listFiles(p, out)
        else
            out[#out + 1] = { path = p, size = storage.size(p) or 0 }
        end
    end
    return out
end

--- Total bytes of a directory tree.
function storage.treeSize(dir)
    local total = 0
    for _, f in ipairs(storage.listFiles(dir)) do total = total + f.size end
    return total
end

--- Keep a cache directory at or below `maxBytes`, deleting the oldest
-- files first. CraftOS exposes fs.getLastModified; when it does not, the
-- directory order is used instead. Returns the number of bytes freed.
function storage.capCache(dir, maxBytes)
    maxBytes = maxBytes or storage.CACHE_MAX
    local files = storage.listFiles(dir)
    local total = 0
    for _, f in ipairs(files) do total = total + f.size end
    if total <= maxBytes then return 0 end
    if type(fs.getLastModified) == "function" then
        table.sort(files, function(a, b)
            local oka, ta = pcall(fs.getLastModified, a.path)
            local okb, tb = pcall(fs.getLastModified, b.path)
            if oka and okb and ta ~= tb then return ta < tb end
            return a.path < b.path
        end)
    end
    local freed = 0
    for _, f in ipairs(files) do
        if total <= maxBytes then break end
        if storage.delete(f.path) then
            total = total - f.size
            freed = freed + f.size
        end
    end
    return freed
end

--- Housekeeping at boot: restore settings from their backup if a power cut
-- lost the live file, trim the log and any cache, and drop stale temp files.
-- `opts` = { base, settings, log, cache, cacheMax }.
function storage.maintain(opts)
    opts = opts or {}
    local settings = opts.settings
    if settings then
        if not storage.exists(settings) and storage.exists(settings .. ".bak") then
            copyFile(settings .. ".bak", settings)
        end
        pcall(fs.delete, settings .. ".new")
    end
    if opts.log then storage.trim(opts.log, opts.logMax or storage.LOG_MAX) end
    if opts.cache then storage.capCache(opts.cache, opts.cacheMax or storage.CACHE_MAX) end
    if opts.base then
        pcall(fs.delete, opts.base .. "/.installed-manifest.new")
        pcall(fs.delete, opts.base .. "/version.new")
    end
    return true
end

--- If `path` vanished in the middle of a write, restore its backup.
-- Returns true when a file was recovered.
function storage.recover(path)
    if type(path) ~= "string" or path == "" then return false end
    if storage.exists(path) then
        -- A stale staging file from a crash can be discarded safely.
        pcall(fs.delete, path .. ".new")
        return false
    end
    local bak = path .. ".bak"
    if storage.exists(bak) then
        if copyFile(bak, path) then return true end
    end
    pcall(fs.delete, path .. ".new")
    return false
end

function storage.delete(path)
    if type(path) ~= "string" or path == "" then return false end
    pcall(fs.delete, path)
    return not storage.exists(path)
end

function storage.makeDir(path)
    if storage.isDir(path) then return true end
    pcall(fs.makeDir, path)
    return storage.isDir(path)
end

--- Free bytes on the filesystem holding `path`, or nil where the host has
--- no way to ask (older CC versions).
function storage.freeSpace(path)
    if type(fs.getFreeSpace) ~= "function" then return nil end
    local ok, n = pcall(fs.getFreeSpace, path or "/")
    if ok and type(n) == "number" then return n end
    return nil
end

--- True unless the filesystem positively reports less room than asked.
function storage.hasSpace(path, bytes)
    local free = storage.freeSpace(path)
    if not free then return true end
    return free >= (bytes or 0) + 1024
end

return storage
