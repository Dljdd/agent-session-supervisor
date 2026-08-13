#!/usr/bin/env python3
"""telemetry.py - statusline stdin -> telemetry files (design 14.2, CT-8).

STANDALONE by design: it imports NOTHING from its sibling python units, so the
copy install_statusline.py drops into <data>/bin/ keeps working even when the
plugin root (and every other script) has been deleted or renamed (design 14.3,
critics SF-04/TF-5). The `_safe_sid` rule below is a verbatim copy of
supervisor_common.safe_sid (design 4.3) - keep them in sync by hand.

Contract:
  argv: --data-dir <abs>   (required; passed by statusline.sh from its own
                            self-resolution - no env dependency)
  stdin: the statusline JSON (schema FACTS 6.2). Unparseable -> exit 0.
Writes atomically (same-dir 0600 temp + os.replace; os.umask(0o077)):
  telemetry/rate_limits.json      account-scoped, only when rate_limits present
  telemetry/sessions/<safe_sid>.json   latest cost snapshot for the session
Both writes carry an independent 2 s mtime throttle (second layer under the
statusline shell's 30 s throttle). Session files older than 30 days are pruned
opportunistically, at most once an hour (a .retention-mark mtime gate).
Any failure is swallowed: a telemetry write must never surface an error.
"""
import json
import os
import re
import sys
import time

_SAFE_SID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


def _safe_sid(raw):
    # Verbatim twin of supervisor_common.safe_sid (design 4.3, critic SEC-12).
    if isinstance(raw, str) and _SAFE_SID.match(raw):
        return raw
    import hashlib
    b = raw.encode("utf-8", "replace") if isinstance(raw, str) else repr(raw).encode()
    return "x" + hashlib.sha256(b).hexdigest()[:12]


def _now():
    v = os.environ.get("SUPERVISOR_NOW")
    if v:
        try:
            return int(v)
        except (TypeError, ValueError):
            pass
    return int(time.time())


def _atomic(path, obj):
    """Same-dir O_EXCL 0600 temp -> os.replace; temp unlinked on any failure."""
    d = os.path.dirname(path) or "."
    try:
        os.makedirs(d, 0o700, exist_ok=True)
    except OSError:
        pass
    tmp = os.path.join(d, ".%s.tmp%d" % (os.path.basename(path), os.getpid()))
    try:
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        try:
            os.write(fd, json.dumps(obj, separators=(",", ":")).encode("utf-8"))
        finally:
            os.close(fd)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _fresh(path, secs):
    """True when `path` exists and its mtime is younger than `secs` real seconds."""
    try:
        return (time.time() - os.path.getmtime(path)) < secs
    except OSError:
        return False


def _num(v):
    if isinstance(v, bool):
        return None
    return v if isinstance(v, (int, float)) else None


def _window(d):
    """Extract a {used_percentage, resets_at} object, keeping only present keys."""
    if not isinstance(d, dict):
        return None
    out = {}
    up = _num(d.get("used_percentage"))
    if up is not None:
        out["used_percentage"] = up
    ra = _num(d.get("resets_at"))
    if ra is not None:
        out["resets_at"] = ra
    return out or None


def _write_rate_limits(base, data, now):
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return
    fh = _window(rl.get("five_hour"))
    sd = _window(rl.get("seven_day"))
    if fh is None and sd is None:
        return
    path = os.path.join(base, "telemetry", "rate_limits.json")
    if _fresh(path, 2):
        return
    obj = {"v": 1, "ts": now}
    if fh is not None:
        obj["five_hour"] = fh
    if sd is not None:
        obj["seven_day"] = sd
    _atomic(path, obj)


def _write_session(base, data, now):
    sid = data.get("session_id")
    if not isinstance(sid, str) or not sid:
        return
    path = os.path.join(base, "telemetry", "sessions", _safe_sid(sid) + ".json")
    if _fresh(path, 2):
        return
    cost = data.get("cost") if isinstance(data.get("cost"), dict) else {}
    cw = data.get("context_window") if isinstance(data.get("context_window"), dict) else {}
    model = data.get("model") if isinstance(data.get("model"), dict) else {}
    obj = {"v": 1, "ts": now, "session_id": sid}
    for src, key in (("total_cost_usd", "total_cost_usd"),
                     ("total_duration_ms", "total_duration_ms"),
                     ("total_lines_added", "total_lines_added"),
                     ("total_lines_removed", "total_lines_removed")):
        val = _num(cost.get(src))
        if val is not None:
            obj[key] = val
    up = _num(cw.get("used_percentage"))
    if up is not None:
        obj["context_used_percentage"] = up
    mid = model.get("id")
    if isinstance(mid, str) and mid:
        obj["model_id"] = mid
    _atomic(path, obj)


def _retention(base):
    """Delete telemetry/sessions/*.json older than 30 days, <=hourly (marker mtime)."""
    sdir = os.path.join(base, "telemetry", "sessions")
    mark = os.path.join(base, "telemetry", ".retention-mark")
    if _fresh(mark, 3600):
        return
    try:
        os.makedirs(os.path.join(base, "telemetry"), 0o700, exist_ok=True)
        # touch the marker first so a scan failure still spaces out attempts
        with open(mark, "w"):
            pass
        os.chmod(mark, 0o600)
    except OSError:
        pass
    cutoff = time.time() - 30 * 86400
    try:
        entries = list(os.scandir(sdir))
    except OSError:
        return
    for e in entries:
        if not e.name.endswith(".json"):
            continue
        try:
            if e.stat().st_mtime < cutoff:
                os.unlink(e.path)
        except OSError:
            continue


def main(argv=None):
    os.umask(0o077)
    argv = list(sys.argv[1:] if argv is None else argv)
    data_dir = None
    i = 0
    while i < len(argv):
        if argv[i] == "--data-dir" and i + 1 < len(argv):
            data_dir = argv[i + 1]
            i += 2
            continue
        i += 1
    if not data_dir:
        return 0
    try:
        raw = sys.stdin.read()
    except Exception:
        return 0
    try:
        data = json.loads(raw)
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0
    # Nothing to persist (no rate_limits, no session) -> do NOT even create the
    # telemetry dir or the retention marker (keeps the S-05 "no write" case clean).
    has_rl = isinstance(data.get("rate_limits"), dict)
    has_sid = isinstance(data.get("session_id"), str) and bool(data.get("session_id"))
    if not has_rl and not has_sid:
        return 0
    now = _now()
    try:
        _write_rate_limits(data_dir, data, now)
    except Exception:
        pass
    try:
        _write_session(data_dir, data, now)
    except Exception:
        pass
    try:
        _retention(data_dir)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
