#!/bin/sh
# hook-stop-failure.sh - StopFailure(matcher rate_limit) entrypoint (design 13.5).
# The platform IGNORES this hook's stdout and exit code (FACTS 1.6); it exists
# only to (1) record the rate-limit event and (2) arm ONE detached resume
# sleeper. It must never break the user's session: exit 0 on every path, and
# print NOTHING to stdout (R-06). Total budget < 200 ms.
[ -n "${SUPERVISOR_DISABLE:-}" ] && exit 0
SUP_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$SUP_ROOT/scripts/lib/guard.sh"   2>/dev/null || exit 0
. "$SUP_ROOT/scripts/lib/findpid.sh" 2>/dev/null || exit 0
. "$SUP_ROOT/scripts/lib/detach.sh"  2>/dev/null || exit 0
DATA=$(sup_data_dir) || exit 0
_py=$(sup_py) || exit 0
COMMON="$SUP_ROOT/scripts/py/supervisor_common.py"

sup_notify() {  # sup_notify MESSAGE - best-effort macOS toast; silent no-op elsewhere.
  sup_have osascript || return 0
  osascript -e "display notification \"$1\" with title \"Claude Supervisor\"" >/dev/null 2>&1
}

STDIN_JSON=$(cat 2>/dev/null)
SID=""; SRC=""; CWD="$PWD"; ERR=""; DETAIL=""
eval "$(printf '%s' "$STDIN_JSON" | "$_py" "$COMMON" stdin-vars 2>/dev/null)"
[ -z "$SID" ] && exit 0

# Defense in depth (R-05): production only registers this hook for matcher
# `rate_limit` (hooks.json / L-02). If a mis-registration or a manual pipe
# delivers any other StopFailure error, no-op entirely - never arm a resume
# for an auth/billing/server error.
[ "$ERR" = "rate_limit" ] || exit 0

# 1. ALWAYS record the limit event (redacted), regardless of the resume gates.
printf '%s' "$STDIN_JSON" | "$_py" "$SUP_ROOT/scripts/py/capture.py" --limit 2>/dev/null

# 2. Gate: opt-in only, and honor the kill-switch.
[ "$(sup_cfg auto_resume false)" = "true" ] || exit 0
[ -f "$DATA/resume/DISABLED" ] && exit 0

# 3. Arm-time singleton (design 13.5.1 / critic TF-3): a live pending sleeper
#    means DO NOT arm a second one. rc 0 = clear, non-zero = armed/no-store.
"$_py" "$COMMON" resume-arm-check 2>/dev/null || exit 0

# 4. Compute the wake schedule from telemetry (design 13.5); fall back to the
#    ladder. `skip` = telemetry is fresh but names no window worth a surprise.
SCHED=$(printf '%s' "$DETAIL" | "$_py" "$COMMON" resume-schedule 2>/dev/null)
MODE=""; DUE=""; WKEY=""; FILEDUE=""
eval "$SCHED"
if [ "$MODE" = "skip" ] || [ -z "$MODE" ]; then
  sup_notify "Rate limit hit; no reset time known, not scheduling an auto-resume."
  exit 0
fi

CLAUDE_PID=$(sup_find_claude_pid)

# 5. Detach the ONLY long-lived process, then persist its pending file (CT-6)
#    with the real sleeper pid so the arm-time singleton and the kill-switch
#    (kill <pid>) describe reality.
HP=$(sup_detach "$SUP_ROOT/scripts/resume-sleeper.sh" "$SID" "$CWD" "$DUE" "$CLAUDE_PID")
[ -z "$HP" ] && exit 0
"$_py" "$COMMON" resume-write-pending \
  --session "$SID" --cwd "$CWD" --due "$FILEDUE" --wkey "$WKEY" --pid "$HP" >/dev/null 2>&1

# 6. Arm-time notification (design 13.5.3 / critic SEC-09).
sup_notify "Supervisor will auto-resume session $SID. Disable: /supervisor:config auto_resume false"
exit 0
