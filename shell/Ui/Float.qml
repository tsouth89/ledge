import QtQuick
import Quickshell
import qs.Core

// A popped-out note.
//
// This is an ordinary toplevel window, not a layer surface, and that is a
// deliberate reversal of how the strip works.
//
// wlr-layer-shell surfaces belong to exactly one output and cannot span two.
// Making a detached note work across monitors on top of layer-shell means one
// surface per note *per output*, each full-screen and click-through so the note
// can sit anywhere on it. That costs a transparent full-screen buffer per
// monitor per note, and worse, it breaks dragging: the pointer grab belongs to
// the surface the press landed on, so the moment the cursor crosses onto
// another output the drag dies and the note stops halfway across the seam.
//
// A toplevel has none of those problems, because moving windows between
// monitors is the compositor's job. `startSystemMove` hands the drag straight
// to it -- the same request a title bar uses -- so crossing outputs, spanning
// the seam, and snapping all behave exactly like every other window, at the
// cost of one small window-sized buffer instead of N full-screen ones.
// `startSystemResize` gets us resizing for the same price.
//
// The trade is that a toplevel is a window, and would tile and take focus
// without help. See docs/hyprland.md for the rules that make it behave like the
// desktop object it is; Ledge applies them itself at startup.
FloatingWindow {
  id: win

  required property var modelData
  readonly property string noteId: String(modelData)

  readonly property var state: Store.floatState(noteId)
  readonly property var note: Store.get(noteId)

  visible: state !== null && note !== null

  // Matched by the window rules. Keep it stable and distinctive: `class` is
  // shared with every other Quickshell instance on the system, including the
  // Omarchy shell itself, so rules key off the title instead.
  title: "ledge-note:" + noteId

  color: "transparent"

  // Room around the note for our own drop shadow. The window itself is
  // borderless and unrounded by rule, so this padding is the only thing
  // separating the note from the windows behind it.
  readonly property int shadowPad: 14

  minimumSize: Qt.size(180 + shadowPad * 2, 90 + shadowPad * 2)

  // The requested size. Quickshell drives toplevel geometry from the implicit
  // size; the compositor is free to override it, and does once the resize grip
  // is used.
  implicitWidth: (state && state.w ? state.w : Config.cardWidth) + shadowPad * 2
  implicitHeight: (state && state.h ? state.h : 200) + shadowPad * 2

  Item {
    id: content
    anchors.fill: parent

    Note {
      id: noteItem
      anchors.fill: parent
      anchors.margins: win.shadowPad

      noteId: win.noteId
      colorKey: win.note ? win.note.color : Theme.swatchKeys[0]
      label: win.note ? Store.deriveTitle(win.note.body, win.note.title) : ""
      body: win.note ? win.note.body : ""
      pinned: win.note ? win.note.pinned : false
      index: 0

      floating: true
      open: true
      editing: false

      onFloatMoveRequested: win.startSystemMove()
      onFloatResizeRequested: function (edges) { win.startSystemResize(edges) }

      onDockRequested: Store.unfloat(win.noteId)
      onDismissed: Store.unfloat(win.noteId)
      onDeleteRequested: {
        var id = win.noteId
        Store.unfloat(id)
        Store.remove(id)
      }
    }
  }

  // The compositor owns geometry now, so remember the size it settles on. There
  // is no equivalent for position: a Wayland client is never told where it is,
  // so placement is restored through the compositor instead (see Placement in
  // shell.qml).
  onWidthChanged: if (settled) sizeSaver.restart()
  onHeightChanged: if (settled) sizeSaver.restart()

  // Nothing is persisted until the window has stopped being resized *at* us.
  // Without this, a window the compositor tiled before its rules landed writes
  // its tiled geometry straight into floats.json and the note is wrong forever
  // after.
  property bool settled: false
  Timer {
    running: true
    interval: 1200
    onTriggered: win.settled = true
  }

  Timer {
    id: sizeSaver
    interval: 400
    onTriggered: {
      if (!win.state) return
      var w = win.width - win.shadowPad * 2
      var h = win.height - win.shadowPad * 2
      if (w < 180 || h < 90 || w > 900 || h > 1200) return
      Store.setFloatSize(win.noteId, w, h)
    }
  }
}
