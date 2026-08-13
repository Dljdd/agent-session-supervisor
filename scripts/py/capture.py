#!/usr/bin/env python3
"""capture.py — one hook stdin payload -> at most one event line (design U6).

Invoked by scripts/hook-capture.sh (PostToolUse/PostToolUseFailure, no flag),
by the boundary hooks with `--start`/`--stop`/`--end`, and by
scripts/hook-stop-failure.sh with `--limit` (U13/design §13.5): a StopFailure
payload -> one `{"k":"limit","err":error,"detail":clean(error_details,200)}`
event (both strings run through the same redaction pipeline as every other
stored field). `--limit` never touches sessions.index (only `--start` does).

Contract: main() ALWAYS returns 0 and NEVER raises — a capture hook must never
break the user's session (guard contract U1). Every stored string passes the
§10 redaction + §11.2 control-strip + CT-11 newline-escape + §10.4 truncation
pipeline BEFORE it reaches disk; §8.2 self-noise drops the recorder's own
activity; the single-write append (supervisor_common.append_event) enforces the
CT-10 4096-byte line budget.
"""
import hashlib
import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import supervisor_common as sc  # noqa: E402

try:
    import redact as _redact
except Exception:  # pragma: no cover - redact ships alongside; degrade closed
    _redact = None

BOUNDARY_MODES = ("--start", "--stop", "--end")

# field truncation budgets (design §U6 / §10.4)
C_MAX = 300
E_MAX = 200
PATH_MAX = 240
LIMIT_ERR_MAX = 100        # `error` code (design §13.5 k:"limit")
LIMIT_DETAIL_MAX = 200     # clean(error_details, 200)
GIT_TIMEOUT = 0.8
HASH_CAP = 100


# ---------------------------------------------------------------------------
# string cleaning: redact -> strip_controls -> escape_newlines -> truncate
# ---------------------------------------------------------------------------
def _scrub(s):
    """redact -> strip_controls -> escape_newlines. Returns None (fail closed)
    only when redact() itself raises — the caller substitutes a marker."""
    if _redact is None:
        return None
    try:
        s = _redact.redact(s)
    except Exception:
        return None
    return sc.escape_newlines(sc.strip_controls(s))


def clean(s, maxlen, path=False):
    """Design §U6 clean(): the full capture-time scrub pipeline.

    For `c`/`e` the tail is cut at `maxlen` with a trailing '…'; for `p`/`cwd`
    (`path=True`) the §10.4 `cap_path` head/tail elision is used instead. On a
    redact() error the value fails closed to "[redaction-error]"."""
    if not isinstance(s, str):
        s = "" if s is None else str(s)
    scrubbed = _scrub(s)
    if scrubbed is None:
        return "[redaction-error]"
    if path:
        return sc.cap_path(scrubbed, maxlen)
    if len(scrubbed) > maxlen:
        return scrubbed[:maxlen - 1] + "…"
    return scrubbed


# ---------------------------------------------------------------------------
# path relativization (paths under cwd stored relative, else absolute)
# ---------------------------------------------------------------------------
def _abspath(raw, cwd):
    try:
        if os.path.isabs(raw):
            return os.path.normpath(raw)
        base = cwd if cwd else os.getcwd()
        return os.path.normpath(os.path.join(base, raw))
    except Exception:
        return raw


def _relativize(raw, cwd):
    """Absolute path under `cwd` -> repo-relative (relpath verbatim, so a path
    exactly at cwd stores '.'); otherwise the path is returned unchanged."""
    try:
        if not cwd:
            return raw
        cwd_n = os.path.normpath(cwd)
        ab = _abspath(raw, cwd_n)
        if ab == cwd_n or ab.startswith(cwd_n + os.sep):
            return os.path.relpath(ab, cwd_n)
        return raw
    except Exception:
        return raw


def clean_path(raw, cwd):
    return clean(_relativize(raw, cwd), PATH_MAX, path=True)


