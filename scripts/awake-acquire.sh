#!/bin/sh
# awake-acquire.sh <sid> - design 13.1. Never breaks the caller (invoked under guard).
SID="$1"; [ -z "$SID" ] && exit 0
SUP_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
. "$SUP_ROOT/scripts/lib/guard.sh"   2>/dev/null || exit 0
. "$SUP_ROOT/scripts/lib/findpid.sh" 2>/dev/null || exit 0
. "$SUP_ROOT/scripts/lib/detach.sh"  2>/dev/null || exit 0
DATA=$(sup_data_dir) || exit 0
MODE=$(sup_cfg awake auto); [ "$MODE" = "off" ] && exit 0
LOCK="$DATA/awake/$SID.lock"
[ -f "$LOCK" ] && exit 0
mkdir -p "$DATA/awake" 2>/dev/null || exit 0
NOW=$(sup_now)

if [ "$MODE" = "auto" ] || [ "$MODE" = "adrafinil" ]; then
  if sup_have adrafinil && adrafinil acquire "supervisor-$SID" --tool claude-code >/dev/null 2>&1; then
    printf '{"v":1,"mode":"adrafinil","key":"supervisor-%s","ts":%s}\n' "$SID" "$NOW" > "$LOCK"
    exit 0
  fi
fi
PID=$(sup_find_claude_pid); [ -z "$PID" ] && exit 0
case "$(uname -s)" in
  Darwin)
    [ "$MODE" = "inhibit" ] && exit 0
    HP=$(sup_detach caffeinate -ims -w "$PID"); [ -z "$HP" ] && exit 0
    printf '{"v":1,"mode":"caffeinate","holder_pid":%s,"claude_pid":%s,"ts":%s}\n' "$HP" "$PID" "$NOW" > "$LOCK"
    ;;
  Linux)
    [ "$MODE" = "caffeinate" ] && exit 0
    sup_have systemd-inhibit || exit 0
    HP=$(sup_detach systemd-inhibit --what=sleep:idle --who=claude-supervisor \
         --why="Claude Code session $SID" --mode=block tail --pid="$PID" -f /dev/null)
    [ -z "$HP" ] && exit 0
    printf '{"v":1,"mode":"inhibit","holder_pid":%s,"claude_pid":%s,"ts":%s}\n' "$HP" "$PID" "$NOW" > "$LOCK"
    ;;
esac
exit 0
