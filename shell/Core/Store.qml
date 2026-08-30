pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Notes on disk, and the model the UI binds to.
//
//   ~/.local/share/ledge/notes/<id>.md    one file per note, YAML frontmatter
//   ~/.local/share/ledge/order            note ids, one per line, display order
//   ~/.local/share/ledge/trash/           deleted notes, kept for undo
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
    var override = Quickshell.env("LEDGE_DATA_DIR")
    return (override && override.length) ? override : home + "/.local/share/ledge"
  }
  readonly property string notesDir: dataDir + "/notes"
  readonly property string trashDir: dataDir + "/trash"
  readonly property string orderPath: dataDir + "/order"
  readonly property string floatsPath: dataDir + "/floats.json"

  readonly property ListModel notes: ListModel {}

  property bool ready: false
  property var order: []

  // Visible-note count, kept as plain state rather than derived in the view.
  // Binding a window's `visible` to a child ListView's count makes the child's
  // existence depend on the window it lives in, which is a loop.
  property int liveCount: 0

  function recount() {
    var c = 0
    for (var i = 0; i < notes.count; i++) if (!notes.get(i).archived) c++
    root.liveCount = c
  }

  // Popped-out notes: id -> { x, y }, in GLOBAL compositor layout coordinates.
  //
  // Global, not screen-local, so a note can be dragged from one monitor to the
  // next as one continuous movement instead of being teleported at the seam.
  // Each monitor draws whichever floats overlap it, so a note straddling the
  // boundary is simply drawn by both.
  //
  // Kept out of the note files entirely. Position changes on every frame of a
  // drag, and rewriting a note's frontmatter that often would churn the file,
  // wake every watcher, and bury real edits in a sync tool's history. This is
  // volatile window state, not part of what the note says.
  property var floats: ({})
  property var floatIds: []

  function isFloating(id) { return root.floats[id] !== undefined }

  function floatState(id) { return root.floats[id] || null }

  function setFloating(id, x, y, w, h) {
    var f = JSON.parse(JSON.stringify(root.floats))
    f[id] = {
      x: Math.round(x),
      y: Math.round(y),
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
  function setFloatGeometry(id, x, y, w, h) {
    if (!isFloating(id)) return
    if (![x, y, w, h].every(isFinite)) return
    var cur = root.floats[id]
    if (cur.x === Math.round(x) && cur.y === Math.round(y)
        && cur.w === Math.round(w) && cur.h === Math.round(h)) return
    var f = JSON.parse(JSON.stringify(root.floats))
    f[id] = { x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(h) }
    root.floats = f
    floatSaveTimer.restart()
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
      if (!seen[n.noteId] && !n.pending) notes.remove(j)
    }

    applyOrder()
    recount()
    root.ready = true
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
    var doc = "# Ledge notes\n\n" + parts.join("\n---\n\n")
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
      onStreamFinished: root.syncFiles(text)
    }
  }

  function rescan() { scanProc.running = false; scanProc.running = true }

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
  // something outside Ledge edits the file, without a central write queue.
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
