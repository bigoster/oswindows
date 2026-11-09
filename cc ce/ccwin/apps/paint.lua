--- CC-Windows - Paint.
--
-- The canvas is kept as an array of row strings (one byte per pixel, a
-- palette index), exactly like the frame buffer, so blitting it back is a
-- single call per scan line.
local app = {}

app.id = "paint"
app.name = "Paint"
app.icon = "paint"
app.defaultSize = { 300, 210 }

local theme, widgets, dialogs, C
local state

local TOOLBAR_H = 36
local COLOUR_H = 32
local STATUS_H = 14
local BTN_H = 14
local WHITE = 17

local TOOLS = {
    { id = "pencil", label = "Pencil", key = keys.p },
    { id = "line", label = "Line", key = keys.l },
    { id = "box", label = "Box", key = keys.b },
    { id = "fill", label = "Fill", key = keys.f },
    { id = "erase", label = "Erase", key = keys.e },
    { id = "pick", label = "Pick", key = keys.i },
}

local function dc_size(win)
    if win.content then return win.content.w, win.content.h end
    return 1, 1
end

function app.create(win, opts, ctx)
    theme, widgets, dialogs = ctx.theme, ctx.widgets, ctx.dialogs
    C = theme.C
    state = ctx.state

    local self = {
        tool = "pencil",
        colour = 143,          -- the black end of the paint palette
        path = opts and opts.path or nil,
        hover = nil,
        status = "",
        pointer = nil,
        preview = nil,         -- { tool, x0, y0, x1, y1 } while dragging
        last = nil,            -- last painted pixel (pencil continuation)
        undo = nil,
        oy = 0,
        rects = {},
        ctrl = false,
    }

    local canvas = {}
    local cw, chh = 0, 0

    -------------------------------------------------------------------
    -- canvas
    -------------------------------------------------------------------

    local function ensureCanvas(w, h)
        if w < 1 then w = 1 end
        if h < 1 then h = 1 end
        if w <= cw and h <= chh then return end
        local nw = math.max(w, cw)
        local nh = math.max(h, chh)
        local pad = string.rep(string.char(WHITE), nw)
        for y = 1, nh do
            local row = canvas[y]
            if row then
                if #row < nw then row = row .. string.rep(string.char(WHITE), nw - #row) end
            else
                row = pad
            end
            canvas[y] = row
        end
        cw, chh = nw, nh
    end

    local function getPx(x, y)
        if x < 0 or y < 0 or x >= cw or y >= chh then return nil end
        local row = canvas[y + 1]
        if not row then return nil end
        return string.byte(row, x + 1)
    end

    local function setPx(x, y, c)
        if x < 0 or y < 0 or x >= cw or y >= chh then return end
        local row = canvas[y + 1]
        if not row then return end
        canvas[y + 1] = row:sub(1, x) .. string.char(c) .. row:sub(x + 2)
    end

    local function snapshot()
        local copy = {}
        for y = 1, chh do copy[y] = canvas[y] end
        self.undo = { rows = copy, w = cw, h = chh }
    end

    local function restore()
        local u = self.undo
        if not u then return end
        canvas, cw, chh = u.rows, u.w, u.h
        self.undo = nil
        win.dirty = true
    end

    local function clearCanvas()
        snapshot()
        for y = 1, chh do
            canvas[y] = string.rep(string.char(WHITE), cw)
        end
        win.dirty = true
    end

    local function lineTo(x0, y0, x1, y1, colour)
        local dx, dy = math.abs(x1 - x0), math.abs(y1 - y0)
        local sx = x0 < x1 and 1 or -1
        local sy = y0 < y1 and 1 or -1
        local err = dx - dy
        while true do
            setPx(x0, y0, colour)
            if x0 == x1 and y0 == y1 then break end
            local e2 = 2 * err
            if e2 > -dy then err = err - dy; x0 = x0 + sx end
            if e2 < dx then err = err + dx; y0 = y0 + sy end
        end
    end

    local function outline(x0, y0, x1, y1, colour)
        local ax, bx = math.min(x0, x1), math.max(x0, x1)
        local ay, by = math.min(y0, y1), math.max(y0, y1)
        for x = ax, bx do
            setPx(x, ay, colour)
            setPx(x, by, colour)
        end
        for y = ay, by do
            setPx(ax, y, colour)
            setPx(bx, y, colour)
        end
    end

    local function floodFill(sx, sy, colour)
        local target = getPx(sx, sy)
        if target == nil or target == colour then return end
        local stack = { sx, sy }
        while #stack > 0 do
            local y = table.remove(stack)
            local x = table.remove(stack)
            if getPx(x, y) == target then
                setPx(x, y, colour)
                stack[#stack + 1] = x - 1; stack[#stack + 1] = y
                stack[#stack + 1] = x + 1; stack[#stack + 1] = y
                stack[#stack + 1] = x; stack[#stack + 1] = y - 1
                stack[#stack + 1] = x; stack[#stack + 1] = y + 1
            end
        end
    end

    -------------------------------------------------------------------
    -- files
    -------------------------------------------------------------------

    local function setTitle()
        local name = self.path and fs.getName(self.path) or "Untitled"
        ctx.wm.setTitle(win, name .. " - Paint")
    end

    local function saveTo(path, asNfp)
        local f = fs.open(path, "w")
        if not f then
            self.status = "Cannot write " .. path
            win.dirty = true
            return
        end
        if asNfp then
            for y = 1, chh do
                local row, out = canvas[y], {}
                for x = 1, cw do
                    local v = string.byte(row, x)
                    out[x] = v < 16 and string.format("%x", v) or "0"
                end
                f.writeLine(table.concat(out))
            end
        else
            f.writeLine("CCWIN1 " .. cw .. " " .. chh)
            for y = 1, chh do
                local row, out = canvas[y], {}
                for x = 1, cw do
                    out[x] = string.format("%02x", string.byte(row, x))
                end
                f.writeLine(table.concat(out))
            end
        end
        f.close()
        self.path = path
        self.status = "Saved " .. fs.getName(path)
        setTitle()
        win.dirty = true
    end

    local function saveAs()
        dialogs.open(win, {
            type = "prompt",
            title = "Save picture",
            label = "File name:",
            initial = self.path or "/image.cwp",
            onSubmit = function(text)
                if text and text ~= "" then
                    saveTo(text, text:match("%.nfp$") ~= nil)
                end
            end,
        })
    end

    local function save()
        if self.path then
            saveTo(self.path, self.path:match("%.nfp$") ~= nil)
        else
            saveAs()
        end
    end

    local function loadFrom(path)
        local f = fs.open(path, "r")
        if not f then
            self.status = "Cannot open " .. path
            win.dirty = true
            return
        end
        local first = f.readLine()
        local rows = {}
        if first and first:match("^CCWIN1") then
            local w, h = first:match("^CCWIN1%s+(%d+)%s+(%d+)")
            w, h = tonumber(w), tonumber(h)
            if not w or not h or w < 1 or h < 1 or w > 4096 or h < 1 or h > 4096 then
                f.close()
                self.status = "Not a valid picture"
                win.dirty = true
                return
            end
            for _ = 1, h do
                local line = f.readLine()
                if not line then break end
                local out = {}
                for i = 1, w do
                    local byte = tonumber(line:sub(i * 2 - 1, i * 2), 16)
                    out[i] = string.char(byte or WHITE)
                end
                rows[#rows + 1] = table.concat(out)
            end
        elseif first then
            -- NFP: one character per pixel, CC colour digits.
            if #first > 0 then rows[1] = first end
            while true do
                local line = f.readLine()
                if not line then break end
                rows[#rows + 1] = line
            end
            for y = 1, #rows do
                local out = {}
                for x = 1, #rows[y] do
                    local d = tonumber(rows[y]:sub(x, x), 16)
                    out[x] = string.char(d or 15)
                end
                rows[y] = table.concat(out)
            end
        end
        f.close()

        if #rows == 0 then
            self.status = "Empty picture"
            win.dirty = true
            return
        end

        canvas, cw, chh = {}, 0, 0
        local widest = 0
        for _, row in ipairs(rows) do widest = math.max(widest, #row) end
        ensureCanvas(widest, #rows)
        for y = 1, #rows do
            local row = rows[y]
            if #row < cw then row = row .. string.rep(string.char(WHITE), cw - #row) end
            canvas[y] = row:sub(1, cw)
        end
        for y = #rows + 1, chh do
            canvas[y] = string.rep(string.char(WHITE), cw)
        end
        self.path = path
        self.undo = nil
        self.oy = 0
        self.status = "Opened " .. fs.getName(path)
        setTitle()
        win.dirty = true
    end

    local function openFile()
        dialogs.open(win, {
            type = "file",
            title = "Open picture",
            path = (state and state.settings and state.settings.lastPath) or "/",
            filter = function(p)
                if fs.isDir(p) then return true end
                return p:match("%.cwp$") ~= nil or p:match("%.nfp$") ~= nil
            end,
            onPick = function(p) loadFrom(p) end,
        })
    end

    -------------------------------------------------------------------
    -- layout
    -------------------------------------------------------------------

    local function canvasArea(w, h)
        return 2, TOOLBAR_H + 2, w - 4, h - TOOLBAR_H - COLOUR_H - STATUS_H - 6
    end

    local function fileRects()
        return {
            new = { 4, 3, 34, BTN_H },
            open = { 41, 3, 40, BTN_H },
            save = { 84, 3, 40, BTN_H },
        }
    end

    local function statusRects(w, h)
        local y = h - STATUS_H
        local list = {}
        local colours = theme.paintColours()
        local sw, sh = 11, 9
        local x0 = 4
        for i, index in ipairs(colours) do
            local col = (i - 1) % 16
            local row = math.floor((i - 1) / 16)
            list[i] = { x0 + col * sw, y - COLOUR_H + 4 + row * sh, sw - 1, sh - 1, index }
        end
        return list, y
    end

    -------------------------------------------------------------------
    -- drawing
    -------------------------------------------------------------------

    local function hot(x, y, r)
        return r and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
    end

    function self:draw(dc, w, h)
        dc:fill(0, 0, w, h, C.face)

        -- toolbar: file buttons on the first row, tools on the second
        theme.band(dc, 0, 0, w, TOOLBAR_H, nil)
        local fr = fileRects()
        widgets.button(dc, fr.new[1], fr.new[2], fr.new[3], fr.new[4], "New",
            { state = self.hover == "new" and "hover" or nil })
        widgets.button(dc, fr.open[1], fr.open[2], fr.open[3], fr.open[4], "Open",
            { state = self.hover == "open" and "hover" or nil })
        widgets.button(dc, fr.save[1], fr.save[2], fr.save[3], fr.save[4], "Save",
            { state = self.hover == "save" and "hover" or nil })
        self.rects.file = fr

        local x = 4
        self.rects.tools = {}
        for i, t in ipairs(TOOLS) do
            local bw = dc:textWidth(t.label) + 12
            local r = { x, 19, bw, BTN_H, t.id }
            self.rects.tools[i] = r
            widgets.button(dc, r[1], r[2], r[3], r[4], t.label,
                { state = (self.tool == t.id and "down") or (self.hover == t.id and "hover" or nil) })
            x = x + bw + 3
        end

        -- canvas
        local ax, ay, aw, ah = canvasArea(w, h)
        ensureCanvas(aw, ah)
        dc:fill(ax, ay, aw, ah, C.bevelShadow)
        dc:pushClip(ax, ay, aw, ah)
        local maxOy = math.max(0, chh - ah)
        if self.oy > maxOy then self.oy = maxOy end
        for row = 1, chh do
            local y = ay + row - 1 - self.oy
            if y >= ay and y < ay + ah then
                dc:blit(ax, y, canvas[row])
            end
        end

        -- rubber band preview
        if self.preview then
            local p = self.preview
            local colour = self.tool == "erase" and WHITE or self.colour
            local ox, oy = ax, ay - self.oy
            if p.tool == "line" then
                dc:line(ox + p.x0, oy + p.y0, ox + p.x1, oy + p.y1, colour)
            elseif p.tool == "box" then
                dc:rect(ox + math.min(p.x0, p.x1), oy + math.min(p.y0, p.y1),
                    math.abs(p.x1 - p.x0) + 1, math.abs(p.y1 - p.y0) + 1, colour)
            end
        end
        dc:popClip()
        dc:rect(ax, ay, aw, ah, C.bevelDark)
        self.rects.canvas = { ax, ay, aw, ah }

        -- colour bar
        local cr, statusY = statusRects(w, h)
        dc:fill(0, statusY - COLOUR_H, w, COLOUR_H, C.face)
        dc:fill(0, statusY - COLOUR_H, w, 1, C.bevelMid)
        for i, r in ipairs(cr) do
            dc:fill(r[1], r[2], r[3], r[4], r[5])
            if r[5] == self.colour then
                dc:rect(r[1] - 1, r[2] - 1, r[3] + 2, r[4] + 2, C.white)
                dc:rect(r[1] - 2, r[2] - 2, r[3] + 4, r[4] + 4, C.accent)
            else
                dc:rect(r[1], r[2], r[3], r[4], C.bevelDark)
            end
        end
        self.rects.colours = cr

        -- status bar
        dc:fill(0, statusY, w, STATUS_H, C.face)
        dc:fill(0, statusY, w, 1, C.bevelMid)
        local label = self.status
        if label == "" then
            label = (self.path and fs.getName(self.path) or "Untitled")
        end
        if self.pointer then
            label = string.format("%s   (%d, %d)   %s",
                label, self.pointer[1], self.pointer[2], self.tool)
        else
            label = label .. "   " .. self.tool
        end
        dc:text(4, statusY + 3, widgets.ellipsis(label, w - 8), C.textMuted)
    end

    -------------------------------------------------------------------
    -- input
    -------------------------------------------------------------------

    local function canvasHit(x, y, w, h)
        local ax, ay, aw, ah = canvasArea(w, h)
        if not widgets.inside(x, y, ax, ay, aw, ah) then return nil end
        return x - ax, y - ay + self.oy
    end

    local function paintStroke(x0, y0, x1, y1, colour)
        if x0 == x1 and y0 == y1 then
            setPx(x1, y1, colour)
        else
            lineTo(x0, y0, x1, y1, colour)
        end
    end

    function self:click(x, y, button, double)
        local w, h = dc_size(win)
        local fr = self.rects.file or fileRects()

        if button == 1 then
            if hot(x, y, fr.new) then
                clearCanvas()
                self.path = nil
                self.status = ""
                setTitle()
                return true
            elseif hot(x, y, fr.open) then
                openFile()
                return true
            elseif hot(x, y, fr.save) then
                save()
                return true
            end
            for _, r in ipairs(self.rects.tools or {}) do
                if hot(x, y, r) then
                    self.tool = r[5]
                    win.dirty = true
                    return true
                end
            end
            for _, r in ipairs(self.rects.colours or {}) do
                if hot(x, y, r) then
                    self.colour = r[5]
                    win.dirty = true
                    return true
                end
            end
        end

        local px, py = canvasHit(x, y, w, h)
        if not px then return true end

        if button == 3 then
            -- right button always erases
            snapshot()
            setPx(px, py, WHITE)
            self.last = { px, py }
            win.dirty = true
            return true
        end
        if button ~= 1 then return true end

        snapshot()
        local colour = self.colour
        if self.tool == "pencil" or self.tool == "erase" then
            local c = self.tool == "erase" and WHITE or colour
            setPx(px, py, c)
            self.last = { px, py }
        elseif self.tool == "fill" then
            floodFill(px, py, colour)
        elseif self.tool == "pick" then
            local c = getPx(px, py)
            if c then self.colour = c end
            self.undo = nil
        else
            self.preview = { tool = self.tool, x0 = px, y0 = py, x1 = px, y1 = py }
        end
        win.dirty = true
        return true
    end

    function self:drag(x, y, button)
        local w, h = dc_size(win)
        local px, py = canvasHit(x, y, w, h)

        local newHover = nil
        local fr = self.rects.file or fileRects()
        if hot(x, y, fr.new) then newHover = "new"
        elseif hot(x, y, fr.open) then newHover = "open"
        elseif hot(x, y, fr.save) then newHover = "save" end
        if not newHover then
            for _, r in ipairs(self.rects.tools or {}) do
                if hot(x, y, r) then newHover = r[5] end
            end
        end
        if newHover ~= self.hover then
            self.hover = newHover
            win.dirty = true
        end

        if not px then
            self.pointer = nil
            return true
        end
        self.pointer = { px, py }

        if self.preview then
            self.preview.x1, self.preview.y1 = px, py
            win.dirty = true
        elseif self.last and (button == 1 or button == 3) then
            local c = (button == 3 or self.tool == "erase") and WHITE or self.colour
            paintStroke(self.last[1], self.last[2], px, py, c)
            self.last = { px, py }
            win.dirty = true
        else
            win.dirty = true
        end
        return true
    end

    function self:up(x, y, button)
        local w, h = dc_size(win)
        local px, py = canvasHit(x, y, w, h)
        if self.preview and px then
            local p = self.preview
            p.x1, p.y1 = px, py
            if p.tool == "line" then
                lineTo(p.x0, p.y0, p.x1, p.y1, self.colour)
            elseif p.tool == "box" then
                outline(p.x0, p.y0, p.x1, p.y1, self.colour)
            end
            self.preview = nil
            win.dirty = true
        end
        self.preview = nil
        self.last = nil
        return true
    end

    function self:scroll(x, y, dir)
        local w, h = dc_size(win)
        local _, _, aw, ah = canvasArea(w, h)
        local maxOy = math.max(0, chh - ah)
        self.oy = math.max(0, math.min(maxOy, self.oy + dir * 3))
        win.dirty = true
        return true
    end

    function self:key(key)
        if key == keys.leftCtrl or key == keys.rightCtrl then
            self.ctrl = true
            return true
        end
        if self.ctrl then
            if key == keys.z then restore(); return true end
            if key == keys.s then save(); return true end
            if key == keys.o then openFile(); return true end
        end
        for _, t in ipairs(TOOLS) do
            if key == t.key then
                self.tool = t.id
                win.dirty = true
                return true
            end
        end
        if key == keys.s then save(); return true end
        return true
    end

    function self:key_up(key)
        if key == keys.leftCtrl or key == keys.rightCtrl then self.ctrl = false end
    end

    function self:char() return true end

    -------------------------------------------------------------------
    -- boot
    -------------------------------------------------------------------

    setTitle()
    if self.path and fs.exists(self.path) then loadFrom(self.path) end
    return self
end

return app