def _payload_cwd(payload):
    cwd = payload.get("cwd")
    return cwd if isinstance(cwd, str) and cwd else os.getcwd()


# ---------------------------------------------------------------------------
# self-noise exclusion (design §8.2)
# ---------------------------------------------------------------------------
def _realpath(p):
    try:
        return os.path.realpath(p)
    except Exception:
        return None


def _under(child, base):
    if not child or not base:
        return False
    return child == base or child.startswith(base + os.sep)


def self_noise(kind, p, c, env):
    """True when the event is the recorder observing itself (§8.2 rules 1-4)."""
    try:
        data_raw = env.get("CLAUDE_PLUGIN_DATA") if env else None
        root_raw = env.get("CLAUDE_PLUGIN_ROOT") if env else None
        home = os.path.expanduser("~")
        plugins_data = os.path.join(home, ".claude", "plugins", "data")
        data_real = _realpath(data_raw) if data_raw else None
        plugins_real = _realpath(plugins_data)
        root_real = _realpath(root_raw) if root_raw else None

        # rules 1 & 4: event path under data dir / generic plugins data / plugin root
        if p:
            rp = _realpath(p)
            for base in (data_real, plugins_real, root_real):
                if base and _under(rp, base):
                    return True

        # rules 2 & 3: bash command string references the store or the plugin
        if c:
            needles = []
            if data_raw:
                needles.append(data_raw)
            if data_real:
                needles.append(data_real)
            needles.append(plugins_data)
            needles.append("~/.claude/plugins/data/")
            for n in needles:
                if n and n in c:
                    return True
            if "supervisorctl.sh" in c or "/scripts/py/" in c:
                return True
    except Exception:
        return False
    return False


# ---------------------------------------------------------------------------
# git snapshot (design §7 / CT-17)
# ---------------------------------------------------------------------------
def _git_text(cwd, args):
    try:
        r = subprocess.run(["git", "-C", cwd] + args, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=GIT_TIMEOUT)
        if r.returncode != 0:
            return None
        return r.stdout.decode("utf-8", "replace")
    except Exception:
        return None


def _git_bytes(cwd, args):
    try:
        r = subprocess.run(["git", "-C", cwd] + args, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=GIT_TIMEOUT)
        if r.returncode != 0:
            return None
        return r.stdout
    except Exception:
        return None


def _parse_porcelain(data):
    """Parse `git status --porcelain -z` (NUL-delimited). Each record is
    `XY PATH`; when X or Y is R/C the NEXT record is the rename/copy source —
    both go into the dirty set (CT-17). `??` records populate untracked."""
    dirty = []
    untracked = []
    recs = data.split(b"\0")
    if recs and recs[-1] == b"":
        recs.pop()
    i = 0
    n = len(recs)
    while i < n:
        rec = recs[i]
        if len(rec) < 3:
            i += 1
            continue
        xy = rec[:2]
        x = xy[0:1]
        y = xy[1:2]
        path = rec[3:].decode("utf-8", "replace")
        if xy == b"??":
            untracked.append(path)
        else:
            dirty.append(path)
        if x in (b"R", b"C") or y in (b"R", b"C"):
            i += 1
            if i < n:
                dirty.append(recs[i].decode("utf-8", "replace"))
        i += 1
    return dirty, untracked


def _hash_path(p):
    return hashlib.sha256(p.encode("utf-8", "replace")).hexdigest()[:12]


