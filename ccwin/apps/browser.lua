--- CC-Windows - Browser: a small text web browser.
--- icon:
--- 00000bbbbbb00000
--- 000b3dd33333b000
--- 00b3ddd33dd33b00
--- 0b3dddd3ddd333b0
--- 0b33ddd33dd333b0
--- b333dd333dd3333b
--- b3333333ddd333db
--- b33dd33333dd33db
--- b3dddd3333333ddb
--- b3ddd33333333ddb
--- b33dd3333333d33b
--- 0b33d33333d333b0
--- 0b333333ddd333b0
--- 00b3333dd3333b00
--- 000b33333333b000
--- 00000bbbbbb00000
--
-- Fetches pages with http.request (non-blocking, result arrives via `feed`),
-- turns HTML into word-wrapped text with clickable links, and keeps a
-- back/forward history. Also opens local files and folders (file:///...).
--
-- Install: save as ccwin/apps/browser.lua and add "browser" to APP_LIST
-- (ccwin/main.lua), DESKTOP_APPS (ccwin/core/desktop.lua) and the manifest
-- in install.lua. The desktop picture is the `--- icon:` block above
-- (read as text by core/programs.lua, one hex digit per pixel).
local app = {}

app.id = "browser"
app.name = "Browser"
app.icon = "info"                 -- glyph icon (title bar / start menu fallback)
app.defaultSize = { 290, 150 }

local HOME = "about:home"
local TB_H = 20        -- toolbar height
local SB_H = 12        -- status band height
local LH = 11          -- line height (9px font + underline room)
local CW = 6           -- character width
local MARGIN = 4
local MAXB = 120000    -- max bytes parsed (CC kills programs that never yield)

local HOME_HTML = [[
<h1>CC-Windows Browser</h1>
<p>Type an address in the bar above and press Enter. Anything that does not look like an address is searched.</p>
<h2>Try these</h2>
<ul>
<li><a href="https://example.com/">example.com</a></li>
<li><a href="https://tweaked.cc/">tweaked.cc - CC:Tweaked docs</a></li>
<li><a href="https://text.npr.org/">text.npr.org - text-only news</a></li>
<li><a href="file:///">Browse local files</a></li>
</ul>
<hr>
<p>Keys: Ctrl+L address bar, Ctrl+R / F5 reload, Backspace back, arrows / PageUp / PageDown / Home / End scroll. Right-click for a menu, middle-click a link to open it in a new window.</p>
<p>Needs http.enabled in the server config. Images, scripts and styles are not supported - pages show as text.</p>
]]

-----------------------------------------------------------------------
-- text helpers
-----------------------------------------------------------------------

local ENT = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    copy = "(c)", reg = "(R)", trade = "(TM)", hellip = "...", mdash = "-",
    ndash = "-", lsquo = "'", rsquo = "'", ldquo = '"', rdquo = '"',
    bull = "*", middot = "*", laquo = "<<", raquo = ">>", times = "x",
}

local function uchar(n)
    if not n then return "?" end
    if n == 9 or n == 10 or n == 13 or n == 160 then return " " end
    if n >= 32 and n < 127 then return string.char(n) end
    if n == 8211 or n == 8212 then return "-" end
    if n == 8216 or n == 8217 then return "'" end
    if n == 8220 or n == 8221 then return '"' end
    if n == 8226 then return "*" end
    if n == 8230 then return "..." end
    return "?"
end

