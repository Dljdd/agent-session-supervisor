#!/bin/sh
# resume-sleeper.sh SID CWD DUE|"ladder" CLAUDE_PID - the ONLY long-lived
# supervisor process (design 13.6). Detached by hook-stop-failure.sh via
# sup_detach (own session, survives the hook, the terminal group, and hook
# timeouts). Waits until the reset (or walks the backoff ladder), then appends
# ONE headless turn with `claude -p --resume` under a hard wall-clock bound.
#
# ANTI-HANG: the wait loop reads the REAL wall clock (never SUPERVISOR_NOW) in
# bounded <=30 s chunks, and SUPERVISOR_RESUME_FASTFORWARD=1 (test mode only)
# collapses EVERY wait to zero so no test ever sleeps for real. The claude
# invocation is spawned in its own process group and hard-killed at
# resume_max_minutes (TF-4).
SID="$1"; CWD="$2"; DUE="$3"; CPID="$4"
[ -z "$SID" ] && exit 0
SUP_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$SUP_ROOT/scripts/lib/guard.sh" 2>/dev/null || exit 0
DATA=$(sup_data_dir) || exit 0
_py=$(sup_py) || exit 0
COMMON="$SUP_ROOT/scripts/py/supervisor_common.py"

SAFE=$("$_py" "$COMMON" safe-sid "$SID" 2>/dev/null)
[ -z "$SAFE" ] && SAFE="$SID"
PENDING="$DATA/resume/pending/$SAFE.json"
LOCK_HELD=0
_SLEEP_PID=""

