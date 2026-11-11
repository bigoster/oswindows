--- CC-Windows - System information.
--
-- Shows computer details, CC:CE power readings (when running on an
-- electric computer) and the attached peripherals. The numbers refresh
-- once a second from a private timer.
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
    }

    -------------------------------------------------------------------
    -- data collection
    -------------------------------------------------------------------

    local function addSection(list, title, rows)
        if #rows > 0 then list[#list + 1] = { title = title, rows = rows } end
    end

    local function refresh()
        local list = {}

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
    -- drawing
    -------------------------------------------------------------------

    function self:draw(dc, w, h)
        dc:fill(0, 0, w, h, C.face)

        local y = PAD
        for _, section in ipairs(self.sections) do
            if y + BAND_H > h then break end
            theme.band(dc, PAD - 2, y, w - PAD * 2 + 4, BAND_H, section.title)
            y = y + BAND_H + 2

            if section.title:sub(1, 11) == "Peripherals" then
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
            if section.title:sub(1, 11) == "Peripherals" then
                local listH = math.min(LIST_H, h - y - PAD)
                return y, listH
            end
            for _ in ipairs(section.rows) do y = y + ROW_H end
            y = y + 5
        end
        return nil, nil
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
        if close then close(self) end
    end

    return self
end

return app
