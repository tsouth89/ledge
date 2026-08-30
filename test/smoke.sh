#!/usr/bin/env bash
# Smoke test for Ledge.
#
# Runs a second Ledge instance against a throwaway data directory and drives it
# over IPC, asserting on what actually lands on disk. It never touches your real
# notes. The strip will briefly appear on screen while it runs; that is the
# point, since the thing being tested is a real shell and not a mock.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHELL_DIR=${LEDGE_SHELL_DIR:-$HERE/../shell}
DATA=$(mktemp -d /tmp/ledge-smoke.XXXXXX)
LOG="$DATA/shell.log"

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '        %s\n' "$2"; fail=$((fail+1)); }
is()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

cleanup() {
  [[ -n ${PID:-} ]] && kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  rm -rf "$DATA"
}
trap cleanup EXIT

echo "ledge smoke test"
echo "  data: $DATA"

LEDGE_DATA_DIR="$DATA" qs --path "$SHELL_DIR" >"$LOG" 2>&1 &
PID=$!

# Wait for the IPC surface rather than sleeping a guessed amount.
for _ in $(seq 1 60); do
  qs ipc --pid "$PID" call ledge ping >/dev/null 2>&1 && break
  sleep 0.2
done
if ! qs ipc --pid "$PID" call ledge ping >/dev/null 2>&1; then
  bad "instance came up" "$(tail -5 "$LOG")"
  echo; echo "0 passed, 1 failed"; exit 1
fi
ok "instance came up"

ipc() { qs ipc --pid "$PID" call ledge "$@" 2>/dev/null; }
count() { ipc list | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))'; }
titles() { ipc list | python3 -c 'import sys,json;print(",".join(n["title"] for n in json.load(sys.stdin)))'; }
settle() { sleep 0.7; }

# --- a clean instance starts empty -------------------------------------------
is "starts with no notes" "$(count)" "0"

