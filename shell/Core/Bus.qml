pragma Singleton

import QtQuick

// One-way signals from the outside world (CLI, keybinds, IPC) into whichever
// edge strips happen to be mapped. Kept as a singleton because the strips are
// created per-monitor by Variants and have no stable id to address.
QtObject {
  // Toggle rather than plain create: pressing the new-note key again should
  // put the note away, which is what the key already feels like it does.
  signal newRequested()
  signal peekRequested()
  signal closeRequested()
  signal openRequested(string id)
}