# guard.sh installs `trap 'exit 0' EXIT`; replace it with our cleanup so a
# crash at ANY point still frees the mutex and clears OUR pending file (never
# another sleeper's - per-sleeper files are CT-6). INT/TERM must EXIT (not just
# run the handler and resume the loop, which would let the sleeper survive a
# kill and leak): they call `exit`, which fires the EXIT trap exactly once. The
# EXIT trap also reaps the in-flight sleep child so `kill <pid>` (a documented
# escape hatch) and test teardown terminate the sleeper within a moment, never
# after a full sleep chunk.
cleanup() {
  [ -n "$_SLEEP_PID" ] && kill "$_SLEEP_PID" 2>/dev/null
  [ "$LOCK_HELD" = "1" ] && "$_py" "$COMMON" resume-release-lock >/dev/null 2>&1
  rm -f "$PENDING" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# One python spawn for all three knobs (per-fire latency matters on slow
# interpreters); falls back to the design defaults if the read yields nothing.
MAXATT=4; MINGAP=5; MAXMIN=30
eval "$("$_py" "$COMMON" resume-config 2>/dev/null)"
LADDER="1800,3600,7200,14400"                       # CT-7: +30/+60/+120/+240 min
if [ "${SUPERVISOR_TEST_MODE:-}" = "1" ] && [ -n "${SUPERVISOR_RESUME_LADDER:-}" ]; then
  LADDER="$SUPERVISOR_RESUME_LADDER"                 # CT-13 test seam
fi

# window_key: resets_at for an epoch schedule (DUE carries the +90 pad, so
# resets_at = DUE-90 - matches the arm's pending file, R-01), else the 5 h
# bucket (SUPERVISOR_NOW-aware) for the ladder path.
if [ "$DUE" = "ladder" ]; then
  WKEY=$(( $(sup_now) / 18000 ))
else
  WKEY=$(( DUE - 90 ))
fi

ladder_at() {  # ladder_at N -> Nth ladder offset (1-based); overflow reuses the last.
  _n=$1; _i=0; _last=1800; _oldifs=$IFS; IFS=,
  for _v in $LADDER; do
    _i=$((_i+1)); _last=$_v
    if [ "$_i" -eq "$_n" ]; then IFS=$_oldifs; printf '%s\n' "$_v"; return 0; fi
  done
  IFS=$_oldifs; printf '%s\n' "$_last"
}

sup_sleep_until() {  # sup_sleep_until TARGET_EPOCH - REAL clock, bounded chunks.
  if [ "${SUPERVISOR_TEST_MODE:-}" = "1" ] && [ "${SUPERVISOR_RESUME_FASTFORWARD:-}" = "1" ]; then
    return 0
  fi
  _tgt=$1
  while :; do
    _now=$(date +%s)
    _rem=$((_tgt - _now))
    [ "$_rem" -le 0 ] && return 0
    [ "$_rem" -gt 30 ] && _rem=30
    # Background sleep + `wait`: `wait` is interruptible by a trapped signal, so
    # a TERM/INT lands immediately (the EXIT trap then reaps this sleep child),
    # instead of blocking until the chunk elapses.
    sleep "$_rem" & _SLEEP_PID=$!
    wait "$_SLEEP_PID" 2>/dev/null
    _SLEEP_PID=""
  done
}

sup_notify() {
  sup_have osascript || return 0
  osascript -e "display notification \"$1\" with title \"Claude Supervisor\"" >/dev/null 2>&1
}

release_lock() {
  "$_py" "$COMMON" resume-release-lock >/dev/null 2>&1
  LOCK_HELD=0
}

# Bounded claude launcher (design 13.6.5). Builds the argv as a LIST inside
# python (SEC-02: never an unquoted $var word-split), re-validates
# resume_extra_args at USE time, and hard-kills the child's process group on
# timeout. Exit: child rc | 124 timeout | 125 bad-extra-args | 126/127 launch.
resume_exec() {  # resume_exec MAXMIN SID CWD -> prints child stdout
  SUP_PY_DIR="$SUP_ROOT/scripts/py" "$_py" - "$1" "$2" "$3" <<'PYEOF'
import os, sys, signal, subprocess
sys.path.insert(0, os.environ.get("SUP_PY_DIR", ""))
try:
    import supervisor_common as sc
except Exception:
    sys.exit(126)
mins = float(sys.argv[1]); sid = sys.argv[2]; cwd = sys.argv[3]
cfg = sc.load_config()
extra = cfg.get("resume_extra_args") or []
try:
    sc.validate_extra_args(extra)            # SEC-02 use-time re-validation
except Exception:
    sys.exit(125)                            # hostile args: fatal, NO invocation
argv = ["claude", "-p", "--resume", sid,
        "Continue the task from where it stopped."] + list(extra)
try:
    p = subprocess.Popen(argv, cwd=(cwd or None), start_new_session=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
except Exception:
    sys.exit(127)
try:
    out, _ = p.communicate(timeout=mins * 60)
    sys.stdout.buffer.write(out or b"")
    sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)   # TF-4 hard bound
    except Exception:
        pass
    try:
        out, _ = p.communicate(timeout=5)
    except Exception:
        out = b""
    sys.stdout.buffer.write(out or b"")
    sys.exit(124)
PYEOF
}

ATTEMPT=1
while [ "$ATTEMPT" -le "$MAXATT" ]; do
  # target for this attempt
  if [ "$ATTEMPT" -eq 1 ] && [ "$DUE" != "ladder" ]; then
    TARGET="$DUE"
  else
    TARGET=$(( $(date +%s) + $(ladder_at "$ATTEMPT") ))
  fi
  sup_sleep_until "$TARGET"

  # re-check every wake (design 13.6.2): opt-in still on, no kill-switch.
  [ "$(sup_cfg auto_resume false)" = "true" ] || exit 0
  [ -f "$DATA/resume/DISABLED" ] && exit 0

  # fire-time mutex held across window-check -> invoke -> ledger (design 13.6.3).
  "$_py" "$COMMON" resume-acquire-lock --max-minutes "$MAXMIN" >/dev/null 2>&1 || exit 0
  LOCK_HELD=1

  # once-per-window cap + min-gap fuse.
  if ! "$_py" "$COMMON" resume-window-check --wkey "$WKEY" --min-gap-hours "$MINGAP" >/dev/null 2>&1; then
    release_lock; exit 0
  fi

  # liveness (design 13.4): the interactive claude is still alive -> never fork
  # context under the user; notify and stand down.
  if [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null; then
    sup_notify "Session $SID hit a limit but is still open; not auto-resuming."
    release_lock; exit 0
  fi

  OUT=$(resume_exec "$MAXMIN" "$SID" "$CWD"); RC=$?
  printf '%s' "$OUT" | "$_py" "$SUP_ROOT/scripts/py/redact.py" 2>/dev/null \
    | tail -c 20480 > "$DATA/resume/last.log" 2>/dev/null

  if [ "$RC" -eq 0 ]; then
    "$_py" "$COMMON" resume-ledger --ok true --wkey "$WKEY" --session "$SID" --attempt "$ATTEMPT" >/dev/null 2>&1
    "$_py" "$COMMON" resume-event --cwd "$CWD" --session "$SID" >/dev/null 2>&1
    sup_notify "Supervisor resumed session $SID."
    release_lock; exit 0
  elif [ "$RC" -eq 124 ]; then
    "$_py" "$COMMON" resume-ledger --ok false --fatal --reason timeout --wkey "$WKEY" --session "$SID" --attempt "$ATTEMPT" >/dev/null 2>&1
    sup_notify "Supervisor auto-resume timed out for session $SID."
    release_lock; exit 0
  elif [ "$RC" -eq 125 ]; then
    "$_py" "$COMMON" resume-ledger --ok false --fatal --reason bad_extra_args --wkey "$WKEY" --session "$SID" --attempt "$ATTEMPT" >/dev/null 2>&1
    sup_notify "Supervisor auto-resume refused: resume_extra_args failed validation."
    release_lock; exit 0
  else
    # non-zero: retry ONLY on a quota/overload signal; every other error is fatal.
    if printf '%s' "$OUT" | grep -Eiq 'rate.?limit|429|overloaded'; then
      "$_py" "$COMMON" resume-ledger --ok false --reason retry --wkey "$WKEY" --session "$SID" --attempt "$ATTEMPT" >/dev/null 2>&1
      release_lock
      ATTEMPT=$((ATTEMPT + 1))
      continue
    fi
    "$_py" "$COMMON" resume-ledger --ok false --fatal --reason error --wkey "$WKEY" --session "$SID" --attempt "$ATTEMPT" >/dev/null 2>&1
    sup_notify "Supervisor auto-resume failed (non-quota error) for session $SID."
    release_lock; exit 0
  fi
done
exit 0
