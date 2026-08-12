#!/bin/bash
# 42-subagent-events.sh — A-13. A subagent payload (agent_id/agent_type) is
# captured with `"a":1` (design §7), does not crash the builder, and its EDITS
# count toward churn while subagent READS are excluded from read-never-edited
# (§9.3). Both directions asserted.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
hc() { run_hook hook-capture.sh; }

mksub_edit() { jq -cn --arg cwd "$T/proj" --arg fp "$1" \
  '{session_id:"s1",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"O",new_string:"N"},agent_id:"agent-1",agent_type:"reviewer",duration_ms:5}'; }
mksub_read() { jq -cn --arg cwd "$T/proj" --arg fp "$1" \
  '{session_id:"s1",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:$fp},agent_id:"agent-1",agent_type:"reviewer",duration_ms:3}'; }

payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
mksub_edit "$T/proj/sub.ts" | hc                       # subagent edit -> counts
mksub_read "$T/proj/onlyread.ts" | hc                  # subagent read x3 -> excluded
mksub_read "$T/proj/onlyread.ts" | hc
mksub_read "$T/proj/onlyread.ts" | hc
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

ef=$(events_file); assert_json_lines "$ef"
jq -e 'select(.k=="edit" and .a==1 and .p=="sub.ts")' "$ef" >/dev/null || fail "subagent edit missing a:1"

raw=$(payload sessionstart-resume session_id=s2 | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"
assert_grep_fixed "Edited sub.ts" "$T/ac.txt"                 # subagent edit counted
grep -Fq 'onlyread.ts' "$T/ac.txt" && fail "subagent read surfaced in read-never-edited"

echo "A-13 ok: subagent edit counts (a:1), subagent read excluded from reads"
