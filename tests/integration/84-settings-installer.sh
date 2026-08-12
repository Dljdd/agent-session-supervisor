#!/bin/bash
# tests/integration/84-settings-installer.sh — S-09 (design §18.27; critic
# SEC-08). install_statusline.py is the ONLY writer of ~/.claude/settings.json:
# minimal edit, timestamped backup, atomic parse-checked replace, idempotent,
# reversible; a malformed settings file is refused untouched.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
export TZ=UTC LC_ALL=C
export SUPERVISOR_NOW=1753689600   # deterministic backup name

t_sandbox
unset CLAUDE_PROJECT_DIR 2>/dev/null || true

INST="$PLUGIN_ROOT/scripts/py/install_statusline.py"
SET="$T/home/.claude/settings.json"
mkdir -p "$T/home/.claude"
# Normalize as the installer does (os.path.abspath collapses the double slash
# mktemp inherits from a trailing-slash TMPDIR) so equality checks line up.
DATA2=$(python3 -c "import os,sys;print(os.path.abspath(sys.argv[1]))" "$T/data2")
mkdir -p "$DATA2"
TARGET="$DATA2/bin/supervisor-statusline.sh"
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# ---- settings.json with 6 unrelated keys ----
cat > "$SET" <<'JSON'
{"model":"opus","theme":"dark","a":1,"b":[1,2,3],"c":{"x":true},"verbose":false}
JSON
cp "$SET" "$T/orig.json"

# ---- install ----
python3 "$INST" install --data-dir "$DATA2" >/dev/null; rc=$?
assert_exit0 $rc
# statusLine points at the installed copy
assert_jq ".statusLine.type == \"command\"" "$SET"
assert_jq ".statusLine.command == \"$TARGET\"" "$SET"
# the 6 unrelated keys are preserved (value-identical; the file is reformatted
# on write, so this is a semantic, not a raw-byte, comparison)
python3 - "$T/orig.json" "$SET" <<'PY' || fail "S-09 install did not preserve the 6 unrelated keys"
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2])); b.pop("statusLine", None)
sys.exit(0 if a == b else 1)
PY
# backup exists, mode 0600, no temp residue
ls "$T/home/.claude/settings.json.supervisor-bak-"* >/dev/null 2>&1 \
  || fail "S-09 no timestamped backup created"
perm=$(stat -f '%Lp' "$SET" 2>/dev/null || stat -c '%a' "$SET" 2>/dev/null)
[ "$perm" = "600" ] || fail "S-09 settings.json mode $perm != 600"
ls "$T/home/.claude/".*.suptmp* >/dev/null 2>&1 && fail "S-09 atomic-write temp residue left behind"

# ---- idempotency: second install is a no-op (mtime unchanged) ----
mt1=$(mtime "$SET")
out=$(python3 "$INST" install --data-dir "$DATA2"); rc=$?
assert_exit0 $rc
printf '%s\n' "$out" | grep -qi 'already installed' || fail "S-09 second install did not report 'already installed'"
mt2=$(mtime "$SET")
[ "$mt1" = "$mt2" ] || fail "S-09 second install rewrote settings.json (mtime changed)"

# ---- remove: no prior statusLine in the backup -> key deleted, 6 keys intact ----
python3 "$INST" remove >/dev/null; rc=$?
assert_exit0 $rc
assert_jq 'has("statusLine") | not' "$SET"
python3 - "$T/orig.json" "$SET" <<'PY' || fail "S-09 remove did not restore the original object"
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
sys.exit(0 if a == b else 1)
PY

# ---- pre-existing DIFFERENT statusLine: backed up, reported, restored on remove ----
cat > "$SET" <<'JSON'
{"statusLine":{"type":"command","command":"/usr/local/bin/old-line.sh"},"model":"opus"}
JSON
out=$(python3 "$INST" install --data-dir "$DATA2"); rc=$?
assert_exit0 $rc
printf '%s\n' "$out" | grep -qF '/usr/local/bin/old-line.sh' \
  || fail "S-09 install did not report the replaced statusLine value"
assert_jq ".statusLine.command == \"$TARGET\"" "$SET"
python3 "$INST" remove >/dev/null; rc=$?
assert_exit0 $rc
assert_jq '.statusLine.command == "/usr/local/bin/old-line.sh"' "$SET" \
  || fail "S-09 remove did not restore the pre-existing statusLine from backup"

# ---- malformed settings.json: non-zero, file byte-identical (untouched) ----
printf '{ not valid json ' > "$SET"
cp "$SET" "$T/mal.json"
python3 "$INST" install --data-dir "$DATA2" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] || fail "S-09 install on malformed settings.json must exit non-zero"
cmp -s "$SET" "$T/mal.json" || fail "S-09 malformed settings.json was modified"

# ---- show reports a settings.local.json override ----
printf '{}' > "$SET"
cat > "$T/home/.claude/settings.local.json" <<'JSON'
{"statusLine":{"type":"command","command":"/local/override.sh"}}
JSON
out=$(python3 "$INST" show); rc=$?
assert_exit0 $rc
printf '%s\n' "$out" | grep -qF 'settings.local.json' \
  || fail "S-09 show did not report the settings.local.json override"
printf '%s\n' "$out" | grep -qF '/local/override.sh' \
  || fail "S-09 show did not print the override value"

echo "S-09 ok: install/idempotent/remove/backup/atomic/malformed-refusal/local-override"
