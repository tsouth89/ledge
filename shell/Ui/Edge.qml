import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core

// The edge strip: a full-height layer surface pinned to one side of the
// screen, almost all of which is click-through.
//
// The surface never changes size. Only its input region and its contents move.
// Resizing a Wayland surface mid-animation lets the compositor scale a stale
// buffer for a frame, which shows up as a visible stretch exactly when a note
// is opening, so everything here animates inside a fixed rectangle.
PanelWindow {
  id: win

  required property var modelData
  screen: modelData

  // Set by the shell's monitor policy. A strip not wanted on this output stays
  // unmapped rather than merely transparent, so it reserves and receives
  // nothing.
  property bool active: true

  property string openId: ""
  property bool peeked: false
  property bool editing: false
  property string hoveredId: ""

  // The open note's item, so the input region can be cut from it directly.
  //
  // This used to be a pair of numbers pushed here from the delegate's change
  // handlers, which only fired for the note's own y and height -- never for its
  // slot moving, the strip re-centring, or the list scrolling. A note appended
  // at the end of the strip therefore got an input region left somewhere near
  // the top, and could not be clicked into at all. Binding a Region to the item
  // makes Quickshell track its real geometry instead.
  property Item openItem: emptyRegion

  // The input region below is the hit test. Anything the pointer can reach on
  // this surface is either the strip or the open note, so a single flag covers
  // both and the gap between them never reads as a leave.
  property bool pointerInside: false

  readonly property bool onLeft: Config.onLeft
  readonly property int tabWidth: peeked || openId !== "" ? Config.tabPeek : Config.tabRest
  readonly property int slotStep: Config.tabHeight + Config.tabGap

  // Visible even with no notes: the + at the end of the strip is how you
  // make the first one, so it can never be the thing that is missing.
  visible: active && Store.ready

  WlrLayershell.namespace: "ledge"
  WlrLayershell.layer: Config.layer === "overlay" ? WlrLayer.Overlay : WlrLayer.Top
  // Accept focus from the moment the strip fans out, not only once a note is
  // open.
  //
  // The compositor decides whether to grant keyboard focus at the instant of
  // the click, using whatever this said *then*. Flipping it to OnDemand as a
  // result of the click is too late: clicking the + opened a note that could
  // never be typed into, because at the moment of the press the surface was
  // still refusing focus. A resting strip still takes nothing.
  WlrLayershell.keyboardFocus: (peeked || openId !== "")
                               ? WlrKeyboardFocus.OnDemand
                               : WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  color: "transparent"

  anchors {
    top: true
    bottom: true
    left: win.onLeft
    right: !win.onLeft
  }

  implicitWidth: Config.cardWidth + 32

  mask: Region {
    Region { item: stripMask }
    Region { item: win.openItem }
  }

  // ------------------------------------------------------- state machine

  function scheduleClose() {
    if (win.editing) return
    closeTimer.restart()
  }

  function cancelClose() { closeTimer.stop() }

  function closeNow() {
    var was = win.openId
    win.peeked = false
    win.openId = ""
    win.editing = false
    win.hoveredId = ""
    win.openItem = emptyRegion
    // Discard before flushing, so a note nobody typed into is never written
    // only to be deleted a moment later.
    if (was.length) Store.discardIfBlank(was)
    Store.flushPending()
  }

  function openNote(id) {
    openTimer.stop()
    win.openId = id
    win.peeked = true
    win.cancelClose()
  }

  // Visible (non-archived) model indices, in display order. Drag maths has to
  // run over these rather than raw model indices: an archived note is still a
  // row in the model but occupies no height on screen.
  function visibleIndices() {
    var out = []
    for (var i = 0; i < Store.notes.count; i++) {
      var n = Store.notes.get(i)
      if (!n.archived && !Store.isFloating(n.noteId)) out.push(i)
    }
    return out
  }

  // Where a drag that started on model index `origin` and has travelled `dy`
  // would land, as a position within visibleIndices().
  function dragTargetPos(origin, dy) {
    var vis = win.visibleIndices()
    var pos = vis.indexOf(origin)
    if (pos < 0) return -1
    var moved = pos + Math.round(dy / win.slotStep)
    return Math.max(0, Math.min(vis.length - 1, moved))
  }

  function createNote() {
    var id = Store.create("", "")
    win.openNote(id)
    win.editing = true
    return id
  }

  onPointerInsideChanged: {
    if (pointerInside) {
      cancelClose()
      peekTimer.restart()
    } else {
      peekTimer.stop()
      openTimer.stop()
      scheduleClose()
    }
  }

  onActiveChanged: if (!active) closeNow()

  // External drivers. Only the strip on the wanted output responds, so a
  // keybind does not light up every monitor at once.
  Connections {
    target: Bus
    function onNewRequested() {
      if (!win.active) return
      if (win.openId !== "") win.closeNow()
      else win.createNote()
    }
    function onPeekRequested() {
      if (!win.active) return
      win.peeked = true
      // A CLI or keybind peek has no pointer to keep it alive, so the normal
      // hideDelay would close it again before anyone looked. Hold it open long
      // enough to reach, then fall back to the usual rules.
      holdTimer.restart()
    }
    function onCloseRequested() { win.closeNow() }
    function onOpenRequested(id) {
      if (!win.active) return
      win.openNote(id)
      win.editing = true
    }
  }

  Timer {
    id: peekTimer
    interval: Config.revealDelay
    onTriggered: win.peeked = true
  }

  Timer {
    id: openTimer
    interval: Config.openDelay
    onTriggered: if (win.hoveredId.length) win.openNote(win.hoveredId)
  }

  Timer {
    id: holdTimer
    interval: 2500
    onTriggered: win.scheduleClose()
  }

  Timer {
    id: closeTimer
    interval: Config.hideDelay
    // Re-check rather than trusting the enter/leave pair. A fast cursor across
    // the strip can deliver leave before enter, and without this the strip
    // latches open with nothing under the pointer.
    onTriggered: if (!win.pointerInside && !win.editing) win.closeNow()
  }

  // -------------------------------------------------------------- content

  Item {
    id: content
    anchors.fill: parent

    HoverHandler {
      onHoveredChanged: win.pointerInside = hovered
    }

    // Geometry-only items defining the surface's input region. They paint
    // nothing.
    Item {
      id: stripMask
      width: win.tabWidth
      height: strip.height
      y: strip.y
      x: win.onLeft ? 0 : content.width - width
      Behavior on width { NumberAnimation { duration: 160 } }
    }

    // Stand-in for "no open note". A Region pointed at a null item covers the
    // whole surface, which is the opposite of what is wanted here.
    Item {
      id: emptyRegion
      width: 0
      height: 0
    }

    // ------------------------------------------------------------ strip

    Flickable {
      id: strip

      width: content.width
      x: 0
      height: Math.min(contentHeight,
                       content.height - Config.topMargin - Config.bottomMargin)
      y: Math.max(Config.topMargin, (content.height - contentHeight) / 2)

      contentWidth: width
      contentHeight: column.height
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height && win.openId === ""
      // Clipping would cut an open note off at the strip's edge, so it is only
      // on when the strip actually scrolls and nothing is open.
      clip: interactive

      Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      Column {
        id: column
        width: strip.width
        spacing: Config.tabGap

        Repeater {
          model: Store.notes

          // A fixed-height slot. The note inside may render taller than its
          // slot when open, overlapping its neighbours rather than shoving
          // them down the screen.
          delegate: Item {
            id: slot
            required property int index
            required property string noteId
            required property string color
            required property string body
            required property string title
            required property bool archived
            required property bool pinned

            width: column.width
            readonly property bool hidden: archived || Store.isFloating(noteId)
            height: hidden ? 0 : Config.tabHeight
            visible: !hidden
            z: noteItem.open ? 20 : (column.dragOrigin === index ? 15 : 0)

            // How far this note steps aside to open a gap where the dragged
            // note will land. Zero unless a drag is in flight and this note
            // sits between the drag's origin and its current target.
            readonly property real dragShift: {
              if (column.dragOrigin < 0 || column.dragOrigin === index) return 0
              var vis = win.visibleIndices()
              var origin = vis.indexOf(column.dragOrigin)
              var target = win.dragTargetPos(column.dragOrigin, column.dragDy)
              var mine = vis.indexOf(index)
              if (origin < 0 || target < 0 || mine < 0) return 0
              if (mine > origin && mine <= target) return -win.slotStep
              if (mine < origin && mine >= target) return win.slotStep
              return 0
            }

            Note {
              id: noteItem

              noteId: slot.noteId
              colorKey: slot.color
              label: Store.deriveTitle(slot.body, slot.title)
              body: slot.body
              pinned: slot.pinned
              index: slot.index

              peeked: win.peeked
              open: win.openId === slot.noteId
              editing: open && win.editing

              // Grows away from the screen edge, so the anchored side stays put.
              anchors.right: win.onLeft ? undefined : parent.right
              anchors.left: win.onLeft ? parent.left : undefined

              // Three cases: the note being dragged follows the pointer, its
              // neighbours slide out of the way to show where it will land, and
              // an open note lifts off the bottom of the screen if it would
              // otherwise run past the edge.
              y: {
                if (column.dragOrigin === slot.index) return column.dragDy
                if (column.dragOrigin >= 0) return slot.dragShift
                if (!open) return 0
                var top = strip.y - strip.contentY + slot.y
                var overflow = (top + height) - (content.height - 8)
                return overflow > 0 ? -Math.min(overflow, top - 8) : 0
              }

              // The dragged note must track the pointer exactly; everything
              // else eases into its new slot.
              Behavior on y {
                enabled: column.dragOrigin !== slot.index
                NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
              }

              // Hand the item itself over rather than a snapshot of where it
              // was. The identity check stops a note that is closing from
              // clearing the region belonging to the note that just replaced
              // it, since the two changes arrive in that order.
              onOpenChanged: {
                if (open) win.openItem = noteItem
                else if (win.openItem === noteItem) win.openItem = emptyRegion
              }

              onEntered: {
                win.hoveredId = slot.noteId
                // Once one note is open, sliding along the strip swaps to the
                // next immediately. Waiting out the dwell again feels broken.
                if (win.openId !== "" && win.openId !== slot.noteId) win.openNote(slot.noteId)
                else openTimer.restart()
              }
              onActivated: {
                if (win.openId === slot.noteId) win.editing = true
                else { win.openNote(slot.noteId); win.editing = true }
              }
              onEditingRequested: win.editing = true
              onDismissed: win.closeNow()
              onDeleteRequested: {
                var id = slot.noteId
                win.closeNow()
                Store.remove(id)
              }
              onPopOutRequested: {
                var id = slot.noteId
                // Detach roughly where the note already is, in global
                // coordinates, so it does not teleport when it comes off the
                // edge. Inset from the strip so it clearly reads as detached.
                var top = strip.y - strip.contentY + slot.y
                var localX = win.onLeft
                  ? Config.tabPeek + 40
                  : win.screen.width - Config.cardWidth - Config.tabPeek - 40
                Bus.popRequested(id,
                                 win.screen.x + Math.max(20, localX),
                                 win.screen.y + Math.max(20, top))
                win.closeNow()
              }

              // Reordering the model mid-drag would rebind this very delegate
              // to a different note, and the pointer grab would carry on
              // dragging whatever landed underneath it. So the drag only moves
              // pixels; the model is not touched until the drop.
              onDragStarted: {
                column.dragOrigin = slot.index
                column.dragDy = 0
                openTimer.stop()
                win.cancelClose()
              }
              onDragMoved: function (dy) {
                if (column.dragOrigin < 0) return
                column.dragDy = dy
              }
              onDragEnded: {
                var origin = column.dragOrigin
                var dy = column.dragDy
                column.dragOrigin = -1
                column.dragDy = 0
                if (origin < 0) return
                var vis = win.visibleIndices()
                var from = vis.indexOf(origin)
                var to = win.dragTargetPos(origin, dy)
                if (to >= 0 && to !== from) Store.move(origin, vis[to])
              }
            }
          }
        }

        // New note. Deliberately part of the strip rather than a floating
        // button: the strip is the only thing the pointer ever goes looking
        // for, so the way to add a note has to live there too. Half height, so
        // it reads as an action rather than as another note.
        Item {
          id: adder
          width: column.width
          height: Math.round(Config.tabHeight * 0.42)

          Rectangle {
            id: adderBody
            width: win.tabWidth
            height: parent.height
            radius: Math.min(9, height / 2)
            anchors.right: win.onLeft ? undefined : parent.right
            anchors.left: win.onLeft ? parent.left : undefined

            color: Theme.withAlpha(Theme.accent,
                                   adderHover.hovered ? 0.95 : (win.peeked ? 0.7 : 0.4))
            Behavior on color { ColorAnimation { duration: 150 } }
            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            // Square off the screen-facing side, same as a note.
            Rectangle {
              color: adderBody.color
              width: adderBody.radius
              height: parent.height
              anchors.right: win.onLeft ? undefined : parent.right
              anchors.left: win.onLeft ? parent.left : undefined
            }

            Text {
              anchors.centerIn: parent
              text: "+"
              font.family: Theme.fontFamily
              font.pixelSize: 14
              color: Theme.mix(Theme.accent, Theme.dark ? "#000000" : "#ffffff", 0.75)
              opacity: win.peeked ? 1 : 0
              visible: opacity > 0.01
              Behavior on opacity { NumberAnimation { duration: 150 } }
            }
          }

          HoverHandler {
            id: adderHover
            onHoveredChanged: if (hovered) { win.hoveredId = ""; openTimer.stop() }
          }

          TapHandler { onTapped: win.createNote() }
        }

        property int dragOrigin: -1
        property real dragDy: 0
      }
    }
  }
}