local function decode(s)
    if not s:find("&", 1, true) then return s end
    s = s:gsub("&#[xX](%x+);", function(h) return uchar(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return uchar(tonumber(d)) end)
    s = s:gsub("&(%a+);", function(n) return ENT[n] end)
    return s
end

local function fixUtf8(s)
    if not s:find("[\128-\255]") then return s end
    s = s:gsub("\226\128\153", "'"):gsub("\226\128\152", "'")
    s = s:gsub("\226\128\156", '"'):gsub("\226\128\157", '"')
    s = s:gsub("\226\128\147", "-"):gsub("\226\128\148", "-")
    s = s:gsub("\226\128\166", "..."):gsub("\226\128\162", "*")
    s = s:gsub("\194\160", " ")
    s = s:gsub("[\194-\244][\128-\191]*", "?")
    return s
end

local function clean(s)
    s = decode(fixUtf8(s))
    return (s:gsub("%c", " "))
end

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function urlencode(s)
    return (s:gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function attr(tag, name)
    local t = " " .. tag
    return t:match("%s" .. name .. "%s*=%s*\"([^\"]*)\"")
        or t:match("%s" .. name .. "%s*=%s*'([^']*)'")
        or t:match("%s" .. name .. "%s*=%s*([^%s\"'>]+)")
end

-----------------------------------------------------------------------
-- URLs
-----------------------------------------------------------------------

local function resolve(base, href)
    if not href then return nil end
    local h = href:match("^%s*(.-)%s*$")
    if h == "" or h:sub(1, 1) == "#" then return nil end
    if h:match("^%a[%w+.-]*:") then
        if h:match("^https?://") or h:match("^file://") then
            return (h:gsub("#.*$", ""))
        end
        return nil -- mailto:, javascript:, data: ...
    end
    if not base then return nil end
    local scheme, host = base:match("^(https?)://([^/?#]+)")
    if not scheme then return nil end
    if h:sub(1, 2) == "//" then return scheme .. ":" .. h:gsub("#.*$", "") end
    if h:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. (h:gsub("#.*$", ""))
    end
    local basePath = base:match("^https?://[^/?#]+([^?#]*)") or ""
    if h:sub(1, 1) == "?" then
        return scheme .. "://" .. host .. (basePath ~= "" and basePath or "/") .. (h:gsub("#.*$", ""))
    end
    local dir = basePath:match("^(.*/)") or "/"
    local p, q = (dir .. h):match("^([^?#]*)(.*)$")
    q = q:gsub("#.*$", "")
    local trailing = p:sub(-1) == "/"
    local stack = {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then stack[#stack] = nil
        elseif seg ~= "." then stack[#stack + 1] = seg end
    end
    local path = "/" .. table.concat(stack, "/")
    if trailing and #stack > 0 then path = path .. "/" end
    return scheme .. "://" .. host .. path .. q
end

local function normalize(input)
    local s = (input or ""):match("^%s*(.-)%s*$")
    if s == "" then return nil end
    if s == HOME then return HOME end
    if s:match("^https?://") or s:match("^file://") then return s end
    if s:sub(1, 1) == "/" then return "file://" .. s end
    if not s:find("%s") and (s:find(".", 1, true) or s:match("^localhost")) then
        if s:match("^localhost") or s:match("^%d+%.%d+%.%d+%.%d+") then
            return "http://" .. s
        end
        return "https://" .. s
    end
    return "https://lite.duckduckgo.com/lite/?q=" .. urlencode(s)
end

-----------------------------------------------------------------------
-- HTML -> tokens
-----------------------------------------------------------------------

local function set(list)
    local t = {}
    for _, v in ipairs(list) do t[v] = true end
    return t
end

local BLOCK2 = set { "p", "ul", "ol", "table", "blockquote", "section", "article",
    "header", "footer", "nav", "main", "form", "pre", "dl", "figure",
    "fieldset", "details", "aside" }
local BLOCK1 = set { "div", "tr", "dt", "dd", "address", "figcaption", "summary", "caption" }
local SKIP = set { "script", "style", "svg", "template", "noscript" }

--- Returns title, tokens.
-- tokens: { t="w", s, sp, href, st } | { t="nl", n } | { t="br" } | { t="hr" } | { t="raw", s, href }
local function parseHtml(html, base)
    local toks, title = {}, ""
    local pending, linkHref, head, pre = false, nil, 0, 0
    local lower = html:lower()
    local n = #html
    local pos = 1

    local function emit(t) toks[#toks + 1] = t end
    local function nl(k) emit({ t = "nl", n = k }); pending = false end
    local function word(s, sp, st)
        emit({ t = "w", s = s, sp = sp, href = linkHref,
            st = st or (linkHref and "a") or (head > 0 and "h") or nil })
    end

    local function text(s)
        if pre > 0 then
            s = decode(fixUtf8(s)):gsub("\r", "")
            local lines = {}
            for l in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
            for i, l in ipairs(lines) do
                emit({ t = "raw", s = (l:gsub("\t", "    ")), href = linkHref })
                if i < #lines then emit({ t = "br" }) end
            end
            return
        end
        s = clean(s)
        if s == "" then return end
        local lead, trail = s:match("^%s"), s:match("%s$")
        local first = true
        for w in s:gmatch("%S+") do
            local sp
            if first then sp = pending or lead ~= nil else sp = true end
            first = false
            word(w, sp)
        end
        if first then pending = true else pending = trail ~= nil end
    end

    while pos <= n do
        local lt = html:find("<", pos, true)
        if not lt then text(html:sub(pos)); break end
        if lt > pos then text(html:sub(pos, lt - 1)) end
        if html:sub(lt, lt + 3) == "<!--" then
            local e = html:find("-->", lt + 4, true)
            pos = e and e + 3 or n + 1
        else
            local gt = html:find(">", lt, true)
            if not gt then break end
            local tag = html:sub(lt + 1, gt - 1)
            pos = gt + 1
            local closing = tag:sub(1, 1) == "/"
            local name = (tag:match("^/?%s*(%a[%w]*)") or ""):lower()
            if not closing then
                if SKIP[name] then
                    if tag:sub(-1) ~= "/" then
                        local c1, c2 = lower:find("</" .. name, pos, true)
                        if c1 then
                            local g = html:find(">", c2, true)
                            pos = g and g + 1 or n + 1
                        else
                            pos = n + 1
                        end
                    end
                elseif name == "title" then
                    local c1 = lower:find("</title", pos, true)
                    if c1 then
                        title = clean(html:sub(pos, c1 - 1)):match("^%s*(.-)%s*$")
                        local g = html:find(">", c1, true)
                        pos = g and g + 1 or n + 1
                    end
                elseif name == "a" then
                    local h = attr(tag, "href")
                    linkHref = h and resolve(base, decode(h)) or nil
                elseif name:match("^h[1-6]$") then
                    nl(2); head = head + 1
                elseif BLOCK2[name] then
                    nl(2)
                    if name == "pre" then pre = pre + 1 end
                elseif BLOCK1[name] then
                    nl(1)
                elseif name == "li" then
                    nl(1); word("*", false, nil); pending = true
                elseif name == "br" then
                    emit({ t = "br" }); pending = false
                elseif name == "hr" then
                    nl(1); emit({ t = "hr" }); nl(1)
                elseif name == "td" or name == "th" then
                    pending = true
                elseif name == "img" then
                    local alt = attr(tag, "alt")
                    if alt and alt ~= "" then
                        local a = "[" .. clean(alt) .. "]"
                        for w in a:gmatch("%S+") do word(w, true, "m") end
                    end
                end
            else
                if name == "a" then
                    linkHref = nil
                elseif name:match("^h[1-6]$") then
                    head = math.max(0, head - 1); nl(2)
                elseif BLOCK2[name] then
                    nl(2)
                    if name == "pre" then pre = math.max(0, pre - 1) end
                elseif BLOCK1[name] or name == "li" then
                    nl(1)
                end
            end
        end
    end
    return title, toks
end

local function parsePlain(body)
    local toks = {}
    body = body:gsub("\r", "")
    for l in (body .. "\n"):gmatch("(.-)\n") do
        toks[#toks + 1] = { t = "raw", s = (l:gsub("\t", "    ")):gsub("[%c\128-\255]", "?") }
        toks[#toks + 1] = { t = "br" }
    end
    return "", toks
end

local function looksHtml(body)
    local head = body:sub(1, 1500):lower()
    return head:find("<!doctype html", 1, true) or head:find("<html", 1, true)
        or head:find("<body", 1, true) or head:find("<head", 1, true)
        or head:find("<p>", 1, true) or head:find("<div", 1, true)
end

local function looksBinary(body)
    local sample = body:sub(1, 300)
    if #sample == 0 then return false end
    local bad = 0
    for i = 1, #sample do
        local b = sample:byte(i)
        if (b < 9) or (b > 13 and b < 32) then bad = bad + 1 end
    end
    return bad / #sample > 0.1
end

-----------------------------------------------------------------------
-- tokens -> wrapped lines
-- line = array of segments { x, s, w, st, href }
-----------------------------------------------------------------------

local function buildLines(tokens, maxW)
    maxW = math.max(maxW, CW * 2)
    local maxChars = math.max(1, math.floor(maxW / CW))
    local lines, cur, x = {}, {}, 0

    local function push() lines[#lines + 1] = cur; cur = {}; x = 0 end
    local function brk(k)
        if #cur > 0 then push() end
        if k >= 2 and #lines > 0 and #lines[#lines] > 0 then push() end
    end

    for _, tok in ipairs(tokens) do
        local t = tok.t
        if t == "nl" then
            brk(tok.n)
        elseif t == "br" then
            push()
        elseif t == "hr" then
            brk(1)
            cur[1] = { x = 0, s = string.rep("-", maxChars), w = maxChars * CW, st = "m" }
            push()
        elseif t == "w" then
            local s = tok.s
            local sp = (x > 0 and tok.sp) and CW or 0
            if x + sp + #s * CW > maxW and x > 0 then push(); sp = 0 end
            while #s > maxChars do
                cur[#cur + 1] = { x = x, s = s:sub(1, maxChars), w = maxChars * CW, st = tok.st, href = tok.href }
                push()
                s = s:sub(maxChars + 1)
            end
            cur[#cur + 1] = { x = x + sp, s = s, w = #s * CW, st = tok.st, href = tok.href }
            x = x + sp + #s * CW
        elseif t == "raw" then
            local s = tok.s
            while #s > maxChars do
                cur[#cur + 1] = { x = x, s = s:sub(1, maxChars), w = maxChars * CW, href = tok.href }
                push()
                s = s:sub(maxChars + 1)
            end
            if #s > 0 then
                cur[#cur + 1] = { x = x, s = s, w = #s * CW, href = tok.href }
                x = x + #s * CW
            end
        end
    end
    if #cur > 0 then push() end
    return lines
end

-----------------------------------------------------------------------
-- the app
-----------------------------------------------------------------------

function app.create(win, opts, ctx)
    local theme, widgets = ctx.theme, ctx.widgets
    local C = theme.C

    local self = {
        hist = {}, hpos = 0,
        field = widgets.newField(""), focus = false,
        tokens = {}, lines = nil, layoutW = nil, top = 0, vis = 1,
        title = "", url = nil, status = "Ready",
        pending = nil, started = 0, tick = nil,
        restoreTop = 0, ctrl = false, sbDrag = false,
    }

    local function hit(x, y, r)
        return x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
    end

    local function toolbar(cw)
        local fw = math.max(20, cw - 53 - 30)
        return {
            back = { 3, 3, 14, 14 }, fwd = { 19, 3, 14, 14 }, rel = { 35, 3, 14, 14 },
            field = { 53, 3, fw, 14 }, go = { 53 + fw + 3, 3, 24, 14 },
        }
    end

    local function setField(text)
        self.field.text = text
        self.field.caret = #text
        self.field.scroll = 0
    end

    local function startTick()
        if self.tick then pcall(os.cancelTimer, self.tick) end
        self.tick = os.startTimer(0.5)
    end

    local function setPage(url, title, toks, status)
        self.url = url
        self.title = title or ""
        self.tokens = toks
        self.lines = nil
        self.top = self.restoreTop or 0
        self.restoreTop = 0
        self.status = status or "Done"
        self.pending = nil
        setField(url == HOME and "" or url)
        local shown = (self.title ~= "" and self.title) or (url == HOME and "Home") or tostring(url)
        pcall(ctx.wm.setTitle, win, shown .. " - Browser")
        win.dirty = true
    end

    local function errorPage(url, msg, hint)
        local html = "<h2>Cannot open this page</h2><p>" .. esc(url or "") .. "</p><p>" .. esc(msg) .. "</p>"
        if hint then html = html .. "<p>" .. esc(hint) .. "</p>" end
        local title, toks = parseHtml(html, nil)
        setPage(url, "Error", toks, "Failed")
    end

    local function finish(url, body, ct, code, note)
        body = body or ""
        if looksBinary(body) then
            return errorPage(url, "This looks like binary data (image, archive...). The browser only shows text.")
        end
        if #body > MAXB then body = body:sub(1, MAXB); note = "truncated" end
        local lct = (ct or ""):lower()
        local isHtml
        if lct:find("html", 1, true) then isHtml = true
        elseif lct:find("text/plain", 1, true) or lct:find("json", 1, true)
            or lct:find("javascript", 1, true) or lct:find("xml", 1, true) then isHtml = false
        else isHtml = looksHtml(body) and true or false end
        local title, toks
        if isHtml then title, toks = parseHtml(body, url) else title, toks = parsePlain(body) end
        local status = "Done" .. (code and (" (" .. code .. ")") or "") .. (note and (", " .. note) or "")
        setPage(url, title, toks, status)
    end

    local function loadLocal(url)
        local path = url:sub(8)
        if path == "" then path = "/" end
        local ok, err = pcall(function()
            if not fs.exists(path) then error("No such file or folder: " .. path, 0) end
            if fs.isDir(path) then
                local names = fs.list(path)
                table.sort(names)
                local join = (path:sub(-1) == "/") and path or (path .. "/")
                local out = { "<h2>Index of " .. esc(path) .. "</h2><ul>" }
                if path ~= "/" then
                    local parent = "/" .. fs.getDir(path)
                    out[#out + 1] = '<li><a href="file://' .. parent .. '">..</a></li>'
                end
                for _, name in ipairs(names) do
                    local full = join .. name
                    local label = esc(name) .. (fs.isDir(full) and "/" or "")
                    out[#out + 1] = '<li><a href="file://' .. full .. '">' .. label .. "</a></li>"
                end
                out[#out + 1] = "</ul>"
                local title, toks = parseHtml(table.concat(out), nil)
                setPage(url, path, toks, "Folder")
            else
                local f = fs.open(path, "r")
                if not f then error("Cannot read " .. path, 0) end
                local data = f.readAll() or ""
                f.close()
                local isHtml = path:match("%.html?$") ~= nil
                finish(url, data, isHtml and "text/html" or "text/plain", nil, nil)
            end
        end)
        if not ok then errorPage(url, tostring(err)) end
    end

    function self:load(url, top)
        if self.pending then self.pending = nil end
        self.restoreTop = top or 0
        if url == HOME then
            local title, toks = parseHtml(HOME_HTML, nil)
            setPage(HOME, "Home", toks, "Ready")
            return
        end
        if url:sub(1, 7) == "file://" then
            loadLocal(url)
            return
        end
        if not http or not http.request then
            return errorPage(url, "The http API is not available.",
                "Set http.enabled = true in the server's ComputerCraft config.")
        end
        self.url = url
        setField(url)
        local ok, err = pcall(http.request, {
            url = url,
            headers = { ["User-Agent"] = "CC-Windows-Browser/1.0", ["Accept"] = "text/html,text/plain,*/*" },
        })
        if not ok then
            return errorPage(url, tostring(err))
        end
        self.pending = url
        self.started = os.clock()
        self.status = "Loading..."
        startTick()
        win.dirty = true
    end

    function self:navigate(url)
        local cur = self.hist[self.hpos]
        if cur then cur.top = self.top end
        for i = #self.hist, self.hpos + 1, -1 do table.remove(self.hist, i) end
        self.hist[#self.hist + 1] = { url = url, top = 0 }
        self.hpos = #self.hist
        self:load(url, 0)
    end

    function self:go(text)
        local url = normalize(text)
        self.focus = false
        if url then self:navigate(url) end
        win.dirty = true
    end

    function self:back()
        if self.hpos <= 1 then return end
        self.hist[self.hpos].top = self.top
        self.hpos = self.hpos - 1
        local h = self.hist[self.hpos]
        self:load(h.url, h.top)
    end

    function self:forward()
        if self.hpos >= #self.hist then return end
        self.hist[self.hpos].top = self.top
        self.hpos = self.hpos + 1
        local h = self.hist[self.hpos]
        self:load(h.url, h.top)
    end

    function self:reload()
        if self.url then self:load(self.url, self.top) end
    end

    -------------------------------------------------------------------
    -- drawing
    -------------------------------------------------------------------

    function self:draw(dc, cw, ch)
        local viewH = ch - TB_H - SB_H
        local viewW = cw - 8
        local vis = math.max(1, math.floor(viewH / LH))
        self.vis = vis
        if not self.lines or self.layoutW ~= viewW then
            self.lines = buildLines(self.tokens, viewW - 2 * MARGIN)
            self.layoutW = viewW
        end
        local maxTop = math.max(0, #self.lines - vis)
        if self.top > maxTop then self.top = maxTop end
        if self.top < 0 then self.top = 0 end

        -- page
        dc:fill(0, TB_H, cw, viewH, C.fieldBg)
        dc:pushClip(0, TB_H, viewW, viewH)
        for i = 1, vis + 1 do
            local line = self.lines[self.top + i]
            if not line then break end
            local y = TB_H + (i - 1) * LH + 1
            for _, sg in ipairs(line) do
                local col = C.text
                if sg.st == "a" then col = C.accent
                elseif sg.st == "h" then col = C.accentDark
                elseif sg.st == "m" then col = C.textMuted
                elseif sg.href then col = C.accent end
                dc:text(MARGIN + sg.x, y, sg.s, col)
                if sg.href then dc:fill(MARGIN + sg.x, y + 9, sg.w, 1, col) end
            end
        end
        dc:popClip()
        widgets.scrollV(dc, cw - 8, TB_H, 8, viewH, self.top, #self.lines, vis, false)

        -- toolbar
        dc:fill(0, 0, cw, TB_H, C.face)
        dc:fill(0, TB_H - 1, cw, 1, C.bevelMid)
        local r = toolbar(cw)
        widgets.button(dc, r.back[1], r.back[2], r.back[3], r.back[4], "<",
            { state = self.hpos <= 1 and "disabled" or nil })
        widgets.button(dc, r.fwd[1], r.fwd[2], r.fwd[3], r.fwd[4], ">",
            { state = self.hpos >= #self.hist and "disabled" or nil })
        widgets.button(dc, r.rel[1], r.rel[2], r.rel[3], r.rel[4], "R")
        widgets.fieldDraw(dc, r.field[1], r.field[2], r.field[3], r.field[4],
            self.field, self.focus, self.focus)
        widgets.button(dc, r.go[1], r.go[2], r.go[3], r.go[4], "Go")

        -- status
        local st = self.status or ""
        if self.pending then
            local dots = string.rep(".", math.floor(os.clock() * 2) % 4)
            st = "Loading " .. self.pending .. dots
        elseif self.url and self.url ~= HOME then
            st = st .. "  " .. self.url
        end
        theme.band(dc, 0, ch - SB_H, cw, SB_H, widgets.ellipsis(st, cw - 8))
    end

    function self:resize()
        self.lines = nil
        win.dirty = true
    end

    -------------------------------------------------------------------
    -- input
    -------------------------------------------------------------------

    local function linkAt(x, y, ch)
        if not self.lines then return nil end
        if y < TB_H or y >= ch - SB_H then return nil end
        local line = self.lines[self.top + math.floor((y - TB_H) / LH) + 1]
        if not line then return nil end
        local px = x - MARGIN
        for _, sg in ipairs(line) do
            if sg.href and px >= sg.x and px < sg.x + sg.w then return sg.href end
        end
        return nil
    end

    local function scrollTo(y, ch)
        local viewH = ch - TB_H - SB_H
        local maxTop = math.max(0, #self.lines - self.vis)
        local frac = math.min(1, math.max(0, (y - TB_H) / math.max(1, viewH)))
        self.top = math.floor(frac * maxTop + 0.5)
        win.dirty = true
    end

    function self:click(x, y, button)
        local cw, ch = win.content.w, win.content.h
        if y < TB_H then
            if button ~= 1 then return true end
            local r = toolbar(cw)
            if hit(x, y, r.back) then self.focus = false; self:back()
            elseif hit(x, y, r.fwd) then self.focus = false; self:forward()
            elseif hit(x, y, r.rel) then self.focus = false; self:reload()
            elseif hit(x, y, r.go) then self:go(self.field.text)
            elseif hit(x, y, r.field) then
                self.focus = true
                self.field.caret = #self.field.text
            else
                self.focus = false
            end
            win.dirty = true
            return true
        end

        self.focus = false
        win.dirty = true

        if x >= cw - 8 and y < ch - SB_H then
            self.sbDrag = true
            scrollTo(y, ch)
            return true
        end

        local link = linkAt(x, y, ch)
        if button == 1 then
            if link then self:navigate(link) end
        elseif button == 3 then
            if link then ctx.launch("browser", { url = link }) end
        elseif button == 2 then
            local items = {}
            if link then
                items[#items + 1] = { label = "Open link", onPick = function() self:navigate(link) end }
                items[#items + 1] = { label = "Open in new window",
                    onPick = function() ctx.launch("browser", { url = link }) end }
                items[#items + 1] = { label = "Copy to address bar",
                    onPick = function() setField(link); win.dirty = true end }
                items[#items + 1] = { sep = true }
            end
            items[#items + 1] = { label = "Back", disabled = self.hpos <= 1, onPick = function() self:back() end }
            items[#items + 1] = { label = "Forward", disabled = self.hpos >= #self.hist,
                onPick = function() self:forward() end }
            items[#items + 1] = { label = "Reload", onPick = function() self:reload() end }
            ctx.menu.open { x = win.content.x + x, y = win.content.y + y, items = items }
        end
        return true
    end

    function self:drag(x, y)
        if self.sbDrag then scrollTo(y, win.content.h) end
        return true
    end

    function self:up()
        self.sbDrag = false
    end

    function self:scroll(x, y, dir)
        self.top = math.max(0, math.min(math.max(0, #(self.lines or {}) - self.vis), self.top + dir * 3))
        win.dirty = true
        return true
    end

    function self:key(key)
        if key == keys.leftCtrl or key == keys.rightCtrl then self.ctrl = true; return true end

        if self.ctrl then
            if key == keys.l then self.focus = true; self.field.caret = #self.field.text; win.dirty = true; return true end
            if key == keys.r then self:reload(); return true end
        end

        if self.focus then
            if key == keys.enter or key == keys.numPadEnter then
                self:go(self.field.text)
            elseif widgets.fieldKey(self.field, key) then
                win.dirty = true
            end
            return true
        end

        local maxTop = math.max(0, #(self.lines or {}) - self.vis)
        if key == keys.down then self.top = math.min(maxTop, self.top + 1)
        elseif key == keys.up then self.top = math.max(0, self.top - 1)
        elseif key == keys.pageDown then self.top = math.min(maxTop, self.top + self.vis - 1)
        elseif key == keys.pageUp then self.top = math.max(0, self.top - self.vis + 1)
        elseif key == keys.home then self.top = 0
        elseif key == keys["end"] then self.top = maxTop
        elseif key == keys.f5 then self:reload()
        elseif key == keys.backspace then self:back()
        else return false end
        win.dirty = true
        return true
    end

    function self:key_up(key)
        if key == keys.leftCtrl or key == keys.rightCtrl then self.ctrl = false end
    end

    function self:char(ch)
        if self.focus then
            widgets.fieldChar(self.field, ch)
            win.dirty = true
        end
        return true
    end

    -------------------------------------------------------------------
    -- background events
    -------------------------------------------------------------------

    function self:feed(ev)
        local name = ev[1]
        if name ~= "http_success" and name ~= "http_failure" then return end
        if not self.pending or ev[2] ~= self.pending then return end
        local url = self.pending
        self.pending = nil

        local function readHandle(h)
            if not h then return nil end
            local okb, body = pcall(h.readAll)
            local code, ct
            if h.getResponseCode then local okc, c = pcall(h.getResponseCode); if okc then code = c end end
            if h.getResponseHeaders then
                local okh, hd = pcall(h.getResponseHeaders)
                if okh and type(hd) == "table" then ct = hd["Content-Type"] or hd["content-type"] end
            end
            pcall(h.close)
            return okb and body or nil, ct, code
        end

        if name == "http_success" then
            local body, ct, code = readHandle(ev[3])
            finish(url, body, ct, code)
        else
            local body, ct, code = readHandle(ev[4])
            if body and #body > 0 then
                finish(url, body, ct, code)
            else
                local msg = tostring(ev[3] or "request failed") .. (code and (" (HTTP " .. code .. ")") or "")
                errorPage(url, msg,
                    "CC:Tweaked blocks local/private addresses by default and the server may restrict domains.")
            end
        end
    end

    function self:timer(id)
        if id ~= self.tick then return end
        self.tick = nil
        if self.pending then
            if os.clock() - self.started > 30 then
                local url = self.pending
                self.pending = nil
                errorPage(url, "The request timed out after 30 seconds.")
            else
                self.tick = os.startTimer(0.5)
            end
            win.dirty = true
        end
    end

    function self:close()
        if self.tick then pcall(os.cancelTimer, self.tick) end
        self.pending = nil
    end

    -------------------------------------------------------------------
    -- start
    -------------------------------------------------------------------

    local start = opts and opts.url and normalize(opts.url)
    if start then
        self:navigate(start)
    else
        self:navigate(HOME)
        self.focus = true
    end

    return self
end

return app
