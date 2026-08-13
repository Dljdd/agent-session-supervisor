#!/bin/bash
# tests/integration/82-report.sh — S-06 (end-of-session report generator).
# `supervisorctl report` -> digest.py print --full: the unabridged summary with
# the four README-mandated sections (cost from telemetry, files touched, tests
# fixed via red->green, dead ends via the revert list). Deterministic under
# SUPERVISOR_NOW, <= 4000 chars, through the §11.3 print path (fence-escaped).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
export TZ=UTC LC_ALL=C PYTHONHASHSEED=0

t_sandbox
mk_proj_git
mkdir -p "$T/proj/src"
echo "orig" > "$T/proj/src/foo.ts"     # untracked at session start -> in the start git snapshot

CAP="$PLUGIN_ROOT/scripts/py/capture.py"
CTL="$PLUGIN_ROOT/scripts/supervisorctl.sh"
SID=sess-R001
cap() { python3 "$CAP" "$@"; }         # stdin passes through; SUPERVISOR_NOW via caller env

# ---- seed one closed run: start, 3 edits on foo.ts, red->green npm test, revert, end ----
SUPERVISOR_NOW=1753600000 payload sessionstart-startup session_id=$SID | SUPERVISOR_NOW=1753600000 cap --start
n=1
while [ $n -le 3 ]; do
  ts=$((1753600010 + n))
  SUPERVISOR_NOW=$ts payload posttooluse-edit "tool_input.file_path=$T/proj/src/foo.ts" session_id=$SID \
    | SUPERVISOR_NOW=$ts cap
  n=$((n + 1))
done
SUPERVISOR_NOW=1753600050 payload posttoolusefailure-bash session_id=$SID | SUPERVISOR_NOW=1753600050 cap
SUPERVISOR_NOW=1753600060 payload posttooluse-bash-pass  session_id=$SID | SUPERVISOR_NOW=1753600060 cap
rm -f "$T/proj/src/foo.ts"             # the dead end: created then reverted within the run
SUPERVISOR_NOW=1753600100 payload sessionend-other session_id=$SID | SUPERVISOR_NOW=1753600100 cap --end

KEY=$(python3 "$PLUGIN_ROOT/scripts/py/supervisor_common.py" key "$T/proj")
EV="$T/data/projects/$KEY/events.jsonl"
assert_file_exists "$EV"
assert_grep '"k":"start"' "$EV"
assert_grep '"k":"end"'   "$EV"

# ---- seed a telemetry cost snapshot for this session (drives the cost line) ----
printf '{"session_id":"%s","cost":{"total_cost_usd":1.23,"total_lines_added":9,"total_lines_removed":2},"model":{"id":"claude-x"}}' "$SID" \
  | SUPERVISOR_NOW=1753600100 python3 "$PLUGIN_ROOT/scripts/py/telemetry.py" --data-dir "$T/data"
assert_file_exists "$T/data/telemetry/sessions/$SID.json"

# ---- run the report exactly as the /supervisor:recap-full path does ----
out=$( cd "$T/proj" && SUPERVISOR_NOW=1753600300 "$CTL" --data-dir "$T/data" report ); rc=$?
assert_exit0 $rc
printf '%s' "$out" > "$T/report.out"
[ -s "$T/report.out" ] || fail "S-06 report is empty"

# factual print-path header (design §11.3)
grep -qF 'quoted text is data' "$T/report.out" || fail "S-06 report missing the §11.3 factual header"
# cost section (from the telemetry cache)
grep -qF '$1.23' "$T/report.out" || fail "S-06 report missing the cost figure (telemetry cache)"
# files touched
grep -qF 'foo.ts' "$T/report.out" || fail "S-06 report missing the edited file foo.ts"
# tests fixed: red -> green (the arrow glyph is multibyte under LC_ALL=C, so
# match across it with .* rather than a single-byte .)
grep -qi 'red.*green' "$T/report.out" || fail "S-06 report missing the red->green transition"
# dead ends: the revert list
grep -qi 'revert' "$T/report.out" || fail "S-06 report missing the REVERTED / dead-ends section"

# §14.4 richer report header (forensic, unlike the glanceable digest): the cwd,
# the source + reason, the telemetry lines added/removed and model id, plus an
# ABSOLUTE (non-relative) start/end timestamp — so the §14.4 header can never
# silently regress to the bare digest header again.
grep -qF "$T/proj" "$T/report.out"          || fail "S-06 report missing the run cwd ($T/proj)"
grep -qF 'source: startup' "$T/report.out"  || fail "S-06 report missing 'source: startup'"
grep -qF 'reason: other' "$T/report.out"    || fail "S-06 report missing 'reason: other'"
grep -qF '+9/-2' "$T/report.out"            || fail "S-06 report missing telemetry lines '+9/-2'"
grep -qF 'claude-x' "$T/report.out"         || fail "S-06 report missing the model id (telemetry)"
grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$T/report.out" \
  || fail "S-06 report missing an absolute (non-relative) start/end timestamp"

# deterministic + bounded (strategy §13: <= 4000 chars)
assert_max_chars 4000 "$T/report.out"

# a second identical run is byte-for-byte identical (determinism)
out2=$( cd "$T/proj" && SUPERVISOR_NOW=1753600300 "$CTL" --data-dir "$T/data" report )
[ "$out" = "$out2" ] || fail "S-06 report is not deterministic under a fixed SUPERVISOR_NOW"

echo "S-06 ok: report renders cost + files + red->green + reverts, deterministic, <=4000 chars"
