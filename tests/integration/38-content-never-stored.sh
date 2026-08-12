#!/bin/bash
# 38-content-never-stored.sh — A-09. Canary strings planted in Write content, a
# Read tool_response, a Bash stdout, and Edit old/new_string must NEVER reach the
# store. Enforces "paths and counts only, never file contents" as a hard,
# greppable property.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
hc() { run_hook hook-capture.sh; }

payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
# fixtures already embed the canaries: CANARY_WRITE_CONTENT, CANARY_READ_CONTENT,
# CANARY_STDOUT, CANARY_OLD/CANARY_NEW.
payload posttooluse-write     session_id=s1 tool_input.file_path="$T/proj/a.ts" | hc
payload posttooluse-read      session_id=s1 tool_input.file_path="$T/proj/b.ts" | hc
payload posttooluse-bash-pass session_id=s1 | hc
payload posttooluse-edit      session_id=s1 tool_input.file_path="$T/proj/c.ts" | hc
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh
payload sessionstart-resume session_id=s2 | run_hook hook-session-start.sh >/dev/null

for canary in CANARY_WRITE_CONTENT CANARY_READ_CONTENT CANARY_STDOUT CANARY_OLD CANARY_NEW; do
  assert_not_grep_fixed "$canary" "$CLAUDE_PLUGIN_DATA"
done

echo "A-09 ok: no file/response/stdout/diff content stored (5 canaries absent)"
