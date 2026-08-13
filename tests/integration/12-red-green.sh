#!/bin/bash
# 12-red-green.sh — I-03 (AC3). `npm test` fails then passes (later ts): digest
# marks it red -> green. A fail-only command shows as FAILED; a pass-only
# control carries no transition. pass/fail derives from WHICH event fired
# (PostToolUse vs PostToolUseFailure), never an exit-code field.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

hc() { run_hook hook-capture.sh; }

session_start_raw sessionstart-startup s1 >/dev/null

export SUPERVISOR_NOW=1753689600
payload posttoolusefailure-bash session_id=s1 tool_input.command="npm test"  | hc   # red
payload posttoolusefailure-bash session_id=s1 tool_input.command="npm run lint" | hc # fail-only control
export SUPERVISOR_NOW=1753689700
payload posttooluse-bash-pass   session_id=s1 tool_input.command="npm test"  | hc   # green
payload posttooluse-bash-pass   session_id=s1 tool_input.command="echo hi"   | hc   # pass-only control
export SUPERVISOR_NOW=1753689600

payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

raw=$(session_start_raw sessionstart-resume s2)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"

assert_grep_fixed "npm test  ${TOK_REDGREEN}" "$T/ac.txt"
# fail-only control renders as FAILED, not a transition
assert_grep "npm run lint" "$T/ac.txt"
grep -F "npm run lint" "$T/ac.txt" | grep -Fq "$TOK_REDGREEN" && fail "fail-only command wrongly marked red->green"
# pass-only control carries no transition line at all
grep -Fq "echo hi" "$T/ac.txt" && grep -F "echo hi" "$T/ac.txt" | grep -Eq "→" && fail "pass-only wrongly marked with a transition"

echo "I-03 ok: npm test red->green; fail-only=FAILED; pass-only no transition"
