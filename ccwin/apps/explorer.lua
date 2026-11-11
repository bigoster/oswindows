--- CC-Windows - File Explorer.
local app = {}

app.id = "explorer"
app.name = "Files"
app.icon = "folder"
app.defaultSize = { 260, 170 }

local widgets, icons, dialogs, theme, C
local state

local ROW_H = 13
local TOOLBAR_H = 20
local STATUS_H = 14

local HOME = "/"

--- Content size of a window (client area).
local function dc_size(win)
    if win.content then return win.content.w, win.content.h end
    return 1, 1
end

local function sortEntries(items)
    local dirs, files = {}, {}
    for _, item in ipairs(items) do
        if item.isDir then dirs[#dirs + 1] = item else files[#files + 1] = item end
    end
    table.sort(dirs, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    local out = {}
    for _, d in ipairs(dirs) do out[#out + 1] = d end
    for _, f in ipairs(files) do out[#out + 1] = f end
    return out
end

function app.create(win, opts, ctx)
    widgets, icons, dialogs = ctx.widgets, ctx.icons, ctx.dialogs
    theme, C = ctx.theme, ctx.theme.C
    state = ctx.state

    local self = {
        path = (opts and opts.path) or HOME,
        items = {},
        offset = 0,
        selected = nil,
        hover = nil,
        status = "",
        caret = nil,
        press = nil,        -- row held down, may become a drag
        dragging = nil,     -- name of the file being moved
        dropTarget = nil,   -- folder row a dragged file would land in
        dragX = nil, dragY = nil,
    }

    -------------------------------------------------------------------
    -- listing
    -------------------------------------------------------------------

    local function refresh()
        local list = {}
        local ok, entries = pcall(fs.list, self.path)
        if ok and entries then
            for _, name in ipairs(entries) do
                local full = fs.combine(self.path, name)
                list[#list + 1] = {
                    name = name,
                    path = full,
                    isDir = fs.isDir(full),
                }
            end
        end
        self.items = sortEntries(list)
        self.offset = 0
        self.selected = nil
        win.dirty = true
    end
    self.refresh = refresh

    local function visible(cw, ch)
        local listH = ch - TOOLBAR_H - STATUS_H - 4
        return math.max(1, math.floor(listH / ROW_H)), listH
    end

    local function navigate(path)
        self.path = path
        refresh()
        if state and state.settings then
            state.settings.lastPath = path
            if state.save then state.save() end
        end
    end
    self.navigate = navigate

    local function isBinary(path)
        local f = fs.open(path, "r")
        if not f then return true end
        local head = f.read(512) or ""
        f.close()
        return head:find("\0", 1, true) ~= nil
    end

    local function openItem(item)
        if item.isDir then
            navigate(item.path)
        elseif item.name:match("%.lua$") then
            -- A program: ours opens as a real window, anything else runs
            -- in the CraftOS console. Notepad stays one right-click away
            -- through "Open in Notepad".
            if ctx.programs and ctx.programs.open then
                ctx.programs.open(item.path)
            else
                ctx.launch("console", { program = item.path })
            end
        else
            -- hand text files to the editor, everything else says hello
            local editor = ctx.wm and ctx.wm.context().apps and ctx.wm.context().apps.editor
            if editor and not isBinary(item.path) then
                ctx.launch("editor", { path = item.path })
            else
                dialogs.open(win, {
                    type = "confirm",
                    title = item.name,
                    message = "No application is registered\nfor this file type.\n\n" .. item.path,
                    buttons = { "OK" },
                })
            end
        end
    end

    -------------------------------------------------------------------
    -- toolbar
    -------------------------------------------------------------------

    local function toolbarRects(cw)
        local r = {}
        local x = 4
        r.back = { x, 3, 18, 14 }
        x = x + 21
        r.up = { x, 3, 18, 14 }
        x = x + 21
        r.home = { x, 3, 18, 14 }
        x = x + 22
        r.path = { x, 3, cw - x - 96, 14 }
        x = cw - 92
        r.newFolder = { x, 3, 44, 14 }
        x = x + 46
        r.newFile = { x, 3, 44, 14 }
        return r
    end

    local history = {}
    local histIndex = 0

    local function pushHistory(path)
        for i = #history, histIndex + 1, -1 do history[i] = nil end
        history[#history + 1] = path
        histIndex = #history
    end

    local realNavigate = navigate
    navigate = function(path)
        pushHistory(path)
        realNavigate(path)
    end
    self.navigate = navigate

    -- seed history
    history[1] = self.path
    histIndex = 1

    -------------------------------------------------------------------
    -- drawing
    -------------------------------------------------------------------

    local function hot(x, y, r)
        return r and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
    end

    local function drawGlyph(dc, r, kind, enabled)
        local face = (self.hover == kind) and C.faceHover or C.face
        if not enabled then face = C.faceDown end
        dc:fill(r[1], r[2], r[3], r[4], face)
        dc:rect(r[1], r[2], r[3], r[4], self.hover == kind and C.accent or C.bevelDark)
        local cx, cy = r[1] + math.floor(r[3] / 2), r[2] + math.floor(r[4] / 2)
        local col = enabled and C.text or C.textMuted
        if kind == "back" or kind == "up" then
            local dir = (kind == "back") and -1 or -1
            local dy = (kind == "up") and -1 or 0
            if kind == "back" then
                dc:line(cx + 3, cy, cx - 3, cy - 4, col)
                dc:line(cx + 3, cy, cx - 3, cy + 4, col)
                dc:fill(cx - 3, cy - 4, 1, 9, col)
            else
                dc:line(cx, cy + 4, cx - 4, cy, col)
                dc:line(cx, cy + 4, cx + 4, cy, col)
                dc:fill(cx - 4, cy, 9, 1, col)
            end
        elseif kind == "home" then
            icons.draw(dc, "computer", cx - 4, cy - 4, 1)
        end
    end

    function self:draw(dc, cw, ch)
        dc:fill(0, 0, cw, ch, C.face)

        -- toolbar band
        theme.band(dc, 0, 0, cw, TOOLBAR_H, nil)
        local r = toolbarRects(cw)
        drawGlyph(dc, r.back, "back", histIndex > 1)
        drawGlyph(dc, r.up, "up", self.path ~= "/" and self.path ~= "")
        drawGlyph(dc, r.home, "home", true)

        -- address bar
        widgets.fieldDraw(dc, r.path[1], r.path[2], r.path[3], r.path[4],
            { text = self.path, caret = #self.path, scroll = 0 }, self.caret, false)
        dc:text(r.path[1] + 3, r.path[2] + 3, "", C.text)

        -- new folder / new file
        widgets.button(dc, r.newFolder[1], r.newFolder[2], r.newFolder[3], r.newFolder[4],
            "Folder", { state = self.hover == "newFolder" and "hover" or nil })
        widgets.button(dc, r.newFile[1], r.newFile[2], r.newFile[3], r.newFile[4],
            "File", { state = self.hover == "newFile" and "hover" or nil })
        self.rects = r

        -- list area
        local listY = TOOLBAR_H
        local count, listH = visible(cw, ch)
        local listW = cw - 14
        theme.field(dc, 3, listY, listW, listH, false)
        dc:pushClip(4, listY + 2, listW - 2, listH - 4)

        local maxOffset = math.max(0, #self.items - count)
        if self.offset > maxOffset then self.offset = maxOffset end

        for i = 1, math.min(count, #self.items - self.offset) do
            local item = self.items[i + self.offset]
            local iy = listY + 2 + (i - 1) * ROW_H
            local stateName = nil
            if self.selected == i + self.offset then
                stateName = "selected"
            elseif self.hover == "row" .. (i + self.offset)
                or self.dropTarget == i + self.offset then
                stateName = "hover"
            end
            widgets.listRow(dc, 4, iy, listW - 2, ROW_H, stateName)
            if self.dropTarget == i + self.offset then
                -- the folder a dragged file would land in
                dc:rect(4, iy, listW - 2, ROW_H, C.accent)
            end
            local colour = stateName == "selected" and C.white or C.text
            if item.isDir then
                icons.draw(dc, "folder", 6, iy + 2, 1)
            else
                icons.draw(dc, "file", 6, iy + 2, 1)
            end
            dc:text(18, iy + 2, widgets.ellipsis(item.name, listW - 40), colour)
            if not item.isDir then
                local size = "-"
                local ok, sz = pcall(fs.getSize, item.path)
                if ok then size = widgets.formatBytes(sz) end
                local sw = dc:textWidth(size)
                dc:text(listW - 6 - sw, iy + 2, size, stateName == "selected" and C.white or C.textMuted)
            end
        end
        dc:popClip()

        if #self.items > count then
            widgets.scrollV(dc, 3 + listW - 10, listY + 2, 8, listH - 4,
                self.offset, #self.items, count, self.hover == "scroll")
        end

        -- status bar
        local sy = ch - STATUS_H
        dc:fill(0, sy, cw, STATUS_H, C.face)
        dc:fill(0, sy, cw, 1, C.bevelMid)
        local label = self.status
        if label == "" then
            label = tostring(#self.items) .. " items"
            if self.selected and self.items[self.selected] then
                label = label .. "   |   " .. self.items[self.selected].name
            end
        end
        dc:text(4, sy + 3, widgets.ellipsis(label, cw - 8), C.textMuted)

        -- drag ghost: the name of the file being moved, following the cursor
        if self.dragging then
            local text = widgets.ellipsis(self.dragging, cw - 12)
            local gw = dc:textWidth(text) + 8
            local gx, gy = self.dragX or 0, self.dragY or 0
            if gx + gw > cw then gx = math.max(0, cw - gw) end
            if gy + 13 > ch then gy = math.max(0, ch - 13) end
            dc:fill(gx + 2, gy + 2, gw, 13, C.shadow)
            dc:fill(gx, gy, gw, 13, C.face)
            dc:rect(gx, gy, gw, 13, C.accent)
            dc:text(gx + 4, gy + 3, text, C.text)
        end
    end

    -------------------------------------------------------------------
    -- input
    -------------------------------------------------------------------

    local function rowAtY(y, ch)
        local listY = TOOLBAR_H
        if y < listY + 2 then return nil end
        local count = visible(0, ch)
        local index = math.floor((y - listY - 2) / ROW_H) + 1 + self.offset
        if index < 1 or index > #self.items then return nil end
        if index > self.offset + count then return nil end
        return index
    end

    local function toolbarHover(x, y, cw)
        local r = toolbarRects(cw)
        if hot(x, y, r.back) then return "back" end
        if hot(x, y, r.up) then return "up" end
        if hot(x, y, r.home) then return "home" end
        if hot(x, y, r.newFolder) then return "newFolder" end
        if hot(x, y, r.newFile) then return "newFile" end
        return nil
    end

    local function askNew(kind)
        dialogs.open(win, {
            type = "prompt",
            title = kind == "folder" and "New folder" or "New file",
            label = kind == "folder" and "Folder name:" or "File name:",
            initial = kind == "folder" and "New folder" or "new.txt",
            onSubmit = function(text)
                if text and text ~= "" then
                    local full = fs.combine(self.path, text)
                    local ok, err
                    if kind == "folder" then
                        ok, err = pcall(fs.makeDir, full)
                    else
                        ok, err = pcall(function()
                            if not fs.exists(full) then
                                local f = fs.open(full, "w")
                                f.close()
                            end
                        end)
                    end
                    if not ok then
                        self.status = "Error: " .. tostring(err)
                    else
                        self.status = ""
                        refresh()
                    end
                end
            end,
        })
    end

    local function askDelete(item)
        dialogs.open(win, {
            type = "confirm",
            title = "Delete",
            message = "Delete '" .. item.name .. "'?",
            buttons = { "Delete", "Cancel" },
            onResult = function(n)
                if n == 1 then
                    local ok, err = pcall(fs.delete, item.path)
                    if ok then
                        self.status = ""
                        refresh()
                    else
                        self.status = "Error: " .. tostring(err)
                    end
                end
            end,
        })
    end

    --- Drop a shortcut to this item on the desktop.
    local function createLink(item)
        if not ctx.shortcuts or not ctx.shortcuts.create then
            self.status = "Shortcuts are not available"
            win.dirty = true
            return
        end
        local e = ctx.shortcuts.create { kind = "file", target = item.path }
        self.status = e and "Link created on the desktop"
            or "Error: could not create link"
        win.dirty = true
    end

    --- Hand this program to another computer and let it run there.
    local function runOn(item, id)
        if not ctx.fabric then
            self.status = "The fabric link is not available"
            win.dirty = true
            return
        end
        local name = ctx.fabric.peerName(id)
        self.status = "Sending " .. item.name .. " to " .. name .. "..."
        win.dirty = true
        ctx.fabric.runOn(id, item.path, function(ok, msg)
            self.status = ok and (name .. ": " .. (msg or "started"))
                or ("Error: " .. (msg or "could not run it there"))
            win.dirty = true
        end)
    end

    --- The "Run on" submenu: only for programs, and only when there is
    -- someone on the other end of the fabric link to run them.
    local function runOnItems(item)
        local fab = ctx.fabric
        if not fab or not fab.present() then return nil end
        if item.isDir or not item.name:match("%.lua$") then return nil end
        local peers = fab.peers()
        if #peers == 0 then return nil end
        local items = {}
        for _, p in ipairs(peers) do
            local id = p.id
            items[#items + 1] = {
                label = fab.peerName(id),
                icon = "computer",
                onPick = function() runOn(item, id) end,
            }
        end
        return items
    end

    --- Right-click menu for a row (screen coordinates).
    local function openItemMenu(item, sx, sy)
        if not ctx.menu then return end
        local items = {
            { label = "Open", icon = item.isDir and "folder" or "file",
              onPick = function() openItem(item) end },
        }
        -- Open runs a .lua program now, so the editor needs its own way in.
        if not item.isDir and item.name:match("%.lua$") then
            items[#items + 1] = {
                label = "Open in Notepad", icon = "editor",
                onPick = function()
                    ctx.launch("editor", { path = item.path })
                end,
            }
        end
        items[#items + 1] = { label = "Create link", icon = "file",
                              onPick = function() createLink(item) end }
        local runItems = runOnItems(item)
        if runItems then
            items[#items + 1] = {
                label = "Run on", icon = "computer", submenu = runItems,
            }
        end
        items[#items + 1] = { sep = true }
        items[#items + 1] = { label = "Delete",
                              onPick = function() askDelete(item) end }
        ctx.menu.open { x = sx, y = sy, items = items }
    end

    function self:click(x, y, button, double)
        local cw, ch = dc_size(win)
        local r = self.rects or toolbarRects(cw)

        if button == 3 then
            local index = rowAtY(y, ch)
            if index and self.items[index] then askDelete(self.items[index]) end
            return true
        end
        if button == 2 then
            -- right-click a row: open it, link it or delete it
            local index = rowAtY(y, ch)
            if index and self.items[index] then
                self.selected = index
                openItemMenu(self.items[index],
                    win.content.x + x, win.content.y + y)
                win.dirty = true
            end
            return true
        end
        if button ~= 1 then return true end
        self.press = nil
        self.dragging = nil
        self.dropTarget = nil

        if hot(x, y, r.back) then
            if histIndex > 1 then
                histIndex = histIndex - 1
                realNavigate(history[histIndex])
            end
            return true
        elseif hot(x, y, r.up) then
            local parent = fs.getDir(self.path)
            if parent == "" then parent = "/" end
            navigate(parent)
            return true
        elseif hot(x, y, r.home) then
            navigate(HOME)
            return true
        elseif hot(x, y, r.newFolder) then
            askNew("folder")
            return true
        elseif hot(x, y, r.newFile) then
            askNew("file")
            return true
        end

        local index = rowAtY(y, ch)
        if index then
            self.status = ""
            self.selected = index
            if double then
                openItem(self.items[index])
            else
                -- held down: may turn into a drag onto a folder
                self.press = { index = index, x0 = x, y0 = y, moved = false }
            end
            win.dirty = true
            return true
        end
        self.selected = nil
        win.dirty = true
        return true
    end

    --- Hover tracking, and moving a row onto a folder while it is held.
    function self:drag(x, y)
        local cw, ch = dc_size(win)

        if self.press then
            local dx, dy = x - self.press.x0, y - self.press.y0
            if not self.press.moved and (math.abs(dx) >= 4 or math.abs(dy) >= 4) then
                -- past the drag threshold: this is now a move, not a click
                local item = self.items[self.press.index]
                if item then
                    self.press.moved = true
                    self.dragging = item.name
                    self.dropTarget = nil
                    self.status = "Drop on a folder to move"
                    win.dirty = true
                else
                    self.press = nil
                end
            end

            if self.press and self.press.moved then
                local item = self.items[self.press.index]
                if not item then
                    self.press, self.dragging, self.dropTarget = nil, nil, nil
                    self.status = ""
                    win.dirty = true
                    return true
                end
                self.dragX, self.dragY = x, y
                local target = rowAtY(y, ch)
                if target then
                    local it = self.items[target]
                    -- only a real folder counts, and never into itself
                    if not it or not it.isDir or target == self.press.index
                        or (item.isDir and it.path:find(item.path .. "/", 1, true)) then
                        target = nil
                    end
                end
                if target ~= self.dropTarget then
                    self.dropTarget = target
                    self.status = target
                        and ("Move to " .. self.items[target].name)
                        or "Drop on a folder to move"
                    win.dirty = true
                end
                win.dirty = true
                return true
            end
        end

        local newHover = toolbarHover(x, y, cw)
        local index = rowAtY(y, ch)
        if index and y >= TOOLBAR_H and y < ch - STATUS_H then
            newHover = "row" .. index
        end
        if newHover ~= self.hover then
            self.hover = newHover
            win.dirty = true
            return true
        end
        return false
    end

    --- Release: commit the move if a folder was under the cursor.
    function self:up(x, y, button)
        local p = self.press
        if not p then return false end
        self.press = nil
        if button ~= 1 or not p.moved then
            win.dirty = true
            return true
        end

        local src = self.items[p.index]
        local dst = self.dropTarget and self.items[self.dropTarget] or nil
        self.dragging = nil
        self.dropTarget = nil

        if src and dst and dst.isDir then
            local to = fs.combine(dst.path, src.name)
            local ok, err = pcall(fs.move, src.path, to)
            if ok and fs.exists(to) then
                self.status = "Moved " .. src.name .. " to " .. dst.name
            else
                self.status = "Error: " .. tostring(ok and "could not move" or err)
            end
        else
            self.status = ""
        end
        refresh()
        return true
    end

    function self:scroll(x, y, dir)
        local cw, ch = dc_size(win)
        local count = select(1, visible(cw, ch))
        self.offset = widgets.scrollWheel(self.offset, #self.items, count, dir, 3)
        win.dirty = true
        return true
    end

    function self:key(key)
        local count = select(1, visible(dc_size(win)))
        if key == keys.f5 then
            refresh()
            return true
        elseif key == keys.delete and self.selected and self.items[self.selected] then
            askDelete(self.items[self.selected])
            return true
        elseif key == keys.enter and self.selected and self.items[self.selected] then
            openItem(self.items[self.selected])
            return true
        elseif key == keys.up then
            if self.selected and self.selected > 1 then self.selected = self.selected - 1 end
            if (self.selected or 1) <= self.offset then
                self.offset = math.max(0, (self.selected or 1) - 1)
            end
            win.dirty = true
            return true
        elseif key == keys.down then
            if self.selected and self.selected < #self.items then
                self.selected = self.selected + 1
            elseif not self.selected and #self.items > 0 then
                self.selected = 1
            end
            if self.selected and self.selected > self.offset + count then
                self.offset = self.selected - count
            end
            win.dirty = true
            return true
        elseif key == keys.backspace then
            local parent = fs.getDir(self.path)
            if parent == "" then parent = "/" end
            if parent ~= self.path then navigate(parent) end
            return true
        end
        return false
    end

    refresh()
    return self
end

return app