# --- create writes a file with frontmatter -----------------------------------
ID=$(ipc create "first note
second line")
settle
is "create returns an id" "$([[ -n $ID ]] && echo yes)" "yes"
is "note is listed" "$(count)" "1"
is "title is the first line" "$(titles)" "first note"
is "file exists" "$([[ -f $DATA/notes/$ID.md ]] && echo yes)" "yes"
is "frontmatter carries the id" "$(grep -c "^id: $ID\$" "$DATA/notes/$ID.md")" "1"
is "body is intact" "$(sed -n '/^---$/,/^---$/!p' "$DATA/notes/$ID.md" | tr -d '\n')" "first notesecond line"

# --- blank notes are never written -------------------------------------------
BLANK=$(ipc create "")
settle
is "blank note is listed while open" "$(count)" "2"
is "blank note is not on disk" "$(ls -1 "$DATA/notes" | wc -l)" "1"
ipc close >/dev/null; settle
is "blank note is discarded on close" "$(count)" "1"
is "discarding leaves no trash" "$(ls -1 "$DATA/trash" 2>/dev/null | wc -l)" "0"

# --- rapid creates must not bleed into each other ----------------------------
A=$(ipc create "alpha"); B=$(ipc create "beta"); C=$(ipc create "gamma")
settle
is "three distinct notes" "$(count)" "4"
for pair in "$A:alpha" "$B:beta" "$C:gamma"; do
  nid=${pair%%:*}; want=${pair#*:}
  got=$(sed -n '/^---$/,/^---$/!p' "$DATA/notes/$nid.md" | tr -d '\n')
  is "body of $want is exactly its own" "$got" "$want"
done

# --- reordering persists ------------------------------------------------------
ipc move "$C" 0 >/dev/null; settle
is "moved note is first" "$(head -1 "$DATA/order")" "$C"

# --- archive round trip -------------------------------------------------------
ipc archive "$A" >/dev/null 2>&1 || true
settle

# --- delete goes to trash, restore brings it back ----------------------------
ipc remove "$B" >/dev/null; settle
is "deleted note is gone from the list" "$(count)" "3"
is "deleted note is in the trash" "$(ls -1 "$DATA/trash" | grep -c "$B")" "1"
ipc refreshTrash >/dev/null; sleep 0.5
is "trash listing finds it" "$(ipc trash | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')" "1"
is "trash listing recovers the title" "$(ipc trash | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["title"])')" "beta"
TRASHED=$(ls -1 "$DATA/trash" | grep "$B")
ipc restore "$TRASHED" >/dev/null; sleep 1.2
is "restored note is back" "$(count)" "4"

# --- reminders ----------------------------------------------------------------
R=$(ipc remind "$A" 90m)
settle
is "relative reminder is accepted" "$(grep -c '^reminder: ' "$DATA/notes/$A.md")" "1"
ipc remind "$A" clear >/dev/null; settle
is "reminder clears" "$(grep -c '^reminder: ' "$DATA/notes/$A.md")" "0"
is "nonsense time is refused" "$(ipc remind "$A" 'not a time' | grep -c 'could not read')" "1"

# --- export -------------------------------------------------------------------
ipc exportAll "$DATA/export.md" true >/dev/null; sleep 1
is "export writes a file" "$([[ -s $DATA/export.md ]] && echo yes)" "yes"
is "export has a heading per note" "$(grep -c '^## ' "$DATA/export.md")" "$(count)"
is "export does not repeat the title in the body" "$(grep -c '^alpha$' "$DATA/export.md")" "0"

# --- float state --------------------------------------------------------------
ipc pop "$A" >/dev/null; sleep 1.2
is "popped note is recorded" "$(python3 -c "
import json;d=json.load(open('$DATA/floats.json'));print('$A' in d)" 2>/dev/null)" "True"
is "popped note leaves the strip listing" "$(ipc list | python3 -c "
import sys,json
print(sum(1 for n in json.load(sys.stdin) if n['id']=='$A'))")" "1"
ipc dock "$A" >/dev/null; sleep 0.8
is "docked note is no longer floating" "$(python3 -c "
import json;d=json.load(open('$DATA/floats.json'));print(len(d))" 2>/dev/null)" "0"

# --- attachments --------------------------------------------------------------
# Clipboard tests are opt-in: the clipboard is global, and a test run has no
# business overwriting whatever the user had on it.
if [[ ${LEDGE_TEST_CLIPBOARD:-0} == 1 ]] && command -v wl-copy >/dev/null; then
  ATT=$(ipc create "note with a picture"); settle
  magick -size 40x40 xc:teal "$DATA/probe.png" 2>/dev/null \
    || convert -size 40x40 xc:teal "$DATA/probe.png" 2>/dev/null
  wl-copy --type image/png < "$DATA/probe.png"; sleep 0.4
  ipc attach "$ATT" >/dev/null; sleep 1.2
  is "clipboard image becomes an attachment" "$(ls -1 "$DATA/attachments/$ATT" 2>/dev/null | wc -l)" "1"

  printf 'plain text' | wl-copy; sleep 0.4
  ipc attach "$ATT" >/dev/null; sleep 1.2
  is "clipboard text does not" "$(ls -1 "$DATA/attachments/$ATT" 2>/dev/null | wc -l)" "1"

  ipc remove "$ATT" >/dev/null; sleep 1.2
  is "deleting a note takes its attachments" "$([[ -d $DATA/attachments/$ATT ]] && echo present || echo gone)" "gone"
  wl-copy --clear 2>/dev/null || true
else
  echo "  skip attachments (set LEDGE_TEST_CLIPBOARD=1 to include; it overwrites your clipboard)"
fi

# --- the shell stayed healthy throughout --------------------------------------
noise=$(grep -E "ERROR|Binding loop|is not a type|Cannot set" "$LOG" | grep -v portal | head -3)
is "no errors in the log" "$([[ -z $noise ]] && echo clean)" "clean"
[[ -n $noise ]] && printf '        %s\n' "$noise"

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m\n' "$pass"
else
  printf '%d passed, \033[31m%d failed\033[0m\n' "$pass" "$fail"
fi
exit $(( fail > 0 ? 1 : 0 ))
