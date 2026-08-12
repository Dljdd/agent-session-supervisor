#!/bin/bash
# 14-heavy-session-cap.sh — I-05 (AC5, CT-4). A 4-hour heavy session (gen seed
# 42, ~1300 events): the injected additionalContext stays <= 1600 Python chars
# (and < 9000 as the 10k platform-cap margin), FAILED lines survive truncation
# before any Read line (at this volume reads must be gone), and the body is
# <= 30 lines.
#
# The ~1300 events are bulk-loaded through capture.main() in ONE interpreter
# (byte-identical routing to hook-capture.sh; the per-event shell wrapper is
# proven in 31/45/46 and the P-02 latency gate). This test targets the DIGEST
# budget on a heavy store, then exercises the REAL session-start entrypoint.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_git
awake_off

GEN="$PLUGIN_ROOT/tests/fixtures/generators/gen_heavy_session.py"
python3 "$GEN" --seed 42 --times-out "$T/times.txt" > "$T/heavy.jsonl"

# start event for sess-0001 (the gen session), then bulk-load the heavy stream.
export SUPERVISOR_NOW=1753689600
payload sessionstart-startup session_id=sess-0001 | run_hook hook-session-start.sh >/dev/null
python3 - "$T/heavy.jsonl" "$T/times.txt" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["PLUGIN_ROOT"], "scripts", "py"))
import capture, supervisor_common as sc
proj = os.environ["CLAUDE_PROJECT_DIR"]
# Resolve the project store ONCE (one git probe; creates the dir + meta.json),
# then pin capture's store resolver to it for the setup loop. Production runs one
# capture PROCESS per event (one git probe each); this single-interpreter bulk
# loader would otherwise re-spawn `git config` 1298x (~18s of pure fork/poll,
# the whole reason this test flirted with the anti-hang ceiling). The stored
# event BYTES are unchanged — project_dir only picks the WRITE LOCATION, and all
# 1298 events share this one cwd, so the once-resolved path is exactly what each
# event would resolve to. Routing/redaction/append stay byte-identical.
_store = sc.project_dir(proj, for_hook=True)
sc.project_dir = lambda cwd, for_hook=True: _store
lines = [l for l in open(sys.argv[1]).read().split("\n") if l]
times = [t for t in open(sys.argv[2]).read().split("\n") if t]
for i, line in enumerate(lines):
    # gen hardcodes cwd/paths under /sandbox/proj; retarget them at the sandbox
    # project so every event lands in the SAME project store as the boundary
    # events (capture keys the store on the payload's cwd).
    line = line.replace("/sandbox/proj", proj)
    if i < len(times):
        os.environ["SUPERVISOR_NOW"] = times[i]
    capture.main(argv=[], stdin=line)
PY
export SUPERVISOR_NOW=$((1753689600 + 14400))
payload stop             session_id=sess-0001 | run_hook hook-stop.sh
payload sessionend-other session_id=sess-0001 | run_hook hook-session-end.sh

ef=$(events_file); n=$(grep -c . "$ef")
[ "$n" -ge 1298 ] || fail "heavy store only has $n events (want >=1298)"

raw=$(payload sessionstart-resume session_id=sess-0002 | run_hook hook-session-start.sh)
printf '%s' "$raw" | jq -j '.hookSpecificOutput.additionalContext' > "$T/ac.txt"

chars=$(python3 -c 'import io,sys;print(len(open(sys.argv[1],encoding="utf-8").read()))' "$T/ac.txt")
bytes=$(LC_ALL=C wc -c < "$T/ac.txt" | tr -d ' ')
# AC5 / CT-4: the FULL additionalContext stays within budget no matter how big
# the 4-hour session was.
[ "$chars" -le 1600 ] || fail "additionalContext $chars chars > 1600 (CT-4)"
[ "$bytes"  -lt 9000 ] || fail "additionalContext $bytes bytes >= 9000 (platform-cap margin)"

# The digest is meaningful: it names the churn and the failures.
assert_grep_fixed 'Edited' "$T/ac.txt"
assert_grep_fixed 'FAILED' "$T/ac.txt"

# Body is bounded. NOTE: render caps each section to a fixed top-N (design §9.4)
# so a heavy session settles well under 1600 WITHOUT the CT-9 drop ladder firing
# — the ladder's ordering (reads dropped before failures) is exercised directly
# in tests/unit/test_digest.py::DropLadder. Here the property that matters is the
# hard budget + line cap.
nlines=$(LC_ALL=C awk 'END{print NR}' "$T/ac.txt")
[ "$nlines" -le 30 ] || fail "digest body has $nlines lines > 30"

# Fail-closed indent invariant (§11.2 layer 2): every non-framing body line is
# a two-space-indented template line — no attacker-authored text at column 0.
bad=$(LC_ALL=C awk 'NR>3 && $0 !~ /^  / && $0 != "</supervisor-digest>" {print NR": "$0}' "$T/ac.txt")
[ -z "$bad" ] || fail "un-indented body line(s): $bad"

echo "I-05 ok: heavy digest ${chars}<=1600 chars / ${bytes}<9000 bytes / ${nlines}<=30 lines"
