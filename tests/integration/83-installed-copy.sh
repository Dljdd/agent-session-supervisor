#!/bin/bash
# tests/integration/83-installed-copy.sh — S-08 (design §18.26; critics
# SF-04/TF-5/SEC-11). The installed copy must be fully self-contained: baked
# data dir + a co-located telemetry.py, so it renders AND persists telemetry
# with the plugin root gone and NONE of the CLAUDE_*/SUPERVISOR_* env present.
# data2 deliberately simulates a MARKETPLACE id dir (not "-inline").
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
export TZ=UTC LC_ALL=C

t_sandbox

# Install FROM A COPY of the plugin scripts so we can then delete that source and
# prove the installed artifact reaches back to nothing. (Never touch the real
# repo scripts dir — other tests run against it.)
SRC="$T/src"
mkdir -p "$SRC/scripts"
cp -R "$PLUGIN_ROOT/scripts/statusline.sh" "$SRC/scripts/statusline.sh"
cp -R "$PLUGIN_ROOT/scripts/py" "$SRC/scripts/py"

# Normalize the path the way the installer stores it (os.path.abspath collapses
# the double slash mktemp inherits from a trailing-slash TMPDIR).
DATA2=$(python3 -c "import os,sys;print(os.path.abspath(sys.argv[1]))" "$T/data2")
mkdir -p "$DATA2"
# The installer resolves its plugin root from its own __file__, so run the COPY.
python3 "$SRC/scripts/py/install_statusline.py" install --data-dir "$DATA2" >/dev/null; rc=$?
assert_exit0 $rc
assert_file_exists "$DATA2/bin/supervisor-statusline.sh"
assert_file_exists "$DATA2/bin/telemetry.py"
# baked line points at data2 (self-location independent)
grep -qF "SUPERVISOR_BAKED_DATA_DIR=\"$DATA2\"" "$DATA2/bin/supervisor-statusline.sh" \
  || fail "S-08 installed copy did not bake the data dir"

# The plugin source is now gone.
rm -rf "$SRC"

# Run the installed copy in a BARE environment: no CLAUDE_*/SUPERVISOR_* at all,
# a fresh HOME, only PATH+TZ. It must render the golden line and write telemetry.
OUT="$T/installed.out"
env -i HOME="$T/home" PATH="$PATH" TZ=UTC LC_ALL=C \
  "$DATA2/bin/supervisor-statusline.sh" < "$PLUGIN_ROOT/tests/fixtures/payloads/statusline-full.json" \
  > "$OUT" 2>"$T/installed.err"; rc=$?
assert_exit0 $rc
[ -s "$T/installed.err" ] && fail "S-08 installed copy wrote to stderr: $(cat "$T/installed.err")"
cmp -s "$OUT" "$PLUGIN_ROOT/tests/fixtures/golden/statusline-full.out" \
  || fail "S-08 installed copy render != golden. got: $(cat "$OUT")"

# The co-located telemetry.py (baked dir) made the persist path fully local.
RL="$DATA2/telemetry/rate_limits.json"
i=0; while [ $i -lt 50 ]; do [ -f "$RL" ] && break; sleep 0.1; i=$((i+1)); done
assert_file_exists "$RL"
assert_jq '.five_hour.resets_at == 1738425600' "$RL"
python3 -c "import json;json.load(open('$RL'))" || fail "S-08 installed-copy telemetry not valid JSON"

echo "S-08 ok: installed copy renders + persists telemetry with plugin root gone and a bare env"
