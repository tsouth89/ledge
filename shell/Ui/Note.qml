import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import qs.Core
import "../Core/Markup.js" as Markup

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
  // Per-note override for markdown styling, from `styled: false` frontmatter.
  property bool styledNote: true

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
  // Moving and resizing a popped-out note are handed to the compositor rather
  // than driven from here. See Float.qml for why.
  signal floatMoveRequested()
  signal floatResizeRequested(int edges)
  signal deleteRequested()
  signal dragStarted()
  signal dragMoved(real dy)
  signal dragEnded()

  // Read straight off the store rather than passed in, so a reminder set from
  // the CLI lights the control up without the strip being rebuilt.
  readonly property string reminderAt: {
    var n = Store.get(noteId)
    return n ? String(n.reminder || "") : ""
  }
  readonly property bool hasReminder: reminderAt.length > 0

  readonly property color tint: Theme.tabColor(colorKey)
  readonly property color paperColor: Theme.cardColor(colorKey)
  readonly property color ink: Theme.cardTextColor(colorKey)

  // Which side faces the screen edge. The band lives there and the note grows
  // away from it, so the anchored side never moves.
  readonly property bool bandRight: floating ? false : !Config.onLeft
  readonly property int pad: 12
  readonly property int bandWidth: 6
  readonly property int radius: 9

  readonly property var attachments: Store.attachmentsFor(noteId)
  readonly property int attachHeight: attachments.length ? 48 : 0

  readonly property int openHeight: Math.max(Config.cardMinHeight,
                                             Math.min(Config.cardMaxHeight,
                                                      Math.ceil(editor.contentHeight) + actions.height
                                                      + attachHeight + 6 + pad * 2))

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
      // index goes to -1 while a delegate is being torn down, and a negative
      // duration is an error rather than a no-op.
      PauseAnimation {
        duration: note.open || !note.peeked ? 0 : Math.max(0, Math.min(note.index, 8)) * 16
      }
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
      MouseArea {
        anchors.fill: parent
        enabled: note.floating
        cursorShape: Qt.SizeAllCursor
        onPressed: note.floatMoveRequested()
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

    // Set in the note's own case at close to body size, not shouted in 9px
    // capitals. Rotating text already costs legibility; all-caps takes more
    // width per character on top of that, so the label ran out of room and
    // elided sooner as well as being harder to read.
    Text {
      anchors.centerIn: parent
      rotation: -90
      width: note.height - 12
      text: note.label
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      font.family: Theme.fontFamily
      font.pixelSize: Math.max(10, Theme.fontBase - 1)
      font.weight: Font.DemiBold
      font.letterSpacing: 0.2
      color: Theme.tabTextColor(note.colorKey)
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
      MouseArea {
        anchors.fill: parent
        anchors.topMargin: -note.pad
        anchors.leftMargin: -note.pad
        anchors.rightMargin: -note.pad
        z: -1
        enabled: note.floating
        cursorShape: Qt.SizeAllCursor
        onPressed: note.floatMoveRequested()
      }

      property string hint: ""
      // Deleting takes two clicks. The note does go to the trash rather than
      // being unlinked, but it still vanishes from the screen, and a stray
      // click on a 12px target should not make anything disappear.
      property bool deleteArmed: false
      // Swaps the control row for a row of reminder choices. Inline rather than
      // a popup: a note is already a small surface, and a menu floating off one
      // would need its own input region on the strip's layer.
      property bool pickingReminder: false
      // Same inline treatment as the reminder chooser: the control row is
      // swapped for the choices rather than opening a menu, which on the strip
      // would need an input region of its own.
      property bool pickingColour: false

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
        visible: !actions.pickingReminder && !actions.pickingColour

        Repeater {
          model: [
            { glyph: note.floating ? "\uf2d2" : "\uf08e",
              act: "pop",
              tip: note.floating ? "Dock" : "Pop out" },
            { glyph: "\uf08d", act: "pin",     tip: "Pin" },
            { glyph: "\uf187", act: "archive", tip: "Archive" },
            { glyph: "\uf1f8", act: "delete",  tip: "Delete" },
            { glyph: "\uf017", act: "remind",  tip: "Remind me" }
          ]
          delegate: Text {
            required property var modelData
            text: modelData.glyph
            font.family: Theme.fontFamily
            font.pixelSize: 12
            color: {
              if (modelData.act === "delete" && actions.deleteArmed) return Theme.urgent
              if (modelData.act === "remind" && note.hasReminder) return note.tint
              var lit = hit.containsMouse ? 1.0
                        : (modelData.act === "pin" && note.pinned ? 0.85 : 0.42)
              return Theme.withAlpha(note.ink, lit)
            }

            MouseArea {
              id: hit
              anchors.fill: parent
              anchors.margins: -5
              hoverEnabled: true
              onEntered: {
                if (modelData.act === "delete" && actions.deleteArmed) actions.hint = "Click again"
                else if (modelData.act === "remind" && note.hasReminder)
                  actions.hint = Store.relativeFuture(note.reminderAt) + " (click to clear)"
                else actions.hint = modelData.tip
              }
              onExited: if (actions.hint === modelData.tip) actions.hint = ""
              onClicked: {
                if (modelData.act === "pop") {
                  if (note.floating) note.dockRequested()
                  else note.popOutRequested()
                  return
                }
                if (modelData.act === "pin") { Store.togglePinned(note.noteId); return }
                if (modelData.act === "archive") { Store.toggleArchived(note.noteId); note.dismissed(); return }
                if (modelData.act === "remind") {
                  if (note.hasReminder) Store.setReminder(note.noteId, "")
                  else actions.pickingReminder = true
                  return
                }
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

      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        visible: actions.pickingReminder

        Repeater {
          model: [
            { label: "15m",  mins: 15 },
            { label: "1h",   mins: 60 },
            { label: "3h",   mins: 180 },
            { label: "9am",  mins: -1 },
            { label: "\u00d7", mins: 0 }
          ]
          delegate: Rectangle {
            required property var modelData
            width: chipLabel.width + 10
            height: 15
            radius: 4
            color: Theme.withAlpha(note.ink, chipHit.containsMouse ? 0.22 : 0.10)

            Text {
              id: chipLabel
              anchors.centerIn: parent
              text: modelData.label
              font.family: Theme.fontFamily
              font.pixelSize: 9
              color: Theme.withAlpha(note.ink, 0.85)
            }

            MouseArea {
              id: chipHit
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                actions.pickingReminder = false
                if (modelData.mins === 0) return
                if (modelData.mins < 0) {
                  // Next 9am, today if it has not happened yet.
                  var d = new Date()
                  d.setSeconds(0, 0)
                  if (d.getHours() >= 9) d.setDate(d.getDate() + 1)
                  d.setHours(9, 0, 0, 0)
                  Store.setReminder(note.noteId, d.toISOString())
                  return
                }
                Store.setReminder(note.noteId,
                                  new Date(Date.now() + modelData.mins * 60000).toISOString())
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

      // The whole palette, not the next one along. Cycling through eight is
      // fine for the second colour and tedious for the one you actually want.
      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: 7
        visible: actions.pickingColour

        Repeater {
          model: Theme.swatchKeys
          delegate: Rectangle {
            required property string modelData
            width: 13; height: 13
            radius: 6.5
            color: Theme.tabColor(modelData)
            border.width: modelData === note.colorKey ? 2 : 0
            border.color: Theme.withAlpha(note.ink, 0.9)

            MouseArea {
              anchors.fill: parent
              anchors.margins: -2
              hoverEnabled: true
              onEntered: actions.hint = Theme.swatchLabels[modelData] || modelData
              onExited: actions.hint = ""
              onClicked: {
                Store.setColor(note.noteId, modelData)
                actions.pickingColour = false
                actions.hint = ""
              }
            }
          }
        }
      }

      Rectangle {
        width: 10; height: 10; radius: 5
        color: note.tint
        visible: !actions.pickingColour
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          anchors.fill: parent
          anchors.margins: -5
          hoverEnabled: true
          onEntered: actions.hint = "Colour"
          onExited: if (actions.hint === "Colour") actions.hint = ""
          onClicked: {
            actions.pickingReminder = false
            actions.pickingColour = true
          }
        }
      }
    }

    // Whether this note paints its markdown. Off entirely in a proportional
    // font: the styled layer only lines up with the editor above it while bold
    // and regular share an advance width.
    readonly property bool styled: Config.styling && note.styledNote

    Flickable {
      id: scroller
      width: parent.width
      height: Math.max(0, layout.height - actions.height - attachRow.height
                          - layout.spacing * (attachRow.height > 0 ? 2 : 1))
      contentHeight: editor.contentHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      // The styled layer. Sits behind a transparent editor holding the real
      // text, matching it glyph for glyph, so what you see is formatted and
      // what you edit is still exactly the characters you typed. No modes.
      Text {
        id: styledLayer
        width: scroller.width
        visible: layout.styled
        textFormat: Text.RichText
        wrapMode: editor.wrapMode
        font: editor.font
        color: note.ink
        text: visible ? "<div style='white-space:pre-wrap'>"
                        + Markup.toHtml(editor.text, {
                            marker: Theme.withAlpha(note.ink, 0.38),
                            strong: Theme.withAlpha(note.ink, 1.0),
                            link: note.tint,
                            code: note.tint,
                            accent: note.tint
                          })
                        + "</div>"
                      : ""
      }

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
          var n = id.length ? Store.get(id) : null

          // A row that exists but has not been read off disk yet carries an
          // empty body that means "not known", not "empty". Loading from it
          // would blank an editor that already has the note's real text in it.
          // Leave `boundId` alone too, so write-back stays blocked until the
          // content actually arrives and this runs again.
          if (n && !n.loaded && !n.pending && editor.text.length > 0) return

          syncing = true
          boundId = id
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
        // Transparent when the styled layer is showing the text instead. The
        // selection colour has to stay translucent for the same reason: an
        // opaque highlight would paint over the layer underneath and blank the
        // words being selected.
        color: layout.styled ? "transparent" : note.ink
        selectionColor: Theme.withAlpha(note.tint, layout.styled ? 0.32 : 0.45)
        selectedTextColor: layout.styled ? "transparent" : note.ink

        // The caret takes its colour from `color`, which is transparent above,
        // so it has to be drawn explicitly or it disappears.
        cursorDelegate: Rectangle {
          visible: editor.activeFocus
          width: 1
          color: note.ink
          Timer {
            running: editor.activeFocus
            interval: 530
            repeat: true
            onTriggered: parent.opacity = parent.opacity > 0.5 ? 0 : 1
          }
        }
        placeholderText: "Write something"
        placeholderTextColor: Theme.withAlpha(note.ink, 0.35)

        background: null
        padding: 0

        // Focus only when actually editing. A popped-out note is pinned and
        // sits on every workspace; auto-focusing its editor just because it is
        // floating means a note parked on the desktop quietly swallows
        // keystrokes meant for whatever you were really typing into.
        focus: note.editing
        onActiveFocusChanged: if (activeFocus) note.editingRequested()

        Keys.onEscapePressed: {
          Store.flushPending()
          note.dismissed()
        }

        // Ctrl+V. Whether the clipboard holds an image can only be answered by
        // asking it, so the decision is made asynchronously and a plain text
        // paste is handed back to the editor once the answer comes.
        Keys.onPressed: function (event) {
          if (!event.matches(StandardKey.Paste)) return
          event.accepted = true
          Store.pasteInto(note.noteId)
        }

        Connections {
          target: Store
          function onPasteFellThrough(id) {
            if (id === note.noteId && editor.activeFocus) editor.paste()
          }
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

            // Edit the single character in place rather than reassigning
            // `text`. Assigning to text rebuilds the document and throws away
            // the undo history, so one stray click on a checkbox would cost you
            // every edit you had made to the note.
            var at = lineStart + box[1].length
            var caret = editor.cursorPosition
            editor.remove(at, at + 1)
            editor.insert(at, box[2] === " " ? "x" : " ")
            editor.cursorPosition = caret
          }
        }
      }
    }

    // Pasted images. A row of thumbnails rather than anything in the text, so
    // the note still reads as the words you wrote.
    Row {
      id: attachRow
      width: parent.width
      height: note.attachHeight
      spacing: 6
      visible: height > 0

      Repeater {
        model: note.attachments
        delegate: Rectangle {
          required property string modelData
          width: 44
          height: 44
          radius: 5
          color: Theme.withAlpha(note.ink, 0.10)
          clip: true

          Image {
            anchors.fill: parent
            source: Store.attachUrl(note.noteId, modelData)
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: 88
            sourceSize.height: 88
            asynchronous: true
          }

          MouseArea {
            id: thumbHit
            anchors.fill: parent
            hoverEnabled: true
            onClicked: Store.openAttachment(note.noteId, modelData)
          }

          Rectangle {
            width: 14; height: 14; radius: 7
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 2
            color: Theme.withAlpha("#000000", 0.6)
            opacity: thumbHit.containsMouse || dropHit.containsMouse ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 120 } }

            Text {
              anchors.centerIn: parent
              text: "\u00d7"
              font.pixelSize: 10
              color: "#ffffff"
            }

            MouseArea {
              id: dropHit
              anchors.fill: parent
              hoverEnabled: true
              onClicked: Store.removeAttachment(note.noteId, modelData)
            }
          }
        }
      }
    }
  }

  // A half-made choice should not still be sitting there next time the note is
  // reached for.
  onOpenChanged: {
    if (!open) { actions.pickingReminder = false; actions.pickingColour = false }
    else Store.refreshAttachments(note.noteId)
  }

  Component.onCompleted: if (open || floating) Store.refreshAttachments(note.noteId)

  // Resize grip. Only meaningful once detached; docked notes are sized by the
  // strip.
  MouseArea {
    visible: note.floating
    enabled: note.floating
    width: 16
    height: 16
    anchors.right: note.bandRight ? undefined : parent.right
    anchors.left: note.bandRight ? parent.left : undefined
    anchors.bottom: parent.bottom
    cursorShape: note.bandRight ? Qt.SizeBDiagCursor : Qt.SizeFDiagCursor
    onPressed: note.floatResizeRequested(note.bandRight ? Qt.BottomEdge | Qt.LeftEdge
                                                        : Qt.BottomEdge | Qt.RightEdge)

    Canvas {
      anchors.fill: parent
      anchors.margins: 4
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.strokeStyle = Theme.withAlpha(note.ink, 0.35)
        ctx.lineWidth = 1
        for (var i = 0; i < 3; i++) {
          var o = i * 3
          ctx.beginPath()
          ctx.moveTo(width - o, height)
          ctx.lineTo(width, height - o)
          ctx.stroke()
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
