pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Notes on disk, and the model the UI binds to.
//
//   ~/.local/share/notestrip/notes/<id>.md    one file per note, YAML frontmatter
//   ~/.local/share/notestrip/order            note ids, one per line, display order
//   ~/.local/share/notestrip/trash/           deleted notes, kept for undo
//
// Ordering lives outside the notes on purpose. Dragging a note to a new
// position rewrites one small file instead of touching the frontmatter of
// every note below it, which keeps reorders out of the way in git and in any
// file-sync tool pointed at this directory.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")

  // Overridable so a test run, or a second profile, never touches real notes.
  readonly property string dataDir: {
    var override = Quickshell.env("NOTESTRIP_DATA_DIR")
    if (!override || !override.length) override = Quickshell.env("LEDGE_DATA_DIR")
    if (override && override.length) return override
    var dataHome = Quickshell.env("XDG_DATA_HOME")
    if (!dataHome || !dataHome.length) dataHome = home + "/.local/share"
    return dataHome + "/notestrip"
  }
  readonly property string notesDir: dataDir + "/notes"
  readonly property string trashDir: dataDir + "/trash"
  readonly property string orderPath: dataDir + "/order"
  readonly property string seededPath: dataDir + "/.seeded"
  readonly property string conflictDir: dataDir + "/conflicts"
  readonly property string floatsPath: dataDir + "/floats.json"

  readonly property ListModel notes: ListModel {}

  property bool ready: false
  property var order: []

  // First-run seeding. Tracked with a marker file rather than "are there zero
  // notes", so deleting every note does not make the welcome note reappear.
  property bool seedChecked: false
  property bool seeded: false

  function maybeSeed() {
    if (!root.ready || !root.seedChecked || root.seeded) return
    root.seeded = true
    seedMarker.setText("NoteStrip writes this once, the first time it runs.\n")
    if (notes.count > 0) return
    create("Welcome to NoteStrip\n"
           + "- [ ] reach for the edge to fan these out\n"
           + "- [ ] hover a dash to open its note\n"
           + "- [ ] drag a dash to reorder\n"
           + "- [ ] the + below makes a new one\n"
           + "\n"
           + "SUPER+N for a new note anywhere\n"
           + "SUPER+SHIFT+L for search and archive\n"
           + "\n"
           + "Delete this note when you are done with it.\n", "")
  }

  property FileView seedMarker: FileView {
    path: root.seededPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: { root.seeded = true; root.seedChecked = true }
    onLoadFailed: { root.seedChecked = true; root.maybeSeed() }
  }

  onReadyChanged: if (ready) maybeSeed()

  // Visible-note count, kept as plain state rather than derived in the view.
  // Binding a window's `visible` to a child ListView's count makes the child's
  // existence depend on the window it lives in, which is a loop.
  property int liveCount: 0

  function recount() {
    var c = 0
    for (var i = 0; i < notes.count; i++) if (!notes.get(i).archived) c++
    root.liveCount = c
  }

  // Popped-out notes: id -> { monitor, x, y, w, h }, where x and y are relative
  // to the named output.
  //
  // This is stored the way Hyprland thinks about it, not the way it is nicer to
  // reason about. A `move` window rule is applied relative to whichever monitor
  // the window opens on; `exact = true` is supposed to make it absolute and
  // does not reliably do so when the window opens on a secondary output. The
  // failure mode is vicious rather than cosmetic: the note lands at
  // stored + monitor_origin, that position is then learned back, and every
  // restart shifts it another monitor width until it is off-screen entirely.
  //
  // Naming the output and keeping the offset relative to it sidesteps the whole
  // question, and survives a monitor being unplugged more gracefully besides.
  //
  // Kept out of the note files entirely. Position changes on every frame of a
  // drag, and rewriting a note's frontmatter that often would churn the file,
  // wake every watcher, and bury real edits in a sync tool's history. This is
  // volatile window state, not part of what the note says.
  property var floats: ({})
  property var floatIds: []

  function isFloating(id) { return root.floats[id] !== undefined }

  function floatState(id) { return root.floats[id] || null }

  // Which output contains a global point, by preference, else the first.
  function screenAt(gx, gy) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      if (gx >= s.x && gx < s.x + s.width && gy >= s.y && gy < s.y + s.height) return s
    }
    return screens.length ? screens[0] : null
  }

  function screenNamed(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }

  // Takes GLOBAL coordinates and stores them against whichever output they land
  // on. Callers think in global terms; only the stored form is relative.
  function setFloating(id, gx, gy, w, h) {
    var scr = screenAt(gx, gy)
    var f = JSON.parse(JSON.stringify(root.floats))
    f[id] = {
      monitor: scr ? scr.name : "",
      x: Math.round(gx - (scr ? scr.x : 0)),
      y: Math.round(gy - (scr ? scr.y : 0)),
      w: Math.round(w || Config.cardWidth),
      h: Math.round(h || 180)
    }
    root.floats = f
    root.floatIds = Object.keys(f)
    persistFloats()
  }

  // The note rectangle, in global compositor coordinates. Written back from
  // what the compositor actually did, since it owns the geometry of a
  // popped-out note and a Wayland client is never told where it is.
  function setFloatGeometry(id, gx, gy, w, h) {
    if (!isFloating(id)) return
    if (![gx, gy, w, h].every(isFinite)) return

    var scr = screenAt(gx, gy)
    // A position on no output at all is not something to learn from. Refusing
    // it is the backstop against a placement bug walking a note off the desktop
    // one restart at a time.
    if (!scr) return

    var next = {
      monitor: scr.name,
      x: Math.round(gx - scr.x),
      y: Math.round(gy - scr.y),
      w: Math.round(w),
      h: Math.round(h)
    }
    var cur = root.floats[id]
    if (cur.monitor === next.monitor && cur.x === next.x && cur.y === next.y
        && cur.w === next.w && cur.h === next.h) return

    var f = JSON.parse(JSON.stringify(root.floats))
    f[id] = next
    root.floats = f
    floatSaveTimer.restart()
  }

  // Stored position back in global terms, for anything that needs to draw or
  // reason about it.
  function floatGlobal(id) {
    var st = root.floats[id]
    if (!st) return null
    var scr = screenNamed(st.monitor)
    return {
      x: st.x + (scr ? scr.x : 0),
      y: st.y + (scr ? scr.y : 0),
      w: st.w, h: st.h,
      monitor: scr ? scr.name : ""
    }
  }

  // Bounding box of every connected output, in global coordinates. A note is
  // kept inside this rather than inside one screen, which is what lets a drag
  // carry it across a monitor boundary.
  function desktopBounds() {
    var minX = 0, minY = 0, maxX = 0, maxY = 0, seen = false
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var s = Quickshell.screens[i]
      if (!seen) { minX = s.x; minY = s.y; maxX = s.x + s.width; maxY = s.y + s.height; seen = true; continue }
      minX = Math.min(minX, s.x); minY = Math.min(minY, s.y)
      maxX = Math.max(maxX, s.x + s.width); maxY = Math.max(maxY, s.y + s.height)
    }
    return { x: minX, y: minY, right: maxX, bottom: maxY }
  }

  // Keep a note grabbable. It may hang off an edge, but never so far that the
  // header you drag it by is unreachable.
  function clampFloat(x, y, w, h) {
    var b = desktopBounds()
    var keepX = Math.min(120, w)
    var keepY = 34
    return {
      x: Math.round(Math.max(b.x - (w - keepX), Math.min(b.right - keepX, x))),
      y: Math.round(Math.max(b.y, Math.min(b.bottom - keepY, y)))
    }
  }

  function moveFloat(id, x, y, h) {
    if (!isFloating(id)) return
    var f = JSON.parse(JSON.stringify(root.floats))
    var p = clampFloat(x, y, Config.cardWidth, h || 140)
    f[id].x = p.x
    f[id].y = p.y
    root.floats = f
    floatSaveTimer.restart()
  }

  function nudgeFloat(id, dx, dy, h) {
    var cur = floatState(id)
    if (!cur) return
    moveFloat(id, cur.x + dx, cur.y + dy, h)
  }

  // A float entry can outlive the note it names. A note that has never been
  // typed into is `pending` and deliberately has no file, so popping one out
  // and then restarting loses the note while floats.json keeps its id. The
  // entry then names nothing: `Float` renders nothing for it, but it counts in
  // `notestrip stats` forever and no longer has any way of being cleared.
  //
  // Safe to run after every scan. `notes` is authoritative by the time a scan
  // ends, and a blank note that is merely unsaved is still a row in it, so a
  // note that is only unwritten is never pruned.
  function pruneFloats() {
    if (!root.ready || !root.floatsReady) return
    var stale = []
    for (var id in root.floats)
      if (indexOfId(id) < 0) stale.push(id)
    if (!stale.length) return
    var f = JSON.parse(JSON.stringify(root.floats))
    for (var i = 0; i < stale.length; i++) delete f[stale[i]]
    root.floats = f
    root.floatIds = Object.keys(f)
    persistFloats()
  }

  function unfloat(id) {
    if (!isFloating(id)) return
    var f = JSON.parse(JSON.stringify(root.floats))
    delete f[id]
    root.floats = f
    root.floatIds = Object.keys(f)
    persistFloats()
  }

  function persistFloats() {
    floatsFile.setText(JSON.stringify(root.floats, null, 2) + "\n")
  }

  property Timer floatSaveTimer: Timer {
    interval: 350
    onTriggered: root.persistFloats()
  }

  // Set once floats.json has been read (or found missing). Consumers gate on
  // this rather than on a one-shot signal, because a singleton's file load can
  // complete before anything has had a chance to connect to it.
  property bool floatsReady: false

  signal noteAdded(string id)
  signal noteRemoved(string id)

  // ------------------------------------------------------------- lookup

  function indexOfId(id) {
    for (var i = 0; i < notes.count; i++)
      if (notes.get(i).noteId === id) return i
    return -1
  }

  function get(id) {
    var i = indexOfId(id)
    return i < 0 ? null : notes.get(i)
  }

  // Visible notes, in display order, newest-unordered last.
  function liveIds() {
    var out = []
    for (var i = 0; i < notes.count; i++) {
      var n = notes.get(i)
      if (!n.archived) out.push(n.noteId)
    }
    return out
  }

  // --------------------------------------------------------- id + title

  // Sortable, collision-resistant, and readable in a filename. Timestamp in
  // base36 keeps files in creation order in a plain `ls`.
  function newId() {
    var stamp = Date.now().toString(36)
    var salt = Math.floor(Math.random() * 1679616).toString(36)
    while (salt.length < 4) salt = "0" + salt
    return stamp + "-" + salt
  }

  // The edge tab's label. Sticky notes do not have a title field; the first
  // line is the title, the way it works on paper. An explicit frontmatter
  // `title:` wins when the first line makes a poor label.
  function deriveTitle(body, explicit) {
    if (explicit && explicit.length) return explicit
    var lines = String(body || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s*[#>\-*]+\s*/, "").replace(/^\s+|\s+$/g, "")
      line = line.replace(/^\[[ xX]\]\s*/, "")
      if (line.length) return line
    }
    return "Untitled"
  }

  // ------------------------------------------------------- frontmatter

  function parseNote(text) {
    var raw = String(text || "")
    var meta = {}
    var body = raw

    var match = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/)
    if (match) {
      body = match[2]
      var lines = match[1].split("\n")
      for (var i = 0; i < lines.length; i++) {
        var colon = lines[i].indexOf(":")
        if (colon < 0) continue
        var key = lines[i].slice(0, colon).replace(/^\s+|\s+$/g, "")
        var val = lines[i].slice(colon + 1).replace(/^\s+|\s+$/g, "")
        val = val.replace(/^"(.*)"$/, "$1").replace(/^'(.*)'$/, "$1")
        meta[key] = val
      }
    }
    return { meta: meta, body: body }
  }

  function serializeNote(n) {
    var lines = ["---"]
    lines.push("id: " + n.noteId)
    lines.push("color: " + n.color)
    if (n.title && n.title.length) lines.push("title: " + JSON.stringify(n.title))
    if (n.archived) lines.push("archived: true")
    if (n.pinned) lines.push("pinned: true")
    if (n.styled === false) lines.push("styled: false")
    if (n.reminder && n.reminder.length) lines.push("reminder: " + n.reminder)
    if (n.created && n.created.length) lines.push("created: " + n.created)
    lines.push("---")
    var body = String(n.body || "")
    // Keep the file POSIX-clean so `cat`, `grep` and git all behave.
    if (body.length && body.charAt(body.length - 1) !== "\n") body += "\n"
    return lines.join("\n") + "\n" + body
  }

  function truthy(v) {
    return v === true || v === "true" || v === "yes" || v === "1"
  }

  // ---------------------------------------------------------- mutation

  // A new note exists in the model but not yet on disk. Nothing is written
  // until it has content, so opening the strip and changing your mind leaves no
  // file behind and no entry in the trash.
  function create(body, color) {
    var id = root.newId()
    var hasBody = String(body || "").replace(/\s+/g, "").length > 0
    notes.append({
      noteId: id,
      file: root.notesDir + "/" + id + ".md",
      color: color || Theme.swatchKeys[notes.count % Theme.swatchKeys.length],
      title: "",
      body: body || "",
      archived: false,
      pinned: false,
      styled: true,
      reminder: "",
      created: new Date().toISOString(),
      loaded: true,
      pending: !hasBody
    })
    root.order = root.liveIds()
    persistOrder()
    root.noteAdded(id)
    recount()
    if (hasBody) save(id)
    return id
  }

  function isBlank(id) {
    var n = get(id)
    return !n || String(n.body || "").replace(/\s+/g, "").length === 0
  }

  // Drop a note that was never written to. Unlinked outright rather than
  // trashed: there is nothing in it to recover, and a trash full of empty files
  // is just noise.
  function discardIfBlank(id) {
    var i = indexOfId(id)
    if (i < 0 || !isBlank(id)) return false
    var n = notes.get(i)
    var wasPending = n.pending === true
    var file = n.file
    notes.remove(i)
    if (isFloating(id)) unfloat(id)
    root.order = root.liveIds()
    persistOrder()
    recount()
    if (!wasPending) purgeProc.exec(["rm", "-f", file])
    root.noteRemoved(id)
    return true
  }

  function update(id, fields) {
    var i = indexOfId(id)
    if (i < 0) return
    notes.set(i, fields)
    save(id)
  }

  function setBody(id, body) {
    var i = indexOfId(id)
    if (i < 0 || notes.get(i).body === body) return
    notes.setProperty(i, "body", body)
    if (notes.get(i).pending && String(body || "").replace(/\s+/g, "").length > 0)
      notes.setProperty(i, "pending", false)
    saveDebounced(id)
  }

  // ISO 8601, or "" to clear. Stored in the note's frontmatter because unlike
  // window geometry a reminder is genuinely part of what the note says, and
  // should survive being copied to another machine.
  function setReminder(id, iso) {
    update(id, { reminder: String(iso || "") })
  }

  function dueReminders(nowMs) {
    var out = []
    for (var i = 0; i < notes.count; i++) {
      var n = notes.get(i)
      if (!n.reminder || !n.reminder.length) continue
      var at = Date.parse(n.reminder)
      if (!isFinite(at) || at > nowMs) continue
      out.push({ id: n.noteId, title: deriveTitle(n.body, n.title), body: String(n.body || "") })
    }
    return out
  }

  function setColor(id, color) {
    update(id, { color: Theme.swatchKey(color) })
  }

  function toggleArchived(id) {
    var i = indexOfId(id)
    if (i < 0) return
    notes.setProperty(i, "archived", !notes.get(i).archived)
    root.order = root.liveIds()
    persistOrder()
    recount()
    save(id)
  }

  function togglePinned(id) {
    var i = indexOfId(id)
    if (i < 0) return
    notes.setProperty(i, "pinned", !notes.get(i).pinned)
    save(id)
  }

  // Delete moves the file to trash/ rather than unlinking it. Accidental
  // deletion is the single most common complaint about every sticky notes
  // app ever shipped, so the bytes stay recoverable until the user empties it.
  function remove(id) {
    var i = indexOfId(id)
    if (i < 0) return
    var file = notes.get(i).file
    notes.remove(i)
    if (isFloating(id)) unfloat(id)
    root.order = root.liveIds()
    persistOrder()
    recount()

    var inflight = root.removing
    inflight[id] = true
    root.removing = inflight

    // The images belong to the note, so they go with it.
    attachOps.exec(["bash", "-c", 'rm -rf -- "$1"', "_", attachPathFor(id)])
    var without = JSON.parse(JSON.stringify(root.attachments))
    delete without[id]
    root.attachments = without

    trashProc.exec(["bash", "-c",
      'mkdir -p "$1" && mv -f "$2" "$1/$(date +%s)-$(basename "$2")"',
      "_", root.trashDir, file])
    root.noteRemoved(id)
  }

  function move(fromIndex, toIndex) {
    if (fromIndex === toIndex || fromIndex < 0 || toIndex < 0) return
    if (fromIndex >= notes.count || toIndex >= notes.count) return
    notes.move(fromIndex, toIndex, 1)
    root.order = root.liveIds()
    persistOrder()
  }

  // ------------------------------------------------------------ writing

  property var pendingSaves: ({})

  // Notes whose file is in the middle of being moved to the trash. A directory
  // rescan that lands during the move still sees the file and would re-add the
  // row as an unloaded placeholder, which then never goes away.
  property var removing: ({})

  function saveDebounced(id) {
    var p = root.pendingSaves
    p[id] = true
    root.pendingSaves = p
    saveTimer.restart()
  }

  function flushPending() {
    var p = root.pendingSaves
    for (var id in p) save(id)
    root.pendingSaves = ({})
  }

  function save(id) {
    var n = get(id)
    if (!n || !n.loaded || n.pending) return
    var view = viewFor(id)
    if (view) view.setText(serializeNote(n))
  }

  function persistOrder() {
    orderFile.setText(root.order.join("\n") + "\n")
  }

  property Timer saveTimer: Timer {
    interval: 400
    onTriggered: root.flushPending()
  }

  // ------------------------------------------------------------ loading

  function viewFor(id) {
    for (var i = 0; i < noteViews.count; i++) {
      var v = noteViews.objectAt(i)
      if (v && v.noteId === id) return v
    }
    return null
  }

  function applyOrder() {
    if (!root.order.length) return
    var target = 0
    for (var i = 0; i < root.order.length; i++) {
      var at = indexOfId(root.order[i])
      if (at < 0) continue
      if (at !== target) notes.move(at, target, 1)
      target++
    }
  }

  // Reconcile the model against what is actually on disk. Adds arrive as
  // placeholder rows whose FileView fills in the content; removals drop rows
  // whose file vanished from under us (an external delete, or a sync tool).
  function syncFiles(listing) {
    var seen = {}
    var files = String(listing || "").split("\n")

    for (var i = 0; i < files.length; i++) {
      var file = files[i].replace(/^\s+|\s+$/g, "")
      if (!file.length || !file.match(/\.md$/)) continue
      var id = file.replace(/\.md$/, "")
      if (root.removing[id]) continue
      seen[id] = true
      if (indexOfId(id) >= 0) continue
      notes.append({
        noteId: id,
        file: root.notesDir + "/" + file,
        color: Theme.swatchKeys[0],
        title: "",
        body: "",
        archived: false,
        pinned: false,
        styled: true,
        reminder: "",
        created: "",
        loaded: false,
        pending: false
      })
    }

    for (var j = notes.count - 1; j >= 0; j--) {
      var n = notes.get(j)
      // `pending` notes have no file by design and must survive. Everything
      // else came from a directory listing, so a row whose file has gone is
      // stale -- including one still waiting on its first load, which is
      // exactly the ghost a delete used to leave behind.
      if (!seen[n.noteId] && !n.pending) {
        root.reapCount++
        notes.remove(j)
      }
    }

    applyOrder()
    recount()
    root.ready = true
    pruneFloats()
  }

  function ingest(id, text) {
    var i = indexOfId(id)
    if (i < 0) return
    var parsed = parseNote(text)
    var m = parsed.meta
    notes.set(i, {
      noteId: id,
      file: root.notesDir + "/" + id + ".md",
      color: Theme.swatchKey(m["color"]),
      title: m["title"] || "",
      body: parsed.body,
      archived: truthy(m["archived"]),
      pinned: truthy(m["pinned"]),
      styled: m["styled"] === undefined ? true : truthy(m["styled"]),
      reminder: m["reminder"] || "",
      created: m["created"] || "",
      loaded: true,
      pending: false
    })
    recount()
  }

  // ---------------------------------------------------------- conflicts
  //
  // An open editor deliberately ignores changes made to its file by anything
  // else, because yanking text out from under a caret mid-sentence is its own
  // kind of awful. The cost is that the next keystroke would overwrite whatever
  // the other editor wrote. Rather than pick a side, the version NoteStrip is about
  // to overwrite is kept.

  property var conflictSeen: ({})

  signal conflictKept(string id, string path)

  function keepConflictCopy(id, content) {
    var body = String(content || "")
    if (!body.length) return
    // The same external content can arrive repeatedly; keep it once.
    if (root.conflictSeen[id] === body) return
    var seen = root.conflictSeen
    seen[id] = body
    root.conflictSeen = seen

    var path = root.conflictDir + "/" + id + "-" + Date.now() + ".md"
    conflictProc.stdinEnabled = true
    conflictProc.exec(["bash", "-c",
      'mkdir -p "$(dirname "$1")" && cat > "$1"', "_", path])
    conflictProc.write(body)
    conflictProc.stdinEnabled = false
    root.conflictKept(id, path)
  }

  property Process conflictProc: Process { stdinEnabled: true }

  // -------------------------------------------------- attachments
  //
  // Pasted images are files beside the notes, not markdown embedded in them.
  // `![](path)` would put a filesystem path into the note's text, where it
  // would be styled, wrapped, edited and eventually broken; and an image is not
  // something you want occupying four lines of a sticky note as a URL.
  //
  //   ~/.local/share/notestrip/attachments/<note-id>/<timestamp>.<ext>

  readonly property string attachDir: dataDir + "/attachments"

  // id -> [filename]. Reassigned wholesale so bindings re-evaluate.
  property var attachments: ({})

  function attachPathFor(id) { return root.attachDir + "/" + id }

  function attachmentsFor(id) {
    var list = root.attachments[id]
    return list ? list : []
  }

  function attachUrl(id, file) {
    return "file://" + attachPathFor(id) + "/" + file
  }

  property string attachScanId: ""

  function refreshAttachments(id) {
    root.attachScanId = id
    attachScan.command = ["bash", "-c",
      'cd "$1" 2>/dev/null && ls -1 2>/dev/null || true', "_", attachPathFor(id)]
    attachScan.running = false
    attachScan.running = true
  }

  function ingestAttachments(listing) {
    var id = root.attachScanId
    if (!id.length) return
    var files = String(listing || "").split("\n").filter(function (f) { return f.length })
    var next = JSON.parse(JSON.stringify(root.attachments))
    if (files.length) next[id] = files
    else delete next[id]
    root.attachments = next
  }

  property Process attachScan: Process {
    stdout: StdioCollector { onStreamFinished: root.ingestAttachments(text) }
  }

  // Paste: an image on the clipboard becomes an attachment, anything else is
  // left for the editor to paste as text. Which of the two it is can only be
  // known by asking the clipboard, so the decision is asynchronous.
  signal pasteFellThrough(string id)

  property string pasteTarget: ""

  function pasteInto(id) {
    root.pasteTarget = id
    pasteProc.command = ["bash", "-c",
      'set -e; dir="$1"; '
      + 'types=$(wl-paste --list-types 2>/dev/null || true); '
      + 'img=$(printf "%s\\n" "$types" | grep -m1 "^image/" || true); '
      + 'if [ -z "$img" ]; then echo TEXT; exit 0; fi; '
      + 'mkdir -p "$dir"; ext="${img#image/}"; '
      + 'case "$ext" in jpeg) ext=jpg;; "svg+xml") ext=svg;; esac; '
      + 'name="$(date +%s%N).$ext"; '
      + 'wl-paste --type "$img" > "$dir/$name"; '
      + 'echo "IMAGE $name"',
      "_", attachPathFor(id)]
    pasteProc.running = false
    pasteProc.running = true
  }

  function finishPaste(result) {
    var id = root.pasteTarget
    if (!id.length) return
    if (String(result || "").indexOf("IMAGE ") === 0) refreshAttachments(id)
    else root.pasteFellThrough(id)
  }

  property Process pasteProc: Process {
    stdout: StdioCollector { onStreamFinished: root.finishPaste(String(text).trim()) }
  }

  function removeAttachment(id, file) {
    attachOps.exec(["bash", "-c", 'rm -f -- "$1/$2"', "_", attachPathFor(id), file])
    attachSettle.restart()
  }

  function openAttachment(id, file) {
    attachOps.exec(["xdg-open", attachPathFor(id) + "/" + file])
  }

  // The note's text on the clipboard.
  //
  // Passed as one argument rather than several, so the line breaks survive:
  // wl-copy joins multiple arguments with spaces. `--trim-newline` stops it
  // adding one of its own on the end.
  function copyText(text) {
    if (!String(text).length) return
    attachOps.exec(["wl-copy", "--trim-newline", "--", String(text)])
  }

  // A link in a note, handed to whatever the desktop uses for the web.
  //
  // The scheme is re-checked here rather than trusted from the caller. Note
  // bodies are just files, and a file can be written by anything; `xdg-open`
  // will happily act on schemes that are not a web page at all.
  function openLink(url) {
    if (!/^https?:\/\//.test(String(url))) return
    attachOps.exec(["xdg-open", String(url)])
  }

  property Process attachOps: Process {}

  property Timer attachSettle: Timer {
    interval: 250
    onTriggered: root.refreshAttachments(root.pasteTarget)
  }

  // -------------------------------------------------------------- trash
  //
  // Deleted notes keep their file, prefixed with the epoch second they were
  // removed. Nothing reads them back into the notes model, so they are listed
  // straight off disk rather than mirrored in memory.

  readonly property ListModel trashModel: ListModel {}

  function refreshTrash() { trashScan.running = false; trashScan.running = true }

  function ingestTrash(listing) {
    trashModel.clear()
    var lines = String(listing || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line.length) continue
      var tab = line.indexOf("\t")
      if (tab < 0) continue
      var file = line.slice(0, tab)
      var preview = line.slice(tab + 1)
      var stamp = file.match(/^(\d+)-/)
      trashModel.append({
        file: file,
        title: preview.length ? preview : "Untitled",
        deletedAt: stamp ? parseInt(stamp[1], 10) : 0
      })
    }
  }

  function restoreTrashed(file) {
    // Strip the epoch prefix to recover the original note id. A note whose id
    // is somehow already back in place is restored beside it rather than over
    // it; losing the newer of the two would be the worse failure.
    trashOps.exec(["bash", "-c",
      'set -e; src="$1/$2"; id="${2#*-}"; dest="$3/$id"; '
      + 'if [ -e "$dest" ]; then dest="$3/restored-$2"; fi; mv -n "$src" "$dest"',
      "_", root.trashDir, file, root.notesDir])
    trashSettle.restart()
  }

  function purgeTrashed(file) {
    trashOps.exec(["bash", "-c", 'rm -f -- "$1/$2"', "_", root.trashDir, file])
    trashSettle.restart()
  }

  function emptyTrash() {
    trashOps.exec(["bash", "-c", 'rm -f -- "$1"/*.md 2>/dev/null || true', "_", root.trashDir])
    trashSettle.restart()
  }

  property Process trashOps: Process {}

  property Timer trashSettle: Timer {
    interval: 250
    onTriggered: { root.refreshTrash(); root.rescan() }
  }

  property Process trashScan: Process {
    command: ["bash", "-c",
      'mkdir -p "$1"; cd "$1" || exit 0; '
      + 'for f in *.md; do [ -e "$f" ] || continue; '
      + 'line=$(awk \'BEGIN{c=0} /^---$/{c++; next} c>=2 && NF {print; exit}\' "$f" | cut -c1-70); '
      + 'printf "%s\\t%s\\n" "$f" "$line"; done',
      "_", root.trashDir]
    stdout: StdioCollector { onStreamFinished: root.ingestTrash(text) }
  }

  // Human-readable age, for the trash listing. Deliberately coarse: the exact
  // minute something was deleted is never the question being asked.
  function relativeTime(epochSeconds) {
    if (!epochSeconds) return "some time ago"
    var secs = Math.max(0, Math.floor(Date.now() / 1000) - epochSeconds)
    if (secs < 90) return "just now"
    var mins = Math.round(secs / 60)
    if (mins < 60) return mins + (mins === 1 ? " minute ago" : " minutes ago")
    var hours = Math.round(mins / 60)
    if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
    var days = Math.round(hours / 24)
    return days + (days === 1 ? " day ago" : " days ago")
  }

  // How far off a reminder is, for the note's own hint text.
  function relativeFuture(iso) {
    var at = Date.parse(iso)
    if (!isFinite(at)) return ""
    var mins = Math.round((at - Date.now()) / 60000)
    if (mins <= 0) return "due"
    if (mins < 60) return "in " + mins + (mins === 1 ? " minute" : " minutes")
    var hours = Math.round(mins / 60)
    if (hours < 24) return "in " + hours + (hours === 1 ? " hour" : " hours")
    var days = Math.round(hours / 24)
    return "in " + days + (days === 1 ? " day" : " days")
  }

  // ------------------------------------------------------------- export

  // Everything as one document, newest section last. Written through a helper
  // rather than assembled in QML so the file lands atomically.
  function exportAll(path, includeArchived) {
    var parts = []
    for (var i = 0; i < notes.count; i++) {
      var n = notes.get(i)
      if (n.archived && !includeArchived) continue
      if (n.pending) continue
      // A note's title is its first line, so promoting that line to a heading
      // and then printing the body verbatim would say it twice. Only an
      // explicit frontmatter title is additional to the body.
      var body = String(n.body || "").replace(/\s+$/, "")
      if (!(n.title && n.title.length)) {
        var nl = body.indexOf("\n")
        body = nl < 0 ? "" : body.slice(nl + 1).replace(/^\n+/, "")
      }
      parts.push("## " + deriveTitle(n.body, n.title)
                 + (n.archived ? "  (archived)" : "")
                 + (body.length ? "\n\n" + body + "\n" : "\n"))
    }
    var doc = "# NoteStrip notes\n\n" + parts.join("\n---\n\n")
    exportProc.exec(["bash", "-c", 'cat > "$1"', "_", path])
    exportProc.write(doc)
    exportProc.stdinEnabled = false
    return parts.length
  }

  property Process exportProc: Process { stdinEnabled: true }

  // ------------------------------------------------------------- files

  property Process trashProc: Process {
    onExited: {
      root.removing = ({})
      root.rescan()
    }
  }
  property Process purgeProc: Process {}

  property Process scanProc: Process {
    command: ["bash", "-c",
      'mkdir -p "$1" "$2" && cd "$1" && ls -1 2>/dev/null || true',
      "_", root.notesDir, root.trashDir]
    stdout: StdioCollector {
      onStreamFinished: root.scanBuffer = text
    }
    onExited: function (exitCode) {
      // A scan that did not finish cleanly says nothing about what is on disk,
      // and acting on it would reap live notes.
      if (exitCode === 0) root.syncFiles(root.scanBuffer)
      root.scanBuffer = ""
      if (root.scanQueued) {
        root.scanQueued = false
        Qt.callLater(root.rescan)
      }
    }
  }

  // Scans are serialised, and only a cleanly finished one is believed.
  //
  // This used to restart the scan process mid-flight on every request. The
  // directory is watched, and every autosave touches it, so requests stack up
  // constantly -- and killing a running `ls` hands back a truncated or empty
  // listing. An empty listing reads as "there are no notes", so the reap pass
  // below deleted every row and the next scan re-added them as blank
  // placeholders. For whichever note was open at the time, that emptied the
  // editor in front of the user while they were typing in it.
  property bool scanQueued: false
  property string scanBuffer: ""

  // How many times a scan has decided a row's file is gone. Steady-state this
  // only moves when a note is genuinely deleted from disk. If it climbs while
  // notes are merely being edited, scanning is racing its own writes and live
  // notes are being torn down and rebuilt underneath the UI -- which is what
  // blanked an open editor mid-sentence. Exposed so that is assertable rather
  // than something you notice by losing a note.
  property int reapCount: 0

  function rescan() {
    if (scanProc.running) { root.scanQueued = true; return }
    scanProc.running = true
  }

  // FileView cannot watch a path that does not exist yet, but it can watch the
  // directory holding it. A change here means a note file was created or
  // deleted, by us or by anything else touching the folder.
  property FileView dirWatch: FileView {
    path: root.notesDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.rescan()
  }

  property FileView floatsFile: FileView {
    path: root.floatsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text() || "{}")
        root.floats = (parsed && typeof parsed === "object") ? parsed : ({})
      } catch (e) {
        root.floats = ({})
      }
      root.floatIds = Object.keys(root.floats)
      root.floatsReady = true
      root.pruneFloats()
    }
    onFileChanged: reload()
    onLoadFailed: { root.floats = ({}); root.floatIds = []; root.floatsReady = true }
  }

  property FileView orderFile: FileView {
    path: root.orderPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var ids = String(text() || "").split("\n").filter(function (s) { return s.length })
      root.order = ids
      root.applyOrder()
    }
    onFileChanged: reload()
    onLoadFailed: root.order = []
  }

  // One view per note. Gives every note atomic writes and live reload when
  // something outside NoteStrip edits the file, without a central write queue.
  property Instantiator noteViews: Instantiator {
    model: root.notes
    delegate: FileView {
      required property string noteId
      required property string file
      path: file
      watchChanges: true
      atomicWrites: true
      printErrors: false
      onLoaded: root.ingest(noteId, text())
      onFileChanged: reload()
    }
  }

  Component.onCompleted: root.rescan()
}
