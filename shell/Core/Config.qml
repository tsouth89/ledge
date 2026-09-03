pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// User settings, hot-reloaded from ~/.config/notestrip/config.json.
// Every key is optional; the defaults below are the shipped behaviour.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string path: {
    var override = Quickshell.env("NOTESTRIP_CONFIG")
    if (!override || !override.length) override = Quickshell.env("LEDGE_CONFIG")
    if (override && override.length) return override
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome || !configHome.length) configHome = home + "/.config"
    return configHome + "/notestrip/config.json"
  }

  property var values: ({})

  function str(key, fallback) {
    var v = root.values[key]
    return (typeof v === "string" && v.length) ? v : fallback
  }
  function num(key, fallback) {
    var v = Number(root.values[key])
    return isFinite(v) ? v : fallback
  }
  function bool(key, fallback) {
    var v = root.values[key]
    return typeof v === "boolean" ? v : fallback
  }

  // Which screen edge the notes live on.
  readonly property string edge: {
    var e = str("edge", "right")
    return (e === "left" || e === "right") ? e : "right"
  }
  readonly property bool onLeft: edge === "left"

  // "focused" follows the active monitor, "all" mirrors on every monitor, or
  // name one output directly (e.g. "DP-2").
  readonly property string monitor: str("monitor", "focused")

  // Resting width of the colour dash. The Mac original uses 12pt; anything
  // under about 8 gets hard to hit without overshooting off-screen.
  readonly property int tabRest: Math.max(6, num("tabRest", 12))
  // Width once the strip notices the cursor and the labels rotate into view.
  readonly property int tabPeek: Math.max(root.tabRest, num("tabPeek", 34))
  // A tab's height is also the length of its label, since the text is rotated
  // along it. Too short and every note reads as an ellipsis.
  readonly property int tabHeight: Math.max(28, num("tabHeight", 104))
  readonly property int tabGap: Math.max(0, num("tabGap", 4))

  readonly property int cardWidth: Math.max(180, num("cardWidth", 300))

  // Transparent margin around a popped-out note, inside its window, for the
  // note's own drop shadow. Stored float geometry is the *note* rectangle; the
  // window is this much larger on each side.
  readonly property int floatShadowPad: Math.max(0, num("floatShadowPad", 14))
  readonly property int cardMinHeight: Math.max(56, num("cardMinHeight", 92))
  readonly property int cardMaxHeight: Math.max(root.cardMinHeight, num("cardMaxHeight", 420))

  // Dwell before the strip peeks, and grace before it closes again. The close
  // grace matters more than it looks: without it, crossing the gap between a
  // tab and its own card reads as a leave and the card snaps shut mid-reach.
  readonly property int revealDelay: Math.max(0, num("revealDelay", 90))
  readonly property int hideDelay: Math.max(0, num("hideDelay", 260))
  readonly property int openDelay: Math.max(0, num("openDelay", 130))

  // Scroll the strip past this many visible notes.
  readonly property int maxVisible: Math.max(3, num("maxVisible", 10))

  // How much of the colour wheel the eight note swatches span, centred on the
  // theme's accent hue. 1.0 is the full wheel (maximum contrast between notes,
  // least like the theme); around 0.4 keeps them a family. 0 makes them all
  // one hue, distinguished only by the tab position.
  readonly property real swatchSpread: Math.max(0, Math.min(1, num("swatchSpread", 0.42)))

  // Inline markdown styling. Per-note frontmatter `styled: false` overrides.
  readonly property bool styling: bool("styling", true)

  // Top sits under fullscreen windows, which is almost always what you want.
  // Overlay draws over them, including over games.
  readonly property string layer: str("layer", "top")

  // Whether a popped-out note follows you between workspaces. On by default,
  // because that is what makes a sticky note a sticky note. Turn it off if you
  // keep a note per project and want it to stay on the workspace you left it
  // on. Applies to every note; a per-note choice would need its own frontmatter
  // field, and is only worth it if this switch turns out not to be enough.
  readonly property bool floatFollows: bool("floatFollows", true)

  readonly property int topMargin: num("topMargin", 0)
  readonly property int bottomMargin: num("bottomMargin", 0)

  property FileView file: FileView {
    path: root.path
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text() || "{}")
        root.values = (parsed && typeof parsed === "object") ? parsed : ({})
      } catch (e) {
        console.warn("notestrip: config.json is not valid JSON, using defaults:", e)
      }
    }
    onFileChanged: reload()
    onLoadFailed: root.values = ({})
  }
}
