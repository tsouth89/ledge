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
  property bool editing: false
  property bool dragging: false

  signal entered()
  signal activated()
  signal dismissed()
  signal editingRequested()
  signal dragStarted()
  signal dragMoved(real dy)
  signal dragEnded()

  readonly property color tint: Theme.tabColor(colorKey)
  readonly property color paperColor: Theme.cardColor(colorKey)
  readonly property color ink: Theme.cardTextColor(colorKey)

  // Which side faces the screen edge. The band lives there and the note grows
  // away from it, so the anchored side never moves.
  readonly property bool bandRight: !Config.onLeft
  readonly property int pad: 12
  readonly property int bandWidth: 6
  readonly property int radius: 9

  readonly property int openHeight: Math.max(Config.cardMinHeight,
                                             Math.min(Config.cardMaxHeight,
                                                      Math.ceil(editor.contentHeight) + actions.height + 6 + pad * 2))

  implicitWidth: open ? Config.cardWidth : (peeked ? Config.tabPeek : Config.tabRest)
  implicitHeight: open ? openHeight : Config.tabHeight

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
    }
  }

  MultiEffect {
    source: paper
    anchors.fill: paper
    shadowEnabled: true
    shadowColor: Qt.rgba(0, 0, 0, Theme.dark ? 0.5 : 0.18)
    shadowBlur: 0.8
    shadowVerticalOffset: 4
    opacity: note.open ? 1 : 0
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

    Item {
      id: actions
      width: parent.width
      height: 14

      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: 9
        opacity: hover.hovered ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Repeater {
          model: [
            { glyph: "", act: "pin" },
            { glyph: "", act: "archive" },
            { glyph: "", act: "delete" }
          ]
          delegate: Text {
            required property var modelData
            text: modelData.glyph
            font.family: Theme.fontFamily
            font.pixelSize: 11
            color: Theme.withAlpha(note.ink, hit.containsMouse ? 1.0 : 0.4)

            MouseArea {
              id: hit
              anchors.fill: parent
              anchors.margins: -4
              hoverEnabled: true
              onClicked: {
                if (modelData.act === "pin") Store.togglePinned(note.noteId)
                else if (modelData.act === "archive") { Store.toggleArchived(note.noteId); note.dismissed() }
                else { Store.remove(note.noteId); note.dismissed() }
              }
            }
          }
        }
      }

      Rectangle {
        width: 10; height: 10; radius: 5
        color: note.tint
        opacity: hover.hovered ? 1 : 0
        visible: opacity > 0.01
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        Behavior on opacity { NumberAnimation { duration: 150 } }

        MouseArea {
          anchors.fill: parent
          anchors.margins: -4
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
        enabled: note.open

        text: note.body
        // Guard against the model write coming back around and moving the
        // cursor while this same note is still being typed into.
        property string boundId: note.noteId
        onTextChanged: if (boundId === note.noteId) Store.setBody(note.noteId, text)

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

        focus: note.editing
        onActiveFocusChanged: if (activeFocus) note.editingRequested()

        Keys.onEscapePressed: {
          Store.flushPending()
          note.dismissed()
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
    enabled: !note.open
    onTapped: note.activated()
  }

  DragHandler {
    enabled: !note.open
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
