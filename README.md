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

### Quick install — over the network

Once the repository is on GitHub, a single command installs everything on a
computer (CC:CE + CC-Graphics, `http.enabled = true` in the server config):

```
wget https://raw.githubusercontent.com/bigoster/oswindows/main/install.lua install.lua
install.lua
reboot
```

Or without saving a copy of the installer:

```
wget run https://raw.githubusercontent.com/bigoster/oswindows/main/install.lua
```

`install.lua` fetches every file from the repository, checks that each one
really is a compilable Lua chunk (so a truncated download or an HTML error
page is caught rather than installed), and only then puts it in place.
Re-running it upgrades an existing install in place and never touches
`/ccwin/settings.cfg`.

It downloads to a `<file>.new` temp name first because the ROM's `wget`
refuses to overwrite an existing file *and* reports success even when the
download failed — the installer verifies the bytes itself instead of trusting
the exit status.

### Manual install

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
    │   ├── dialogs.lua   (message boxes, file pickers)
    │   ├── menu.lua      (right-click context menus and submenus)
    │   ├── wm.lua        (window list, z-order, focus, drag/resize)
    │   ├── desktop.lua   (shortcuts, wallpaper, taskbar, start menu, clock)
    │   ├── backdrop.lua  (wallpaper renderers)
    │   ├── fabric.lua    (CC:CE fabric link — "Run on", incoming programs)
    │   └── programs.lua  (recognising and opening CC-Windows programs)
    ├── apps/
    │   ├── explorer.lua  (Files)
    │   ├── console.lua   (Console — hosts a real CraftOS shell)
    │   ├── editor.lua    (Notepad)
    │   ├── paint.lua     (Paint)
    │   ├── settings.lua  (Settings)
    │   └── system.lua    (System monitor)
    └── programs/
        └── fabric_agent.lua  (standalone fabric peer for other computers)
