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

The installer can also do a smaller install:

```
install.lua            -- full: core, standard apps and extras
install.lua standard   -- core + the standard apps
install.lua core       -- the smallest bootable desktop
```

`install.lua` reads `manifest.txt`, the release's file list. Each line
carries the file's size, SHA-256 hash, download path, destination and
component. Nothing is installed before its bytes match the size and hash, and
every Lua download is compiled with `load()` (never run) first. The files
themselves come from `dist/ccwin/`, the minified release build; the readable
sources in `ccwin/` are not downloaded.

Re-running the installer is an upgrade: files whose SHA-256 already matches
are skipped, so only changed files cross the network. It records what it
installed in `/ccwin/.installed-manifest`, which lets the in-OS updater keep
the same component selection, and it never touches `/ccwin/settings.cfg`.

Downloads go to a `<file>.new` temp name first because the ROM's `wget`
refuses to overwrite an existing file *and* reports success even when the
download failed — the installer verifies the bytes itself instead of trusting
the exit status. Every temp file and the manifest copy are removed on both
success and failure, so an interrupted install leaves no residue beyond
files that were already complete.

### Building a release

The repository ships readable sources; players download a minified build.
After changing anything under `ccwin/`, rebuild and check it in:

```
lua52 tools/build.lua          # writes dist/ccwin, files.txt, manifest.txt
lua52 tools/build.lua --check  # fails when dist is stale
lua52 tools/budget.lua         # size budgets and manifest sanity
```

`tools/build.lua` minifies each Lua file with `tools/minify.lua` (comments and
whitespace only — identifiers are never renamed), copies non-Lua files byte
for byte, and refuses to build when a Lua file under `ccwin/` is missing from
its `SOURCES` list. `files.txt` stays in its old two-column form so 1.2
installs can still read it; `manifest.txt` is what current installers use.
The build fails if the full install exceeds 350 KB, core exceeds 210 KB, or
any single file exceeds 200 KB.

### Manual install

Use the built release (`dist/ccwin/`) rather than the source tree: it is
minified and about half the size.

1. Copy `dist/ccwin/` to `/ccwin/` on the computer.
2. Copy `dist/ccwin/startup.lua` to `/startup.lua` on the root.
3. Reboot.

The readable `ccwin/` sources work the same way if you prefer; only the size
differs. A manual copy does not create `/ccwin/.installed-manifest`, so the
first in-OS update treats the computer as having every component and hashes
each local file once.

```
/
├── startup.lua
└── ccwin/
    ├── main.lua
    ├── version      (the marker the in-OS updater compares with GitHub)
    ├── core/
    │   ├── font.lua      (generated glyph atlas — do not edit by hand)
    │   ├── gfx.lua       (framebuffer, clipping, DC drawing primitives)
    │   ├── loading.lua   (boot splash and progress panel)
    │   ├── theme.lua     (light/dark palettes, paint palette, HSV helper)
    │   ├── icons.lua     (pixel icon definitions)
    │   ├── widgets.lua   (buttons, toggles, text fields, scrollbars, ...)
    │   ├── dialogs.lua   (message boxes, file pickers)
    │   ├── menu.lua      (right-click context menus and submenus)
    │   ├── wm.lua        (window list, z-order, cached surfaces, damage render)
    │   ├── desktop.lua   (shortcuts, wallpaper, taskbar, clock, background cache)
    │   ├── backdrop.lua  (wallpaper renderers, picture loading)
    │   ├── picture.lua   (NFP / CWP1 / CWP2 picture codec)
    │   ├── hash.lua      (SHA-256 for verified downloads)
    │   ├── update.lua    (transactional update journal, rollback and recovery)
    │   ├── storage.lua   (atomic writes, size caps, cache/log housekeeping)
    │   ├── image.lua     (pure-Lua PNG / JPEG / WebP decoders, loaded on demand)
    │   ├── fabric.lua    (CC:CE fabric link — "Run on", incoming programs)
    │   └── programs.lua  (recognising and opening CC-Windows programs)
    ├── apps/
    │   ├── explorer.lua  (Files)
    │   ├── console.lua   (Console — hosts a real CraftOS shell)
    │   ├── editor.lua    (Notepad)
    │   ├── paint.lua     (Paint)
    │   ├── settings.lua  (Settings)
    │   ├── system.lua    (System monitor)
    │   └── browser.lua   (Browser)
    ├── images/
    │   ├── landscape.cwp (the default background, a real image file)
    │   └── gradient.cwp  (the other built-in wallpaper)
    └── programs/
        └── fabric_agent.lua  (standalone fabric peer for other computers)
```

`startup.lua` finds `ccwin/` relative to wherever it was started from, so
launching it from a subdirectory still works.

## Updating

The **System** app has an *Updates* band at the top with one button:

