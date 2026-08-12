#!/usr/bin/env python3
"""maintain.py - store hygiene run at SessionStart only (design U7 / section 8.4,
12.1, 13.3). Single writer for rotation and reconciliation. Every action is
isolated in its own try/except so one failing step never blocks the others, and
the whole entrypoint is best-effort: a hook must never break the user's session.

CLI:
  maintain.py sweep  --cwd <cwd> [--now <ts>]
  maintain.py forget --cwd <cwd> [--all] [--yes]

`sweep` does: rotate (>10 MB), retention (30-day archive/report prune, sessions
cap, debug truncate), reconcile unterminated runs (infer an end only when the
run is old AND not provably live, critic TF-6), awake-lock sweep, resume-pending
cleanup, statusline-copy staleness marker, and a permission re-assert walk.
"""
import json
import os
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import supervisor_common as sc  # noqa: E402

ROTATE_BYTES = 10 * 1024 * 1024          # 10 MB (design 8.4)
ARCHIVE_MAX_AGE = 30 * 24 * 3600         # 30 days
REPORT_MAX_AGE = 30 * 24 * 3600
SESSIONS_CAP = 500
DEBUG_CAP = 1 * 1024 * 1024              # 1 MB
IDLE_CLOSE_S = 30 * 60                   # 30 min unterminated-run rule
AWAKE_ABS_CAP = 36 * 3600               # 36 h absolute lock cap
LEDGER_MAX_AGE = 14 * 24 * 3600
AWAKE_COMMS = ("caffeinate", "systemd-inhibit", "tail")


# ---------------------------------------------------------------------------
# liveness helpers (module level so tests can monkeypatch _looks_claude)
# ---------------------------------------------------------------------------

def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def _looks_claude(pid):
    """Whether pid's command looks like a claude process (design U2 acceptance).
    Honors the SUPERVISOR_FAKE_LOOKS_CLAUDE test seam (test mode only) so the
    live-idle reconcile skip is drivable without a real claude process."""
    if (os.environ.get("SUPERVISOR_TEST_MODE") == "1"
            and os.environ.get("SUPERVISOR_FAKE_LOOKS_CLAUDE") == "1"):
        return True
    try:
        r = subprocess.run(["ps", "-p", str(int(pid)), "-o", "command="],
                           capture_output=True, text=True, timeout=2)
        if r.returncode != 0:
            return False
        return sc._looks_claude(r.stdout.strip())
    except Exception:
        return False


def _comm(pid):
    try:
        r = subprocess.run(["ps", "-p", str(int(pid)), "-o", "comm="],
                           capture_output=True, text=True, timeout=2)
        if r.returncode != 0:
            return ""
        return os.path.basename(r.stdout.strip())
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# sweep actions (each independently try/excepted by sweep())
# ---------------------------------------------------------------------------

def _rotate(pdir):
    ev = os.path.join(pdir, "events.jsonl")
    try:
        size = os.path.getsize(ev)
    except OSError:
        return
    if size <= ROTATE_BYTES:
        return
    arc = os.path.join(pdir, "events.jsonl.1")
    try:
        if os.path.exists(arc):
            os.unlink(arc)
    except OSError:
        pass
    try:
        os.rename(ev, arc)
    except OSError:
        pass


def _retention(pdir, now):
    arc = os.path.join(pdir, "events.jsonl.1")
    try:
        if os.path.exists(arc) and (now - os.path.getmtime(arc)) > ARCHIVE_MAX_AGE:
            os.unlink(arc)
    except OSError:
        pass
    rdir = os.path.join(pdir, "reports")
    try:
        for name in os.listdir(rdir):
            if not name.endswith(".md"):
                continue
            p = os.path.join(rdir, name)
            try:
                if (now - os.path.getmtime(p)) > REPORT_MAX_AGE:
                    os.unlink(p)
            except OSError:
                pass
    except OSError:
        pass
    sess = os.path.join(pdir, "sessions.jsonl")
    try:
        if os.path.exists(sess):
            with open(sess, "r", encoding="utf-8", errors="replace") as f:
                lines = [ln for ln in f.read().split("\n") if ln.strip()]
            if len(lines) > SESSIONS_CAP:
                sc.atomic_write(sess, "\n".join(lines[-SESSIONS_CAP:]) + "\n")
    except Exception:
        pass


