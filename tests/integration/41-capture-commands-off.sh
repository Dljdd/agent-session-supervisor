#!/bin/bash
# tests/integration/41-capture-commands-off.sh — A-12 (CT-5 / TP-12, design §4.4).
#
# With capture_commands=false: Bash PASS events add nothing and are dropped;
# Bash FAIL events keep the failure (ok:false) but store the placeholder
# "[command capture disabled]" with NO command text and NO error text; Read/Edit
# path events are unaffected. Toggled two ways (seeded config.json, then the
# supervisorctl setter), and default-on is confirmed by deleting config.json.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

t_sandbox
mk_proj_plain

CTL="$PLUGIN_ROOT/scripts/supervisorctl.sh"
hc() { "$PLUGIN_ROOT/scripts/hook-capture.sh"; }
mkpass() { jq -cn --arg cwd "$CLAUDE_PROJECT_DIR" --arg c "$1" \
  '{session_id:"sessA12",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},duration_ms:5}'; }
mkfail() { jq -cn --arg cwd "$CLAUDE_PROJECT_DIR" --arg c "$1" --arg e "$2" \
  '{session_id:"sessA12",cwd:$cwd,hook_event_name:"PostToolUseFailure",tool_name:"Bash",tool_input:{command:$c},error:$e,duration_ms:9}'; }
mkedit() { jq -cn --arg cwd "$CLAUDE_PROJECT_DIR" --arg p "$1" \
  '{session_id:"sessA12",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$p},duration_ms:4}'; }
mkread() { jq -cn --arg cwd "$CLAUDE_PROJECT_DIR" --arg p "$1" \
  '{session_id:"sessA12",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:$p},duration_ms:3}'; }
evfile() { ls "$CLAUDE_PLUGIN_DATA"/projects/*/events.jsonl 2>/dev/null | head -n 1; }

# =====================================================================
# Phase A — capture_commands=false via a seeded config.json
# =====================================================================
mkdir -p "$CLAUDE_PLUGIN_DATA"
echo '{"v":1,"capture_commands":false}' > "$CLAUDE_PLUGIN_DATA/config.json"

mkpass "PASSCMD_AAA echo hello"        | hc
mkfail "FAILCMD_AAA pytest" "ERRTEXT_AAA traceback boom" | hc
mkedit "src/edited_here.py"            | hc
mkread "src/read_here.py"              | hc

EV=$(evfile); [ -n "$EV" ] || fail "no events.jsonl created"
assert_json_lines "$EV"

# command + error text never reached disk
assert_not_grep_fixed "PASSCMD_AAA" "$EV"
assert_not_grep_fixed "FAILCMD_AAA" "$EV"
assert_not_grep_fixed "ERRTEXT_AAA" "$EV"
# path events survive
grep -Fq "edited_here.py" "$EV" || fail "edit path event dropped"
grep -Fq "read_here.py" "$EV"   || fail "read path event dropped"
# the pass Bash event is dropped entirely; the fail is kept as a redacted placeholder
nbash=$(grep -Fc '"k":"bash"' "$EV")
[ "$nbash" -eq 1 ] || fail "expected exactly 1 bash (fail) event, got $nbash"
grep -Fq '"c":"[command capture disabled]"' "$EV" || fail "disabled placeholder missing on the fail event"
grep -Fq '"ok":false' "$EV" || fail "fail event lost its ok:false"
grep -Fq '"e":' "$EV" && fail "error text field present though commands disabled"

# digest aggregate line (needs digest.py — Task 6). Exercised only when present.
if [ -f "$PLUGIN_ROOT/scripts/py/digest.py" ]; then
  dg=$( cd "$CLAUDE_PROJECT_DIR" && "$CTL" --data-dir "$CLAUDE_PLUGIN_DATA" recap )
  printf '%s\n' "$dg" | grep -Eiq 'commands hidden' || fail "digest missing 'commands hidden' aggregate line"
  printf '%s\n' "$dg" | grep -Fq "FAILCMD_AAA" && fail "digest leaked a hidden command"
  echo "digest 'commands hidden' line exercised (digest.py present)"
else
  echo "note: digest.py absent (Task 6) — 'commands hidden' digest line not exercised here"
fi

# =====================================================================
# Phase B — same behavior when toggled through the supervisorctl setter
# =====================================================================
rm -f "$CLAUDE_PLUGIN_DATA/config.json"
( cd "$CLAUDE_PROJECT_DIR" && "$CTL" --data-dir "$CLAUDE_PLUGIN_DATA" config set capture_commands false ) >/dev/null
rc=$?; [ "$rc" -eq 0 ] || fail "setter config set capture_commands false exit $rc"
got=$( cd "$CLAUDE_PROJECT_DIR" && "$CTL" --data-dir "$CLAUDE_PLUGIN_DATA" config get capture_commands )
assert_eq "false" "$got"

mkfail "PHASEB_SECRET pytest --token" "PHASEB_ERR stack" | hc
EV=$(evfile)
assert_not_grep_fixed "PHASEB_SECRET" "$EV"
assert_not_grep_fixed "PHASEB_ERR" "$EV"

# =====================================================================
# Phase C — deleting config.json restores the default (capture_commands=true)
# =====================================================================
rm -f "$CLAUDE_PLUGIN_DATA/config.json"
mkpass "PHASEC_VISIBLE echo ok" | hc
EV=$(evfile)
grep -Fq "PHASEC_VISIBLE" "$EV" || fail "default-on: pass command not recorded"

echo "A-12 ok: commands+errors hidden when off (seed + setter), path events kept, default-on restored"
