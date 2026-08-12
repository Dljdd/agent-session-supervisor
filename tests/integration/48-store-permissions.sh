#!/bin/bash
# 48-store-permissions.sh — A-19 (design §18.28). After a full seeded run
# (capture, inject, telemetry write, statusline install), every file and dir
# under the data dir has mode & 0o077 == 0 (0700 dirs / 0600 files). Umask
# independence: the test relaxes umask to 022 first.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
umask 022
mk_proj_git
awake_off
mkdir -p "$HOME/.claude"; printf '{}\n' > "$HOME/.claude/settings.json"

# full cycle
payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/a.ts" | run_hook hook-capture.sh
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh
payload sessionstart-resume session_id=s2 | run_hook hook-session-start.sh >/dev/null

# telemetry write
jq -c --arg c "$T/proj" '.cwd=$c' "$PLUGIN_ROOT/tests/fixtures/payloads/statusline-full.json" \
  | python3 "$PLUGIN_ROOT/scripts/py/telemetry.py" --data-dir "$CLAUDE_PLUGIN_DATA" >/dev/null 2>&1 || true
# statusline install (writes <data>/bin/* )
python3 "$PLUGIN_ROOT/scripts/py/install_statusline.py" install --data-dir "$CLAUDE_PLUGIN_DATA" >/dev/null 2>&1 || true

python3 - <<'PY'
import os, sys, stat
base = os.environ["CLAUDE_PLUGIN_DATA"]
bad = []
for root, dirs, files in os.walk(base):
    for name in dirs + files:
        p = os.path.join(root, name)
        try:
            m = os.lstat(p).st_mode
        except OSError:
            continue
        if stat.S_ISLNK(m):
            continue
        if m & 0o077:
            bad.append("%s %s" % (oct(m & 0o777), p))
if bad:
    sys.stderr.write("group/other-accessible entries:\n" + "\n".join(bad) + "\n")
    sys.exit(1)
# make sure we actually created a populated tree (not a vacuous pass)
n = sum(len(f) for _, _, f in os.walk(base))
if n < 3:
    sys.stderr.write("data tree suspiciously empty (%d files)\n" % n)
    sys.exit(1)
print("perm-walk ok: %d files, all 0o700/0o600" % n)
PY
rc=$?; [ "$rc" -eq 0 ] || fail "permission walk failed"

echo "A-19 ok: data tree is 0700/0600 under umask 022"
