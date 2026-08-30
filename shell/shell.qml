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

  // ------------------------------------------------------- popped-out notes
  //
  // A popped-out note is a real toplevel, which means the compositor decides
  // where it opens and whether it tiles. Hyprland is told how to treat them
  // through window rules, and a rule only applies to a window that has not
  // mapped yet -- so nothing is added to the float table until its rule has
  // landed. `hyprctl keyword` is unavailable under the Lua config parser, so
  // this goes through `hyprctl eval`.

  property bool rulesReady: false

  // Escape regex metacharacters for a Hyprland rule.
  //
  // The replacement emits *two* backslashes because this string is Lua source:
  // Lua turns `\\x` back into `\x`, which is what the regex engine then sees. A
  // single backslash would reach Lua as an invalid escape and kill the whole
  // chunk. Hyphens are deliberately not escaped -- `\-` is not valid Lua, and a
  // hyphen outside a character class is already literal.
  function reEscape(text) {
    return String(text).replace(/[.*+?^${}()|[\]\\]/g, "\\\\$&")
  }

  function noteTitleRe(id) { return "^(ledge-note:" + shell.reEscape(id) + ")$" }

  // Placement is expressed the way Hyprland applies it: pin the window to a
  // named output, then offset within that output. `exact = true` claims to make
  // coordinates absolute and does not do so reliably on a secondary monitor,
  // and the resulting drift compounds on every restart.
  //
  // Stored geometry is the note rectangle; the window carries a transparent
  // margin around it for the note's shadow, so convert on the way out.
  function placementLua(id, st) {
    if (!st) return ""
    if (![st.x, st.y, st.w, st.h].every(isFinite)) return ""
    var pad = Config.floatShadowPad
    var monitor = st.monitor && st.monitor.length
                ? ', monitor = "' + st.monitor + '"' : ""
    return 'hl.window_rule({ match = { title = "' + shell.noteTitleRe(id) + '" }'
         + monitor
         + ', move = { ' + Math.round(st.x - pad) + ', ' + Math.round(st.y - pad) + ' }'
         + ', size = { ' + Math.round(st.w + pad * 2) + ', ' + Math.round(st.h + pad * 2) + ' } })'
  }

  // hyprctl eval wraps its argument in `return ...`, so several statements have
  // to be smuggled in as one expression.
  function evalChunk(statements) {
    return "(function() " + statements.join(" ") + " end)()"
  }

  // Hyprland has two config parsers and they take window rules by completely
  // different routes. The Lua parser (Omarchy 4 and anything else opting in)
  // refuses `hyprctl keyword` outright -- "keyword can't work with non-legacy
  // parsers. Use eval." -- while the classic parser has no `hl.window_rule` to
  // call. Assuming either one strands every user of the other with popped-out
  // notes that tile instead of floating.
  readonly property bool luaConfig: Hyprland.usingLua

  // Classic parser equivalents of the same rules.
  readonly property var legacyBaseRules: [
    "float", "pin", "noinitialfocus", "noblur", "noshadow", "nodim",
    "bordersize 0", "rounding 0", "opacity 1 1"
  ]

  function legacyKeyword(rule, match) {
    return "keyword windowrule " + rule + ", " + match
  }

  function legacyBaseCommand() {
    var match = 'title:^(ledge-note:.*)$'
    var parts = []
    for (var i = 0; i < legacyBaseRules.length; i++)
      parts.push(legacyKeyword(legacyBaseRules[i], match))
    parts.push(legacyKeyword("float", 'title:^(ledge-library)$'))
    parts.push(legacyKeyword("center", 'title:^(ledge-library)$'))
    return ["hyprctl", "--batch", parts.join(" ; ")]
  }

  function legacyPlacementCommand(entries) {
    var parts = []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      var match = "title:^(ledge-note:" + e.id + ")$"
      var pad = Config.floatShadowPad
      if (e.st.monitor && e.st.monitor.length)
        parts.push(legacyKeyword("monitor " + e.st.monitor, match))
      parts.push(legacyKeyword("move " + Math.round(e.st.x - pad)
                               + " " + Math.round(e.st.y - pad), match))
      parts.push(legacyKeyword("size " + Math.round(e.st.w + pad * 2)
                               + " " + Math.round(e.st.h + pad * 2), match))
    }
    return parts.length ? ["hyprctl", "--batch", parts.join(" ; ")] : []
  }

  readonly property string libraryRuleLua:
    'hl.window_rule({ match = { title = "^(ledge-library)$" }'
    + ', tag = "-default-opacity", float = true, center = true'
    + ', no_dim = true, opacity = "1 1" })'

  readonly property string baseRuleLua:
    'hl.window_rule({ match = { title = "^(ledge-note:.*)$" }'
    + ', tag = "-default-opacity"'
    + ', float = true, pin = true, no_initial_focus = true'
    + ', no_blur = true, no_shadow = true, no_dim = true'
    + ', border_size = 0, rounding = 0, opacity = "1 1" })'

  Process { id: ruleProc }

  // The base rule goes in on its own, deliberately.
  //
  // hyprctl eval rejects a malformed chunk *wholesale*, so bundling the
  // float/pin rule together with one placement rule per note means a single bad
  // coordinate silently takes the float rule down with it and every popped-out
  // note tiles. Keeping them in separate calls means the worst a bad placement
  // rule can do is leave one note in the wrong place.
  Process {
    id: baseRuleProc
    stdout: StdioCollector { onStreamFinished: shell.checkRuleResult("base", text) }
    onExited: {
      // Placement is best-effort; the notes are usable without it, so they are
      // not held back waiting for it.
      shell.applyPlacementRules()
      shell.rulesReady = true
    }
  }

  Process {
    id: setupProc
    stdout: StdioCollector { onStreamFinished: shell.checkRuleResult("placement", text) }
  }

  function checkRuleResult(which, text) {
    if (String(text).indexOf("error") >= 0)
      console.warn("ledge: Hyprland rejected the " + which + " window rules, "
                   + "popped-out notes will not behave correctly:", text)
  }

  function applyPlacementRules() {
    if (shell.luaConfig) {
      var lines = []
      for (var id in Store.floats) {
        var rule = shell.placementLua(id, Store.floats[id])
        if (rule.length) lines.push(rule)
      }
      if (!lines.length) return
      setupProc.command = ["hyprctl", "eval", shell.evalChunk(lines)]
      setupProc.running = true
      return
    }
    var entries = []
    for (var lid in Store.floats) {
      var st = Store.floats[lid]
      if (![st.x, st.y, st.w, st.h].every(isFinite)) continue
      entries.push({ id: lid, st: st })
    }
    var cmd = shell.legacyPlacementCommand(entries)
    if (!cmd.length) return
    setupProc.command = cmd
    setupProc.running = true
  }

  property bool rulesRequested: false

  // Gated on a property rather than a signal. The store's file load can finish
  // before this component exists, in which case a signal handler attached here
  // would never fire and no rules would ever be applied -- which shows up as
  // popped-out notes being tiled by the compositor.
  function applyStartupRules() {
    if (shell.rulesRequested || !Store.floatsReady) return
    shell.rulesRequested = true
    baseRuleProc.command = shell.luaConfig
      ? ["hyprctl", "eval", shell.evalChunk([shell.baseRuleLua, shell.libraryRuleLua])]
      : shell.legacyBaseCommand()
    baseRuleProc.running = true
  }

  Component.onCompleted: shell.applyStartupRules()

  Connections {
    target: Store
    function onFloatsReadyChanged() { shell.applyStartupRules() }
  }

  // Popping out: place first, then float, so the window never flashes at
  // whatever position Hyprland would have chosen for it.
  Connections {
    target: Bus
    function onPopRequested(id, x, y) {
      if (Store.isFloating(id)) return
      // Reuse the size this note was last given, so popping it out again does
      // not undo a resize.
      var prev = Store.floats[id]
      var w = prev && prev.w ? prev.w : Config.cardWidth
      var h = prev && prev.h ? prev.h : 200
      ruleProc.exited.connect(function once() {
        ruleProc.exited.disconnect(once)
        Store.setFloating(id, x, y, w, h)
      })
      // Resolve to the output the note is being dropped on before writing the
      // rule, so both agree on which monitor this is.
      var scr = Store.screenAt(x, y)
      var st = {
        monitor: scr ? scr.name : "",
        x: x - (scr ? scr.x : 0),
        y: y - (scr ? scr.y : 0),
        w: w, h: h
      }
      ruleProc.command = shell.luaConfig
        ? ["hyprctl", "eval", shell.evalChunk([shell.placementLua(id, st)])]
        : shell.legacyPlacementCommand([{ id: id, st: st }])
      ruleProc.running = true
    }
  }

  Variants {
    model: shell.rulesReady ? Store.floatIds : []
    delegate: Float {}
  }

  // ------------------------------------------------------------- library

  property bool libraryOpen: false

  Connections {
    target: Bus
    function onLibraryRequested() { shell.libraryOpen = !shell.libraryOpen }
  }

  Loader {
    active: shell.libraryOpen
    sourceComponent: Library {
      onDismissRequested: shell.libraryOpen = false
    }
  }

  // ---------------------------------------------------------- reminders
  //
  // A reminder is a timestamp in a note's frontmatter. Nothing schedules a
  // timer per note: the list is swept periodically instead, which means a
  // reminder that came due while the machine was asleep, or while Ledge was not
  // running, still fires the next time it is looked at rather than being
  // silently skipped.

  // One process per notification, because `--action` implies `--wait`: the
  // command lives until the user answers it or it times out, so a single shared
  // Process would let one pending reminder block the next.
  Component {
    id: notifier
    Process {
      property string noteId: ""
      stdout: StdioCollector {
        onStreamFinished: if (String(text).trim() === "open") shell.revealNote(noteId)
      }
      onExited: destroy()
    }
  }

  // Bring a note to the user's attention wherever it currently lives.
  function revealNote(id) {
    if (Store.indexOfId(id) < 0) return
    if (Store.isFloating(id)) return   // already a window on screen
    Bus.openRequested(id)
  }

  Timer {
    running: true
    interval: 20000
    repeat: true
    triggeredOnStart: true
    onTriggered: shell.sweepReminders()
  }

  function sweepReminders() {
    if (!Store.ready) return
    var due = Store.dueReminders(Date.now())
    for (var i = 0; i < due.length; i++) {
      // Cleared before notifying, so a notification that fails to send cannot
      // leave the reminder due and re-firing every sweep.
      Store.setReminder(due[i].id, "")
      shell.notifyReminder(due[i])
    }
  }

  function notifyReminder(item) {
    var lines = String(item.body || "").split("\n").slice(1)
                  .filter(function (l) { return l.replace(/\s+/g, "").length })
    var proc = notifier.createObject(shell, { noteId: item.id })
    if (!proc) return
    proc.command = ["notify-send", "--app-name=Ledge", "--icon=ledge",
                    "-A", "open=Open note",
                    item.title, lines.slice(0, 4).join("\n")]
    proc.running = true
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

    // Internal counters, for diagnosing odd behaviour and for the test suite.
    function stats(): string {
      return JSON.stringify({
        notes: Store.notes.count,
        live: Store.liveCount,
        floating: Store.floatIds.length,
        reaped: Store.reapCount,
        ready: Store.ready
      })
    }

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
      // Land it on the focused output rather than at the desktop origin, which
      // on a multi-monitor layout may not be the screen being looked at.
      var scr = Hyprland.focusedMonitor
      var base = null
      for (var i = 0; i < Quickshell.screens.length; i++)
        if (scr && Quickshell.screens[i].name === scr.name) base = Quickshell.screens[i]
      // Through the same path the UI uses, so the placement rule is applied
      // before the window exists. Calling Store.setFloating directly here meant
      // a note popped from the CLI inherited whatever stale rule was lying
      // around from a previous pop.
      Bus.popRequested(id, (base ? base.x : 0) + 80, (base ? base.y : 0) + 120)
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

    function all(): string { Bus.libraryRequested(); return "ok" }

    function trash(): string {
      var out = []
      for (var i = 0; i < Store.trashModel.count; i++) {
        var e = Store.trashModel.get(i)
        out.push({ file: e.file, title: e.title, deletedAt: e.deletedAt })
      }
      return JSON.stringify(out)
    }

    function restore(file: string): string {
      Store.restoreTrashed(file)
      return "ok"
    }

    function refreshTrash(): string { Store.refreshTrash(); return "ok" }

    // Attach whatever image is on the clipboard to a note.
    function attach(id: string): string {
      if (Store.indexOfId(id) < 0) return "unknown id"
      Store.pasteInto(id)
      return "ok"
    }

    function attachments(id: string): string {
      return JSON.stringify(Store.attachmentsFor(id))
    }

    // `when` is a duration like 15m / 2h / 3d, an ISO 8601 timestamp, or
    // "clear".
    function remind(id: string, when: string): string {
      if (Store.indexOfId(id) < 0) return "unknown id"
      var w = String(when || "").trim()
      if (!w.length || w === "clear" || w === "none") {
        Store.setReminder(id, "")
        return "cleared"
      }
      var rel = w.match(/^(\d+)\s*([mhd])$/i)
      var at
      if (rel) {
        var mult = { m: 60000, h: 3600000, d: 86400000 }[rel[2].toLowerCase()]
        at = Date.now() + parseInt(rel[1], 10) * mult
      } else {
        at = Date.parse(w)
        if (!isFinite(at)) return "could not read a time from '" + w + "'"
      }
      var iso = new Date(at).toISOString()
      Store.setReminder(id, iso)
      return iso
    }

    function exportAll(path: string, includeArchived: string): string {
      var target = (path && path.length) ? path : (Store.home + "/ledge-notes.md")
      var n = Store.exportAll(target, includeArchived !== "false")
      return n + " notes -> " + target
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
