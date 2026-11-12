--- CC-Windows - System information and OS updates.
--
-- Shows computer details, CC:CE power readings (when running on an
-- electric computer) and the attached peripherals. The numbers refresh
-- once a second from a private timer.
--
-- The Updates band at the top talks to GitHub: "Check for updates"
-- compares /ccwin/version with the one in the repository, and "Install
-- update" downloads the file list (files.txt), fetches every system file
-- and replaces the ones whose contents differ. Downloads are never
-- executed - each Lua file is compiled with load() (and thrown away)
-- before it is allowed near the filesystem.
local app = {}

app.id = "system"
app.name = "System"
app.icon = "system"
app.defaultSize = { 272, 208 }

local theme, widgets, C

local PAD = 6
local BAND_H = 12
local ROW_H = 11
local LIST_H = 58
-- Space the Updates band takes below its header: gap, button, two status
-- lines (11px pitch each).
local UPD_BODY = 41

-- Where updates come from - the same three values install.lua uses.
local OWNER, REPO, BRANCH = "bigoster", "oswindows", "main"
local BASE = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPO .. "/" .. BRANCH
local VERSION_URL = BASE .. "/ccwin/version"
local MANIFEST_URL = BASE .. "/files.txt"
local LOCAL_VERSION = "/ccwin/version"
local HTTP_TIMEOUT = 30

local function dc_size(win)
    if win.content then return win.content.w, win.content.h end
    return 1, 1
end

local function call(fn, ...)
    if type(cee) ~= "table" or type(cee[fn]) ~= "function" then return nil end
    local ok, a = pcall(cee[fn], ...)
    if ok then return a end
    return nil
end

local function fmtUptime(sec)
    sec = math.floor(sec or 0)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%dh %02dm %02ds", h, m, s) end
    if m > 0 then return string.format("%dm %02ds", m, s) end
    return string.format("%ds", s)
end

local function fmtBytes(n)
    n = tonumber(n)
    if not n then return "unknown" end
    if n >= 1024 * 1024 * 1024 then
        return string.format("%.2f GB", n / (1024 * 1024 * 1024))
    elseif n >= 1024 * 1024 then
        return string.format("%.1f MB", n / (1024 * 1024))
    elseif n >= 1024 then
        return string.format("%.1f KB", n / 1024)
    end
    return n .. " B"
end

local function fmtNum(n, fmt)
    if type(n) ~= "number" then return nil end
    return string.format(fmt, n)
end

