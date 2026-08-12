#!/bin/bash
# 50p-sessionend-budget.sh — P-01. hook-session-end.sh stays cheap even on a
# heavy store: it only releases the wake lock and appends the end event
# (reconcile/rebuild is deferred to the next SessionStart, TP-7). The plugin
# SessionEnd budget is ~1.5s and hook timeouts cannot raise it (FACTS §1.7);
# the session-end hook launches 2 python processes (stdin-vars + capture --end),
# and its own marginal work must land under 1000ms.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
perf_gate 50p-sessionend-budget

export SUPERVISOR_NOW=1753689600
payload sessionstart-startup session_id=sess-0001 | run_hook hook-session-start.sh >/dev/null
seed_heavy_events
export SUPERVISOR_NOW=$((1753689600 + 14400))

run_end() { payload sessionend-other session_id=sess-0001 | run_hook hook-session-end.sh; }
assert_hook_budget "P-01 session-end (heavy store)" 2 1000 -- run_end

echo "P-01 ok: session-end cheap on a heavy store"
