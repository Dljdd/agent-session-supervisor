#!/bin/bash
# tests/lib.sh — sandbox, payloads, asserts. bash 3.2 compatible.
set -u

t_sandbox() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/suptest.XXXXXX")
  mkdir -p "$T/home" "$T/data" "$T/proj" "$T/bin"
  export HOME="$T/home"
  export CLAUDE_PLUGIN_DATA="$T/data"
  export CLAUDE_PROJECT_DIR="$T/proj"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export SUPERVISOR_TEST_MODE=1
  export SUPERVISOR_DATA_DIR="$T/data"
  export SUPERVISOR_NOW="${SUPERVISOR_NOW:-1753689600}"
  export PATH="$T/bin:$PATH"
  trap t_teardown EXIT
}
t_teardown() { pkill -f "$T" 2>/dev/null; rm -rf "$T"; }

mk_proj_git()        { git -C "$T/proj" init -q; echo base > "$T/proj/base.txt"; git -C "$T/proj" add -A; git -C "$T/proj" commit -qm init; }
mk_proj_git_remote() { mk_proj_git; git -C "$T/proj" remote add origin "$1"; }
mk_proj_plain()      { echo x > "$T/proj/file.txt"; }

payload() {  # payload <fixture-basename> [jq.path=value ...] -> stdout JSON
  local f="$PLUGIN_ROOT/tests/fixtures/payloads/$1.json"; shift
  local jqargs='.cwd=$cwd'
  local out; out=$(jq -c --arg cwd "$CLAUDE_PROJECT_DIR" "$jqargs" "$f")
  local kv
  for kv in "$@"; do
    out=$(printf '%s' "$out" | jq -c --arg v "${kv#*=}" "setpath(path(.${kv%%=*}); \$v)")
  done
  printf '%s' "$out"
}
run_hook() { "$PLUGIN_ROOT/scripts/$1"; }   # stdin passes through; caller captures out/err/rc

assert_eq()           { [ "$1" = "$2" ] || fail "expected [$1] got [$2]"; }
assert_exit0()        { [ "$1" -eq 0 ] || fail "expected exit 0 got $1"; }
assert_file_exists()  { [ -e "$1" ] || fail "missing $1"; }
assert_line_count()   { local n; n=$(wc -l < "$1" | tr -d ' '); [ "$n" -eq "$2" ] || fail "$1: $n lines, want $2"; }
assert_grep()         { grep -Eq "$1" "$2" || fail "no match /$1/ in $2"; }
assert_not_grep_fixed(){ if grep -RFq -- "$1" "$2" 2>/dev/null; then fail "found forbidden [$1] under $2"; fi; }
assert_jq()           { jq -e "$1" "$2" >/dev/null || fail "jq $1 failed on $2"; }
assert_json_lines()   { while IFS= read -r l; do [ -z "$l" ] && continue; printf '%s' "$l" | jq -e . >/dev/null || fail "bad JSONL in $1"; done < "$1"; }
assert_max_chars()    { local n; n=$(python3 -c 'import sys;print(len(sys.stdin.read()))' < "$2"); [ "$n" -le "$1" ] || fail "$2: $n chars > $1"; }
assert_max_bytes()    { local n; n=$(LC_ALL=C wc -c < "$2" | tr -d ' '); [ "$n" -le "$1" ] || fail "$2: $n bytes > $1"; }
assert_single_line()  { local n; n=$(LC_ALL=C awk 'END{print NR}' "$1"); [ "$n" -eq 1 ] || fail "$1: $n lines, want exactly 1"; }
assert_duration_under_ms() {  # assert_duration_under_ms <ms> -- cmd args...
  # python3 time.monotonic wrapper (BSD date has no sub-second resolution).
  # The command runs in THIS shell (functions/redirections work); the measured
  # window includes one python3 startup (~tens of ms) — budgets have margin.
  local limit="$1"; shift; [ "${1:-}" = "--" ] && shift
  local t0 t1 rc dur
  t0=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
  "$@"; rc=$?
  t1=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
  dur=$((t1 - t0))
  [ "$rc" -eq 0 ] || fail "command failed rc=$rc: $*"
  [ "$dur" -le "$limit" ] || fail "took ${dur}ms > ${limit}ms: $*"
}
fail()                { echo "ASSERT FAIL: $*" >&2; exit 1; }

