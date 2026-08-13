#!/bin/bash
# tests/integration/80-statusline-render.sh — S-01/S-02/S-05/S-07 (strategy §13).
# Drives scripts/statusline.sh directly (the plugin cannot install the main
# statusline; the user does). Byte-exact golden render, degraded render, and
# crash-proofing. The reset epochs render as HH:MM under TZ=UTC (pinned below).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
# Goldens were generated under UTC (↺16:00). Force it so a standalone run of this
# file (outside run.sh) matches byte-for-byte too.
export TZ=UTC LC_ALL=C

t_sandbox   # sets SUPERVISOR_TEST_MODE=1 + SUPERVISOR_DATA_DIR="$T/data" (DATA resolves there)

SL="$PLUGIN_ROOT/scripts/statusline.sh"
FIX="$PLUGIN_ROOT/tests/fixtures/payloads"
GOLD="$PLUGIN_ROOT/tests/fixtures/golden"

# ---- S-01: full golden render, byte-for-byte, exactly one line, exit 0 ----
"$SL" < "$FIX/statusline-full.json" > "$T/full.out" 2>"$T/full.err"; rc=$?
assert_exit0 $rc
cmp -s "$T/full.out" "$GOLD/statusline-full.out" \
  || fail "S-01 full render != golden. got: $(cat "$T/full.out")"
assert_single_line "$T/full.out"
[ -s "$T/full.err" ] && fail "S-01 statusline wrote to stderr: $(cat "$T/full.err")"

# ---- S-07: the lines segment reads cost.total_lines_added/removed ----
grep -qF '+120/-14' "$T/full.out" || fail "S-07 lines-changed segment wrong (want +120/-14)"

# ---- S-02: minimal render (no rate_limits, null used_percentage) ----
"$SL" < "$FIX/statusline-minimal.json" > "$T/min.out" 2>"$T/min.err"; rc=$?
assert_exit0 $rc
cmp -s "$T/min.out" "$GOLD/statusline-minimal.out" \
  || fail "S-02 minimal render != golden. got: $(cat "$T/min.out")"
assert_single_line "$T/min.out"
grep -qi 'null' "$T/min.out" && fail "S-02 output leaked a null literal: $(cat "$T/min.out")"
[ -s "$T/min.err" ] && fail "S-02 statusline wrote to stderr"

# ---- S-05: crash-proofing — empty stdin, {}, truncated JSON ----
# Each: exit 0, exactly one line on stdout, nothing on stderr. A broken
# statusline must never blank the user's status row.
# Use a FRESH data dir: S-01/S-02 above legitimately spawned telemetry into
# "$T/data", so the crash-case "no write" check must run against clean state.
export SUPERVISOR_DATA_DIR="$T/crashdata"
mkdir -p "$SUPERVISOR_DATA_DIR"
crash_case() {  # crash_case <label> <stdin-producer-cmd...>
  local label="$1"; shift
  "$@" | "$SL" > "$T/c.out" 2>"$T/c.err"; local r=${PIPESTATUS[1]}
  [ "$r" -eq 0 ] || fail "S-05 [$label] exit $r != 0"
  assert_single_line "$T/c.out"
  [ -s "$T/c.err" ] && fail "S-05 [$label] wrote to stderr: $(cat "$T/c.err")"
  return 0
}
crash_case empty     printf ''
grep -qx 'supervisor' "$T/c.out" || fail "S-05 empty stdin should print the fallback line"
crash_case braces    cat "$FIX/statusline-empty.json"     # {}
crash_case truncated printf '{"cost":{"total_cost_usd":0.4'
grep -qx 'supervisor' "$T/c.out" || fail "S-05 truncated JSON should print the fallback line"

# No telemetry file may result from any crash case (empty/trunc exit early;
# {} has neither rate_limits nor session_id so telemetry.py writes nothing).
# Allow the background {} spawn a moment, then assert absence.
i=0; while [ $i -lt 15 ]; do [ -f "$SUPERVISOR_DATA_DIR/telemetry/rate_limits.json" ] && break; sleep 0.1; i=$((i+1)); done
[ -f "$SUPERVISOR_DATA_DIR/telemetry/rate_limits.json" ] && fail "S-05 crash cases must not write rate_limits.json"
ls "$SUPERVISOR_DATA_DIR/telemetry/sessions/"*.json >/dev/null 2>&1 && fail "S-05 crash cases must not write a session snapshot"

echo "S-01/S-02/S-05/S-07 ok: golden full+minimal render, lines fields, crash-proofing"
