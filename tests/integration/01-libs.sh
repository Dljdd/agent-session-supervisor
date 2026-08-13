#!/bin/bash
# tests/integration/01-libs.sh — plan Task 3: unit tests for the shell libs
# scripts/lib/guard.sh (U1), findpid.sh (U2), detach.sh (U3).
#
# Sections (plan Task 3 step 1):
#   (a) guard trap forces subshell exit 0 after an induced failure
#   (b) SUPERVISOR_DISABLE=1 hook-capture.sh exits 0 instantly
#   (c) sup_data_dir resolution per CT-12 + design §4.1 containment
#       (containment cases added per gate advisory: A-20 phase 2)
#   (d) findpid: fake-claude wrapper discovery; orphaned negative probe
#   (e) detach: new session id; survives TERM of the caller's process group
#
# Platform notes (verified on Darwin 24):
#   - `ps -o sess=` prints 0 for every process on macOS, so the sess-differs
#     assert falls back to os.getsid() ground truth when ps is degenerate.
#   - The suite itself runs under Claude Code, so a naive negative findpid
#     probe WOULD find a real claude ancestor; the probe is therefore
#     detached (orphaned to ppid 1) before it walks.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox

LIB="$PLUGIN_ROOT/scripts/lib"

assert_pid_num() { case "$1" in ''|*[!0-9]*) fail "not a pid: [$1]";; esac; }
wait_for_file()  { # wait_for_file <path> — poll up to 8 s for a non-empty file
  local f="$1" n=0
  while [ "$n" -lt 80 ]; do [ -s "$f" ] && return 0; sleep 0.1; n=$((n+1)); done
  return 1
}

# --- existence gate (the TDD red before Task 3 step 2) -----------------------
assert_file_exists "$LIB/guard.sh"
assert_file_exists "$LIB/findpid.sh"
assert_file_exists "$LIB/detach.sh"

# ---------------------------------------------------------------------------
# (a) guard.sh: trap 'exit 0' EXIT armor
# ---------------------------------------------------------------------------
env LIB="$LIB" sh -c '. "$LIB/guard.sh"; false'
assert_exit0 $?
echo "ok: guard forces exit 0 after false"

env LIB="$LIB" sh -c '. "$LIB/guard.sh"; exit 7'
assert_exit0 $?
echo "ok: guard forces exit 0 over explicit exit 7"

out=$(env LIB="$LIB" sh -c '. "$LIB/guard.sh"; umask')
case "$out" in *77) : ;; *) fail "guard umask not 077: [$out]";; esac
echo "ok: guard sets umask 077"

out=$(env LIB="$LIB" SUPERVISOR_NOW=123456 sh -c '. "$LIB/guard.sh"; sup_now')
assert_eq "123456" "$out"
echo "ok: sup_now honors SUPERVISOR_NOW"

# sup_cfg falls back to the default while supervisor_common.py is absent/broken
out=$(env LIB="$LIB" SUP_ROOT="$PLUGIN_ROOT" sh -c '. "$LIB/guard.sh"; sup_cfg some_key defval')
assert_eq "defval" "$out"
echo "ok: sup_cfg prints the default when the python side is unavailable"

# ---------------------------------------------------------------------------
# (b) SUPERVISOR_DISABLE short-circuit on the capture entrypoint
# ---------------------------------------------------------------------------
assert_duration_under_ms 1000 -- env SUPERVISOR_DISABLE=1 "$PLUGIN_ROOT/scripts/hook-capture.sh" </dev/null
echo "ok: SUPERVISOR_DISABLE=1 hook-capture.sh exits 0 instantly"

# ---------------------------------------------------------------------------
# (c) sup_data_dir — CT-12 precedence + §4.1 containment (gate advisory)
# ---------------------------------------------------------------------------
probe_dd() { # probe_dd [env(1) args: -u NAME / NAME=VALUE ...] -> OK:<dir> | RC1
  env "$@" LIB="$LIB" sh -c \
    '. "$LIB/guard.sh"; if d=$(sup_data_dir); then printf "OK:%s\n" "$d"; else printf "RC1\n"; fi'
}

