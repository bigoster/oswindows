# CC-Windows

A Windows-style desktop environment for **CC:CE** (CC:Tweaked + CC-Graphics), written
entirely in Lua and rendered with CC-Graphics' pixel graphics mode.

Everything — the desktop, icons, taskbar, start menu, window chrome, widgets and
app content — is drawn as pixels into the terminal's framebuffer using
`term.drawPixels()`, so you get real anti-aliased-looking UI instead of a grid of
block characters.

## Requirements

- **CC:CE** — <https://wiki.jodiserver.cc/>
- **CC-Graphics** — <https://github.com/sashafiesta/CC-Graphics> (provides
  `term.setGraphicsMode`, `term.drawPixels`, `term.setPaletteColor` on raw indices)

CC-Windows checks for the graphics API on boot and refuses to start with a clear
error if CC-Graphics is missing.

Target size is the default 51×19 character terminal (306×171 pixels), but the
layout adapts to any terminal size and to `term_resize` events.

## Install

1. Copy the `ccwin/` folder to the **root** of a computer's filesystem.
2. Copy `ccwin/startup.lua` to `/startup.lua` on the root.
3. Reboot.

```
/
├── startup.lua
└── ccwin/
    ├── main.lua
    ├── core/
    │   ├── font.lua      (generated glyph atlas — do not edit by hand)
    │   ├── gfx.lua       (framebuffer, clipping, DC drawing primitives)
    │   ├── theme.lua     (light/dark palettes, paint palette, HSV helper)
    │   ├── icons.lua     (pixel icon definitions)
    │   ├── widgets.lua   (buttons, toggles, text fields, scrollbars, ...)
    │   ├── dialogs.lua   (message boxes, file pickers, menus)
    │   ├── wm.lua        (window list, z-order, focus, drag/resize)
    │   ├── desktop.lua   (wallpaper, icons, taskbar, start menu, clock)
    │   └── backdrop.lua  (wallpaper renderers)
    └── apps/
        ├── explorer.lua  (Files)
        ├── console.lua   (Console — hosts a real CraftOS shell)
        ├── editor.lua    (Notepad)
        ├── paint.lua     (Paint)
        ├── settings.lua  (Settings)
        └── system.lua    (System monitor)
```

`startup.lua` finds `ccwin/` relative to wherever it was started from, so
launching it from a subdirectory still works.

## Features

**Desktop**

- Pixel wallpaper (Landscape / Gradient / Solid, with selectable solid colour)
- Draggable-free desktop icon grid with single-click select and double-click open
- Taskbar with Start menu, running-window buttons and a live clock
  (12/24-hour, optional seconds)
- Light and Dark themes, applied instantly to the whole palette

**Window manager**

- Move by dragging the title bar, resize by dragging the bottom-right corner
- Minimise / maximise / close title-bar buttons, double-click title to maximise
- Focus follows click, z-order raise, cascading placement
- Crashed apps are caught and shown as a crashed window instead of killing the OS

**Apps**

| App | Notes |
| --- | --- |
| **Files** | Browse the filesystem, open folders, navigate with Backspace, F5 refresh, Delete removes, Enter opens |
| **Console** | A real CraftOS shell in a window. The shell runs in its own coroutine against a custom terminal object; only the focused console receives events, and the global `term` redirect follows focus |
| **Notepad** | Text editor with cursor movement, Home/End, Tab, Ctrl shortcuts, save dialogs |
| **Paint** | Pencil, Line, Box, Fill, Erase, Pick (P/L/B/F/E/I); 48-colour palette; single-level undo; load/save images |
| **Settings** | Theme, wallpaper, clock format; persisted to `/ccwin/settings.cfg` |
| **System** | Computer ID, label, OS version, free/total disk space, peripheral list |

**Dialogs** — message boxes, confirmation prompts, file open/save pickers and
context menus are implemented centrally in `core/dialogs.lua`.

## Console specifics

The Console is the most involved piece: it hosts the unmodified
`/rom/programs/shell.lua` inside a window.

- A custom term object renders the shell's character grid into the pixel
  framebuffer; `term.blit` digits map straight onto palette indices.
- Only the **focused** console is fed mouse/key/char events. The global
  `term` redirect is re-asserted every loop iteration to follow focus, so a
  background shell can never draw over the desktop.
- `Ctrl+T` (Terminate) at the prompt restarts the shell instead of closing the
  window; other shell errors are echoed as `shell: <err>`.
- Colour calls arriving as CC colour bits (`colors.red`) are converted to
  palette indices; blit digits pass through unchanged.
- **`paintutils` graphics calls are no-ops inside the console** — a nested
  program drawing to `term` is drawing into the console's character grid, not
  the pixel framebuffer. Text output, cursor movement and palette changes all
  work normally.

## Boot & shutdown

- `startup.lua` sets `_CCWIN_RUNNING` before doing anything else. Console shells
  re-run `/rom/startup.lua` (because they have no parent shell), which would
  otherwise boot the OS a second time — the guard makes that a no-op.
- Power → Shutdown from the Start menu saves settings, restores the text
  palette, leaves graphics mode and returns to the CraftOS shell.

## Development

All files pass `luac52 -p` (Lua 5.2 syntax check). The code targets Lua 5.2 —
no `//` operator, no `table.pack`/`table.unpack` beyond what CC provides,
`bit32` is fine.

`ccwin/core/font.lua` is generated by `tools/gen_font.py` from CC:Tweaked's
`term_font.png`; edit the script, not the Lua file.

### Test harness

A headless smoke test lives outside this repository. It builds a fake CraftOS
environment (framebuffer, palette, `fs` over Windows, event pump with a virtual
clock), boots the real `ccwin/` sources in a coroutine and drives the OS with
scripted mouse/keyboard events. It asserts boot sanity, opens every app from its
desktop icon, runs a command in the console shell, switches theme, powers off
and verifies that `settings.cfg` was written and that graphics mode was left
cleanly — then reboots into the saved settings and checks they were read back.

## Licence

The bundled `cc-graphics-ref/` copy of CC-Graphics is there for API reference
only and is not part of CC-Windows. CC-Graphics and CC:Tweaked retain their own
licences.