- **Check for updates** fetches `ccwin/version` from the repository — a
  single small download — and compares it with `/ccwin/version` on the
  computer. It reports either `Up to date - version 1.2 is installed.` or
  `Update available: <local> to <remote>`.
- **Install update** reads `manifest.txt`, keeps the components this computer
  installed (core, standard, extras, from `/ccwin/.installed-manifest`), and
  compares the release hashes with the local files. Unchanged files are
  skipped without a download; changed ones are fetched one at a time from
  `dist/ccwin/`, checked against the manifest's size and SHA-256, and Lua
  files are compiled with `load()` — never run — before being staged.

Nothing live is touched while downloads run. Verified files collect in
`/ccwin/.update/new`; only when every file has arrived are they swapped into
place as one transaction. The old files move to `/ccwin/.update/old` and a
journal is written first. Deleting that journal is the commit point: if the
computer loses power mid-swap, `startup.lua` runs `update.recover()` before
`main.lua`, restores the old files from the backup and discards the staging
tree. A failure, cancel or closing the window discards staging and leaves
the installed OS exactly as it was.

When it finishes, the updater records `/ccwin/.installed-manifest` and the
new `/ccwin/version`, then asks for a `reboot`. Everything happens in the
background (`http.request` plus `feed`), so the window stays alive while it
works. If `http` is off, the repository is unreachable, a download is corrupt
or the disk is too full, the band says exactly what went wrong.

**When you push changes to the repository:**

1. Add any new system file to `SOURCES` in `tools/build.lua` (the build fails
   if a Lua file under `ccwin/` is missing). If it is an app, also add it to
   `APP_LIST` and `DESKTOP_APPS`.
2. Run `lua52 tools/build.lua` and commit the sources together with `dist/`,
   `files.txt` and `manifest.txt`.
3. Bump the number in `ccwin/version` before publishing — that file is what
   every installed computer compares against, so nothing is offered until it
   changes.

Hand-edited system files are replaced the next time an update installs,
exactly like re-running the installer.

## Features

**Desktop**

- Pixel wallpaper (**Image** / **Solid**): *Image* opens a file chooser
  starting in `/ccwin/images`, so you can show any `.nfp` / `.cwp` picture
  **or** any `.png` / `.jpg` / `.jpeg` / `.webp` image saved on
  the computer — the photos are decoded in pure Lua and downsampled to
  the screen — the shipped **landscape** (the default background) and
  **gradient** sit there as plain image files beside your own pictures, and
  the mode only flips once a file is really picked; *Solid* fills the
  screen with any `#RRGGBB` hex colour typed into Settings. A broken or
  missing picture falls back to the landscape. **CWP2** stores a full
  306×171 wallpaper in about 8 KB with run-length compression (the
  shipped landscape is 7.6 KB instead of 102 KB), and Paint saves new
  pictures in that format; older CWP1 and NFP files still load
- **Accent colour**: the standard blue behind window bars, buttons, the
  Start menu and taskbar highlights can be changed to any `#RRGGBB` hex
  colour in Settings — the family's darker/lighter shades (hover, pressed,
  selection tints) are derived from it automatically
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
  (12/24-hour, optional seconds); the power/fabric link is sampled every
  5 seconds instead of every tick
- **Boot splash**: a themed progress panel appears as soon as graphics mode
  and the palette are ready, and steps through modules, apps, the wallpaper
  and the first desktop frame — a photo wallpaper no longer looks like a
  crashed boot while it decodes
- Light and Dark themes, applied instantly to the whole palette

**Window manager**

- Move by dragging the title bar, resize by dragging the bottom-right corner
- Minimise / maximise / close title-bar buttons, double-click title to maximise,
  right-click the title bar for the window menu
- Focus follows click, z-order raise, cascading placement
- Crashed apps are caught and shown as a crashed window instead of killing the OS
- Drag and move redraws are coalesced to one frame per 0.03 s, so a fast
  mouse cannot queue up a redraw storm; clicks, keys and releases still
  render immediately
- **Cached window surfaces + damage rendering**: each window's pixels are
  captured after it draws, so moving or resizing another window, or
  repainting the clock, does not re-run its `draw` callback. Only the
  damaged rectangle is recomposited (the taskbar tray is about 96 px),
  with a full redraw kept as the correctness fallback

**Reliability**

- **Atomic saves**: Notepad, Paint, settings and received programs write
  through `core/storage.lua` — bytes go to a `.new` sibling, are read back
  to prove they all arrived, then replace the real file and keep a `.bak`
  copy. A power cut leaves either the old file or the new one, never half
  of each
- **Safe boot**: a boot marker is written before the desktop starts and
  removed after its first frame. If the previous start was interrupted,
  the next one uses known-good defaults in memory (the user's
  `settings.cfg` is untouched) and shows a short recovery notice
