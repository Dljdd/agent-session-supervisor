#!/bin/bash
# 36-determinism.sh — A-07. The digest is a pure function of (events, clock).
# Building it twice from the same store — once under perturbed
# TZ/LC_ALL/PYTHONHASHSEED — is byte-identical. Advancing the clock 3 days
# changes ONLY the relative-time header line.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off
hc() { run_hook hook-capture.sh; }

# a closed run with a spread of signal kinds.
export SUPERVISOR_NOW=1753689600
payload sessionstart-startup session_id=s1 | run_hook hook-session-start.sh >/dev/null
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/foo.ts" | hc
payload posttooluse-edit session_id=s1 tool_input.file_path="$T/proj/foo.ts" | hc
payload posttoolusefailure-bash session_id=s1 tool_input.command="npm test" | hc
export SUPERVISOR_NOW=1753689700
payload posttooluse-bash-pass   session_id=s1 tool_input.command="npm test" | hc
export SUPERVISOR_NOW=1753689800
payload stop             session_id=s1 | run_hook hook-stop.sh
payload sessionend-other session_id=s1 | run_hook hook-session-end.sh

DG="$PLUGIN_ROOT/scripts/py/digest.py"
prt() { TZ="$1" LC_ALL="$2" PYTHONHASHSEED="$3" SUPERVISOR_NOW="$4" \
        python3 "$DG" print --cwd "$T/proj" 2>/dev/null; }

d1=$(prt UTC             C            0 1753776000)
d2=$(prt Australia/Eucla en_US.UTF-8  1 1753776000)
[ -n "$d1" ] || fail "empty digest"
[ "$d1" = "$d2" ] || fail "digest not deterministic under perturbed TZ/LC/HASHSEED:
$(diff <(printf '%s\n' "$d1") <(printf '%s\n' "$d2"))"

d3=$(prt UTC C 0 $((1753776000 + 259200)))       # +3 days
diffs=$(diff <(printf '%s\n' "$d1") <(printf '%s\n' "$d3") | grep -E '^[<>]')
[ -n "$diffs" ] || fail "3-day clock shift changed nothing (header not time-relative)"
# every changed line is the relative-time header
if printf '%s\n' "$diffs" | grep -Ev '^[<>] .*Last session' | grep -q .; then
  fail "3-day shift changed more than the header line:
$diffs"
fi

echo "A-07 ok: byte-identical under perturbation; only the time header moves with the clock"
