#!/bin/bash
# tests/integration/60-awake.sh — plan Task 11 / strategy §11: v0.2 stay-awake.
# W-01 acquire via adrafinil · W-02 caffeinate fallback (-w scoping + release)
# W-03 idempotent acquire · W-04 release without acquire · W-05 stale-lock guard.
#
# Fake shims (PATH-substituted per TP-8):
#   adrafinil  — logs "adrafinil <argv>" to $T/shim.log, exit 0.
#   caffeinate — logs "caffeinate <argv>", emulates `-w <pid>` (a watcher kills
#                the holder when the watched pid dies), execs `tail -f /dev/null
#                <marker>` so ps -o comm= reports `tail` (matching awake-release's
#                recycled-PID comm guard) and the sandbox $T marker rides in argv
#                for pkill/pgrep. Real caffeinate is a binary (comm=caffeinate);
#                a shell script would report comm=/bin/sh, so the shim execs into
#                a real `tail` to present a matching comm.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox

ACQ="$PLUGIN_ROOT/scripts/awake-acquire.sh"
REL="$PLUGIN_ROOT/scripts/awake-release.sh"

assert_pid_num() { case "$1" in ''|*[!0-9]*) fail "not a pid: [$1]";; esac; }
wait_gone() {  # wait_gone <pid> — poll ≤8 s for pid to die; rc 0 when gone
  local n=0
  while kill -0 "$1" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done
  ! kill -0 "$1" 2>/dev/null
}
wait_file() {  # wait_file <path> — poll ≤8 s for a non-empty file
  local n=0
  while [ ! -s "$1" ] && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done
  [ -s "$1" ]
}
wait_grep() {  # wait_grep <ere> <file> — poll ≤8 s for a match (detached shim log)
  local n=0
  while ! grep -Eq "$1" "$2" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done
  grep -Eq "$1" "$2" 2>/dev/null || fail "no match /$1/ in $2 after 8 s"
}
mk_live() {  # mk_live <tag> -> pid of a long-lived process carrying the $T marker
  # (self-terminating loop: no long-lived orphan when the parent is killed).
  sh -c 'i=0; while [ $i -lt 6000 ]; do i=$((i+1)); sleep 0.1; done' "MARK-$T-$1" \
    >/dev/null 2>&1 &
  echo $!
}
write_adrafinil_shim() {
  cat > "$T/bin/adrafinil" <<'SHIM'
#!/bin/sh
printf 'adrafinil %s\n' "$*" >> "@@T@@/shim.log"
exit 0
SHIM
  sed -i.bak "s#@@T@@#$T#g" "$T/bin/adrafinil" && rm -f "$T/bin/adrafinil.bak"
  chmod +x "$T/bin/adrafinil"
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
count_holders() { pgrep -f "$T/caffeinate-marker" 2>/dev/null | grep -c . ; }
comm_of() { ps -p "$1" -o comm= 2>/dev/null; }
settle_comm_tail() {  # wait for the exec into tail to complete (comm != /bin/sh)
  local n=0
  while [ "$(comm_of "$1")" = "/bin/sh" ] && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n+1)); done
}

# --- existence gate (TDD red before the scripts land) ------------------------
assert_file_exists "$ACQ"
assert_file_exists "$REL"
[ -x "$ACQ" ] || fail "awake-acquire.sh not executable"
[ -x "$REL" ] || fail "awake-release.sh not executable"

# ===========================================================================
# W-01 — acquire via adrafinil (mode auto prefers adrafinil; no caffeinate)
# ===========================================================================
write_adrafinil_shim
: > "$T/shim.log"
sid=w1
"$ACQ" "$sid"; assert_exit0 $?
assert_file_exists "$T/data/awake/$sid.lock"
assert_grep "acquire supervisor-$sid --tool claude-code" "$T/shim.log"
assert_jq '.mode=="adrafinil"' "$T/data/awake/$sid.lock"
assert_jq '.v==1' "$T/data/awake/$sid.lock"
if pgrep -f "$T/caffeinate-marker" >/dev/null 2>&1; then fail "caffeinate spawned on the adrafinil path"; fi
echo "ok W-01: adrafinil acquire recorded, no caffeinate holder"
# release via adrafinil -> keyed release logged, lock removed
: > "$T/shim.log"
"$REL" "$sid"; assert_exit0 $?
assert_grep "release supervisor-$sid" "$T/shim.log"
[ -e "$T/data/awake/$sid.lock" ] && fail "adrafinil release did not remove the lock"
echo "ok W-01: adrafinil release keyed + lock removed"

# adrafinil must be ABSENT for the caffeinate-fallback cases.
rm -f "$T/bin/adrafinil"
if command -v adrafinil >/dev/null 2>&1; then
  echo "SKIP 60-awake: a real adrafinil is on PATH; caffeinate fallback (W-02/W-03/W-05b) is unverifiable"
  exit 75
fi
write_caffeinate_shim

