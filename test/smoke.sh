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

# shellcheck disable=SC2317  # reached via trap, not by falling through
cleanup() {
  [[ -n ${PID:-} ]] && kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  rm -rf "$DATA"
}
trap cleanup EXIT

echo "ledge smoke test"
echo "  data: $DATA"

# Suppress the first-run welcome note for the main body of the suite, using the
# same marker the app itself writes rather than a test-only switch. Seeding gets
# its own instance further down.
touch "$DATA/.seeded"

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
ipc create "" >/dev/null
settle
is "blank note is listed while open" "$(count)" "2"
is "blank note is not on disk" "$(find "$DATA/notes" -name '*.md' | wc -l)" "1"
ipc close >/dev/null; settle
is "blank note is discarded on close" "$(count)" "1"
is "discarding leaves no trash" "$(find "$DATA/trash" -name '*.md' 2>/dev/null | wc -l)" "0"

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
is "deleted note is in the trash" "$(find "$DATA/trash" -name "*$B*" | wc -l)" "1"
ipc refreshTrash >/dev/null; sleep 0.5
is "trash listing finds it" "$(ipc trash | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')" "1"
is "trash listing recovers the title" "$(ipc trash | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["title"])')" "beta"
TRASHED=$(basename "$(find "$DATA/trash" -name "*$B*" | head -1)")
ipc restore "$TRASHED" >/dev/null; sleep 1.2
is "restored note is back" "$(count)" "4"

# --- writes must not disturb the note being written ---------------------------
# The notes directory is watched, so every save triggers a rescan. Restarting a
# running scan handed back a truncated listing, which read as "no notes exist"
# and reaped every row; the next scan re-added them empty. Whoever had a note
# open watched it blank itself mid-sentence.
# Measure the delta across the writes only. Counting cumulatively swept up the
# delete test above, where a file legitimately does disappear, which made this
# fail intermittently for a reason that had nothing to do with what it claims.
reaped_before=$(ipc stats | python3 -c 'import sys,json;print(json.load(sys.stdin)["reaped"])')
CHURN=$(ipc create "keep line")
settle
for extra in a b c d e; do
  ipc append "line $extra" >/dev/null
  sleep 0.5
done
sleep 1
reaped_after=$(ipc stats | python3 -c 'import sys,json;print(json.load(sys.stdin)["reaped"])')
is "writing a note never tears its row down" "$(( reaped_after - reaped_before ))" "0"
churn_body=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2' "$DATA/notes/$CHURN.md" | tr -d '\n')
is "repeated writes keep every line" "$churn_body" "keep lineline aline bline cline dline e"
is "and do not duplicate the note" "$(find "$DATA/notes" -name "$CHURN.md" | wc -l)" "1"
is "and leave it loaded, not a blank placeholder" \
   "$(ipc list | python3 -c "
import sys,json
print(next((n['title'] for n in json.load(sys.stdin) if n['id']=='$CHURN'), 'MISSING'))")" "keep line"

# --- reminders ----------------------------------------------------------------
ipc remind "$A" 90m >/dev/null
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
# The window rules are what make a popped note a sticky note rather than just
# another tiled window, and they have failed silently more than once. Ask the
# compositor rather than trusting that the rules were sent.
is "popped note floats in the compositor" "$(hyprctl -j clients 2>/dev/null | python3 -c "
import sys,json
c = next((c for c in json.load(sys.stdin) if c['title'] == 'ledge-note:$A'), None)
print('no window' if c is None else 'floating' if c['floating'] else 'tiled')" 2>/dev/null)" "floating"
ipc dock "$A" >/dev/null; sleep 0.8
is "docked note is no longer floating" "$(python3 -c "
import json;d=json.load(open('$DATA/floats.json'));print(len(d))" 2>/dev/null)" "0"

