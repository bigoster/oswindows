--- CC-Windows - Console.
--
-- Hosts a real CraftOS shell inside a window. The shell runs in a coroutine
-- and talks to a terminal object of our own that renders a character grid
-- into the pixel framebuffer. Events are fed to the coroutine while the
-- window has focus; the global `term` redirect follows the focused console.
local app = {}

app.id = "console"
app.name = "Console"
app.icon = "terminal"
app.defaultSize = { 340, 200 }

local wm

local PX_W, PX_H = 6, 9

local function dc_size(win)
    if win.content then return win.content.w, win.content.h end
    return 1, 1
end

local function cellGrid(w, h)
    local cols = math.floor(w / PX_W)
    local rows = math.floor(h / PX_H)
    if cols < 1 then cols = 1 end
    if rows < 1 then rows = 1 end
    return cols, rows
end

--- A CC colour bit (colors.red = 0x4000 ...) turned into a palette index.
-- The index is also exactly the hex digit used by term.blit, because
-- framebuffer byte v renders palette slot 15 - v, and slot 15 - d is the
-- default colour of the bit 2^d.
local function bitToIndex(n)
    local i = 0
    while n > 1 do
        n = math.floor(n / 2)
        i = i + 1
    end
    return i
end

local function parseHex(ch, fallback)
    local b = string.byte(ch)
    if b >= 48 and b <= 57 then return b - 48 end       -- 0-9
    if b >= 97 and b <= 102 then return b - 87 end      -- a-f
    if b >= 65 and b <= 70 then return b - 55 end       -- A-F
    return fallback
end

local function toIndexString(s, fallback)
    local out = {}
    for i = 1, #s do out[i] = string.char(parseHex(s:sub(i, i), fallback)) end
    return table.concat(out)
end

