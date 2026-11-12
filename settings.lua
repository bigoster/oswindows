--- CC-Windows - Settings.
local app = {}

app.id = "settings"
app.name = "Settings"
app.icon = "settings"
app.defaultSize = { 236, 158 }

local theme, widgets, C
local state, save, dialogs

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

        -- Row 2: the picture picker is always here. Solid mode tucks its
        -- swatches in beside it (narrower than before so both fit), picture
        -- mode shows the chosen file name instead.
        local picW = dc:textWidth("Picture...") + 16
        widgets.button(dc, 8, y, picW, 15, "Picture...",
            { state = self.hover == "pic" and "hover" or nil })
        self.rects["pic"] = { 8, y, picW, 15 }

        local tx = 8 + picW + 6
        if s.wallpaper == "solid" then
            for i, colour in ipairs(SOLID_COLOURS) do
                dc:fill(tx, y, 14, 14, colour)
                if s.wallpaperColour == colour then
                    dc:rect(tx, y, 14, 14, C.accent)
                    dc:rect(tx - 1, y - 1, 16, 16, C.white)
                else
                    dc:rect(tx, y, 14, 14, C.bevelDark)
                end
                self.rects["col" .. i] = { tx, y, 14, 14, colour }
                tx = tx + 16
            end
        elseif s.wallpaper == "picture" then
            local name = "no file chosen"
            if type(s.wallpaperPath) == "string" and s.wallpaperPath ~= "" then
                name = fs.getName(s.wallpaperPath)
                if not fs.exists(s.wallpaperPath) then name = name .. " (missing)" end
            end
            local room = math.floor((dc.w - 8 - tx) / 6)
            if #name > room and room > 3 then
                name = name:sub(1, room - 2) .. ".."
            end
            dc:text(tx, y + 3, name, C.textMuted)
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
        dc:text(8, fy + 1, "CC-Windows 1.0 \194\183 CC-Graphics mode 2", C.textMuted)
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
        elseif key == "pic" then
            pickPicture()
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