def git_snapshot(cwd):
    """`{root, head, dirty_n, untracked_n, dh, uh}` or None (design §7).

    Gated by the git_snapshots config key; each git subprocess bounded to
    GIT_TIMEOUT; any failure/non-repo -> None. Hash lists capped at HASH_CAP;
    the true totals stay in dirty_n/untracked_n."""
    try:
        if not sc.load_config().get("git_snapshots", True):
            return None
        top = _git_text(cwd, ["rev-parse", "--show-toplevel"])
        if not top or not top.strip():
            return None
        root = os.path.realpath(top.strip())
        head = _git_text(cwd, ["rev-parse", "HEAD"])
        if not head or not head.strip():
            return None
        head = head.strip()
        # Read porcelain FROM the repo root so paths are repo-root-relative.
        porc = _git_bytes(root, ["status", "--porcelain", "-z"])
        if porc is None:
            return None
        dirty, untracked = _parse_porcelain(porc)
        return {
            "root": root,
            "head": head,
            "dirty_n": len(dirty),
            "untracked_n": len(untracked),
            "dh": [_hash_path(x) for x in dirty[:HASH_CAP]],
            "uh": [_hash_path(x) for x in untracked[:HASH_CAP]],
        }
    except Exception:
        return None


# ---------------------------------------------------------------------------
# routing: PostToolUse / PostToolUseFailure -> event dict (or None)
# ---------------------------------------------------------------------------
def route_tool(payload, cfg):
    """Build the kind-specific event body (no common fields) or None.

    Gate order per §U6: config gates, then self-noise, then clean/relativize.
    self-noise reads the store/plugin locations from os.environ (main() has
    already overlaid any caller-supplied env there)."""
    env = os.environ
    cwd = _payload_cwd(payload)
    hook = payload.get("hook_event_name")
    tool = payload.get("tool_name")
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        ti = {}

    if hook == "PostToolUse":
        if tool in ("Write", "Edit", "NotebookEdit"):
            raw = ti.get("file_path") or ti.get("notebook_path")
            if not isinstance(raw, str) or not raw:
                return None
            if self_noise("edit", _abspath(raw, cwd), None, env):
                return None
            return {"k": "edit", "p": clean_path(raw, cwd)}
        if tool == "Read":
            if not cfg.get("capture_reads", True):
                return None
            raw = ti.get("file_path")
            if not isinstance(raw, str) or not raw:
                return None
            if self_noise("read", _abspath(raw, cwd), None, env):
                return None
            return {"k": "read", "p": clean_path(raw, cwd)}
        if tool == "Bash":
            return _bash_event(payload, ti, cfg, env, ok=True)
        return None

    if hook == "PostToolUseFailure" and tool == "Bash":
        if payload.get("is_interrupt"):
            return None                       # an interrupt is not a failure
        return _bash_event(payload, ti, cfg, env, ok=False)

    return None


def _bash_event(payload, ti, cfg, env, ok):
    raw_c = ti.get("command")
    raw_c = raw_c if isinstance(raw_c, str) else ""
    capture_cmds = cfg.get("capture_commands", True)
    if ok and not capture_cmds:
        return None                           # pass events add nothing without cmds
    if self_noise("bash", None, raw_c, env):
        return None
    ev = {"k": "bash"}
    if capture_cmds:
        ev["c"] = clean(raw_c, C_MAX)
        ev["ok"] = ok
        if not ok:
            ev["e"] = clean(payload.get("error") or "", E_MAX)
    else:
        ev["c"] = "[command capture disabled]"
        ev["ok"] = ok
    ms = payload.get("duration_ms")
    if isinstance(ms, int) and not isinstance(ms, bool):
        ev["ms"] = ms
    return ev


# ---------------------------------------------------------------------------
# boundary events: --start / --stop / --end
# ---------------------------------------------------------------------------
def boundary_event(payload, mode, cfg):
    cwd = _payload_cwd(payload)
    if mode == "--start":
        ev = {"k": "start",
              "src": clean(payload.get("source") or "", 64),
              "cwd": clean(cwd, PATH_MAX, path=True)}
        pid = sc.find_claude_pid()
        if pid:
            ev["pid"] = pid
        git = git_snapshot(cwd)
        if git:
            ev["git"] = git
        return ev
    if mode == "--stop":
        return {"k": "stop"}
    if mode == "--end":
        ev = {"k": "end", "reason": clean(payload.get("reason") or "other", 64)}
        git = git_snapshot(cwd)
        if git:
            ev["git"] = git
        return ev
    return None