out=$(probe_dd -u SUPERVISOR_DATA_DIR -u SUPERVISOR_TEST_MODE)
assert_eq "OK:$T/data" "$out"
echo "ok: sup_data_dir prints CLAUDE_PLUGIN_DATA (branch 1)"

out=$(probe_dd -u CLAUDE_PLUGIN_DATA -u SUPERVISOR_DATA_DIR -u SUPERVISOR_TEST_MODE)
assert_eq "RC1" "$out"
echo "ok: sup_data_dir returns 1 with neither var (hooks never fall back)"

out=$(probe_dd -u CLAUDE_PLUGIN_DATA -u SUPERVISOR_TEST_MODE)
assert_eq "RC1" "$out"
echo "ok: sup_data_dir ignores SUPERVISOR_DATA_DIR without test mode (CT-12)"

out=$(probe_dd -u CLAUDE_PLUGIN_DATA)
assert_eq "OK:$T/data" "$out"
echo "ok: sup_data_dir honors SUPERVISOR_DATA_DIR under test mode (branch 2)"

# §4.1 containment on branch 2 (gate advisory / A-20 phase 2). Three rejection
# axes: under CLAUDE_PROJECT_DIR, under \$PWD, inside a git worktree.
mk_proj_git

out=$(probe_dd -u CLAUDE_PLUGIN_DATA SUPERVISOR_DATA_DIR="$T/proj/.supervisor")
assert_eq "RC1" "$out"
echo "ok: containment rejects a dir under CLAUDE_PROJECT_DIR"

mkdir -p "$T/plain"
out=$(cd "$T/plain" && env -u CLAUDE_PLUGIN_DATA -u CLAUDE_PROJECT_DIR \
      SUPERVISOR_DATA_DIR="$T/plain/sub" LIB="$LIB" sh -c \
      '. "$LIB/guard.sh"; if d=$(sup_data_dir); then printf "OK:%s\n" "$d"; else printf "RC1\n"; fi')
assert_eq "RC1" "$out"
echo "ok: containment rejects a dir under \$PWD"

out=$(probe_dd -u CLAUDE_PLUGIN_DATA -u CLAUDE_PROJECT_DIR SUPERVISOR_DATA_DIR="$T/proj/.supervisor")
assert_eq "RC1" "$out"
echo "ok: containment rejects a dir inside a git worktree"

[ ! -e "$T/proj/.supervisor" ] || fail "containment probe created a dir inside the project"
echo "ok: nothing was created under the project during refusals"

# ---------------------------------------------------------------------------
# (d) findpid.sh — sup_find_claude_pid
# ---------------------------------------------------------------------------
out=$(env SUPERVISOR_FAKE_CLAUDE_PID=4242 sh -c ". '$LIB/findpid.sh'; sup_find_claude_pid")
assert_eq "4242" "$out"
echo "ok: findpid honors the SUPERVISOR_FAKE_CLAUDE_PID test seam"

# Wrapper discovery: a fake `claude` runs the probe as a child, so the probe's
# parent chain contains ".../bin/claude <args>" and the walk must return the
# wrapper's own pid.
{
  printf '#!/bin/sh\n'
  printf 'echo $$ > "%s/wrapperpid"\n' "$T"
  printf '"$@"\n'
} > "$T/bin/claude"
chmod +x "$T/bin/claude"
found=$(env -u SUPERVISOR_FAKE_CLAUDE_PID LIB="$LIB" "$T/bin/claude" sh -c '. "$LIB/findpid.sh"; sup_find_claude_pid')
wrapper=$(tr -d ' \n' < "$T/wrapperpid")
assert_pid_num "$wrapper"
assert_eq "$wrapper" "$found"
echo "ok: findpid discovers the fake claude wrapper pid ($found)"

