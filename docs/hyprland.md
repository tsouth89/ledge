# Hyprland integration

NoteStrip has two very different kinds of surface, on purpose.

## The strip is a layer surface

The edge strip is `wlr-layer-shell`, like your bar. It never appears in the
window list, never tiles, never takes focus you did not give it, and everything
on it except the strip itself and the open note is click-through. No
configuration is needed.

## A popped-out note is a window

`wlr-layer-shell` surfaces belong to exactly one output and cannot span two.
Building detached notes on layer-shell meant one full-screen click-through
surface per note *per monitor*, and dragging still broke: the pointer grab
belongs to whichever surface the press landed on, so a note stopped dead
halfway across the seam between two monitors.

Moving windows between monitors is the compositor's job, so a popped-out note
is an ordinary toplevel and asks Hyprland to do the work with the same
`xdg_toplevel.move` request a title bar uses. Dragging, spanning the seam and
snapping all behave like any other window, and the note costs one small
window-sized buffer instead of a full-screen one per monitor.

The trade is that a window would tile and take focus without help.

## The rules NoteStrip applies

NoteStrip applies these itself at startup, so there is nothing to add to your
config. They match on title, because `class` is `org.quickshell` and is shared
with every other Quickshell instance on the system, including the Omarchy shell
itself.

```lua
hl.window_rule({
  match = { title = "^(notestrip-note:.*)$" },
  float = true,
  no_initial_focus = true,
  no_blur = true,
  no_shadow = true,
  no_dim = true,
  border_size = 0,
  rounding = 0,
})
```

`no_initial_focus` stops a note reappearing mid-sentence and eating the rest of
it. Border, rounding and shadow are all turned off because NoteStrip draws its own.

Opacity is deliberately absent, so a note is as translucent as the desktop makes
its windows. On Omarchy that is the `default-opacity` tag every window gets, and
a note picks it up like anything else. Dimming is the one thing turned off:
that cue means "this is not the window you are typing in", and since a sticky
note almost never is, obeying it would leave every note greyed out all day.

The per-note placement rule below restates `no_initial_focus`, because a note
you just asked for with `SUPER + N` is the one case where a note *should* take
the keyboard. A later rule overrides an earlier one, so the placement rule
always states an opinion rather than inheriting whatever the last pop left
behind.

Placement is a second rule per note, carrying the position and size from
`floats.json`:

```lua
hl.window_rule({
  match = { title = "^(notestrip-note:<id>)$" },
  monitor = "<output name>",
  pin = true,               -- false when this note stays on one workspace
  no_initial_focus = true,   -- false for a note just created by SUPER + N
  move = { x, y },
  size = { w, h },
})
```

The global `floatFollows` setting supplies the default `pin` value. A note's
globe control writes its own `floatFollows` frontmatter and updates the live
window with Hyprland's pin dispatcher, so changing it does not require a
restart.

Coordinates are relative to the output the rule names, which is why the rule
names one. `floats.json` records the output plus coordinates relative to that
output. Geometry read back from Hyprland is global, so NoteStrip converts it to
the relative stored form when the note settles.

The obvious alternative is `move = { x, y, exact = true }`, which claims to take
absolute coordinates and skip the output entirely. It does not do so reliably on
a secondary monitor, and because NoteStrip reads the geometry back off the
compositor and stores it again, the error compounds a little on every restart
until the note walks off the screen.

The base rule and the placement rules are applied as **separate** `eval` calls.
A malformed chunk is rejected in full, so putting them together would mean one
bad coordinate silently taking `float` with it and every note tiling.
Kept apart, the worst a bad placement rule can do is leave one note in the wrong
place.

A window rule only applies to a window that has not mapped yet, so NoteStrip does
not add a note to the float table until its placement rule has landed. Without
that ordering the note flashes wherever Hyprland would have put it, or gets
tiled outright.

## Two config parsers, two routes

Hyprland has two config parsers and they take window rules by completely
different routes. NoteStrip tries the Lua route first and lets the compositor's own
answer pick the other one.

Under the Lua parser (Omarchy 4, and anything else opting in) `hyprctl keyword`
refuses to run:

```
keyword can't work with non-legacy parsers. Use eval.
```

Under the classic parser there is no `hl.window_rule` to call, and rules go in
as keywords instead:

```bash
hyprctl --batch "keyword windowrule float, title:^(notestrip-note:.*)\$ ; keyword windowrule pin, title:^(notestrip-note:.*)\$"
```

Assuming either parser strands every user of the other with popped-out notes
that tile instead of floating. **The classic-parser path is written to the
documented syntax but has not been run against a classic-parser Hyprland**, for
want of one to test on. If popped-out notes tile for you, that is the first
thing to check, and `notestrip version` reports your compositor.

Which parser is in use is not predicted. Quickshell exposes `Hyprland.usingLua`,
but it is filled in asynchronously and still reads false for the first few
hundred milliseconds of the session, which is exactly when the startup rules go
in. Reading it there sent every rule down the classic route on a Lua-parser
Hyprland, and because `hyprctl` answers a refusal on **stdout** with exit status
0, nothing failed loudly: the rules were simply dropped and every popped-out
note tiled.

So the Lua route goes in first and the reply decides. Hyprland answers `ok` and
nothing else when it accepts a command; anything else means the classic route,
which is then run instead. That needs no readiness signal and does not depend on
the exact wording of the refusal. Any reply other than `ok` to the rules NoteStrip
finally settles on is logged as a warning.

The Lua route is `hyprctl eval`, which wraps its argument in `return
...`. That only takes a single expression, so several rules are applied as one
immediately-invoked function:

```
hyprctl eval '(function() hl.window_rule({...}) hl.window_rule({...}) end)()'
```

Two things to watch, both of which fail silently as "my notes are tiled again":

- The chunk is Lua source. A backslash in a rule regex has to be doubled, or
  Lua rejects it as an invalid escape and **the entire chunk is discarded**,
  taking every rule in it with it. NoteStrip escapes regex metacharacters but
  deliberately leaves hyphens alone: `\-` is not valid Lua, and a hyphen outside
  a character class is already literal. This is why the base rule is applied
  separately, and why NoteStrip logs a warning naming which set of rules Hyprland
  refused.
- Rules applied this way live in the compositor, not your config, so
  `hyprctl reload` drops them. NoteStrip reapplies on startup; if you reload
  Hyprland while NoteStrip is running, restart it with `notestrip restart`.

## Keybinding

`SUPER + N` is the one plain-`SUPER` letter Omarchy leaves free that means
anything here, and it matches the macOS original's new-note chord.

```lua
o.bind("SUPER + N", "New note", "notestrip new")
```

Bare `notestrip new` toggles, so the same key puts the note away again.
