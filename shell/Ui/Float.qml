import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core

// A popped-out note.
//
// One full-screen, click-through layer surface per floating note, with the
// input region cut down to the note itself. The alternative -- a small surface
// anchored top-left and repositioned by changing its margins -- means a
// compositor reconfigure on every frame of a drag, which is exactly when you
// least want one. Here the drag is a plain x/y change inside a surface that
// never moves or resizes, so it stays smooth. The cost is a transparent
// full-screen surface per popped note, which is fine for the handful of notes
// anyone actually detaches.
PanelWindow {
  id: win

  required property var modelData
  readonly property string noteId: String(modelData)

  readonly property var state: Store.floatState(noteId)
  readonly property var note: Store.get(noteId)

  visible: state !== null && note !== null

  WlrLayershell.namespace: "ledge-float"
  WlrLayershell.layer: Config.layer === "overlay" ? WlrLayer.Overlay : WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
  exclusionMode: ExclusionMode.Ignore
  color: "transparent"

  anchors { top: true; bottom: true; left: true; right: true }

  mask: Region { item: noteItem }

  Item {
    id: content
    anchors.fill: parent

    Note {
      id: noteItem

      noteId: win.noteId
      colorKey: win.note ? win.note.color : Theme.swatchKeys[0]
      label: win.note ? Store.deriveTitle(win.note.body, win.note.title) : ""
      body: win.note ? win.note.body : ""
      pinned: win.note ? win.note.pinned : false
      index: 0

      floating: true
      open: true
      editing: false

      width: Config.cardWidth

      // Clamped on every change rather than only on drop, so a note cannot be
      // parked off-screen and then be unreachable after a restart or a
      // monitor change.
      x: Math.max(0, Math.min(content.width - width, win.state ? win.state.x : 60))
      y: Math.max(0, Math.min(content.height - height, win.state ? win.state.y : 60))

      onFloatDragged: function (dx, dy) {
        Store.moveFloat(win.noteId,
                        Math.max(0, Math.min(content.width - width, x + dx)),
                        Math.max(0, Math.min(content.height - height, y + dy)))
      }
      onFloatDragEnded: Store.persistFloats()

      onDockRequested: Store.unfloat(win.noteId)
      onDismissed: Store.unfloat(win.noteId)
      onDeleteRequested: {
        var id = win.noteId
        Store.unfloat(id)
        Store.remove(id)
      }
    }
  }
}
