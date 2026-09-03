# Ledge

Sticky notes that live on the edge of your screen, for Hyprland.

Notes rest as thin coloured dashes against one edge of the display. Reach toward
them and the strip fans out to show its labels. Land on one and that dash *is*
the note: it widens, grows to fit its text, and its colour retreats to a band
down the edge. Nothing slides out from behind anything else. Move away and it
folds back to a dash.

Everything else on the surface is click-through, so the strip costs you nothing
until you reach for it.

![ledge](docs/ledge.png)

## Why not just a window

Ledge is a `wlr-layer-shell` surface, not a floating window. That means it is a
desktop component in the same sense your bar is: it never appears in the window
list, never takes focus you did not give it, is never tiled, and does not steal
the pointer. The only parts of it that accept input are the strip itself and
whichever note is currently open. The rest of the screen behaves as if it were
not there.

## Install

An AUR package is planned. Until it is published, build Ledge yourself. The
PKGBUILD is in the repository and fetches the tagged release:

```bash
git clone https://github.com/tsouth89/ledge
cd ledge
makepkg -si
```

Then start it, either as a user service:

```bash
systemctl --user enable --now ledge
```

or from your compositor's autostart, if you would rather not involve systemd:

```
exec-once = ledge start
```

On Omarchy that goes in `~/.config/hypr/autostart.lua`.

To run it straight from a clone without installing anything:

```bash
./bin/ledge start
```

Requires `quickshell`, a `wlr-layer-shell` compositor, and a Nerd Font for the
note controls (`ttf-jetbrains-mono-nerd` by default -- without one those icons
render as empty boxes).

Developed on Hyprland, against both of its config parsers, though only the Lua
one has been run in anger. Sway, river, niri and Wayfire should show the strip
fine, but popped-out notes place themselves through Hyprland window rules and
will open unplaced elsewhere.

Suggested keybindings:

```lua
o.bind("SUPER + N", "New note", "ledge new")
o.bind("SUPER + SHIFT + L", "All notes", "ledge all")
```

`ledge version` prints everything a bug report needs.

## Use

Reach for the edge. That is the whole interface.

| | |
|---|---|
| hover the strip | fans out, showing labels |
| hover a note | it opens |
| click | opens and puts the caret in the text |
| drag a dash | reorder; neighbours slide aside to show where it lands |
| the `+` at the end of the strip | new note |
| `SUPER + N` | new sticky on the desktop, focused and ready to type; press it again to put it away |
| `Ctrl` + click a link | open it in your browser |
| `Esc` | save and fold away |
| scroll the strip | when there are more notes than fit |

Hovering along an already-open strip swaps straight to the next note rather than
making you wait out the dwell again.

An open note shows its controls the whole time it is open: pop out, pin, copy
the text, archive, delete, a reminder clock, and a swatch that opens the full
colour palette. Hovering one names it.

Links in a note are coloured and underlined, and `Ctrl` + click opens one. A
plain click still just puts the caret where you clicked, because a note is an
editor first. Trailing punctuation is left out of the link, so a sentence that
ends on a URL opens the URL and not the full stop.
Delete takes two clicks, and deleted notes go to `trash/` rather than being
unlinked, so a misclick is recoverable twice over.

A note you open and never type into is discarded when it closes, whether it was
open on the strip or sitting on the desktop. Nothing is written to disk until a
note has something in it, so reaching for `SUPER + N`, thinking better of it,
and pressing it again leaves nothing behind.

### Images

Paste an image into a note and it becomes a thumbnail along the bottom. Click it
to open, or hover for the button to drop it.

Images are files beside the notes, not markdown embedded in them:

```
~/.local/share/ledge/attachments/<note-id>/<timestamp>.png
```

`![](/some/long/path.png)` in the text would be styled, wrapped, edited and
eventually broken by hand, and it would eat four lines of a sticky note to say
"there is a picture here". Deleting a note takes its images with it.

`ledge attach <id>` does the same thing from a script.

### Reminders

The clock on an open note sets one: 15 minutes, an hour, three hours, or next
9am. Click it again to clear it, and it lights up while one is pending. The
notification carries an "Open note" action that brings the note back up.

Reminders live in the note's frontmatter, so they travel with the file. Nothing
schedules a timer per note; the list is swept periodically instead, which means
a reminder that came due while the machine was asleep, or while Ledge was not
running, still fires the next time it is looked at rather than being silently
skipped.

```bash
ledge remind <id> 90m
ledge remind <id> 2026-09-01T09:00:00Z
ledge remind <id> clear
```

### All notes

`SUPER + SHIFT + L` opens a window with every note in it: search across bodies
and titles, browse what you have archived, and go through the trash.

It is keyboard-first. The search field takes focus on open, and you never have
to leave it: arrows move through the results, Return does whatever that row is
mainly for (open a note, unarchive one, rescue one from the trash), `Ctrl` +
Return detaches the selected note onto the desktop instead, Tab cycles the three
views, and Escape clears the search before it closes the window.

So the whole round trip is a keyboard one: `SUPER + SHIFT + L`, type enough of
the note to find it, `Ctrl` + Return, and it is a sticky under your pointer.

Deleting a note moves its file to `trash/` rather than unlinking it, and the
trash view lists what is in there with how long ago it went, so a note you
deleted by mistake is two clicks from being back. Emptying the trash is the only
thing in Ledge that destroys anything, and it asks twice.

Export writes every note into one markdown file, using each note's first line as
its heading.

### Popping a note out