function app.create(win, opts, ctx)
    wm = ctx.wm

    local self = {}

    local cols, rows = cellGrid(dc_size(win))
    local chars, fgs, bgs = {}, {}, {}
    local curX, curY = 1, 1
    local fg, bg = 0, 15            -- white on black, in palette indices
    local cursorBlink = false
    local blinkPhase = true
    local blinkTimer = nil
    local co, filter = nil, nil
    local prevRedirect = nil
    local termObj = {}
    -- A console opened from a desktop shortcut runs that program first and
    -- then drops to a shell, the way a terminal window would.
    local startupProgram = opts and opts.program or nil
    local ranProgram = false

    local function mark() win.dirty = true end

    -------------------------------------------------------------------
    -- character grid
    -------------------------------------------------------------------

    local function rebuildGrid(nc, nr)
        local oldChars, oldFgs, oldBgs = chars, fgs, bgs
        local oldCols = cols
        cols, rows = nc, nr
        chars, fgs, bgs = {}, {}, {}
        local fillF = string.rep(string.char(fg), nc)
        local fillB = string.rep(string.char(bg), nc)
        local fillC = string.rep(" ", nc)
        for y = 1, nr do
            local cs, fs, bs
            if oldChars[y] then
                cs = oldChars[y]:sub(1, nc)
                fs = oldFgs[y]:sub(1, nc)
                bs = oldBgs[y]:sub(1, nc)
            else
                cs, fs, bs = "", "", ""
            end
            local pad = nc - #cs
            if pad > 0 then
                cs = cs .. fillC
                fs = fs .. fillF
                bs = bs .. fillB
            end
            chars[y], fgs[y], bgs[y] = cs, fs, bs
        end
        if curX > cols then curX = cols end
        if curY > rows then curY = rows end
        if curX < 1 then curX = 1 end
        if curY < 1 then curY = 1 end
        if oldCols ~= nc then mark() end
    end

    local function newRowStrings()
        return string.rep(" ", cols),
            string.rep(string.char(fg), cols),
            string.rep(string.char(bg), cols)
    end

    local function writeAt(text, colourText, colourBg)
        if text == "" then return end
        local y = curY
        local advanced = #text
        if y >= 1 and y <= rows then
            local line, fline, bline = chars[y], fgs[y], bgs[y]
            local from = math.max(1, curX)
            local to = math.min(cols, curX + #text - 1)
            if to >= from then
                local srcA = from - curX + 1
                local srcB = to - curX + 1
                local chunk = text:sub(srcA, srcB)
                local fchunk, bchunk
                if colourText then
                    fchunk = colourText:sub(srcA, srcB)
                    bchunk = colourBg:sub(srcA, srcB)
                else
                    fchunk = string.rep(string.char(fg), #chunk)
                    bchunk = string.rep(string.char(bg), #chunk)
                end
                chars[y] = line:sub(1, from - 1) .. chunk .. line:sub(to + 1)
                fgs[y] = fline:sub(1, from - 1) .. fchunk .. fline:sub(to + 1)
                bgs[y] = bline:sub(1, from - 1) .. bchunk .. bline:sub(to + 1)
                mark()
            end
        end
        curX = curX + advanced
    end

    local scroll

    local function newLine()
        if curY < rows then
            curY = curY + 1
        else
            scroll(1)
        end
        curX = 1
    end

    local function clearAll()
        local c, f, b = newRowStrings()
        for y = 1, rows do chars[y], fgs[y], bgs[y] = c, f, b end
        mark()
    end

    local function clearLine()
        if curY >= 1 and curY <= rows then
            local c, f, b = newRowStrings()
            chars[curY], fgs[curY], bgs[curY] = c, f, b
            mark()
        end
    end

    scroll = function(n)
        n = math.floor(n)
        if n > rows then n = rows elseif n < -rows then n = -rows end
        if n == 0 then return end
        local c, f, b = newRowStrings()
        if n > 0 then
            for _ = 1, n do
                table.remove(chars, 1)
                table.remove(fgs, 1)
                table.remove(bgs, 1)
                chars[rows], fgs[rows], bgs[rows] = c, f, b
            end
        else
            for _ = 1, -n do
                table.remove(chars, rows)
                table.remove(fgs, rows)
                table.remove(bgs, rows)
                table.insert(chars, 1, c)
                table.insert(fgs, 1, f)
                table.insert(bgs, 1, b)
            end
        end
        mark()
    end

    local function echo(text, colour)
        local oldFg = fg
        if colour then fg = colour end
        for line in string.gmatch(tostring(text) .. "\n", "([^\n]*)\n") do
            if line ~= "" then writeAt(line) end
            newLine()
        end
        fg = oldFg
    end

    -------------------------------------------------------------------
    -- the terminal object handed to the shell
    -------------------------------------------------------------------

    function termObj.write(text)
        writeAt(tostring(text))
        mark()
    end

    function termObj.blit(text, textColour, bgColour)
        text = tostring(text)
        textColour = tostring(textColour)
        bgColour = tostring(bgColour)
        if #textColour ~= #text or #bgColour ~= #text then
            error("Arguments must be the same length", 2)
        end
        writeAt(text, toIndexString(textColour, fg), toIndexString(bgColour, bg))
        mark()
    end

    function termObj.clear()
        clearAll()
    end

    function termObj.clearLine()
        clearLine()
    end

    function termObj.setCursorPos(x, y)
        curX, curY = math.floor(tonumber(x) or 1), math.floor(tonumber(y) or 1)
        mark()
    end

    function termObj.getCursorPos()
        return curX, curY
    end

    function termObj.getSize(mode)
        if mode == true or (type(mode) == "number" and mode >= 1) then
            return cols * PX_W, rows * PX_H
        end
        return cols, rows
    end

    function termObj.isColour() return true end
    function termObj.isColor() return true end

    function termObj.setTextColour(c)
        local i = bitToIndex(tonumber(c) or 0)
        fg = i
        mark()
    end
    termObj.setTextColor = termObj.setTextColour

    function termObj.getTextColour() return 2 ^ fg end
    termObj.getTextColor = termObj.getTextColour

    function termObj.setBackgroundColor(c)
        bg = bitToIndex(tonumber(c) or 0)
        mark()
    end
    termObj.setBackgroundColour = termObj.setBackgroundColor

    function termObj.getBackgroundColor() return 2 ^ bg end
    termObj.getBackgroundColour = termObj.getBackgroundColor

    function termObj.setCursorBlink(b)
        cursorBlink = not not b
        mark()
    end

    function termObj.getCursorBlink() return cursorBlink end

    function termObj.scroll(n) scroll(tonumber(n) or 0) end

    -- Palette: CC passes colour bits (colors.white = 1), mode 2 wants raw
    -- indices 0-255. Powers of two up to 0x8000 are treated as colour bits.
    function termObj.setPaletteColour(index, a, b, c)
        local n = tonumber(index)
        if not n or n < 0 then error("Colour out of range", 2) end
        local target = n
        if n >= 1 and n <= 0x8000 and n == math.floor(n) and 2 ^ bitToIndex(n) == n then
            target = bitToIndex(n)
        elseif n > 255 then
            error("Colour out of range", 2)
        end
        local native = term.native()
        if b ~= nil then
            native.setPaletteColor(target, a, b, c)
        else
            native.setPaletteColor(target, a)
        end
    end
    termObj.setPaletteColor = termObj.setPaletteColour

    function termObj.getPaletteColour(index)
        local n = tonumber(index) or 0
        local target = n
        if n >= 1 and n <= 0x8000 and 2 ^ bitToIndex(n) == n then
            target = bitToIndex(n)
        end
        return term.native().getPaletteColor(target)
    end
    termObj.getPaletteColor = termObj.getPaletteColour

    -- Graphics mode belongs to the shell's window, not to its programs:
    -- switching it would tear down the whole desktop, so it is faked.
    function termObj.setGraphicsMode() end
    function termObj.getGraphicsMode() return 2 end
    function termObj.setFrozen() end
    function termObj.getFrozen() return false end
    function termObj.setPixel() end
    function termObj.getPixel() return nil end
    function termObj.drawPixels() end

    function termObj.getPixels(_, _, w, h)
        w, h = math.floor(tonumber(w) or 0), math.floor(tonumber(h) or 0)
        if w < 0 then w = 0 end
        if h < 0 then h = 0 end
        if w > 128 then w = 128 end
        if h > 128 then h = 128 end
        local out = {}
        for row = 1, h do
            local line = {}
            for col = 1, w do line[col] = 15 end
            out[row] = line
        end
        return out
    end

    -------------------------------------------------------------------
    -- the shell coroutine
    -------------------------------------------------------------------

    -- Forward declaration: resumeShell restarts the shell after Ctrl+T.
    local startShell

    local function resumeShell(...)
        if not co or coroutine.status(co) ~= "suspended" then return end

        -- The global term redirect follows the focused window, so while this
        -- console is in the background it points somewhere else (the native
        -- term, i.e. straight over the desktop). Every byte the shell writes
        -- happens synchronously inside this resume, so claim the redirect for
        -- the duration of it and hand it back afterwards.
        local prev = term.current()
        if prev ~= termObj then pcall(term.redirect, termObj) end

        local ok, a = coroutine.resume(co, ...)

        if prev ~= termObj and term.current() == termObj then
            pcall(term.redirect, prev)
        end

        if not ok then
            co, filter = nil, nil
            cursorBlink = false
            if tostring(a) == "Terminated" then
                -- Ctrl+T at the prompt: stock CraftOS kills the shell (and
                -- the computer). Here the window survives, we just start a
                -- fresh shell in it.
                ranProgram = false
                startShell()
            else
                echo("shell: " .. tostring(a), 14)
                mark()
            end
        elseif coroutine.status(co) == "dead" then
            co, filter = nil, nil
            cursorBlink = false
            if ranProgram then
                -- A shortcut's program finished; hand the window back to a
                -- shell instead of leaving it dead.
                ranProgram = false
                startShell()
            else
                echo("[Process exited]", 14)
                mark()
            end
        else
            filter = a
        end
    end

    local function deliver(name, ...)
        if not co then return end
        if filter ~= nil and filter ~= name and name ~= "terminate" then return end
        resumeShell(name, ...)
    end

    startShell = function()
        local path = "/rom/programs/shell.lua"
        if startupProgram then
            path = startupProgram
            startupProgram = nil
            ranProgram = true
        end
        local f = fs.open(path, "r")
        if not f then
            echo("Cannot open " .. path, 14)
            return
        end
        local src = f.readAll()
        f.close()
        local fn, err = load(src, "@" .. path)
        if not fn then
            echo(tostring(err), 14)
            return
        end
        co = coroutine.create(fn)
        filter = nil
        resumeShell()
    end

    -------------------------------------------------------------------
    -- window callbacks
    -------------------------------------------------------------------

    local function toCell(px, py)
        local x = math.floor(px / PX_W) + 1
        local y = math.floor(py / PX_H) + 1
        if x < 1 then x = 1 elseif x > cols then x = cols end
        if y < 1 then y = 1 elseif y > rows then y = rows end
        return x, y
    end

    local function focused() return wm.focused() == win end

    function self:draw(dc, w, h)
        dc:fill(0, 0, w, h, bg)

        for y = 1, rows do
            local line, fline, bline = chars[y], fgs[y], bgs[y]
            local x = 1
            while x <= cols do
                local f0 = string.byte(fline, x)
                local b0 = string.byte(bline, x)
                local x2 = x
                while x2 < cols
                    and string.byte(fline, x2 + 1) == f0
                    and string.byte(bline, x2 + 1) == b0
                    and string.byte(line, x2 + 1) < 128 do
                    x2 = x2 + 1
                end
                dc:text((x - 1) * PX_W, (y - 1) * PX_H, line:sub(x, x2), f0, b0)
                x = x2 + 1
            end
        end

        -- caret: a solid block that blinks while the window is focused
        if cursorBlink and blinkPhase and focused()
            and curX >= 1 and curX <= cols and curY >= 1 and curY <= rows then
            dc:fill((curX - 1) * PX_W, (curY - 1) * PX_H, PX_W, PX_H, fg)
        end
    end

    function self:resize(w, h)
        local nc, nr = cellGrid(w, h)
        if nc ~= cols or nr ~= rows then
            rebuildGrid(nc, nr)
            deliver("term_resize")
        end
    end

    function self:timer(id)
        if id == blinkTimer then
            blinkPhase = not blinkPhase
            blinkTimer = os.startTimer(0.5)
            if focused() then mark() end
            return
        end
        -- Timers must reach the shell even when this window is in the
        -- background: a program sleeping in an unfocused console would
        -- otherwise never wake up, hanging the shell with no error at all.
        deliver("timer", id)
    end

    function self:key(key)
        deliver("key", key, false)
        mark()
        return true
    end

    function self:key_up(key)
        deliver("key_up", key, false)
        return true
    end

    function self:char(ch)
        deliver("char", ch)
        mark()
        return true
    end

    function self:click(x, y, button)
        local cx, cy = toCell(x, y)
        deliver("mouse_click", button or 1, cx, cy)
        return true
    end

    function self:drag(x, y, button)
        local cx, cy = toCell(x, y)
        deliver("mouse_drag", button or 1, cx, cy)
        return true
    end

    function self:up(x, y, button)
        local cx, cy = toCell(x, y)
        deliver("mouse_up", button or 1, cx, cy)
        return true
    end

    function self:scroll(x, y, dir)
        local cx, cy = toCell(x, y)
        deliver("mouse_scroll", dir, cx, cy)
        return true
    end

    --- Everything wm does not route itself (peripherals, timers, ...).
    --
    -- Not gated on focus: a shell in the background must still receive
    -- http/rednet/peripheral/disk events, or any program waiting for one
    -- would hang silently forever. Input events are excluded below because
    -- wm only routes those to the focused window.
    function self:feed(ev)
        local name = ev[1]
        -- Ctrl+T belongs to the console you are actually looking at.
        if name == "terminate" and not focused() then return end
        if name == "mouse_click" or name == "mouse_up" or name == "mouse_drag"
            or name == "mouse_scroll" or name == "key" or name == "char"
            or name == "key_up" or name == "paste" or name == "term_resize"
            or name == "timer" then
            return
        end
        -- ev[1] is the event name, which `name` already carries: the payload
        -- starts at 2. Unpacking from 1 would hand the shell a duplicated
        -- name as its first parameter (so `ch` in a radio message would be
        -- "cee_radio_message" instead of the channel).
        deliver(name, table.unpack(ev, 2, ev.n or #ev))
    end

    function self:close()
        if blinkTimer then pcall(os.cancelTimer, blinkTimer) end
        blinkTimer = nil
        co, filter = nil, nil
        if prevRedirect and term.current() == termObj then
            pcall(term.redirect, prevRedirect)
        end
    end

    -------------------------------------------------------------------
    -- boot
    -------------------------------------------------------------------

    prevRedirect = term.redirect(termObj)
    rebuildGrid(cols, rows)
    startShell()
    blinkTimer = os.startTimer(0.5)

    -- Test hook: the harness reads the character grid to verify that
    -- commands actually produced output, and the shell coroutine state.
    if rawget(_G, "CCWIN_DEBUG") then
        self.debugGrid = function() return table.concat(chars, "\n") end
        self.debugShell = function()
            return co and coroutine.status(co) or "dead", filter
        end
    end

    self.redirectTarget = termObj
    return self
end

return app
