#!/bin/bash
# tests/integration/46-self-noise.sh — A-17 (design §18.11, critic SF-05).
#
# The recorder must not record itself. Pipe the four §8.2 shapes:
#   (a) Bash command invoking supervisorctl.sh (rule 3)
#   (b) Read of a file under the data dir (rule 1)
#   (c) Read of a file under the plugin root (rule 4)
#   (d) Bash command containing the literal data-dir path (rule 2)
# Assert events.jsonl gains ZERO events; then a control payload still records.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

t_sandbox
mk_proj_plain

hc() { "$PLUGIN_ROOT/scripts/hook-capture.sh"; }
mkbash() { jq -cn --arg cwd "$CLAUDE_PROJECT_DIR" --arg c "$1" \
  '{session_id:"sess-0001",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},duration_ms:5}'; }
mkread() { jq -cn --arg cwd "$CLAUDE_PROJECT_DIR" --arg p "$1" \
  '{session_id:"sess-0001",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:$p},duration_ms:3}'; }

count_events() {
  local f
  f=$(ls "$CLAUDE_PLUGIN_DATA"/projects/*/events.jsonl 2>/dev/null | head -n 1)
  [ -n "$f" ] || { echo 0; return; }
  grep -c . "$f"
}

# (a) rule 3 — supervisorctl.sh
mkbash "\"$CLAUDE_PLUGIN_ROOT\"/scripts/supervisorctl.sh --data-dir \"$CLAUDE_PLUGIN_DATA\" recap" | hc
# (b) rule 1 — path under the data dir
mkread "$CLAUDE_PLUGIN_DATA/projects/abc123/digest.md" | hc
# (c) rule 4 — path under the plugin root
mkread "$CLAUDE_PLUGIN_ROOT/scripts/statusline.sh" | hc
# (d) rule 2 — command references the data-dir path literally
mkbash "cat $CLAUDE_PLUGIN_DATA/config.json" | hc

n=$(count_events)
[ "$n" -eq 0 ] || fail "self-noise payloads recorded $n event(s), want 0"

# Control: a genuine command still records.
mkbash "npm test" | hc
n=$(count_events)
[ "$n" -eq 1 ] || fail "control payload produced $n event(s), want 1"

echo "A-17 ok: 4 self-noise shapes dropped, control recorded"
