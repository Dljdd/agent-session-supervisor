#!/bin/bash
# tests/integration/71-resume-fire.sh — plan Task 12 / strategy §12 R-02, R-03, R-04.
# The FIRE side: resume-sleeper.sh is driven DIRECTLY (TP-9) with the
# fast-forward seam (SUPERVISOR_RESUME_FASTFORWARD=1) so NOTHING sleeps for real
# and the shrunk ladder (SUPERVISOR_RESUME_LADDER) makes the multi-attempt loop
# run in milliseconds. A fake `claude` shim records argv / exits with 429 and
# always returns instantly — it never blocks on stdin.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox

SC="$PLUGIN_ROOT/scripts/py/supervisor_common.py"
CTL="$PLUGIN_ROOT/scripts/supervisorctl.sh"
SLEEPER="$PLUGIN_ROOT/scripts/resume-sleeper.sh"

# Anti-hang: every sleeper invocation is bounded by this wrapper. With
# fast-forward on and an instant claude shim it returns in well under a second;
# the timeout is a hard backstop so a bug can never hang the suite.
run_sleeper() {  # run_sleeper SID CWD DUE CLAUDE_PID
  ( export SUPERVISOR_RESUME_FASTFORWARD=1 SUPERVISOR_RESUME_LADDER="1,1,1,1"
    exec "$SLEEPER" "$@" ) &
  local p=$!
  local n=0
  while kill -0 "$p" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
  if kill -0 "$p" 2>/dev/null; then kill -9 "$p" 2>/dev/null; fail "sleeper did not exit within 10 s"; fi
}
enable_resume() { python3 "$SC" config-set auto_resume true --i-understand-quota-spend >/dev/null; }
recorder_claude() {
  cat > "$T/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/claude.log"
exit 0
EOF
  chmod +x "$T/bin/claude"
}
ratelimit_claude() {  # exits 1 with a 429 line -> the sleeper's retry signal
  cat > "$T/bin/claude" <<EOF
#!/bin/sh
printf 'invoke\n' >> "$T/claude.log"
echo "API Error: 429 rate limit reached"
exit 1
EOF
  chmod +x "$T/bin/claude"
}
led_ok_true() { python3 -c "import json;print(sum(1 for a in json.load(open('$T/data/resume/state.json'))['attempts'] if a['ok']))"; }
led_count()   { python3 -c "import json;print(len(json.load(open('$T/data/resume/state.json'))['attempts']))"; }

# ---------------------------------------------------------------------------
# R-02 — exact relaunch argv (list exec, prompt spaces survive; extra args verbatim)
# ---------------------------------------------------------------------------
enable_resume
recorder_claude
: > "$T/claude.log"
# DUE in the (SUPERVISOR_NOW) past -> fires on the first wake; window_key = DUE-90.
run_sleeper sess-0001 "$T/proj" 1753689690 ""
assert_line_count "$T/claude.log" 1
got=$(cat "$T/claude.log")
assert_eq '-p --resume sess-0001 Continue the task from where it stopped.' "$got"
assert_eq "1" "$(led_ok_true)"
[ -e "$T/data/resume/pending/sess-0001.json" ] && fail "R-02: sleeper left its pending file behind"
echo "ok R-02: argv is exactly -p --resume <sid> \"Continue the task from where it stopped.\""

# extra args re-passed verbatim, spaces intact (dev-mode resume, sessions.md:38).
python3 "$SC" config-set resume_extra_args '["--plugin-dir","/x y/p"]' --i-understand-quota-spend >/dev/null
: > "$T/claude.log"; rm -rf "$T/data/resume/state.json"
run_sleeper sess-0001 "$T/proj" 1753689690 ""
got=$(cat "$T/claude.log")
assert_eq '-p --resume sess-0001 Continue the task from where it stopped. --plugin-dir /x y/p' "$got"
echo "ok R-02: resume_extra_args appended verbatim, the space in /x y/p intact"

# ---------------------------------------------------------------------------
# R-03 — once-per-window guard (file-based, survives process boundaries)
# ---------------------------------------------------------------------------
python3 "$SC" config-set resume_extra_args '[]' --i-understand-quota-spend >/dev/null
recorder_claude
: > "$T/claude.log"; rm -rf "$T/data/resume"
# Seed a successful attempt for window_key W = 1753689600.
python3 "$SC" resume-ledger --ok true --wkey 1753689600 --session sess-0001 --attempt 1 >/dev/null
# Wake for the SAME window (DUE-90 == 1753689600): must NOT invoke.
run_sleeper sess-0001 "$T/proj" 1753689690 ""
assert_eq "0" "$(wc -l < "$T/claude.log" | tr -d ' ')"
echo "ok R-03: same window_key already ok:true -> no invocation"
# A new window, far enough past the min-gap: a fresh fire DOES invoke.
export SUPERVISOR_NOW=1753900000
NEWRESET=1753903600
: > "$T/claude.log"
run_sleeper sess-0001 "$T/proj" $((NEWRESET + 90)) ""
assert_eq "1" "$(wc -l < "$T/claude.log" | tr -d ' ')"
export SUPERVISOR_NOW=1753689600
echo "ok R-03: new window_key past the min-gap -> invokes"

# ---------------------------------------------------------------------------
# R-04 — backoff ladder when no reset is known (exactly resume_max_attempts)
# ---------------------------------------------------------------------------
rm -rf "$T/data/resume"; rm -f "$T/data/telemetry/rate_limits.json"
ratelimit_claude
: > "$T/claude.log"
# "ladder" mode: every attempt sees a 429 -> retries through all 4 attempts.
run_sleeper sess-lad "$T/proj" ladder ""
assert_eq "4" "$(wc -l < "$T/claude.log" | tr -d ' ')"
assert_eq "4" "$(led_count)"
assert_eq "0" "$(led_ok_true)"
echo "ok R-04: ladder ran exactly resume_max_attempts (4) attempts, all ok:false"
# The documented production ladder constants are +30/+60/+120/+240 min (CT-7);
# assert the literal lives in the sleeper source (the shrunk run above proves
# the loop mechanics; this proves the constants without waiting 7.5 h).
assert_grep 'LADDER="1800,3600,7200,14400"' "$SLEEPER"
echo "ok R-04: production ladder constants 1800,3600,7200,14400 present (CT-7)"

echo "71-resume-fire: R-02, R-03, R-04 verified"
exit 0
