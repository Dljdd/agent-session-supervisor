#!/bin/bash
# 20-cost-line.sh — I-11 (design §18.24). The injected digest header shows a
# cost figure ONLY when a telemetry cost snapshot exists for the run. Case A:
# no telemetry/sessions/<sid>.json -> no `$` in the header. Case B: write it
# with total_cost_usd=1.2 -> header carries `, $1.20`. Both on one store.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

# closed run s1
payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/foo.ts" | run_hook hook-capture.sh
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

# Case A: no telemetry -> no cost figure in the header.
raw=$(payload sessionstart-resume session_id=s2 | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/acA.txt"
hdrA=$(grep -F 'Last session' "$T/acA.txt")
printf '%s' "$hdrA" | grep -Fq '$' && fail "cost figure shown with no telemetry: [$hdrA]"

# Case B: write a cost snapshot for s1, re-inject.
mkdir -p "$CLAUDE_PLUGIN_DATA/telemetry/sessions"
printf '{"v":1,"total_cost_usd":1.2}\n' > "$CLAUDE_PLUGIN_DATA/telemetry/sessions/s1.json"
raw2=$(payload sessionstart-resume session_id=s3 | run_hook hook-session-start.sh)
printf '%s' "$raw2" | jq -r '.hookSpecificOutput.additionalContext' > "$T/acB.txt"
grep -F 'Last session' "$T/acB.txt" | grep -Fq ', $1.20' || fail "cost \$1.20 missing after telemetry write"

echo "I-11 ok: header cost absent without telemetry, present (\$1.20) with it"
