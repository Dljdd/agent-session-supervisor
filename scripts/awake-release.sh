#!/bin/sh
# awake-release.sh <sid> - design 13.2.
SID="$1"; [ -z "$SID" ] && exit 0
SUP_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$SUP_ROOT/scripts/lib/guard.sh" 2>/dev/null || exit 0
DATA=$(sup_data_dir) || exit 0
LOCK="$DATA/awake/$SID.lock"
[ -f "$LOCK" ] || exit 0
MODE=$(sed -n 's/.*"mode":"\([a-z]*\)".*/\1/p' "$LOCK" 2>/dev/null)
if [ "$MODE" = "adrafinil" ]; then
  adrafinil release "supervisor-$SID" 2>/dev/null || adrafinil release 2>/dev/null
else
  HP=$(sed -n 's/.*"holder_pid":\([0-9]*\).*/\1/p' "$LOCK" 2>/dev/null)
  if [ -n "$HP" ] && kill -0 "$HP" 2>/dev/null; then
    COMM=$(ps -p "$HP" -o comm= 2>/dev/null)
    case "$COMM" in *caffeinate*|*systemd-inhibit*|*tail*) kill -TERM "$HP" 2>/dev/null ;; esac
  fi
fi
rm -f "$LOCK" 2>/dev/null
exit 0
