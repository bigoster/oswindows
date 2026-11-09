--- CC-Windows - Settings.
local app = {}

app.id = "settings"
app.name = "Settings"
app.icon = "settings"
app.defaultSize = { 236, 158 }

local theme, widgets, C
local state, save

local WALLPAPERS = {
    { id = "landscape", label = "Landscape" },
    { id = "gradient", label = "Gradient" },
    { id = "solid", label = "Solid" },
}
local SOLID_COLOURS = { 38, 39, 40, 41, 42, 43, 44, 16 }

function app.create(win, opts, ctx)
    theme, widgets, C = ctx.theme, ctx.widgets, ctx.theme.C
    state = ctx.state
    save = state.save

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

    -------------------------------------------------------------------
    -- drawing
    -------------------------------------------------------------------

    local function section(dc, y, title)
        dc:text(8, y, title, C.accent)
        dc:fill(8, y + 10, dc.w - 16, 1, C.bevelMid)
        return y + 15
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
        y = toggleButtons(dc, y, { { id = "light", label = "Light" }, { id = "dark", label = "Dark" } },
            s.theme, "theme")

        y = section(dc, y + 2, "Wallpaper")
        y = toggleButtons(dc, y, WALLPAPERS, s.wallpaper, "wall")

        if s.wallpaper == "solid" then
            local x = 8
            for i, colour in ipairs(SOLID_COLOURS) do
                local r = { x, y, 16, 14, colour }
                dc:fill(x, y, 16, 14, colour)
                if s.wallpaperColour == colour then
                    dc:rect(x, y, 16, 14, C.accent)
                    dc:rect(x - 1, y - 1, 18, 16, C.white)
                else
                    dc:rect(x, y, 16, 14, C.bevelDark)
                end
                self.rects["col" .. i] = r
                x = x + 20
            end
            y = y + 20
        end

        y = section(dc, y + 2, "Taskbar")
        local checked = s.clockSeconds
        widgets.checkbox(dc, 8, y, checked, "Show seconds in the clock",
            self.hover == "sec")
        self.rects["sec"] = { 8, y, 180, 11, not checked }
        y = y + 18

        dc:fill(8, y, dc.w - 16, 1, C.bevelMid)
        dc:text(8, y + 6, "CC-Windows 1.0 for CC:CE", C.textMuted)
        dc:text(8, y + 16, "Rendering: CC-Graphics mode 2", C.textMuted)
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
        if not r then return true end
        if key:sub(1, 5) == "theme" then
            setState("theme", r[5])
        elseif key:sub(1, 4) == "wall" then
            setState("wallpaper", r[5])
        elseif key:sub(1, 3) == "col" then
            setState("wallpaperColour", r[5])
            if state.settings.wallpaper ~= "solid" then
                state.settings.wallpaper = "solid"
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

    return self
end

return app
