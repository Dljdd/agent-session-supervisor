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
