#!/bin/bash
# tests/integration/81-telemetry.sh — S-03 (telemetry write, CT-8) + S-04
# (cache preservation + shell throttle). The statusline persists cost and
# rate-limit telemetry into the store; the digest cost line and v0.3 resume
# reset-time both read it.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
export TZ=UTC LC_ALL=C
export SUPERVISOR_NOW=1753689600   # pinned so telemetry ts is deterministic

t_sandbox   # SUPERVISOR_TEST_MODE=1 + SUPERVISOR_DATA_DIR="$T/data"

SL="$PLUGIN_ROOT/scripts/statusline.sh"
TPY="$PLUGIN_ROOT/scripts/py/telemetry.py"
FIX="$PLUGIN_ROOT/tests/fixtures/payloads"
RL="$T/data/telemetry/rate_limits.json"

wait_file() {  # wait_file <path> [max_tenths]; 0 when it appears
  local i=0 max=${2:-50}
  while [ $i -lt "$max" ]; do [ -f "$1" ] && return 0; sleep 0.1; i=$((i+1)); done
  [ -f "$1" ]
}
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
backdate() {  # backdate <path> <seconds-ago>
  python3 - "$1" "$2" <<'PY'
import os, sys, time
p, secs = sys.argv[1], int(sys.argv[2])
t = time.time() - secs
os.utime(p, (t, t))
PY
}

# ============================ S-03: telemetry write ============================
# Drive the render (which spawns telemetry.py in the background) with the full
# fixture, then wait for the account-scoped file and assert its exact contract.
"$SL" < "$FIX/statusline-full.json" >/dev/null 2>&1
wait_file "$RL" || fail "S-03 statusline did not spawn a telemetry write of rate_limits.json"

assert_jq '.v == 1' "$RL"
assert_jq ".ts == $SUPERVISOR_NOW" "$RL"
assert_jq '.five_hour.resets_at == 1738425600' "$RL"
assert_jq '.seven_day.resets_at == 1738857600' "$RL"
assert_jq '.five_hour.used_percentage == 62' "$RL"
assert_jq '.seven_day.used_percentage == 18' "$RL"
python3 -c "import json,sys; json.load(open('$RL'))" || fail "S-03 rate_limits.json not valid JSON"
perm=$(stat -f '%Lp' "$RL" 2>/dev/null || stat -c '%a' "$RL" 2>/dev/null)
[ "$perm" = "600" ] || fail "S-03 rate_limits.json mode $perm != 600"
ls "$T/data/telemetry/".*.tmp* >/dev/null 2>&1 && fail "S-03 atomic-write .tmp residue left behind"

# session snapshot carries the cost figure (joined to a run by the digest)
SESS="$T/data/telemetry/sessions/sess-0001.json"
wait_file "$SESS" 20 || fail "S-03 session snapshot not written"
assert_jq '.total_cost_usd == 0.42' "$SESS"
assert_jq '.session_id == "sess-0001"' "$SESS"

# ======================= S-04a: shell throttle blocks spawn ===================
# A FRESH rate_limits.json (< 30 s) must make the statusline skip the spawn
# entirely — proven by the file being untouched after a FULL-fixture render
# (full WOULD overwrite it if a telemetry process ran).
printf '{"v":1,"ts":222222,"five_hour":{"used_percentage":1,"resets_at":1}}' > "$RL"
before_mt=$(mtime "$RL")
"$SL" < "$FIX/statusline-full.json" >/dev/null 2>&1
# The throttle decision is synchronous and made BEFORE any spawn; when it skips,
# no writer exists, so the file is guaranteed untouched. Assert immediately.
assert_jq '.ts == 222222' "$RL"
after_mt=$(mtime "$RL")
[ "$before_mt" = "$after_mt" ] || fail "S-04a fresh cache mutated — throttle failed to block the spawn"

# ======================= S-04b: throttle opens when stale =====================
# Backdate the cache past the 30 s window; a FULL render must now spawn and
# refresh it (rate_limits present in the input).
backdate "$RL" 60
"$SL" < "$FIX/statusline-full.json" >/dev/null 2>&1
i=0; while [ $i -lt 50 ]; do
  [ "$(jq -r '.ts' "$RL" 2>/dev/null)" = "$SUPERVISOR_NOW" ] && break
  sleep 0.1; i=$((i+1))
done
assert_jq ".ts == $SUPERVISOR_NOW" "$RL"
assert_jq '.five_hour.resets_at == 1738425600' "$RL"

# ================= S-04c: minimal input never clobbers the cache ==============
# Even when telemetry.py runs (past its own 2 s guard), a statusline JSON with
# NO rate_limits must leave the cached rate_limits.json intact.
printf '{"v":1,"ts":333333,"five_hour":{"used_percentage":7,"resets_at":7}}' > "$RL"
backdate "$RL" 10
"$TPY" --data-dir "$T/data" < "$FIX/statusline-minimal.json"; rc=$?
assert_exit0 $rc
assert_jq '.ts == 333333' "$RL"
assert_jq '.five_hour.resets_at == 7' "$RL"

# ==================== S-05: telemetry opt-out gate (config, CT-5) =============
# The user-settable knob config.json {"telemetry":false} MUST suppress the
# persist side-effect (CT-5; design 14.1; skills/config/SKILL.md). Regression
# guard for the jq `//` "false-is-empty" bug (SUP-TEL-01) that made the opt-out
# a silent no-op. Each sub-case uses a FRESH data dir so it is independent of
# the writes S-03/S-04 already made into "$T/data". The gate decision is
# synchronous and precedes any spawn, so an opted-out render spawns NO writer
# and no telemetry file can ever appear; wait_file bounds the negative check at
# ~2s (anti-hang: well under the 15s per-test cap; any spawned telemetry.py
# carries "$T" in its argv and is reaped by t_teardown's pkill).

# (a) opt-out: telemetry:false -> no rate_limits.json AND no session snapshot
GATE="$T/gate"; mkdir -p "$GATE"
export SUPERVISOR_DATA_DIR="$GATE"
GRL="$GATE/telemetry/rate_limits.json"
GSESS="$GATE/telemetry/sessions/sess-0001.json"
printf '{"v":1,"telemetry":false}' > "$GATE/config.json"
"$SL" < "$FIX/statusline-full.json" >/dev/null 2>&1
if wait_file "$GRL" 20; then fail "S-05 opt-out ignored: rate_limits.json written despite telemetry:false"; fi
[ -f "$GSESS" ] && fail "S-05 opt-out ignored: session snapshot written despite telemetry:false"

# (b) opt-in: telemetry:true still persists (same fresh dir, throttle open)
printf '{"v":1,"telemetry":true}' > "$GATE/config.json"
"$SL" < "$FIX/statusline-full.json" >/dev/null 2>&1
wait_file "$GRL" || fail "S-05 telemetry:true must still persist rate_limits.json"
assert_jq ".ts == $SUPERVISOR_NOW" "$GRL"

# (c) no config at all -> default ON still persists (another fresh dir)
GATE2="$T/gate2"; mkdir -p "$GATE2"
export SUPERVISOR_DATA_DIR="$GATE2"
GRL2="$GATE2/telemetry/rate_limits.json"
"$SL" < "$FIX/statusline-full.json" >/dev/null 2>&1
wait_file "$GRL2" || fail "S-05 no-config default (telemetry ON) must persist rate_limits.json"

echo "S-03/S-04/S-05 ok: telemetry write (CT-8), throttle blocks fresh + opens stale, minimal preserves cache, opt-out gate honored (SUP-TEL-01)"