```

`startup.lua` finds `ccwin/` relative to wherever it was started from, so
launching it from a subdirectory still works.

## Features

**Desktop**

- Pixel wallpaper (Landscape / Gradient / Solid, with selectable solid colour)
- **Shortcut links**: on first boot the OS writes a `.lnk` file per installed
  program into `/desktop`, and the desktop shows them as icons — see
  [Desktop shortcuts](#desktop-shortcuts)
- Icon grid with single-click select and double-click open; icons can be
  **dragged to any position** and the new position is written back to the
  `.lnk`, so it survives a reboot
- **Right-click context menus** everywhere: on the desktop (View / Sort by /
  Refresh / New ▸ Shortcut / Personalize), on an icon (Open / Rename / Delete /
  Properties), inside Files (Open / Open in Notepad / Create link / Run on ▸
  peer / Delete) and on a window title
  bar or taskbar button (Minimise / Maximize / Close)
- Icon views: Large / Medium / Small icons (View menu), plus Sort by Name
- Taskbar with Start menu, running-window buttons and a live clock
  (12/24-hour, optional seconds)
- Light and Dark themes, applied instantly to the whole palette

**Window manager**

- Move by dragging the title bar, resize by dragging the bottom-right corner
- Minimise / maximise / close title-bar buttons, double-click title to maximise,
  right-click the title bar for the window menu
- Focus follows click, z-order raise, cascading placement
- Crashed apps are caught and shown as a crashed window instead of killing the OS

**Apps**

| App | Notes |
| --- | --- |
| **Files** | Browse the filesystem, open folders, navigate with Backspace, F5 refresh, Delete removes, Enter opens; double-click a `.lua` runs it (a CC-Windows program gets its own window, anything else runs in the Console); right-click a row for Open / Open in Notepad / Create link / Run on ▸ peer / Delete, and drag a file or folder onto a folder to move it there |
| **Console** | A real CraftOS shell in a window. The shell runs in its own coroutine against a custom terminal object; only the focused console receives events, and the global `term` redirect follows focus |
| **Notepad** | Text editor with cursor movement, Home/End, Tab, Ctrl shortcuts, save dialogs |
| **Paint** | Pencil, Line, Box, Fill, Erase, Pick (P/L/B/F/E/I); 48-colour palette; single-level undo; load/save images |
| **Settings** | Theme, wallpaper, clock format; persisted to `/ccwin/settings.cfg` |
| **System** | Computer ID, label, OS version, free/total disk space, peripheral list |

**Dialogs** — message boxes, confirmation prompts and file open/save pickers are
implemented centrally in `core/dialogs.lua`; right-click context menus live in
`core/menu.lua`.

## Desktop shortcuts

Shortcuts are real files, one per link — the CC equivalent of a Windows `.lnk`:

```
/desktop/Console.lnk      -- a small serialised table
/desktop/Notepad.lnk
```

Each file holds `{ kind, target, label, icon, x, y }`. `kind` is `"app"` when
`target` is an application id (`console`, `paint`, …) and `"file"` when it is a
path. `x, y` is the icon's pixel position, which is what makes moving icons
persist across a reboot: the folder is the source of truth, not an in-memory
list.

- **Seeding.** On first boot (guarded by `/ccwin/desktop.seeded`, deliberately
  *outside* `/desktop` so deleting every shortcut stays deleted) the OS creates
  one link per installed program, laid out column-major from the top-left.
- **New ▸ Shortcut.** Right-click the desktop → New ▸ Shortcut opens a file
  picker; choosing a file drops a link on the next free grid cell.
- **Create link from Files.** Right-click any file or folder in Files →
  Create link drops the same `.lnk` on the desktop (label and icon are worked
  out from the target), so links do not have to be made from the desktop.
- **Open.** Double-clicking a link opens its target: folders go to Files,
  `.lua` files are opened the OS way — a program written for CC-Windows gets
  its own window, anything else runs in a Console (that window runs the
  program first, then drops to a shell), `.nfp`/`.png` go to Paint,
  everything else to Notepad. A link whose
  program no longer exists is deleted when you open it.
- **Arrange / remove.** Drag an icon to move it; right-click → Rename / Delete
  (with a confirmation) / Properties, or select and press `F2` / `Delete`.
- **Views.** View ▸ Large / Medium / Small icons changes the grid cell size;
  Sort by ▸ Name re-flows the icons into column order.

## Installing programs

Copying a program in *is* the install — no lists to edit, no installer to
run:

1. Put the file in **`/ccwin/apps`** (the OS keeps this folder present), or
   drop it straight onto the desktop.
2. If its first line says so (see below), the OS links it on the desktop
   automatically — on the next Refresh or reboot as well.
3. Double-click the link, or open it from Files, and it runs.

**The header.** A program is "written for CC-Windows" when its **first
line** says so:

```lua
--- CC-Windows - Solitaire
```

Detection only ever *reads* that line: looking at a file never runs it, so
dropping scripts into `/ccwin/apps` cannot fire off code just by being
scanned.

**Opening one.** With the header, the OS loads the file in a sandbox first
(no fs writes, no timers, `print` is a no-op) purely to see whether it
returns an app table — `id`, `name`, `create`: the same contract
`ccwin/apps/*.lua` follows, covered in
[Writing programs for CC-Windows](docs/writing-apps.md):

* **It returns an app** → the file is loaded again, for real this time,
  and opened as a window with a title bar and a taskbar button. The app
  gets `opts.path` (its own path) and the full shared `ctx`.
* **No header, or no app table** → it runs in the CraftOS console exactly
  like `run <path>`, so ordinary scripts keep working untouched.

In Files, double-clicking a `.lua` runs it this way; the right-click menu
still offers **Open in Notepad** when you want to edit it instead.

**The picture on the link.** A program may also ship the picture its
desktop link shows, in either of two places — a *Pictures* file sitting
beside it (`game.nfp`, or `game.cwp`), or a block of comment lines written
into the program itself:

```lua
--- CC-Windows - Solitaire
--- icon:
--- 000f000
--- 0f00f00
--- ...
local app = {}
```

One hex digit per pixel, the same digits Paint writes as `.nfp` (colour
indices, up to 64×64). The picture is resolved by *reading* the files — the
program is never executed to find it — copied into the link, and drawn
scaled into the icon cell; a program with neither falls back to the usual
glyph icon. Links made before a program gained a picture pick it up on the
next Refresh.

**Anywhere on the filesystem.** The OS installs a `ccwin` global at boot,
so a program on a disc reaches the core apps and libraries from wherever
it lives — a copy on a drive is exactly as powerful as one in `/ccwin/apps`:

```lua
ccwin.dir                        -- "/ccwin"
ccwin.path("core/widgets.lua")   -- "/ccwin/core/widgets.lua"
ccwin.launch("editor", { path = ... })   -- open a core app
ccwin.open("/ccwin/apps/game.lua")       -- open any program the OS way
```

Console-run programs also get `arg = { [0] = path }`, and both kinds get
`shell.setRunningProgram(path)`, so `shell`-relative APIs know where the
program lives.

## Running a program on another computer (the fabric link)

On **CC:CE** with a fabric link (gold pins), CC-Windows can hand a program
to another computer and watch it run there:

* Right-click a `.lua` in Files → **Run on ▸ Computer 7**. The whole file
  travels with the message, and the status bar reports
  `Sending hello.lua to Computer 7...` and then the peer's answer,
  `Computer 7: running hello.lua`.
* The other side does not need CC-Windows: a plain CraftOS computer runs
  `/ccwin/programs/fabric_agent.lua`, which answers `hello`s, runs what it
  is sent and can push a program back the other way
  (`fabric> run 7 /ccwin/apps/hello.lua`; also `peers`, `hello`, `help`,
  `exit`). A machine that *does* run CC-Windows opens the received program
  in a console window of its own.
* The **System** app gains a *Fabric* section (link state and peer names)
  while the link is up.
* Without CC:CE — no `cee` API — every one of these quietly disappears:
  no menu entries, no System section, no errors.

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

### Writing apps

**[Writing programs for CC-Windows](docs/writing-apps.md)** is the tutorial for
adding software: console programs vs. GUI apps, the app module contract, every
callback, drawing/colour/widget/dialog APIs, timers and background events, and
a complete worked example.

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

`run5` covers the desktop shell itself: the seeded `/desktop/*.lnk` files and
their positions, the three context menus and their submenus, Escape dismissal,
delete-with-confirmation (including the labels the confirm buttons actually
render), New ▸ Shortcut end to end (including double-clicking
the new link and watching its program run), dragging an icon and finding the new
position persisted on disk, switching icon views, and inside Files: right-click
▸ Create link producing a seventh `.lnk`, then dragging a file onto a folder and
finding it really moved on disk. It then exercises the two new halves: the
fabric link (Run on → the exact message that went over the wire → the peer's
answer in the status bar, plus incoming runs including a source-only drop into
`/received`), and installing/running programs (auto-linking from
`/ccwin/apps` and loose desktop `.lua`, the picture a program ships for its
link, header detection that never executes anything,
windowed app opens, console fallback for header'd non-apps, Explorer
double-click vs Open in Notepad, a disc program reaching the core apps through
`ctx`, and the `ccwin` global).

## Licence

The bundled `cc-graphics-ref/` copy of CC-Graphics is there for API reference
only and is not part of CC-Windows. CC-Graphics and CC:Tweaked retain their own
licences.