local function safe(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

---------------------------------------------------------------------------
-- small filesystem helpers for the updater (plain reads and writes, no
-- execution of anything that comes back from the network)
---------------------------------------------------------------------------

local function readFile(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local ok, data = pcall(h.readAll)
    pcall(h.close)
    if ok then return data end
    return nil
end

--- Write through a .new temp file and swap it in, so a failed write can
--- never leave a half-written system file behind.
local function writeFile(path, data)
    local dir = path:match("^(.*)/[^/]*$")
    if dir and dir ~= "" then pcall(fs.makeDir, dir) end
    local tmp = path .. ".new"
    if fs.exists(tmp) then pcall(fs.delete, tmp) end
    local h = fs.open(tmp, "w")
    if not h then return nil, "cannot write " .. tmp end
    local okW, err = pcall(h.write, data)
    pcall(h.close)
    if not okW or err == false then
        pcall(fs.delete, tmp)
        return nil, "cannot write " .. tmp
    end
    if fs.exists(path) then pcall(fs.delete, path) end
    local okM, merr = pcall(fs.move, tmp, path)
    if not okM then return nil, tostring(merr) end
    return true
end

--- A plain path: non-empty, segments of [word chars . _ -] only, no
--- empty segment (so no leading "/", "//" or trailing "/") and no "." or
--- "..". (Lua patterns cannot quantify groups, so the segments are walked.)
local function plainPath(s)
    if type(s) ~= "string" or s == "" then return false end
    local n, slashes = 0, 0
    for seg in s:gmatch("[^/]+") do
        n = n + 1
        if seg == "." or seg == ".." then return false end
        if not seg:match("^[%w._-]+$") then return false end
    end
    for _ in s:gmatch("/") do slashes = slashes + 1 end
    if n == 0 or slashes ~= n - 1 then return false end
    return true
end

--- A manifest source: a plain repository-relative file.
local function safeSrc(s)
    return plainPath(s)
end

--- A manifest destination: absolute, plain, no `..`.
local function safeDst(s)
    return type(s) == "string" and s:sub(1, 1) == "/" and plainPath(s:sub(2))
end

--- First line of a file/body, trimmed; nil when there is none.
local function firstLine(data)
    local line = data and data:match("[^\r\n]+")
    if not line then return nil end
    line = line:match("^%s*(.-)%s*$")
    if line == "" then return nil end
    return line
end

--- Wrap a status line to `maxChars` columns; at most two lines, the
--- second ellipsized when there is more to say than fits.
local function wrapText(s, maxChars)
    if type(s) ~= "string" or s == "" then return { "" } end
    if #s <= maxChars then return { s } end
    local lines, cur = {}, ""
    local function push(line)
        -- only two status lines fit; the second gets an ellipsis
        if #lines >= 2 then
            local last = lines[2]
            lines[2] = last:sub(1, maxChars - 3) .. "..."
            return true
        end
        lines[#lines + 1] = line
        return false
    end
    for word in s:gmatch("%S+") do
        if cur == "" then
            cur = word
        elseif #cur + 1 + #word <= maxChars then
            cur = cur .. " " .. word
        else
            if push(cur) then return lines end
            cur = word
        end
        while #cur > maxChars do        -- one word longer than a whole line
            if push(cur:sub(1, maxChars)) then return lines end
            cur = cur:sub(maxChars + 1)
        end
    end
    if cur ~= "" then push(cur) end
    return lines
end

function app.create(win, opts, ctx)
    theme, widgets, C = ctx.theme, ctx.widgets, ctx.theme.C
    local fabric = ctx.fabric

    local self = {
        sections = {},
        periph = {},
        periphCount = 0,
        oy = 0,
        timerId = nil,
        hover = nil,
        rects = {},
        pending = nil,   -- { kind, url, ... } while a GitHub fetch runs
        tick = nil,      -- timer guarding the pending fetch
        upd = {
            state = "idle",   -- idle | checking | ready | installing | done | uptodate | error
            msg = "Click to look for a new version of CC-Windows on GitHub.",
            localV = nil,
            remote = nil,
            files = nil,
            idx = 0,
            total = 0,
            updated = 0,
        },
    }

    -------------------------------------------------------------------
    -- data collection
    -------------------------------------------------------------------

    local function addSection(list, title, rows)
        if #rows > 0 then list[#list + 1] = { title = title, rows = rows } end
    end

    local function refresh()
        local list = {}

        -- The updater band is first, so its button stays reachable even in
        -- a small window. It is rebuilt with the rest every second but its
        -- text comes from self.upd, which only the updater writes.
        list[#list + 1] = { title = "Updates", updates = true, rows = {} }

        -----------------------------------------------------------------
        local rows = {}
        rows[#rows + 1] = { "Computer ID", tostring(safe(os.getComputerID) or "?") }
        local label = safe(os.getComputerLabel)
        rows[#rows + 1] = { "Label", label and tostring(label) or "(none)" }
        rows[#rows + 1] = { "OS", tostring(safe(os.version) or "?") }
        rows[#rows + 1] = { "Uptime", fmtUptime(os.clock()) }
        -- collectgarbage does not exist on CC (Cobalt strips it), so it must
        -- go through safe() like every other optional API below.
        local memKb = safe(function() return collectgarbage("count") end)
        if memKb then
            rows[#rows + 1] = { "Memory used", fmtBytes((memKb or 0) * 1024) }
        end
        local free = safe(fs.getFreeSpace, "/")
        local cap = safe(fs.getCapacity, "/")
        if free then
            local text = fmtBytes(free)
            if cap then text = text .. " of " .. fmtBytes(cap) end
            rows[#rows + 1] = { "Disk free", text }
        end
        addSection(list, "Computer", rows)

        -----------------------------------------------------------------
        if type(cee) == "table" then
            rows = {}
            local has = call("hasPower")
            if has ~= nil then
                rows[#rows + 1] = { "Power", has and "On" or "OFF (gate down)" }
            end
            local volts = call("getPowerVoltage")
            local amps = call("getSupplyCurrent")
            local draw = call("getDeliveredPower")
            local maxW = call("getMaxPower")
            local head = call("getPowerHeadroom")
            local state = call("getSupplyState")

            local v = fmtNum(volts, "%.1f V")
            if v and amps ~= nil then v = v .. "   " .. fmtNum(amps, "%.1f A") end
            if v then rows[#rows + 1] = { "Supply", v } end

            if draw then
                local text = fmtNum(draw, "%.0f W")
                if maxW then text = text .. " of " .. fmtNum(maxW, "%.0f W") end
                rows[#rows + 1] = { "Draw", text }
            end
            if head then rows[#rows + 1] = { "Headroom", fmtNum(head, "%.0f W") } end
            if state ~= nil then rows[#rows + 1] = { "State", tostring(state) } end

            local bus = call("busInfo")
            if type(bus) == "table" then
                if bus.load and bus.capacity then
                    rows[#rows + 1] = {
                        "Rack bus",
                        string.format("%.0f / %.0f W", bus.load or 0, bus.capacity or 0),
                    }
                end
                if bus.volts then rows[#rows + 1] = { "Bus volts", fmtNum(bus.volts, "%.1f V") } end
                if bus.supplies then
                    rows[#rows + 1] = {
                        "Supplies",
                        tostring(bus.activeSupplies or 0) .. " active of " .. tostring(bus.supplies),
                    }
                end
                if bus.onBus ~= nil then
                    rows[#rows + 1] = { "Feed", bus.onBus and "rack bus" or "own feed" }
                end
            end
            addSection(list, "Power", rows)
        end

        -----------------------------------------------------------------
        -- The CC:CE fabric link. Only shown where there is one: on a
        -- computer without CC:CE this section must not appear at all.
        if fabric and fabric.present() then
            rows = {}
            rows[#rows + 1] = { "Link", "Up (CC:CE fabric)" }
            local peers = fabric.peers()
            rows[#rows + 1] = {
                "Peers",
                #peers > 0 and tostring(#peers) or "(none connected)",
            }
            for i = 1, math.min(4, #peers) do
                rows[#rows + 1] = {
                    nil,
                    fabric.peerName(peers[i].id)
                        .. "  -  id " .. tostring(peers[i].id),
                }
            end
            if #peers > 4 then
                rows[#rows + 1] = { nil, "and " .. (#peers - 4) .. " more" }
            end
            addSection(list, "Fabric", rows)
        end

        -----------------------------------------------------------------
        rows = {}
        local names = safe(peripheral.getNames) or {}
        local list2 = {}
        for _, name in ipairs(names) do
            local ptype = safe(peripheral.getType, name) or "?"
            list2[#list2 + 1] = { name = name, text = name .. "  -  " .. ptype }
        end
        table.sort(list2, function(a, b) return a.text < b.text end)
        self.periph = list2
        self.periphCount = #list2
        for i = 1, math.min(6, #list2) do
            rows[#rows + 1] = { nil, list2[i].text }
        end
        if #list2 == 0 then rows[1] = { nil, "(no peripherals attached)" } end
        addSection(list, "Peripherals  (" .. #list2 .. ")", rows)

        self.sections = list
        self.dirty = true
    end
    self.refresh = refresh

    -------------------------------------------------------------------
    -- OS updater
    -------------------------------------------------------------------

    local function markDirty() self.dirty = true end

    local function failUpd(msg)
        self.upd.state = "error"
        self.upd.msg = msg
        self.pending = nil
        markDirty()
    end

    --- Show a repository-relative path instead of the whole raw URL.
    local function shortUrl(url)
        if type(url) == "string" and url:sub(1, #BASE + 1) == BASE .. "/" then
            return url:sub(#BASE + 2)
        end
        return tostring(url)
    end

    local function localVersion()
        return firstLine(readFile(LOCAL_VERSION))
    end

    --- Kick off one non-blocking request. The answer arrives in self:feed.
    local function fetch(url, kind, extra)
        if type(http) ~= "table" or type(http.request) ~= "function" then
            return failUpd("The http API is off - set http.enabled = true in the server config.")
        end
        local pending = extra or {}
        pending.kind = kind
        pending.url = url
        self.pending = pending
        local ok, err = pcall(http.request, {
            url = url,
            headers = { ["User-Agent"] = "CC-Windows-Updater/1.0" },
        })
        if not ok then
            self.pending = nil
            return failUpd("Cannot reach GitHub: " .. tostring(err))
        end
        if self.tick then pcall(os.cancelTimer, self.tick) end
        self.tick = os.startTimer(HTTP_TIMEOUT)
        markDirty()
    end

    --- All files handled: record the new version and report.
    local function finishInstall()
        local remote = self.upd.remote or "unknown"
        local wok, werr = writeFile(LOCAL_VERSION, remote .. "\n")
        self.upd.state = "done"
        if not wok then
            self.upd.msg = ("Files updated, but %s could not be saved: %s")
                :format(LOCAL_VERSION, tostring(werr))
        elseif self.upd.updated > 0 then
            self.upd.msg = ("Updated %d of %d files to version %s. Reboot to finish.")
                :format(self.upd.updated, self.upd.total, remote)
        else
            self.upd.msg = ("Already current: all %d files match version %s.")
                :format(self.upd.total, remote)
        end
        self.upd.files = nil
        self.upd.idx = 0
        markDirty()
    end

    local function nextFile()
        local list = self.upd.files or {}
        local i = self.upd.idx + 1
        if i > #list then return finishInstall() end
        self.upd.idx = i
        local entry = list[i]
        self.upd.msg = ("Installing %d/%d: %s"):format(i, #list, entry.src)
        markDirty()
        fetch(BASE .. "/" .. entry.src, "file", { dst = entry.dst })
    end

    --- One downloaded file: check it (never run it), then swap it in only
    --- when its bytes actually differ from what is on disk.
    local function onFile(p, body)
        local dst = p.dst
        if dst:match("%.lua$") then
            local fn, err = load(body, "@" .. dst)
            if not fn then
                return failUpd(("Bad download: %s does not compile (%s). Nothing was changed.")
                    :format(shortUrl(p.url), tostring(err)))
            end
        elseif firstLine(body) == nil then
            return failUpd("Bad download: " .. shortUrl(p.url)
                .. " came back empty. Nothing was changed.")
        end
        if readFile(dst) ~= body then
            local wok, werr = writeFile(dst, body)
            if not wok then
                return failUpd("Cannot write " .. dst .. ": " .. tostring(werr))
            end
            self.upd.updated = self.upd.updated + 1
        end
        nextFile()
    end

    --- The file list from the repository: "<source> <destination>" per
    --- line, # comments (the same pairs install.lua works from).
    local function onManifest(body)
        local list = {}
        for line in body:gmatch("[^\r\n]+") do
            local s = line:match("^%s*(.-)%s*$")
            if s ~= "" and s:sub(1, 1) ~= "#" then
                local src, dst = s:match("^(%S+)%s+(%S+)$")
                if not src or not safeSrc(src) or not safeDst(dst) then
                    return failUpd("GitHub's file list has a bad line: " .. s)
                end
                list[#list + 1] = { src = src, dst = dst }
            end
        end
        if #list == 0 then return failUpd("GitHub's file list is empty.") end
        self.upd.files = list
        self.upd.total = #list
        self.upd.idx = 0
        self.upd.updated = 0
        nextFile()
    end

    --- The version check: local marker vs. the one in the repository.
    local function onCheck(body)
        local remote = firstLine(body)
        if not remote or remote:find("<", 1, true) then
            return failUpd("GitHub did not send a version number (is the repo pushed?).")
        end
        local loc = localVersion()
        self.upd.remote = remote
        self.upd.localV = loc
        if loc == remote then
            self.upd.state = "uptodate"
            self.upd.msg = "Up to date - version " .. remote .. " is installed."
        else
            self.upd.state = "ready"
            self.upd.msg = ("Update available: %s to version %s. Click Install.")
                :format(loc or "unknown version", remote)
        end
        markDirty()
    end

    local function startCheck()
        if self.pending then return end
        self.upd.state = "checking"
        self.upd.msg = "Checking GitHub for updates..."
        self.upd.localV = nil
        self.upd.remote = nil
        fetch(VERSION_URL, "check")
    end

    local function startInstall()
        if self.pending then return end
        self.upd.state = "installing"
        self.upd.msg = "Fetching the file list..."
        self.upd.idx = 0
        self.upd.updated = 0
        fetch(MANIFEST_URL, "manifest")
    end

    local function updButton()
        local st = self.upd.state
        if st == "checking" then return "Checking...", true end
        if st == "installing" then return "Installing...", true end
        if st == "ready" then return "Install update", false end
        return "Check for updates", false
    end

    local function msgColour()
        local st = self.upd.state
        if st == "error" then return C.danger end
        if st == "done" or st == "uptodate" then return C.success end
        if st == "ready" then return C.accent end
        if st == "idle" then return C.textMuted end
        return C.text
    end


    -------------------------------------------------------------------
    -- drawing
    -------------------------------------------------------------------

    function self:draw(dc, w, h)
        dc:fill(0, 0, w, h, C.face)
        self.rects = {}

        local y = PAD
        for _, section in ipairs(self.sections) do
            if y + BAND_H > h then break end
            theme.band(dc, PAD - 2, y, w - PAD * 2 + 4, BAND_H, section.title)
            y = y + BAND_H + 2

            if section.updates then
                -- Check / Install button plus a two-line status under it.
                local label, disabled = updButton()
                local bw = dc:textWidth(label) + 18
                local bx, by = PAD + 2, y + 2
                widgets.button(dc, bx, by, bw, 15, label, {
                    state = disabled and "disabled"
                        or (self.hover == "upd" and "hover" or nil),
                })
                self.rects.upd = { bx, by, bw, 15 }
                local maxChars = math.max(8, math.floor((w - PAD * 2 - 4) / 6))
                local lines = wrapText(self.upd.msg or "", maxChars)
                local colour = msgColour()
                dc:text(bx, by + 17, lines[1] or "", colour)
                if lines[2] then dc:text(bx, by + 28, lines[2], colour) end
                y = y + UPD_BODY + 5
            elseif section.title:sub(1, 11) == "Peripherals" then
                -- The last section is a scrollable list.
                local listTop = y
                local listH = math.min(LIST_H, h - y - PAD)
                dc:pushClip(PAD, y, w - PAD * 2, math.max(0, listH))
                local maxOy = math.max(0, self.periphCount * ROW_H - listH)
                if self.oy > maxOy then self.oy = maxOy end
                local shown = self.periphCount
                for i = 1, shown do
                    local ry = listTop + (i - 1) * ROW_H - self.oy
                    if ry >= listTop - ROW_H and ry < listTop + listH then
                        local alt = (i % 2 == 0)
                        if alt then dc:fill(PAD, ry, w - PAD * 2, ROW_H, C.listAlt) end
                        dc:text(PAD + 3, ry + 1,
                            widgets.ellipsis(self.periph[i].text, w - PAD * 2 - 6),
                            C.text)
                    end
                end
                dc:popClip()
                dc:rect(PAD, listTop, w - PAD * 2, listH, C.bevelDark)
                if self.periphCount * ROW_H > listH then
                    local frac = listH / (self.periphCount * ROW_H)
                    local start = (self.oy / (self.periphCount * ROW_H)) * (1 - frac)
                    theme.scrollbarV(dc, w - PAD - 8, listTop + 1, 7, listH - 2, start, frac, false)
                end
                y = listTop + listH + PAD
            else
                for _, row in ipairs(section.rows) do
                    if y + ROW_H > h then break end
                    if row[1] then
                        dc:text(PAD + 4, y, row[1], C.textMuted)
                        dc:text(PAD + 88, y, widgets.ellipsis(row[2], w - PAD * 4 - 88), C.text)
                    else
                        dc:text(PAD + 4, y, widgets.ellipsis(row[2], w - PAD * 2 - 8), C.text)
                    end
                    y = y + ROW_H
                end
                y = y + 5
            end
        end
    end

    -------------------------------------------------------------------
    -- input
    -------------------------------------------------------------------

    local function listBounds(w, h)
        local y = PAD
        for _, section in ipairs(self.sections) do
            y = y + BAND_H + 2
            if section.updates then
                y = y + UPD_BODY + 5
            elseif section.title:sub(1, 11) == "Peripherals" then
                local listH = math.min(LIST_H, h - y - PAD)
                return y, listH
            else
                for _ in ipairs(section.rows) do y = y + ROW_H end
                y = y + 5
            end
        end
        return nil, nil
    end

    local function hitUpd(x, y)
        local r = self.rects.upd
        if not r then return false end
        return x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
    end

    function self:click(x, y, button)
        if button == 1 and hitUpd(x, y) then
            local st = self.upd.state
            if st == "ready" then
                startInstall()
            elseif st ~= "checking" and st ~= "installing" then
                startCheck()
            end
            self.dirty = true
        end
        return true
    end

    function self:drag(x, y)
        local hov = hitUpd(x, y) and "upd" or nil
        if hov ~= self.hover then
            self.hover = hov
            self.dirty = true
            return true
        end
        return false
    end

    --- Answers to the updater's requests (every window sees every event;
    --- the pending URL is what makes this one ours).
    function self:feed(ev)
        local name = ev[1]
        if name ~= "http_success" and name ~= "http_failure" then return end
        local p = self.pending
        if not p or ev[2] ~= p.url then return end
        self.pending = nil
        if self.tick then pcall(os.cancelTimer, self.tick); self.tick = nil end

        local handle = (name == "http_success") and ev[3] or ev[4]
        local body, code
        if type(handle) == "table" then
            local okB, b = pcall(handle.readAll)
            if okB then body = b end
            if handle.getResponseCode then
                local okC, c = pcall(handle.getResponseCode)
                if okC then code = c end
            end
            pcall(handle.close)
        end

        if name == "http_failure" or not body then
            local why
            if name == "http_failure" then
                why = tostring(ev[3] or "request failed")
            else
                why = "no data came back"
            end
            if code then why = why .. " (HTTP " .. tostring(code) .. ")" end
            return failUpd("Cannot fetch " .. shortUrl(p.url) .. ": " .. why)
        end
        if code and code >= 400 then
            return failUpd("Cannot fetch " .. shortUrl(p.url)
                .. ": HTTP " .. tostring(code))
        end

        if p.kind == "check" then
            onCheck(body)
        elseif p.kind == "manifest" then
            onManifest(body)
        elseif p.kind == "file" then
            onFile(p, body)
        end
        self.dirty = true
    end

    function self:scroll(x, y, dir)
        local w, h = dc_size(win)
        local listTop, listH = listBounds(w, h)
        if not listTop then return true end
        if y < listTop or y >= listTop + listH then return true end
        local maxOy = math.max(0, self.periphCount * ROW_H - listH)
        self.oy = math.max(0, math.min(maxOy, self.oy + dir * ROW_H))
        self.dirty = true
        return true
    end

    function self:timer(id)
        if id == self.tick then
            -- The guard on a pending GitHub fetch fired.
            self.tick = nil
            if self.pending then
                local p = self.pending
                self.pending = nil
                failUpd(("Timed out after %d seconds: %s")
                    :format(HTTP_TIMEOUT, shortUrl(p.url)))
            end
            return
        end
        if id == self.timerId then
            self.timerId = os.startTimer(1)
            refresh()
        end
    end

    function self:resize()
        self.dirty = true
    end

    -------------------------------------------------------------------
    -- boot
    -------------------------------------------------------------------

    refresh()
    self.timerId = os.startTimer(1)

    local close = self.close
    function self:close()
        if self.timerId then pcall(os.cancelTimer, self.timerId) end
        self.timerId = nil
        if self.tick then pcall(os.cancelTimer, self.tick) end
        self.tick = nil
        -- A half-finished update simply stops here: /ccwin/version is only
        -- written by finishInstall, so the next check offers it again.
        self.pending = nil
        if close then close(self) end
    end

    return self
end

return app
