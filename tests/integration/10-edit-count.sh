#!/bin/bash
# 10-edit-count.sh — I-01 (AC1). Edit foo.ts 5× (kept), 1× bar.ts control; the
# NEXT session's injected digest says `Edited foo.ts ×5` and bar.ts carries no
# ×N multiplier. Full cycle runs through the real hook entrypoints (Task 9).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

# foo.ts / bar.ts tracked+clean at start, so kept edits read as normal Edited
# lines (not REVERTED).
printf 'orig\n' > "$T/proj/foo.ts"; printf 'orig\n' > "$T/proj/bar.ts"
git -C "$T/proj" add -A; git -C "$T/proj" commit -qm files

hc() { run_hook hook-capture.sh; }

# --- Session s1 ---
session_start_raw sessionstart-startup s1 >/dev/null   # first-run note, no digest yet
i=0
while [ $i -lt 5 ]; do
  printf 'edit%d\n' "$i" >> "$T/proj/foo.ts"          # keep the change (not reverted)
  payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/foo.ts" | hc
  i=$((i+1))
done
printf 'once\n' >> "$T/proj/bar.ts"
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/bar.ts" | hc
payload stop         session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

# events.jsonl: exactly 6 edit events, all jq-valid.
ef=$(events_file); assert_file_exists "$ef"; assert_json_lines "$ef"
n=$(grep -c '"k":"edit"' "$ef"); [ "$n" -eq 6 ] || fail "want 6 edit events, got $n"

# --- Session s2: injected digest describes s1 ---
raw=$(session_start_raw sessionstart-resume s2)
printf '%s' "$raw" > "$T/raw.json"
assert_jq '.hookSpecificOutput.hookEventName=="SessionStart"' "$T/raw.json"
printf '%s' "$raw" | jq -e '.hookSpecificOutput.additionalContext|type=="string"' >/dev/null \
  || fail "additionalContext is not a string"
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"
assert_grep_fixed "Edited foo.ts ×5" "$T/ac.txt"
assert_grep_fixed "Edited bar.ts"    "$T/ac.txt"
assert_not_grep_ext 'Edited bar\.ts ×' "$T/ac.txt"

echo "I-01 ok: foo.ts ×5, bar.ts no multiplier, 6 edit events, valid SessionStart JSON"
