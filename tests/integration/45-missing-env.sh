#!/bin/bash
# tests/integration/45-missing-env.sh — A-16 (CT-12).
#
# With CLAUDE_PLUGIN_DATA unset AND the test-mode pair unset, hook-capture.sh
# and the boundary modes must exit 0 (fail-safe, non-blocking), write NOTHING
# under $HOME or $PWD (hooks have NO fallback — design §4.1.4), and emit nothing
# on stdout that would inject garbage context.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

t_sandbox
mk_proj_plain

# CT-12: no data dir resolvable at all.
unset CLAUDE_PLUGIN_DATA SUPERVISOR_DATA_DIR SUPERVISOR_TEST_MODE

snapshot() { ( cd "$1" && find . 2>/dev/null | LC_ALL=C sort ); }

# Work from inside $PWD == the project dir so a stray write would be caught.
cd "$T/proj" || fail "cannot cd proj"
HOME_BEFORE=$(snapshot "$HOME")
PWD_BEFORE=$(snapshot "$T/proj")

run_and_check() {  # run_and_check <label> <flag-or-empty> <fixture>
  local label="$1" flag="$2" fx="$3" out rc
  out=$(payload "$fx" | "$PLUGIN_ROOT/scripts/hook-capture.sh" $flag 2>/dev/null); rc=$?
  assert_exit0 "$rc"
  [ -z "$out" ] || fail "$label: stdout was non-empty: [$out]"
}

run_and_check "tool"  ""        posttooluse-bash-pass
run_and_check "start" "--start" sessionstart-startup
run_and_check "stop"  "--stop"  stop
run_and_check "end"   "--end"   sessionend-other

HOME_AFTER=$(snapshot "$HOME")
PWD_AFTER=$(snapshot "$T/proj")
[ "$HOME_BEFORE" = "$HOME_AFTER" ] || fail "hooks wrote under \$HOME:
$(diff <(printf '%s' "$HOME_BEFORE") <(printf '%s' "$HOME_AFTER"))"
[ "$PWD_BEFORE" = "$PWD_AFTER" ] || fail "hooks wrote under \$PWD:
$(diff <(printf '%s' "$PWD_BEFORE") <(printf '%s' "$PWD_AFTER"))"

echo "A-16 ok: missing env — exit 0, no writes under \$HOME/\$PWD, no stdout"
