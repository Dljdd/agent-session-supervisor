#!/bin/bash
# 30-interleaved-sessions.sh — A-01. Two sessions (s1, s2) interleaved in one
# project/events.jsonl: s1 edits a.ts ×3, s2 edits b.ts ×4. The next session's
# injected digest reports ONLY the latest closed run (s2: b.ts ×4), never s1's
# a.ts; sessions.jsonl carries one summary per ended session. Guards against
# cross-session bleed when two claude instances share a project.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

hc() { run_hook hook-capture.sh; }
ed() { payload posttooluse-edit session_id="$1" tool_input.file_path="$T/proj/$2" | hc; }

export SUPERVISOR_NOW=1753689600
session_start_raw sessionstart-startup s1 >/dev/null      # first-run note
session_start_raw sessionstart-startup s2 >/dev/null      # nothing (no closed run yet)

ed s1 a.ts; ed s2 b.ts
ed s1 a.ts; ed s2 b.ts
ed s1 a.ts; ed s2 b.ts
ed s2 b.ts                                                # a.ts ×3, b.ts ×4

export SUPERVISOR_NOW=1753690000
payload stop session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh
export SUPERVISOR_NOW=1753690500
payload stop session_id=s2 | run_hook hook-stop.sh
payload sessionend-other session_id=s2 | run_hook hook-session-end.sh

export SUPERVISOR_NOW=1753691000
raw=$(session_start_raw sessionstart-resume s3)
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"
assert_grep_fixed "Edited b.ts ×4" "$T/ac.txt"
assert_not_grep_fixed "a.ts" "$T/ac.txt"

# Deterministic sessions.jsonl: one row per ended run (s1 and s2).
_py=$(command -v python3)
"$_py" "$PLUGIN_ROOT/scripts/py/digest.py" rebuild --cwd "$T/proj" >/dev/null 2>&1
sf=$(ls "$CLAUDE_PLUGIN_DATA"/projects/*/sessions.jsonl | head -n1)
assert_file_exists "$sf"; assert_json_lines "$sf"
rows=$(grep -c . "$sf"); [ "$rows" -eq 2 ] || fail "sessions.jsonl has $rows rows, want 2"
jq -e 'select(.s=="s1")' "$sf" >/dev/null || fail "s1 summary missing"
jq -e 'select(.s=="s2")' "$sf" >/dev/null || fail "s2 summary missing"

echo "A-01 ok: latest run (s2 b.ts ×4) injected, no s1 bleed, 2 session summaries"
