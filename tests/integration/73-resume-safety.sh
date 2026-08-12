#!/bin/bash
# tests/integration/73-resume-safety.sh — plan Task 12 / strategy §12
# R-08 (liveness), R-09 (DISABLED / auto_resume flip mid-sleep), R-10 use-time
# (hostile resume_extra_args re-validated at fire time, critic SEC-02), and
# R-11 (hard wall-clock bound on a hung claude, critic TF-4). All sleepers are
# driven DIRECTLY with the fast-forward seam and a bounded join; the hang shim
# records its pid so we can prove the child's process group was killed.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox

SC="$PLUGIN_ROOT/scripts/py/supervisor_common.py"
CTL="$PLUGIN_ROOT/scripts/supervisorctl.sh"
SLEEPER="$PLUGIN_ROOT/scripts/resume-sleeper.sh"

wait_gone() { local n=0; while [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done; }
run_sleeper() {  # run_sleeper SID CWD DUE CLAUDE_PID  — fast-forward + bounded join
  ( export SUPERVISOR_RESUME_FASTFORWARD=1 SUPERVISOR_RESUME_LADDER="1,1,1,1"
    exec "$SLEEPER" "$@" ) &
  local p=$! n=0
  while kill -0 "$p" 2>/dev/null && [ "$n" -lt 120 ]; do sleep 0.1; n=$((n+1)); done
  if kill -0 "$p" 2>/dev/null; then kill -9 "$p" 2>/dev/null; fail "sleeper did not exit within 12 s"; fi
}
enable_resume() { "$CTL" --data-dir "$T/data" config set auto_resume true --i-understand-quota-spend >/dev/null; }
recorder_claude() {
  cat > "$T/bin/claude" <<EOF
#!/bin/sh
printf 'invoke\n' >> "$T/claude.log"
exit 0
EOF
  chmod +x "$T/bin/claude"
}
hang_claude() {  # records its pid, then hangs; killpg at the bound must reap it
  cat > "$T/bin/claude" <<EOF
#!/bin/sh
printf 'invoke\n' >> "$T/claude.log"
echo \$\$ > "$T/claude.pid"
exec sleep 600
EOF
  chmod +x "$T/bin/claude"
}
fake_osascript() {
  cat > "$T/bin/osascript" <<EOF
#!/bin/sh
printf 'notify %s\n' "\$*" >> "$T/osa.log"
exit 0
EOF
  chmod +x "$T/bin/osascript"
}
seed_pending() {  # seed_pending SID — so we can assert the sleeper removes it
  python3 "$SC" resume-write-pending --session "$1" --cwd "$T/proj" --due 1753689690 --wkey 1753689600 --pid 999999 >/dev/null
}
pending_count() { ls -A "$T/data/resume/pending" 2>/dev/null | grep -c . ; }
led_last_reason() { python3 -c "import json;a=json.load(open('$T/data/resume/state.json'))['attempts'];print(a[-1].get('reason',''), a[-1]['ok'], a[-1].get('fatal',False))"; }

enable_resume
fake_osascript

# ---------------------------------------------------------------------------
# R-08 — liveness: the interactive claude is still alive -> notify, never fork
# ---------------------------------------------------------------------------
recorder_claude
: > "$T/claude.log"; : > "$T/osa.log"; rm -rf "$T/data/resume"
sleep 600 & LIVE=$!
disown "$LIVE" 2>/dev/null || true   # keep bash from printing a job-kill notice at teardown
seed_pending sess-live
run_sleeper sess-live "$T/proj" 1753689690 "$LIVE"
assert_eq "0" "$(wc -l < "$T/claude.log" | tr -d ' ')"
[ -s "$T/osa.log" ] || fail "R-08: expected a liveness notification"
assert_eq "0" "$(pending_count)"
kill "$LIVE" 2>/dev/null; wait_gone "$LIVE"
echo "ok R-08: live interactive claude -> notification, no headless resume, pending cleared"

# ---------------------------------------------------------------------------
# R-09 — DISABLED kill-switch, and the auto_resume flip, mid-sleep
# ---------------------------------------------------------------------------
: > "$T/claude.log"; rm -rf "$T/data/resume"
seed_pending sess-dis
mkdir -p "$T/data/resume"; touch "$T/data/resume/DISABLED"
run_sleeper sess-dis "$T/proj" 1753689690 ""
assert_eq "0" "$(wc -l < "$T/claude.log" | tr -d ' ')"
assert_eq "0" "$(pending_count)"
rm -f "$T/data/resume/DISABLED"
echo "ok R-09a: resume/DISABLED honored at wake -> no invocation, pending cleared"

# Variant: auto_resume flipped false before the wake -> same clean stand-down.
: > "$T/claude.log"; rm -rf "$T/data/resume"
seed_pending sess-off
"$CTL" --data-dir "$T/data" config set auto_resume false --i-understand-quota-spend >/dev/null
run_sleeper sess-off "$T/proj" 1753689690 ""
assert_eq "0" "$(wc -l < "$T/claude.log" | tr -d ' ')"
assert_eq "0" "$(pending_count)"
enable_resume
echo "ok R-09b: auto_resume=false at wake -> no invocation, pending cleared"

# ---------------------------------------------------------------------------
# R-10 use-time — hostile resume_extra_args hand-written into config.json is
# re-validated at fire time and REFUSED before any claude spawn (critic SEC-02).
# ---------------------------------------------------------------------------
recorder_claude
: > "$T/claude.log"; : > "$T/osa.log"; rm -rf "$T/data/resume"
python3 - "$T/data/config.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
try:
    cfg = json.load(open(p))
except Exception:
    cfg = {}
cfg["v"] = 1
cfg["auto_resume"] = True
cfg["resume_extra_args"] = ["--dangerously-skip-permissions"]  # bypasses the setter
open(p, "w").write(json.dumps(cfg))
PYEOF
seed_pending sess-bad
run_sleeper sess-bad "$T/proj" 1753689690 ""
assert_eq "0" "$(wc -l < "$T/claude.log" | tr -d ' ')"
assert_eq "0" "$(pending_count)"
r=$(led_last_reason)
assert_eq "bad_extra_args False True" "$r"
echo "ok R-10 use-time: hostile resume_extra_args refused at fire time, no invocation, fatal ledger"
# Restore a clean config for R-11.
"$CTL" --data-dir "$T/data" config set resume_extra_args '[]' --i-understand-quota-spend >/dev/null

# ---------------------------------------------------------------------------
# R-11 — hard wall-clock bound on a hung claude (critic TF-4)
# ---------------------------------------------------------------------------
hang_claude
: > "$T/claude.log"; : > "$T/osa.log"; rm -rf "$T/data/resume"
"$CTL" --data-dir "$T/data" config set resume_max_minutes 0.03 --i-understand-quota-spend >/dev/null
seed_pending sess-hang
run_sleeper sess-hang "$T/proj" 1753689690 ""
# The child (exec'd into `sleep 600`) must be dead — its process group was killed.
HPID=$(cat "$T/claude.pid" 2>/dev/null)
[ -n "$HPID" ] && kill -0 "$HPID" 2>/dev/null && { kill -9 "$HPID" 2>/dev/null; fail "R-11: hung claude ($HPID) survived the bound"; }
r=$(led_last_reason)
assert_eq "timeout False True" "$r"
[ -s "$T/osa.log" ] || fail "R-11: expected a timeout notification"
assert_eq "0" "$(pending_count)"
echo "ok R-11: hung claude killed at resume_max_minutes, ledger fatal timeout, pending cleared"

echo "73-resume-safety: R-08, R-09, R-10(use-time), R-11 verified"
exit 0
