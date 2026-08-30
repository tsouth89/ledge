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

**Never reorder the model during a drag.** With a `Repeater`, moving model data
does not move the delegate; the delegate at index i simply rebinds to whatever
data now sits at i. So a live reorder leaves the pointer grab attached to a
delegate that is now a *different note*, and the rest of the drag moves the
wrong one. Drags move pixels only (`column.dragDy` plus a per-slot `dragShift`
for the neighbours); the model is touched once, on drop.

**Drag maths runs over visible indices, not model indices.** An archived note is
still a row in the model but has zero height on screen, so raw indices and
on-screen positions diverge the moment anything is archived.

**Never bind an editor's `text` to model data on a recycled delegate.** Delegates
get rebound when the model reorders or a row is removed. With `text: note.body`
the editor's contents and the note it thinks it is editing update in the *same
batch*, so a guard written as another binding (`property string boundId:
note.noteId`) is worthless -- both sides change together and stale text gets
written to the new note's id. This actually corrupted a note, concatenating one
note's keystrokes onto another's body. The load is now explicit, one-way, and
suppressed during the sync. Do not "simplify" it back into a binding.

**Popped-out notes are toplevel windows, not layer surfaces.** This was tried
the other way first and it was wrong twice over. A layer surface belongs to one
output and cannot span two, so cross-monitor floats needed one full-screen
click-through surface per note *per monitor* -- 14 MB of buffers per note on a
two-monitor desk versus 0.27 MB now -- and dragging still broke, because the
pointer grab belongs to the surface the press landed on, so the note stuck
halfway across the seam. `FloatingWindow` + `startSystemMove()` hands the drag to
the compositor, which is whose job it actually is, and `startSystemResize()`
gives resizing for free. Do not "optimise" this back to layer-shell.

**`hyprctl keyword` does not work under the Lua config parser.** It errors with
"keyword can't work with non-legacy parsers. Use eval." Rules go through
`hyprctl eval`, which wraps its argument in `return ...` and therefore takes a
single expression -- multiple rules have to be smuggled in as
`(function() ... end)()`.

**Apply the base window rule in its own eval call.** `hyprctl eval` rejects a
malformed chunk wholesale, so bundling float/pin together with one placement
rule per note means a single bad coordinate or a hand-edited float id silently
takes the float rule down with it and *every* popped-out note tiles. Base rule
and placement rules are separate calls: the worst a bad placement rule can now
do is leave one note in the wrong position. Verified by injecting a malformed
id and confirming the notes still float.

**Do not try to reposition a live window from Ledge.** `hl.dispatch(dispatcher,
"title:...")` does *not* target by title -- it falls through to the focused
window, so an attempt to nudge a note moved whatever the user was actually
using. Ledge is read-only toward window geometry: it asks Hyprland where a note
ended up and remembers that. Placement happens once, through a rule, before the
window exists.

**Runtime window rules accumulate within a session.** Each pop adds another rule
for that note's title. The last matching rule wins, so behaviour stays correct
and the cost is a slow memory trickle cleared by any `hyprctl reload`. Worth
knowing while debugging: stale rules from earlier runs are still live, and a
non-`exact` rule left over from an older build will make placement look broken
in a way the current code cannot explain.

**`move` in a window rule is monitor-relative unless you pass `exact = true`.**
A note saved at x=400 reopened at x=2448 when the second monitor happened to be
focused, because 2448 is 400 past that monitor's origin. This is invisible while
testing on a single-monitor layout or with the leftmost monitor focused.

**The eval chunk is Lua source, so backslashes must be doubled.** A single `\-`
is an invalid Lua escape and the *entire chunk* is rejected, silently taking
every rule with it. The visible symptom is "popped-out notes are tiled again",
several layers away from the cause. Hyphens are not escaped at all: `\-` is not
valid Lua and a hyphen outside a character class is already literal.

**A window rule only applies to a window that has not mapped yet.** Nothing is
added to the float table until its placement rule has landed, and rule
application is gated on a `Store.floatsReady` *property* rather than a signal --
a singleton's file load can finish before shell.qml exists to connect to it, and
that race showed up as every note being tiled.

