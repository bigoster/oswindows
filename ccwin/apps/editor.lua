--- CC-Windows - Notepad-style text editor.
local app = {}

app.id = "editor"
app.name = "Notepad"
app.icon = "editor"
app.defaultSize = { 280, 190 }

local theme, widgets, dialogs, C
local state

local GUTTER = 26
local STATUS_H = 14
local TOOLBAR_H = 20
local LINE_H = 10

local function dc_size(win)
    if win.content then return win.content.w, win.content.h end
    return 1, 1
end

function app.create(win, opts, ctx)
    theme, widgets, dialogs = ctx.theme, ctx.widgets, ctx.dialogs
    C = theme.C
    state = ctx.state

    local self = {
        path = opts and opts.path or nil,
        lines = { "" },
        row = 1,
        col = 1,           -- character index within line (1-based)
        top = 1,           -- first visible line
        left = 0,          -- horizontal pixel scroll
        modified = false,
        hover = nil,
        rects = {},
        status = "",
    }

    -------------------------------------------------------------------
    -- file handling
    -------------------------------------------------------------------

    local function title()
        local name = self.path and fs.getName(self.path) or "Untitled"
        local flag = self.modified and " *" or ""
        ctx.wm.setTitle(win, name .. flag .. " - Notepad")
    end

    local function loadFile(path)
        local f = fs.open(path, "r")
        if not f then return false, "Cannot open " .. path end
        local lines = {}
        while true do
            local line = f.readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
        f.close()
        if #lines == 0 then lines = { "" } end
        self.lines = lines
        self.path = path
        self.row, self.col, self.top, self.left = 1, 1, 1, 0
        self.modified = false
        self.status = ""
        title()
        win.dirty = true
        return true
    end
    self.loadFile = loadFile

    local function saveFile(path)
        if not path then return end
        local f = fs.open(path, "w")
        if not f then
            self.status = "Cannot write " .. path
            win.dirty = true
            return
        end
        for _, line in ipairs(self.lines) do f.writeLine(line) end
        f.close()
        self.path = path
        self.modified = false
        self.status = "Saved " .. fs.getName(path)
        title()
        win.dirty = true
    end

    local function save()
        if self.path then
            saveFile(self.path)
        else
            dialogs.open(win, {
                type = "prompt",
                title = "Save as",
                label = "File name:",
                initial = "/untitled.txt",
                onSubmit = function(text)
                    if text and text ~= "" then saveFile(text) end
                end,
            })
        end
    end
    self.save = save

    local function confirmDiscard(thenFn)
        if not self.modified then thenFn() return end
        dialogs.open(win, {
            type = "confirm",
            title = "Notepad",
            message = "Save changes to " ..
                (self.path and fs.getName(self.path) or "Untitled") .. " ?",
            buttons = { "Save", "Don't save", "Cancel" },
            onResult = function(n)
                if n == 1 then
                    if self.path then
                        saveFile(self.path)
                        thenFn()
                    else
                        dialogs.open(win, {
                            type = "prompt",
                            title = "Save as",
                            label = "File name:",
                            initial = "/untitled.txt",
                            onSubmit = function(text)
                                if text and text ~= "" then
                                    saveFile(text)
                                    thenFn()
                                end
                            end,
                        })
                    end
                elseif n == 2 then
                    thenFn()
                end
            end,
        })
    end
    self.confirmDiscard = confirmDiscard

    local function openFileDialog()
        dialogs.open(win, {
            type = "file",
            title = "Open file",
            path = (state and state.settings and state.settings.lastPath) or "/",
            filter = function(path)
                if fs.isDir(path) then return true end
                return not path:match("%.png$") and not path:match("%.nfp$")
            end,
            onPick = function(path)
                confirmDiscard(function()
                    loadFile(path)
                end)
            end,
        })
    end
    self.openFileDialog = openFileDialog

    -------------------------------------------------------------------
    -- cursor helpers
    -------------------------------------------------------------------

    local function curLine() return self.lines[self.row] or "" end

    local function clampCol()
        local len = #curLine()
        if self.col > len + 1 then self.col = len + 1 end
        if self.col < 1 then self.col = 1 end
    end

    local function ensureVisible(cw, ch)
        local rows = math.max(1, math.floor((ch - TOOLBAR_H - STATUS_H - 4) / LINE_H))
        if self.row < self.top then self.top = self.row end
        if self.row >= self.top + rows then self.top = self.row - rows + 1 end
        if self.top < 1 then self.top = 1 end

        local cols = math.max(1, math.floor((cw - GUTTER - 8) / 6))
        local col0 = self.col - 1            -- zero-based caret column
        if col0 < self.left then self.left = col0 end
        if col0 >= self.left + cols then self.left = col0 - cols + 1 end
        if self.left < 0 then self.left = 0 end
    end

    -------------------------------------------------------------------
    -- editing
    -------------------------------------------------------------------

    local function insert(str)
        local line = curLine()
        self.lines[self.row] = line:sub(1, self.col - 1) .. str .. line:sub(self.col)
        self.col = self.col + #str
        self.modified = true
        title()
    end

    local function backspace()
        if self.col > 1 then
            local line = curLine()
            self.lines[self.row] = line:sub(1, self.col - 2) .. line:sub(self.col)
            self.col = self.col - 1
            self.modified = true
        elseif self.row > 1 then
            local prev = self.lines[self.row - 1]
            self.lines[self.row - 1] = prev .. curLine()
            table.remove(self.lines, self.row)
            self.row = self.row - 1
            self.col = #prev + 1
            self.modified = true
        end
        title()
    end

    local function deleteChar()
        local line = curLine()
        if self.col <= #line then
            self.lines[self.row] = line:sub(1, self.col - 1) .. line:sub(self.col + 1)
            self.modified = true
        elseif self.row < #self.lines then
            self.lines[self.row] = line .. self.lines[self.row + 1]
            table.remove(self.lines, self.row + 1)
            self.modified = true
        end
        title()
    end

    local function newline()
        local line = curLine()
        local tail = line:sub(self.col)
        self.lines[self.row] = line:sub(1, self.col - 1)
        table.insert(self.lines, self.row + 1, tail)
        self.row = self.row + 1
        -- keep the previous line's indentation
        local indent = (line:match("^[ \t]*") or "")
        if indent ~= "" then
            self.lines[self.row] = indent .. self.lines[self.row]
            self.col = #indent + 1
        else
            self.col = 1
        end
        self.modified = true
        title()
    end

    -------------------------------------------------------------------
    -- drawing
    -------------------------------------------------------------------

    local function toolbarRects(cw)
        local r = {}
        local x = 4
        r.new = { x, 3, 34, 14 }; x = x + 36
        r.open = { x, 3, 34, 14 }; x = x + 36
        r.save = { x, 3, 34, 14 }; x = x + 40
        return r
    end

    local function hot(x, y, r)
        return r and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
    end

    local blink = 0

    function self:draw(dc, cw, ch)
        dc:fill(0, 0, cw, ch, C.face)

        -- toolbar
        theme.band(dc, 0, 0, cw, TOOLBAR_H, nil)
        local r = toolbarRects(cw)
        widgets.button(dc, r.new[1], r.new[2], r.new[3], r.new[4], "New",
            { state = self.hover == "new" and "hover" or nil })
        widgets.button(dc, r.open[1], r.open[2], r.open[3], r.open[4], "Open",
            { state = self.hover == "open" and "hover" or nil })
        widgets.button(dc, r.save[1], r.save[2], r.save[3], r.save[4], "Save",
            { state = self.hover == "save" and "hover" or nil })
        self.rects = r

        local textY = TOOLBAR_H + 2
        local listH = ch - TOOLBAR_H - STATUS_H - 4
        local rows = math.max(1, math.floor(listH / LINE_H))

        -- text field background
        theme.field(dc, 2, textY, cw - 4, listH + 2, true)
        ensureVisible(cw, ch)

        dc:pushClip(3, textY + 2, cw - 6, listH)

        -- gutter
        dc:fill(3, textY + 2, GUTTER, listH, C.listAlt)
        dc:fill(3 + GUTTER, textY + 2, 1, listH, C.bevelMid)

        for i = 1, rows do
            local index = self.top + i - 1
            if index > #self.lines then break end
            local ly = textY + 2 + (i - 1) * LINE_H
            local num = tostring(index)
            dc:text(3 + GUTTER - 6 - #num * 6, ly, num,
                index == self.row and C.text or C.textMuted)
            if index == self.row then
                dc:fill(3, ly, GUTTER, LINE_H, C.accentFaint)
                dc:text(3 + GUTTER - 6 - #num * 6, ly, num, C.accent)
            end

            -- the line itself
            local line = self.lines[index]
            local shown = line
            if #shown > self.left then
                shown = shown:sub(self.left + 1)
            else
                shown = ""
            end
            local maxChars = math.floor((cw - GUTTER - 12) / 6)
            if #shown > maxChars then shown = shown:sub(1, maxChars) end
            dc:text(3 + GUTTER + 4, ly, shown, C.text)
        end

        -- caret
        blink = blink + 1
        if math.floor(blink / 6) % 2 == 0 then
            local cy = textY + 2 + (self.row - self.top) * LINE_H
            local cx = 3 + GUTTER + 4 + (self.col - 1 - self.left) * 6
            if cy >= textY + 2 and cy < textY + 2 + listH then
                dc:fill(cx, cy, 1, LINE_H - 1, C.text)
            end
        end
        dc:popClip()

        -- status bar
        local sy = ch - STATUS_H
        dc:fill(0, sy, cw, STATUS_H, C.face)
        dc:fill(0, sy, cw, 1, C.bevelMid)
        local info = string.format("Ln %d, Col %d", self.row, self.col)
        if self.status ~= "" then
            info = self.status .. "   |   " .. info
        end
        dc:text(4, sy + 3, widgets.ellipsis(info, cw - 8), C.textMuted)
    end

    function self:timer()
        win.dirty = true -- caret blink
    end

    -------------------------------------------------------------------
    -- input
    -------------------------------------------------------------------

    local function newFile()
        confirmDiscard(function()
            self.lines = { "" }
            self.path = nil
            self.row, self.col, self.top, self.left = 1, 1, 1, 0
            self.modified = false
            self.status = ""
            title()
            win.dirty = true
        end)
    end

    function self:click(x, y, button, double)
        local cw, ch = dc_size(win)
        local r = self.rects or toolbarRects(cw)
        if button == 1 then
            if hot(x, y, r.new) then newFile(); return true end
            if hot(x, y, r.open) then openFileDialog(); return true end
            if hot(x, y, r.save) then save(); return true end
        end
        -- click into the text area
        if y >= TOOLBAR_H + 2 and y < ch - STATUS_H then
            local ly = math.floor((y - (TOOLBAR_H + 4)) / LINE_H)
            local index = self.top + ly
            if index >= 1 and index <= #self.lines then
                self.row = index
                local line = self.lines[index]
                local px = x - (3 + GUTTER + 4) + self.left * 6
                local col = math.floor(px / 6) + 1
                if col < 1 then col = 1 end
                if col > #line + 1 then col = #line + 1 end
                self.col = col
                clampCol()
                win.dirty = true
            end
        end
        return true
    end

    function self:drag(x, y)
        local cw, ch = dc_size(win)
        local r = self.rects or toolbarRects(cw)
        local newHover = nil
        if hot(x, y, r.new) then newHover = "new"
        elseif hot(x, y, r.open) then newHover = "open"
        elseif hot(x, y, r.save) then newHover = "save" end
        if newHover ~= self.hover then
            self.hover = newHover
            win.dirty = true
            return true
        end
        return false
    end

    function self:scroll(x, y, dir)
        local cw, ch = dc_size(win)
        local rows = math.max(1, math.floor((ch - TOOLBAR_H - STATUS_H - 4) / LINE_H))
        local maxTop = math.max(1, #self.lines - rows + 1)
        self.top = math.min(maxTop, math.max(1, self.top + dir))
        win.dirty = true
        return true
    end

    function self:char(ch)
        if ch == "\n" or ch == "\r" then return true end
        insert(ch)
        win.dirty = true
        return true
    end

    function self:key(key)
        local cw, ch = dc_size(win)
        if key == keys.left then
            if self.col > 1 then
                self.col = self.col - 1
            elseif self.row > 1 then
                self.row = self.row - 1
                self.col = #curLine() + 1
            end
        elseif key == keys.right then
            if self.col <= #curLine() then
                self.col = self.col + 1
            elseif self.row < #self.lines then
                self.row = self.row + 1
                self.col = 1
            end
        elseif key == keys.up then
            if self.row > 1 then self.row = self.row - 1; clampCol() end
        elseif key == keys.down then
            if self.row < #self.lines then self.row = self.row + 1; clampCol() end
        elseif key == keys.home then
            self.col = 1
        elseif key == keys["end"] or key == keys.endKey then
            self.col = #curLine() + 1
        elseif key == keys.pageUp then
            local rows = math.max(1, math.floor((ch - TOOLBAR_H - STATUS_H - 4) / LINE_H))
            self.row = math.max(1, self.row - rows); clampCol()
        elseif key == keys.pageDown then
            local rows = math.max(1, math.floor((ch - TOOLBAR_H - STATUS_H - 4) / LINE_H))
            self.row = math.min(#self.lines, self.row + rows); clampCol()
        elseif key == keys.backspace then
            backspace()
        elseif key == keys.delete then
            deleteChar()
        elseif key == keys.enter then
            newline()
        elseif key == keys.tab then
            insert("    ")
        end
        clampCol()
        ensureVisible(cw, ch)
        win.dirty = true
        return true
    end

    -- Ctrl+S / Ctrl+O / Ctrl+N are delivered via the raw key event;
    -- CC sends `key` without modifiers, so we track ctrl ourselves.
    local ctrlHeld = false
    local realKey = self.key
    function self:key(key)
        if key == keys.leftCtrl or key == keys.rightCtrl then
            ctrlHeld = true
            return true
        end
        if ctrlHeld then
            if key == keys.s then save(); return true end
            if key == keys.o then openFileDialog(); return true end
            if key == keys.n then newFile(); return true end
        end
        return realKey(self, key)
    end

    function self:key_up(key)
        if key == keys.leftCtrl or key == keys.rightCtrl then ctrlHeld = false end
    end

    if self.path then loadFile(self.path) end
    title()
    return self
end

return app