def _truncate_debug(base):
    dbg = os.path.join(base, "logs", "debug.log")
    try:
        if os.path.exists(dbg) and os.path.getsize(dbg) > DEBUG_CAP:
            with open(dbg, "rb") as f:
                f.seek(-DEBUG_CAP // 2, os.SEEK_END)
                tail = f.read()
            nl = tail.find(b"\n")
            tail = tail[nl + 1:] if nl >= 0 else tail
            sc.atomic_write(dbg, tail)
    except Exception:
        pass


def reconcile(pdir, cwd, now):
    """Append an inferred end for each unterminated run whose last event is
    older than 30 min AND that is not provably live (design 12.1 / U7.3).
    Returns the number of inferred ends appended."""
    import digest
    events = sc.read_events([os.path.join(pdir, "events.jsonl.1"),
                             os.path.join(pdir, "events.jsonl")])
    runs = digest.group_runs(digest._normalize(events))
    appended = 0
    snap = None
    snap_taken = False
    for r in runs:
        if r["closed"]:
            continue
        pid = r.get("pid")
        if pid is not None:
            try:
                pidi = int(pid)
                if _pid_alive(pidi) and _looks_claude(pidi):
                    continue                          # live: never close under user
            except Exception:
                pass
        last_ts = max((e.get("ts", r["t0"]) for e in r["events"]), default=r["t0"])
        if now - last_ts <= IDLE_CLOSE_S:
            continue
        if not snap_taken:
            try:
                import capture
                snap = capture.git_snapshot(cwd)
            except Exception:
                snap = None
            snap_taken = True
        ev = {"v": 1, "ts": now, "s": r["sid"], "k": "end",
              "reason": "inferred", "inf": 1}
        if snap:
            ev["git"] = snap
        try:
            sc.append_event(os.path.join(pdir, "events.jsonl"), ev)
            appended += 1
        except Exception:
            pass
    return appended


def _awake_sweep(base, now):
    adir = os.path.join(base, "awake")
    try:
        names = os.listdir(adir)
    except OSError:
        return
    for name in names:
        if not name.endswith(".lock"):
            continue
        lock = os.path.join(adir, name)
        try:
            with open(lock, "r", encoding="utf-8", errors="replace") as f:
                obj = json.load(f)
        except Exception:
            obj = None
        remove = False
        if isinstance(obj, dict):
            ts = obj.get("ts", 0)
            claude_pid = obj.get("claude_pid")
            holder = obj.get("holder_pid")
            mode = obj.get("mode")
            aged = (now - ts) > AWAKE_ABS_CAP if isinstance(ts, (int, float)) else True
            # No claude_pid to probe (adrafinil locks carry none) => we CANNOT
            # prove the session is dead, so default to alive and let the 36 h
            # `aged` cap and awake-release.sh reclaim it. Defaulting dead=True
            # here made every fresh adrafinil lock self-destruct on the next
            # sweep (and let a second session release a first session's live
            # lock). caffeinate/inhibit locks always carry claude_pid, so their
            # liveness is still probed exactly as before.
            dead = False
            if claude_pid is not None:
                dead = not _pid_alive(claude_pid)
            if dead or aged:
                if mode == "adrafinil":
                    try:
                        subprocess.run(
                            ["adrafinil", "release", obj.get("key", "")],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=2)
                    except Exception:
                        pass
                elif holder is not None and _pid_alive(holder) and _comm(holder) in AWAKE_COMMS:
                    try:
                        os.kill(int(holder), 15)
                    except Exception:
                        pass
                remove = True
        else:
            remove = True
        if remove:
            try:
                os.unlink(lock)
            except OSError:
                pass


def _resume_cleanup(base, now, cfg):
    rdir = os.path.join(base, "resume")
    pend = os.path.join(rdir, "pending")
    try:
        for name in os.listdir(pend):
            if not name.endswith(".json"):
                continue
            p = os.path.join(pend, name)
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    obj = json.load(f)
                pid = obj.get("pid") if isinstance(obj, dict) else None
                if pid is None or not _pid_alive(pid):
                    os.unlink(p)
            except Exception:
                try:
                    os.unlink(p)
                except OSError:
                    pass
    except OSError:
        pass
    # stale exec mutex
    lock = os.path.join(rdir, "attempt.lock")
    try:
        max_min = cfg.get("resume_max_minutes", 30)
        if not isinstance(max_min, (int, float)) or isinstance(max_min, bool):
            max_min = 30
        if os.path.exists(lock) and (now - os.path.getmtime(lock)) > (max_min + 5) * 60:
            os.unlink(lock)
    except Exception:
        pass
    # prune old ledger entries
    state = os.path.join(rdir, "state.json")
    try:
        if os.path.exists(state):
            with open(state, "r", encoding="utf-8", errors="replace") as f:
                obj = json.load(f)
            if isinstance(obj, dict) and isinstance(obj.get("attempts"), list):
                kept = [a for a in obj["attempts"]
                        if isinstance(a, dict)
                        and (now - a.get("ts", 0)) <= LEDGER_MAX_AGE]
                if len(kept) != len(obj["attempts"]):
                    obj["attempts"] = kept
                    sc.atomic_write(state,
                                    json.dumps(obj, separators=(",", ":")) + "\n")
    except Exception:
        pass


def _statusline_freshness(base):
    """Mark the installed statusline copy stale when it drifts from the shipped
    script (design U7.6 / critic SEC-11). Best-effort; no failure propagates."""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    installed = os.path.join(base, "bin", "supervisor-statusline.sh")
    stale = os.path.join(base, "bin", ".stale")
    try:
        if not os.path.exists(installed):
            return
        shipped = os.path.join(root, "scripts", "statusline.sh") if root else None
        if not shipped or not os.path.exists(shipped):
            return
        import hashlib

        def digest_of(p):
            # Normalize the install-time customization: install_statusline.py bakes
            # the data dir into the `SUPERVISOR_BAKED_DATA_DIR=` line of the copy
            # (design 14.3/U18), so that ONE line legitimately differs from the
            # shipped script and must not read as drift. Everything else (the real
            # logic) is compared byte-for-byte, so a plugin update to statusline.sh
            # still correctly marks the copy stale.
            h = hashlib.sha256()
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("SUPERVISOR_BAKED_DATA_DIR="):
                        line = "SUPERVISOR_BAKED_DATA_DIR=\n"
                    h.update(line.encode("utf-8", "replace"))
            return h.hexdigest()
        same = digest_of(installed) == digest_of(shipped)
        if same:
            if os.path.exists(stale):
                os.unlink(stale)
        else:
            sc.atomic_write(stale, "1\n")
    except Exception:
        pass


def _perm_reassert(base):
    try:
        os.chmod(base, 0o700)
    except OSError:
        pass
    try:
        for root, dirs, files in os.walk(base):
            for d in dirs:
                try:
                    os.chmod(os.path.join(root, d), 0o700)
                except OSError:
                    pass
            for fn in files:
                try:
                    os.chmod(os.path.join(root, fn), 0o600)
                except OSError:
                    pass
    except Exception:
        pass


def sweep(cwd, now):
    try:
        base = sc.data_dir(for_hook=True)
    except Exception:
        return 0
    try:
        pdir = sc.project_dir(cwd, for_hook=True)
    except Exception:
        return 0
    cfg = sc.load_config()
    for action in (
            lambda: _rotate(pdir),
            lambda: _retention(pdir, now),
            lambda: _truncate_debug(base),
            lambda: reconcile(pdir, cwd, now),
            lambda: _awake_sweep(base, now),
            lambda: _resume_cleanup(base, now, cfg),
            lambda: _statusline_freshness(base),
            lambda: _perm_reassert(base)):
        try:
            action()
        except Exception:
            pass
    return 0


# ---------------------------------------------------------------------------
# forget (CT-16 / design U16)
# ---------------------------------------------------------------------------

def _read_index(pdir):
    idx = os.path.join(pdir, "sessions.index")
    out = []
    try:
        with open(idx, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                s = line.strip()
                if s:
                    out.append(s)
    except OSError:
        pass
    return out


def _rmtree(path):
    try:
        import shutil
        shutil.rmtree(path, ignore_errors=True)
    except Exception:
        pass


def _forget_all(base, yes):
    if not yes:
        sys.stdout.write("DRY RUN - would remove the ENTIRE supervisor data "
                         "dir:\n  %s\nRe-run with --yes to proceed.\n" % base)
        return 3
    _rmtree(base)
    sys.stdout.write("Removed the entire supervisor data dir: %s\n" % base)
    return 0


def forget(cwd, all_flag, yes):
    try:
        base = sc.data_dir(for_hook=False)
    except Exception:
        return 0
    if all_flag:
        return _forget_all(base, yes)

    key, src = sc.project_key(cwd)
    pdir = os.path.join(base, "projects", key)
    sids = _read_index(pdir)
    tele_sess = os.path.join(base, "telemetry", "sessions")
    awake = os.path.join(base, "awake")
    pend = os.path.join(base, "resume", "pending")
    state = os.path.join(base, "resume", "state.json")
    debug = os.path.join(base, "logs", "debug.log")

    # pending sleepers whose cwd keys to THIS project
    proj_pending = []
    try:
        for name in os.listdir(pend):
            if not name.endswith(".json"):
                continue
            p = os.path.join(pend, name)
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    obj = json.load(f)
                pcwd = obj.get("cwd") if isinstance(obj, dict) else None
                if pcwd and sc.project_key(pcwd)[0] == key:
                    proj_pending.append((p, obj))
            except Exception:
                pass
    except OSError:
        pass

    if not yes:
        lines = ["DRY RUN - the following WILL be deleted for project key %s"
                 " (%s):" % (key, src),
                 "  %s/  (event log + derived caches)" % pdir]
        for s in sids:
            lines.append("  telemetry/sessions/%s.json" % s)
            lines.append("  awake/%s.lock" % s)
            lines.append("  resume/pending/%s.json" % s)
        for p, _o in proj_pending:
            lines.append("  %s" % p)
        lines.append("  ledger entries for this project's sessions in "
                     "resume/state.json")
        lines.append("  logs/debug.log  (truncated to empty)")
        lines.append("WILL NOT be touched: telemetry/rate_limits.json "
                     "(account-scoped), and every other project's data.")
        lines.append("Re-run with --yes to proceed.")
        sys.stdout.write("\n".join(lines) + "\n")
        return 3

    # --yes: perform deletions
    _rmtree(pdir)
    sid_set = set(sids)
    for s in sids:
        for p in (os.path.join(tele_sess, s + ".json"),
                  os.path.join(awake, s + ".lock"),
                  os.path.join(pend, s + ".json")):
            try:
                if p.endswith(".json") and os.path.dirname(p) == pend and os.path.exists(p):
                    _sigterm_pending(p)
                if os.path.exists(p):
                    os.unlink(p)
            except Exception:
                pass
    for p, _o in proj_pending:
        try:
            _sigterm_pending(p)
            if os.path.exists(p):
                os.unlink(p)
        except Exception:
            pass
    _filter_ledger(state, sid_set)
    try:
        if os.path.exists(debug):
            sc.atomic_write(debug, "")
    except Exception:
        pass
    sys.stdout.write("Forgot project %s (%s).\n" % (key, src))
    return 0


def _sigterm_pending(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            obj = json.load(f)
        pid = obj.get("pid") if isinstance(obj, dict) else None
        if pid is not None and _pid_alive(pid) and _comm(pid) in ("claude", "sh", "python3", "python"):
            os.kill(int(pid), 15)
    except Exception:
        pass


def _filter_ledger(state, sid_set):
    try:
        if not os.path.exists(state):
            return
        with open(state, "r", encoding="utf-8", errors="replace") as f:
            obj = json.load(f)
        if isinstance(obj, dict) and isinstance(obj.get("attempts"), list):
            obj["attempts"] = [a for a in obj["attempts"]
                               if not (isinstance(a, dict)
                                       and a.get("session") in sid_set)]
            sc.atomic_write(state, json.dumps(obj, separators=(",", ":")) + "\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _opt(args, name):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return None


def main(argv=None):
    os.umask(0o077)
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "sweep":
        cwd = _opt(args, "--cwd") or os.getcwd()
        nv = _opt(args, "--now")
        now = int(nv) if nv is not None and nv.isdigit() else sc.now()
        try:
            return sweep(cwd, now)
        except Exception:
            return 0
    if cmd == "forget":
        cwd = _opt(args, "--cwd") or os.getcwd()
        try:
            return forget(cwd, "--all" in args, "--yes" in args)
        except Exception:
            return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
