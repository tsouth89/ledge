pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Live view of the active Omarchy theme.
//
// Reads the same two files the Omarchy shell reads, so Ledge recolors in step
// with `omarchy theme set` instead of shipping a palette that drifts:
//
//   ~/.local/state/omarchy/current/theme/colors.toml   foundational palette
//   ~/.local/state/omarchy/current/theme/shell.toml    per-surface design tokens
//
// theme.name is the reload trigger. It is rewritten on every theme set, and
// unlike the toml files it is a stable path that always exists, so watching it
// catches a swap even when the theme directory is replaced wholesale.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string statePath: home + "/.local/state/omarchy/current"
  readonly property string themePath: statePath + "/theme"

  property string name: "unknown"
  property string mode: "dark"
  readonly property bool dark: mode !== "light"

  // Flat dicts. Reassigned wholesale rather than mutated, because bindings
  // below only re-evaluate when the property identity changes.
  property var colors: ({})
  property var tokens: ({})

  // ------------------------------------------------------------ parsing

  // Minimal TOML reader. Both files are the flat `key = "value"` subset with
  // optional [section] headers; nothing here needs arrays, dates, or nesting.
  function parseToml(text) {
    var out = {}
    var section = ""
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (!line.length || line.charAt(0) === "#") continue

      var header = line.match(/^\[([^\]]+)\]$/)
      if (header) { section = header[1] + "."; continue }

      var eq = line.indexOf("=")
      if (eq < 0) continue
      var key = line.slice(0, eq).replace(/^\s+|\s+$/g, "")
      var val = line.slice(eq + 1).replace(/^\s+|\s+$/g, "")
      val = val.replace(/\s+#.*$/, "")
      val = val.replace(/^"(.*)"$/, "$1").replace(/^'(.*)'$/, "$1")
      out[section + key] = val
    }
    return out
  }

  function loadColors(text) {
    var parsed = parseToml(text)
    root.mode = parsed["mode"] || "dark"
    root.colors = parsed
  }

  function loadTokens(text) {
    root.tokens = parseToml(text)
  }

  function color(key, fallback) {
    var v = root.colors[key]
    return (typeof v === "string" && v.length) ? v : fallback
  }

  function token(key, fallback) {
    var v = root.tokens[key]
    return (typeof v === "string" && v.length) ? v : fallback
  }

  function tokenNumber(key, fallback) {
    var n = Number(root.tokens[key])
    return isFinite(n) ? n : fallback
  }

  // ------------------------------------------------------------ palette

  readonly property color background: color("background", "#101315")
  readonly property color backgroundDark: color("dark_background", "#0c0f11")
  readonly property color backgroundDarker: color("darker_background", "#090b0d")
  readonly property color backgroundLight: color("lighter_background", "#1c2225")

  readonly property color foreground: color("foreground", "#cacccc")
  readonly property color foregroundDim: color("dark_foreground", "#8a8f8f")
  readonly property color foregroundBright: color("bright_foreground", "#f0f2f2")

  readonly property color accent: color("accent", "#7ea3a0")
  readonly property color selection: color("selection", "#2a3438")
  readonly property color muted: color("muted", "#5a6468")
  readonly property color urgent: color("red", "#a55555")

  // Surface roles, matching the shell's own tokens so a Ledge card sits next
  // to a notification toast without looking like a different application.
  readonly property color surface: token("popups.background", background)
  readonly property color surfaceText: token("popups.text", foreground)
  readonly property color surfaceBorder: token("popups.border", accent)
  readonly property real borderAlpha: tokenNumber("popups.border-alpha", 1.0)

  readonly property string fontFamily: token("font.family", "JetBrainsMono Nerd Font")
  readonly property int fontBase: Math.round(tokenNumber("font.base-size", 12))

  // ------------------------------------------------------------ helpers

  function mix(a, b, t) {
    var ca = Qt.color(a), cb = Qt.color(b)
    return Qt.rgba(ca.r + (cb.r - ca.r) * t,
                   ca.g + (cb.g - ca.g) * t,
                   ca.b + (cb.b - ca.b) * t,
                   ca.a + (cb.a - ca.a) * t)
  }

  function withAlpha(c, a) {
    var cc = Qt.color(c)
    return Qt.rgba(cc.r, cc.g, cc.b, a)
  }

  // ------------------------------------------------------- note colours
  //
  // Note colours are generated, not looked up. Reading them straight off the
  // theme palette sounds right and is wrong in practice: a monochrome theme
  // names eight entries `red`, `green`, `magenta` and so on that are all the
  // same hue, so every note comes out the same colour and stops being a
  // recognisable object. Osaka Jade's `bright_magenta` is #75bbb3, a teal.
  //
  // Instead the swatches are eight evenly spaced hues, wearing the saturation
  // and lightness of the *current theme's* accent. Muted themes get eight muted
  // notes, vivid themes get eight vivid ones, and the whole wheel rotates to
  // start at the theme's own accent hue. Notes stay theme-native and stay
  // telling apart.

  readonly property var swatchKeys: [
    "yellow", "green", "cyan", "blue", "magenta", "orange", "red", "brown"
  ]

  readonly property var swatchLabels: ({
    "yellow": "Yellow", "green": "Green", "cyan": "Cyan", "blue": "Blue",
    "magenta": "Pink", "orange": "Orange", "red": "Red", "brown": "Sand"
  })

  function swatchKey(key) {
    return root.swatchKeys.indexOf(key) >= 0 ? key : root.swatchKeys[0]
  }

  // hslHue reports -1 for greys; fall back to a fixed start so a monochrome
  // theme still yields a usable wheel rather than collapsing to one hue.
  readonly property real refHue: {
    var h = Qt.color(accent).hslHue
    return h < 0 ? 0.12 : h
  }
  readonly property real refSat: {
    var sv = Qt.color(accent).hslSaturation
    return Math.max(0.30, Math.min(0.70, sv <= 0 ? 0.45 : sv))
  }

  // Spread across a slice of the wheel centred on the theme's accent hue, not
  // the whole wheel. A full 360 degrees gives eight unmistakably different
  // colours that also look nothing like the active theme -- pastel pink and
  // baby blue on a deep green desktop. A ~150 degree arc keeps every swatch
  // recognisably part of the same family while still telling them apart.
  function swatchHue(key) {
    var n = root.swatchKeys.length
    var i = Math.max(0, root.swatchKeys.indexOf(key))
    var offset = (i / (n - 1) - 0.5) * Config.swatchSpread
    var h = (root.refHue + offset) % 1.0
    return h < 0 ? h + 1.0 : h
  }

  // Vivid: the resting dash, and the band down the edge of an open note.
  function tabColor(key) {
    return Qt.hsla(swatchHue(key), root.refSat, dark ? 0.62 : 0.52, 1)
  }

  // The paper. Dark enough to sit under light text in a dark theme, but with
  // the hue left intact so two open notes never look like the same object.
  function cardColor(key) {
    return dark ? Qt.hsla(swatchHue(key), root.refSat * 0.80, 0.235, 1)
                : Qt.hsla(swatchHue(key), root.refSat * 0.55, 0.90, 1)
  }

  // Ink, keyed to the note's own hue so it belongs to the paper, but pushed to
  // the ends of the lightness range so contrast never depends on the swatch.
  function cardTextColor(key) {
    return dark ? Qt.hsla(swatchHue(key), 0.22, 0.88, 1)
                : Qt.hsla(swatchHue(key), 0.45, 0.16, 1)
  }

  // Relative luminance, sRGB. Used to decide whether a surface wants dark or
  // light text rather than assuming, which is what made tab labels unreadable
  // on the lighter half of the palette.
  function luminance(c) {
    var col = Qt.color(c)
    function channel(v) {
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(col.r) + 0.7152 * channel(col.g) + 0.0722 * channel(col.b)
  }

  // Ink for text sitting directly on a swatch, e.g. the label on an edge tab.
  // Same hue so it still belongs to the note, but driven to whichever end of
  // the lightness range actually contrasts with the tab underneath it.
  function tabTextColor(key) {
    var tab = tabColor(key)
    var hue = swatchHue(key)
    return luminance(tab) > 0.34
         ? Qt.hsla(hue, Math.min(0.9, refSat * 1.1), 0.11, 1)
         : Qt.hsla(hue, 0.18, 0.96, 1)
  }

  // ------------------------------------------------------------- files

  property FileView nameFile: FileView {
    path: root.statePath + "/theme.name"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.name = String(text() || "").replace(/^\s+|\s+$/g, "")
      colorsFile.reload()
      tokensFile.reload()
    }
    // text() is stale inside the change signal, so route every path through
    // reload() -> onLoaded and always parse fresh content.
    onFileChanged: reload()
  }

  property FileView colorsFile: FileView {
    id: colorsFile
    path: root.themePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadColors(text())
    onFileChanged: reload()
    onLoadFailed: root.loadColors("")
  }

  property FileView tokensFile: FileView {
    id: tokensFile
    path: root.themePath + "/shell.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadTokens(text())
    onFileChanged: reload()
    onLoadFailed: root.loadTokens("")
  }
}
