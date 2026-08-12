#!/bin/bash
# tests/integration/61-awake-wiring.sh — plan Task 11 / strategy §11 W-06.
# End-to-end wiring through hooks.json (CT-1/CT-2): the awake scripts are NOT
# registered directly — they are invoked BY the hook entrypoints. This test
# extracts the EXACT registered SessionStart / SessionEnd command strings from
# hooks.json, runs them (with CLAUDE_PLUGIN_ROOT set) against the session
# fixtures, and asserts the SessionStart path produced an acquire and the
# SessionEnd path produced the release — closing the gap between the isolated
# script tests (60-awake) and registration reality.
#
# Ordering note: the entrypoints hook-session-start.sh / hook-session-end.sh are
# authored in plan Task 9, which wires `awake-acquire.sh "$SID"` /
# `awake-release.sh "$SID"` into them. Until Task 9 lands they may still be the
# runnable `exit 0` placeholders (plan Task 9 note), in which case the chain
# cannot be exercised and this test SKIPs (exit 75) with a reason. Once wired,
# it runs the full assertion. adrafinil mode is used so no caffeinate holder is
# spawned by the wiring probe.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox

HJ="$PLUGIN_ROOT/hooks/hooks.json"
assert_file_exists "$HJ"

write_adrafinil_shim() {
  cat > "$T/bin/adrafinil" <<'SHIM'
#!/bin/sh
printf 'adrafinil %s\n' "$*" >> "@@T@@/shim.log"
exit 0
SHIM
  sed -i.bak "s#@@T@@#$T#g" "$T/bin/adrafinil" && rm -f "$T/bin/adrafinil.bak"
  chmod +x "$T/bin/adrafinil"
}

# The EXACT registered command strings (jq over hooks.json).
start_cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HJ")
end_cmd=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$HJ")
[ -n "$start_cmd" ] && [ "$start_cmd" != "null" ] || fail "hooks.json: no SessionStart command"
[ -n "$end_cmd" ]   && [ "$end_cmd" != "null" ]   || fail "hooks.json: no SessionEnd command"

# The registered commands must reference the two entrypoints under the plugin root.
case "$start_cmd" in *hook-session-start.sh*) : ;; *) fail "SessionStart command is not hook-session-start.sh: [$start_cmd]";; esac
case "$end_cmd"   in *hook-session-end.sh*)   : ;; *) fail "SessionEnd command is not hook-session-end.sh: [$end_cmd]";; esac
start_script="$PLUGIN_ROOT/scripts/hook-session-start.sh"
end_script="$PLUGIN_ROOT/scripts/hook-session-end.sh"
assert_file_exists "$start_script"
assert_file_exists "$end_script"

# Wiring detection: are the entrypoints wired to the awake helpers yet (Task 9)?
if ! grep -q 'awake-acquire' "$start_script" 2>/dev/null || \
   ! grep -q 'awake-release' "$end_script" 2>/dev/null; then
  echo "SKIP 61-awake-wiring: hook entrypoints not yet wired to awake-acquire/awake-release"
  echo "  (plan Task 9 wires them; the awake scripts are invoked BY the entrypoints, so the"
  echo "   registered chain cannot be exercised while the entrypoints are exit-0 placeholders)."
  exit 75
fi

# Belt-and-braces: an out-of-sandbox adrafinil would still take the adrafinil
# branch (fine for this probe), but if it is missing AND no shim is found the
# entrypoint would attempt the caffeinate branch. We provide the shim, so mode
# `auto` prefers adrafinil deterministically.
write_adrafinil_shim
: > "$T/shim.log"
sid=w6sess

# Run the EXACT registered SessionStart command, piping the documented fixture.
payload sessionstart-startup session_id="$sid" | sh -c "$start_cmd"
assert_grep "acquire supervisor-$sid --tool claude-code" "$T/shim.log"
assert_file_exists "$T/data/awake/$sid.lock"
assert_jq '.mode=="adrafinil"' "$T/data/awake/$sid.lock"
echo "ok W-06: registered SessionStart command acquired the wake lock via adrafinil"

# Run the EXACT registered SessionEnd command; it must release + remove the lock.
: > "$T/shim.log"
payload sessionend-other session_id="$sid" | sh -c "$end_cmd"
assert_grep "release supervisor-$sid" "$T/shim.log"
[ -e "$T/data/awake/$sid.lock" ] && fail "registered SessionEnd command did not release/remove the wake lock"
echo "ok W-06: registered SessionEnd command released the wake lock"

echo "61-awake-wiring: chain verified"
exit 0
