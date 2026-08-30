import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Core
import qs.Ui

ShellRoot {
  id: shell

  // Which outputs get a strip. "focused" follows the active monitor so the
  // notes are always on the screen you are actually looking at; "all" mirrors
  // them everywhere; anything else is treated as an output name.
  readonly property string focusedName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""

  function wants(aScreen) {
    if (!aScreen) return false
    if (Config.monitor === "all") return true
    if (Config.monitor === "focused") return aScreen.name === shell.focusedName
    return aScreen.name === Config.monitor
  }

  Variants {
    model: Quickshell.screens

    delegate: Edge {
      active: shell.wants(modelData)
    }
  }

  // Popped-out notes. One surface each, driven by the store's float table.
  Variants {
    model: Store.floatIds
    delegate: Float {}
  }

  // ------------------------------------------------------------------ ipc
  //
  //   ledge new "text"     create a note and open it
  //   ledge add "text"     append to the most recent note
  //   ledge peek           fan the strip open without opening a note
  //   ledge list           ids, colours and titles as JSON
  IpcHandler {
    target: "ledge"

    function ping(): string { return "ok" }

    function create(body: string): string {
      var id = Store.create(body || "", "")
      Bus.openRequested(id)
      return id
    }

    // What SUPER+N is bound to: open a fresh note, or put the open one away.
    function toggleNew(): string { Bus.newRequested(); return "ok" }

    function pop(id: string): string {
      if (Store.indexOfId(id) < 0) return "unknown id"
      if (Store.isFloating(id)) return "already floating"
      var scr = Hyprland.focusedMonitor
      Store.setFloating(id, 80, 120, scr ? scr.name : "")
      Bus.closeRequested()
      return "ok"
    }

    function dock(id: string): string {
      if (!Store.isFloating(id)) return "not floating"
      Store.unfloat(id)
      return "ok"
    }

    function peek(): string { Bus.peekRequested(); return "ok" }

    function close(): string { Bus.closeRequested(); return "ok" }

    function open(id: string): string { Bus.openRequested(id); return "ok" }

    function append(body: string): string {
      var ids = Store.liveIds()
      if (!ids.length) return Store.create(body || "", "")
      var id = ids[ids.length - 1]
      var note = Store.get(id)
      var joined = String(note.body || "")
      if (joined.length && joined.charAt(joined.length - 1) !== "\n") joined += "\n"
      Store.setBody(id, joined + String(body || ""))
      Store.flushPending()
      return id
    }

    function list(): string {
      var out = []
      for (var i = 0; i < Store.notes.count; i++) {
        var n = Store.notes.get(i)
        out.push({
          id: n.noteId,
          color: n.color,
          title: Store.deriveTitle(n.body, n.title),
          archived: n.archived,
          pinned: n.pinned
        })
      }
      return JSON.stringify(out)
    }

    // Position is counted over visible notes, so it matches what you see on
    // the strip rather than raw model indices.
    function move(id: string, position: string): string {
      var from = Store.indexOfId(id)
      if (from < 0) return "unknown id"
      var vis = []
      for (var i = 0; i < Store.notes.count; i++)
        if (!Store.notes.get(i).archived) vis.push(i)
      var want = parseInt(position, 10)
      if (!isFinite(want)) return "bad position"
      want = Math.max(0, Math.min(vis.length - 1, want))
      Store.move(from, vis[want])
      return "ok"
    }

    function remove(id: string): string {
      Store.remove(id)
      return "ok"
    }

    function theme(): string {
      return JSON.stringify({ name: Theme.name, mode: Theme.mode })
    }
  }
}
