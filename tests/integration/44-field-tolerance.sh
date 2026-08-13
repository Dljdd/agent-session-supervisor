#!/bin/bash
# 44-field-tolerance.sh — A-15. Payloads with (a) five extra unknown fields at
# top level and inside tool_input and (b) removed optional fields (duration_ms,
# is_interrupt, permission_mode) must still exit 0 and produce equivalent events
# — guarding the 2.1.126-floor vs newer-CLI payload skew (FACTS §8).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

# forward-compatible SessionStart (extra fields) exits 0 with valid JSON.
serr hook-session-start.sh sessionstart-future session_id=s1 >/dev/null 2>&1 || true
out=$(payload sessionstart-future session_id=s1 | run_hook hook-session-start.sh 2>/dev/null); rc=$?
assert_exit0 "$rc"

# edit with 5 extra unknown fields + removed duration_ms -> same k/p as the floor.
base=$(jq -c --arg cwd "$T/proj" --arg fp "$T/proj/a.ts" \
  '.cwd=$cwd|.tool_input.file_path=$fp' "$PLUGIN_ROOT/tests/fixtures/payloads/posttooluse-edit.json")
var=$(printf '%s' "$base" | jq -c '
  .x1="a"|.x2="b"|.x3="c"|.x4="d"|.x5="e"
  |.tool_input.y1="p"|.tool_input.y2="q"
  |del(.duration_ms)|del(.permission_mode)')
printf '%s' "$base" | run_hook hook-capture.sh
printf '%s' "$var"  | run_hook hook-capture.sh
ef=$(events_file); assert_json_lines "$ef"
nedit=$(jq -e -s '[.[]|select(.k=="edit" and .p=="a.ts")]|length' "$ef")
[ "$nedit" -eq 2 ] || fail "extra/removed-field edits not equivalent: got $nedit edit events, want 2"

# boundary hooks with a failure payload missing is_interrupt still exit 0.
fail_noflag=$(jq -c --arg cwd "$T/proj" 'del(.is_interrupt)' \
  "$PLUGIN_ROOT/tests/fixtures/payloads/posttoolusefailure-bash.json")
printf '%s' "$fail_noflag" | run_hook hook-capture.sh; assert_exit0 "$?"
payload stop             session_id=s1 | run_hook hook-stop.sh;         assert_exit0 "$?"
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh;  assert_exit0 "$?"

echo "A-15 ok: extra/removed fields tolerated, equivalent stores, all hooks exit 0"