# ===========================================================================
# W-02 — caffeinate fallback: spawn args, lock fields, release kills a LIVE
#        holder, and `-w` scoping (holder dies when the claude pid dies).
# ===========================================================================
# Part A — release SIGTERMs a live, comm-verified holder.
fcA=$(mk_live fcA); assert_pid_num "$fcA"
export SUPERVISOR_FAKE_CLAUDE_PID="$fcA"
: > "$T/shim.log"
sid=w2a
"$ACQ" "$sid"; assert_exit0 $?
lockA="$T/data/awake/$sid.lock"
assert_file_exists "$lockA"
assert_jq '.mode=="caffeinate"' "$lockA"
assert_jq ".claude_pid==$fcA" "$lockA"
hpA=$(jq -r '.holder_pid' "$lockA"); assert_pid_num "$hpA"
kill -0 "$hpA" 2>/dev/null || fail "caffeinate holder $hpA not alive after acquire"
settle_comm_tail "$hpA"
commA=$(comm_of "$hpA")
case "$commA" in *tail*) : ;; *) fail "holder comm not tail (release guard would miss it): [$commA]";; esac
# The holder has exec'd past the shim's opening printf, so the log line is present.
wait_grep "caffeinate -ims -w $fcA" "$T/shim.log"
"$REL" "$sid"; assert_exit0 $?
wait_gone "$hpA" || fail "release did not kill the live caffeinate holder $hpA"
[ -e "$lockA" ] && fail "release did not remove the lock"
echo "ok W-02a: caffeinate -ims -w <pid>; release kills live holder + clears lock"
kill "$fcA" 2>/dev/null

# Part B — `-w` scoping: holder auto-exits when the fake claude pid dies.
fcB=$(mk_live fcB); assert_pid_num "$fcB"
export SUPERVISOR_FAKE_CLAUDE_PID="$fcB"
sid=w2b
"$ACQ" "$sid"; assert_exit0 $?
lockB="$T/data/awake/$sid.lock"
assert_file_exists "$lockB"
hpB=$(jq -r '.holder_pid' "$lockB"); assert_pid_num "$hpB"
kill -0 "$hpB" 2>/dev/null || fail "holder $hpB not alive"
kill "$fcB" 2>/dev/null
wait_gone "$hpB" || fail "holder $hpB did not exit when the claude pid died (-w scoping)"
"$REL" "$sid"; assert_exit0 $?
[ -e "$lockB" ] && fail "release did not clean the now-stale lock"
echo "ok W-02b: -w scoping (holder dies with claude); release clears the stale lock"

# ===========================================================================
# W-03 — idempotent acquire: a second acquire is a no-op (lock exists), so
#        exactly one keepalive holder is alive.
# ===========================================================================
fc3=$(mk_live fc3); assert_pid_num "$fc3"
export SUPERVISOR_FAKE_CLAUDE_PID="$fc3"
sid=w3
"$ACQ" "$sid"; assert_exit0 $?
"$ACQ" "$sid"; assert_exit0 $?
sleep 0.4
cnt=$(count_holders)
assert_eq 1 "$cnt"
echo "ok W-03: idempotent acquire -> exactly one keepalive holder"
"$REL" "$sid"
kill "$fc3" 2>/dev/null
wait_gone "$(jq -r '.holder_pid' "$T/data/awake/$sid.lock" 2>/dev/null || echo 1)" 2>/dev/null || true

# ===========================================================================
# W-04 — release without a prior acquire: clean no-op (exit 0, no stderr, kills
#        nothing).
# ===========================================================================
decoy=$(mk_live decoy4); assert_pid_num "$decoy"
errf="$T/w04.err"
"$REL" no-such-session 2>"$errf"; rc=$?
assert_exit0 $rc
[ -s "$errf" ] && fail "release without acquire wrote stderr: [$(cat "$errf")]"
kill -0 "$decoy" 2>/dev/null || fail "release without acquire killed an unrelated process"
echo "ok W-04: release without acquire is a clean, silent no-op"
kill "$decoy" 2>/dev/null

# ===========================================================================
# W-05 — stale-lock handling in awake-release (§13.2/§13.3 recycled-PID guard).
#   (a) lock -> reaped pid: exit 0, lock removed, nothing killed.
#   (b) lock -> live UNRELATED pid (recycled): comm guard spares it; lock removed.
# ===========================================================================
mkdir -p "$T/data/awake"
# (a) reaped pid
sh -c 'exit 0' & deadpid=$!; wait "$deadpid" 2>/dev/null
lock5a="$T/data/awake/w5a.lock"
printf '{"v":1,"mode":"caffeinate","holder_pid":%s,"claude_pid":999999,"ts":%s}\n' \
  "$deadpid" "$SUPERVISOR_NOW" > "$lock5a"
"$REL" w5a; assert_exit0 $?
[ -e "$lock5a" ] && fail "release did not remove a stale (reaped-pid) lock"
echo "ok W-05a: stale lock (reaped pid) cleaned, exit 0"
# (b) recycled live unrelated pid — comm guard must spare it
unrel=$(mk_live w5b); assert_pid_num "$unrel"
lock5b="$T/data/awake/w5b.lock"
printf '{"v":1,"mode":"caffeinate","holder_pid":%s,"claude_pid":999999,"ts":%s}\n' \
  "$unrel" "$SUPERVISOR_NOW" > "$lock5b"
"$REL" w5b; assert_exit0 $?
kill -0 "$unrel" 2>/dev/null || fail "release killed an unrelated recycled-pid process (comm guard failed)"
[ -e "$lock5b" ] && fail "release did not remove the recycled-pid lock"
echo "ok W-05b: recycled-pid comm guard spares the unrelated process; lock cleaned"
kill "$unrel" 2>/dev/null

echo "60-awake: all sections passed"
exit 0
