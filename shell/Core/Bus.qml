pragma Singleton

import QtQuick

// One-way signals from the outside world (CLI, keybinds, IPC) into whichever
// edge strips happen to be mapped. Kept as a singleton because the strips are
// created per-monitor by Variants and have no stable id to address.
QtObject {
  // Toggle rather than plain create: pressing the new-note key again should
  // put the note away, which is what the key already feels like it does.
  signal newRequested()
  // Popping out has to go through the shell: a window rule placing the note
  // must reach the compositor before the window maps, so the shell runs that
  // first and only then adds the note to the float table.
  signal popRequested(string id, real x, real y)
  // Published by whichever strip is active, so the note currently open on the
  // edge is visible to `ledge stats` and therefore assertable.
  property string openNoteId: ""
  property bool editing: false

  signal libraryRequested()
  signal peekRequested()
  signal closeRequested()
  signal openRequested(string id)
}