**`exact = true` on a `move` window rule does not reliably mean absolute.** On a
secondary output the window still lands at stored + monitor_origin. That would be
a cosmetic annoyance except the position is then read back and learned, so every
restart shifts the note another monitor width until it is off the desktop
entirely. Observed: a note reached x=4176 on a desktop 3584 wide. Float geometry
is therefore stored as `{ monitor, x, y }` relative to a named output, which is
how Hyprland actually applies it, and `setFloatGeometry` refuses to learn a
position that lands on no output at all as a backstop.

**The styled markdown layer must not change a single character's width.** It is
painted behind a transparent editor holding the real text; if one glyph shifts,
the caret drifts away from the character it belongs to. That is why markers are
dimmed rather than hidden, why `- [ ]` is not swapped for a checkbox glyph, and
why headings change weight and colour but never size. Verified by measuring: the
same line occupies rows 65-75 and columns 18-299 in both modes. Bold sharing an
advance width is a property of monospaced faces only, hence the `styling` switch.

**A directory rescan can race a file move.** Deleting a note removes its row and
*then* moves the file to trash. A rescan landing in between still sees the file
and re-adds the row as an unloaded placeholder, and the reap pass used to skip
rows that had never loaded -- so the row stayed forever, pointing at a file in
the trash. Ids being moved are held in `Store.removing` and skipped by the scan,
and the reap now spares only `pending` rows, which are the only ones legitimately
without a file.

**Cut input regions from the item, not from a snapshot of where it was.** The
open note's `Region` was fed a y/height pushed over from the delegate's change
handlers, which fired for the note's own geometry but not for its slot moving,
the strip re-centring, or the list scrolling. A note created by the + is
appended at the end of the strip, so its slot settles *after* that fired and the
input region was left near the top of the screen: the note was drawn but nothing
could be clicked. `Region { item: ... }` tracks the real geometry. This is the
same mistake as the editor `text` binding, from the opposite direction: there,
state that should have been imperative was declarative; here, geometry that
should have been declarative was imperative.

**A layer surface's `keyboardFocus` is read at the instant of the click.**
Flipping it to OnDemand *because* of a click is too late -- the compositor has
already decided not to grant focus. The strip accepted focus only once a note
was open, so clicking the + opened a note that could never be typed into. It now
accepts focus from the moment the strip fans out, which is the only time
anything on it is clickable anyway.

**Never auto-focus a floating note's editor.** Popped-out notes are pinned and
sit on every workspace; focusing the editor because the note is floating means
it quietly eats keystrokes meant for whatever you were actually typing into.
Observed for real: a note picked up a stray character this way.

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
- IPC + CLI (`new`/`add`/`list`/`open`/`rm`/`move`/`peek`/`close`)
- Drag reorder, persisted to `order` and verified across a restart
- `+` at the end of the strip for a new note, and `SUPER + N` globally
- Pop a note out to float on the desktop, drag it by the header or band, across
  monitors, dock it back
- Controls always visible on an open note, two-step delete, blank notes discarded
- `SUPER + N` toggles: opens a blank note, or puts the open one away
- All Notes window: search, archived notes, trash with restore, export
- Reminders, fired by a sweep rather than per-note timers
- Config hot reload

## Next, roughly in order

1. **Image paste** - as an attachment chip, not `![]()` markdown syntax.
2. **Markup coverage** - tables and fenced code blocks are deliberately absent;
   both need block layout, which the same-width invariant forbids. behind the `styling` flag. The approach that works
   without a mode split: a styled `Text` layer behind a transparent `TextEdit`.
   Only aligns if bold and regular share advance widths, i.e. a monospace font.
   Note that in the config docs.
3. Multi-monitor `"all"` is written but only `"focused"` has been exercised.
4. Publish: tag v0.1.0, AUR submission, marketplace listing, competition entry.

## Testing

```bash
./test/smoke.sh
```

Runs a second Ledge instance against a throwaway `LEDGE_DATA_DIR` and drives it
over IPC, asserting on what lands on disk. It never touches real notes. The
strip appears on screen for a few seconds while it runs, which is the point:
what is being tested is a real shell, not a mock.

Add a case for anything that breaks. The first run of this suite immediately
found a ghost-row bug in delete that had been shipped and never noticed, which
is a fair summary of why it exists. Several regressions in this project reached
the user rather than the author, all of them mechanically checkable.

Not covered, because it needs a real pointer: hover-to-peek, drag reorder,
dragging a float between monitors, and the resize grip.
