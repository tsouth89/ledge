# Configuration

`~/.config/ledge/config.json`. Hot-reloaded on save; every key is optional and
the values below are the defaults.

## Placement

| key | default | |
|---|---|---|
| `edge` | `"right"` | `"right"` or `"left"` |
| `monitor` | `"focused"` | `"focused"` follows the active output, `"all"` mirrors everywhere, or name one (`"DP-2"`) |
| `layer` | `"top"` | `"top"` sits under fullscreen windows. `"overlay"` draws over them, including over games |
| `topMargin` | `0` | keep the strip clear of something at the top |
| `bottomMargin` | `0` | |

## The strip

| key | default | |
|---|---|---|
| `tabRest` | `12` | width of a resting dash. Under about 8 gets hard to hit without overshooting off-screen |
| `tabPeek` | `30` | width once the strip notices the cursor and labels rotate into view |
| `tabHeight` | `86` | a dash's height. Shorter truncates longer labels |
| `tabGap` | `4` | |
| `maxVisible` | `10` | scroll the strip past this many notes |

## An open note

| key | default | |
|---|---|---|
| `cardWidth` | `300` | |
| `cardMinHeight` | `92` | |
| `cardMaxHeight` | `420` | past this the note scrolls internally |

## Timing

| key | default | |
|---|---|---|
| `revealDelay` | `90` | dwell before the strip fans out, in ms |
| `openDelay` | `130` | further dwell on one dash before it opens |
| `hideDelay` | `260` | grace before folding away |

`hideDelay` matters more than it looks. Without it, crossing the few pixels
between a dash and the note it became reads as a leave, and the note snaps shut
mid-reach.

## Colour

| key | default | |
|---|---|---|
| `swatchSpread` | `0.42` | how much of the colour wheel the eight swatches span, centred on the theme's accent hue. `1.0` is the full wheel: maximum contrast between notes, least like your theme. `0` makes them all one hue |

## Text

| key | default | |
|---|---|---|
| `styling` | `true` | reserved for inline markdown styling; not yet implemented |

Per-note `styled: false` in a note's frontmatter overrides it.
