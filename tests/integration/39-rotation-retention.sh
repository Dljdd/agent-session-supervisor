#!/bin/bash
# tests/integration/39-rotation-retention.sh — A-10 (design §8.4, U7.1-2).
#
# Rotation is owned by the SessionStart sweep (maintain.py sweep), never by
# capture. This test drives `maintain.py sweep` directly — the real
# hook-session-start.sh wrapper (Task 9) merely calls it, sweep FIRST then
# capture.py --start, which is exactly the sequence reproduced here.
#
# Bounded, no sleeps. Rotation: a 10.5 MB active log rotates to .1; a capture
# call beforehand does NOT rotate. Retention: a 31-day-old archive is pruned,
# a 29-day-old archive is kept (mtimes faked, SUPERVISOR_NOW pinned).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "python3 absent"; exit 75; }

t_sandbox
mk_proj_git

KEY=$("$PY" "$PLUGIN_ROOT/scripts/py/supervisor_common.py" key "$T/proj") \
  || fail "project_key failed"
PDIR="$CLAUDE_PLUGIN_DATA/projects/$KEY"
mkdir -p "$PDIR" || fail "cannot make $PDIR"

# ---- seed a 10.5 MB active log of valid filler events -------------------
"$PY" - "$PDIR/events.jsonl" <<'PYEOF'
import json, sys
p = sys.argv[1]
line = json.dumps({"v": 1, "ts": 1753600000, "s": "old", "k": "edit",
                   "p": "src/filler/module.ts"}) + "\n"
block = line * 4096
target = 10 * 1024 * 1024 + 512 * 1024
with open(p, "w") as f:
    n = 0
    while n < target:
        f.write(block)
        n += len(block)
PYEOF
SIZE0=$(wc -c < "$PDIR/events.jsonl" | tr -d ' ')
[ "$SIZE0" -gt 10485760 ] || fail "seed file too small: $SIZE0"

# ---- capture must NOT rotate -------------------------------------------
payload posttooluse-edit | run_hook hook-capture.sh
[ -f "$PDIR/events.jsonl.1" ] && fail "capture.py rotated the log (must never)"
SIZE1=$(wc -c < "$PDIR/events.jsonl" | tr -d ' ')
[ "$SIZE1" -gt "$SIZE0" ] || fail "capture did not append to the active log"

# ---- sweep is the rotation owner ---------------------------------------
"$PY" "$PLUGIN_ROOT/scripts/py/maintain.py" sweep --cwd "$T/proj" \
  || fail "sweep exited non-zero"
assert_file_exists "$PDIR/events.jsonl.1"
ARC=$(wc -c < "$PDIR/events.jsonl.1" | tr -d ' ')
[ "$ARC" -gt 10485760 ] || fail "archive is not the big file ($ARC bytes)"

# ---- next session's start lands in a fresh, small active log -----------
payload sessionstart-startup | "$PY" "$PLUGIN_ROOT/scripts/py/capture.py" --start \
  || fail "capture --start failed"
assert_file_exists "$PDIR/events.jsonl"
NEW=$(wc -c < "$PDIR/events.jsonl" | tr -d ' ')
[ "$NEW" -lt 10000 ] || fail "post-rotation active log not small ($NEW bytes)"
assert_grep '"k":"start"' "$PDIR/events.jsonl"

# ---- retention: 31-day archive pruned, 29-day kept ---------------------
NOW=${SUPERVISOR_NOW}
rm -f "$PDIR/events.jsonl.1"
printf '%s\n' '{"v":1,"ts":1,"s":"x","k":"stop"}' > "$PDIR/events.jsonl"

printf 'archive\n' > "$PDIR/events.jsonl.1"
"$PY" -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' \
  "$PDIR/events.jsonl.1" "$((NOW - 31 * 86400))"
"$PY" "$PLUGIN_ROOT/scripts/py/maintain.py" sweep --cwd "$T/proj" \
  || fail "retention sweep (31d) non-zero"
[ -f "$PDIR/events.jsonl.1" ] && fail "31-day archive was NOT pruned"

printf 'archive\n' > "$PDIR/events.jsonl.1"
"$PY" -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' \
  "$PDIR/events.jsonl.1" "$((NOW - 29 * 86400))"
"$PY" "$PLUGIN_ROOT/scripts/py/maintain.py" sweep --cwd "$T/proj" \
  || fail "retention sweep (29d) non-zero"
assert_file_exists "$PDIR/events.jsonl.1"

echo "A-10 ok: rotation at >10MB (capture never rotates), 30-day retention"
