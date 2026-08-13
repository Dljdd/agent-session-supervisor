#!/bin/bash
# 43-interrupt-not-red.sh — A-14. An interrupted `npm test` (is_interrupt:true)
# followed by a pass must NOT read as red -> green (an interrupt is not a failing
# test), and the interrupt event is dropped entirely (design §U6).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
hc() { run_hook hook-capture.sh; }

payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
export SUPERVISOR_NOW=1753689600
payload posttoolusefailure-interrupt session_id=s1 tool_input.command="npm test" | hc  # dropped
export SUPERVISOR_NOW=1753689700
payload posttooluse-bash-pass         session_id=s1 tool_input.command="npm test" | hc  # pass
export SUPERVISOR_NOW=1753689600
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

ef=$(events_file); assert_file_exists "$ef"
# the interrupt was dropped: no failing bash event stored.
jq -e 'select(.k=="bash" and .ok==false)' "$ef" >/dev/null 2>&1 && fail "interrupt event was stored as a failure"

raw=$(payload sessionstart-resume session_id=s2 | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext // ""' > "$T/ac.txt"
assert_not_grep_fixed "$TOK_REDGREEN" "$T/ac.txt"

echo "A-14 ok: interrupt dropped, no red->green from an interrupted-then-passed command"