- **Fault isolation**: every event, redraw, theme install and module boot
  step is guarded; a fault is logged to `/ccwin/last-error.log` (capped at
  32 KB) and the desktop keeps running
- **Validated settings**: `/ccwin/settings.cfg` is capped at 64 KB,
  unserialised safely, migrated from older wallpaper names/palette
  indices, and each key is checked against its schema; bad values are
  repaired in memory with a warning instead of crashing the boot
- **Transactional updates**: the updater stages verified bytes, writes a
  journal, swaps files and only then deletes the journal — the commit point.
  A power cut at any point rolls back to the previous files on the next boot;
  the boot recovery runs before `main.lua`
- **Storage housekeeping**: boot restores `settings.cfg` from its `.bak` if a
  power cut lost the live file, trims `/ccwin/last-error.log` to 32 KB, caps
  `/ccwin/cache` at 128 KB (oldest first) and removes stale `.new` and update
  staging files left by an interruption
- **Small install**: the minified release is **341 KB full**, **209 KB
  standard** and **140 KB core** (69 KB of standard apps, 132 KB of extras),
  down from 594 KB of readable source. CWP2 pictures, runtime picture caches
  and an on-demand PNG/JPEG/WebP decoder keep it there, with no change to the
  app contract

**Apps**

| App | Notes |
| --- | --- |
| **Files** | Browse the filesystem, open folders, navigate with Backspace, F5 refresh, Delete removes, Enter opens; double-click a `.lua` runs it (a CC-Windows program gets its own window, anything else runs in the Console); right-click a row for Open / Open in Notepad / Create link / Run on ▸ peer / Delete, and drag a file or folder onto a folder to move it there |
| **Console** | A real CraftOS shell in a window. The shell runs in its own coroutine against a custom terminal object; only the focused console receives events, and the global `term` redirect follows focus |
| **Notepad** | Text editor with cursor movement, Home/End, Tab, Ctrl shortcuts, save dialogs |
| **Paint** | Pencil, Line, Box, Fill, Erase, Pick (P/L/B/F/E/I); 48-colour palette; single-level undo; load/save images |
| **Settings** | Theme plus an **Accent** hex colour (the blue of window bars, buttons, Start menu and taskbar highlights), wallpaper (**Image** — pick any `.nfp` or `.cwp` picture (CWP1 or CWP2), or any `.png` / `.jpg` / `.jpeg` / `.webp` image, saved on the computer; the built-in images are in `/ccwin/images` — or **Solid** in any `#RRGGBB` hex colour), clock format; persisted atomically to `/ccwin/settings.cfg` |
| **System** | Computer ID, label, OS version, free/total disk space, peripheral list, plus the **OS updater**: *Check for updates* compares `/ccwin/version` with GitHub and *Install update* replaces the system files that changed |
| **Browser** | Small HTML browser: `http.request` fetches (the answer arrives via `feed`), headings, lists, tables, quotes, code and buttons lay out like a real page, only the visible lines are drawn, back/forward history, and `file://` opens folders and text files |

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
  program first, then drops to a shell), `.nfp`/`.cwp`/`.png`/`.jpg`/`.jpeg`/
  `.webp` go to Paint, everything else to Notepad. A link whose
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
- The boot splash (`core/loading.lua`) uses only `core/gfx.lua` and the
  palette, so it can draw before the rest of the OS is loaded. Its steps are
  `pcall`-guarded; if the splash itself fails, boot continues silently.
  The boot marker is still removed only after the first real desktop frame.
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
The same run checks the boot splash really painted and reached the desktop,
that a clock tick repaints only the tray without calling an app's `draw`, and
that dragging a window reuses its cached surface and carries its pixels with
it.

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

`update_test` drives the System app's OS updater on its own: version check →
manifest → delta plan → verified staging → transactional commit against the
real `manifest.txt` and `dist/` tree, plus component filtering, a corrupt
download, a manifest/version mismatch, a traversal path, low disk, HTTP 404,
http switched off, an HTML page instead of a version, the 30-second timeout,
cancelling, and simulated power cuts during commit with boot recovery.

`install_test` runs the real `install.lua` against an in-memory CraftOS
filesystem: full / standard / core selection, byte-identical installs, delta
re-runs that skip matching hashes, size / SHA-256 / compile / unsafe-path
failures, and `manifest.txt` / `files.txt` / `dist/` consistency plus the
size budgets. The built dist tree also boots under harness runs 1, 2, 4 and
5 by pointing `CCWIN_PROJ` at `dist/ccwin`, and a 22-file core-only tree
boots under the boot-only `runcore` mode.

## Licence

The bundled `cc-graphics-ref/` copy of CC-Graphics is there for API reference
only and is not part of CC-Windows. CC-Graphics and CC:Tweaked retain their own
licences.
