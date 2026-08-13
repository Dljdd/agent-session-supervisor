#!/bin/bash
# 11-failed-command.sh — I-02 (AC2). A failed command with a long error: the
# digest names the command and shows the ECONNREFUSED marker (inside the first
# 200 chars) but NOT the TAIL_MARKER after char 300 (200-char capture cap), and
# the stored error field is <= 200 chars.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

pad=$(printf 'A%.0s' $(seq 1 480))
ERR="ECONNREFUSED 127.0.0.1:5432 ${pad}TAIL_MARKER_XYZ"     # ~523 chars, TAIL @ ~508

session_start_raw sessionstart-startup s1 >/dev/null
payload posttoolusefailure-bash session_id=s1 \
  tool_input.command="npm run test:integration" error="$ERR" | run_hook hook-capture.sh
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

ef=$(events_file); assert_file_exists "$ef"; assert_json_lines "$ef"
elen=$(jq -r 'select(.k=="bash" and .ok==false) | .e | length' "$ef" | head -1)
[ -n "$elen" ] || fail "no stored failure event"
[ "$elen" -le 200 ] || fail "stored error length $elen > 200"

raw=$(session_start_raw sessionstart-resume s2)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"
assert_grep "npm run test:integration" "$T/ac.txt"
assert_grep "ECONNREFUSED"             "$T/ac.txt"
assert_not_grep_fixed "TAIL_MARKER_XYZ" "$T/ac.txt"
# and the tail marker never reached the store either
assert_not_grep_fixed "TAIL_MARKER_XYZ" "$CLAUDE_PLUGIN_DATA"

echo "I-02 ok: command + ECONNREFUSED shown, TAIL truncated, stored error <=200"