# Negative: no claude ancestor -> empty. The probe MUST be orphaned first
# (this suite itself runs under a real claude process), so it is detached and
# walks only after the double-fork intermediary is gone (ppid 1).
. "$LIB/detach.sh"
rm -f "$T/negout"
negpid=$(sup_detach sh -c "sleep 1; . '$LIB/findpid.sh'; r=\$(sup_find_claude_pid); printf 'R:%s' \"\$r\" > '$T/negout'")
assert_pid_num "$negpid"
wait_for_file "$T/negout" || fail "orphaned findpid probe never reported"
neg=$(cat "$T/negout")
assert_eq "R:" "$neg"
echo "ok: findpid prints nothing without a claude ancestor"

# ---------------------------------------------------------------------------
# (e) detach.sh — sup_detach
# ---------------------------------------------------------------------------
# e1: prints a live pid in a NEW session.
d1=$(sup_detach sleep 30)
assert_pid_num "$d1"
kill -0 "$d1" 2>/dev/null || fail "sup_detach pid $d1 is not alive"
s_test=$(ps -p $$ -o sess= 2>/dev/null | tr -d ' ')
s_d=$(ps -p "$d1" -o sess= 2>/dev/null | tr -d ' ')
if [ -n "$s_test" ] && [ -n "$s_d" ] && [ "$s_test" != "$s_d" ]; then
  echo "ok: detached session id differs via ps sess ($s_test vs $s_d)"
else
  # macOS ps reports sess=0 for everything; os.getsid is the ground truth.
  python3 -c 'import os,sys; sys.exit(0 if os.getsid(int(sys.argv[1])) != os.getsid(os.getpid()) else 1)' "$d1" \
    || fail "daemon session id equals caller session id"
  echo "ok: detached session id differs via os.getsid (ps sess= degenerate: [$s_test] vs [$s_d])"
fi
kill -TERM "$d1" 2>/dev/null

# e2: survives SIGTERM of the caller's entire process group. A detached
# wrapper W (own session) detaches the subject daemon and keeps an in-group
# control child; TERMing W's group must kill W + control but not the daemon.
W="$T/w.sh"
cat > "$W" <<EOF
#!/bin/sh
. '$LIB/detach.sh'
d=\$(sup_detach sleep 30)
printf '%s\n' "\$d" > '$T/e2_daemon'
sleep 15 &
printf '%s\n' "\$!" > '$T/e2_ingroup'
printf '%s\n' "\$\$" > '$T/e2_w'
wait
EOF
chmod +x "$W"
wpid=$(sup_detach "$W")
assert_pid_num "$wpid"
wait_for_file "$T/e2_daemon"  || fail "wrapper never wrote the daemon pid"
wait_for_file "$T/e2_ingroup" || fail "wrapper never wrote the control pid"
wait_for_file "$T/e2_w"       || fail "wrapper never wrote its own pid"
d2=$(tr -d ' \n' < "$T/e2_daemon");  assert_pid_num "$d2"
ing=$(tr -d ' \n' < "$T/e2_ingroup"); assert_pid_num "$ing"
wsh=$(tr -d ' \n' < "$T/e2_w");      assert_pid_num "$wsh"
assert_eq "$wpid" "$wsh"   # sup_detach printed the ACTUAL daemonized pid

pg=$(ps -p "$wpid" -o pgid= 2>/dev/null | tr -d ' ')
assert_pid_num "$pg"
mypg=$(ps -p $$ -o pgid= 2>/dev/null | tr -d ' ')
[ "$pg" != "$mypg" ] || fail "wrapper shares the test's process group; group TERM would kill the suite"

kill -s TERM -- "-$pg" 2>/dev/null || fail "could not TERM process group $pg"
n=0
while kill -0 "$wpid" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
kill -0 "$wpid" 2>/dev/null && fail "wrapper survived TERM of its own group"
kill -0 "$ing"  2>/dev/null && fail "in-group control child survived group TERM"
kill -0 "$d2"   2>/dev/null || fail "detached daemon did NOT survive the caller-group TERM"
echo "ok: detached daemon survives caller-group TERM (group $pg killed, daemon $d2 alive)"
kill -TERM "$d2" 2>/dev/null

echo "01-libs: all sections passed"
exit 0
