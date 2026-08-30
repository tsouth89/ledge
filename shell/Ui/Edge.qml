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

  // Geometry of the open note, published by whichever slot owns it. Used to
  // carve that note out of the input region; a plain property keeps the
  // binding reactive where mapToItem would be a one-shot.
  property real openY: 0
  property real openH: 0

  // The input region below is the hit test. Anything the pointer can reach on
  // this surface is either the strip or the open note, so a single flag covers
  // both and the gap between them never reads as a leave.
  property bool pointerInside: false

  readonly property bool onLeft: Config.onLeft
  readonly property int tabWidth: peeked || openId !== "" ? Config.tabPeek : Config.tabRest
  readonly property int slotStep: Config.tabHeight + Config.tabGap

  visible: active && Store.ready && Store.liveCount > 0

  WlrLayershell.namespace: "ledge"
  WlrLayershell.layer: Config.layer === "overlay" ? WlrLayer.Overlay : WlrLayer.Top
  // Focus only while a note is open, so a stray click on the resting strip can
  // never pull keyboard focus off the window underneath.
  WlrLayershell.keyboardFocus: openId !== "" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
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
    Region { item: openMask }
  }

  // ------------------------------------------------------- state machine

  function scheduleClose() {
    if (win.editing) return
    closeTimer.restart()
  }

  function cancelClose() { closeTimer.stop() }

  function closeNow() {
    win.peeked = false
    win.openId = ""
    win.editing = false
    win.hoveredId = ""
    Store.flushPending()
  }

  function openNote(id) {
    openTimer.stop()
    win.openId = id
    win.peeked = true
    win.cancelClose()
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
    function onPeekRequested() { if (win.active) { win.peeked = true; win.scheduleClose() } }
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

    Item {
      id: openMask
      width: win.openId !== "" ? Config.cardWidth : 0
      height: win.openId !== "" ? win.openH : 0
      y: win.openY
      x: win.onLeft ? 0 : content.width - width
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
            height: archived ? 0 : Config.tabHeight
            visible: !archived
            z: noteItem.open ? 20 : 0

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

              // Lift the note off the bottom of the screen when opening it
              // would otherwise run past the edge.
              y: {
                if (!open) return 0
                var top = strip.y - strip.contentY + slot.y
                var overflow = (top + height) - (content.height - 8)
                return overflow > 0 ? -Math.min(overflow, top - 8) : 0
              }

              onYChanged: if (open) win.openY = strip.y - strip.contentY + slot.y + y
              onHeightChanged: if (open) win.openH = height
              onOpenChanged: {
                if (!open) return
                win.openY = strip.y - strip.contentY + slot.y + y
                win.openH = height
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

              onDragStarted: {
                column.dragOrigin = slot.index
                openTimer.stop()
                win.cancelClose()
              }
              onDragMoved: function (dy) {
                if (column.dragOrigin < 0) return
                var target = column.dragOrigin + Math.round(dy / win.slotStep)
                target = Math.max(0, Math.min(Store.notes.count - 1, target))
                if (target !== slot.index) Store.move(slot.index, target)
              }
              onDragEnded: column.dragOrigin = -1
            }
          }
        }

        property int dragOrigin: -1
      }
    }
  }
}
