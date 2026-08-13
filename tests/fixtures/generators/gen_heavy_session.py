#!/usr/bin/env python3
"""gen_heavy_session.py --seed N [--times-out F]

Emits one documented hook stdin payload (JSON) per stdout line, simulating a
4-hour heavy session (test strategy section 4, plan Task 2 step 5):

  - 80 distinct files edited, 1-25 Edit events each
  - 120 distinct commands: 80 pass-only, 40 failing (PostToolUseFailure with a
    190-210 char error string); 6 of the 40 also pass LATER (red->green pairs)
  - 200 Read events across 60 distinct (never-edited) files

Hook payloads carry no timestamp: capture.py stamps time from SUPERVISOR_NOW.
The generator therefore writes one epoch value per payload line to the
--times-out side file (monotonically increasing across the 4 h window); the
consuming test exports SUPERVISOR_NOW from line i while piping payload line i.

Deterministic: the same --seed produces a byte-identical stdout stream and
times file (seeded random.Random, fixed iteration order, compact json.dumps).
Stdlib only.
"""
import argparse
import json
import random
import string
import sys

SESSION_ID = "sess-0001"
TRANSCRIPT = "/tmp/t.jsonl"
CWD = "/sandbox/proj"
BASE_TS = 1753689600          # matches tests/lib.sh default SUPERVISOR_NOW
SPAN_S = 4 * 60 * 60          # the 4-hour window

N_EDIT_FILES = 80
EDITS_MIN, EDITS_MAX = 1, 25
N_COMMANDS = 120
N_FAILURES = 40
ERR_MIN, ERR_MAX = 190, 210
N_READS = 200
N_READ_FILES = 60
N_REDGREEN = 6


def edit_payload(path, tool_use_id, duration_ms):
    return {
        "session_id": SESSION_ID,
        "transcript_path": TRANSCRIPT,
        "cwd": CWD,
        "permission_mode": "default",
        "hook_event_name": "PostToolUse",
        "tool_name": "Edit",
        "tool_input": {"file_path": path, "old_string": "OLD", "new_string": "NEW"},
        "tool_response": {"filePath": path, "success": True},
        "tool_use_id": tool_use_id,
        "duration_ms": duration_ms,
    }


def read_payload(path, tool_use_id, duration_ms):
    return {
        "session_id": SESSION_ID,
        "transcript_path": TRANSCRIPT,
        "cwd": CWD,
        "hook_event_name": "PostToolUse",
        "tool_name": "Read",
        "tool_input": {"file_path": path},
        "tool_response": "     1\tcontent",
        "tool_use_id": tool_use_id,
        "duration_ms": duration_ms,
    }


def bash_pass_payload(command, tool_use_id, duration_ms):
    return {
        "session_id": SESSION_ID,
        "transcript_path": TRANSCRIPT,
        "cwd": CWD,
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command, "description": "run"},
        "tool_response": {"stdout": "ok", "stderr": "", "interrupted": False, "isImage": False},
        "tool_use_id": tool_use_id,
        "duration_ms": duration_ms,
    }


def bash_fail_payload(command, error, tool_use_id, duration_ms):
    return {
        "session_id": SESSION_ID,
        "transcript_path": TRANSCRIPT,
        "cwd": CWD,
        "hook_event_name": "PostToolUseFailure",
        "tool_name": "Bash",
        "tool_input": {"command": command, "description": "run"},
        "tool_use_id": tool_use_id,
        "error": error,
        "is_interrupt": False,
        "duration_ms": duration_ms,
    }


def make_error(rng, tag):
    """A 190-210 char error string, deterministic per rng state."""
    target = rng.randint(ERR_MIN, ERR_MAX)
    base = "Command exited with non-zero status code 1: %s failed with " % tag
    pad = target - len(base)
    filler = "".join(rng.choice(string.ascii_lowercase) for _ in range(max(pad, 0)))
    return (base + filler)[:target]


def build_events(rng):
    """Return the ordered list of (kind, dict-without-tool_use_id) events."""
    events = []

    edit_paths = ["%s/src/mod%02d/file%02d.ts" % (CWD, i // 10, i) for i in range(N_EDIT_FILES)]
    for path in edit_paths:
        for _ in range(rng.randint(EDITS_MIN, EDITS_MAX)):
            events.append(("edit", {"path": path}))

    commands = ["npm run task-%03d" % i for i in range(N_COMMANDS)]
    failing = commands[:N_FAILURES]           # 40 failing commands
    passing_only = commands[N_FAILURES:]      # 80 pass-only commands
    redgreen = failing[:N_REDGREEN]           # 6 of the failing also pass later

    for cmd in passing_only:
        events.append(("bash_pass", {"command": cmd}))
    fail_markers = {}
    for cmd in failing:
        tag = cmd.split()[-1]
        events.append(("bash_fail", {"command": cmd, "error": make_error(rng, tag)}))
    for cmd in redgreen:
        events.append(("bash_pass_rg", {"command": cmd}))

    # 200 reads over exactly 60 distinct files: one guaranteed read per file,
    # the remaining 140 spread by the rng.
    read_paths = ["%s/src/readonly/r%02d.ts" % (CWD, i) for i in range(N_READ_FILES)]
    for path in read_paths:
        events.append(("read", {"path": path}))
    for _ in range(N_READS - N_READ_FILES):
        events.append(("read", {"path": rng.choice(read_paths)}))

    rng.shuffle(events)

    # Red->green ordering: every rg pass event must come AFTER its fail event.
    fail_idx = {}
    for i, (kind, d) in enumerate(events):
        if kind == "bash_fail" and d["command"] in redgreen:
            fail_idx[d["command"]] = i
    for i in range(len(events)):
        kind, d = events[i]
        if kind == "bash_pass_rg" and i < fail_idx[d["command"]]:
            j = fail_idx[d["command"]]
            events[i], events[j] = events[j], events[i]
            fail_idx[d["command"]] = i
    return events


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--times-out", default=None,
                    help="file to receive one SUPERVISOR_NOW epoch per payload line")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    events = build_events(rng)

    n = len(events)
    step = max(SPAN_S // n, 1)   # strictly increasing, spans <= 4 h
    times = [BASE_TS + i * step for i in range(n)]

    out = sys.stdout
    tf = open(args.times_out, "w") if args.times_out else None
    try:
        for i, (kind, d) in enumerate(events):
            tid = "toolu_h%04d" % i
            dur = rng.randint(2, 9000)
            if kind == "edit":
                p = edit_payload(d["path"], tid, dur)
            elif kind == "read":
                p = read_payload(d["path"], tid, dur)
            elif kind in ("bash_pass", "bash_pass_rg"):
                p = bash_pass_payload(d["command"], tid, dur)
            else:
                p = bash_fail_payload(d["command"], d["error"], tid, dur)
            out.write(json.dumps(p, separators=(",", ":")) + "\n")
            if tf:
                tf.write("%d\n" % times[i])
    finally:
        if tf:
            tf.close()


if __name__ == "__main__":
    main()
