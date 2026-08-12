#!/bin/bash
# 50-untracked-canary.sh — A-21 (critic SEC-07). A git project with an untracked
# `.env.production` (a secret-y NAME): after a full cycle the literal string
# `.env.production` (and its content) appear NOWHERE under the data dir —
# snapshots store only hashes/counts — while REVERTED adjudication for a
# genuinely reverted tracked file still works.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
printf 'orig\n' > "$T/proj/tracked.txt"
git -C "$T/proj" add -A; git -C "$T/proj" commit -qm files
printf 'SECRET_ENV_CONTENT_CANARY\n' > "$T/proj/.env.production"   # untracked, secret name
hc() { run_hook hook-capture.sh; }

payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
printf 'mod\n' > "$T/proj/tracked.txt"
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/tracked.txt" | hc
printf 'orig\n' > "$T/proj/tracked.txt"                      # restore -> reverted
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

# the untracked secret name/content never landed in the store (hashes only).
assert_not_grep_fixed ".env.production"           "$CLAUDE_PLUGIN_DATA"
assert_not_grep_fixed "SECRET_ENV_CONTENT_CANARY" "$CLAUDE_PLUGIN_DATA"

raw=$(payload sessionstart-resume session_id=s2 | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"
grep -F "tracked.txt" "$T/ac.txt" | grep -Fq "$TOK_NONET" || fail "REVERTED adjudication broke with an untracked file present"

echo "A-21 ok: untracked .env.production absent from store, REVERTED still works"
