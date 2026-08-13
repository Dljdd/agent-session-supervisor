#!/bin/bash
# 37-corrupt-store.sh — A-08. A store containing a valid line, a torn half-line
# (power-loss artifact), a garbage non-JSON line and an empty line still builds a
# digest that includes every valid event and skips the garbage without crashing.
# Also probes the TP-5 torn-tail guard: appending to a file whose last byte is
# not \n prefixes the write with one \n so events never merge.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
hc() { run_hook hook-capture.sh; }

payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/foo.ts" | hc
ef=$(events_file); assert_file_exists "$ef"

# torn tail: a half line with NO trailing newline.
printf '{"v":1,"ts":1753689600,"s":"s1","k":"edit","p":"tor' >> "$ef"
# next capture must NOT merge into the torn line (torn-tail guard prefixes \n).
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/bar.ts" | hc
tail -n1 "$ef" | jq -e 'select(.p=="bar.ts")' >/dev/null \
  || fail "torn-tail guard failed: last line is not a clean bar.ts event"

# garbage + empty line, then another valid event.
printf 'THIS LINE IS NOT JSON AT ALL\n\n' >> "$ef"
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/baz.ts" | hc

payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

# digest builds over the corrupt store, exits 0, includes every valid edit.
raw=$(payload sessionstart-resume session_id=s2 | run_hook hook-session-start.sh); rc=$?
assert_exit0 "$rc"
printf '%s' "$raw" | jq -e . >/dev/null || fail "corrupt store produced invalid inject JSON"
printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext' > "$T/ac.txt"
assert_grep_fixed "Edited foo.ts" "$T/ac.txt"
assert_grep_fixed "Edited bar.ts" "$T/ac.txt"
assert_grep_fixed "Edited baz.ts" "$T/ac.txt"

echo "A-08 ok: torn/garbage/empty lines skipped, all valid events survive, torn-tail isolated"
