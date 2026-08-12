#!/bin/bash
# 19-inject-contract.sh — I-10. For every SessionStart variant (startup, resume,
# future-fields) the hook stdout is EXACTLY one JSON object whose
# hookSpecificOutput.hookEventName == "SessionStart" and additionalContext is a
# string, with empty stderr. Stray stdout would itself be injected as context
# (a real contamination bug), so we assert the stdout is a single JSON line.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

# seed one CLOSED run so a digest exists (and consume the first-run note).
session_start_raw sessionstart-startup s1 >/dev/null
serr hook-capture.sh posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/a.ts"
serr hook-stop.sh         stop             session_id=s1
serr hook-session-end.sh  sessionend-other session_id=s1

check_variant() {  # check_variant <fixture> <sid>
  local fx="$1" sid="$2" out err
  err=$(mktemp)
  out=$(payload "$fx" session_id="$sid" | run_hook hook-session-start.sh 2>"$err")
  [ -s "$err" ] && { local m; m=$(cat "$err"); rm -f "$err"; fail "$fx: stderr not empty: $m"; }
  rm -f "$err"
  # exactly one line
  local nl; nl=$(printf '%s' "$out" | LC_ALL=C awk 'END{print NR}')
  [ "$nl" -eq 1 ] || fail "$fx: stdout is $nl lines, want exactly 1"
  printf '%s' "$out" | jq -e . >/dev/null || fail "$fx: stdout not valid JSON"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
    || fail "$fx: hookEventName != SessionStart"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext|type=="string"' >/dev/null \
    || fail "$fx: additionalContext not a string"
}

check_variant sessionstart-startup s2
check_variant sessionstart-resume  s3
check_variant sessionstart-future  s4

echo "I-10 ok: startup/resume/future all emit one clean SessionStart JSON object"
