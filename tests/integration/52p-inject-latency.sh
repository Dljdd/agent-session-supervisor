#!/bin/bash
# 52p-inject-latency.sh — P-03. hook-session-start.sh on the crash path (a heavy
# store whose owner is gone, so maintain must reconcile ~1300 events and the
# digest is rebuilt) keeps its own work under 500ms. SessionStart runs on every
# session, so it must stay fast (hooks.md:940). The start hook launches 4 python
# processes (stdin-vars + maintain sweep + digest inject + capture --start).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
perf_gate 52p-inject-latency

# a reaped owner pid so the heavy run is a CRASH the next start must reconcile.
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null || true
export SUPERVISOR_FAKE_CLAUDE_PID="$DEAD"

export SUPERVISOR_NOW=1753689600
payload sessionstart-startup session_id=sess-0001 | run_hook hook-session-start.sh >/dev/null
seed_heavy_events
# advance well past the 30-min idle rule so reconcile does the crash-path work.
export SUPERVISOR_NOW=$((1753689600 + 14400 + 3600))

run_start() { payload sessionstart-resume session_id=sess-0002 | run_hook hook-session-start.sh >/dev/null; }
assert_hook_budget "P-03 session-start (crash rebuild, heavy store)" 4 500 -- run_start

# sanity: the crash-path actually injected the recovered digest.
raw=$(payload sessionstart-resume session_id=sess-0003 | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -e '.hookSpecificOutput.additionalContext|type=="string"' >/dev/null \
  || fail "no digest injected after crash rebuild"

echo "P-03 ok: crash-path session-start within budget on a heavy store"
