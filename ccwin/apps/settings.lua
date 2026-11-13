--- CC-Windows - Settings.
local app = {}

app.id = "settings"
app.name = "Settings"
app.icon = "settings"
app.defaultSize = { 236, 158 }

local theme, widgets, C
local state, save, dialogs

-- Row 1 of the wallpaper section. Image opens the file chooser: the
-- shipped wallpapers live in /ccwin/images next to your own pictures,
-- and the mode only flips once a file is really picked.
local WALLPAPERS = {
    { id = "picture", label = "Image" },
    { id = "solid", label = "Solid" },
}

function app.create(win, opts, ctx)
    theme, widgets, C = ctx.theme, ctx.widgets, ctx.theme.C
    state = ctx.state
    save = state.save
    dialogs = ctx.dialogs

    local self = {
        rects = {},
        hover = nil,
    }

    local function setState(key, value)
        state.settings[key] = value
        if save then save() end
        ctx.state.onSettingsChanged = true
        self.dirty = true
        if state.applySettings then state.applySettings() end
    end
    self.setState = setState

    --- The stored colour for a key as "#RRGGBB". Settings keeps hex
    --- strings now, but a legacy palette index must still display (and
    --- an unreadable value falls back to the colour actually shown).
    local function currentHex(key)
        local v = state.settings[key]
        local n
        if type(v) == "string" then
            n = theme.fromHex(v)
        elseif type(v) == "number" then
            local h = theme.hexOf(v)
            if h then n = theme.fromHex(h) end
        end
        if not n then
            n = theme.fromHex(theme.hexOf(key == "accentColour" and C.accent or C.wpBlue))
        end
        return theme.toHex(n)
    end

    --- The two hex colour fields: the accent sits on the theme row, the
    --- solid wallpaper's colour on the wallpaper's second row.
    self.fields = {
        accent = widgets.newField(currentHex("accentColour")),
        solid = widgets.newField(currentHex("wallpaperColour")),
    }
    self.fieldFocus = nil
    self.fieldFresh = false

    --- Focus a colour field: caret where the click landed, and the next
    --- character typed replaces the old colour the way a colour box does.
    local function focusField(name, r, px)
        self.fieldFocus = name
        self.fieldFresh = true
        local f = self.fields[name]
        local vis = math.max(1, math.floor((r[3] - 8) / 6))
        if f.caret < f.scroll then f.scroll = f.caret end
        if f.caret > f.scroll + vis then f.scroll = f.caret - vis end
        local i = math.floor((px - r[1] - 4) / 6) + f.scroll
        f.caret = math.max(0, math.min(#f.text, i))
        self.dirty = true
    end

    --- Enter in a colour field: store the colour when it is valid hex,
    --- otherwise put the field back to what is actually in effect.
    local function commitField(name)
        local key = name == "accent" and "accentColour" or "wallpaperColour"
        local f = self.fields[name]
        local n = theme.fromHex(f.text)
        local text = n and theme.toHex(n) or currentHex(key)
        f.text, f.caret = text, #text
        if n and state.settings[key] ~= text then
            setState(key, text)
        end
        self.dirty = true
    end

    --- The installed version, read once: the footer must not disagree
    --- with /ccwin/version after an update replaces it.
    local version = (function()
        local ok, v = pcall(function()
            local f = fs.open("/ccwin/version", "r")
            if not f then return nil end
            local line = f.readLine and f.readLine()
            if f.close then f.close() end
            return line
        end)
        if ok and type(v) == "string" and v:match("^[%w%.%-_]+$") then return v end
        return "1.0"
    end)()

    --- File picker for the picture wallpaper: starts where the current
    --- picture lives (or the last browsed folder), accepts .nfp/.cwp files,
    --- and only flips the wallpaper mode once a file is actually picked.
    local function pickPicture()
        local s = state.settings
        local start = s.lastPath or "/"
        if type(s.wallpaperPath) == "string" and s.wallpaperPath ~= "" then
            local dir = s.wallpaperPath:match("^(.*)[/\\][^/\\]+$")
            if dir == "" then dir = "/" end
            if dir and fs.exists(dir) then start = dir end
        end
        dialogs.open(win, {
            type = "file",
            title = "Choose wallpaper",
            path = start,
            filter = function(p)
                if fs.isDir(p) then return true end
                return p:match("%.nfp$") ~= nil or p:match("%.cwp$") ~= nil
            end,
            onPick = function(p)
                s.wallpaperPath = p
                setState("wallpaper", "picture")
            end,
        })
    end

    -------------------------------------------------------------------
    -- drawing
    -------------------------------------------------------------------

    local function section(dc, y, title)
        dc:text(8, y, title, C.accent)
        dc:fill(8, y + 10, dc.w - 16, 1, C.bevelMid)
        return y + 15
    end

    --- The palette slot the solid wallpaper currently shows: the custom
    --- slot for a hex colour, the index itself for a legacy setting.
    local function solidIndex(s)
        local col = s.wallpaperColour
        if type(col) == "string" and theme.fromHex(col) then return C.wpCustom end
        if type(col) == "number" then return col end
        return C.wpBlue
    end

    local function toggleButtons(dc, y, list, current, prefix)
        local x = 8
        for i, item in ipairs(list) do
            local w = dc:textWidth(item.label) + 16
            local selected = (current == item.id)
            widgets.button(dc, x, y, w, 15, item.label,
                { state = selected and "down" or (self.hover == prefix .. i and "hover" or nil) })
            self.rects[prefix .. i] = { x, y, w, 15, item.id }
            x = x + w + 5
        end
        return y + 20
    end

    function self:draw(dc, w, h)
        local s = state.settings
        self.rects = {}
        dc:fill(0, 0, w, h, C.face)

        local y = section(dc, 8, "Theme")
        local ry = y
        y = toggleButtons(dc, y, { { id = "light", label = "Light" }, { id = "dark", label = "Dark" } },
            s.theme, "theme")

        -- The accent colour: a hex field sharing the theme row, with a
        -- swatch of the colour actually installed in the palette. This
        -- one colour is what the window bars, buttons, Start menu and
        -- taskbar highlights are painted with.
        dc:text(104, ry + 3, "Accent", C.textMuted)
        local onAccent = self.fieldFocus == "accent"
        widgets.fieldDraw(dc, 144, ry, 64, 15, self.fields.accent, onAccent, onAccent)
        self.rects.facc = { 144, ry, 64, 15 }
        dc:fill(212, ry, 14, 14, C.accent)
        dc:rect(212, ry, 14, 14, C.bevelDark)

        y = section(dc, y + 2, "Wallpaper")
        y = toggleButtons(dc, y, WALLPAPERS, s.wallpaper, "wall")

        -- Row 2: solid gets a hex colour field with its swatch; picture
        -- shows which file is on screen. The Image button above opens
        -- the chooser.
        if s.wallpaper == "solid" then
            dc:text(8, y + 3, "Colour", C.textMuted)
            local onSolid = self.fieldFocus == "solid"
            widgets.fieldDraw(dc, 48, y, 130, 15, self.fields.solid, onSolid, onSolid)
            self.rects.fsolid = { 48, y, 130, 15 }
            dc:fill(182, y, 14, 14, solidIndex(s))
            dc:rect(182, y, 14, 14, C.bevelDark)
        elseif s.wallpaper == "picture" then
            local name = "no file chosen"
            if type(s.wallpaperPath) == "string" and s.wallpaperPath ~= "" then
                name = s.wallpaperPath
                if not fs.exists(s.wallpaperPath) then name = name .. " (missing)" end
            end
            local room = math.floor((dc.w - 16) / 6)
            if #name > room and room > 3 then
                name = name:sub(1, room - 2) .. ".."
            end
            dc:text(8, y + 3, name, C.textMuted)
        end
        y = y + 20

        y = section(dc, y + 2, "Taskbar")
        local checked = s.clockSeconds
        widgets.checkbox(dc, 8, y, checked, "Show seconds in the clock",
            self.hover == "sec")
        self.rects["sec"] = { 8, y, 180, 11, not checked }

        -- One footer line pinned to the bottom: the picture row needs the
        -- pixels the old two-line footer used to hold.
        local fy = h - 11
        dc:fill(8, fy, dc.w - 16, 1, C.bevelMid)
        dc:text(8, fy + 1, "CC-Windows " .. version .. " \194\183 CC-Graphics mode 2", C.textMuted)
    end

    -------------------------------------------------------------------
    -- input
    -------------------------------------------------------------------

    local function hit(self, x, y)
        for key, r in pairs(self.rects) do
            if x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4] then
                return r, key
            end
        end
        return nil, nil
    end

    function self:click(x, y, button)
        if button ~= 1 then return true end
        local r, key = hit(self, x, y)
        -- clicking anywhere but a colour field lets it go
        if key ~= "facc" and key ~= "fsolid" and self.fieldFocus then
            self.fieldFocus = nil
            self.dirty = true
        end
        if not r then return true end
        if key == "facc" or key == "fsolid" then
            focusField(key == "facc" and "accent" or "solid", r, x)
        elseif key:sub(1, 5) == "theme" then
            setState("theme", r[5])
        elseif key:sub(1, 4) == "wall" then
            if r[5] == "picture" then
                -- Image opens the chooser; the mode only flips once a
                -- file is picked (the built-in images are in there too).
                pickPicture()
            else
                setState("wallpaper", r[5])
            end
        elseif key == "sec" then
            setState("clockSeconds", r[5])
        end
        return true
    end

    function self:drag(x, y)
        local r = hit(self, x, y)
        local key = r and select(2, hit(self, x, y)) or nil
        local newHover = key
        if newHover ~= self.hover then
            self.hover = newHover
            self.dirty = true
            return true
        end
        return false
    end

    --- Typing goes to the focused colour field; Enter commits it.
    function self:key(key)
        local name = self.fieldFocus
        if not name then return false end
        if key == keys.enter or key == keys.numPadEnter then
            commitField(name)
        else
            self.fieldFresh = false
            if widgets.fieldKey(self.fields[name], key) then
                self.dirty = true
            end
        end
        return true
    end

    function self:char(ch)
        local name = self.fieldFocus
        if not name then return false end
        local f = self.fields[name]
        if self.fieldFresh then
            -- the first character replaces the old colour
            f.text, f.caret, f.scroll = "", 0, 0
            self.fieldFresh = false
        end
        widgets.fieldChar(f, ch)
        self.dirty = true
        return true
    end

    return self
end

return app
