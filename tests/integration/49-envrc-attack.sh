#!/bin/bash
# 49-envrc-attack.sh — A-20 (critic SEC-06). (1) SUPERVISOR_DATA_DIR pointing
# into the project WITHOUT SUPERVISOR_TEST_MODE (and no CLAUDE_PLUGIN_DATA) is
# ignored: hooks exit 0 and create NOTHING under the project. (2) WITH test mode
# but the dir inside the git worktree, the containment check refuses:
# supervisorctl exits 4 and hooks no-op, leaving the project clean.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git

snap() { ( cd "$1" && find . 2>/dev/null | LC_ALL=C sort ); }

# ---- Part 1: env-var alone is ignored in production (CT-12) ----
before=$(snap "$T/proj")
(
  unset CLAUDE_PLUGIN_DATA SUPERVISOR_TEST_MODE
  export SUPERVISOR_DATA_DIR="$T/proj/.supervisor"
  payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/a.ts" | "$PLUGIN_ROOT/scripts/hook-capture.sh"; [ $? -eq 0 ] || { echo "capture rc!=0" >&2; exit 1; }
  payload sessionstart-startup session_id=s1 | "$PLUGIN_ROOT/scripts/hook-session-start.sh" >/dev/null; [ $? -eq 0 ] || { echo "start rc!=0" >&2; exit 1; }
) || fail "part1 hook returned non-zero"
after=$(snap "$T/proj")
[ "$before" = "$after" ] || fail "part1: env-var alone caused writes under project:
$(diff <(printf '%s' "$before") <(printf '%s' "$after"))"
[ -e "$T/proj/.supervisor" ] && fail "part1: .supervisor dir was created under the project"

# ---- Part 2: test-mode + dir inside the git worktree -> containment refuses ----
before2=$(snap "$T/proj")
export SUPERVISOR_TEST_MODE=1
export SUPERVISOR_DATA_DIR="$T/proj/.supervisor"   # inside the git worktree
unset CLAUDE_PLUGIN_DATA
# hooks no-op (python data_dir raises DataDirRefused -> caught -> exit 0, no write)
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/a.ts" | "$PLUGIN_ROOT/scripts/hook-capture.sh"; assert_exit0 "$?"
payload sessionstart-startup session_id=s1 | "$PLUGIN_ROOT/scripts/hook-session-start.sh" >/dev/null; assert_exit0 "$?"
# supervisorctl refuses with exit 4
( cd "$T/proj" && "$PLUGIN_ROOT/scripts/supervisorctl.sh" --data-dir "$T/proj/.supervisor" status >/dev/null 2>&1 )
rc=$?; [ "$rc" -eq 4 ] || fail "supervisorctl did not refuse contained data dir (exit $rc, want 4)"
after2=$(snap "$T/proj")
[ "$before2" = "$after2" ] || fail "part2: containment breach wrote under project:
$(diff <(printf '%s' "$before2") <(printf '%s' "$after2"))"
[ -e "$T/proj/.supervisor" ] && fail "part2: .supervisor dir created despite containment refusal"

echo "A-20 ok: env-var ignored without test-mode; contained data dir refused (exit 4), project clean"
