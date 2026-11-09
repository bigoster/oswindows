--- CC-Windows - modal dialogs (confirm, text prompt, file picker).
--
-- A dialog belongs to a window: it is drawn over the window's client area and
-- swallows input until it is dismissed.
local dialogs = {}

local gfx, theme, widgets, icons, C

function dialogs.attach(g, t, w, ic)
    gfx, theme, widgets, icons, C = g, t, w, ic, t.C
end

local TITLE_H = 13
local BTN_W, BTN_H = 58, 14

local function splitLines(text)
    local lines = {}
    for line in tostring(text):gmatch("[^\n]+") do lines[#lines + 1] = line end
    if #lines == 0 then lines[1] = "" end
    return lines
end

local function geometry(win, wantW, wantH)
    local c = win.content
    local w = math.min(wantW, c.w - 8)
    local h = math.min(wantH, c.h - 8)
    local x = math.floor((c.w - w) / 2)
    local y = math.floor((c.h - h) / 2)
    return x, y, w, h
end

local function refreshListing(spec)
    local items = { { name = "..", isDir = true, parent = true } }
    if spec.path == "/" or spec.path == "" then items = {} end
    local ok, entries = pcall(fs.list, spec.path)
    if ok and entries then
        local dirs, files = {}, {}
        for _, name in ipairs(entries) do
            local full = fs.combine(spec.path, name)
            if not spec.filter or spec.filter(full) then
                if fs.isDir(full) then
                    dirs[#dirs + 1] = name
                else
                    files[#files + 1] = name
                end
            end
        end
        table.sort(dirs)
        table.sort(files)
        for _, name in ipairs(dirs) do items[#items + 1] = { name = name, isDir = true } end
        for _, name in ipairs(files) do items[#items + 1] = { name = name, isDir = false } end
    end
    spec.items = items
    spec.selected = nil
    spec.offset = 0
end

function dialogs.open(win, spec)
    if spec.type == "prompt" then
        spec.field = widgets.newField(spec.initial or "")
        spec.focus = true
    elseif spec.type == "file" then
        spec.path = spec.path or "/"
        spec.offset = 0
        refreshListing(spec)
    end
    win.dialog = spec
    win.dirty = true
    return spec
end

function dialogs.close(win)
    win.dialog = nil
    win.dirty = true
end

local function drawFrame(dc, x, y, w, h, title)
    dc:fill(x + 3, y + 3, w, h, C.shadow)
    dc:fill(x, y, w, h, C.face)
    dc:rect(x, y, w, h, C.accent)
    dc:fill(x + 1, y + 1, w - 2, TITLE_H, C.accent)
    dc:text(x + 5, y + 3, widgets.ellipsis(title, w - 26), C.white)
    -- close box
    local bx = x + w - 15
    theme.button(dc, bx, y + 2, 13, TITLE_H - 4, "up")
    dc:line(bx + 4, y + 5, bx + 8, y + 9, C.text)
    dc:line(bx + 8, y + 5, bx + 4, y + 9, C.text)
    return bx, y + 2, 13, TITLE_H - 4
end

local function drawButton(dc, x, y, w, label, primary, hot)
    theme.button(dc, x, y, w, BTN_H, hot and "hover" or "up")
    if primary then
        dc:fill(x + 1, y + 1, w - 2, BTN_H - 2, C.accent)
        theme.buttonLabel(dc, x, y, w, BTN_H, label, C.white)
    else
        theme.buttonLabel(dc, x, y, w, BTN_H, label, C.text)
    end
end

---------------------------------------------------------------------------
-- drawing
---------------------------------------------------------------------------

function dialogs.draw(win, dc)
    local spec = win.dialog
    if not spec then return end
    local c = win.content
    local x, y, w, h

    if spec.type == "confirm" then
        local lines = splitLines(spec.message or "")
        local textW = 0
        for _, l in ipairs(lines) do textW = math.max(textW, dc:textWidth(l)) end
        x, y, w, h = geometry(win, math.max(textW + 24, 150), 34 + #lines * 11 + 18)
        spec.rect = { x, y, w, h }
        spec.close = { drawFrame(dc, x, y, w, h, spec.title or "Confirm") }
        local ty = y + TITLE_H + 8
        for _, l in ipairs(lines) do
            dc:text(x + 10, ty, l, C.text)
            ty = ty + 11
        end
        local by = y + h - BTN_H - 6
        local n = #(spec.buttons or { "OK" })
        local bx = x + w - 6 - n * (BTN_W + 6)
        spec.btnRects = {}
        for i, label in ipairs(spec.buttons or { "OK" }) do
            local r = { bx, by, BTN_W, BTN_H }
            spec.btnRects[i] = r
            drawButton(dc, r[1], r[2], r[3], r[4], i == 1, spec.hot == i)
            bx = bx + BTN_W + 6
        end

    elseif spec.type == "prompt" then
        x, y, w, h = geometry(win, 210, 76)
        spec.rect = { x, y, w, h }
        spec.close = { drawFrame(dc, x, y, w, h, spec.title or "Enter a value") }
        dc:text(x + 10, y + TITLE_H + 7, spec.label or "", C.textMuted)
        spec.fieldRect = { x + 10, y + TITLE_H + 20, w - 20, 14 }
        widgets.fieldDraw(dc, spec.fieldRect[1], spec.fieldRect[2], spec.fieldRect[3],
            spec.fieldRect[4], spec.field, spec.focus, spec.caret ~= false)
        local by = y + h - BTN_H - 6
        spec.okRect = { x + w - 6 - 2 * (BTN_W + 6), by, BTN_W, BTN_H }
        spec.cancelRect = { x + w - 6 - BTN_W, by, BTN_W, BTN_H }
        drawButton(dc, spec.okRect[1], by, BTN_W, "OK", true, spec.hot == "ok")
        drawButton(dc, spec.cancelRect[1], by, BTN_W, "Cancel", false, spec.hot == "cancel")

    elseif spec.type == "file" then
        x, y, w, h = geometry(win, 250, 160)
        spec.rect = { x, y, w, h }
        spec.close = { drawFrame(dc, x, y, w, h, spec.title or "Open file") }
        dc:text(x + 8, y + TITLE_H + 4, spec.path, C.textMuted)

        local listY = y + TITLE_H + 16
        local listH = h - TITLE_H - 16 - BTN_H - 14
        local rowH = 12
        local total = #spec.items
        local visible = math.floor((listH - 4) / rowH)
        local listW = w - 16 - 12
        spec.listRect = { x + 8, listY, listW, listH }
        spec.rowH, spec.visible = rowH, visible
        theme.field(dc, x + 8, listY, listW, listH, false)
        dc:pushClip(x + 9, listY + 2, listW - 2, listH - 4)
        local offset = math.min(spec.offset or 0, math.max(0, total - visible))
        spec.offset = offset
        for i = 1, math.min(visible, total - offset) do
            local item = spec.items[i + offset]
            local iy = listY + 2 + (i - 1) * rowH
            local state = nil
            if spec.selected == i + offset then state = "selected" end
            widgets.listRow(dc, x + 9, iy, listW - 2, rowH, state)
            local colour = state == "selected" and C.white or C.text
            if item.isDir then
                icons.draw(dc, "folder", x + 11, iy + 2, 1)
            else
                icons.draw(dc, "file", x + 11, iy + 2, 1)
            end
            dc:text(x + 23, iy + 2, widgets.ellipsis(item.name, listW - 30), colour)
        end
        dc:popClip()
        if total > visible then
            widgets.scrollV(dc, x + 8 + listW - 10, listY + 2, 8, listH - 4, offset, total, visible, spec.scrollHot)
        end

        local by = y + h - BTN_H - 6
        spec.okRect = { x + w - 6 - 2 * (BTN_W + 6), by, BTN_W, BTN_H }
        spec.cancelRect = { x + w - 6 - BTN_W, by, BTN_W, BTN_H }
        drawButton(dc, spec.okRect[1], by, BTN_W, "Open", true, spec.hot == "ok")
        drawButton(dc, spec.cancelRect[1], by, BTN_W, "Cancel", false, spec.hot == "cancel")
    end
end

---------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------

local function pick(spec, win)
    local item = spec.items[spec.selected]
    if not item then return end
    if item.parent then
        spec.path = fs.getDir(spec.path)
        if spec.path == "" then spec.path = "/" end
        refreshListing(spec)
        win.dirty = true
        return
    end
    local full = fs.combine(spec.path, item.name)
    if item.isDir then
        spec.path = full
        refreshListing(spec)
    else
        dialogs.close(win)
        if spec.onPick then spec.onPick(full) end
    end
    win.dirty = true
end

--- Returns true when the dialog consumed the click. `x, y` are client-relative.
function dialogs.click(win, x, y, button, double)
    local spec = win.dialog
    if not spec then return false end
    local r = spec.rect
    if not r then return false end

    local function inBox(b) return b and widgets.inside(x, y, b[1], b[2], b[3], b[4]) end

    if inBox(spec.close) then
        dialogs.close(win)
        return true
    end
    if spec.type == "confirm" then
        for i, b in ipairs(spec.btnRects or {}) do
            if inBox(b) then
                dialogs.close(win)
                if spec.onResult then spec.onResult(i) end
                return true
            end
        end
        return widgets.inside(x, y, r[1], r[2], r[3], r[4])

    elseif spec.type == "prompt" then
        if inBox(spec.okRect) then
            local text = spec.field.text
            dialogs.close(win)
            if spec.onSubmit then spec.onSubmit(text) end
            return true
        elseif inBox(spec.cancelRect) or inBox(spec.fieldRect) then
            if inBox(spec.cancelRect) then
                dialogs.close(win)
                if spec.onCancel then spec.onCancel() end
            end
            return true
        end
        return true

    elseif spec.type == "file" then
        local list = spec.listRect
        if inBox(spec.okRect) then
            pick(spec, win)
            return true
        elseif inBox(spec.cancelRect) then
            dialogs.close(win)
            if spec.onCancel then spec.onCancel() end
            return true
        elseif widgets.inside(x, y, list[1], list[2], list[3], list[4]) then
            local rowY = list[2] + 2
            if y >= rowY then
                local index = math.floor((y - rowY) / spec.rowH) + 1 + (spec.offset or 0)
                if index >= 1 and index <= #spec.items then
                    if spec.selected == index and (double or not spec.items[index].isDir) then
                        spec.selected = index
                        pick(spec, win)
                    else
                        spec.selected = index
                    end
                    win.dirty = true
                end
            end
            return true
        end
        return widgets.inside(x, y, r[1], r[2], r[3], r[4])
    end
    return false
end

function dialogs.scroll(win, dir, x, y)
    local spec = win.dialog
    if not spec or spec.type ~= "file" or not spec.listRect then return false end
    local l = spec.listRect
    if not widgets.inside(x, y, l[1], l[2], l[3], l[4]) then return false end
    spec.offset = widgets.scrollWheel(spec.offset or 0, #spec.items, spec.visible, dir, 3)
    win.dirty = true
    return true
end

function dialogs.key(win, key)
    local spec = win.dialog
    if not spec then return false end
    if key == keys.escape then
        dialogs.close(win)
        if spec.onCancel then spec.onCancel() end
        return true
    end
    if spec.type == "prompt" then
        if key == keys.enter then
            local text = spec.field.text
            dialogs.close(win)
            if spec.onSubmit then spec.onSubmit(text) end
            return true
        end
        return widgets.fieldKey(spec.field, key)
    elseif spec.type == "file" then
        if key == keys.enter then
            pick(spec, win)
            return true
        elseif key == keys.up and (spec.selected or 1) > 1 then
            spec.selected = (spec.selected or 2) - 1
            win.dirty = true
            return true
        elseif key == keys.down and (spec.selected or 0) < #spec.items then
            spec.selected = (spec.selected or 0) + 1
            win.dirty = true
            return true
        end
    end
    return true
end

function dialogs.char(win, ch)
    local spec = win.dialog
    if not spec or spec.type ~= "prompt" then return false end
    widgets.fieldChar(spec.field, ch)
    win.dirty = true
    return true
end

return dialogs
