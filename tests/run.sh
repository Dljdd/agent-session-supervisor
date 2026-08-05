#!/bin/bash
# tests/run.sh [substring] — phases: lint, unit, integration. RELEASE=1 turns SKIP into FAIL.
set -u -o pipefail
PLUGIN_ROOT=$(cd "$(dirname "$0")/.." && pwd); export PLUGIN_ROOT
export TZ=UTC LC_ALL=C PYTHONHASHSEED=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; failn=0; skip=0
run_one() {
  local t="$1" name; name=$(basename "$t" .sh)
  local errf; errf=$(mktemp); bash "$t" >"$errf" 2>&1; local rc=$?
  if [ $rc -eq 0 ]; then echo "ok $name"; pass=$((pass+1))
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
  case "$t" in *"${1:-}"*) run_one "$t";; esac
done
echo "$pass passed, $failn failed, $skip skipped"
[ $failn -eq 0 ]
