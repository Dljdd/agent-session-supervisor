#!/bin/sh
# hook-session-end.sh - SessionEnd entrypoint (design U11). Runs under a tight
# ~1.5s plugin budget (FACTS 1.7) that hook timeouts cannot raise, so it does
# only the two cheap, must-happen-now things: release the wake-lock and append
# the end event. Reconciliation/rebuild is deliberately left to the next
# SessionStart (TP-7), since SessionEnd is not guaranteed to fire on a crash.
[ -n "${SUPERVISOR_DISABLE:-}" ] && exit 0
SUP_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$SUP_ROOT/scripts/lib/guard.sh" 2>/dev/null || exit 0
sup_data_dir >/dev/null || exit 0
STDIN_JSON=$(cat 2>/dev/null)
_py=$(sup_py) || _py=""
SID=""
if [ -n "$_py" ]; then
  eval "$(printf '%s' "$STDIN_JSON" | "$_py" "$SUP_ROOT/scripts/py/supervisor_common.py" stdin-vars 2>/dev/null)"
elif sup_have jq; then
  SID=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
fi
[ -n "$SID" ] && "$SUP_ROOT/scripts/awake-release.sh" "$SID" 2>/dev/null
[ -z "$_py" ] && exit 0
printf '%s' "$STDIN_JSON" | "$_py" "$SUP_ROOT/scripts/py/capture.py" --end 2>/dev/null
exit 0
