#!/bin/bash
# 13b-revert-subdir-cwd.sh — I-04b (critic SF-03). Every payload's cwd is a
# SUBDIRECTORY of the git root and edited paths are cwd-relative. A kept edit in
# the subdir must NOT be reported REVERTED (the old cwd-vs-porcelain base
# mismatch fabricated exactly that), while a genuinely reverted subdir file IS.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
mkdir -p "$T/proj/pkg/src"
printf 'keep-orig\n' > "$T/proj/pkg/src/keep.ts"
printf 'rev-orig\n'  > "$T/proj/pkg/src/rev.ts"
git -C "$T/proj" add -A; git -C "$T/proj" commit -qm files

SUB="$T/proj/pkg"
hc() { run_hook hook-capture.sh; }

payload sessionstart-startup session_id=s1 cwd="$SUB" | run_hook hook-session-start.sh >/dev/null

printf 'keep-mod\n' > "$SUB/src/keep.ts"     # kept
payload posttooluse-edit session_id=s1 cwd="$SUB" tool_input.file_path="$SUB/src/keep.ts" | hc
printf 'rev-mod\n'  > "$SUB/src/rev.ts"      # will be restored
payload posttooluse-edit session_id=s1 cwd="$SUB" tool_input.file_path="$SUB/src/rev.ts" | hc
printf 'rev-orig\n' > "$SUB/src/rev.ts"      # restore -> reverted

payload stop             session_id=s1 cwd="$SUB" | run_hook hook-stop.sh
payload sessionend-other session_id=s1 cwd="$SUB" | run_hook hook-session-end.sh

raw=$(payload sessionstart-resume session_id=s2 cwd="$SUB" | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"

grep -F "src/keep.ts" "$T/ac.txt" | grep -Fq "$TOK_NONET" && fail "kept subdir edit wrongly REVERTED"
grep -F "src/rev.ts"  "$T/ac.txt" | grep -Fq "$TOK_NONET" || fail "restored subdir file not REVERTED"
assert_grep_fixed "Edited src/keep.ts" "$T/ac.txt"

echo "I-04b ok: subdir cwd — kept edit not reverted, restored file reverted"