DIGEST_MAX_CHARS=1600   # mirror of scripts/py/digest.py (CT-4); L-09 asserts they match

# ============================================================================
# Task 9 shared helpers (session-cycle integration; design §9.4 / U9-U11).
# Appended, purely additive — existing tests do not reference these names.
# ============================================================================

# Disable the wake-lock BEFORE any hook-session-start.sh call. On a dev box a
# live `claude` ancestor is detectable, so with awake=auto the entrypoint would
# `sup_detach caffeinate -ims -w <claude-pid>` — a keepalive that outlives the
# sandbox and is NOT caught by `pkill -f "$T"` (its argv carries no $T marker).
# Every git/plain session test calls this first; awake wiring itself is proven
# separately in 60/61/62 with dedicated shims.
awake_off() {
  mkdir -p "$CLAUDE_PLUGIN_DATA" 2>/dev/null
  printf '{"v":1,"awake":"off"}\n' > "$CLAUDE_PLUGIN_DATA/config.json"
}
# awake=off plus one extra bool/str config key in a single write.
awake_off_with() {  # awake_off_with <json-key> <json-value-literal>
  mkdir -p "$CLAUDE_PLUGIN_DATA" 2>/dev/null
  printf '{"v":1,"awake":"off",%s:%s}\n' "\"$1\"" "$2" > "$CLAUDE_PLUGIN_DATA/config.json"
}

# Path of the single project's store files ("" when absent).
events_file() { ls "$CLAUDE_PLUGIN_DATA"/projects/*/events.jsonl 2>/dev/null | head -n 1; }
digest_file() { ls "$CLAUDE_PLUGIN_DATA"/projects/*/digest.md   2>/dev/null | head -n 1; }

# Run hook-session-start with a fixture; emit the injected additionalContext
# string ("" when nothing is injected). Caller must have run awake_off first.
session_start_ac() {  # session_start_ac <fixture> <session_id> [jq kv...]
  local fx="$1" sid="$2"; shift 2
  payload "$fx" session_id="$sid" "$@" | run_hook hook-session-start.sh \
    | jq -r '.hookSpecificOutput.additionalContext // empty'
}
# Same, but emit the raw hook stdout (for JSON-shape / emptiness asserts).
session_start_raw() {  # session_start_raw <fixture> <session_id> [jq kv...]
  local fx="$1" sid="$2"; shift 2
  payload "$fx" session_id="$sid" "$@" | run_hook hook-session-start.sh
}

# Byte-exact (fixed-string) grep for the multibyte digest glyphs (× — →),
# which an LC_ALL=C -E pattern can mangle.
assert_grep_fixed()   { grep -Fq -- "$1" "$2" || fail "no fixed match [$1] in $2"; }
assert_not_grep_ext() { if grep -Eq "$1" "$2" 2>/dev/null; then fail "forbidden /$1/ in $2"; fi; }

# Run a hook script with a templated payload; assert exit 0 AND empty stderr
# (no `fatal: not a git repository` or other leakage), discarding stdout.
serr() {  # serr <script.sh> <fixture> [jq kv...]
  local s="$1" fx="$2"; shift 2
  local e; e=$(mktemp)
  payload "$fx" "$@" | "$PLUGIN_ROOT/scripts/$s" >/dev/null 2>"$e"; local rc=$?
  assert_exit0 "$rc"
  [ -s "$e" ] && { local msg; msg=$(cat "$e"); rm -f "$e"; fail "$s emitted stderr: $msg"; }
  rm -f "$e"
}

# Bulk-load the gen seed-42 heavy stream (~1300 events) into the CURRENT
# project store under session sess-0001, in ONE interpreter (byte-identical
# routing to hook-capture.sh; the per-event shell path is proven elsewhere).
# Retargets gen's hardcoded /sandbox/proj at the sandbox project so every event
# lands in the same store as the boundary events.
seed_heavy_events() {
  local gen="$PLUGIN_ROOT/tests/fixtures/generators/gen_heavy_session.py"
  python3 "$gen" --seed 42 --times-out "$T/times.txt" > "$T/heavy.jsonl"
  python3 - "$T/heavy.jsonl" "$T/times.txt" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["PLUGIN_ROOT"], "scripts", "py"))
