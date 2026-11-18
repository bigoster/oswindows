--- CC-Windows installer.
--
-- Fetches the release manifest from GitHub, then every missing or changed
-- file. Each download is checked against the size and SHA-256 in the
-- manifest and, for Lua, compiled with load() before it is allowed near the
-- filesystem. /ccwin/settings.cfg is never touched.
--
-- Bootstrap on a CraftOS computer (CC:CE + CC-Graphics, http enabled):
--
--   wget https://raw.githubusercontent.com/OWNER/REPO/BRANCH/install.lua install.lua
--   install.lua             -- full install
--   install.lua standard    -- core + the standard apps
--   install.lua core        -- smallest bootable install
--
-- or, without saving a copy:
--
--   wget run https://raw.githubusercontent.com/OWNER/REPO/BRANCH/install.lua
--
-- Why downloads go through a temporary name: the ROM's wget refuses to
-- overwrite an existing file ("File already exists") and every one of its
-- failure paths is a bare `return`, so shell.run() reports success even when
-- the fetch failed. We fetch to <dst>.new, verify the bytes, and only then
-- replace the destination.

---------------------------------------------------------------------------
-- Repository: edit these three lines to point at your GitHub repo.
---------------------------------------------------------------------------

local OWNER  = "bigoster"
local REPO   = "oswindows"
local BRANCH = "main"

---------------------------------------------------------------------------

local BASE = "https://raw.githubusercontent.com/"
    .. OWNER .. "/" .. REPO .. "/" .. BRANCH
local MANIFEST_URL = BASE .. "/manifest.txt"
local MANIFEST_TMP = "/ccwin-manifest.new"
local STATE_PATH = "/ccwin/.installed-manifest"

local MODES = {
    full = { core = true, standard = true, extras = true },
    standard = { core = true, standard = true },
    core = { core = true },
}

local function die(msg)
    error(msg, 0)
end

---------------------------------------------------------------------------
-- SHA-256 (kept inside the installer: it must verify bytes before running
-- or trusting anything downloaded)
---------------------------------------------------------------------------

local band, bxor, bnot = bit32.band, bit32.bxor, bit32.bnot
local rshift, rrotate = bit32.rshift, bit32.rrotate
local MOD = 4294967296

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local HEX = {}
for i = 0, 255 do HEX[i] = ("%02x"):format(i) end

local function be32(n)
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

local function hex32(n)
    return HEX[math.floor(n / 16777216) % 256]
        .. HEX[math.floor(n / 65536) % 256]
        .. HEX[math.floor(n / 256) % 256]
        .. HEX[n % 256]
end

