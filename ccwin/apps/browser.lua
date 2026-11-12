--- CC-Windows - Browser: a small HTML web browser.
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
-- parses HTML into blocks and inline styles - headings, lists, tables,
-- quotes, code, buttons, links - lays the page out once per window width
-- and draws only the lines that are on screen, so scrolling never re-parses
-- or re-lays-out. Also opens local files and folders (file:///...).
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
local LH = 11          -- normal line height (9px font + underline room)
local CW = 6           -- character width at scale 1
local FH = 9           -- font height
local MARGIN = 6       -- page margin
local MAXB = 120000    -- max bytes parsed (CC kills programs that never yield)

-- Block spacing: top padding given to the first line of a block.
local PAD_P, PAD_LIST, PAD_QUOTE, PAD_PRE, PAD_TABLE = 4, 4, 5, 4, 6
local PAD_H = { 9, 8, 6, 5, 4, 4 }          -- h1 .. h6, before
local BOT_H = { 3, 3, 1, 1, 1, 1 }          -- h1 .. h6, after
local PAD_DT, PAD_DD = 4, 2
local LIST_IND, QUOTE_IND = 8, 10           -- indent per list level / quote
local CELL_PAD = 4                          -- table cell right padding

-- Inline style bits (carried on every word; resolved to colours at draw).
local S_BOLD, S_CODE, S_MUTED, S_UNDER = 2, 4, 8, 16
local S_MARK, S_SUP, S_SUB, S_BTN, S_FIELD = 32, 64, 128, 256, 512

local function has(st, b) return st % (b + b) >= b end          -- power-of-2 bits
local function bitAdd(st, b) return has(st, b) and st or st + b end

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
<h2>What it understands</h2>
<p>Headings, <b>bold</b>, <code>code</code>, lists, quotes and tables all lay out like a real page:</p>
<blockquote><p>A <code>&lt;blockquote&gt;</code> gets an indent and a bar down the side.</p></blockquote>
<table>
<tr><th>Tag</th><th>Rendered as</th></tr>
<tr><td><code>&lt;h1&gt;</code></td><td>a big heading</td></tr>
<tr><td><code>&lt;li&gt;</code></td><td>a bulleted item</td></tr>
<tr><td><code>&lt;td&gt;</code></td><td>a table cell</td></tr>
</table>
<hr>
<p>Keys: Ctrl+L address bar, Ctrl+R / F5 reload, Backspace back, arrows / PageUp / PageDown / Home / End scroll. Right-click for a menu, middle-click a link to open it in a new window.</p>
<p>Needs http.enabled in the server config. Images, scripts and styles are not supported.</p>
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
--
-- Inline:  { t="w", s, sp, href, st }   word (st = style bits)
--          { t="raw", s, href, st }     preformatted / plain line piece
--          { t="br" }                   forced line break
-- Blocks:  { t="b", k="open"|"close", b=name, lvl, ordered, num }
--          { t="hr" }
-- Table:   { t="table", rows = { { head, cells = { {toks...} } } } }
-----------------------------------------------------------------------

local function set(list)
    local t = {}
    for _, v in ipairs(list) do t[v] = true end
    return t
end

local SKIP = set { "script", "style", "svg", "template", "noscript",
    "iframe", "canvas", "object", "embed" }

local BLOCKS = set { "p", "div", "section", "article", "header", "footer",
    "nav", "main", "aside", "form", "fieldset", "figure", "figcaption",
    "address", "summary", "details", "caption", "center", "menu",
    "ul", "ol", "li", "dl", "dt", "dd", "blockquote", "pre",
    "h1", "h2", "h3", "h4", "h5", "h6" }

--- Returns title, tokens.
local function parseHtml(html, base)
    local toks, title = {}, ""
    local lower = html:lower()
    local n = #html
    local pos = 1

    local bstack = {}       -- open block names (closes pair with them)
    local lists = {}        -- { ordered=, n= } stack for ul/ol numbering
    local href              -- current <a href>
    local pre = 0           -- inside <pre>
    local pending = false   -- whitespace seen since the last word
    local btn               -- <button> label being collected
    local cnt = { bold = 0, code = 0, under = 0, mark = 0, sup = 0, sub = 0, small = 0 }
    local tblDepth = 0      -- >0 while collecting a table
    local rows, row, cell   -- table being collected

    local function emit(t) toks[#toks + 1] = t end

    local function styleNow()
        local st = 0
        if cnt.bold > 0 then st = st + S_BOLD end
        if cnt.code > 0 then st = st + S_CODE end
        if cnt.under > 0 then st = st + S_UNDER end
        if cnt.mark > 0 then st = st + S_MARK end
        if cnt.sup > 0 then st = st + S_SUP end
        if cnt.sub > 0 then st = st + S_SUB end
        if cnt.small > 0 then st = st + S_MUTED end
        local top = bstack[#bstack]
        if top == "dt" then st = bitAdd(st, S_BOLD)
        elseif top and top:match("^h[3-6]$") then st = bitAdd(st, S_BOLD) end
        return st
    end

    local function ensureCell()
        if cell then return cell end
        if not row then
            row = { cells = {}, head = false }
            if not rows then rows = {} end
            rows[#rows + 1] = row
        end
        cell = {}
        row.cells[#row.cells + 1] = cell
        return cell
    end

    local function emitBR()
        local d = tblDepth > 0 and ensureCell() or toks
        d[#d + 1] = { t = "br" }
        pending = false
    end

    --- One word into the current destination (flow, cell or button buffer).
    local function word(s, sp, st)
        st = st or styleNow()
        if btn ~= nil then
            btn = btn .. ((btn ~= "" and sp) and " " or "") .. s
            return
        end
        if tblDepth > 0 then
            if not cell and s:match("^%s*$") then return end
            local d = ensureCell()
            d[#d + 1] = { t = "w", s = s, sp = sp, href = href, st = st }
            return
        end
        toks[#toks + 1] = { t = "w", s = s, sp = sp, href = href, st = st }
    end

    --- Preformatted / plain text: keep line structure, hard-wrap later.
    local function emitRaw(s)
        s = decode(fixUtf8(s)):gsub("\r", "")
        local d = tblDepth > 0 and (cell or ensureCell()) or toks
        local first = true
        for l in (s .. "\n"):gmatch("(.-)\n") do
            if not first then
                d[#d + 1] = { t = "br" }
                pending = false
            end
            first = false
            local piece = l:gsub("\t", "    ")
            if piece == "" then piece = " " end -- keeps blank lines visible
            d[#d + 1] = { t = "raw", s = piece, href = href, st = styleNow() }
        end
    end

    local function text(s)
        if pre > 0 then emitRaw(s); return end
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

    local function closeTop()
        local name = table.remove(bstack)
        if not name then return end
        emit({ t = "b", k = "close", b = name })
        if name == "ul" or name == "ol" then lists[#lists] = nil end
        if name == "pre" then pre = math.max(0, pre - 1) end
    end

    --- Open a block, first closing anything HTML says cannot contain it
    --- (<p> and headings hold no blocks, an <li> ends at the next <li>...).
    local function openBlock(name, lvl, ordered, num)
        while #bstack > 0 do
            local top = bstack[#bstack]
            local pop = false
            if top == "p" then pop = true
            elseif top:match("^h[1-6]$") then pop = true
            elseif name == "li" and top == "li" then pop = true
            elseif (name == "dt" or name == "dd") and (top == "dt" or top == "dd") then pop = true
            end
            if not pop then break end
            closeTop()
        end
        bstack[#bstack + 1] = name
        emit({ t = "b", k = "open", b = name, lvl = lvl, ordered = ordered, num = num })
        if name == "ul" or name == "ol" then
            lists[#lists + 1] = { ordered = name == "ol", n = 0 }
        elseif name == "pre" then
            pre = pre + 1
        end
    end

    local function closeBlock(name)
        for i = #bstack, 1, -1 do
            if bstack[i] == name then
                while #bstack >= i do closeTop() end
                return true
            end
        end
        return false
    end

    local function flushButton()
        if btn == nil then return end
        local s = btn
        btn = nil
        if s ~= "" then word(s, false, S_BTN) end
    end

    local function handleTag(name, closing, tag)
        -- table plumbing wins over everything while a table is open
        if name == "table" and tblDepth > 0 and not closing then
            tblDepth = tblDepth + 1
            return
        end
        if closing then
            if name == "table" then
                tblDepth = tblDepth - 1
                if tblDepth <= 0 then
                    tblDepth = 0
                    if rows and #rows > 0 then emit({ t = "table", rows = rows }) end
                    rows, row, cell = nil, nil, nil
                end
                return
            end
            if tblDepth > 0 then return end        -- stray closes inside a cell
            if name == "a" then href = nil; return end
            if name == "button" then flushButton(); return end
            if BLOCKS[name] then closeBlock(name); return end
            if name == "b" or name == "strong" then cnt.bold = math.max(0, cnt.bold - 1)
            elseif name == "u" then cnt.under = math.max(0, cnt.under - 1)
            elseif name == "code" or name == "kbd" or name == "samp" or name == "tt" then
                cnt.code = math.max(0, cnt.code - 1)
            elseif name == "mark" then cnt.mark = math.max(0, cnt.mark - 1)
            elseif name == "sup" then cnt.sup = math.max(0, cnt.sup - 1)
            elseif name == "sub" then cnt.sub = math.max(0, cnt.sub - 1)
            elseif name == "small" then cnt.small = math.max(0, cnt.small - 1)
            end
            return
        end

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
            return
        end
        if name == "title" then
            local c1 = lower:find("</title", pos, true)
            if c1 then
                title = clean(html:sub(pos, c1 - 1)):match("^%s*(.-)%s*$")
                local g = html:find(">", c1, true)
                pos = g and g + 1 or n + 1
            end
            return
        end
        if name == "table" then
            if tblDepth == 0 then rows, row, cell = {}, nil, nil end
            tblDepth = tblDepth + 1
            return
        end
        if tblDepth > 0 then
            if name == "tr" then
                row = { cells = {}, head = false }
                if not rows then rows = {} end
                rows[#rows + 1] = row
                cell = nil
            elseif name == "td" or name == "th" then
                if not row then
                    row = { cells = {}, head = false }
                    if not rows then rows = {} end
                    rows[#rows + 1] = row
                end
                cell = {}
                row.cells[#row.cells + 1] = cell
                if name == "th" then row.head = true end
            elseif name == "br" then
                emitBR()
            end
            return                        -- block tags inside cells: text just flows
        end

        if name:match("^h[1-6]$") then
            openBlock(name, tonumber(name:sub(2)))
        elseif name == "p" then openBlock("p")
        elseif name == "ul" or name == "ol" then openBlock(name)
        elseif name == "li" then
            local L = lists[#lists]
            if L then
                local v = tonumber(attr(tag, "value"))
                if v then L.n = v else L.n = L.n + 1 end
                openBlock("li", nil, L.ordered, L.n)
            else
                openBlock("li")
            end
        elseif name == "blockquote" then openBlock("blockquote")
        elseif name == "pre" then openBlock("pre")
        elseif name == "dl" then openBlock("dl")
        elseif name == "dt" then openBlock("dt")
        elseif name == "dd" then openBlock("dd")
        elseif BLOCKS[name] then openBlock(name)   -- div, section, form, ...
        elseif name == "hr" then
            while #bstack > 0 do
                local top = bstack[#bstack]
                if top == "p" or top:match("^h[1-6]$") then closeTop() else break end
            end
            emit({ t = "hr" })
        elseif name == "br" then
            emitBR()
        elseif name == "a" then
            local h = attr(tag, "href")
            href = h and resolve(base, decode(h)) or nil
        elseif name == "img" then
            local alt = attr(tag, "alt")
            if alt and alt ~= "" then
                local a = "[" .. clean(alt) .. "]"
                for w in a:gmatch("%S+") do word(w, true, bitAdd(styleNow(), S_MUTED)) end
            end
        elseif name == "button" then
            btn = ""
        elseif name == "input" then
            local typ = (attr(tag, "type") or "text"):lower()
            local val = attr(tag, "value") or attr(tag, "placeholder") or ""
            if typ == "submit" or typ == "button" or typ == "reset" then
                local lbl = val ~= "" and val or (typ == "submit" and "Submit" or "")
                if lbl ~= "" then word(lbl, false, S_BTN) end
            elseif typ ~= "hidden" and typ ~= "image" then
                local txt = val ~= "" and val or " "
                if #txt < 10 then txt = txt .. string.rep(" ", 10 - #txt) end
                word(txt, false, bitAdd(S_FIELD, val == "" and S_MUTED or 0))
            end
        elseif name == "b" or name == "strong" then cnt.bold = cnt.bold + 1
        elseif name == "u" then cnt.under = cnt.under + 1
        elseif name == "code" or name == "kbd" or name == "samp" or name == "tt" then
            cnt.code = cnt.code + 1
        elseif name == "mark" then cnt.mark = cnt.mark + 1
        elseif name == "sup" then cnt.sup = cnt.sup + 1
        elseif name == "sub" then cnt.sub = cnt.sub + 1
        elseif name == "small" then cnt.small = cnt.small + 1
        end                                -- i/em: no italic face in the font
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
            if name ~= "" then handleTag(name, closing, tag) end
        end
    end
    if btn ~= nil then flushButton() end
    if tblDepth > 0 and rows and #rows > 0 then emit({ t = "table", rows = rows }) end
    while #bstack > 0 do closeTop() end
    return title, toks
end

local function parsePlain(body)
    local toks = {}
    body = body:gsub("\r", "")
    for l in (body .. "\n"):gmatch("(.-)\n") do
        local piece = (l:gsub("\t", "    ")):gsub("[%c\128-\255]", "?")
        if piece == "" then piece = " " end
        toks[#toks + 1] = { t = "raw", s = piece }
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
-- layout: tokens -> visual lines + pixel offsets
--
-- A line is one row on screen: { segs, h, pad, th, ... }. `offs` is the
-- prefix sum of heights, so the draw code binary-searches straight to the
-- first visible line and scrolling is a pure pixel offset.
-----------------------------------------------------------------------

local TSET = set { "p", "li", "dt", "dd", "pre", "blockquote",
    "h1", "h2", "h3", "h4", "h5", "h6" }

local function lineBot(kind)
    local lvl = kind and tonumber(kind:match("^h([1-6])$"))
    if lvl then return BOT_H[lvl] end       -- extra gap under a heading
    return 0                                -- needLine always adds 2 for the
end                                          -- underline room

local function padFor(name, tok)
    local lvl = tok and tok.lvl
    if name:match("^h[1-6]$") and lvl then return PAD_H[lvl] end
    if name == "p" then return PAD_P end
    if name == "blockquote" then return PAD_QUOTE end
    if name == "pre" then return PAD_PRE end
    if name == "dt" then return PAD_DT end
    if name == "dd" then return PAD_DD end
    return 0
end

local function newFlow(W, indent, scale)
    indent, scale = indent or 0, scale or 1
    return {
        W = W, depth = 0, quotes = 0, pad = 0,
        tmpl = { indent = indent, scale = scale },
        tstack = {}, once = nil, first = true, cur = nil,
        lines = {}, offs = { 0 },
    }
end

local function flowPush(f, ln)
    ln.pad = f.pad or 0
    f.pad = 0
    ln.h = ln.pad + ln.th + (ln.bot or 0)
    f.lines[#f.lines + 1] = ln
    f.offs[#f.offs + 1] = f.offs[#f.offs] + ln.h
end

local function flowFlush(f)
    local ln = f.cur
    f.cur = nil
    if not ln or #ln.segs == 0 then return end
    flowPush(f, ln)
end

local function needLine(f)
    if f.cur then return f.cur end
    local t = f.tmpl
    local scale = t.scale or 1
    local ln = {
        segs = {}, x = 0, scale = scale, th = FH * scale,
        kind = t.kind, indent = t.indent or 0, bg = t.bg, bar = t.bar,
        bullet = f.once, first = f.first,
        bot = (f.first and t.bot or 0) + 2,
    }
    f.once = nil
    f.first = false
    f.cur = ln
    return ln
end

--- Current line is full: push it and continue on a hanging-indent copy.
local function wrapLine(f)
    local old = f.cur
    f.cur = nil
    if #old.segs > 0 then flowPush(f, old) end
    f.cur = {
        segs = {}, x = 0, scale = old.scale, th = old.th, kind = old.kind,
        indent = old.indent, bg = old.bg, bar = old.bar, bot = 2,
    }
    return f.cur
end

local function flowWord(f, s, sp, st, href)
    local ln = needLine(f)
    local cw = CW * ln.scale
    local maxW = f.W - ln.indent
    if maxW < cw then maxW = cw end
    local maxChars = math.max(1, math.floor(maxW / cw))
    local spW = (ln.x > 0 and sp) and cw or 0
    if ln.x + spW + #s * cw > maxW and ln.x > 0 then
        ln = wrapLine(f)
        spW = 0
    end
    while #s > maxChars do
        local chunk = s:sub(1, maxChars)
        ln.segs[#ln.segs + 1] = { x = ln.indent + ln.x, s = chunk,
            w = maxChars * cw, st = st, href = href }
        ln.x = ln.x + maxChars * cw
        ln = wrapLine(f)
        s = s:sub(maxChars + 1)
        spW = 0
    end
    if s ~= "" then
        ln.segs[#ln.segs + 1] = { x = ln.indent + ln.x, s = s,
            w = #s * cw, st = st, href = href }
        ln.x = ln.x + spW + #s * cw
    end
end

local function flowRaw(f, s, st, href)
    if s == "" then return end
    local ln = needLine(f)
    if ln.x > 0 then ln = wrapLine(f) end
    local cw = CW * ln.scale
    local maxW = math.max(cw, f.W - ln.indent)
    local maxChars = math.max(1, math.floor(maxW / cw))
    while #s > maxChars do
        local chunk = s:sub(1, maxChars)
        ln.segs[#ln.segs + 1] = { x = ln.indent + ln.x, s = chunk,
            w = maxChars * cw, st = st, href = href }
        ln.x = ln.x + maxChars * cw
        ln = wrapLine(f)
        s = s:sub(maxChars + 1)
    end
    ln.segs[#ln.segs + 1] = { x = ln.indent + ln.x, s = s,
        w = #s * cw, st = st, href = href }
    ln.x = ln.x + #s * cw
end

--- Wrap a token list (a table cell) on its own, returning its lines plus
--- the natural width and the widest unbreakable word.
local function flowCell(toks, W, scale)
    local f = newFlow(W, 0, scale or 1)
    for _, tk in ipairs(toks) do
        if tk.t == "w" then flowWord(f, tk.s, tk.sp, tk.st, tk.href)
        elseif tk.t == "raw" then flowRaw(f, tk.s, tk.st, tk.href)
        elseif tk.t == "br" then flowFlush(f) end
    end
    flowFlush(f)
    local nat, minw = 0, 0
    for _, ln in ipairs(f.lines) do
        for _, sg in ipairs(ln.segs) do
            local right = sg.x + sg.w
            if right > nat then nat = right end
            if sg.w > minw then minw = sg.w end
        end
    end
    if #f.lines == 0 then minw = CW end
    return f.lines, nat, minw
end

--- Lay a whole table out: wrap every cell, share the width between
--- columns (shrinking the widest first), then emit one line per visual
--- row with the row's rule hanging off the last one.
local function layoutTable(tok, f)
    local rows = tok.rows
    local ncols = 0
    for _, r in ipairs(rows) do
        if #r.cells > ncols then ncols = #r.cells end
    end
    if ncols == 0 then return end

    local capW = f.W - ncols * CELL_PAD
    if capW < CW * 2 then capW = CW * 2 end

    local wrapped, nat, minw = {}, {}, {}
    for ri, r in ipairs(rows) do
        wrapped[ri] = {}
        for ci, cell in ipairs(r.cells) do
            local lines, cnat, cmin = flowCell(cell, capW, 1)
            wrapped[ri][ci] = lines
            if cnat > (nat[ci] or 0) then nat[ci] = cnat end
            if cmin > (minw[ci] or 0) then minw[ci] = cmin end
        end
    end

    local colW, sum = {}, 0
    for c = 1, ncols do
        colW[c] = nat[c] or CW
        sum = sum + colW[c]
    end
    local guard = 0
    while sum > capW and guard < 200 do
        guard = guard + 1
        local wi, wv = nil, 0
        for c = 1, ncols do
            if colW[c] > (minw[c] or 0) and colW[c] > wv then wi, wv = c, colW[c] end
        end
        if not wi then break end
        local nv = math.max(minw[wi], colW[wi] - (sum - capW))
        sum = sum - (colW[wi] - nv)
        colW[wi] = nv
    end

    -- cells that no longer fit their column are re-wrapped at it
    for ri, r in ipairs(rows) do
        for ci = 1, #r.cells do
            local lines = wrapped[ri][ci]
            local widest = 0
            for _, ln in ipairs(lines) do
                for _, sg in ipairs(ln.segs) do
                    local right = sg.x + sg.w
                    if right > widest then widest = right end
                end
            end
            if widest > colW[ci] then
                wrapped[ri][ci] = flowCell(r.cells[ci], colW[ci], 1)
            end
        end
    end

    local xs, x = {}, 0
    for c = 1, ncols do
        xs[c] = x
        x = x + colW[c] + CELL_PAD
    end
    local tableW = math.min(x, f.W)

    f.pad = math.max(f.pad, PAD_TABLE)
    for ri, r in ipairs(rows) do
        local cellLines, maxLines = {}, 1
        for ci = 1, ncols do
            cellLines[ci] = wrapped[ri][ci] or {}
            if #cellLines[ci] > maxLines then maxLines = #cellLines[ci] end
        end
        for li = 1, maxLines do
            local ln = {
                segs = {}, x = 0, scale = 1, th = FH,
                kind = "tr", indent = 0, first = false, bot = 2,
                bg = r.head and "alt" or nil,
            }
            for ci = 1, ncols do
                local src = cellLines[ci][li]
                if src then
                    for _, sg in ipairs(src.segs) do
                        local st = sg.st or 0
                        if r.head then st = bitAdd(st, S_BOLD) end
                        ln.segs[#ln.segs + 1] = {
                            x = xs[ci] + 2 + sg.x, s = sg.s, w = sg.w,
                            st = st, href = sg.href,
                        }
                    end
                end
            end
            if li == maxLines then
                ln.rule = r.head and "head" or "row"
                ln.ruleW = tableW
            end
            flowPush(f, ln)
        end
    end
    f.pad = PAD_TABLE
end

--- The line whose pixel band contains `py` (0-based into the page).
local function lineAt(offs, n, py)
    if py < 0 then py = 0 end
    local last = offs[n + 1] - 1
    if py > last then py = last end
    local lo, hi = 1, n
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if offs[mid] <= py then lo = mid else hi = mid - 1 end
    end
    return lo
end

--- Line template for a newly opened block: indent (page margin + list
--- depth + quote depth), heading scale, bottom spacing, quote bar.
local function makeTmpl(f, name, tok)
    local t = {
        kind = name,
        scale = (name == "h1" or name == "h2") and 2 or 1,
        bot = lineBot(name),
        bar = f.quotes > 0,
    }
    local q = f.quotes * QUOTE_IND
    if name == "li" then
        local depth = math.max(1, f.depth)
        local numX = q + (depth - 1) * LIST_IND + 1
        local textX = q + depth * LIST_IND
        local bullet
        if tok and tok.ordered and tok.num then
            local s = tostring(tok.num) .. "."
            if numX + #s * CW + 3 > textX then textX = numX + #s * CW + 3 end
            bullet = { s = s, x = numX }
        else
            if numX + 7 > textX then textX = numX + 7 end
            bullet = { sq = (depth % 2 == 1), x = numX }
        end
        t.indent = textX
        t.bullet = bullet
    elseif name == "dd" then
        t.indent = q + 8
    elseif name == "pre" then
        t.indent = q
        t.bg = "alt"
    else
        t.indent = q
    end
    return t
end

--- Build every line of the page once for a given content width.
local function layout(toks, W)
    if W < CW * 4 then W = CW * 4 end
    local f = newFlow(W, 0, 1)

    for _, tok in ipairs(toks) do
        local t = tok.t
        if t == "w" then
            flowWord(f, tok.s, tok.sp, tok.st, tok.href)
        elseif t == "raw" then
            flowRaw(f, tok.s, tok.st, tok.href)
        elseif t == "br" then
            flowFlush(f)
        elseif t == "hr" then
            flowFlush(f)
            f.pad = math.max(f.pad, 5)
            flowPush(f, { segs = {}, th = 1, bot = 4, hr = true,
                scale = 1, indent = 0 })
        elseif t == "table" then
            flowFlush(f)
            layoutTable(tok, f)
        elseif t == "b" then
            local name = tok.b
            if tok.k == "open" then
                if TSET[name] then
                    flowFlush(f)
                    f.tstack[#f.tstack + 1] = f.tmpl
                    if name == "blockquote" then f.quotes = f.quotes + 1 end
                    local tmpl = makeTmpl(f, name, tok)
                    f.once = tmpl.bullet      -- drawn on the item's first line only
                    tmpl.bullet = nil
                    if name ~= "li" then f.once = nil end
                    f.tmpl = tmpl
                    f.first = true
                    f.pad = math.max(f.pad, padFor(name, tok))
                elseif name == "ul" or name == "ol" then
                    flowFlush(f)
                    f.depth = f.depth + 1
                    if f.depth == 1 then f.pad = math.max(f.pad, PAD_LIST) end
                else
                    flowFlush(f)         -- div, section, form: just break
                end
            else
                if TSET[name] then
                    flowFlush(f)
                    f.tmpl = table.remove(f.tstack) or f.tmpl
                    f.once = nil
                    if name == "blockquote" then
                        f.quotes = math.max(0, f.quotes - 1)
                    end
                    f.first = true
                elseif name == "ul" or name == "ol" then
                    flowFlush(f)
                    f.depth = math.max(0, f.depth - 1)
                    if f.depth == 0 then f.pad = math.max(f.pad, PAD_LIST) end
                else
                    flowFlush(f)
                end
            end
        end
    end
    flowFlush(f)
    return f.lines, f.offs, f.offs[#f.offs]
end

--- The home page is static: parse it once and share the tokens.
local homeTitle, homeToks
local function homePage()
    if not homeToks then homeTitle, homeToks = parseHtml(HOME_HTML, nil) end
    return homeTitle, homeToks
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
        tokens = {}, lines = {}, offs = { 0 }, height = 0, layoutW = nil,
        off = 0,                                   -- scroll position, pixels
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

    local function viewSize()
        return win.content.w - 8, win.content.h - TB_H - SB_H
    end

    local function maxOff()
        local _, viewH = viewSize()
        return math.max(0, self.height - viewH)
    end

    local function clampOff()
        local m = maxOff()
        if self.off > m then self.off = m end
        if self.off < 0 then self.off = 0 end
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
        self.lines, self.offs, self.height = {}, { 0 }, 0
        self.layoutW = nil
        self.off = self.restoreTop or 0
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
            local title, toks = homePage()
            setPage(HOME, title, toks, "Ready")
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
        if cur then cur.top = self.off end
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
        self.hist[self.hpos].top = self.off
        self.hpos = self.hpos - 1
        local h = self.hist[self.hpos]
        self:load(h.url, h.top)
    end

    function self:forward()
        if self.hpos >= #self.hist then return end
        self.hist[self.hpos].top = self.off
        self.hpos = self.hpos + 1
        local h = self.hist[self.hpos]
        self:load(h.url, h.top)
    end

    function self:reload()
        if self.url then self:load(self.url, self.off) end
    end

    -------------------------------------------------------------------
    -- drawing
    -------------------------------------------------------------------

    local function bgColour(name)
        if name == "alt" then return C.listAlt end
        return nil
    end

    local function drawSeg(dc, ln, sg, x0, y)
        local st = sg.st or 0
        local scale = ln.scale
        local x = x0 + sg.x
        local col = C.text
        if ln.kind == "h1" or ln.kind == "h2" then col = C.accentDark end
        if has(st, S_MUTED) then col = C.textMuted end
        if sg.href then col = C.accent end
        local dy = 0
        if has(st, S_SUP) then dy = -2
        elseif has(st, S_SUB) then dy = 2 end
        if has(st, S_BTN) then
            theme.button(dc, x - 2, y, sg.w + 4, ln.th + 2, nil)
            dy = 1
        elseif has(st, S_FIELD) then
            theme.field(dc, x - 2, y, sg.w + 4, ln.th + 2, false)
            dy = 1
        elseif has(st, S_MARK) then
            dc:fill(x - 1, y, sg.w + 2, ln.th, C.warning)
            col = C.black
        elseif has(st, S_CODE) then
            dc:fill(x - 1, y, sg.w + 2, ln.th, C.listAlt)
        end
        dc:text(x, y + dy, sg.s, col, nil, scale)
        if has(st, S_BOLD) then dc:text(x + 1, y + dy, sg.s, col, nil, scale) end
        if sg.href or has(st, S_UNDER) then
            dc:fill(x, y + dy + FH * scale, sg.w, 1, col)
        end
    end

    local function drawLine(dc, ln, x0, y, W)
        local pad = ln.pad or 0
        local ty = y + pad
        local full = ln.h - pad
        if ln.bg then
            local c = bgColour(ln.bg)
            if c then dc:fill(x0, ty, W, full, c) end
        end
        if ln.bar then dc:fill(x0 + 1, ty, 2, full, C.bevelMid) end
        if ln.hr then dc:fill(x0, ty, W, 1, C.bevelMid) end
        local b = ln.bullet
        if b then
            if b.s then
                dc:text(x0 + b.x, ty, b.s, C.textMuted)
            elseif b.sq then
                dc:fill(x0 + b.x, ty + 3, 3, 3, C.textMuted)
            else
                dc:rect(x0 + b.x, ty + 3, 3, 3, C.textMuted)
            end
        end
        for _, sg in ipairs(ln.segs) do
            drawSeg(dc, ln, sg, x0, ty)
        end
        if ln.rule then
            local c = ln.rule == "head" and C.accent or C.bevelMid
            dc:fill(x0, y + ln.h - 1, ln.ruleW or W, 1, c)
        end
    end

    function self:draw(dc, cw, ch)
        local viewW, viewH = viewSize()
        local W = viewW - 2 * MARGIN
        if self.layoutW ~= W then
            self.lines, self.offs, self.height = layout(self.tokens, W)
            self.layoutW = W
            clampOff()
        end
        clampOff()

        -- page: only the lines that are on screen are touched
        dc:fill(0, TB_H, cw, viewH, C.fieldBg)
        dc:pushClip(0, TB_H, viewW, viewH)
        local n = #self.lines
        if n > 0 then
            local i = lineAt(self.offs, n, self.off)
            local y = TB_H + (self.offs[i] - self.off)
            while i <= n and y < TB_H + viewH do
                drawLine(dc, self.lines[i], MARGIN, y, W)
                y = y + self.lines[i].h
                i = i + 1
            end
        end
        dc:popClip()
        widgets.scrollV(dc, cw - 8, TB_H, 8, viewH, self.off,
            math.max(self.height, viewH), viewH, false)

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
        self.layoutW = nil
        win.dirty = true
    end

    -------------------------------------------------------------------
    -- input
    -------------------------------------------------------------------

    --- Line under the pointer, its text band, or nil when the click was
    --- in the padding between blocks.
    local function lineAtPoint(y, ch)
        if #self.lines == 0 then return nil end
        if y < TB_H or y >= ch - SB_H then return nil end
        local py = y - TB_H + self.off
        local i = lineAt(self.offs, #self.lines, py)
        local ln = self.lines[i]
        local ty = self.offs[i] + (ln.pad or 0)
        if py < ty or py >= ty + ln.th then return nil end
        return i, ln
    end

    local function linkAt(x, y, ch)
        local _, ln = lineAtPoint(y, ch)
        if not ln then return nil end
        local px = x - MARGIN
        for _, sg in ipairs(ln.segs) do
            if sg.href and px >= sg.x and px < sg.x + sg.w then return sg.href end
        end
        return nil
    end

    local function scrollTo(y, ch)
        local _, viewH = viewSize()
        local m = maxOff()
        local frac = math.min(1, math.max(0, (y - TB_H) / math.max(1, viewH)))
        self.off = math.floor(frac * m + 0.5)
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
        self.off = math.max(0, math.min(maxOff(), self.off + dir * 3 * LH))
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

        local _, viewH = viewSize()
        local m = maxOff()
        if key == keys.down then self.off = math.min(m, self.off + LH)
        elseif key == keys.up then self.off = math.max(0, self.off - LH)
        elseif key == keys.pageDown then self.off = math.min(m, self.off + viewH)
        elseif key == keys.pageUp then self.off = math.max(0, self.off - viewH)
        elseif key == keys.home then self.off = 0
        elseif key == keys["end"] then self.off = m
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
