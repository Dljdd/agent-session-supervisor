#!/bin/bash
# tests/integration/33-redaction-vectors.sh — A-04 (design §18.6, critic SEC-01).
#
# Table-driven over tests/fixtures/redaction-vectors.jsonl. Each vector's secret
# string is driven through the real capture routes — Bash command, Bash-failure
# error, and (path-class vectors) Read file_path — then the ENTIRE data dir is
# recursively fixed-string grepped: every must_not_contain string must be absent
# everywhere, every may_contain string must be present, and every event line
# stays jq-valid. This vector file is the acceptance gate for §18.6.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

VECTORS="$PLUGIN_ROOT/tests/fixtures/redaction-vectors.jsonl"
[ -f "$VECTORS" ] || { echo "SKIP: vectors fixture missing"; exit 75; }

t_sandbox
mk_proj_plain

hc() { "$PLUGIN_ROOT/scripts/hook-capture.sh" "$@"; }

# --- inject every vector through each applicable capture route ---------------
n=0
while IFS= read -r vec; do
  [ -n "$vec" ] || continue
  val=$(printf '%s' "$vec" | jq -r '.cmd // .err // .path')
  field=$(printf '%s' "$vec" | jq -r 'if .cmd then "cmd" elif .err then "err" else "path" end')

  # (a) Bash-pass command carries the secret.
  jq -cn --arg cwd "$CLAUDE_PROJECT_DIR" --arg c "$val" \
    '{session_id:"sess-0001",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},duration_ms:5}' \
    | hc
  # (b) Bash-failure error string carries the secret.
  jq -cn --arg cwd "$CLAUDE_PROJECT_DIR" --arg e "$val" \
    '{session_id:"sess-0001",cwd:$cwd,hook_event_name:"PostToolUseFailure",tool_name:"Bash",tool_input:{command:"run"},error:$e,is_interrupt:false,duration_ms:5}' \
    | hc
  # (c) path-class vectors also as a Read file_path.
  if [ "$field" = "path" ]; then
    jq -cn --arg cwd "$CLAUDE_PROJECT_DIR" --arg p "$val" \
      '{session_id:"sess-0001",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:$p},duration_ms:3}' \
      | hc
  fi
  n=$((n+1))
done < "$VECTORS"

EV=$(ls "$CLAUDE_PLUGIN_DATA"/projects/*/events.jsonl 2>/dev/null | head -n 1)
[ -n "$EV" ] || fail "no events.jsonl produced from $n vectors"
assert_json_lines "$EV"

# --- assert: secrets absent everywhere, expected markers present -------------
while IFS= read -r vec; do
  [ -n "$vec" ] || continue
  name=$(printf '%s' "$vec" | jq -r '.name')
  # must_not_contain: fixed-string grep over the WHOLE data dir must be empty.
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    assert_not_grep_fixed "$s" "$CLAUDE_PLUGIN_DATA"
  done <<EOF
$(printf '%s' "$vec" | jq -r '.must_not_contain[]?')
EOF
  # may_contain: each must be present somewhere in the data dir.
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -RFq -- "$s" "$CLAUDE_PLUGIN_DATA" || fail "[$name] expected may_contain [$s] missing"
  done <<EOF
$(printf '%s' "$vec" | jq -r '.may_contain[]?')
EOF
done < "$VECTORS"

echo "A-04 ok: $n vectors, all secrets redacted, markers present, lines jq-valid"
