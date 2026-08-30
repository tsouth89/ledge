# Hyprland integration

Ledge has two very different kinds of surface, on purpose.

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

## The rules Ledge applies

Ledge applies these itself at startup, so there is nothing to add to your
config. They match on title, because `class` is `org.quickshell` and is shared
with every other Quickshell instance on the system, including the Omarchy shell
itself.

```lua
hl.window_rule({
  match = { title = "^(ledge-note:.*)$" },
  tag = "-default-opacity",
  float = true,
  pin = true,
  no_initial_focus = true,
  no_blur = true,
  no_shadow = true,
  no_dim = true,
  border_size = 0,
  rounding = 0,
  opacity = "1 1",
})
```

`pin` is what makes a sticky note behave like one: it follows you between
workspaces instead of being stranded on the one you popped it out from.
`no_initial_focus` stops a note appearing mid-sentence and eating the rest of
it. Border, rounding and shadow are all turned off because Ledge draws its own.

Placement is a second rule per note, carrying the position and size from
`floats.json`:

```lua
hl.window_rule({
  match = { title = "^(ledge-note:<id>)$" },
  move = { x, y, exact = true },
  size = { w, h },
})
```

`exact = true` matters: without it Hyprland treats the coordinates as relative to
whichever monitor the window opens on, so a note saved near the left of your
desktop reopens shifted by the width of everything to its left.

The base rule and the placement rules are applied as **separate** `eval` calls.
A malformed chunk is rejected in full, so putting them together would mean one
bad coordinate silently taking `float` and `pin` with it and every note tiling.
Kept apart, the worst a bad placement rule can do is leave one note in the wrong
place.

A window rule only applies to a window that has not mapped yet, so Ledge does
not add a note to the float table until its placement rule has landed. Without
that ordering the note flashes wherever Hyprland would have put it, or gets
tiled outright.

## Two config parsers, two routes

Hyprland has two config parsers and they take window rules by completely
different routes. Ledge checks which one is in use and picks accordingly.

Under the Lua parser (Omarchy 4, and anything else opting in) `hyprctl keyword`
refuses to run:

```
keyword can't work with non-legacy parsers. Use eval.
```

Under the classic parser there is no `hl.window_rule` to call, and rules go in
as keywords instead:

```bash
hyprctl --batch "keyword windowrule float, title:^(ledge-note:.*)\$ ; keyword windowrule pin, title:^(ledge-note:.*)\$"
```

Assuming either parser strands every user of the other with popped-out notes
that tile instead of floating. **The classic-parser path is written to the
documented syntax but has not been run against a classic-parser Hyprland**, for
want of one to test on. If popped-out notes tile for you, that is the first
thing to check, and `ledge version` reports your compositor.

So the rules go through `hyprctl eval`, which wraps its argument in `return
...`. That only takes a single expression, so several rules are applied as one
immediately-invoked function:

```
hyprctl eval '(function() hl.window_rule({...}) hl.window_rule({...}) end)()'
```

Two things to watch, both of which fail silently as "my notes are tiled again":

- The chunk is Lua source. A backslash in a rule regex has to be doubled, or
  Lua rejects it as an invalid escape and **the entire chunk is discarded**,
  taking every rule in it with it. Ledge escapes regex metacharacters but
  deliberately leaves hyphens alone: `\-` is not valid Lua, and a hyphen outside
  a character class is already literal. This is why the base rule is applied
  separately, and why Ledge logs a warning naming which set of rules Hyprland
  refused.
- Rules applied this way live in the compositor, not your config, so
  `hyprctl reload` drops them. Ledge reapplies on startup; if you reload
  Hyprland while Ledge is running, restart it with `ledge restart`.

## Keybinding

`SUPER + N` is the one plain-`SUPER` letter Omarchy leaves free that means
anything here, and it matches the macOS original's new-note chord.

```lua
o.bind("SUPER + N", "New note", "ledge new")
```

Bare `ledge new` toggles, so the same key puts the note away again.
