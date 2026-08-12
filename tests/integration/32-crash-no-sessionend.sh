#!/bin/bash
# 32-crash-no-sessionend.sh — A-03 (TP-7 crash recovery). A full active session
# (edits, a fail, a red->green pair) with NO SessionEnd and a start-event pid
# pointing at a REAPED process. The next SessionStart (clock advanced >30 min)
# must still infer the end, inject a digest containing all of it, exit 0, and
# NOT double-infer when later clean sessions run.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

# a reaped pid for the start event (crash: the owner is gone).
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null || true
export SUPERVISOR_FAKE_CLAUDE_PID="$DEAD"

hc() { run_hook hook-capture.sh; }

export SUPERVISOR_NOW=1753689600
session_start_raw sessionstart-startup s1 >/dev/null      # start event pid=DEAD
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/foo.ts" | hc
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/foo.ts" | hc
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/foo.ts" | hc
export SUPERVISOR_NOW=1753689601
payload posttoolusefailure-bash session_id=s1 tool_input.command="npm test" | hc   # red
export SUPERVISOR_NOW=1753689602
payload posttooluse-bash-pass   session_id=s1 tool_input.command="npm test" | hc   # green
# CRASH: no stop, no session-end.

# Next session, clock advanced > 30 min: reconcile infers s1's end, injects it.
export SUPERVISOR_NOW=$((1753689600 + 3600))
raw=$(session_start_raw sessionstart-resume s2)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext // ""' > "$T/ac.txt"
assert_grep_fixed "Edited foo.ts ×3"     "$T/ac.txt"
assert_grep_fixed "npm test  ${TOK_REDGREEN}" "$T/ac.txt"

ef=$(events_file); assert_file_exists "$ef"; assert_json_lines "$ef"
ninf=$(grep -c '"inf":1' "$ef"); [ "$ninf" -eq 1 ] || fail "want exactly 1 inferred end, got $ninf"

# A later clean session must not double-infer or double-count s1.
payload posttooluse-edit session_id=s2 tool_input.file_path="$T/proj/bar.ts" | hc
export SUPERVISOR_NOW=$((1753689600 + 3660))
payload stop session_id=s2 | run_hook hook-stop.sh
payload sessionend-other session_id=s2 | run_hook hook-session-end.sh
export SUPERVISOR_NOW=$((1753689600 + 7200))
session_start_raw sessionstart-resume s3 >/dev/null
ninf2=$(grep -c '"inf":1' "$ef"); [ "$ninf2" -eq 1 ] || fail "inferred end re-appended: now $ninf2, want 1"

echo "A-03 ok: crashed run recovered (foo.ts ×3 + red->green), exactly one inferred end"
