# Writing programs for CC-Windows

This guide covers the three ways to write software for CC-Windows:

1. **Console programs** — ordinary CraftOS Lua programs (`print`, `read`,
   `os.pullEvent`) that run inside a Console window. Everything in the
   CC:Tweaked wiki works here.
2. **GUI applications** — windowed programs with a title bar, buttons, mouse
   input and pixel drawing. These are Lua modules that CC-Windows loads at
   boot.
3. **Drop-in programs** — the same kind of GUI app (or a plain script),
   installed by copying it into `/ccwin/apps` or onto the desktop. A
   `--- CC-Windows` first line is all it takes for the OS to link it and
   open it the right way — no registration (section 19).

If you have never written a CraftOS program before, read section 1 first. If
you want a window with buttons in it, jump to [section 2](#2-your-first-gui-app).

---

## Contents

1. [Console programs](#1-console-programs)
2. [Your first GUI app](#2-your-first-gui-app)
3. [Registering an app](#3-registering-an-app)
4. [The app module](#4-the-app-module)
5. [Callbacks reference](#5-callbacks-reference)
6. [Drawing](#6-drawing)
7. [Colours and theming](#7-colours-and-theming)
8. [Widgets](#8-widgets)
9. [Icons](#9-icons)
10. [Dialogs](#10-dialogs)
11. [Timers and background events](#11-timers-and-background-events)
12. [Focus, input and the dirty flag](#12-focus-input-and-the-dirty-flag)
13. [Window geometry](#13-window-geometry)
14. [Shared state, settings and power](#14-shared-state-settings-and-power)
15. [Errors and crash handling](#15-errors-and-crash-handling)
16. [A complete example app](#16-a-complete-example-app)
17. [Checklist](#17-checklist)
18. [Gotchas](#18-gotchas)
19. [Drop-in programs](#19-drop-in-programs)

---

## 1. Console programs

Open the **Console** app from the desktop and type a program name, exactly as
you would in CraftOS. The shell searches `.` (the computer root) and
`/rom/programs`, so a file you drop at `/hello.lua` runs as `hello`.

A console is a real terminal backed by a character grid:

| Property | Value |
| --- | --- |
| Default grid | 50 columns × 15 rows |
| Cell size | 6 × 9 pixels |
| `term.getSize()` | `cols, rows` (character cells) |
| `term.getSize(true)` | `cols * 6, rows * 9` (pixels) |
| `term.getGraphicsMode()` | always `2` |
| `term.drawPixels` / `setGraphicsMode` | no-ops (your window *is* the drawing surface) |

The grid grows if you resize or maximise the window; you get a `term_resize`
event like any other program.

### Rules specific to consoles

* **Only the focused console receives input.** `key`, `char`, `paste` and
  `terminate` go to the window you are looking at.
* **Background consoles still receive everything else.** Timers (`sleep`,
  `os.startTimer`), `http_*`, `rednet`/`modem` events, `peripheral_*` and
  `cee_*` events are delivered even when the window is minimised or behind
  another window. A program that `sleep()`s in the background wakes up.
* **Output always lands in your own window**, even while your console is in
  the background — the shell claims the global `term` redirect for the
  duration of each event, then hands it back.
* **Ctrl+T** (`terminate`) ends the running program. Instead of killing the
  computer, CC-Windows starts a fresh shell prompt in the same window.
* `os.shutdown()` and `os.reboot()` are wrapped to leave graphics mode and
  save settings first, so they are safe to call.

### Lua version

CC runs **Lua 5.2**. That means `bit32`, `table.pack`, `table.unpack` and
`os.clock()` (uptime in seconds) are available, but:

* no `//` integer division — use `math.floor(a / b)`
* no `math.type`, `string.pack`, `utf8.*` (those are 5.3+)
* `//` in comments is fine, only the operator is a syntax error

---

## 2. Your first GUI app

A GUI app is a Lua file that returns a table. Save it as
`ccwin/apps/hello.lua`:

```lua
--- CC-Windows - Hello World sample app.
local app = {}

app.id = "hello"            -- unique id, also the filename
app.name = "Hello"          -- shown in the title bar and start menu
app.icon = "info"           -- an icon name from core/icons.lua
app.defaultSize = { 220, 140 }  -- pixels

function app.create(win, opts, ctx)
    local C = ctx.theme.C
    local widgets = ctx.widgets

    local self = { count = 0, rects = {} }

    local function layout(cw, ch)
        local w, h = 96, 16
        local x = math.floor((cw - w) / 2)
        return { bump = { x, ch - 48, w, h } }
    end

    function self:draw(dc, cw, ch)
        dc:fill(0, 0, cw, ch, C.face)

        local text = "You clicked " .. self.count .. " time(s)"
        dc:text(math.floor((cw - dc:textWidth(text)) / 2), 16, text, C.text)

        local r = layout(cw, ch)
        self.rects = r
        widgets.button(dc, r.bump[1], r.bump[2], r.bump[3], r.bump[4], "Click me")
    end

    function self:click(x, y, button)
        local r = self.rects
        local b = r.bump
        if button == 1 and x >= b[1] and x < b[1] + b[3]
            and y >= b[2] and y < b[2] + b[4] then
            self.count = self.count + 1
            win.dirty = true      -- ask for a redraw
        end
        return true
    end

    return self
end

return app
```

`widgets` comes from `ctx` (see [section 4](#4-the-app-module)); the full,
correct version in [section 16](#16-a-complete-example-app) uses the same
imports and is covered by an automated test.

Note the first line, `--- CC-Windows - Hello World sample app.`: it is a
plain comment to the OS's own boot loading, but it is also the marker that
makes the file recognisable as a CC-Windows program when it is copied
into `/ccwin/apps` — see [section 19](#19-drop-in-programs).

To make it appear you also have to register it — that is
[section 3](#3-registering-an-app) — or skip registration entirely and
drop it in: [section 19](#19-drop-in-programs).

---

## 3. Registering an app

Three lists control an app's life. All three must be edited.

| List | File | What it does |
| --- | --- | --- |
| `APP_LIST` | `ccwin/main.lua` (line 78) | loads the file at boot: `dofile(path("apps/" .. id .. ".lua"))` |
| `DESKTOP_APPS` | `ccwin/core/desktop.lua` (line 19) | puts an icon on the desktop and an entry in the start menu |
| installer manifest | `install.lua` | ships the file to players over `wget` |

```lua
-- ccwin/main.lua
local APP_LIST = { "console", "explorer", "editor", "paint", "settings", "system", "hello" }

-- ccwin/core/desktop.lua
local DESKTOP_APPS = { "explorer", "console", "editor", "paint", "settings", "system", "hello" }
```

```lua
-- install.lua, inside the manifest table: { source, destination }
{ "ccwin/apps/hello.lua", "/ccwin/apps/hello.lua" },
```

`APP_LIST` entries are **filenames** (minus `.lua`); the module's `app.id` is
the **key** in the apps table (`apps[app.id or id] = app`), and that is what
`DESKTOP_APPS` and `ctx.launch` refer to. Keep them identical to avoid
confusion.

Both desktop icons and the start menu iterate `DESKTOP_APPS` and silently
skip ids that have no loaded app, so a typo means "no icon, no menu entry,
no error".

---

## 4. The app module

### Module fields

| Field | Required | Meaning |
| --- | --- | --- |
| `app.id` | yes | unique id used by `ctx.launch`, `DESKTOP_APPS`, taskbar lookups |
| `app.name` | yes | title bar text, start-menu label, desktop label |
| `app.icon` | no | icon name; defaults to `"file"` |
| `app.defaultSize` | no | `{ w, h }` in pixels; defaults to 60% of the desktop |
| `app.create` | yes | constructor, see below |

### `app.create(win, opts, ctx)`

Called once per window. **Must return the instance table** (conventionally
`self`); every callback is a method on it.

* **`win`** — the window record owned by the window manager. Useful fields:

  | Field | Meaning |
  | --- | --- |
  | `win.id`, `win.appId` | identifiers |
  | `win.title` | current title (prefer `ctx.wm.setTitle`) |
  | `win.state` | `"normal"`, `"max"` or `"min"` |
  | `win.x, win.y, win.w, win.h` | window rectangle in **screen** pixels |
  | `win.content` | `{ x, y, w, h }` of the client area, screen pixels |
  | `win.dc` | draw context for the client area (the one passed to `draw`) |
  | `win.dirty` | set to `true` to request a redraw |
  | `win.dialog` | non-nil while a modal dialog is open |
  | `win.crashed` | error string if your app blew up |
  | `win.instance` | your instance table |

  `win.content` is already computed before `create` runs, so you may read it
  during construction.

* **`opts`** — whatever was passed to `ctx.launch(appId, opts)` or
  `wm.create(appId, opts)`. `wm.create` sends `opts or {}`, so it is **always
  a table** — an empty one when launched from an icon. Reading an unset key
  (`opts.path`) is therefore always safe and simply yields `nil`.

* **`ctx`** — the shared context:

  | Key | Value |
  | --- | --- |
  | `ctx.state` | shared OS state (section 14) |
  | `ctx.wm` | the window manager module |
  | `ctx.gfx` | the framebuffer module |
  | `ctx.theme` | palette + style helpers (`ctx.theme.C` is the colour table) |
  | `ctx.widgets` | reusable controls |
  | `ctx.dialogs` | modal dialogs |
  | `ctx.icons` | 8×8 icon drawing |
  | `ctx.apps` | table of all loaded app modules, keyed by id |
  | `ctx.menu` | right-click context menus (section 10) |
  | `ctx.shortcuts.create(spec)` | drop a shortcut on the desktop (see below) |
  | `ctx.launch(appId, opts)` | open a window for another app |

Cross-app example, from `explorer.lua`:

```lua
ctx.launch("editor", { path = item.path })
```

`ctx.shortcuts.create` is how an app adds a link to the desktop without
knowing anything about `/desktop`:

```lua
local e = ctx.shortcuts.create { kind = "file", target = item.path }
-- e.file, e.label, e.icon, e.x, e.y; label/icon are derived when omitted
-- kind = "app" for a program id, "file" for a path
```

---

## 5. Callbacks reference

Every callback is optional. `x, y` are always **client-relative pixels**
(0,0 = top-left of the client area), never screen coordinates.

| Callback | Arguments | Delivered to | Notes |
| --- | --- | --- | --- |
| `draw` | `dc, cw, ch` | focused + background | called on every render; `cw, ch` = client size |
| `resize` | `w, h` | that window | client size changed (resize, maximize, `term_resize`) |
| `click` | `x, y, button, double` | the window under the mouse, after focus | `button`: 1 left, 2 right, 3 middle |
| `up` | `x, y, button` | the **focused** window | mouse button released |
| `drag` | `x, y, button` | the **focused** window | only fires while a button is held (CC emits `mouse_drag` only then) |
| `scroll` | `x, y, dir` | the window under the mouse, after focus | `dir` is `1` or `-1` |
| `key` | `key` | the **focused** window | `keys.*` constants |
| `key_up` | `key` | the **focused** window | use it to track Ctrl/Shift yourself |
| `char` | `ch` | the **focused** window | printable characters; `paste` is expanded into `char` calls for you |
| `timer` | `id` | **every** window | compare `id` against your own timer ids |
| `feed` | `ev` | **every** window | raw broadcast event; `ev[1]` is the name, payload starts at `ev[2]` |
| `close` | — | that window | called before removal; cancel your timers here |

Return values are ignored by the window manager, so returning `true` is a
convention for "I handled it", not a requirement.

### The `self.dirty` shortcut

After changing anything visible, set `win.dirty = true` **or**
`self.dirty = true`. Both work: `wm.call` checks either one after every
callback and forwards it to the shell's render pass.

You never call `wm.render()` yourself.

---

## 6. Drawing

You draw inside `draw(dc, cw, ch)` with the **draw context** `dc`. A DC
translates client-relative coordinates into screen pixels and clips to your
client area, so you cannot paint over the title bar, the taskbar or another
window.

### DC methods

```lua
dc:fill(x, y, w, h, colour)      -- solid rectangle
dc:rect(x, y, w, h, colour)      -- 1px outline
dc:hline(x, y, w, colour)
dc:vline(x, y, h, colour)
dc:line(x0, y0, x1, y1, colour)  -- Bresenham
dc:pixel(x, y, colour)
dc:getPixel(x, y)                -- reads the back buffer, or nil if off-screen
dc:text(x, y, str, fg, bg, scale) -- bg may be nil (transparent); returns width
dc:textWidth(str, scale)         -- width in pixels
dc:blit(x, y, rowBytes)          -- splice raw palette bytes into one row
dc:pushClip(x, y, w, h)          -- nested clip, client-relative
dc:popClip()
```

The global `gfx` module has the same primitives plus `gfx.size()`,
`gfx.setRow(y, str)` and `gfx.getPixel` in **screen** coordinates. Prefer
`dc:` inside an app.

### Text metrics

The embedded font is **6 × 9 pixels** per character:

* one character advances 6 px, so `dc:textWidth("abc")` is `18`
* `scale` multiplies both dimensions (`scale = 2` → 12 × 18)
* unknown code points render as a 6×9 open box, never an error

Clip scrolling content yourself:

```lua
dc:pushClip(4, 20, cw - 8, ch - 40)
-- ... draw rows that may run past the edge ...
dc:popClip()
```

---

## 7. Colours and theming

**Never pass `colors.red` to a drawing call.** Drawing functions take a
*palette index* — a plain number.

Two ranges exist:

* **0–15** — the classic ComputerCraft colours, in blit-digit order:
  `0` white, `1` orange, … `14` red, `15` black. Index = `log2(colors.X bit)`.
  Handy for the odd CC-coloured detail, but they do not change with the theme.
* **16–143** — CC-Windows' own slots, named in `theme.C` and re-bound when
  the user switches Light/Dark. **Use these.**

```lua
local C = ctx.theme.C   -- capture once in app.create
```

| Group | Names |
| --- | --- |
| chrome | `face`, `faceHover`, `faceDown`, `bevelLight`, `bevelMid`, `bevelDark`, `bevelShadow`, `shadow` |
| text | `text`, `textMuted`, `white`, `black` |
| accent | `accent`, `accentDark`, `accentLight`, `accentFaint`, `titleInactive` |
| feedback | `danger`, `dangerDark`, `success`, `warning` |
| controls | `fieldBg`, `hover`, `listAlt`, `track`, `thumb`, `thumbHover`, `taskbar`, `taskbarHover` |

Because drawing code only ever refers to a colour **by name**, an app written
against `C.face` automatically looks right in both themes. That is the whole
point of the indirection — resist hard-coding `18`.

### Style helpers on `theme`

```lua
theme.raise(dc, x, y, w, h)        -- outset bevel
theme.sunken(dc, x, y, w, h)       -- inset bevel
theme.button(dc, x, y, w, h, state) -- state: nil | "hover" | "down" | "disabled"
theme.buttonLabel(dc, x, y, w, h, label, colour, scale)
theme.field(dc, x, y, w, h, focused)
theme.panel(dc, x, y, w, h)
theme.band(dc, x, y, w, h, text)    -- toolbar / status strip
theme.scrollbarV(dc, x, y, w, h, fracStart, fracLen, hot)
theme.scrollbarH(dc, x, y, w, h, fracStart, fracLen, hot)
```

---

## 8. Widgets

`ctx.widgets` provides the shared controls. They all take a DC first.

```lua
-- button; opts.state is usually "hover" or nil, driven by your own hover tracking
widgets.button(dc, x, y, w, h, label, { state = "hover", icon = "folder", iconScale = 1 })
widgets.iconButton(dc, x, y, size, "trash")

-- text
widgets.label(dc, x, y, text, colour, scale)
widgets.centeredLabel(dc, x, y, w, h, text, colour, scale)
widgets.ellipsis(str, maxWidth, scale)   -- "very long ti..." ; maxWidth in px
widgets.pad(s, n) / widgets.padLeft(s, n)

-- lists
widgets.listRow(dc, x, y, w, h, state)   -- state: nil | "hover" | "selected"
widgets.scrollV(dc, x, y, w, h, offset, total, visible, hot)
widgets.scrollH(dc, x, y, w, h, offset, total, visible, hot)
widgets.scrollWheel(offset, total, visible, delta, step)  -- clamped new offset
widgets.rowAt(y, originY, rowH, count)   -- row index under a y, or nil

-- dropdown / context menu (row height is fixed at 13px)
local h = widgets.menu(dc, x, y, w, items, selected, maxHeight)
local i = widgets.menuIndex(x, y, menuX, menuY, w, #items, maxHeight)

-- checkbox
widgets.checkbox(dc, x, y, checked, label, hot)

-- single-line text field
local field = widgets.newField("initial text")   -- { text, caret, scroll }
widgets.fieldDraw(dc, x, y, w, h, field, focused, showCaret)
if widgets.fieldKey(field, key) then ... end     -- returns true if consumed
widgets.fieldChar(field, ch)

-- misc
widgets.inside(x, y, rx, ry, rw, rh)  -- point-in-rect
widgets.formatBytes(n)                -- "1.4 KB"
```

`field` usage pattern (from the dialogs module):

```lua
function self:key(key)
    if widgets.fieldKey(self.field, key) then
        win.dirty = true
        return true
    end
    -- ... other keys
end

function self:char(ch)
    widgets.fieldChar(self.field, ch)
    win.dirty = true
    return true
end
```

---

## 9. Icons

Icons are 8×8 bitmaps drawn with `ctx.icons.draw`.

```lua
ctx.icons.draw(dc, "folder", x, y, 1)   -- 8×8
ctx.icons.draw(dc, "folder", x, y, 2)   -- 16×16, used for desktop icons
ctx.icons.exists("folder")              -- true
```

Built-in names:

| name | used by |
| --- | --- |
| `computer`, `folder`, `terminal`, `editor`, `paint`, `settings`, `system` | the shipped apps |
| `file` | default `app.icon` |
| `power`, `info`, `trash` | dialogs and chrome |

### Adding your own icon

Append a `def(...)` in `ccwin/core/icons.lua` (the local `def` is in scope
throughout the file):

```lua
def("hello", { ["1"] = 75, ["2"] = 69 }, {
    "11111111",
    "1......1",
    "1.1111.1",
    "1......1",
    "1.1111.1",
    "1......1",
    "1......1",
    "11111111",
})
```

Each row is 8 characters. `.` is transparent; every other character is a key
into that icon's colour map, whose values are palette indices (75 = yellow,
69 = blue here). Then set `app.icon = "hello"`.

---

## 10. Dialogs

Modals belong to a window: they draw over its client area and swallow input
until dismissed. While `win.dialog` is set, `wm` routes `click`, `key`,
`char` and `scroll` to the dialog instead of your callbacks — your callbacks
resume when it closes.

```lua
ctx.dialogs.open(win, { type = "...", ... })
ctx.dialogs.close(win)          -- usually unnecessary; callbacks close it for you
```

### `type = "confirm"`

```lua
dialogs.open(win, {
    type = "confirm",
    title = "Notepad",
    message = "Save changes to untitled.txt ?",   -- "\n" splits lines
    buttons = { "Save", "Don't save", "Cancel" }, -- first button is primary
    onResult = function(i) ... end,               -- 1-based button index
})
```

### `type = "prompt"`

```lua
dialogs.open(win, {
    type = "prompt",
    title = "Save as",
    label = "File name:",
    initial = "/untitled.txt",
    caret = true,                        -- set false to hide the caret
    onSubmit = function(text) ... end,   -- OK or Enter
    onCancel = function() ... end,       -- Cancel or Escape
})
```

### `type = "file"`

```lua
dialogs.open(win, {
    type = "file",
    title = "Open file",
    path = (state.settings.lastPath) or "/",
    filter = function(path)              -- return false to hide a file
        return fs.isDir(path) or not path:match("%.png$")
    end,
    onPick = function(path) ... end,     -- double-click or Open
    onCancel = function() ... end,
})
```

Double-clicking a directory navigates into it; the `..` row goes up.

### Context menus

Right-click menus are a separate module, `core/menu.lua`, reached through
`ctx.menu`. One menu is open at a time; it is drawn above windows, dialogs and
the taskbar, and it owns the mouse until it is dismissed — clicking an item
runs it, clicking anywhere else just closes the menu and **swallows** the click,
so nothing underneath reacts to it.

```lua
ctx.menu.open {
    x = x, y = y,                   -- screen pixels, clamped on screen
    items = {
        { label = "Cut",    onPick = function() ... end },
        { label = "Paste",  disabled = not canPaste,
          onPick = function() ... end },
        { sep = true },
        { label = "View", submenu = {           -- opens on click, not hover
            { label = "Large",  checked = (mode == "large"),
              onPick = function() ... end },
            { label = "Small",  checked = (mode == "small"),
              onPick = function() ... end },
        } },
    },
}
```

Item fields: `label`, `onPick`, `disabled`, `checked` (draws a checkmark; set it
to `false` to reserve the column without ticking), `icon`, `sep`, and `submenu`
(a nested `items` list, one level deep).

`ctx.menu.isOpen()`, `ctx.menu.close()` and `ctx.menu.current()` are available
too. Menus dismiss themselves on `Escape`; `menu.key`/`menu.click` return
`true` when they consumed the event.

CC has **no mouse-move event** (only `mouse_drag`, while a button is held), so
submenus open on click rather than on hover — this is a platform limit, not an
oversight.

The shell already uses this for the desktop, icons and window title bars. To
add a right-click menu *inside your app*, handle `button == 2` in your `click`
callback and call `ctx.menu.open` with screen coordinates (`win.x + cx`,
`win.y + cy`).

---

## 11. Timers and background events

This is the part people get wrong. The OS has **one** event loop; your app is
a set of callbacks invoked from it. You must never block inside one.

### Never do this in a callback

```lua
function self:click(x, y)
    sleep(1)            -- FREEZES THE ENTIRE DESKTOP
    read()              -- and so does this
    os.pullEvent("foo") -- you are already inside the event loop
end
```

### Timers: do this instead

`timer` is delivered to **every** window, focused or not, with the raw timer
id. Always compare ids — otherwise you will consume someone else's timer.

```lua
-- in app.create
self.tickTimer = os.startTimer(1)

function self:timer(id)
    if id == self.tickTimer then
        self.tickTimer = os.startTimer(1)   -- re-arm
        win.dirty = true                    -- redraw the clock
    end
end

function self:close()
    if self.tickTimer then pcall(os.cancelTimer, self.tickTimer) end
end
```

Forgetting to re-arm gives you a single fire; forgetting `close()` leaks a
timer that keeps waking a dead window.

### Background events: `feed`

`wm.broadcast(ev)` calls `feed(ev)` on **every** window before the event is
handed to the focused window. Use it for events that are not input:

```lua
function self:feed(ev)
    local name = ev[1]
    if name == "http_success" then
        local url, body = ev[2], ev[3]
        -- ...
        win.dirty = true
    elseif name == "peripheral" or name == "peripheral_detach" then
        win.dirty = true
    end
end
```

**`feed` sees input events too.** The main loop does
`wm.broadcast(ev)` *then* `wm.handle(ev)`, so if your `feed` handles `char`
and you also implement `self:char`, the character is processed twice. Ignore
the input set in `feed` exactly as the console does:

```lua
function self:feed(ev)
    local name = ev[1]
    if name == "mouse_click" or name == "mouse_up" or name == "mouse_drag"
        or name == "mouse_scroll" or name == "key" or name == "char"
        or name == "key_up" or name == "paste" or name == "term_resize"
        or name == "timer" then
        return -- wm routes these to the right callback already
    end
    -- ... your background events ...
end
```

Event payload offsets: `ev[1]` is the name, `ev[2]` onward are the event's
parameters, exactly as `os.pullEvent` returns them.

### Worked example: a background HTTP fetch

```lua
self.url = "https://example.com/api"
http.get(self.url)   -- fire and forget; the result arrives via feed

function self:feed(ev)
    if ev[1] == "http_success" and ev[2] == self.url then
        self.body = ev[3]
        self.status = "loaded"
        win.dirty = true
    elseif ev[1] == "http_failure" and ev[2] == self.url then
        self.status = "failed: " .. tostring(ev[3])
        win.dirty = true
    end
end
```

---

## 12. Focus, input and the dirty flag

### Who gets what

| Event | Routed to |
| --- | --- |
| `mouse_click`, `mouse_scroll` | an open menu first, then a modal dialog, then the taskbar, then the window under the cursor (after focusing it) |
| `mouse_up`, `mouse_drag` | an in-progress window move/resize, then an icon drag, then the focused window |
| `key`, `char` | an open menu first, then a modal dialog (desktop or window), then the focused window — and to the desktop itself when nothing is focused |
| `key_up`, `paste` | the focused window (an open menu swallows them) |
| `term_resize` | handled by `wm` (relayout + `resize` on each window) |
| `timer` | every window with a `timer` method |
| everything else | every window with a `feed` method |
| — | a modal dialog intercepts click/key/char/scroll for its own window, or for the whole desktop when the shell owns it |

Consequences you can rely on:

* a `click` you receive is always inside your client area
* you are the only window seeing a given `char`
* you must still check *where* inside your client area a click landed
* while a context menu is open you receive nothing at all — it owns the mouse

### The dirty flag

The shell renders only when `wm.dirty` is set, and clears it after a full
frame. Your callbacks contribute like this:

```
your callback sets win.dirty / self.dirty
        ↓
wm.call() notices it and sets wm.dirty
        ↓
main loop calls wm.render() once the event is consumed
```

So: **mutate state → set dirty → return.** Setting dirty with nothing
changed just costs one redraw; forgetting it means the screen never updates
and is the single most common bug in a new app.

### Hover

CC only emits `mouse_drag` while a button is held, so "hover" callbacks fire
only during a drag. The shipped apps track hover in `drag` and repaint when
it changes; for a tooltip-free UI you can simply ignore hover and style
buttons on `click`.

---

## 13. Window geometry

All in pixels, all from `ccwin/core/wm.lua`:

```lua
wm.TITLE_H    -- 13   title bar height
wm.BORDER     -- 1    frame border
wm.TASKBAR_H  -- 17   taskbar height
-- MIN_W, MIN_H = 96, 46 (local to wm.lua)
-- BTN_W = 16  (title bar buttons)
```

* **Screen** size: `ctx.gfx.size()` → `W, H`. A standard computer gives
  51 × 19 cells × 6 × 9 px = **306 × 171**.
* **Desktop area** (where windows live): `0, 0, W, H - wm.TASKBAR_H` —
  306 × 154 on the default screen.
* **Client area** of a window:
  `w - 2 * wm.BORDER` wide, `h - wm.TITLE_H - 2 * wm.BORDER` tall.
  For a maximized window on the default screen that is 304 × 139 →
  **50 × 15** character cells at 6 × 9.

Layout rules worth knowing:

* `app.defaultSize` is clamped to the desktop area and to the 96×46 minimum
* new windows cascade from (18, 12) in 14 px steps, six deep
* maximized windows remember their previous rectangle in `win.prev`
* resizing and maximizing both emit `resize(w, h)` — recompute your layout
  there rather than caching sizes at construction time

A defensive helper used by the shipped apps:

```lua
local function dc_size(win)
    if win.content then return win.content.w, win.content.h end
    return 1, 1
end
```

---

## 14. Shared state, settings and power

`ctx.state`:

| Field | Meaning |
| --- | --- |
| `state.tick` | increments ~4×/second (the shell's 0.25 s timer) |
| `state.pointer` | `{ x, y }` last known mouse position, screen pixels |
| `state.lastClick` | `{ x, y, tick }` used for double-click detection |
| `state.settings` | the persisted settings table |
| `state.save()` | write settings to `/ccwin/settings.cfg` |
| `state.applySettings()` | re-install the theme and rebuild the desktop |
| `state.onPower(action)` | `action` = `"shutdown"` or `"restart"`; saves settings and leaves graphics mode |

Settings keys (see `ccwin/main.lua` `DEFAULTS`):

```lua
state.settings.theme        -- "light" | "dark"
state.settings.wallpaper    -- wallpaper id used by core/backdrop.lua
state.settings.clockSeconds -- show seconds in the taskbar clock
state.settings.lastPath     -- last folder used by file dialogs
```

Mutate and then call `state.save()` — nothing is written automatically except
on shutdown. Call `state.applySettings()` after changing `theme` or
`wallpaper`.

```lua
-- in a Settings-style app
state.settings.theme = "dark"
state.save()
state.applySettings()
```

Use `state.onPower("shutdown")` rather than calling `os.shutdown()` from a
GUI app; both are safe, but the former is the intended path.

---

## 15. Errors and crash handling

Every callback goes through `wm.call`, which `pcall`s it:

```lua
local ok, err = pcall(fn, win.instance, ...)
if not ok then wm.crash(win, err) end
```

On failure your window is replaced by a crash panel — *"This program has
stopped."* plus the error text and a Close button — and **the rest of the
desktop keeps running**. The same happens if `app.create` itself throws.

Practical implications:

* an error is survivable, but your window is dead; the user must close it
* keep callbacks fast and non-blocking (no `sleep`, no `read`)
* wrap risky I/O so a missing file does not kill the window:

  ```lua
  local ok, err = pcall(fs.readAll, path)
  if not ok then self.status = tostring(err); win.dirty = true end
  ```
* `close` is called inside `pcall` too, so a throwing `close` will not
  prevent the window from being removed — but cancel timers first anyway

---

## 16. A complete example app

Save as `ccwin/apps/hello.lua`, then apply the three edits from
[section 3](#3-registering-an-app).

```lua
--- CC-Windows - Hello: a complete, runnable sample application.
--
-- Demonstrates: layout, buttons with hover, a self-rearming timer,
-- a modal prompt, a status band and correct cleanup.
local app = {}

app.id = "hello"
app.name = "Hello"
app.icon = "info"
app.defaultSize = { 220, 140 }

function app.create(win, opts, ctx)
    local theme, widgets, dialogs = ctx.theme, ctx.widgets, ctx.dialogs
    local C = theme.C

    local self = {
        count = 0,
        hover = nil,
        rects = {},
        clock = nil,
        note = "",
    }

    -- One layout function shared by draw and click, so they can never
    -- disagree about where a button is.
    local function layout(cw, ch)
        local w, h = 96, 16
        local x = math.floor((cw - w) / 2)
        return {
            bump = { x, ch - 48, w, h },
            ask = { x, ch - 28, w, h },
        }
    end

    local function hot(x, y, r)
        return r and x >= r[1] and x < r[1] + r[3]
            and y >= r[2] and y < r[2] + r[4]
    end

    -------------------------------------------------------------------
    -- drawing
    -------------------------------------------------------------------

    function self:draw(dc, cw, ch)
        dc:fill(0, 0, cw, ch, C.face)

        local text = "You clicked " .. self.count .. " time(s)"
        dc:text(math.floor((cw - dc:textWidth(text)) / 2), 14, text, C.text)

        if self.note ~= "" then
            local note = widgets.ellipsis(self.note, cw - 12)
            dc:text(math.floor((cw - dc:textWidth(note)) / 2), 34, note, C.textMuted)
        end

        local r = layout(cw, ch)
        self.rects = r

        widgets.button(dc, r.bump[1], r.bump[2], r.bump[3], r.bump[4], "Click me",
            { state = self.hover == "bump" and "hover" or nil })
        widgets.button(dc, r.ask[1], r.ask[2], r.ask[3], r.ask[4], "Say hello...",
            { state = self.hover == "ask" and "hover" or nil })

        -- Status band driven by our own timer: proof the window repaints
        -- itself without user input.
        theme.band(dc, 0, ch - 14, cw, 14, os.date("%H:%M:%S"))
    end

    -------------------------------------------------------------------
    -- input
    -------------------------------------------------------------------

    function self:click(x, y, button)
        if button ~= 1 then return true end
        local cw, ch = win.content.w, win.content.h
        local r = layout(cw, ch)

        if hot(x, y, r.bump) then
            self.count = self.count + 1
            self.note = ""
            win.dirty = true
        elseif hot(x, y, r.ask) then
            dialogs.open(win, {
                type = "prompt",
                title = "Hello",
                label = "What is your name?",
                initial = "Steve",
                onSubmit = function(text)
                    self.count = 0
                    self.note = "Hello, " .. tostring(text) .. "!"
                    ctx.wm.setTitle(win, (text ~= "" and text or "Hello") .. " - Hello")
                    win.dirty = true
                end,
                onCancel = function()
                    self.note = "Cancelled"
                    win.dirty = true
                end,
            })
        end
        return true
    end

    function self:drag(x, y)
        local cw, ch = win.content.w, win.content.h
        local r = self.rects
        local hov = nil
        if hot(x, y, r.bump) then hov = "bump"
        elseif hot(x, y, r.ask) then hov = "ask" end
        if hov ~= self.hover then
            self.hover = hov
            win.dirty = true
        end
        return hov ~= nil
    end

    function self:scroll(x, y, dir)
        self.count = math.max(0, self.count + dir)
        win.dirty = true
        return true
    end

    -------------------------------------------------------------------
    -- timers: delivered to every window, so match your own id
    -------------------------------------------------------------------

    self.clock = os.startTimer(1)

    function self:timer(id)
        if id == self.clock then
            self.clock = os.startTimer(1)   -- re-arm
            win.dirty = true                -- repaint the status band
        end
    end

    -------------------------------------------------------------------
    -- cleanup
    -------------------------------------------------------------------

    function self:close()
        if self.clock then pcall(os.cancelTimer, self.clock) end
    end

    if opts and opts.count then self.count = opts.count end
    return self
end

return app
```

Launch it from anywhere with a window:

```lua
ctx.launch("hello", { count = 5 })
```

---

## 17. Checklist

- [ ] File is `ccwin/apps/<id>.lua` and ends with `return app`
- [ ] `app.id`, `app.name` set; `app.icon` names a real icon
- [ ] `app.defaultSize` chosen (pixels, will be clamped to the desktop)
- [ ] `app.create(win, opts, ctx)` **returns** the instance table
- [ ] added to `APP_LIST` in `ccwin/main.lua`
- [ ] added to `DESKTOP_APPS` in `ccwin/core/desktop.lua`
- [ ] added to the manifest in `install.lua`
- [ ] or, for a drop-in install: first line is `--- CC-Windows - ...` (omit
      it on purpose to stay a console program) and the top level only
      defines and returns the app — no `sleep`, `peripheral` or fs writes
      there (they run in the sandbox during detection)
- [ ] colours come from `ctx.theme.C`, never `colors.*`
- [ ] every state change sets `win.dirty = true`
- [ ] timers are matched by id and cancelled in `close()`
- [ ] `feed` ignores input events (no double handling)
- [ ] no `sleep` / `read` / `os.pullEvent` inside a callback
- [ ] `resize` recomputes layout instead of trusting construction-time sizes
- [ ] passes `luac52 -p` (Lua 5.2 syntax — no `//`)

---

## 18. Gotchas

**`colors.*` will not work in `dc:fill`.** They are bit flags
(`colors.red == 0x4000`); drawing wants a palette index. Use `theme.C`.

**Do not call `term.*` from a GUI app.** The global `term` redirect points at
the focused console or at the native terminal, either way it draws outside
your window — over the desktop, in the worst case. Use `dc`.

**Do not block.** `sleep`, `read`, `os.pullEvent` and `parallel.waitForAny`
inside a callback freeze the whole shell, because you *are* the shell's event
loop at that moment. Convert the logic into state plus a timer.

**Forgetting `win.dirty` looks like a hang.** The code ran, the model is
correct, the pixels are stale.

**`timer` fires for every window.** Always compare against your own id, or
you will steal the console's blink timer and your app will re-arm forever.

**`feed` fires for every window, including yours, for input events too.**
`wm.broadcast` runs before `wm.handle`, so handling `char` in both places
duplicates the character.

**`drag` only happens with a button held.** CC does not emit a plain
mouse-move event, so there is no true hover without pressing a button.

**A crash kills only your window.** You get a crash panel with the message;
close it and carry on. Test by deliberately throwing in a callback.

**`opts` is always a table, but its keys are `nil` on icon launches.**
`wm.create` passes `opts or {}`, so `opts` itself never needs guarding —
but `opts.path` is `nil` unless somebody launched you with it:

```lua
local path = opts and opts.path   -- or simply opts.path
if path then loadFile(path) end
```

**Registration is three lists, not one.** A file that is in `APP_LIST` but
missing from `DESKTOP_APPS` runs but has no icon or start-menu entry; missing
from `install.lua` it never reaches players.

**Lua 5.2.** `//` is a syntax error. Use `math.floor(a / b)`.

---

## 19. Drop-in programs

Registering an app (section 3) is how software ships *with* the OS. To
**install** something, you do not register anything: copy the file into
**`/ccwin/apps`** (the OS keeps that folder present), or drop it straight
onto the desktop, and the OS takes it from there.

### The one-line contract

A program is "written for CC-Windows" when its **first line** says so:

```lua
--- CC-Windows - Solitaire
local app = {}
app.id = "solitaire"
app.name = "Solitaire"
-- ...
return app
```

Finding that out reads exactly one line of text — a file is never
executed just by being scanned, so scripts lying in `/ccwin/apps` cannot
fire off code until somebody actually opens them.

### What the OS does with it

* **Auto desktop link.** On boot and on every Refresh, `/ccwin/apps` and
  any loose `.lua` sitting on the desktop are scanned; each header'd file
  gets a `kind = "file"` shortcut (icon `terminal`, label = file name
  minus `.lua`). A program that already has a link is skipped, so the scan
  is cheap enough to run every time. The OS's own apps live in that folder
  too — they are skipped, since each already has a link of its own keyed by
  its app id.
* **Opening it the right way.** A desktop link, a double-click in Files
  and `ccwin.open(path)` all make the same decision:
  1. The header is there, so the file is loaded in a **sandbox** — no fs
     writes, no timers, `print`/`write` are no-ops, no `load`, `dofile`,
     `shell`, `term` or `peripheral`, and `ccwin` exposes only `dir` and
     `path` — purely to see whether it **returns an app table** (`id`,
     `name`, `create`; sections 4 and 5).
  2. **It does** → the file is loaded a second time, for real, with the
     full environment the OS's own programs get, and that app opens as a
     window. `opts.path` is the program's path, and `ctx` arrives as
     usual in `create`.
  3. **It does not** (no header, or the top level returns nothing) → it
     runs in a CraftOS console like `run <path>` — ordinary scripts keep
     working untouched.

  The sandboxed probe means the *decision* never causes side effects, and
  the real run happens exactly once either way.

### The picture your link shows

A desktop link draws a glyph icon by default. A program can ship its own
picture instead — drawn scaled into the icon cell — in either of two
places.

**Beside the program**, named after it: `solitaire.lua` looks for
`solitaire.nfp` (the format Paint writes for a `.nfp` name) and then
`solitaire.cwp` (Paint's own `CCWIN1` format) in the same folder.

**Inside the program**, as a run of comment lines:

```lua
--- CC-Windows - Solitaire
--- icon:
--- 000f000
--- 0f00f00
--- 000f000
local app = {}
```

A comment line reading `icon:` opens the block; every following comment
line made of hex digits is one picture row, and the block ends at the
first line that is not — so the file stays ordinary Lua either way.

Either way it is the NFP picture: up to 64×64, one hex digit per pixel,
that digit being the palette index (`0` white … `f` black). Finding the
picture only ever *reads* text — the program is never executed for it.

The rows are copied into the link (`.lnk`) when the link is made and drawn
scaled into the icon box (aspect kept, centred) on every frame, so the link
keeps its picture even if the program is edited later. Links made before a
program gained a picture pick it up on the next Refresh, and a program with
no picture anywhere keeps the usual glyph icon.

### Rules for the top level

* **Keep the top level pure enough to `return app`.** During the probe it
  runs in the sandbox: calling `sleep`, `peripheral.*` or `fs.write` there
  raises an error, the file is treated as an ordinary program, and it gets
  a console window instead of its own. Real work belongs in `create` and
  the callbacks.
* **No header means console.** If you *want* a console program, simply
  leave the first line off — nothing changes for plain scripts.
* Detection matches `^%-%-+%s*CC%-Windows`, so `--- CC-Windows - Name`,
  `----CC-Windows` and `-- CC-Windows` all count.

### Opening it yourself

```lua
ccwin.open("/ccwin/apps/solitaire.lua")   -- the OS way (window or console)
ccwin.open("/disk/games/solitaire.lua")   -- same decision, any drive
ccwin.launch("editor", { path = ... })    -- a registered core app by id
```

Explorer's right-click menu for a `.lua` reads
**Open / Open in Notepad / Create link / Run on ▸ peer / Delete** —
double-click runs it, the second entry opens the editor.

### From a disc, in a window, with everything

Nothing about `/ccwin/apps` is special except that it is scanned for links.
A header'd app opened from `/disk/...` gets the real environment and the
shared context, so it reaches the core apps and libraries exactly like one
installed on the main drive:

```lua
-- top level (real environment: full fs, dofile, ccwin, ...)
local widgets = dofile(ccwin.path("core/widgets.lua"))

function app.create(win, opts, ctx)
    -- opts.path == "/disk/games/solitaire.lua" (where I live)
    ctx.launch("editor", { path = opts.path })  -- open a core app
end
```

Console-run programs get `arg = { [0] = path }` on top of that, and both
kinds get `shell.setRunningProgram(path)` so shell-relative APIs know
where the program lives.

---

## See also

* `README.md` — install, features, boot and shutdown
* `ccwin/apps/editor.lua` — the best real-world reference: toolbar, file
  dialogs, scrolling, status bar, Ctrl shortcuts
* `ccwin/apps/console.lua` — redirect targets, background event delivery
* `ccwin/core/wm.lua` — the callback dispatch you are plugging into
* [CC:Tweaked API docs](https://tweaked.cc/) — `fs`, `http`, `os`, `keys`,
  `textutils`, `parallel`
* [CC-Graphics](https://github.com/sashafiesta/CC-Graphics) — the graphics
  mode 2 terminal this shell draws into
