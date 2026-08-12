#!/bin/bash
# tests/integration/31-concurrent-capture.sh — A-02 (design §8.3, CT-10).
#
# Spawn WRITERS simultaneous hook-capture.sh writers, each piping PAYLOADS
# distinct Bash-pass payloads (WRITERS*PAYLOADS events, each a distinct marker),
# released together via a pre-created "go" gate. Interleave --start/--stop/--end
# boundary invocations so snapshot-bearing events are in the mix (critic
# SEC-13). Assert: every marker appears exactly once (no loss, no merge), every
# line is jq-valid, and the max line BYTE length is <= 4096 for EVERY event kind.
#
# Defaults are the strategy's 50 x 20; the "10 consecutive runs" gate is the
# RUNNER's repetition (strategy §7) — A02_ROUNDS scales internal rounds, and
# A02_WRITERS/A02_PAYLOADS scale width for a fast smoke run.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

WRITERS=${A02_WRITERS:-50}
PAYLOADS=${A02_PAYLOADS:-20}
ROUNDS=${A02_ROUNDS:-1}
MAX_BYTES=4096   # CT-10 (mirror of scripts/py/supervisor_common.MAX_EVENT_BYTES)

t_sandbox
# A git repo with dirty + untracked files so boundary snapshots carry hash lists.
mk_proj_git
echo change >> "$T/proj/base.txt"
i=0; while [ $i -lt 5 ]; do echo u > "$T/proj/untracked_$i.txt"; i=$((i+1)); done

events_file() { ls "$CLAUDE_PLUGIN_DATA"/projects/*/events.jsonl 2>/dev/null | head -n 1; }

round() {
  local rd="$1"
  # Pre-generate all payloads with ONE python process (jq/python per hook in the
  # timed section would dominate; the concurrency we exercise is the APPEND).
  rm -rf "$T/pl"; mkdir -p "$T/pl"
  python3 - "$T/pl" "$CLAUDE_PROJECT_DIR" "$WRITERS" "$PAYLOADS" "$rd" <<'PY'
import json, os, sys
pldir, proj, W, P, rd = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
for w in range(W):
    for p in range(P):
        d = {"session_id": "sess-0001", "cwd": proj, "hook_event_name": "PostToolUse",
             "tool_name": "Bash", "tool_input": {"command": "MARK_r%s_w%03d_p%03d" % (rd, w, p)},
             "duration_ms": 10}
        open(os.path.join(pldir, "w%03d_p%03d.json" % (w, p)), "w").write(json.dumps(d))
PY
  # Boundary payloads (cwd rewritten by the harness payload() helper).
  payload sessionstart-startup > "$T/pl/_start.json"
  payload stop                 > "$T/pl/_stop.json"
  payload sessionend-other     > "$T/pl/_end.json"

  # Barrier: every worker blocks on the go-gate so they truly overlap.
  rm -f "$T/go"
  local w
  w=0
  while [ $w -lt "$WRITERS" ]; do
    (
      while [ ! -f "$T/go" ]; do :; done
      p=0
      while [ $p -lt "$PAYLOADS" ]; do
        "$PLUGIN_ROOT/scripts/hook-capture.sh" < "$T/pl/w$(printf %03d $w)_p$(printf %03d $p).json"
        p=$((p+1))
      done
    ) &
    w=$((w+1))
  done
  # Interleave the three snapshot-bearing boundary events.
  ( while [ ! -f "$T/go" ]; do :; done; "$PLUGIN_ROOT/scripts/hook-capture.sh" --start < "$T/pl/_start.json" ) &
  ( while [ ! -f "$T/go" ]; do :; done; "$PLUGIN_ROOT/scripts/hook-capture.sh" --stop  < "$T/pl/_stop.json" )  &
  ( while [ ! -f "$T/go" ]; do :; done; "$PLUGIN_ROOT/scripts/hook-capture.sh" --end   < "$T/pl/_end.json" )   &
  : > "$T/go"   # release
  wait
}

r=1
while [ $r -le "$ROUNDS" ]; do
  round "$r"
  r=$((r+1))
done

EV=$(events_file)
[ -n "$EV" ] || fail "no events.jsonl produced"

# Every non-empty line must be valid JSON (no torn/merged lines).
assert_json_lines "$EV"

# Every marker present exactly once — no loss, no merge.
want=$((WRITERS * PAYLOADS * ROUNDS))
got=$(grep -c 'MARK_' "$EV")
[ "$got" -eq "$want" ] || fail "marker line count: got $got want $want"
uniq=$(jq -r 'select(.c != null) | .c' "$EV" | grep '^MARK_' | LC_ALL=C sort | uniq | wc -l | tr -d ' ')
[ "$uniq" -eq "$want" ] || fail "distinct markers: got $uniq want $want (loss or merge)"

# Snapshot-bearing boundary events present (critic SEC-13).
for k in start stop end; do
  c=$(jq -c "select(.k==\"$k\")" "$EV" | wc -l | tr -d ' ')
  [ "$c" -ge "$ROUNDS" ] || fail "missing boundary event k=$k (got $c, want >=$ROUNDS)"
done
# At least one start carried a git snapshot (byte budget must still hold).
snaps=$(jq -c 'select(.k=="start" and .git != null)' "$EV" | wc -l | tr -d ' ')
[ "$snaps" -ge 1 ] || fail "no snapshot-bearing start event in the mix"

# CT-10: max line byte length <= 4096 for EVERY line (measured with LC_ALL=C).
maxb=$(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' "$EV")
[ "$maxb" -le "$MAX_BYTES" ] || fail "max line $maxb bytes > $MAX_BYTES (CT-10)"

echo "A-02 ok: $got markers, $uniq unique, $snaps snapshot start(s), max ${maxb}B <= ${MAX_BYTES}"
