#!/bin/sh
# supervisor statusline - self-contained (design 14.1). Reads Claude Code statusline
# JSON on stdin, prints ONE line. Never fails: worst case prints "supervisor".
# The next line is rewritten by install_statusline.py when this file is copied
# into <data>/bin/ - do not change its shape.
SUPERVISOR_BAKED_DATA_DIR=""

IN=$(cat 2>/dev/null)
if [ -z "$IN" ]; then echo "supervisor"; exit 0; fi

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)

DATA=""
if [ -n "$SUPERVISOR_BAKED_DATA_DIR" ] && [ -d "$SUPERVISOR_BAKED_DATA_DIR" ]; then
  DATA="$SUPERVISOR_BAKED_DATA_DIR"
else
  case "$SELF_DIR" in
    */plugins/data/*/bin) DATA=$(CDPATH= cd -- "$SELF_DIR/.." && pwd) ;;
  esac
fi
if [ -z "$DATA" ] && [ "${SUPERVISOR_TEST_MODE:-}" = "1" ] && [ -n "${SUPERVISOR_DATA_DIR:-}" ]; then
  DATA="$SUPERVISOR_DATA_DIR"
fi
[ -z "$DATA" ] && [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && DATA="$CLAUDE_PLUGIN_DATA"
[ -z "$DATA" ] && DATA="$HOME/.claude/plugins/data/supervisor-inline"

VALS=""
if command -v jq >/dev/null 2>&1; then
  VALS=$(printf '%s' "$IN" | jq -r '
    [ ((.cost.total_cost_usd // 0) * 100 | round | tostring),
      (.context_window.used_percentage // "" | tostring | split(".")[0]),
      (.rate_limits.five_hour.used_percentage // "" | tostring | split(".")[0]),
      (.rate_limits.five_hour.resets_at // "" | tostring),
      (.rate_limits.seven_day.used_percentage // "" | tostring | split(".")[0]),
      (.cost.total_lines_added // "" | tostring),
      (.cost.total_lines_removed // "" | tostring)
    ] | join("|")' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  VALS=$(printf '%s' "$IN" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
def g(*p, default=""):
    v=d
    for k in p:
        v=(v or {}).get(k) if isinstance(v,dict) else None
    return default if v is None else v
cents=round(float(g("cost","total_cost_usd",default=0) or 0)*100)
def pct(v): return "" if v in ("",None) else str(int(float(v)))
print("|".join([str(cents),pct(g("context_window","used_percentage")),
  pct(g("rate_limits","five_hour","used_percentage")),str(g("rate_limits","five_hour","resets_at")),
  pct(g("rate_limits","seven_day","used_percentage")),
  str(g("cost","total_lines_added")),str(g("cost","total_lines_removed"))]))' 2>/dev/null)
fi
if [ -z "$VALS" ]; then echo "supervisor"; exit 0; fi

# NOTE: "|" delimiter, not tab - tab is IFS whitespace and would COLLAPSE empty
# fields, shifting every positional (a real bug caught in plan review).
OLDIFS=$IFS; IFS='|'; set -- $VALS; IFS=$OLDIFS
CENTS=${1:-0}; CTX=${2:-}; FH=${3:-}; FHRESET=${4:-}; SD=${5:-}; LA=${6:-}; LR=${7:-}

LINE=$(printf '$%d.%02d' $((CENTS / 100)) $((CENTS % 100)))
[ -n "$CTX" ] && LINE="$LINE · ctx ${CTX}%"
if [ -n "$FH" ]; then
  SEG="5h ${FH}%"
  if [ -n "$FHRESET" ]; then
    HM=$(date -r "$FHRESET" +%H:%M 2>/dev/null || date -d "@$FHRESET" +%H:%M 2>/dev/null)
    [ -n "$HM" ] && SEG="$SEG ↺$HM"
  fi
  LINE="$LINE · $SEG"
fi
[ -n "$SD" ] && LINE="$LINE · 7d ${SD}%"
if [ -n "$LA" ] || [ -n "$LR" ]; then
  LINE="$LINE · +${LA:-0}/-${LR:-0}"
fi
printf '%s\n' "$LINE"

# telemetry side-effect: shell-throttled, never blocks the render (design 14.1)
# Opt-out gate (config.json {"telemetry":false}). Default ON when the key is
# null/absent. `jq '.telemetry // true'` is WRONG: jq's `//` treats the boolean
# false as "empty" too, so it yields true for an explicit opt-out and the knob
# becomes a no-op. Test the explicit boolean instead. A python3 fallback keeps
# the gate honored when jq is absent but python3 is present (design 14.1
# "jq/python one-liner"): that is exactly the case where the write below WOULD
# still run, so the gate must too.
TEL_ON=1
if [ -f "$DATA/config.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    [ "$(jq -r 'if .telemetry == false then "false" else "true" end' "$DATA/config.json" 2>/dev/null)" = "false" ] && TEL_ON=0
  elif command -v python3 >/dev/null 2>&1; then
    [ "$(python3 -c 'import json,sys
try:
    print("false" if json.load(open(sys.argv[1])).get("telemetry") is False else "true")
except Exception:
    print("true")' "$DATA/config.json" 2>/dev/null)" = "false" ] && TEL_ON=0
  fi
fi
if [ "$TEL_ON" = "1" ] && command -v python3 >/dev/null 2>&1; then
  RL="$DATA/telemetry/rate_limits.json"
  NOWS=$(date +%s)
  MT=$(stat -f %m "$RL" 2>/dev/null || stat -c %Y "$RL" 2>/dev/null || echo 0)
  if [ ! -f "$RL" ] || [ $((NOWS - MT)) -ge 30 ]; then
    TPY="$DATA/bin/telemetry.py"
    [ -f "$TPY" ] || TPY="$SELF_DIR/py/telemetry.py"
    if [ -f "$TPY" ]; then
      printf '%s' "$IN" | python3 "$TPY" --data-dir "$DATA" >/dev/null 2>&1 &
    fi
  fi
fi
exit 0
