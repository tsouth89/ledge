pragma Singleton

import QtQuick

// One-way signals from the outside world (CLI, keybinds, IPC) into whichever
// edge strips happen to be mapped. Kept as a singleton because the strips are
// created per-monitor by Variants and have no stable id to address.
QtObject {
  signal peekRequested()
  signal closeRequested()
  signal openRequested(string id)
}
