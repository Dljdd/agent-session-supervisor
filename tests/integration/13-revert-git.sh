#!/bin/bash
# 13-revert-git.sh — I-04 (AC4). REVERTED adjudication across the real hooks:
#   A: create src/cache/redis.ts (untracked) then delete it  -> REVERTED
#   B: modify a committed file then restore it               -> REVERTED
#   C: modify a committed file and KEEP it                    -> normal Edited
# Digest names A and B with `— no net change`; C is not reverted; sessions.jsonl
# records the revert count (`rev`).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
printf 'B-orig\n' > "$T/proj/fileB.txt"; printf 'C-orig\n' > "$T/proj/fileC.txt"
git -C "$T/proj" add -A; git -C "$T/proj" commit -qm files

hc() { run_hook hook-capture.sh; }

session_start_raw sessionstart-startup s1 >/dev/null            # clean-tree snapshot

# A: create + Write event
mkdir -p "$T/proj/src/cache"; printf 'x\n' > "$T/proj/src/cache/redis.ts"
payload posttooluse-write session_id=s1 tool_input.file_path="$T/proj/src/cache/redis.ts" | hc
# B: modify committed file + Edit event
printf 'B-modified\n' > "$T/proj/fileB.txt"
payload posttooluse-edit  session_id=s1 tool_input.file_path="$T/proj/fileB.txt" | hc
# C: modify committed file + Edit event (kept)
printf 'C-modified\n' > "$T/proj/fileC.txt"
payload posttooluse-edit  session_id=s1 tool_input.file_path="$T/proj/fileC.txt" | hc

# revert A and B before end; leave C changed
rm -f "$T/proj/src/cache/redis.ts"
printf 'B-orig\n' > "$T/proj/fileB.txt"

payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

# next session start -> injected digest describes s1
raw=$(session_start_raw sessionstart-resume s2)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"

assert_grep_fixed "REVERTED" "$T/ac.txt"
grep -F "src/cache/redis.ts" "$T/ac.txt" | grep -Fq "$TOK_NONET" || fail "A (redis.ts) not REVERTED"
grep -F "fileB.txt"          "$T/ac.txt" | grep -Fq "$TOK_NONET" || fail "B (fileB) not REVERTED"
grep -F "fileC.txt" "$T/ac.txt" | grep -Fq "$TOK_NONET" && fail "C (fileC) wrongly REVERTED"
assert_grep_fixed "Edited fileC.txt" "$T/ac.txt"

# sessions.jsonl revert count for s1 == 2
sf=$(ls "$CLAUDE_PLUGIN_DATA"/projects/*/sessions.jsonl 2>/dev/null | head -n1)
assert_file_exists "$sf"; assert_json_lines "$sf"
rev=$(jq -r 'select(.s=="s1") | .rev' "$sf" | head -n1)
[ "$rev" = "2" ] || fail "sessions.jsonl rev for s1 = [$rev], want 2"

echo "I-04 ok: A+B REVERTED (no net change), C kept, sessions rev=2"
