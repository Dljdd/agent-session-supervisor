#!/bin/bash
# 32b-resume-within-30min.sh — A-03b (critic SF-07 golden). A crashed run whose
# last event is only 10 min old, PLUS an older CLOSED run in the same project.
# Resuming the same session id must inject the OLDER closed run (never the
# unterminated one, §9.1 closed-run rule) and append NO inferred end (too fresh).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null || true
export SUPERVISOR_FAKE_CLAUDE_PID="$DEAD"
hc() { run_hook hook-capture.sh; }

# older CLOSED run s_old
export SUPERVISOR_NOW=1753680000
payload sessionstart-startup session_id=s_old | run_hook hook-session-start.sh >/dev/null
payload posttooluse-edit session_id=s_old tool_input.file_path="$T/proj/oldfile.ts" | hc
payload stop             session_id=s_old | run_hook hook-stop.sh
payload sessionend-other session_id=s_old | run_hook hook-session-end.sh

# crashed run s_new, last event 10 min before "now"
export SUPERVISOR_NOW=1753689600
payload sessionstart-startup session_id=s_new | run_hook hook-session-start.sh >/dev/null
payload posttooluse-edit session_id=s_new tool_input.file_path="$T/proj/newfile.ts" | hc
# CRASH — no stop/end.

# resume s_new only 10 min later (< 30 min idle rule).
export SUPERVISOR_NOW=$((1753689600 + 600))
raw=$(payload sessionstart-resume session_id=s_new | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext // ""' > "$T/ac.txt"

assert_grep_fixed "Edited oldfile.ts" "$T/ac.txt"
assert_not_grep_fixed "newfile.ts" "$T/ac.txt"

ef=$(events_file)
ninf=$(grep -c '"inf":1' "$ef")          # grep -c prints 0 on no match (exit 1, stdout still "0")
[ "$ninf" -eq 0 ] || fail "inferred end appended for a fresh (<30 min) crashed run: $ninf"

echo "A-03b ok: older closed run injected, unterminated fresh run left open (no inferred end)"
