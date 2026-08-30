import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Core

// Every note in one place: search, archived notes, and the trash.
//
// A real window rather than a layer surface, because unlike the strip this is
// something you sit in front of and work in: it wants to be focusable,
// movable, and resizable like anything else on the desktop.
FloatingWindow {
  id: win

  title: "ledge-library"
  color: Theme.background

  implicitWidth: 620
  implicitHeight: 520
  minimumSize: Qt.size(420, 320)

  // "notes" | "archived" | "trash"
  property string view: "notes"
  property string query: ""

  // Named to avoid colliding with Window's own closed signal.
  signal dismissRequested()

  function matches(n) {
    if (!win.query.length) return true
    var q = win.query.toLowerCase()
    return String(n.body || "").toLowerCase().indexOf(q) >= 0
        || Store.deriveTitle(n.body, n.title).toLowerCase().indexOf(q) >= 0
  }

  readonly property var rows: {
    // Touch these so the list recomputes as notes change underneath it.
    var _ = Store.notes.count + Store.trashModel.count + win.view.length + win.query.length
    var out = []
    if (win.view === "trash") {
      for (var t = 0; t < Store.trashModel.count; t++) {
        var e = Store.trashModel.get(t)
        if (win.query.length && e.title.toLowerCase().indexOf(win.query.toLowerCase()) < 0) continue
        out.push({ kind: "trash", file: e.file, title: e.title,
                   body: "", color: "", when: e.deletedAt })
      }
      return out
    }
    for (var i = 0; i < Store.notes.count; i++) {
      var n = Store.notes.get(i)
      if (n.pending) continue
      if (win.view === "archived" ? !n.archived : n.archived) continue
      if (!win.matches(n)) continue
      out.push({ kind: "note", id: n.noteId, color: n.color,
                 title: Store.deriveTitle(n.body, n.title),
                 body: String(n.body || ""), when: 0,
                 floating: Store.isFloating(n.noteId) })
    }
    return out
  }

  Component.onCompleted: Store.refreshTrash()
  onViewChanged: if (view === "trash") Store.refreshTrash()

  Item {
    anchors.fill: parent
    anchors.margins: 16

    // ------------------------------------------------------------ header

    Text {
      id: heading
      text: "Notes"
      font.family: Theme.fontFamily
      font.pixelSize: Theme.fontBase + 4
      font.bold: true
      color: Theme.foregroundBright
    }

    Rectangle {
      id: searchBox
      anchors.top: heading.bottom
      anchors.topMargin: 12
      width: parent.width
      height: 30
      radius: 6
      color: Theme.withAlpha(Theme.foreground, 0.06)
      border.width: 1
      border.color: Theme.withAlpha(search.activeFocus ? Theme.accent : Theme.foreground, 0.25)

      TextField {
        id: search
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        background: null
        placeholderText: "Search notes"
        placeholderTextColor: Theme.withAlpha(Theme.foreground, 0.4)
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontBase
        color: Theme.foreground
        selectionColor: Theme.withAlpha(Theme.accent, 0.45)
        onTextChanged: win.query = text
        Keys.onEscapePressed: text.length ? text = "" : win.dismissRequested()
      }
    }

    Row {
      id: tabs
      anchors.top: searchBox.bottom
      anchors.topMargin: 12
      spacing: 6

      Repeater {
        model: [
          { key: "notes",    label: "Notes" },
          { key: "archived", label: "Archived" },
          { key: "trash",    label: "Trash" }
        ]
        delegate: Rectangle {
          required property var modelData
          readonly property bool current: win.view === modelData.key
          width: tabLabel.width + 20
          height: 24
          radius: 12
          color: current ? Theme.withAlpha(Theme.accent, 0.22)
                         : Theme.withAlpha(Theme.foreground, tabHit.containsMouse ? 0.10 : 0.05)

          Text {
            id: tabLabel
            anchors.centerIn: parent
            text: modelData.label
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBase - 1
            color: parent.current ? Theme.foregroundBright
                                  : Theme.withAlpha(Theme.foreground, 0.7)
          }

          MouseArea {
            id: tabHit
            anchors.fill: parent
            hoverEnabled: true
            onClicked: win.view = modelData.key
          }
        }
      }
    }

    // -------------------------------------------------------------- list

    ListView {
      id: list
      anchors.top: tabs.bottom
      anchors.topMargin: 12
      anchors.bottom: footer.top
      anchors.bottomMargin: 12
      width: parent.width
      clip: true
      spacing: 4
      model: win.rows

      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      delegate: Rectangle {
        required property var modelData
        required property int index
        // The action Repeater below introduces its own modelData and index,
        // which would otherwise shadow the row's.
        readonly property var row: modelData

        width: list.width - (list.ScrollBar.vertical.visible ? 10 : 0)
        height: 52
        radius: 6
        color: Theme.withAlpha(Theme.foreground, rowHit.containsMouse ? 0.08 : 0.035)

        MouseArea {
          id: rowHit
          anchors.fill: parent
          hoverEnabled: true
          onClicked: {
            if (row.kind !== "note" || row.floating) return
            Bus.openRequested(row.id)
          }
        }

        Rectangle {
          id: dot
          width: 4
          height: parent.height - 16
          radius: 2
          anchors.left: parent.left
          anchors.leftMargin: 10
          anchors.verticalCenter: parent.verticalCenter
          color: row.kind === "note" ? Theme.tabColor(row.color)
                                           : Theme.withAlpha(Theme.foreground, 0.3)
        }

        Column {
          anchors.left: dot.right
          anchors.leftMargin: 10
          anchors.right: rowActions.left
          anchors.rightMargin: 10
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2

          Text {
            width: parent.width
            text: row.title
            elide: Text.ElideRight
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBase
            color: Theme.foregroundBright
          }

          Text {
            width: parent.width
            text: {
              if (row.kind === "trash")
                return "deleted " + Store.relativeTime(row.when)
              var rest = row.body.split("\n").slice(1).join(" ").replace(/^\s+/, "")
              return rest.length ? rest : "empty"
            }
            elide: Text.ElideRight
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBase - 2
            color: Theme.withAlpha(Theme.foreground, 0.5)
          }
        }

        Row {
          id: rowActions
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 10
          opacity: rowHit.containsMouse ? 1 : 0.25
          Behavior on opacity { NumberAnimation { duration: 120 } }

          Repeater {
            model: {
              if (row.kind === "trash")
                return [{ g: "", act: "restore", tip: "Restore" },
                        { g: "", act: "purge",   tip: "Delete forever" }]
              if (win.view === "archived")
                return [{ g: "", act: "unarchive", tip: "Unarchive" },
                        { g: "", act: "delete",    tip: "Delete" }]
              return [{ g: "", act: "pop",     tip: "Pop out" },
                      { g: "", act: "archive", tip: "Archive" },
                      { g: "", act: "delete",  tip: "Delete" }]
            }
            delegate: Text {
              required property var modelData
              text: modelData.g
              font.family: Theme.fontFamily
              font.pixelSize: 12
              color: Theme.withAlpha(actHit.containsMouse ? Theme.foregroundBright : Theme.foreground,
                                     actHit.containsMouse ? 1 : 0.55)

              MouseArea {
                id: actHit
                anchors.fill: parent
                anchors.margins: -5
                hoverEnabled: true
                onClicked: win.runAction(modelData.act, row)
              }
            }
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: list.count === 0
        text: win.view === "trash" ? "Trash is empty"
              : win.view === "archived" ? "Nothing archived"
              : win.query.length ? "No notes match" : "No notes yet"
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontBase
        color: Theme.withAlpha(Theme.foreground, 0.4)
      }
    }

    // ------------------------------------------------------------ footer

    Row {
      id: footer
      anchors.bottom: parent.bottom
      spacing: 8

      LibraryButton {
        text: "Export all"
        onActivated: win.exportAll()
      }

      LibraryButton {
        text: "Empty trash"
        visible: win.view === "trash" && Store.trashModel.count > 0
        danger: true
        confirm: true
        onActivated: Store.emptyTrash()
      }
    }

    Text {
      id: status
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 7
      font.family: Theme.fontFamily
      font.pixelSize: Theme.fontBase - 2
      color: Theme.withAlpha(Theme.foreground, 0.55)
      opacity: text.length ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 150 } }
    }

    Timer {
      id: clearStatus
      interval: 4000
      onTriggered: status.text = ""
    }
  }

  function runAction(act, row) {
    if (!row) return
    if (act === "restore") { Store.restoreTrashed(row.file); return }
    if (act === "purge") { Store.purgeTrashed(row.file); return }
    if (act === "pop") { Bus.popRequested(row.id, 120, 120); return }
    if (act === "archive" || act === "unarchive") { Store.toggleArchived(row.id); return }
    if (act === "delete") { Store.remove(row.id); Store.refreshTrash(); return }
  }

  function exportAll() {
    var path = Store.home + "/ledge-notes.md"
    var count = Store.exportAll(path, true)
    status.text = count + " notes exported to " + path
    clearStatus.restart()
  }

  Keys.onEscapePressed: win.dismissRequested()
}
