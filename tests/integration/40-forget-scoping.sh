#!/bin/bash
# tests/integration/40-forget-scoping.sh — A-11 (CT-16, design U16, critic SEC-04).
#
# forget must delete EXACTLY this project's footprint across the whole data dir
# (project store, its telemetry rows, its awake locks, its armed sleepers, its
# ledger entries), truncate debug.log, and touch nothing account-scoped
# (rate_limits.json) or belonging to another project. --all wipes everything.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

t_sandbox

CTL="$PLUGIN_ROOT/scripts/supervisorctl.sh"
PYC="$PLUGIN_ROOT/scripts/py/supervisor_common.py"
DD="$CLAUDE_PLUGIN_DATA"

# Two projects with distinct realpath-derived keys.
projA="$T/projA"; projB="$T/projB"
mkdir -p "$projA" "$projB"
keyA=$(python3 "$PYC" key "$projA")
keyB=$(python3 "$PYC" key "$projB")
[ -n "$keyA" ] && [ -n "$keyB" ] && [ "$keyA" != "$keyB" ] || fail "project keys unset/equal"

# ---- seed the store ----
mkdir -p "$DD/projects/$keyA" "$DD/projects/$keyB" \
         "$DD/telemetry/sessions" "$DD/awake" "$DD/resume/pending" "$DD/logs"
printf 'sidA1\nsidA2\n' > "$DD/projects/$keyA/sessions.index"
printf 'sidB1\n'         > "$DD/projects/$keyB/sessions.index"
echo '{"v":1,"ts":1,"s":"sidA1","k":"edit","p":"a.py"}' > "$DD/projects/$keyA/events.jsonl"
echo '{"v":1,"ts":1,"s":"sidB1","k":"edit","p":"b.py"}' > "$DD/projects/$keyB/events.jsonl"

echo '{"v":1,"session_id":"sidA1"}' > "$DD/telemetry/sessions/sidA1.json"
echo '{"v":1,"session_id":"sidA2"}' > "$DD/telemetry/sessions/sidA2.json"
echo '{"v":1,"session_id":"sidB1"}' > "$DD/telemetry/sessions/sidB1.json"
cp "$DD/telemetry/sessions/sidB1.json" "$T/sidB1.snapshot"

echo '{"v":1,"mode":"caffeinate","holder_pid":424242,"claude_pid":515151}' > "$DD/awake/sidA1.lock"

# A dead-pid armed sleeper for project A (cwd keys to A), plus one for B.
cat > "$DD/resume/pending/sidA1.json" <<JSON
{"v":1,"pid":999991,"due":$((SUPERVISOR_NOW+3600)),"session":"sidA1","cwd":"$projA","window_key":"wA","attempt":1}
JSON
cat > "$DD/resume/pending/sidB1.json" <<JSON
{"v":1,"pid":999992,"due":$((SUPERVISOR_NOW+3600)),"session":"sidB1","cwd":"$projB","window_key":"wB","attempt":1}
JSON

printf '{"v":1,"attempts":[{"ts":1,"ok":true,"session":"sidA1","window_key":"wA","attempt":1},{"ts":2,"ok":false,"session":"sidA2","window_key":"wA","attempt":2},{"ts":3,"ok":true,"session":"sidB1","window_key":"wB","attempt":1}]}\n' > "$DD/resume/state.json"

printf 'prev output\nFORGET_CANARY_A trailing\n' > "$DD/resume/last.log"
printf 'some debug bytes here\n' > "$DD/logs/debug.log"
echo '{"v":1,"ts":1,"five_hour":{"used_percentage":50}}' > "$DD/telemetry/rate_limits.json"
cp "$DD/telemetry/rate_limits.json" "$T/rate_limits.snapshot"

