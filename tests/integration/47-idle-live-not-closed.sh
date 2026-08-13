#!/bin/bash
# tests/integration/47-idle-live-not-closed.sh — A-18 (critic TF-6, design §12.1).
#
# A live-but-idle session must NEVER be inferred-closed under the user; a
# genuinely dead one must be; and a resurrected run (a late signal after an
# inferred end) must be regrouped and closeable, nothing orphaned (§9.1).
#
# ANTI-HANG: the single spawned process (a live-pid stand-in) is tracked in
# $LIVE and hard-killed in an unconditional EXIT trap. No test sleeps; all
# time is driven by SUPERVISOR_NOW. The stand-in's comm check is satisfied by
# the SUPERVISOR_FAKE_LOOKS_CLAUDE test seam (test mode only).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "python3 absent"; exit 75; }

t_sandbox
mk_proj_plain

LIVE=""
trap 'kill "$LIVE" 2>/dev/null; t_teardown' EXIT
sleep 600 &
LIVE=$!

KEY=$("$PY" "$PLUGIN_ROOT/scripts/py/supervisor_common.py" key "$T/proj") \
  || fail "project_key failed"
PDIR="$CLAUDE_PLUGIN_DATA/projects/$KEY"
mkdir -p "$PDIR" || fail "cannot make $PDIR"

NOW=${SUPERVISOR_NOW}
sweep() { "$PY" "$PLUGIN_ROOT/scripts/py/maintain.py" sweep --cwd "$T/proj"; }
count_inf() { grep -c '"inf":1' "$PDIR/events.jsonl" 2>/dev/null | tr -d ' '; }

# Session A: start (owning pid = the live stand-in) + one edit, 45 min idle.
printf '%s\n' \
 "{\"v\":1,\"ts\":$((NOW - 2700)),\"s\":\"sA\",\"k\":\"start\",\"src\":\"startup\",\"cwd\":\"$T/proj\",\"pid\":$LIVE}" \
 "{\"v\":1,\"ts\":$((NOW - 2700)),\"s\":\"sA\",\"k\":\"edit\",\"p\":\"a.ts\"}" \
 > "$PDIR/events.jsonl"

# (1) live pid -> the 30-min rule does NOT apply, no inferred end.
SUPERVISOR_FAKE_LOOKS_CLAUDE=1 sweep || fail "sweep #1 non-zero"
[ "$(count_inf)" = "0" ] || fail "a LIVE idle session was inferred-closed"

# (2) the owner dies -> the next sweep closes exactly one run.
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; LIVE=""
sweep || fail "sweep #2 non-zero"
[ "$(count_inf)" = "1" ] || fail "dead run not closed exactly once (got $(count_inf))"

# (3) resurrection: a late signal AFTER the inferred end voids it (§9.1); a
# later sweep re-closes the now-longer run; rebuild groups the late edit in.
printf '%s\n' \
 "{\"v\":1,\"ts\":$((NOW + 10)),\"s\":\"sA\",\"k\":\"edit\",\"p\":\"late.ts\"}" \
 >> "$PDIR/events.jsonl"
SUPERVISOR_NOW=$((NOW + 3600)) sweep || fail "sweep #3 non-zero"

OUT=$("$PY" "$PLUGIN_ROOT/scripts/py/digest.py" rebuild --cwd "$T/proj") \
  || fail "rebuild non-zero"
printf '%s' "$OUT" | grep -q 'late.ts' \
  || fail "rebuild digest is missing the resurrected late edit:
$OUT"

echo "A-18 ok: live-idle never closed; dead closed once; resurrection regrouped"
