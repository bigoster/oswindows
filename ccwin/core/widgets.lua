--- CC-Windows - reusable controls shared by every application.
local widgets = {}

local KEY_END = keys["end"] or keys.endKey or -1

local gfx, theme, C
local icons

local function drawIcon(dc, name, x, y, scale)
    if icons then icons.draw(dc, name, x, y, scale) end
end

function widgets.attach(g, t, ic)
    gfx, theme, C = g, t, t.C
    icons = ic
end

---------------------------------------------------------------------------
-- text helpers
---------------------------------------------------------------------------

--- Shorten `str` so it fits `maxWidth` pixels, appending "..." when cut.
function widgets.ellipsis(str, maxWidth, scale)
    scale = scale or 1
    if gfx.textWidth(str, scale) <= maxWidth then return str end
    local out = str
    while out ~= "" and gfx.textWidth(out .. "...", scale) > maxWidth do
        out = out:sub(1, #out - 1)
    end
    return out .. "..."
end

function widgets.label(dc, x, y, text, colour, scale)
    return dc:text(x, y, text, colour or C.text, nil, scale)
end

function widgets.centeredLabel(dc, x, y, w, h, text, colour, scale)
    scale = scale or 1
    local tw = dc:textWidth(text, scale)
    dc:text(x + math.floor((w - tw) / 2), y + math.floor((h - 9 * scale) / 2), text, colour or C.text, nil, scale)
end

---------------------------------------------------------------------------
-- buttons
---------------------------------------------------------------------------

--- opts: { state = "hover"|"down"|"disabled", icon = "name", iconScale = n }
function widgets.button(dc, x, y, w, h, label, opts)
    opts = opts or {}
    local state = opts.state
    theme.button(dc, x, y, w, h, state)
    local colour = (state == "disabled") and C.textMuted or C.text
    if opts.icon then
        local scale = opts.iconScale or 1
        local iw = 8 * scale
        if label and label ~= "" then
            local tw = dc:textWidth(label)
            local total = iw + 4 + tw
            local start = x + math.floor((w - total) / 2)
            drawIcon(dc, opts.icon, start, y + math.floor((h - iw) / 2), scale)
            dc:text(start + iw + 4, y + math.floor((h - 9) / 2), label, colour)
        else
            drawIcon(dc, opts.icon, x + math.floor((w - iw) / 2), y + math.floor((h - iw) / 2), scale)
        end
    else
        theme.buttonLabel(dc, x, y, w, h, label or "", colour)
    end
end

--- Square icon-only button; hit-test with widgets.inside.
function widgets.iconButton(dc, x, y, size, name, opts)
    opts = opts or {}
    theme.button(dc, x, y, size, size, opts.state)
    local scale = opts.iconScale or 1
    local iw = 8 * scale
    drawIcon(dc, name, x + math.floor((size - iw) / 2), y + math.floor((size - iw) / 2), scale)
end

---------------------------------------------------------------------------
-- lists / rows
---------------------------------------------------------------------------

function widgets.listRow(dc, x, y, w, h, state)
    if state == "selected" then
        dc:fill(x, y, w, h, C.accent)
    elseif state == "hover" then
        dc:fill(x, y, w, h, C.hover)
    end
end

--- Draws a vertical scrollbar for `offset` of `total` rows over `visible` rows.
function widgets.scrollV(dc, x, y, w, h, offset, total, visible, hot)
    if total <= visible then
        dc:fill(x, y, w, h, C.track)
        return
    end
    theme.scrollbarV(dc, x, y, w, h, offset / (total - visible), visible / total, hot)
end

function widgets.scrollH(dc, x, y, w, h, offset, total, visible, hot)
    if total <= visible then
        dc:fill(x, y, w, h, C.track)
        return
    end
    theme.scrollbarH(dc, x, y, w, h, offset / (total - visible), visible / total, hot)
end

function widgets.scrollWheel(offset, total, visible, delta, step)
    step = step or 1
    local newOffset = offset - delta * step
    local maxOffset = math.max(0, total - visible)
    if newOffset < 0 then newOffset = 0 end
    if newOffset > maxOffset then newOffset = maxOffset end
    return newOffset
end

--- Index of the row at `y`, or nil.
function widgets.rowAt(y, originY, rowH, count)
    if y < originY then return nil end
    local index = math.floor((y - originY) / rowH) + 1
    if index < 1 or index > count then return nil end
    return index
end

---------------------------------------------------------------------------
-- menu (dropdown / context list)
---------------------------------------------------------------------------

--- items: array of strings, or { label = ..., icon = ... }.
--- Returns the height used. `selected` may be nil.
function widgets.menu(dc, x, y, w, items, selected, maxHeight)
    local rowH = 13
    local visible = #items
    if maxHeight and math.floor(maxHeight / rowH) < visible then
        visible = math.floor(maxHeight / rowH)
    end
    local h = visible * rowH + 4
    dc:fill(x + 2, y + 2, w, h, C.shadow)          -- drop shadow
    dc:fill(x, y, w, h, C.face)
    dc:rect(x, y, w, h, C.bevelDark)
    for i = 1, visible do
        local iy = y + 2 + (i - 1) * rowH
        local item = items[i]
        local label = type(item) == "table" and (item.label or item[1]) or item
        local icon = type(item) == "table" and item.icon or nil
        if selected == i then
            dc:fill(x + 1, iy, w - 2, rowH, C.accent)
        end
        local tx = x + 5
        if icon then
            drawIcon(dc, icon, x + 3, iy + 3, 1)
            tx = x + 14
        end
        dc:text(tx, iy + 2, label, selected == i and C.white or C.text)
    end
    return h
end

--- Hit-test against the layout produced by widgets.menu.
function widgets.menuIndex(x, y, mx, my, w, count, maxHeight)
    if not gfx.inside(x, y, mx, my, w, count * 13 + 4) then return nil end
    if y < my + 2 then return nil end
    local index = math.floor((y - my - 2) / 13) + 1
    local visible = count
    if maxHeight and math.floor(maxHeight / 13) < visible then
        visible = math.floor(maxHeight / 13)
    end
    if index < 1 or index > visible then return nil end
    return index
end

---------------------------------------------------------------------------
-- checkbox
---------------------------------------------------------------------------

function widgets.checkbox(dc, x, y, checked, label, hot)
    local size = 9
    dc:fill(x, y, size, size, C.fieldBg)
    dc:rect(x, y, size, size, hot and C.accent or C.bevelDark)
    if checked then
        dc:fill(x + 2, y + 2, 5, 5, C.accent)
    end
    if label then dc:text(x + size + 5, y, label, C.text) end
    return size
end

---------------------------------------------------------------------------
-- single line text field with editing
---------------------------------------------------------------------------

function widgets.newField(text)
    text = text or ""
    return { text = text, caret = #text, scroll = 0 }
end

local function visibleChars(w) return math.max(1, math.floor((w - 8) / 6)) end

function widgets.fieldDraw(dc, x, y, w, h, field, focused, showCaret)
    theme.field(dc, x, y, w, h, focused)
    local vis = visibleChars(w)
    if field.caret < field.scroll then field.scroll = field.caret end
    if field.caret > field.scroll + vis then field.scroll = field.caret - vis end
    local from = field.scroll + 1
    local text = field.text:sub(from, from + vis - 1)
    dc:pushClip(x + 4, y + 1, w - 8, h - 2)
    dc:text(x + 4, y + math.floor((h - 9) / 2), text, C.text)
    if focused and showCaret then
        local cx = x + 4 + (field.caret - field.scroll) * 6
        dc:fill(cx, y + 2, 1, h - 4, C.text)
    end
    dc:popClip()
end

--- Returns true when the key was consumed.
function widgets.fieldKey(field, key)
    local len = #field.text
    if key == keys.backspace then
        if field.caret > 0 then
            field.text = field.text:sub(1, field.caret - 1) .. field.text:sub(field.caret + 1)
            field.caret = field.caret - 1
        end
        return true
    elseif key == keys.delete then
        if field.caret < len then
            field.text = field.text:sub(1, field.caret) .. field.text:sub(field.caret + 2)
        end
        return true
    elseif key == keys.left then
        field.caret = math.max(0, field.caret - 1)
        return true
    elseif key == keys.right then
        field.caret = math.min(len, field.caret + 1)
        return true
    elseif key == keys.home then
        field.caret = 0
        return true
    elseif key == KEY_END then
        field.caret = len
        return true
    elseif key == keys.tab then
        field.text = field.text:sub(1, field.caret) .. "    " .. field.text:sub(field.caret + 1)
        field.caret = field.caret + 4
        return true
    end
    return false
end

function widgets.fieldChar(field, ch)
    field.text = field.text:sub(1, field.caret) .. ch .. field.text:sub(field.caret + 1)
    field.caret = field.caret + 1
    return true
end

---------------------------------------------------------------------------
-- misc
---------------------------------------------------------------------------

function widgets.inside(x, y, rx, ry, rw, rh)
    return x >= rx and x < rx + rw and y >= ry and y < ry + rh
end

function widgets.formatBytes(n)
    if n == nil then return "-" end
    if n >= 1024 * 1024 then
        return string.format("%.1f MB", n / (1024 * 1024))
    elseif n >= 1024 then
        return string.format("%.1f KB", n / 1024)
    end
    return tostring(n) .. " B"
end

function widgets.pad(s, n)
    s = tostring(s)
    while #s < n do s = s .. " " end
    return s
end

function widgets.padLeft(s, n)
    s = tostring(s)
    while #s < n do s = " " .. s end
    return s
end

return widgets
