#!/bin/sh
# hook-session-start.sh - SessionStart(startup|resume|clear) entrypoint (design U9).
# This hook must NEVER break the user's session: exit 0 on every path.
# Responsibilities (in order): acquire the wake-lock, sweep stale locks/resumes
# and reconcile crashed runs (maintain.py), regenerate the digest lazily from
# events.jsonl (sessions.jsonl is a derived cache only), emit the injection-inert
# additionalContext envelope, then record this session's start event. All heavy
# work lands here (not SessionEnd) so a crash without SessionEnd still recovers.
[ -n "${SUPERVISOR_DISABLE:-}" ] && exit 0
SUP_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$SUP_ROOT/scripts/lib/guard.sh"   2>/dev/null || exit 0
. "$SUP_ROOT/scripts/lib/findpid.sh" 2>/dev/null || exit 0
. "$SUP_ROOT/scripts/lib/detach.sh"  2>/dev/null || exit 0
sup_data_dir >/dev/null || exit 0

STDIN_JSON=$(cat 2>/dev/null)
_py=$(sup_py) || _py=""
SID=""; SRC="startup"; CWD="$PWD"
if [ -n "$_py" ]; then
  eval "$(printf '%s' "$STDIN_JSON" | "$_py" "$SUP_ROOT/scripts/py/supervisor_common.py" stdin-vars 2>/dev/null)"
fi
[ -z "$SID" ] && SID="nopy-$$"

"$SUP_ROOT/scripts/awake-acquire.sh" "$SID" 2>/dev/null

[ -z "$_py" ] && exit 0
"$_py" "$SUP_ROOT/scripts/py/maintain.py" sweep --cwd "$CWD" 2>/dev/null
OUT=$("$_py" "$SUP_ROOT/scripts/py/digest.py" inject --cwd "$CWD" --session "$SID" --source "$SRC" 2>/dev/null)
printf '%s' "$STDIN_JSON" | "$_py" "$SUP_ROOT/scripts/py/capture.py" --start 2>/dev/null
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
