#!/bin/bash
# 51p-capture-latency.sh — P-02. A single hook-capture.sh (one python launch)
# adds < 150ms of its own work; 100 sequential invocations pile up no worse than
# ~150ms each above the interpreter launch (async hooks fire per tool use with
# no dedup, FACTS §1.10).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
perf_gate 51p-capture-latency

# warm the project dir (first capture creates projects/<key>/ + meta.json).
payload posttooluse-bash-pass session_id=s1 | run_hook hook-capture.sh

one() { payload posttooluse-bash-pass session_id=s1 | run_hook hook-capture.sh; }
assert_hook_budget "P-02 single capture" 1 150 -- one

hundred() {
  local i=0
  while [ $i -lt 100 ]; do
    payload posttooluse-bash-pass session_id=s1 | run_hook hook-capture.sh
    i=$((i+1))
  done
}
# 100 launches: allow 100 × (baseline + 150ms marginal).
assert_hook_budget "P-02 ×100 sequential" 100 15000 -- hundred

echo "P-02 ok: capture marginal latency within budget (single + ×100)"
