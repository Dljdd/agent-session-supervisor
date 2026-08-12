#!/bin/bash
# tests/integration/62-awake-detach.sh — plan Task 11 / strategy §11 W-07
# (design §18.15b — critics SF-08 / TF-2).
#
# The keepalive must survive a SIGTERM of the acquiring hook's ENTIRE process
# group (a plain `&` child shares the hook's pgid — verified by the critics'
# live probe — so a hook-timeout or terminal group signal could reap it minutes
# into the overnight run the feature exists for). awake-acquire launches the
# holder through `sup_detach` (setsid double-fork), removing it from both the
# hook's and the terminal's process group. This test runs acquire inside a
# wrapper that itself owns a process group, TERMs that whole group, and asserts:
#   1. the caffeinate keepalive SURVIVES (detach worked), and
#   2. it still dies when the fake claude pid is killed (`-w` scoping intact).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox

ACQ="$PLUGIN_ROOT/scripts/awake-acquire.sh"
assert_file_exists "$ACQ"

assert_pid_num() { case "$1" in ''|*[!0-9]*) fail "not a pid: [$1]";; esac; }
wait_gone() { local n=0; while kill -0 "$1" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done; ! kill -0 "$1" 2>/dev/null; }
wait_file() { local n=0; while [ ! -s "$1" ] && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done; [ -s "$1" ]; }
mk_live() {
  sh -c 'i=0; while [ $i -lt 6000 ]; do i=$((i+1)); sleep 0.1; done' "MARK-$T-$1" >/dev/null 2>&1 &
  echo $!
}
write_caffeinate_shim() {
  cat > "$T/bin/caffeinate" <<'SHIM'
#!/bin/sh
printf 'caffeinate %s\n' "$*" >> "@@T@@/shim.log"
: > "@@T@@/caffeinate-marker" 2>/dev/null
WPID=
p=
for a in "$@"; do
  [ "$p" = "-w" ] && WPID=$a
  p=$a
done
HOLDER=$$
( i=0
  while [ "$i" -lt 6000 ]; do
    kill -0 "$HOLDER" 2>/dev/null || exit 0
    if [ -n "$WPID" ] && ! kill -0 "$WPID" 2>/dev/null; then
      kill -TERM "$HOLDER" 2>/dev/null; exit 0
    fi
    sleep 0.1
    i=$((i + 1))
  done ) >/dev/null 2>&1 &
exec tail -f /dev/null "@@T@@/caffeinate-marker"
SHIM
  sed -i.bak "s#@@T@@#$T#g" "$T/bin/caffeinate" && rm -f "$T/bin/caffeinate.bak"
  chmod +x "$T/bin/caffeinate"
}

rm -f "$T/bin/adrafinil"
if command -v adrafinil >/dev/null 2>&1; then
  echo "SKIP 62-awake-detach: a real adrafinil is on PATH; caffeinate detach is unverifiable"
  exit 75
fi
write_caffeinate_shim

# A live fake claude, in the TEST's process group (so it survives the wrapper's
# group TERM and can be killed afterward to prove `-w` scoping).
fc=$(mk_live fc7); assert_pid_num "$fc"
export SUPERVISOR_FAKE_CLAUDE_PID="$fc"
sid=w7

# Wrapper: acquires (detaching the holder into its own session), then stays
# alive in its own group so we can TERM the whole group. sup_detach runs it
# with setsid, so the wrapper is its own group leader (TERMing its group cannot
# reap the test suite).
W="$T/w07.sh"
cat > "$W" <<EOF
#!/bin/sh
"$ACQ" "$sid"
printf '%s\n' "\$\$" > "$T/w07_pid"
i=0; while [ \$i -lt 300 ]; do sleep 0.1; i=\$((i+1)); done
EOF
chmod +x "$W"

. "$PLUGIN_ROOT/scripts/lib/detach.sh"
wpid=$(sup_detach "$W"); assert_pid_num "$wpid"
wait_file "$T/w07_pid" || fail "wrapper never reported its pid"
lock="$T/data/awake/$sid.lock"
wait_file "$lock" || fail "acquire never wrote the wake lock"
hp=$(jq -r '.holder_pid' "$lock"); assert_pid_num "$hp"
kill -0 "$hp" 2>/dev/null || fail "caffeinate holder $hp not alive after acquire"

# The wrapper must own a process group distinct from the test's (setsid), and
# the holder must be outside the wrapper's group (detached into its own session).
pg=$(ps -p "$wpid" -o pgid= 2>/dev/null | tr -d ' '); assert_pid_num "$pg"
mypg=$(ps -p $$ -o pgid= 2>/dev/null | tr -d ' ')
[ "$pg" != "$mypg" ] || fail "wrapper shares the test's group; group TERM would kill the suite"
hpg=$(ps -p "$hp" -o pgid= 2>/dev/null | tr -d ' '); assert_pid_num "$hpg"
[ "$hpg" != "$pg" ] || fail "detach failed: holder shares the wrapper's process group"

# TERM the wrapper's ENTIRE process group.
kill -s TERM -- "-$pg" 2>/dev/null || fail "could not TERM wrapper process group $pg"
wait_gone "$wpid" || fail "wrapper survived TERM of its own group"

# (1) the detached keepalive SURVIVES the group TERM.
sleep 0.3
kill -0 "$hp" 2>/dev/null || fail "detached caffeinate holder did NOT survive the wrapper-group TERM (SF-08/TF-2)"
echo "ok W-07: keepalive survives wrapper-group TERM (setsid detach removed it from the group)"

# (2) `-w` scoping still intact: killing the fake claude pid brings it down.
kill "$fc" 2>/dev/null
wait_gone "$hp" || fail "holder did not die when the fake claude pid was killed (-w scoping lost after detach)"
echo "ok W-07: -w scoping intact after detach (holder dies with the claude pid)"

echo "62-awake-detach: detach survival + -w scoping verified"
exit 0