def limit_event(payload):
    """Design §13.5: a StopFailure -> `{"k":"limit","err":error,"detail":...}`.

    `err` is the short `error` code; `detail` is `error_details` cleaned to 200
    chars (dropped entirely when empty). Both flow the redact/strip/escape
    pipeline like every stored field."""
    err = payload.get("error")
    err = err if isinstance(err, str) else ("" if err is None else str(err))
    detail = payload.get("error_details")
    detail = detail if isinstance(detail, str) else ("" if detail is None else str(detail))
    ev = {"k": "limit", "err": clean(err, LIMIT_ERR_MAX)}
    if detail:
        ev["detail"] = clean(detail, LIMIT_DETAIL_MAX)
    return ev


# ---------------------------------------------------------------------------
# sessions.index (design §4.3 — one safe_sid per line, dedup)
# ---------------------------------------------------------------------------
def _append_sessions_index(proj_dir, s):
    try:
        idx = os.path.join(proj_dir, "sessions.index")
        existing = set()
        if os.path.exists(idx):
            with open(idx, "r", encoding="utf-8", errors="replace") as f:
                existing = set(line.strip() for line in f)
        if s in existing:
            return
        fd = os.open(idx, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (s + "\n").encode("utf-8"))
        finally:
            os.close(fd)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# entrypoint
# ---------------------------------------------------------------------------
def _mode_from_argv(argv):
    if not argv:
        return "tool"
    if argv[0] in BOUNDARY_MODES:
        return argv[0]
    if argv[0] == "--limit":
        return "--limit"
    return None                               # unknown flag: no-op


def _run(argv, raw_stdin):
    try:
        payload = json.loads(raw_stdin)
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0

    mode = _mode_from_argv(argv)
    if mode is None:
        return 0

    cfg = sc.load_config()

    raw_sid = payload.get("session_id")
    raw_sid = raw_sid if isinstance(raw_sid, str) else ("" if raw_sid is None else str(raw_sid))
    s = sc.safe_sid(raw_sid)

    agent_id = payload.get("agent_id")
    is_sub = bool(agent_id)
    if is_sub and not cfg.get("capture_subagents", True):
        return 0

    cwd = _payload_cwd(payload)

    if mode == "tool":
        ev = route_tool(payload, cfg)
    elif mode == "--limit":
        ev = limit_event(payload)
    else:
        ev = boundary_event(payload, mode, cfg)
    if ev is None:
        return 0

    # Resolve the store LAST (creates projects/<key>/ + meta.json). A missing
    # data dir raises here and is caught by main() -> exit 0, nothing written.
    proj_dir = sc.project_dir(cwd, for_hook=True)

    out = {"v": 1, "ts": sc.now(), "s": s}
    out.update(ev)
    if is_sub:
        out["a"] = 1
    if raw_sid and s != raw_sid:
        out["sid_raw"] = sc.cap_path(sc.escape_newlines(sc.strip_controls(raw_sid)), PATH_MAX)

    if mode == "--start":
        _append_sessions_index(proj_dir, s)

    sc.append_event(os.path.join(proj_dir, "events.jsonl"), out)
    return 0


def main(argv=None, stdin=None, env=None):
    try:
        os.umask(0o077)
        if argv is None:
            argv = sys.argv[1:]
        argv = list(argv)
        if env is not None and env is not os.environ:
            # Honor a caller-supplied env for the os.environ reads throughout
            # (supervisor_common paths/config, self_noise store locations).
            os.environ.update(env)
        if stdin is None:
            raw = sys.stdin.read()
        else:
            raw = stdin
        return _run(argv, raw)
    except Exception:
        return 0


if __name__ == "__main__":
    sys.exit(main())
