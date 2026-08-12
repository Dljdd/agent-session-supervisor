#!/bin/bash
# 17-first-run.sh — I-08 (+ SEC-14). The one-time first-run disclosure: the
# first SessionStart injects it (mentions local recording, /supervisor:config,
# /supervisor:forget), drops the `first_run_notified` marker, and a SECOND start
# does NOT repeat it. hook-capture BEFORE any SessionStart also exits 0 and
# creates the store (hooks can race).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

# capture before any session-start: exit 0 + store created.
serr hook-capture.sh posttooluse-edit session_id=s0 tool_input.file_path="$T/proj/x.ts"
assert_file_exists "$(events_file)"

# first start -> valid JSON + note + marker.
raw=$(session_start_raw sessionstart-startup s1)
printf '%s' "$raw" | jq -e . >/dev/null || fail "first start stdout not valid JSON"
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac1.txt"
assert_grep_fixed "/supervisor:config" "$T/ac1.txt"
assert_grep_fixed "/supervisor:forget" "$T/ac1.txt"
assert_grep       "recorded locally"   "$T/ac1.txt"
assert_file_exists "$CLAUDE_PLUGIN_DATA/first_run_notified"

# second start -> no repeat of the note.
raw2=$(session_start_raw sessionstart-startup s2)
printf '%s' "$raw2" | jq -r '.hookSpecificOutput.additionalContext // ""' > "$T/ac2.txt"
assert_not_grep_fixed "/supervisor:forget" "$T/ac2.txt"

echo "I-08 ok: first-run note once, marker set, not repeated; pre-start capture safe"
