--- CC-Windows - context menus.
--
-- A menu is a floating panel drawn above everything else (windows, taskbar,
-- dialogs). It owns input until dismissed: clicking an item activates it,
-- clicking a parent item opens its submenu, and clicking anywhere else just
-- dismisses the menu and swallows the click, so the click cannot also act on
-- whatever happens to be underneath.
--
-- CC has no mouse-move event (only `mouse_drag`, while a button is held), so
-- submenus open on click rather than on hover.
local menu = {}

local gfx, theme, widgets, icons, C
local wm

local current = nil

local ROW_H = 13
local SEP_H = 7
local PAD = 2
local CHECK_W = 14
local ICON_W = 14
local ARROW_W = 14
local MIN_W = 96

function menu.attach(d)
    gfx, theme, widgets, icons = d.gfx, d.theme, d.widgets, d.icons
    C = theme.C
    wm = d.wm
end

local function mark()
    if wm then wm.dirty = true end
end

--- Turn an item list into rows with pixel offsets, and measure the panel.
-- Columns are shared by every row (all or nothing), so labels stay aligned
-- even when only some items carry an icon or a checkmark.
-- Returns rows, width, height, wantCheck, anyIcon.
local function buildRows(items)
    local rows = {}
    local y = PAD
    local maxText = 0
    local wantCheck = false
    local anyIcon, anyArrow = false, false

    for _, it in ipairs(items) do
        if it.sep then
            rows[#rows + 1] = { sep = true, y = y, h = SEP_H, item = it }
            y = y + SEP_H
        else
            if it.checked ~= nil then wantCheck = true end
            if it.icon then anyIcon = true end
            if it.submenu then anyArrow = true end
            local tw = gfx.textWidth(tostring(it.label or ""))
            if tw > maxText then maxText = tw end
            rows[#rows + 1] = { y = y, h = ROW_H, item = it }
            y = y + ROW_H
        end
    end

    local w = PAD * 2 + maxText
    if wantCheck then w = w + CHECK_W end
    if anyIcon then w = w + ICON_W end
    if anyArrow then w = w + ARROW_W end
    if w < MIN_W then w = MIN_W end
    return rows, w, y + PAD, wantCheck, anyIcon
end

--- Build a panel, clamped so it stays on screen. `parent` is set for
-- submenus, which flip to the parent's left when they would overflow.
local function newPanel(items, x, y, parent)
    local rows, w, h, wantCheck, anyIcon = buildRows(items)
    local W, H = gfx.size()
    if parent then
        local right = parent.x + parent.w - 1
        if right + w > W then right = parent.x - w + 1 end
        if right < 0 then right = math.max(0, W - w) end
        x = right
        y = parent.y + (parent.hotY or 0) - PAD
    end
    if x + w > W then x = math.max(0, W - w) end
    if y + h > H then y = math.max(0, H - h) end
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    return {
        items = items, rows = rows, x = x, y = y, w = w, h = h,
        wantCheck = wantCheck, anyIcon = anyIcon,
        hot = nil, hotY = nil, sub = nil, parent = parent,
    }
end

--- Index of the row under (x, y), or nil.
local function rowAt(p, x, y)
    if x < p.x or x >= p.x + p.w or y < p.y or y >= p.y + p.h then return nil end
    local ly = y - p.y
    for i, row in ipairs(p.rows) do
        if ly >= row.y and ly < row.y + row.h then return i end
    end
    return nil
end

local function activate(p, i)
    local row = p.rows[i]
    local it = row and row.item
    if not it or it.sep or it.disabled then return true end
    local fn = it.onPick
    menu.close()
    if fn then fn() end
    return true
end

--- Open (or replace) the submenu hanging off row `i`.
local function openSub(p, i)
    local row = p.rows[i]
    if not row or not row.item.submenu then return false end
    p.hot, p.hotY = i, row.y
    p.sub = newPanel(row.item.submenu, 0, 0, p)
    mark()
    return true
end

--- Draw one panel onto a root DC (screen coordinates).
local function drawPanel(dc, p)
    dc:fill(p.x + 3, p.y + 3, p.w, p.h, C.shadow)
    dc:fill(p.x, p.y, p.w, p.h, C.face)
    dc:rect(p.x, p.y, p.w, p.h, C.bevelDark)

    for i, row in ipairs(p.rows) do
        local it = row.item
        if row.sep then
            dc:fill(p.x + 4, p.y + row.y + 3, p.w - 8, 1, C.bevelMid)
        else
            local hot = (p.hot == i) and not it.disabled
            if hot then dc:fill(p.x + 1, p.y + row.y, p.w - 2, row.h, C.accent) end

            local tx = p.x + PAD
            if p.wantCheck then
                if it.checked then
                    local c = hot and C.white or C.accent
                    local cy = p.y + row.y + math.floor(row.h / 2)
                    dc:line(tx + 2, cy, tx + 4, cy + 2, c)
                    dc:line(tx + 4, cy + 2, tx + 8, cy - 2, c)
                end
                tx = tx + CHECK_W
            end
            if p.anyIcon then
                if it.icon then
                    icons.draw(dc, it.icon, tx, p.y + row.y + 3, 1)
                end
                tx = tx + ICON_W
            end

            local colour = it.disabled and C.textMuted
                or (hot and C.white or C.text)
            local label = widgets.ellipsis(tostring(it.label or ""),
                p.x + p.w - tx - (it.submenu and ARROW_W + 4 or 4))
            dc:text(tx, p.y + row.y + 2, label, colour)

            if it.submenu then
                local ax = p.x + p.w - ARROW_W + 4
                local ay = p.y + row.y + 3
                local c = hot and C.white or C.text
                dc:fill(ax, ay, 1, 7, c)
                dc:fill(ax + 1, ay + 1, 1, 5, c)
                dc:fill(ax + 2, ay + 2, 1, 3, c)
                dc:fill(ax + 3, ay + 3, 1, 1, c)
            end
        end
    end
end

---------------------------------------------------------------------------
-- public API
---------------------------------------------------------------------------

--- spec = { x = px, y = px, items = { ... } }
-- Item fields: label, icon, checked, disabled, sep, submenu = { items },
-- onPick = function.
function menu.open(spec)
    if not spec or not spec.items then return end
    current = newPanel(spec.items, spec.x or 0, spec.y or 0, nil)
    mark()
end

function menu.close()
    if current then
        current = nil
        mark()
    end
end

function menu.isOpen() return current ~= nil end
function menu.current() return current end

--- Draw last, so menus sit above windows, dialogs and the taskbar.
function menu.draw(rootDC)
    if not current then return end
    drawPanel(rootDC, current)
    if current.sub then drawPanel(rootDC, current.sub) end
end

--- Returns true when the click was consumed (always, while a menu is open).
function menu.click(x, y, button)
    if not current then return false end
    if button ~= 1 then return false end

    if current.sub then
        local i = rowAt(current.sub, x, y)
        if i then
            mark()
            return activate(current.sub, i)
        end
    end

    local i = rowAt(current, x, y)
    if i then
        local row = current.rows[i]
        local it = row.item
        if it.sep or it.disabled then
            mark()
            return true
        end
        if it.submenu then
            return openSub(current, i)
        end
        mark()
        return activate(current, i)
    end

    -- Outside: dismiss and swallow, so nothing underneath reacts.
    menu.close()
    return true
end

--- Keyboard while open. Returns true when consumed.
function menu.key(key)
    if not current then return false end
    if key == keys.escape then
        menu.close()
        return true
    end
    if key == keys.up or key == keys.down then
        local step = (key == keys.down) and 1 or -1
        local n = #current.rows
        if n > 0 then
            local i = current.hot or (step > 0 and 0 or 1)
            for _ = 1, n do
                i = i + step
                if i < 1 then i = n end
                if i > n then i = 1 end
                local row = current.rows[i]
                if not row.sep and not row.item.disabled then
                    current.hot, current.hotY = i, row.y
                    break
                end
            end
            mark()
        end
        return true
    end
    if key == keys.left and current.sub then
        current.sub = nil
        mark()
        return true
    end
    if key == keys.right and current.hot then
        if openSub(current, current.hot) then return true end
    end
    if key == keys.enter then
        if current.hot then
            local it = current.rows[current.hot].item
            if it.submenu then return openSub(current, current.hot) end
            return activate(current, current.hot)
        end
        menu.close()
        mark()
        return true
    end
    -- Anything else dismisses the menu but is left for the caller.
    menu.close()
    return false
end

return menu