# =====================================================================
# (a) dry run — enumerate, delete NOTHING, exit 3
# =====================================================================
out=$( cd "$projA" && "$CTL" --data-dir "$DD" forget ); rc=$?
[ "$rc" -eq 3 ] || fail "(a) dry-run exit want 3 got $rc"
printf '%s\n' "$out" | grep -q "$keyA" || fail "(a) project A key not enumerated"
printf '%s\n' "$out" | grep -Fq "telemetry/sessions/sidA1.json" || fail "(a) A telemetry row not enumerated"
printf '%s\n' "$out" | grep -Fq "awake/sidA1.lock" || fail "(a) A awake lock not enumerated"
printf '%s\n' "$out" | grep -Fq "resume/pending/sidA1.json" || fail "(a) A sleeper not enumerated"
printf '%s\n' "$out" | grep -Eiq "debug.log.*truncat" || fail "(a) debug truncation not enumerated"
printf '%s\n' "$out" | grep -Fq "rate_limits.json" || fail "(a) rate_limits not named under WILL NOT"
printf '%s\n' "$out" | grep -q "WILL NOT DELETE" || fail "(a) missing WILL NOT section"
# dry run must not have touched anything
assert_file_exists "$DD/projects/$keyA/events.jsonl"
assert_file_exists "$DD/resume/pending/sidA1.json"
[ -s "$DD/logs/debug.log" ] || fail "(a) dry-run truncated debug.log"

# =====================================================================
# (b) confirmed per-project forget — exit 0, scoped deletion
# =====================================================================
out=$( cd "$projA" && "$CTL" --data-dir "$DD" forget --yes ); rc=$?
[ "$rc" -eq 0 ] || fail "(b) forget --yes exit want 0 got $rc"

[ -d "$DD/projects/$keyA" ] && fail "(b) project A dir survived"
[ -d "$DD/projects/$keyB" ] || fail "(b) project B dir was deleted"
[ -e "$DD/telemetry/sessions/sidA1.json" ] && fail "(b) A telemetry sidA1 survived"
[ -e "$DD/telemetry/sessions/sidA2.json" ] && fail "(b) A telemetry sidA2 survived"
cmp -s "$DD/telemetry/sessions/sidB1.json" "$T/sidB1.snapshot" || fail "(b) B telemetry changed"
[ -e "$DD/awake/sidA1.lock" ] && fail "(b) A awake lock survived"
[ -e "$DD/resume/pending/sidA1.json" ] && fail "(b) A sleeper survived"
[ -e "$DD/resume/pending/sidB1.json" ] || fail "(b) B sleeper was deleted"
grep -Fq "sidA1" "$DD/resume/state.json" && fail "(b) sidA1 still in ledger"
grep -Fq "sidA2" "$DD/resume/state.json" && fail "(b) sidA2 still in ledger"
grep -Fq "sidB1" "$DD/resume/state.json" || fail "(b) sidB1 dropped from ledger"
[ -f "$DD/logs/debug.log" ] || fail "(b) debug.log removed instead of truncated"
[ -s "$DD/logs/debug.log" ] && fail "(b) debug.log not truncated to empty"
cmp -s "$DD/telemetry/rate_limits.json" "$T/rate_limits.snapshot" || fail "(b) account-scoped rate_limits changed"

# =====================================================================
# (d) second per-project run — nothing left, still exit 0
# =====================================================================
( cd "$projA" && "$CTL" --data-dir "$DD" forget --yes ) >/dev/null; rc=$?
[ "$rc" -eq 0 ] || fail "(d) second forget --yes exit want 0 got $rc"

# =====================================================================
# (c) forget --all on a fresh data dir — whole tree gone, canary empty
# =====================================================================
DD2="$T/data2"
mkdir -p "$DD2/projects/$keyA" "$DD2/resume" "$DD2/telemetry/sessions"
printf 'sidA1\n' > "$DD2/projects/$keyA/sessions.index"
echo '{"v":1}' > "$DD2/projects/$keyA/events.jsonl"
printf 'FORGET_CANARY_A here\n' > "$DD2/resume/last.log"

out=$( cd "$projA" && "$CTL" --data-dir "$DD2" forget --all ); rc=$?
[ "$rc" -eq 3 ] || fail "(c) --all dry-run exit want 3 got $rc"
[ -d "$DD2" ] || fail "(c) --all dry-run must not delete"

( cd "$projA" && "$CTL" --data-dir "$DD2" forget --all --yes ) >/dev/null; rc=$?
[ "$rc" -eq 0 ] || fail "(c) --all --yes exit want 0 got $rc"
[ -d "$DD2" ] && fail "(c) data dir survived --all --yes"
# fixed-string grep for the project path, its sids, and the canary — all empty
for needle in "$keyA" "sidA1" "FORGET_CANARY_A"; do
  if grep -RFq -- "$needle" "$DD2" 2>/dev/null; then fail "(c) needle survived --all: $needle"; fi
done

echo "A-11 ok: per-project scoping, ledger/telemetry/lock/sleeper pruning, --all wipe"
