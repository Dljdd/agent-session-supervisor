#!/bin/bash
# tests/integration/72-resume-storm.sh — plan Task 12 / strategy §12 R-07
# (critics TF-3/SEC-09, design §18.19/21b). Two defenses against a resume storm:
#   1. arm-time singleton — a second StopFailure while a sleeper is alive must
#      NOT arm a second sleeper (<=1 armed globally, CT-7).
#   2. fire-time mutex — two sleepers waking together invoke claude exactly once
#      (resume/attempt.lock held across window-check -> invoke -> ledger).
# Anti-hang: half 1 keeps sleepers asleep on a real-future due and kills them;
# half 2 fast-forwards and bounds both sleepers. t_teardown pkills the rest.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox

SC="$PLUGIN_ROOT/scripts/py/supervisor_common.py"
CTL="$PLUGIN_ROOT/scripts/supervisorctl.sh"
SLEEPER="$PLUGIN_ROOT/scripts/resume-sleeper.sh"

wait_gone() { local n=0; while [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done; }
enable_resume() { "$CTL" --data-dir "$T/data" config set auto_resume true --i-understand-quota-spend >/dev/null; }
recorder_claude() {
  cat > "$T/bin/claude" <<EOF
#!/bin/sh
printf 'invoke\n' >> "$T/claude.log"
exit 0
EOF
  chmod +x "$T/bin/claude"
}
count_pending() { ls -A "$T/data/resume/pending" 2>/dev/null | grep -c . ; }

# ---------------------------------------------------------------------------
# R-07 half 1 — arm-time singleton across two StopFailures from different cwds
# ---------------------------------------------------------------------------
enable_resume
recorder_claude
: > "$T/claude.log"
mkdir -p "$T/data/telemetry" "$T/projA" "$T/projB"
RESET=$(( $(date +%s) + 3600 ))        # real-future -> sleeper stays asleep
printf '{"v":1,"ts":%s,"five_hour":{"used_percentage":62,"resets_at":%s}}' \
  "$SUPERVISOR_NOW" "$RESET" > "$T/data/telemetry/rate_limits.json"

payload stopfailure-ratelimit session_id=sess-stormA cwd="$T/projA" | run_hook hook-stop-failure.sh
payload stopfailure-ratelimit session_id=sess-stormB cwd="$T/projB" | run_hook hook-stop-failure.sh

n=$(count_pending)
assert_eq "1" "$n"
# The single armed sleeper is alive; no claude fired (real-future due).
PF=$(ls "$T/data/resume/pending/"*.json 2>/dev/null | head -n 1)
SL=$(jq -r '.pid' "$PF")
kill -0 "$SL" 2>/dev/null || fail "R-07: the one armed sleeper ($SL) is not alive"
[ -s "$T/claude.log" ] && fail "R-07: a sleeper fired during the arm-singleton test"
echo "ok R-07: two StopFailures -> exactly one pending sleeper (arm-time singleton)"
kill "$SL" 2>/dev/null; wait_gone "$SL"

# ---------------------------------------------------------------------------
# R-07 half 2 — fire-time mutex: two sleepers, same near-past due, empty ledger
# ---------------------------------------------------------------------------
rm -rf "$T/data/resume"; : > "$T/claude.log"
export SUPERVISOR_RESUME_FASTFORWARD=1 SUPERVISOR_RESUME_LADDER="1,1,1,1"
( exec "$SLEEPER" sess-race "$T/projA" 1753689690 "" ) & R1=$!
( exec "$SLEEPER" sess-race "$T/projA" 1753689690 "" ) & R2=$!
# Bounded join (anti-hang): never wait unconditionally on a detached child.
for p in "$R1" "$R2"; do
  n=0; while kill -0 "$p" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
  kill -0 "$p" 2>/dev/null && { kill -9 "$p" 2>/dev/null; fail "a raced sleeper did not exit within 10 s"; }
done
inv=$(wc -l < "$T/claude.log" | tr -d ' ')
assert_eq "1" "$inv"
ok_true=$(python3 -c "import json;print(sum(1 for a in json.load(open('$T/data/resume/state.json'))['attempts'] if a['ok']))")
assert_eq "1" "$ok_true"
echo "ok R-07: two racing sleepers -> exactly ONE claude invocation (fire-time mutex)"

echo "72-resume-storm: R-07 verified"
exit 0
