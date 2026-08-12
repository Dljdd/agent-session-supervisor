#!/bin/bash
# tests/run.sh [substring] — phases: lint, unit, integration. RELEASE=1 turns SKIP into FAIL.
set -u -o pipefail
PLUGIN_ROOT=$(cd "$(dirname "$0")/.." && pwd); export PLUGIN_ROOT
export TZ=UTC LC_ALL=C PYTHONHASHSEED=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; failn=0; skip=0
# Per-integration-test wall-clock budget (seconds). A test must never be able to
# hang the suite (a real setsid-detached sleeper once froze the build for 45min).
INTEG_TIMEOUT=${INTEG_TIMEOUT:-30}
run_one() {
  local t="$1" name; name=$(basename "$t" .sh)
  local errf; errf=$(mktemp); bash "$t" >"$errf" 2>&1; local rc=$?
  if [ $rc -eq 0 ]; then echo "ok $name"; pass=$((pass+1))
  elif [ $rc -eq 75 ] && [ "${RELEASE:-}" != "1" ]; then echo "skip $name"; skip=$((skip+1))
  else echo "FAIL $name"; sed 's/^/    /' "$errf"; failn=$((failn+1)); fi
  rm -f "$errf"
}
# run_one under a pure-sh bounded watchdog (macOS bash 3.2 has no timeout(1) and
# no setsid). The test runs as a background job in monitor mode, so it becomes
# its own process-group leader (PGID == job PID); we poll for liveness up to
# INTEG_TIMEOUT, and on expiry TERM-then-KILL the WHOLE group (negative PID) so
# any process the test spawned in-group dies with it, and record FAIL-TIMEOUT.
# The verdict protocol (ok / skip / RELEASE=1 skip->FAIL / FAIL) is identical to
# run_one; a timeout is a suite failure. Stderr of the watchdog block is dropped
# only to swallow bash's async job-control notices ("Terminated: 15 ...").
run_one_timed() {
  local t="$1" name; name=$(basename "$t" .sh)
  local errf; errf=$(mktemp); local tpid rc i
  local polls=$((INTEG_TIMEOUT * 10)) timedout=0
  {
    set -m
    bash "$t" >"$errf" 2>&1 &
    tpid=$!
    set +m
    i=0
    while [ $i -lt "$polls" ]; do
      kill -0 "$tpid" 2>/dev/null || break
      sleep 0.1; i=$((i+1))
    done
    if kill -0 "$tpid" 2>/dev/null; then
      timedout=1
      kill -TERM -"$tpid" 2>/dev/null; sleep 0.5; kill -KILL -"$tpid" 2>/dev/null
      wait "$tpid" 2>/dev/null; rc=124
    else
      wait "$tpid"; rc=$?
    fi
  } 2>/dev/null
  if [ "$timedout" -eq 1 ]; then
    echo "FAIL $name (FAIL-TIMEOUT: exceeded ${INTEG_TIMEOUT}s)"; sed 's/^/    /' "$errf"; failn=$((failn+1))
  elif [ $rc -eq 0 ]; then echo "ok $name"; pass=$((pass+1))
  elif [ $rc -eq 75 ] && [ "${RELEASE:-}" != "1" ]; then echo "skip $name"; skip=$((skip+1))
  else echo "FAIL $name"; sed 's/^/    /' "$errf"; failn=$((failn+1)); fi
  rm -f "$errf"
}
# Phase 1: static/lint gates.
for t in "$PLUGIN_ROOT"/tests/integration/0*-lint*.sh; do
  [ -f "$t" ] || continue
  case "$t" in *"${1:-}"*) run_one "$t";; esac
done
# Phase 2: unit tests.
if [ -z "${1:-}" ] || ls "$PLUGIN_ROOT"/tests/unit/*"${1:-}"* >/dev/null 2>&1; then
  python3 -m unittest discover -s "$PLUGIN_ROOT/tests/unit" -v || failn=$((failn+1))
fi
# Phase 3: every remaining integration test in filename order, skipping the
# phase-1 lint files. (Gate fix: a [1-9]*.sh glob would silently never run
# 01-libs.sh or 05-supervisorctl.sh.)
for t in "$PLUGIN_ROOT"/tests/integration/*.sh; do
  [ -f "$t" ] || continue
  case "$(basename "$t")" in 0*-lint*) continue;; esac
  case "$t" in *"${1:-}"*) run_one_timed "$t";; esac
done
echo "$pass passed, $failn failed, $skip skipped"
[ $failn -eq 0 ]
