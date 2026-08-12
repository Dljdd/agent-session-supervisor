#!/bin/bash
# tests/integration/70-resume-arm.sh — plan Task 12 / strategy §12 R-01, R-05, R-06.
# The ARM side of v0.3 auto-resume: hook-stop-failure.sh records the rate-limit
# event and (opt-in) writes ONE resume/pending/<sid>.json (CT-6) + detaches a
# sleeper. No test sleeps for real: the pending-persistence cases give the
# detached sleeper a REAL-future due so it stays asleep (never fires/deletes)
# while we assert, then we kill it explicitly; t_teardown's `pkill -f "$T"` is
# the unconditional backstop (anti-hang contract).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox

SC="$PLUGIN_ROOT/scripts/py/supervisor_common.py"
CTL="$PLUGIN_ROOT/scripts/supervisorctl.sh"

wait_gone() {  # wait_gone <pid> — poll <=8 s for pid to die
  local n=0
  while [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done
}
kill_pending_sleeper() {  # read pid from a pending file and kill+reap it
  local f="$1" pid
  pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  wait_gone "$pid"
}
recorder_claude() {  # a claude shim that must NOT fire in an arm test
  cat > "$T/bin/claude" <<EOF
#!/bin/sh
printf 'invoke %s\n' "\$*" >> "$T/claude.log"
exit 0
EOF
  chmod +x "$T/bin/claude"
}
enable_resume() { "$CTL" --data-dir "$T/data" config set auto_resume true --i-understand-quota-spend >/dev/null; }

# A telemetry file whose reset is in the REAL future keeps the detached sleeper
# asleep (so the pending file persists for our assertions) while remaining a
# valid epoch schedule (resets_at > SUPERVISOR_NOW, ts fresh vs SUPERVISOR_NOW).
seed_future_reset() {  # seed_future_reset -> echoes the resets_at it wrote
  mkdir -p "$T/data/telemetry"
  local reset; reset=$(( $(date +%s) + 3600 ))
  printf '{"v":1,"ts":%s,"five_hour":{"used_percentage":62,"resets_at":%s},"seven_day":{"used_percentage":18,"resets_at":%s}}' \
    "$SUPERVISOR_NOW" "$reset" "$((reset + 86400))" > "$T/data/telemetry/rate_limits.json"
  printf '%s\n' "$reset"
}

# ---------------------------------------------------------------------------
# R-01 — pending spec on rate_limit (CT-6/CT-7)
# ---------------------------------------------------------------------------
recorder_claude
enable_resume
: > "$T/claude.log"
RESET=$(seed_future_reset)

payload stopfailure-ratelimit | run_hook hook-stop-failure.sh
PF="$T/data/resume/pending/sess-0001.json"
assert_file_exists "$PF"
# The detached sleeper has a real-future due, so it must not have fired.
[ -s "$T/claude.log" ] && fail "arm-time sleeper fired early: $(cat "$T/claude.log")"

# CT-6 schema + CT-7 timing: due = resets_at + 90 EXACTLY, window_key = resets_at,
# attempt = 1, cwd keys to this project, pid alive.
assert_jq '.v==1'          "$PF"
assert_jq '.attempt==1'    "$PF"
assert_jq ".due==($RESET+90)" "$PF"
assert_jq ".window_key==\"$RESET\"" "$PF"
assert_jq '.session=="sess-0001"' "$PF"
assert_jq ".cwd==\"$T/proj\"" "$PF"
SL1=$(jq -r '.pid' "$PF")
kill -0 "$SL1" 2>/dev/null || fail "R-01: pending pid $SL1 is not a live sleeper"
# k:"limit" event recorded alongside.
assert_grep '"k":"limit"' "$T/data/projects/"*/events.jsonl
cp "$PF" "$T/pending1.json"
echo "ok R-01: pending due=resets_at+90, window_key=resets_at, attempt=1, pid live"

# Determinism: a second arm (after killing the first sleeper + clearing state)
# reproduces every field except the (inherently fresh) pid.
kill_pending_sleeper "$PF"
rm -f "$PF"; rm -rf "$T/data/resume/state.json"
payload stopfailure-ratelimit | run_hook hook-stop-failure.sh
assert_file_exists "$PF"
a=$(jq -S 'del(.pid)' "$T/pending1.json")
b=$(jq -S 'del(.pid)' "$PF")
assert_eq "$a" "$b"
kill_pending_sleeper "$PF"
echo "ok R-01: two arms are byte-deterministic modulo pid"

# ---------------------------------------------------------------------------
# R-05 — auto_resume OFF, and wrong error type (design §18.16)
# ---------------------------------------------------------------------------
# Fresh sandbox state for a clean assertion (drop config.json -> defaults, so
# auto_resume reverts to its default false).
rm -rf "$T/data/resume" "$T/data/projects"; rm -f "$T/data/config.json"; : > "$T/claude.log"

# (a) DEFAULT config (auto_resume false): rate_limit records k:"limit", arms nothing.
payload stopfailure-ratelimit | run_hook hook-stop-failure.sh
[ -e "$T/data/resume/pending" ] && [ -n "$(ls -A "$T/data/resume/pending" 2>/dev/null)" ] \
  && fail "R-05: auto_resume OFF still armed a sleeper"
assert_grep '"k":"limit"' "$T/data/projects/"*/events.jsonl
echo "ok R-05a: auto_resume off — limit event recorded, nothing armed"

# (b) server_error piped directly (mis-registration): full no-op, no pending.
rm -rf "$T/data/resume" "$T/data/projects"
enable_resume
payload stopfailure-servererror | run_hook hook-stop-failure.sh
[ -e "$T/data/resume/pending" ] && [ -n "$(ls -A "$T/data/resume/pending" 2>/dev/null)" ] \
  && fail "R-05: server_error (non-rate_limit) armed a sleeper"
echo "ok R-05b: server_error is a no-op even with auto_resume on"

# ---------------------------------------------------------------------------
# R-06 — non-blocking and output-free (FACTS §9.9: StopFailure ignores output)
# ---------------------------------------------------------------------------
rm -rf "$T/data/resume" "$T/data/projects"
# auto_resume OFF: the fast path (no detach) — assert EMPTY stdout and that the
# hook returns promptly (it must never block on the sleeper). The design target
# is <200 ms; we assert a generous non-hang bound to stay CI-stable.
OUT=$(payload stopfailure-ratelimit | run_hook hook-stop-failure.sh)
assert_eq "" "$OUT"
t0=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
payload stopfailure-ratelimit | run_hook hook-stop-failure.sh >/dev/null 2>&1
t1=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
dur=$((t1 - t0))
[ "$dur" -le 3000 ] || fail "R-06: hook took ${dur}ms (non-blocking bound 3000ms)"
echo "ok R-06: hook output-free and non-blocking (${dur}ms)"

echo "70-resume-arm: R-01, R-05, R-06 verified"
exit 0
