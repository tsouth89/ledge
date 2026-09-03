#!/usr/bin/env bash
# Verify that the 0.1 data and config paths move without losing compatibility.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_HOME=$(mktemp -d /tmp/notestrip-migration.XXXXXX)
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "$TEST_HOME/.local/share/ledge/notes" "$TEST_HOME/.config/ledge"
printf 'existing note\n' > "$TEST_HOME/.local/share/ledge/notes/example.md"
printf '{}\n' > "$TEST_HOME/.config/ledge/config.json"

HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_HOME/.local/share" \
  XDG_CONFIG_HOME="$TEST_HOME/.config" NOTESTRIP_SHELL_DIR="$ROOT/shell" \
  "$ROOT/bin/notestrip" migrate-state

[[ $(<"$TEST_HOME/.local/share/notestrip/notes/example.md") == "existing note" ]]
[[ -L "$TEST_HOME/.local/share/ledge" ]]
[[ $(readlink -f "$TEST_HOME/.local/share/ledge") == "$TEST_HOME/.local/share/notestrip" ]]
[[ -f "$TEST_HOME/.config/notestrip/config.json" ]]
[[ -L "$TEST_HOME/.config/ledge" ]]
[[ $(readlink -f "$TEST_HOME/.config/ledge") == "$TEST_HOME/.config/notestrip" ]]

# A second pass is a no-op, not a second move or a nested directory.
HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_HOME/.local/share" \
  XDG_CONFIG_HOME="$TEST_HOME/.config" NOTESTRIP_SHELL_DIR="$ROOT/shell" \
  "$ROOT/bin/notestrip" migrate-state
[[ ! -e "$TEST_HOME/.local/share/notestrip/notestrip" ]]

echo "legacy state migrates safely"