# --- a new note arrives as a sticky, not as a dash on the strip ---------------
before=$(count)
ipc toggleNew >/dev/null; sleep 1.5
is "a new note is created floating" "$(python3 -c "
import json;d=json.load(open('$DATA/floats.json'));print(len(d))" 2>/dev/null)" "1"
NEWID=$(python3 -c "
import json;print(list(json.load(open('$DATA/floats.json')))[0])" 2>/dev/null)
is "and takes the keyboard, so it can be typed into" "$(hyprctl -j activewindow 2>/dev/null | python3 -c "
import sys,json
print(json.load(sys.stdin).get('title'))" 2>/dev/null)" "ledge-note:$NEWID"
ipc toggleNew >/dev/null; sleep 1.2
is "pressing again puts it away" "$(python3 -c "
import json;d=json.load(open('$DATA/floats.json'));print(len(d))" 2>/dev/null)" "0"
is "and a note nobody typed into leaves nothing behind" "$(count)" "$before"

# --- a float entry never outlives its note ------------------------------------
# A note that has never been typed into has no file by design, so popping one
# out and restarting used to leave an id in floats.json naming nothing at all.
python3 - "$DATA/floats.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["ghost-note-that-does-not-exist"] = {"monitor": "", "x": 10, "y": 10, "w": 300, "h": 200}
json.dump(d, open(p, "w"))
PY
sleep 1.5
is "a float entry naming no note is pruned" "$(python3 -c "
import json;d=json.load(open('$DATA/floats.json'));print('ghost-note-that-does-not-exist' in d)" 2>/dev/null)" "False"

# --- attachments --------------------------------------------------------------
# Clipboard tests are opt-in: the clipboard is global, and a test run has no
# business overwriting whatever the user had on it.
if [[ ${LEDGE_TEST_CLIPBOARD:-0} == 1 ]] && command -v wl-copy >/dev/null; then
  ATT=$(ipc create "note with a picture"); settle
  magick -size 40x40 xc:teal "$DATA/probe.png" 2>/dev/null \
    || convert -size 40x40 xc:teal "$DATA/probe.png" 2>/dev/null
  wl-copy --type image/png < "$DATA/probe.png"; sleep 0.4
  ipc attach "$ATT" >/dev/null; sleep 1.2
  is "clipboard image becomes an attachment" "$(find "$DATA/attachments/$ATT" -type f 2>/dev/null | wc -l)" "1"

  printf 'plain text' | wl-copy; sleep 0.4
  ipc attach "$ATT" >/dev/null; sleep 1.2
  is "clipboard text does not" "$(find "$DATA/attachments/$ATT" -type f 2>/dev/null | wc -l)" "1"

  ipc remove "$ATT" >/dev/null; sleep 1.2
  is "deleting a note takes its attachments" "$([[ -d $DATA/attachments/$ATT ]] && echo present || echo gone)" "gone"
  wl-copy --clear 2>/dev/null || true
else
  echo "  skip attachments (set LEDGE_TEST_CLIPBOARD=1 to include; it overwrites your clipboard)"
fi

# --- first run ----------------------------------------------------------------
# A separate instance against a genuinely untouched directory, since the suite
# above deliberately starts from a seeded marker.
FRESH=$(mktemp -d /tmp/ledge-fresh.XXXXXX)
LEDGE_DATA_DIR="$FRESH" qs --path "$SHELL_DIR" >"$FRESH/log" 2>&1 &
FPID=$!
for _ in $(seq 1 60); do
  qs ipc --pid "$FPID" call ledge ping >/dev/null 2>&1 && break
  sleep 0.2
done
sleep 1.2
fresh_titles=$(qs ipc --pid "$FPID" call ledge list 2>/dev/null \
  | python3 -c 'import sys,json;print(",".join(n["title"] for n in json.load(sys.stdin)))')
is "a fresh install seeds one welcome note" "$fresh_titles" "Welcome to Ledge"
is "and records that it did" "$([[ -f $FRESH/.seeded ]] && echo yes)" "yes"

# Deleting everything must not bring it back on the next start.
for nid in $(qs ipc --pid "$FPID" call ledge list 2>/dev/null \
             | python3 -c 'import sys,json
for n in json.load(sys.stdin): print(n["id"])'); do
  qs ipc --pid "$FPID" call ledge remove "$nid" >/dev/null 2>&1
done
sleep 1
kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null
LEDGE_DATA_DIR="$FRESH" qs --path "$SHELL_DIR" >>"$FRESH/log" 2>&1 &
FPID=$!
for _ in $(seq 1 60); do
  qs ipc --pid "$FPID" call ledge ping >/dev/null 2>&1 && break
  sleep 0.2
done
sleep 1.2
is "and does not seed again once emptied" \
   "$(qs ipc --pid "$FPID" call ledge list 2>/dev/null | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')" "0"
kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null
rm -rf "$FRESH"

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