Notes do not have to stay on the edge. Pop one out and it detaches to sit
anywhere on the desktop. Drag it by its header strip or its colour band, resize
it from the grip in its corner, and dock it back with one control. It leaves the
strip while it is out.

Dragging a popped-out note between monitors is handed to the compositor, the
same way a title bar does it, so crossing outputs and spanning the seam behave
exactly like every other window on your desktop. Position and size persist in
`floats.json`.

Popped-out notes are pinned, borderless, and do not take focus when they appear,
so one parked on your desktop follows you between workspaces without ever
catching a keystroke meant for something else. Ledge applies the Hyprland rules
for this itself; see [docs/hyprland.md](docs/hyprland.md) if you want to know
exactly what it sets and why.

## Command line

```
ledge start | stop | restart | status
ledge stats             internal health counters as JSON
ledge new [text]        create a note as a sticky on the desktop (reads stdin)
ledge add [text]        append to the most recent note (reads stdin)
ledge list              every note as JSON
ledge all               open the All Notes window
ledge attach <id>       attach the image on the clipboard to a note
ledge remind <id> <when>  set or clear a reminder
ledge export [path]     write every note to one markdown file
ledge trash             list deleted notes as JSON
ledge restore <file>    bring a deleted note back
ledge open <id>         open one note for editing
ledge copy <id>         copy a note's text to the clipboard
ledge rm <id>           move a note to the trash
ledge move <id> <n>     move a note to position n (0 is first)
ledge pop <id>          detach a note to float on the desktop
ledge place <id> <x> <y>  move a floating note (global screen coordinates)
ledge dock <id>         send a floating note back to the strip
ledge peek              fan the strip open
ledge close             collapse it
ledge log               tail the running instance's log
ledge dir               print the data directory
ledge install-desktop   add Ledge to your launcher when running from a clone
ledge version           version and environment for bug reports
```

So this works:

```bash
dmesg | tail -20 | ledge new
ledge add "call the vet at 3"
```

`SUPER + N` is the one plain-SUPER letter Omarchy leaves free that actually
means something here, and it matches the macOS original's new-note chord. Bare
`ledge new` toggles, so the same key puts the note away again.

A new note arrives as a sticky on the desktop rather than as a dash on the
strip, because that is what asking for a sticky note means. It takes the
keyboard so you can start typing straight away; notes that merely reappear
never do. The `+` at the end of the strip still makes a note on the strip,
where you already are.

## Your notes are just files

```
~/.local/share/ledge/
├── notes/<id>.md     one note per file, YAML frontmatter
├── order             note ids, one per line, display order
├── floats.json       geometry of popped-out notes, per monitor
├── attachments/      pasted images, one directory per note
└── trash/            deleted notes
```

```markdown
---
id: mtfb6ns2-v3ak
color: cyan
created: 2026-08-30T04:27:57.026Z
---
vet appointment
- [ ] thursday 3pm
```

Grep them, commit them, sync them, point Obsidian at them, edit them in Neovim
while Ledge is running: the strip watches the directory and picks up outside
edits live, including into a note that is open at the time. If an edit ever does
collide with one you are typing, the version Ledge would have replaced is kept
under `conflicts/` rather than dropped.

Neither ordering nor float position lives in the frontmatter. Dragging a note to a new spot
rewrites one small `order` file rather than touching every note below it, which
keeps reorders out of the way in git and in any file-sync tool.

Notes are plain text, and stay plain text. There is no edit/preview mode,
because a note you hover for half a second should not have modes.

Markdown is styled in place instead. Headings get weight, `**bold**` goes bold,
`*italic*` leans, `~~strike~~` strikes, backticks and links pick up the note's
colour, and a ticked `- [x]` strikes its line through. Every marker stays on
screen, dimmed, and every character stays exactly where you typed it, because
what you are editing is still the plain text underneath. Click a `- [ ]` box to
tick it.

The one real constraint: the styled layer only lines up with the text while bold
and regular share an advance width, which is true of a monospaced font and not
of a proportional one. Headings change weight and colour but never size, for the
same reason. Set `"styling": false`, or `styled: false` in one note's
frontmatter, to turn it off.

## Theming

Ledge reads the active Omarchy theme directly and recolours with it:

```
~/.local/state/omarchy/current/theme/colors.toml
~/.local/state/omarchy/current/theme/shell.toml
```

`omarchy theme set <name>` repaints the notes with no restart.

Note colours are *generated* rather than looked up, and this is deliberate.
Reading eight swatches off a theme palette by name sounds right and fails in
practice: a monochrome theme's `red`, `green` and `magenta` are all the same
hue, so every note ends up the same colour. Osaka Jade's `bright_magenta` is
`#75bbb3`, a teal. Instead Ledge takes the theme accent's hue, saturation and
lightness and spreads eight swatches across an arc centred on it. Muted themes
get muted notes, vivid themes get vivid ones, and the notes stay distinguishable
from each other in every theme. Widen or narrow the arc with `swatchSpread`.

## Configuration

`~/.config/ledge/config.json`, hot-reloaded on save. Every key is optional.
See [docs/config.md](docs/config.md).

```json
{
  "edge": "right",
  "monitor": "focused",
  "cardWidth": 300,
  "swatchSpread": 0.42
}
```

## Development

```bash
./test/smoke.sh     # drives a throwaway instance over IPC, asserts on disk state
./bin/ledge restart # reload after editing the QML
```

`LEDGE_DATA_DIR` and `LEDGE_CONFIG` override where notes and settings live,
which is how the tests stay clear of real notes.

## License

MIT
