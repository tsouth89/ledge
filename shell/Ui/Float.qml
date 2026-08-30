import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core

// A popped-out note, on one monitor.
//
// There is one of these per (floating note x monitor). Positions are stored in
// global compositor coordinates and each surface draws the note at
// global-minus-its-own-origin, so dragging a note across a monitor seam is one
// continuous movement: the note is briefly drawn by both surfaces, each showing
// its own half, and nothing teleports.
//
// Each surface is full-screen and click-through, with the input region cut down
// to the note. The alternative -- a small surface anchored top-left and
// repositioned by changing its margins -- means a compositor reconfigure on
// every frame of a drag, which is exactly when you least want one. Here the
// drag is a plain x/y change inside a surface that never moves or resizes.
PanelWindow {
  id: win

  required property var modelData
  readonly property string noteId: modelData ? String(modelData.id) : ""

  screen: modelData ? modelData.screen : null

  readonly property var state: Store.floatState(noteId)
  readonly property var note: Store.get(noteId)

  readonly property real originX: screen ? screen.x : 0
  readonly property real originY: screen ? screen.y : 0

  // Only map where the note actually overlaps this output, so the idle cost of
  // a float on a two-monitor desk is one surface, not two.
  readonly property bool overlaps: {
    if (!state || !screen) return false
    var nx = state.x, ny = state.y
    var nw = Config.cardWidth, nh = noteItem.height
    return nx < originX + screen.width && nx + nw > originX
        && ny < originY + screen.height && ny + nh > originY
  }

  visible: state !== null && note !== null && overlaps

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

      // Global position, expressed relative to this monitor's origin.
      x: (win.state ? win.state.x : 0) - win.originX
      y: (win.state ? win.state.y : 0) - win.originY

      onFloatDragged: function (dx, dy) {
        Store.nudgeFloat(win.noteId, dx, dy, height)
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
