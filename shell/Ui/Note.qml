import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import qs.Core

// One note, in all three of its states.
//
// There is no separate card. The dash on the edge *is* the note: it widens,
// grows to fit its text, and its solid colour retreats to a band down the edge
// as the paper appears underneath. Rest, peek and open are the same rectangle
// at three sizes, so nothing ever slides out from behind anything else.
Item {
  id: note

  required property string noteId
  required property string colorKey
  required property string label
  required property string body
  required property bool pinned
  required property int index

  property bool peeked: false
  property bool open: false
  // A popped-out note. Always open, never part of the strip, and dragged by
  // its colour band rather than reordered.
  property bool floating: false
  property bool editing: false
  property bool dragging: false

  signal entered()
  signal activated()
  signal dismissed()
  signal editingRequested()
  signal popOutRequested()
  signal dockRequested()
  signal floatDragged(real dx, real dy)
  signal floatDragEnded()

  // DragHandler reports cumulative translation; the store wants deltas. Shared
  // so the band and the header behave identically.
  property real dragLastX: 0
  property real dragLastY: 0
  function beginFloatDrag() { note.dragLastX = 0; note.dragLastY = 0 }
  function stepFloatDrag(tx, ty) {
    note.floatDragged(tx - note.dragLastX, ty - note.dragLastY)
    note.dragLastX = tx
    note.dragLastY = ty
  }
  signal deleteRequested()
  signal dragStarted()
  signal dragMoved(real dy)
  signal dragEnded()

  readonly property color tint: Theme.tabColor(colorKey)
  readonly property color paperColor: Theme.cardColor(colorKey)
  readonly property color ink: Theme.cardTextColor(colorKey)

  // Which side faces the screen edge. The band lives there and the note grows
  // away from it, so the anchored side never moves.
  readonly property bool bandRight: floating ? false : !Config.onLeft
  readonly property int pad: 12
  readonly property int bandWidth: 6
  readonly property int radius: 9

  readonly property int openHeight: Math.max(Config.cardMinHeight,
                                             Math.min(Config.cardMaxHeight,
                                                      Math.ceil(editor.contentHeight) + actions.height + 6 + pad * 2))

  implicitWidth: floating || open ? Config.cardWidth : (peeked ? Config.tabPeek : Config.tabRest)
  implicitHeight: floating || open ? openHeight : Config.tabHeight

  // Staggered on the way out so the strip unfurls in sequence rather than
  // snapping open as a block. That pause is what reads as "reaching for it".
  // Opening overshoots very slightly and settles. Easing straight to a stop is
  // what made this read as a UI panel sliding out rather than a note being
  // pulled open, and it is the whole difference between "sleek" and physical.
  readonly property int growMs: 260

  Behavior on implicitWidth {
    enabled: !note.dragging
    SequentialAnimation {
      PauseAnimation { duration: note.open || !note.peeked ? 0 : Math.min(note.index, 8) * 16 }
      NumberAnimation {
        duration: note.growMs
        easing.type: note.open ? Easing.OutBack : Easing.OutCubic
        easing.overshoot: 1.08
      }
    }
  }
  Behavior on implicitHeight {
    NumberAnimation {
      duration: note.growMs
      easing.type: note.open ? Easing.OutBack : Easing.OutCubic
      easing.overshoot: 1.05
    }
  }

  // ------------------------------------------------------------- surface

  Rectangle {
    id: paper
    anchors.fill: parent
    radius: note.radius
    // Always the paper colour. When collapsed the band covers the whole note,
    // so the dash still reads as solid tint; opening uncovers what was already
    // there instead of recolouring it. Nothing cross-fades.
    color: note.paperColor
    Behavior on color { ColorAnimation { duration: 220 } }

    // Square off the screen-facing side so the note is attached to the edge
    // rather than floating as a pill.
    Rectangle {
      color: paper.color
      width: note.radius
      height: parent.height
      anchors.right: note.bandRight ? parent.right : undefined
      anchors.left: note.bandRight ? parent.left : undefined
    }

    // A hair of top-down sheen. Real paper is never one flat value, and a
    // completely flat fill is the other half of what reads as chrome.
    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      opacity: note.open ? 1 : 0
      visible: opacity > 0.01
      Behavior on opacity { NumberAnimation { duration: 240 } }
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.055) }
        GradientStop { position: 0.55; color: Qt.rgba(1, 1, 1, 0.012) }
        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.07) }
      }
    }

    // The band. Full width when collapsed (invisible as a distinct thing),
    // shrinking to a stripe as the note opens.
    Rectangle {
      id: band
      width: note.open ? note.bandWidth : parent.width
      height: parent.height
      color: note.tint
      radius: note.radius
      anchors.right: note.bandRight ? parent.right : undefined
      anchors.left: note.bandRight ? undefined : parent.left

      Behavior on width {
        NumberAnimation {
          duration: note.growMs
          easing.type: note.open ? Easing.OutBack : Easing.OutCubic
          easing.overshoot: 1.08
        }
      }
      Behavior on color { ColorAnimation { duration: 220 } }

      Rectangle {
        color: band.color
        width: note.radius
        height: parent.height
        anchors.right: note.bandRight ? parent.right : undefined
        anchors.left: note.bandRight ? parent.left : undefined
      }

      // Secondary grab handle. The header is the main one; the band is here
      // because it is the obvious thing to reach for on a note that is mostly
      // text.
      DragHandler {
        enabled: note.floating
        target: null
        cursorShape: Qt.SizeAllCursor
        onActiveChanged: active ? note.beginFloatDrag() : note.floatDragEnded()
        onTranslationChanged: if (active) note.stepFloatDrag(translation.x, translation.y)
      }
    }
  }

  MultiEffect {
    source: paper
    anchors.fill: paper
    shadowEnabled: true
    shadowColor: Qt.rgba(0, 0, 0, Theme.dark ? 0.5 : 0.18)
    shadowBlur: 0.8
    shadowVerticalOffset: 4
    opacity: note.open || note.floating ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 200 } }
    z: -1
  }

  // --------------------------------------------------------- collapsed

  Item {
    anchors.fill: parent
    clip: true
    opacity: note.peeked && !note.open ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 150 } }

    Text {
      anchors.centerIn: parent
      rotation: -90
      width: note.height - 14
      text: note.label
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      font.family: Theme.fontFamily
      font.pixelSize: Math.max(9, Theme.fontBase - 3)
      font.letterSpacing: 0.8
      font.capitalization: Font.AllUppercase
      color: Theme.mix(note.tint, Theme.dark ? "#000000" : "#ffffff", 0.72)
    }
  }

  // Pinned notes carry a notch so the strip still says something at rest.
  Rectangle {
    visible: note.pinned && !note.open
    width: 3; height: 3; radius: 1.5
    color: Theme.mix(note.tint, Theme.dark ? "#000000" : "#ffffff", 0.6)
    anchors.verticalCenter: parent.verticalCenter
    anchors.right: note.bandRight ? parent.right : undefined
    anchors.left: note.bandRight ? undefined : parent.left
    anchors.margins: 3
  }

  // -------------------------------------------------------------- open

  Column {
    id: layout
    anchors.fill: parent
    anchors.margins: note.pad
    anchors.rightMargin: note.pad + (note.bandRight ? note.bandWidth : 0)
    anchors.leftMargin: note.pad + (note.bandRight ? 0 : note.bandWidth)
    spacing: 6

    opacity: note.open ? 1 : 0
    visible: opacity > 0.01
    // Held back until the note is most of the way open, so the text never
    // appears compressed inside a rectangle that is still growing.
    Behavior on opacity {
      SequentialAnimation {
        PauseAnimation { duration: note.open ? Math.round(note.growMs * 0.45) : 0 }
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
      }
    }

    // Controls. Visible the whole time the note is open, not on hover.
    //
    // These were hover-only and unlabelled, which meant there was no way to
    // discover that a note could be deleted at all. A control you cannot find
    // is a missing feature.
    Item {
      id: actions
      width: parent.width
      height: 16

      // The whole header strip drags a popped-out note, not just the 6px band.
      // Extended up and out into the note's padding so the grab area is a
      // comfortable target rather than a hairline, and sitting behind the
      // controls so their clicks still land.
      Item {
        anchors.fill: parent
        anchors.topMargin: -note.pad
        anchors.leftMargin: -note.pad
        anchors.rightMargin: -note.pad
        z: -1

        DragHandler {
          enabled: note.floating
          target: null
          cursorShape: Qt.SizeAllCursor
          onActiveChanged: active ? note.beginFloatDrag() : note.floatDragEnded()
          onTranslationChanged: if (active) note.stepFloatDrag(translation.x, translation.y)
        }
      }

      property string hint: ""
      // Deleting takes two clicks. The note does go to the trash rather than
      // being unlinked, but it still vanishes from the screen, and a stray
      // click on a 12px target should not make anything disappear.
      property bool deleteArmed: false

      Timer {
        id: disarm
        interval: 2600
        onTriggered: { actions.deleteArmed = false; if (actions.hint === "Click again") actions.hint = "" }
      }

      Row {
        id: controls
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10

        Repeater {
          model: [
            { glyph: note.floating ? "\uf2d2" : "\uf08e",
              act: "pop",
              tip: note.floating ? "Dock" : "Pop out" },
            { glyph: "\uf08d", act: "pin",     tip: "Pin" },
            { glyph: "\uf187", act: "archive", tip: "Archive" },
            { glyph: "\uf1f8", act: "delete",  tip: "Delete" }
          ]
          delegate: Text {
            required property var modelData
            text: modelData.glyph
            font.family: Theme.fontFamily
            font.pixelSize: 12
            color: {
              if (modelData.act === "delete" && actions.deleteArmed) return Theme.urgent
              var lit = hit.containsMouse ? 1.0
                        : (modelData.act === "pin" && note.pinned ? 0.85 : 0.42)
              return Theme.withAlpha(note.ink, lit)
            }

            MouseArea {
              id: hit
              anchors.fill: parent
              anchors.margins: -5
              hoverEnabled: true
              onEntered: actions.hint = actions.deleteArmed && modelData.act === "delete"
                                        ? "Click again" : modelData.tip
              onExited: if (actions.hint === modelData.tip) actions.hint = ""
              onClicked: {
                if (modelData.act === "pop") {
                  if (note.floating) note.dockRequested()
                  else note.popOutRequested()
                  return
                }
                if (modelData.act === "pin") { Store.togglePinned(note.noteId); return }
                if (modelData.act === "archive") { Store.toggleArchived(note.noteId); note.dismissed(); return }
                if (!actions.deleteArmed) {
                  actions.deleteArmed = true
                  actions.hint = "Click again"
                  disarm.restart()
                  return
                }
                disarm.stop()
                actions.deleteArmed = false
                note.deleteRequested()
              }
            }
          }
        }
      }

      // Names the control under the cursor. Cheaper than a floating tooltip
      // and it cannot fall off the edge of the screen.
      Text {
        anchors.left: controls.right
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        text: actions.hint
        font.family: Theme.fontFamily
        font.pixelSize: 10
        color: Theme.withAlpha(note.ink, 0.55)
        opacity: actions.hint.length ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      Rectangle {
        width: 10; height: 10; radius: 5
        color: note.tint
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          anchors.fill: parent
          anchors.margins: -5
          hoverEnabled: true
          onEntered: actions.hint = "Colour"
          onExited: if (actions.hint === "Colour") actions.hint = ""
          onClicked: {
            var keys = Theme.swatchKeys
            Store.setColor(note.noteId, keys[(keys.indexOf(note.colorKey) + 1) % keys.length])
          }
        }
      }
    }

    Flickable {
      id: scroller
      width: parent.width
      height: Math.max(0, layout.height - actions.height - layout.spacing)
      contentHeight: editor.contentHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      TextArea {
        id: editor
        width: scroller.width
        enabled: note.open || note.floating

        Component.onCompleted: loadFrom(note.noteId)

        // Deliberately NOT `text: note.body`.
        //
        // Delegates are recycled: when the model reorders or a note is
        // discarded, this same editor gets rebound to a different note. With a
        // declarative binding the editor's contents and the note it believes it
        // is editing update in the same batch, so a guard written as another
        // binding is worthless -- both sides change together and the stale text
        // gets written to the new note's id. That is how a note ended up
        // holding one note's keystrokes concatenated with another's body.
        //
        // So the load is explicit and one-way, and write-back is suppressed
        // while it happens.
        property string boundId: ""
        property bool syncing: false

        function loadFrom(id) {
          syncing = true
          boundId = id
          var n = id.length ? Store.get(id) : null
          text = n ? String(n.body || "") : ""
          syncing = false
        }

        onTextChanged: {
          if (syncing || boundId !== note.noteId) return
          Store.setBody(note.noteId, text)
        }

        wrapMode: TextEdit.Wrap
        textFormat: TextEdit.PlainText
        selectByMouse: true
        persistentSelection: true

        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontBase
        color: note.ink
        selectionColor: Theme.withAlpha(note.tint, 0.45)
        selectedTextColor: note.ink
        placeholderText: "Write something"
        placeholderTextColor: Theme.withAlpha(note.ink, 0.35)

        background: null
        padding: 0

        focus: note.editing || note.floating
        onActiveFocusChanged: if (activeFocus) note.editingRequested()

        Keys.onEscapePressed: {
          Store.flushPending()
          note.dismissed()
        }

        // Rebind when this delegate is handed a different note, and pick up
        // edits made to the file by anything else -- but never yank text out
        // from under a caret that is currently in it.
        Connections {
          target: note
          function onNoteIdChanged() { editor.loadFrom(note.noteId) }
          function onBodyChanged() {
            if (editor.boundId !== note.noteId) { editor.loadFrom(note.noteId); return }
            if (!editor.activeFocus && editor.text !== note.body) editor.loadFrom(note.noteId)
          }
        }

        // Toggle a `- [ ]` checkbox by clicking its marker. Pure text editing,
        // so the file on disk stays exactly what was typed.
        TapHandler {
          onTapped: function (point) {
            var pos = editor.positionAt(point.position.x, point.position.y)
            var text = editor.text
            var lineStart = text.lastIndexOf("\n", Math.max(0, pos - 1)) + 1
            var lineEnd = text.indexOf("\n", pos)
            if (lineEnd < 0) lineEnd = text.length
            var line = text.slice(lineStart, lineEnd)

            var box = line.match(/^(\s*[-*]\s*\[)([ xX])(\])/)
            if (!box) return
            if (pos - lineStart > box[0].length + 1) return

            var flipped = box[2] === " " ? "x" : " "
            var updated = line.replace(/^(\s*[-*]\s*\[)([ xX])(\])/, "$1" + flipped + "$3")
            var caret = editor.cursorPosition
            editor.text = text.slice(0, lineStart) + updated + text.slice(lineEnd)
            editor.cursorPosition = caret
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ input

  HoverHandler {
    id: hover
    onHoveredChanged: if (hovered) note.entered()
  }

  TapHandler {
    // Let the editor own the pointer once the note is open, so clicking into
    // the text places the caret instead of re-triggering the open.
    enabled: !note.open && !note.floating
    onTapped: note.activated()
  }

  DragHandler {
    enabled: !note.open && !note.floating
    yAxis.enabled: true
    xAxis.enabled: false
    target: null
    onActiveChanged: {
      if (active) { note.dragging = true; note.dragStarted() }
      else { note.dragging = false; note.dragEnded() }
    }
    onTranslationChanged: if (active) note.dragMoved(translation.y)
  }
}