local function sha256(data)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local bits = #data * 8
    local pad = (56 - (#data + 1) % 64) % 64
    local msg = data .. "\128" .. string.rep("\0", pad)
        .. be32(math.floor(bits / MOD)) .. be32(bits % MOD)
    local w = {}
    for i = 1, #msg, 64 do
        for j = 1, 16 do
            local a, b, c, d = msg:byte(i + (j - 1) * 4, i + (j - 1) * 4 + 3)
            w[j] = ((a * 256 + b) * 256 + c) * 256 + d
        end
        for j = 17, 64 do
            local x, y = w[j - 15], w[j - 2]
            local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
            local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
            w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % MOD
        end
        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
        for j = 1, 64 do
            local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = (h + S1 + ch + K[j] + w[j]) % MOD
            local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = (S0 + maj) % MOD
            h, g, f, e = g, f, e, (d + t1) % MOD
            d, c, b, a = c, b, a, (t1 + t2) % MOD
        end
        h0 = (h0 + a) % MOD; h1 = (h1 + b) % MOD
        h2 = (h2 + c) % MOD; h3 = (h3 + d) % MOD
        h4 = (h4 + e) % MOD; h5 = (h5 + f) % MOD
        h6 = (h6 + g) % MOD; h7 = (h7 + h) % MOD
    end
    return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3)
        .. hex32(h4) .. hex32(h5) .. hex32(h6) .. hex32(h7)
end

---------------------------------------------------------------------------
-- filesystem and manifest helpers
---------------------------------------------------------------------------

local function readAll(p)
    local h = fs.open(p, "r")
    if not h then return nil end
    local data = h.readAll()
    h.close()
    return data
end

local function makeParent(p)
    local dir = p:match("^(.*)/[^/]*$")
    if dir and dir ~= "" then fs.makeDir(dir) end
end

local function writeAll(p, data)
    local tmp = p .. ".new"
    if fs.exists(tmp) then fs.delete(tmp) end
    makeParent(p)
    local h = fs.open(tmp, "w")
    if not h then die("cannot write " .. tmp) end
    h.write(data)
    h.close()
    if fs.exists(p) then fs.delete(p) end
    fs.move(tmp, p)
end

local function plain(s)
    if type(s) ~= "string" or s == "" then return false end
    local n, slashes = 0, 0
    for seg in s:gmatch("[^/]+") do
        n = n + 1
        if seg == "." or seg == ".." or not seg:match("^[%w._-]+$") then
            return false
        end
    end
    for _ in s:gmatch("/") do slashes = slashes + 1 end
    return n > 0 and slashes == n - 1
end

local function safeDst(s)
    return type(s) == "string" and s:sub(1, 1) == "/" and plain(s:sub(2))
end

local COMPONENTS = { core = true, standard = true, extras = true }

local function parseManifest(body)
    if type(body) ~= "string" then return nil, "empty manifest" end
    local version, entries = nil, {}
    for line in body:gmatch("[^\r\n]+") do
        local s = line:match("^%s*(.-)%s*$")
        if s ~= "" and s:sub(1, 1) ~= "#" then
            local v = s:match("^version%s+(%S+)$")
            if v then
                version = v
            else
                local size, digest, src, dst, comp =
                    s:match("^(%d+)%s+(%x+)%s+(%S+)%s+(%S+)%s+(%S+)$")
                if not size then return nil, "bad line: " .. s end
                if #digest ~= 64 then return nil, "bad SHA-256: " .. s end
                if not plain(src) or not safeDst(dst) then
                    return nil, "unsafe path: " .. s
                end
                if not COMPONENTS[comp] then return nil, "unknown component: " .. s end
                entries[#entries + 1] = {
                    size = tonumber(size),
                    hash = digest:lower(),
                    src = src,
                    dst = dst,
                    comp = comp,
                }
            end
        end
    end
    if not version then return nil, "no version line" end
    if #entries == 0 then return nil, "the manifest is empty" end
    return { version = version, entries = entries }
end

local function stateBody(manifest, selected)
    local lines = { "version " .. manifest.version }
    for _, e in ipairs(selected) do
        lines[#lines + 1] = ("%d %s %s %s %s")
            :format(e.size, e.hash, e.src, e.dst, e.comp)
    end
    return table.concat(lines, "\n") .. "\n"
end

local function wget(url, dst)
    if fs.exists(dst) then fs.delete(dst) end
    if not shell.run("wget", url, dst) then
        die(("wget is missing or failed to start (%s)"):format(url))
    end
    if not fs.exists(dst) then
        die(("download failed: %s\n" ..
             "  check the repo URL, branch and that http is enabled."):format(url))
    end
end

---------------------------------------------------------------------------
-- install
---------------------------------------------------------------------------

local function main(modeName)
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
    local wanted = MODES[modeName or "full"]
    if not wanted then
        die(("unknown install mode %q (use full, standard or core)")
            :format(tostring(modeName)))
    end
    if type(bit32) ~= "table" then
        die("This computer's Lua has no bit32, so downloads cannot be verified.")
    end

    io.write("CC-Windows installer\n")
    io.write(("  %s/%s @ %s\n"):format(OWNER, REPO, BRANCH))
    io.write(("  mode: %s\n\n"):format(modeName or "full"))

    wget(MANIFEST_URL, MANIFEST_TMP)
    local manifestText = readAll(MANIFEST_TMP)
    if fs.exists(MANIFEST_TMP) then fs.delete(MANIFEST_TMP) end
    local manifest, why = parseManifest(manifestText)
    if not manifest then
        die("bad release manifest: " .. tostring(why))
    end

    local selected = {}
    local matches = {}
    local downloadBytes = 0
    for _, e in ipairs(manifest.entries) do
        if wanted[e.comp] then
            selected[#selected + 1] = e
            local have = nil
            if fs.exists(e.dst) then have = readAll(e.dst) end
            local same = have and #have == e.size and sha256(have) == e.hash
            matches[e.dst] = same
            if not same then downloadBytes = downloadBytes + e.size end
        end
    end
    if #selected == 0 then die("the manifest has no files for this mode") end

    local hasStart = false
    for _, e in ipairs(selected) do
        if e.dst == "/startup.lua" then hasStart = true end
    end
    if not hasStart then die("the release manifest has no /startup.lua") end

    if type(fs.getFreeSpace) == "function" then
        local free = fs.getFreeSpace("/")
        if free and free < downloadBytes + 32768 then
            die(("not enough disk space: need %d KB, have %d KB")
                :format(math.ceil((downloadBytes + 32768) / 1024),
                    math.floor(free / 1024)))
        end
    end

    io.write(("  %d files selected, about %d KB to download\n\n")
        :format(#selected, math.ceil(downloadBytes / 1024)))

    local skipped, written = 0, 0

    for i, e in ipairs(selected) do
        local started = os.clock()
        if matches[e.dst] then
            skipped = skipped + 1
        else
            local tmp = e.dst .. ".new"
            if fs.exists(tmp) then fs.delete(tmp) end
            makeParent(e.dst)
            wget(BASE .. "/" .. e.src, tmp)

            local data = readAll(tmp)
            if not data then
                fs.delete(tmp)
                die("download failed: " .. e.src)
            end
            if #data ~= e.size then
                fs.delete(tmp)
                die(("bad download: %s is %d bytes, expected %d")
                    :format(e.src, #data, e.size))
            end
            if sha256(data) ~= e.hash then
                fs.delete(tmp)
                die("bad download: " .. e.src .. " has the wrong SHA-256")
            end
            if e.dst:match("%.lua$") then
                local fn, err = load(data, "@" .. e.dst)
                if not fn then
                    fs.delete(tmp)
                    die(("bad download: %s does not compile: %s")
                        :format(e.src, tostring(err)))
                end
            end
            if fs.exists(e.dst) then fs.delete(e.dst) end
            fs.move(tmp, e.dst)
            written = written + 1
        end
        io.write(("  [%2d/%d] %s%s  (%.1fs)\n"):format(
            i, #selected, e.dst,
            matches[e.dst] and " (current)" or "",
            os.clock() - started))
    end

    -- Final sweep: every selected file exists, and no temp file remains.
    local missing = {}
    for _, e in ipairs(selected) do
        if not fs.exists(e.dst) then missing[#missing + 1] = e.dst end
        if fs.exists(e.dst .. ".new") then fs.delete(e.dst .. ".new") end
    end
    if #missing > 0 then
        die("missing after install: " .. table.concat(missing, ", "))
    end

    writeAll(STATE_PATH, stateBody(manifest, selected))

    io.write(("\nInstalled %d/%d files (version %s).\n")
        :format(#selected, #selected, manifest.version))
    io.write(("  %d downloaded, %d already current\n"):format(written, skipped))
    io.write("Reboot to start CC-Windows:\n  reboot\n")
end

local args = { ... }
local modeName = args[1]
if not modeName and type(arg) == "table" then modeName = arg[1] end

local ok, err = pcall(main, modeName)
if not ok then
    pcall(function()
        if fs.exists(MANIFEST_TMP) then fs.delete(MANIFEST_TMP) end
    end)
    error(err, 0)
end