import capture
proj = os.environ["CLAUDE_PROJECT_DIR"]
lines = [l for l in open(sys.argv[1]).read().split("\n") if l]
times = [t for t in open(sys.argv[2]).read().split("\n") if t]
for i, line in enumerate(lines):
    line = line.replace("/sandbox/proj", proj)
    if i < len(times):
        os.environ["SUPERVISOR_NOW"] = times[i]
    capture.main(argv=[], stdin=line)
PY
}

# --- perf helpers (P-01..P-03) -----------------------------------------------
# The hooks shell out to python3 by PATH. On some dev machines python3 is a slow
# launcher (e.g. a pyenv shim, ~250-300ms/launch) that dwarfs the plugin's own
# work, so an ABSOLUTE sub-second budget measures the interpreter launcher, not
# the plugin. We therefore budget the plugin's MARGINAL cost: a hook that spawns
# N python processes is allowed N × (measured bare-`python3 -c pass`) + the
# strategy's budget. On a normal machine (launch ~30ms) this is essentially the
# strategy's absolute budget; everywhere it still catches a real regression in
# the plugin's own overhead (extra spawn, slow scan). The raw wall time and the
# derived budget are printed so absolute numbers stay visible.
_PY_BASELINE_MS=""
py_baseline_ms() {
  # Min of a few `python3 -c pass` launches spawned FROM THE SHELL by PATH — the
  # exact path the hooks use (a non-python parent exec'ing python3, which on a
  # pyenv box pays the full shim cost). Measuring python->subprocess->python3
  # instead would wrongly report ~15ms and under-budget the tests. Min (not
  # mean) isolates pure launch cost from scheduler contention.
  if [ -z "$_PY_BASELINE_MS" ]; then
    local i=0 t0 t1 dur best=1000000
    while [ $i -lt 3 ]; do
      t0=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
      python3 -c 'pass'
      t1=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
      dur=$((t1 - t0))
      [ "$dur" -lt "$best" ] && best=$dur
      i=$((i+1))
    done
    _PY_BASELINE_MS=$best
  fi
  printf '%s' "$_PY_BASELINE_MS"
}
# Gate a perf test: SKIP (exit 75) when python3 launches slowly (e.g. a pyenv
# shim ~250-300ms). Under such a launcher a faithful heavy / ×100 perf run
# exceeds the 15s per-test bound and the sub-second budgets would just measure
# the launcher, not the plugin — so perf must be validated on a representative
# machine. RELEASE=1 turns this SKIP into a FAIL. On a fast launcher (<=80ms)
# the test proceeds and runs well under 15s.
perf_gate() {  # perf_gate <test-name>
  local base; base=$(py_baseline_ms)
  if [ "$base" -gt 80 ]; then
    echo "SKIP $1: python3 launches at ~${base}ms (slow launcher, e.g. a pyenv shim)."
    echo "  A faithful heavy / ×100 perf run would exceed the 15s per-test bound, and the"
    echo "  sub-second budgets would measure the interpreter launcher, not the plugin."
    echo "  Validate perf on a machine with a fast python3 (RELEASE=1 promotes this SKIP to FAIL)."
    exit 75
  fi
}
assert_hook_budget() {  # assert_hook_budget <label> <python_spawns> <budget_ms> -- cmd...
  local label="$1" spawns="$2" budget="$3"; shift 3; [ "${1:-}" = "--" ] && shift
  local base cap t0 t1 dur
  base=$(py_baseline_ms)
  cap=$(( spawns * base + budget ))
  t0=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
  "$@"
  t1=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
  dur=$((t1 - t0))
  echo "  [$label] ${dur}ms  (budget ${spawns}×${base} + ${budget} = ${cap}ms)"
  [ "$dur" -le "$cap" ] || fail "$label: ${dur}ms > ${cap}ms (marginal work over ${spawns} python launches exceeds ${budget}ms)"
}

# Digest line tokens (design §9.4), reused across Task 9 tests.
TOK_REDGREEN='red → green'
TOK_GREENRED='green → red'
TOK_NONET='— no net change'
TOK_NEVEREDITED='— never edited'
