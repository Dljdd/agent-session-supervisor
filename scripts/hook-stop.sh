#!/bin/sh
# hook-stop.sh - Stop entrypoint (async, design U10). The turn ended cleanly.
# Records the stop signal and refreshes the derived digest cache so the next
# SessionStart can inject without a cold rebuild. Never breaks the session.
[ -n "${SUPERVISOR_DISABLE:-}" ] && exit 0
SUP_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$SUP_ROOT/scripts/lib/guard.sh" 2>/dev/null || exit 0
sup_data_dir >/dev/null || exit 0
_py=$(sup_py) || exit 0
STDIN_JSON=$(cat 2>/dev/null)
SID=""; CWD="$PWD"
eval "$(printf '%s' "$STDIN_JSON" | "$_py" "$SUP_ROOT/scripts/py/supervisor_common.py" stdin-vars 2>/dev/null)"
printf '%s' "$STDIN_JSON" | "$_py" "$SUP_ROOT/scripts/py/capture.py" --stop 2>/dev/null
"$_py" "$SUP_ROOT/scripts/py/digest.py" refresh --cwd "$CWD" --session "$SID" 2>/dev/null
exit 0
