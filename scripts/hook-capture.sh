#!/bin/sh
# supervisor: this hook must never break the user's session.
[ -n "${SUPERVISOR_DISABLE:-}" ] && exit 0
SUP_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$SUP_ROOT/scripts/lib/guard.sh" 2>/dev/null || exit 0
sup_data_dir >/dev/null || exit 0
_py=$(sup_py) || exit 0
exec "$_py" "$SUP_ROOT/scripts/py/capture.py" "$@"
