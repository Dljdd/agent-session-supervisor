#!/bin/bash
# 16-non-git.sh — I-07 (AC7). A plain (non-git) project: the full cycle runs,
# every hook exits 0 with EMPTY stderr (no `fatal: not a git repository`
# leakage), events record, the digest carries edit + FAILED lines and NO
# REVERTED line, and no git snapshot objects are stored.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_plain
awake_off

serr hook-session-start.sh sessionstart-startup session_id=s1
serr hook-capture.sh posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/a.ts"
serr hook-capture.sh posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/a.ts"
serr hook-capture.sh posttoolusefailure-bash session_id=s1 tool_input.command="make build"
serr hook-stop.sh         stop             session_id=s1
serr hook-session-end.sh  sessionend-other session_id=s1

ef=$(events_file); assert_file_exists "$ef"; assert_json_lines "$ef"
assert_not_grep_fixed '"git":'              "$ef"
assert_not_grep_fixed 'fatal:'              "$CLAUDE_PLUGIN_DATA"
assert_not_grep_fixed 'not a git repository' "$CLAUDE_PLUGIN_DATA"

raw=$(session_start_raw sessionstart-resume s2)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"
assert_grep_fixed "Edited a.ts" "$T/ac.txt"
assert_grep "FAILED"            "$T/ac.txt"
assert_not_grep_fixed "REVERTED" "$T/ac.txt"

echo "I-07 ok: non-git full cycle clean (exit 0, no stderr, no git objects, no REVERTED)"
