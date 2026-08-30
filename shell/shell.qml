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

  // Popped-out notes: one surface per floating note per output. Each surface
  // decides for itself whether the note currently overlaps it, so a note being
  // dragged across a seam is drawn by both and never jumps.
  readonly property var floatTargets: {
    var out = []
    for (var i = 0; i < Store.floatIds.length; i++)
      for (var j = 0; j < Quickshell.screens.length; j++)
        out.push({ id: Store.floatIds[i], screen: Quickshell.screens[j] })
    return out
  }

  Variants {
    model: shell.floatTargets
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
      // Land it on the focused output rather than at the desktop origin,
      // which on a multi-monitor layout may not be the screen you are looking at.
      var scr = Hyprland.focusedMonitor
      var base = null
      for (var i = 0; i < Quickshell.screens.length; i++)
        if (scr && Quickshell.screens[i].name === scr.name) base = Quickshell.screens[i]
      Store.setFloating(id, (base ? base.x : 0) + 80, (base ? base.y : 0) + 120)
      Bus.closeRequested()
      return "ok"
    }

    // Global compositor coordinates, so this can place a note on any output.
    function place(id: string, x: string, y: string): string {
      if (!Store.isFloating(id)) return "not floating"
      var px = parseInt(x, 10), py = parseInt(y, 10)
      if (!isFinite(px) || !isFinite(py)) return "bad coordinates"
      Store.moveFloat(id, px, py, 160)
      Store.persistFloats()
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
