# Ledge - working notes

Live handoff doc. Read this first.

## What this is

Edge-docked sticky notes for Hyprland, built as a standalone Quickshell app.
Inspired by holdmynotes.app on macOS. Started 2026-08-30.

## Architecture, and why

**Standalone Quickshell process, not an Omarchy plugin.** An Omarchy plugin runs
unsandboxed inside `omarchy-shell`, the same process as the bar, notifications,
polkit agent and lock screen. A notes app with a live editor and a lot of state
does not belong in there; one bad binding takes down the desktop chrome. Own
process, own systemd unit, own package.

Quickshell rather than GTK4/Rust (which is what waynote uses) for two reasons:
the animation story in QML is far better, and it is the same toolkit the rest of
the desktop is drawn in, so it looks native by construction.

```
shell/
  shell.qml        ShellRoot, Variants over screens, IPC surface
  Core/            singletons (module qs.Core)
    Theme.qml      parses the live Omarchy theme, generates note swatches
    Config.qml     ~/.config/ledge/config.json
    Store.qml      notes model + file IO
    Bus.qml        signals from CLI/IPC into the strips
  Ui/              module qs.Ui
    Edge.qml       the layer surface, input region, state machine
    Note.qml       one note in all three states (rest/peek/open)
bin/ledge          CLI wrapper over `qs ipc`
```

## Things that cost time, do not rediscover them

**Quickshell registers the config root as the `qs` module prefix.** A directory
`Core/` with `module qs.Core` in its qmldir imports as `qs.Core`. Not `ledge.Core`,
not a path-relative import. Omarchy's own shell does the same with `qs.Commons`.

**`IpcHandler` lives in `Quickshell.Io`**, not `Quickshell`.

**A `HoverHandler` parented directly to a `PanelWindow` never attaches.** It has
to go inside an Item. Cost an hour of "hover is broken" when hover was fine.

**`Region` has `regions` as its default property**, so nested `Region {}` children
work for a multi-rect input mask. Do not pass `item: null` to a Region; a null
item is not an empty region.

**Never bind a window's `visible` to a child ListView's `count`.** The child only
exists if the window is visible, so the window's visibility depends on itself.
That is why `Store.liveCount` exists as plain state.

**Do not resize the Wayland surface to animate.** The compositor will scale a
stale buffer for a frame and you get a visible stretch exactly during the open
animation. The surface is a fixed rectangle; only the input region and the
contents move. Same lesson the Omarchy notification plugin documents at
`plugins/notifications/Service.qml:965`.

**`hyprctl dispatch` is Lua-routed on this box.** Moving the cursor for testing
is `hyprctl dispatch 'hl.dsp.cursor.move({ x = 2045, y = 520 })'`. The bare
`movecursor 2045 520` form silently does nothing.

**Do not loop `grim` rapidly** to capture animation frames; it trips the desktop
screenshot toolbar and pollutes the capture.

## Design decisions worth keeping

**The tab *is* the note.** First pass had a separate card that slid out beside
the tab. Rejected: it reads as a window appearing, not a note opening. Now one
rectangle morphs through rest -> peek -> open. The paper is always the paper
colour; when collapsed the vivid band simply covers the whole note. Opening
uncovers rather than recolours, so nothing cross-fades.

**Note colours are generated, not read from the theme palette.** Reading eight
swatches by name (`red`, `green`, `magenta`...) fails badly on monochrome themes:
Osaka Jade's `bright_magenta` is `#75bbb3`, a teal, so every note came out the
same green and stopped reading as a distinct object. Now: take the accent's hue,
saturation and lightness, spread eight swatches across a ~150 degree arc centred
on it. Theme-native *and* distinguishable. Arc width is `swatchSpread`.

**Ordering lives in `order`, not in frontmatter.** A reorder rewrites one small
file instead of touching every note below it. Matters for git and file sync.

**Plain text, no markdown rendering.** Rendering forces an edit/preview mode
split, and a note you hover for half a second must not have modes. `- [ ]` is
special-cased so checkboxes work without any rendering at all.

**`hideDelay` is load-bearing.** Crossing the gap between a dash and the note it
became reads as a pointer leave. Without the grace period the note snaps shut
mid-reach. Same for the re-check inside `closeTimer`: a fast cursor can deliver
leave before enter, and without the re-check the strip latches open.

## State: what works

- Layer surface, correct anchor, click-through everywhere but the strip and the
  open note
- rest -> peek -> open morph, staggered fan-out, overshoot on open
- Live theme following, generated swatches, hot reload on `omarchy theme set`
- Notes as `.md` files with frontmatter, atomic writes, external-edit reload
- Checkbox toggling, colour cycling, pin, archive, delete-to-trash
- IPC + CLI (`new`/`add`/`list`/`open`/`rm`/`peek`/`close`)
- Config hot reload

## Next, roughly in order

1. **Drag reorder is written but untested.** The index maths in `Note.onDragMoved`
   has never been exercised with a real pointer.
2. **All Notes window** - search, filter, archive browsing. Mac parity item.
3. **Export** - markdown, plain text, single document.
4. **Reminders** - `reminder:` is already parsed and persisted in frontmatter but
   nothing fires. Wire it to an Omarchy notification.
5. **Image paste** - as an attachment chip, not `![]()` markdown syntax.
6. **Inline markdown styling** behind the `styling` flag. The approach that works
   without a mode split: a styled `Text` layer behind a transparent `TextEdit`.
   Only aligns if bold and regular share advance widths, i.e. a monospace font.
   Note that in the config docs.
7. Multi-monitor `"all"` is written but only `"focused"` has been exercised.
8. Publish: tag v0.1.0, AUR submission, marketplace listing, competition entry.

## Testing

There is no test suite yet. `./bin/ledge restart` then check
`grep -E 'WARN|ERROR' $(qs log --path shell)`. A clean load prints nothing but
the portal warning.
