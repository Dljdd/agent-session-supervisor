#!/bin/bash
# 15-secret-basic.sh — I-06 (AC6). A command carrying `sk-abc123def456ghi789jkl`
# is captured; the literal secret appears NOWHERE under the data dir, a redaction
# marker is present in the stored command, and the injected digest is clean too.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

SECRET='sk-abc123def456ghi789jkl'
payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
payload posttooluse-bash-pass session_id=s1 \
  tool_input.command="echo \"export API_KEY=$SECRET\"" | run_hook hook-capture.sh
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

# the whole data tree is free of the literal secret.
assert_not_grep_fixed "$SECRET" "$CLAUDE_PLUGIN_DATA"
# a redaction marker made it into the stored command.
ef=$(events_file); assert_grep_fixed "[REDACTED" "$ef"

raw=$(payload sessionstart-resume session_id=s2 | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"
assert_not_grep_fixed "$SECRET" "$T/ac.txt"

echo "I-06 ok: secret redacted everywhere, marker stored, digest clean"
