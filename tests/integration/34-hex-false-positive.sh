#!/bin/bash
# 34-hex-false-positive.sh — A-05. A command embedding a 40-hex git SHA (which
# trips the >=32-hex entropy rule) fails then passes with the IDENTICAL string.
# The digest still shows it red -> green (keying happens on the deterministically
# redacted string, TP-6) and stays human-recognizable (git checkout + npm test).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

SHA=3f5a2b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6
CMD="git checkout $SHA && npm test"
hc() { run_hook hook-capture.sh; }

payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
export SUPERVISOR_NOW=1753689600
payload posttoolusefailure-bash session_id=s1 tool_input.command="$CMD" | hc   # red
export SUPERVISOR_NOW=1753689700
payload posttooluse-bash-pass   session_id=s1 tool_input.command="$CMD" | hc   # green
export SUPERVISOR_NOW=1753689600
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

raw=$(payload sessionstart-resume session_id=s2 | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"

assert_grep_fixed "$TOK_REDGREEN" "$T/ac.txt"
# keying survived redaction: the Tests line carries this exact command red->green
grep -F "git checkout" "$T/ac.txt" | grep -Fq "$TOK_REDGREEN" || fail "command not shown red->green"
assert_grep "npm test" "$T/ac.txt"
# a 40-hex git SHA is the documented KEEP case (CT-15): it stays legible.
assert_grep_fixed "$SHA" "$T/ac.txt"

echo "A-05 ok: 40-hex SHA kept, red->green keying stable and human-recognizable"
