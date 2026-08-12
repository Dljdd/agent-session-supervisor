#!/usr/bin/env python3
"""supervisor_common.py - shared paths, project key, config, atomic IO, sanitize
helpers for the supervisor plugin (design spec U4 / sections 4, 8.3, 10.4, 11.2).

Import-time contract: NO side effects (no disk IO, no env mutation, no umask).
Entrypoint main() sets os.umask(0o077) first. All IO helpers raise on failure;
hook workers catch everything and exit 0 (guard contract U1).
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time


class DataDirUnset(Exception):
    """No data dir resolvable in hook context (CT-12: hooks never fall back)."""


class DataDirRefused(Exception):
    """Resolved data dir failed the containment check (design 4.1)."""


class ConfigRefused(Exception):
    """config_set refused: unknown key, wrong type, protected key without ack,
    or resume_extra_args whitelist violation (design 4.4)."""


# ---------------------------------------------------------------------------
# clock
# ---------------------------------------------------------------------------

def now() -> int:
    """Epoch seconds, honoring the SUPERVISOR_NOW test seam (CT-13)."""
    v = os.environ.get("SUPERVISOR_NOW")
    if v:
        return int(v)
    return int(time.time())


# ---------------------------------------------------------------------------
# data dir resolution (CT-12, design 4.1)
# ---------------------------------------------------------------------------

def _existing_ancestor(path: str) -> str:
    """Nearest existing ancestor of path (path itself when it exists)."""
    q = path
    while q and not os.path.isdir(q):
        parent = os.path.dirname(q)
        if parent == q:
            break
        q = parent
    return q or os.sep


def containment_ok(d: str) -> bool:
    """False when d resolves inside CLAUDE_PROJECT_DIR, the current working
    directory, or any git worktree (design 4.1 containment check). The git
    probe runs against the nearest EXISTING ancestor so a not-yet-created
    dir inside a repo (the .envrc attack, A-20) is still refused."""
    rp = os.path.realpath(d)
    bases = []
    proj = os.environ.get("CLAUDE_PROJECT_DIR")
    if proj:
        bases.append(os.path.realpath(proj))
    try:
        bases.append(os.path.realpath(os.getcwd()))
    except OSError:
        pass
    for b in bases:
        if rp == b or rp.startswith(b + os.sep):
            return False
    probe = _existing_ancestor(rp)
    try:
        r = subprocess.run(
            ["git", "-C", probe, "rev-parse", "--show-toplevel"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        if r.returncode == 0:
            return False
    except Exception:
        pass  # git missing/hung: PWD and PROJECT_DIR checks above still hold
    return True


def data_dir(for_hook: bool = True) -> str:
    """Resolve the plugin data dir in CT-12 order.

    1. CLAUDE_PLUGIN_DATA (platform-supplied; exempt from containment).
    2. SUPERVISOR_DATA_DIR, only when SUPERVISOR_TEST_MODE=1 too; containment
       violation raises DataDirRefused.
    3. for_hook=True and nothing resolved: raise DataDirUnset (hook wrappers
       catch and exit 0 -- hooks never fall back, CT-12).
       for_hook=False (supervisorctl path): ~/.claude/plugins/data/supervisor-inline.
    """
    v = os.environ.get("CLAUDE_PLUGIN_DATA")
    if v:
        return v
    if os.environ.get("SUPERVISOR_TEST_MODE") == "1":
        v = os.environ.get("SUPERVISOR_DATA_DIR")
        if v:
            if not containment_ok(v):
                raise DataDirRefused(v)
            return v
    if for_hook:
        raise DataDirUnset()
    return os.path.join(os.path.expanduser("~"), ".claude", "plugins", "data",
                        "supervisor-inline")


# ---------------------------------------------------------------------------
# project identity (design 4.2)
# ---------------------------------------------------------------------------

_URL_USERINFO = re.compile(r"^([a-z][a-z0-9+.-]*://)[^/@]*@")
_SCP_USERINFO = re.compile(r"^[^@/:]+@")
_URL_SCHEME = re.compile(r"^([a-z][a-z0-9+.-]*)://([^/]+)(/.*)?$")
_SCP_FORM = re.compile(r"^([^/:]+):(.*)$")


def _normalize_remote(url: str) -> str:
    src = url.strip()
    # Strip the ENTIRE userinfo component FIRST (SEC-10: tokens in remotes
    # must never reach meta.json or the key hash).
    src = _URL_USERINFO.sub(r"\1", src)
    src = _SCP_USERINFO.sub("", src)
    # Lowercase the normalized remote (host case is insignificant; the design
    # examples fold path case too so case-variant clones share one store).
    src = src.lower().strip()
    src = src.rstrip("/")
    if src.endswith(".git"):
        src = src[:-4]
    m = _URL_SCHEME.match(src)
    if m:
        host = re.sub(r":\d+$", "", m.group(2))  # ssh://host[:port]/p -> host/p
        return host + (m.group(3) or "")
    m = _SCP_FORM.match(src)
    if m:
        return m.group(1) + "/" + m.group(2)     # host:path -> host/path
    return src


def project_key(cwd: str):
    """(key12, source_string) per design 4.2: normalized remote.origin.url,
    else realpath(cwd)."""
    src = ""
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "config", "--get", "remote.origin.url"],
            capture_output=True, text=True, timeout=2)
        if r.returncode == 0 and r.stdout.strip():
            src = _normalize_remote(r.stdout)
    except Exception:
        src = ""
    if not src:
        src = os.path.realpath(cwd)
    return hashlib.sha256(src.encode("utf-8", "replace")).hexdigest()[:12], src


def _redact_safe(s: str) -> str:
    """redact() with the fail-closed substitution (never store raw on error)."""
    try:
        import redact as _redact_mod
        return _redact_mod.redact(s)
    except Exception:
        return "[redaction-error]"


def project_dir(cwd: str, for_hook: bool = True) -> str:
    """Create (0700) and return projects/<key12>; writes meta.json once with
    the sanitized key_source (design 4.2/10.4)."""
    base = data_dir(for_hook=for_hook)
    key, src = project_key(cwd)
    d = os.path.join(base, "projects", key)
    os.makedirs(d, mode=0o700, exist_ok=True)
    for p in (base, os.path.join(base, "projects"), d):
        try:
            os.chmod(p, 0o700)
        except OSError:
            pass
    meta = os.path.join(d, "meta.json")
    if not os.path.exists(meta):
        ks = cap_path(escape_newlines(strip_controls(_redact_safe(src))))
        atomic_write(meta, json.dumps(
            {"v": 1, "key_source": ks, "first_seen": now()},
            separators=(",", ":")) + "\n")
    return d


_SAFE_SID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


def safe_sid(raw: str) -> str:
    """A session id safe as a path component (design 4.3, critic SEC-12)."""
    if isinstance(raw, str) and _SAFE_SID.match(raw):
        return raw
    b = raw.encode("utf-8", "replace") if isinstance(raw, str) else repr(raw).encode()
    return "x" + hashlib.sha256(b).hexdigest()[:12]


# ---------------------------------------------------------------------------
# claude process discovery (python twin of lib/findpid.sh, design U2)
# ---------------------------------------------------------------------------

def _ps_field(pid: int, field: str):
    try:
        r = subprocess.run(["ps", "-p", str(pid), "-o", field + "="],
                           capture_output=True, text=True, timeout=2)
        if r.returncode != 0:
            return None
        return r.stdout.strip()
    except Exception:
        return None


_CLAUDEISH = re.compile(r"node.*claude|bun.*claude")


def _looks_claude(cmd: str) -> bool:
    if not cmd:
        return False
    first = cmd.split()[0]
    if first == "claude" or first.endswith("/claude"):
        return True
    return bool(_CLAUDEISH.search(cmd))


def find_claude_pid():
    """PID of the owning claude process, or None. Honors the test seam
    (SUPERVISOR_TEST_MODE=1 + SUPERVISOR_FAKE_CLAUDE_PID)."""
    if (os.environ.get("SUPERVISOR_TEST_MODE") == "1"
            and os.environ.get("SUPERVISOR_FAKE_CLAUDE_PID")):
        try:
            return int(os.environ["SUPERVISOR_FAKE_CLAUDE_PID"])
        except ValueError:
            return None
    pid = os.getpid()
    for _ in range(15):
        raw = _ps_field(pid, "ppid")
        if not raw:
            return None
        try:
            ppid = int(raw)
        except ValueError:
            return None
        if ppid <= 1:
            return None
        cmd = _ps_field(ppid, "command")
        if cmd and _looks_claude(cmd):
            return ppid
        pid = ppid
    return None


# ---------------------------------------------------------------------------
# config (design 4.4)
# ---------------------------------------------------------------------------

CONFIG_DEFAULTS = {
    "v": 1,
    "capture_reads": True,
    "capture_commands": True,
    "capture_subagents": True,
    "git_snapshots": True,
    "digest_enabled": True,
    "digest_max_tokens": 400,
    "awake": "auto",
    "auto_resume": False,
    "resume_max_attempts": 4,
    "resume_min_gap_hours": 5,
    "resume_max_minutes": 30,
    "resume_extra_args": [],
    "notify": True,
    "telemetry": True,
    "debug": False,
}

PROTECTED_KEYS = frozenset((
    "auto_resume", "resume_extra_args", "resume_max_attempts",
    "resume_min_gap_hours", "resume_max_minutes"))

_BOOL_KEYS = frozenset((
    "capture_reads", "capture_commands", "capture_subagents", "git_snapshots",
    "digest_enabled", "auto_resume", "notify", "telemetry", "debug"))
_INT_KEYS = frozenset(("v", "digest_max_tokens", "resume_max_attempts"))
_NUM_KEYS = frozenset(("resume_min_gap_hours", "resume_max_minutes"))
_STR_KEYS = frozenset(("awake",))
_LIST_KEYS = frozenset(("resume_extra_args",))


def _valid_type(key: str, value) -> bool:
    if key in _BOOL_KEYS:
        return isinstance(value, bool)
    if key in _INT_KEYS:
        return isinstance(value, int) and not isinstance(value, bool)
    if key in _NUM_KEYS:
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if key in _STR_KEYS:
        return isinstance(value, str)
    if key in _LIST_KEYS:
        return isinstance(value, list) and all(isinstance(x, str) for x in value)
    return False


def _fresh_defaults() -> dict:
    return {k: (list(v) if isinstance(v, list) else v)
            for k, v in CONFIG_DEFAULTS.items()}


def load_config() -> dict:
    """Defaults shallow-updated by <data>/config.json; unknown keys ignored;
    wrong-typed values replaced by defaults (per-key isinstance)."""
    cfg = _fresh_defaults()
    try:
        base = data_dir(for_hook=False)
    except Exception:
        return cfg
    try:
        with open(os.path.join(base, "config.json"), "r",
                  encoding="utf-8", errors="replace") as f:
            raw = json.load(f)
    except Exception:
        return cfg
    if isinstance(raw, dict):
        for k, v in raw.items():
            if k in CONFIG_DEFAULTS and _valid_type(k, v):
                cfg[k] = v
    return cfg


def save_config(d: dict) -> None:
    """Whitelist + type-validate, then atomic_write config.json. Protected-key
    gating is config_set's job, not save's."""
    cfg = {}
    src = d if isinstance(d, dict) else {}
    for k, dv in CONFIG_DEFAULTS.items():
        v = src.get(k, dv)
        cfg[k] = v if _valid_type(k, v) else (list(dv) if isinstance(dv, list) else dv)
    base = data_dir(for_hook=False)
    os.makedirs(base, mode=0o700, exist_ok=True)
    try:
        os.chmod(base, 0o700)
    except OSError:
        pass
    atomic_write(os.path.join(base, "config.json"),
                 json.dumps(cfg, indent=2, sort_keys=True) + "\n")


EXTRA_ARG_FLAGS = frozenset((
    "--plugin-dir", "--settings", "--add-dir", "--model", "--fallback-model"))
_EXTRA_ARG_REJECT = re.compile(r"(?i)dangerous|permission|bypass|allowedtools|mcp-config")  # LINT-ALLOW


def validate_extra_args(args) -> None:
    """Hard whitelist for resume_extra_args (design 4.4, critic SEC-02):
    only the allow-set flags, each followed by exactly one value; any token
    matching the rejector pattern refuses the whole set."""
    if not isinstance(args, list):
        raise ConfigRefused("resume_extra_args must be a JSON list of strings")
    for tok in args:
        if not isinstance(tok, str):
            raise ConfigRefused("resume_extra_args entries must be strings")
        if _EXTRA_ARG_REJECT.search(tok):
            raise ConfigRefused("refused token in resume_extra_args: %s" % tok)
    if len(args) % 2 != 0:
        raise ConfigRefused(
            "resume_extra_args must be flag/value pairs (odd token count)")
    for i in range(0, len(args), 2):
        if args[i] not in EXTRA_ARG_FLAGS:
            raise ConfigRefused("flag not in the resume_extra_args allow-set: %s"
                                % args[i])
        if not args[i + 1]:
            raise ConfigRefused("empty value for %s" % args[i])


def config_set(key: str, value, ack: bool = False) -> None:
    """Whitelisted, type-checked config write; protected keys need ack=True
    (the --i-understand-quota-spend flag)."""
    if key == "v" or key not in CONFIG_DEFAULTS:
        raise ConfigRefused("unknown config key: %s" % key)
    if key in PROTECTED_KEYS and not ack:
        raise ConfigRefused(
            "%s is protected: unattended runs spend your quota with nobody "
            "watching. Re-run with --i-understand-quota-spend to change it."
            % key)
    if key == "resume_extra_args":
        validate_extra_args(value)
    if not _valid_type(key, value):
        raise ConfigRefused("wrong type for %s (want %s)" % (
            key, type(CONFIG_DEFAULTS[key]).__name__))
    cfg = load_config()
    cfg[key] = value
    save_config(cfg)


# ---------------------------------------------------------------------------
# event IO (CT-10 line budget, design 8.3 single-write append)
# ---------------------------------------------------------------------------

MAX_EVENT_BYTES = 4096


def _event_bytes(obj):
    """One \\n-terminated UTF-8 line, degraded deterministically to fit CT-10:
    drop git.uh, then git.dh (counts stay), then drop the event (None)."""
    def enc(o):
        return (json.dumps(o, separators=(",", ":"), ensure_ascii=False)
                + "\n").encode("utf-8")
    data = enc(obj)
    if len(data) <= MAX_EVENT_BYTES:
        return data
    slim = dict(obj)
    git = slim.get("git")
    if isinstance(git, dict):
        git = dict(git)
        slim["git"] = git
        for drop in ("uh", "dh"):
            if drop in git:
                del git[drop]
                data = enc(slim)
                if len(data) <= MAX_EVENT_BYTES:
                    return data
    return None


def append_event(path: str, obj: dict) -> None:
    """Append one event as ONE os.write on an O_APPEND 0600 fd, guarding a
    torn tail (last byte not \\n -> prefix one \\n so the new event never
    merges into a dead writer's fragment)."""
    data = _event_bytes(obj)
    if data is None:
        return  # oversized even after degradation: dropped, never torn
    # O_RDWR (not O_WRONLY as design 8.3 sketches): pread on a write-only fd
    # is EBADF on macOS/Linux, and the torn-tail guard needs that one read.
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        st = os.fstat(fd)
        if st.st_size > 0:
            last = os.pread(fd, 1, st.st_size - 1)
            if last != b"\n":
                data = b"\n" + data
        os.write(fd, data)
    finally:
        os.close(fd)


def read_events(paths, max_bytes_per_file=8 * 2 ** 20):
    """Tolerant tail-bounded JSONL reader: last max_bytes_per_file of each
    file, first partial line dropped, undecodable/garbage lines skipped."""
    out = []
    for p in paths:
        try:
            size = os.path.getsize(p)
        except OSError:
            continue
        try:
            with open(p, "rb") as f:
                if size > max_bytes_per_file:
                    f.seek(size - max_bytes_per_file)
                    blob = f.read(max_bytes_per_file)
                    nl = blob.find(b"\n")
                    blob = blob[nl + 1:] if nl >= 0 else b""
                else:
                    blob = f.read()
        except OSError:
            continue
        for line in blob.split(b"\n"):
            if not line.strip():
                continue
            try:
                obj = json.loads(line.decode("utf-8"))
            except Exception:
                continue
            if isinstance(obj, dict):
                out.append(obj)
    return out


def atomic_write(path: str, text) -> None:
    """Same-dir 0600 temp (O_CREAT|O_EXCL) -> os.replace; temp unlinked on any
    failure so no partial secret-bearing residue remains (design 4.1)."""
    d = os.path.dirname(path) or "."
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
            os.write(fd, text.encode("utf-8") if isinstance(text, str) else text)
        finally:
            os.close(fd)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# sanitize helpers (design 11.2 layer 1, CT-11, 11.3, 10.4)
# ---------------------------------------------------------------------------

_ANSI_CSI = re.compile(r"\x1b\[[0-9;:?]*[ -/]*[@-~]")
_ANSI_OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
# All C0 controls except \n (handled by escape_newlines), plus DEL and C1.
_CTRL = re.compile("[\\x00-\\x09\\x0b-\\x1f\\x7f\\u0080-\\u009f]")
_ZERO_WIDTH = re.compile(
    "[\\u200b-\\u200f\\u2028\\u2029\\u202a-\\u202e"
    "\\u2060-\\u2064\\u2066-\\u2069\\ufeff]")


def strip_controls(s: str) -> str:
    """Strip ANSI/OSC escapes, C0 (\\t -> two spaces, \\r removed, \\n kept
    for escape_newlines), C1, zero-width and bidi controls (design 11.2)."""
    s = _ANSI_CSI.sub("", s)
    s = _ANSI_OSC.sub("", s)
    s = s.replace("\t", "  ")
    s = _CTRL.sub("", s)
    s = _ZERO_WIDTH.sub("", s)
    return s


def escape_newlines(s: str) -> str:
    """CT-11: \\r\\n / \\r / \\n all become the two-character sequence \\n so
    no stored string ever contains a raw newline."""
    return s.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n")


_FENCE_BACKTICKS = re.compile(r"`{3,}")
_FENCE_TILDES = re.compile(r"~{3,}")


def fence_escape(s: str) -> str:
    """Design 11.3: any run of >=3 backticks -> two backticks, >=3 tildes ->
    two tildes (a 2-char run can never open or close a fence)."""
    return _FENCE_TILDES.sub("~~", _FENCE_BACKTICKS.sub("``", s))


def cap_path(s: str, n: int = 240) -> str:
    """Design 10.4: cap at n chars as first half + ellipsis + trailing rest
    (240 -> first 120 + … + last 119)."""
    if len(s) <= n:
        return s
    head = n // 2
    tail = n - head - 1
    if tail <= 0:
        return s[:n]
    return s[:head] + "…" + s[-tail:]


def estimate_tokens(s: str) -> int:
    """ceil(len(s)/4) (CT-4's 4-chars-per-token model)."""
    return (len(s) + 3) // 4


# ---------------------------------------------------------------------------
# resume state machine (v0.3, design 13.5/13.6)
#
# Pure data operations on <base>/resume/ (CT-6). The shell orchestrators
# (hook-stop-failure.sh arms; resume-sleeper.sh fires) call these subcommands
# so the CT-6 pending schema, the ledger, the mutex, and the wake schedule live
# in one testable place. Every op resolves the store in HOOK context (CT-12) so
# the DETACHED sleeper works with only CLAUDE_PLUGIN_DATA (or the test seam) in
# its inherited environment. The pending/ledger shapes here MUST stay in step
# with maintain.py (_resume_cleanup/forget) and supervisorctl.sh status.
# ---------------------------------------------------------------------------

RESUME_PAD = 90                    # CT-7 fixed pad past reset (deterministic, no jitter)
FRESH_TELEMETRY_S = 6 * 3600       # rate_limits.json validity window (design 13.5)
SEVEN_DAY_MAX_S = 26 * 3600        # only schedule a 7d reset if it is < 26 h out
WINDOW_BUCKET_S = 18000            # 5 h ledger buckets when resets_at is unknown
DEFAULT_LADDER = (1800, 3600, 7200, 14400)   # CT-7: +30/+60/+120/+240 min


def _resume_dir(base: str) -> str:
    return os.path.join(base, "resume")


def resume_ladder():
    """Backoff ladder in seconds. SUPERVISOR_RESUME_LADDER overrides ONLY under
    SUPERVISOR_TEST_MODE=1 (CT-13); production is always DEFAULT_LADDER."""
    if os.environ.get("SUPERVISOR_TEST_MODE") == "1":
        raw = os.environ.get("SUPERVISOR_RESUME_LADDER")
        if raw:
            try:
                vals = [int(x) for x in raw.split(",") if x.strip() != ""]
                if vals:
                    return vals
            except Exception:
                pass
    return list(DEFAULT_LADDER)


def pid_alive(pid) -> bool:
    """True iff pid names a live process. Never treats 0/negative as alive
    (kill(0, ...) would signal the whole group)."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def resume_schedule(base: str, detail: str, now_ts: int):
    """Choose the wake schedule (design 13.5). Returns
    (mode, due, window_key, file_due):
      'epoch'  -> due = resets_at + 90; the sleeper wakes at `due`.
      'ladder' -> due = None; the sleeper walks its own backoff ladder.
      'skip'   -> telemetry is fresh but names no usable window: notify, no arm.
    Primary source is telemetry/rate_limits.json (fresh <=6 h). Fallbacks: an
    opportunistic 10-digit epoch parsed out of `error_details`, else the ladder
    (FACTS 1.6: the StopFailure payload has no reset timestamp)."""
    rl = os.path.join(base, "telemetry", "rate_limits.json")
    data = None
    try:
        with open(rl, "r", encoding="utf-8", errors="replace") as f:
            data = json.load(f)
    except Exception:
        data = None
    fresh = False
    if isinstance(data, dict):
        ts = data.get("ts")
        if (isinstance(ts, (int, float)) and not isinstance(ts, bool)
                and -300 <= (now_ts - ts) <= FRESH_TELEMETRY_S):
            fresh = True
    if fresh:
        def _resets(win):
            w = data.get(win)
            r = w.get("resets_at") if isinstance(w, dict) else None
            if isinstance(r, (int, float)) and not isinstance(r, bool):
                return int(r)
            return None
        fr = _resets("five_hour")
        if fr is not None and fr > now_ts:
            return ("epoch", fr + RESUME_PAD, str(fr), fr + RESUME_PAD)
        sr = _resets("seven_day")
        if sr is not None and now_ts < sr < now_ts + SEVEN_DAY_MAX_S:
            return ("epoch", sr + RESUME_PAD, str(sr), sr + RESUME_PAD)
        return ("skip", None, "", None)   # fresh but no window worth a surprise resume
    m = re.search(r"resets?[ _-]?at[^0-9]*([0-9]{10})", detail or "")
    if m:
        r = int(m.group(1))
        if r > now_ts:
            return ("epoch", r + RESUME_PAD, str(r), r + RESUME_PAD)
    ladder = resume_ladder()
    return ("ladder", None, str(now_ts // WINDOW_BUCKET_S), now_ts + ladder[0])


def _kv(args):
    """Parse a flat `--key value` / bare `--flag` argv into a dict. A flag with
    no following value (or whose next token is itself a --flag) maps to 'true'."""
    out = {}
    i = 0
    n = len(args)
    while i < n:
        a = args[i]
        if a.startswith("--"):
            k = a[2:]
            if i + 1 < n and not args[i + 1].startswith("--"):
                out[k] = args[i + 1]
                i += 2
            else:
                out[k] = "true"
                i += 1
        else:
            i += 1
    return out


def _resume_base_or(exc_code):
    """data_dir(for_hook=True) or None; callers map None to their own exit."""
    try:
        return data_dir(for_hook=True)
    except Exception:
        return None


def _cmd_resume_arm_check() -> int:
    """exit 0 = clear to arm; 3 = a live sleeper is already armed (or no store)."""
    base = _resume_base_or(3)
    if base is None:
        return 3
    pend = os.path.join(_resume_dir(base), "pending")
    try:
        names = os.listdir(pend)
    except OSError:
        return 0
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(pend, name), "r", encoding="utf-8",
                      errors="replace") as f:
                obj = json.load(f)
            if isinstance(obj, dict) and pid_alive(obj.get("pid")):
                return 3
        except Exception:
            continue
    return 0


def _cmd_resume_schedule() -> int:
    base = _resume_base_or(1)
    if base is None:
        return 1
    try:
        detail = sys.stdin.read()
    except Exception:
        detail = ""
    mode, due, wkey, file_due = resume_schedule(base, detail, now())
    if mode == "skip":
        sys.stdout.write("MODE=skip\n")
        return 0
    due_arg = "ladder" if mode == "ladder" else str(due)
    sys.stdout.write("MODE=%s DUE=%s WKEY=%s FILEDUE=%s\n"
                     % (mode, due_arg, wkey, file_due))
    return 0


def _cmd_resume_write_pending(args) -> int:
    opts = _kv(args)
    base = _resume_base_or(1)
    if base is None:
        return 1
    try:
        pend = os.path.join(_resume_dir(base), "pending")
        os.makedirs(pend, mode=0o700, exist_ok=True)
        s = safe_sid(opts.get("session", ""))
        obj = {
            "v": 1,
            "pid": int(opts.get("pid", "0") or 0),
            "due": int(opts.get("due", "0") or 0),
            "session": s,
            "cwd": opts.get("cwd", ""),
            "created": now(),
            "window_key": opts.get("wkey", ""),
            "attempt": int(opts.get("attempt", "1") or 1),
        }
        path = os.path.join(pend, s + ".json")
        atomic_write(path, json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.write(path + "\n")
        return 0
    except Exception:
        return 1


def _cmd_resume_acquire_lock(args) -> int:
    """exit 0 = mutex acquired; 3 = another sleeper holds it (design 13.6.3)."""
    opts = _kv(args)
    base = _resume_base_or(3)
    if base is None:
        return 3
    rdir = _resume_dir(base)
    try:
        os.makedirs(rdir, mode=0o700, exist_ok=True)
    except OSError:
        return 3
    lock = os.path.join(rdir, "attempt.lock")
    try:
        mm = float(opts.get("max-minutes", "30") or 30)
    except ValueError:
        mm = 30.0
    # Break a stale lock (design U7.5): staleness is REAL elapsed time vs the
    # file mtime, never the SUPERVISOR_NOW seam (which can sit years off).
    try:
        if os.path.exists(lock) and (time.time() - os.path.getmtime(lock)) > (mm + 5) * 60:
            os.unlink(lock)
    except OSError:
        pass
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except (FileExistsError, OSError):
        return 3
    try:
        os.write(fd, ("%d %d\n" % (os.getpid(), now())).encode())
    finally:
        os.close(fd)
    return 0


def _cmd_resume_release_lock() -> int:
    base = _resume_base_or(0)
    if base is None:
        return 0
    try:
        os.unlink(os.path.join(_resume_dir(base), "attempt.lock"))
    except OSError:
        pass
    return 0


def _cmd_resume_window_check(args) -> int:
    """exit 0 = proceed; 3 = a successful resume already covers this window or
    fell inside the min-gap fuse (design 13.6.3)."""
    opts = _kv(args)
    wkey = opts.get("wkey", "")
    try:
        gap_h = float(opts.get("min-gap-hours", "5") or 5)
    except ValueError:
        gap_h = 5.0
    base = _resume_base_or(3)
    if base is None:
        return 3
    state = os.path.join(_resume_dir(base), "state.json")
    attempts = []
    try:
        with open(state, "r", encoding="utf-8", errors="replace") as f:
            obj = json.load(f)
        if isinstance(obj, dict) and isinstance(obj.get("attempts"), list):
            attempts = obj["attempts"]
    except Exception:
        attempts = []
    now_ts = now()
    for a in attempts:
        if not isinstance(a, dict) or not a.get("ok"):
            continue
        if wkey != "" and str(a.get("window_key", "")) == wkey:
            return 3
        ts = a.get("ts", 0)
        if (isinstance(ts, (int, float)) and not isinstance(ts, bool)
                and (now_ts - ts) < gap_h * 3600):
            return 3
    return 0


def _cmd_resume_ledger(args) -> int:
    opts = _kv(args)
    base = _resume_base_or(1)
    if base is None:
        return 1
    rdir = _resume_dir(base)
    try:
        os.makedirs(rdir, mode=0o700, exist_ok=True)
    except OSError:
        return 1
    state = os.path.join(rdir, "state.json")
    obj = {"v": 1, "attempts": []}
    try:
        with open(state, "r", encoding="utf-8", errors="replace") as f:
            cur = json.load(f)
        if isinstance(cur, dict) and isinstance(cur.get("attempts"), list):
            obj = cur
    except Exception:
        obj = {"v": 1, "attempts": []}
    entry = {
        "ts": now(),
        "ok": (opts.get("ok", "false") == "true"),
        "window_key": opts.get("wkey", ""),
        "session": safe_sid(opts.get("session", "")),
        "attempt": int(opts.get("attempt", "1") or 1),
    }
    if opts.get("fatal") == "true":
        entry["fatal"] = True
    if opts.get("reason"):
        entry["reason"] = opts.get("reason")
    obj.setdefault("attempts", []).append(entry)
    try:
        atomic_write(state, json.dumps(obj, separators=(",", ":")) + "\n")
        return 0
    except Exception:
        return 1


def _cmd_resume_config() -> int:
    """Print the three resume knobs in one eval-able line, so the sleeper reads
    config with ONE python spawn instead of three (per-fire latency, and every
    subprocess counts on a slow interpreter)."""
    cfg = load_config()
    ma = cfg.get("resume_max_attempts", 4)
    mg = cfg.get("resume_min_gap_hours", 5)
    mm = cfg.get("resume_max_minutes", 30)
    sys.stdout.write("MAXATT=%s MINGAP=%s MAXMIN=%s\n" % (_fmt(ma), _fmt(mg), _fmt(mm)))
    return 0


def _cmd_resume_event(args) -> int:
    opts = _kv(args)
    try:
        pdir = project_dir(opts.get("cwd", ""), for_hook=True)
        append_event(os.path.join(pdir, "events.jsonl"),
                     {"v": 1, "ts": now(), "s": safe_sid(opts.get("session", "")),
                      "k": "resume"})
        return 0
    except Exception:
        return 1


# ---------------------------------------------------------------------------
# CLI (for guard.sh sup_cfg, hook entrypoints, supervisorctl, tests)
# ---------------------------------------------------------------------------

def _fmt(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (list, dict)):
        return json.dumps(v, separators=(",", ":"))
    return str(v)


def _sq(s: str) -> str:
    """Single-quote s for safe consumption by sh eval."""
    return "'" + s.replace("'", "'\\''") + "'"


def _cmd_stdin_vars() -> int:
    try:
        payload = json.loads(sys.stdin.read())
        if not isinstance(payload, dict):
            return 0
        sid = safe_sid(str(payload.get("session_id") or ""))
        src = str(payload.get("source") or "")
        cwd = str(payload.get("cwd") or "")
        line = "SID=%s SRC=%s CWD=%s" % (_sq(sid), _sq(src), _sq(cwd))
        # StopFailure carries `error`/`error_details`; expose them for
        # hook-stop-failure.sh (design 13.5). The keys are ABSENT on
        # SessionStart/Stop payloads, so the plain SID/SRC/CWD line stays
        # byte-identical there (test_common.test_stdin_vars_plain).
        if "error" in payload:
            err = str(payload.get("error") or "")
            detail = str(payload.get("error_details") or "")
            line += " ERR=%s DETAIL=%s" % (_sq(err), _sq(detail))
        sys.stdout.write(line + "\n")
    except Exception:
        pass  # silent: hooks treat missing vars as "skip"
    return 0


def _parse_cli_value(raw: str):
    try:
        return json.loads(raw)
    except Exception:
        return raw


def main(argv=None) -> int:
    os.umask(0o077)
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "key":
        if len(args) != 1:
            return 2
        try:
            sys.stdout.write(project_key(args[0])[0] + "\n")
            return 0
        except Exception:
            return 1
    if cmd == "cfg":
        if len(args) != 2:
            return 2
        key, default = args
        try:
            cfg = load_config()
            sys.stdout.write((_fmt(cfg[key]) if key in cfg else default) + "\n")
        except Exception:
            sys.stdout.write(default + "\n")
        return 0
    if cmd == "stdin-vars":
        return _cmd_stdin_vars()
    if cmd == "safe-sid":
        if len(args) != 1:
            return 2
        sys.stdout.write(safe_sid(args[0]) + "\n")
        return 0
    if cmd == "resume-arm-check":
        return _cmd_resume_arm_check()
    if cmd == "resume-schedule":
        return _cmd_resume_schedule()
    if cmd == "resume-write-pending":
        return _cmd_resume_write_pending(args)
    if cmd == "resume-acquire-lock":
        return _cmd_resume_acquire_lock(args)
    if cmd == "resume-release-lock":
        return _cmd_resume_release_lock()
    if cmd == "resume-window-check":
        return _cmd_resume_window_check(args)
    if cmd == "resume-ledger":
        return _cmd_resume_ledger(args)
    if cmd == "resume-config":
        return _cmd_resume_config()
    if cmd == "resume-event":
        return _cmd_resume_event(args)
    if cmd == "config-list":
        try:
            sys.stdout.write(
                json.dumps(load_config(), indent=2, sort_keys=True) + "\n")
            return 0
        except Exception:
            return 1
    if cmd == "config-get":
        if len(args) != 1:
            return 2
        try:
            cfg = load_config()
            if args[0] not in cfg:
                return 2
            sys.stdout.write(_fmt(cfg[args[0]]) + "\n")
            return 0
        except Exception:
            return 1
    if cmd == "config-set":
        ack = "--i-understand-quota-spend" in args
        rest = [a for a in args if a != "--i-understand-quota-spend"]
        if len(rest) != 2:
            return 2
        try:
            config_set(rest[0], _parse_cli_value(rest[1]), ack=ack)
            sys.stdout.write(_fmt(load_config()[rest[0]]) + "\n")
            return 0
        except ConfigRefused as e:
            sys.stderr.write("refused: %s\n" % e)
            return 4
        except (DataDirRefused, DataDirUnset) as e:
            sys.stderr.write("refused: data dir: %s\n" % e)
            return 4
        except Exception:
            return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
