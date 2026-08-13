#!/bin/sh
# supervisorctl.sh - U16 human/skill-facing CLI (design 4.1/11.3/U16, CT-12/CT-16).
#
# This is NOT a hook: it must report real exit codes and real errors, so it does
# NOT source lib/guard.sh (which traps 'exit 0' and silences stderr). The five
# skills invoke it via the Bash tool, always with a leading
#   --data-dir "${CLAUDE_PLUGIN_DATA}"
# because the Bash tool never receives CLAUDE_PLUGIN_DATA (design 4.1.3).
#
# Exit codes (design U16): 0 ok | 2 usage | 3 confirmation-required | 4 refused.
#
# recap/log/report delegate to scripts/py/digest.py print (all output flows the
# 11.3 sanitize + fence-escape + factual-header path). config delegates to
# supervisor_common.py config-*. forget (CT-16) and status run as embedded
# python here (self-contained; they use supervisor_common helpers only). The
# forget deletion logic lives here rather than in maintain.py to keep maintain.py
# sweep-only per design U7 (gate advisory) and to keep the whole CT-16 scope in
# the single unit that owns /supervisor:forget.
set -u

SUP_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
PY_DIR="$SUP_ROOT/scripts/py"

usage() {
  cat >&2 <<'EOF'
usage: supervisorctl.sh [--data-dir <path>] <command> [args]

  recap [--full]                     print the digest for this project
  report                             alias for recap --full
  log [N]                            print the last N events (default 20)
  forget [--all] [--yes]             delete this project's history (CT-16)
  config list                        show all settings
  config get KEY                     show one setting
  config set KEY VALUE [--i-understand-quota-spend]
  status                             data dir, config, locks, sleepers, statusline
EOF
}

PY=$(command -v python3 2>/dev/null)
if [ -z "$PY" ]; then
  echo "supervisorctl: python3 not found; the supervisor CLI is unavailable" >&2
  exit 1
fi

# --- optional leading --data-dir <path> (design 4.1 branch 3) ----------------
# The value is carried to every delegated python via CLAUDE_PLUGIN_DATA, which
# supervisor_common.data_dir(for_hook=False) resolves at highest precedence.
# Containment (design 4.1 / critic SEC-06) is enforced HERE at the CLI boundary
# using supervisor_common.containment_ok before the value is trusted: a path
# inside CLAUDE_PROJECT_DIR, $PWD, or any git worktree is refused (exit 4).
if [ "${1:-}" = "--data-dir" ]; then
  shift
  DATADIR="${1:-}"
  if [ -z "$DATADIR" ]; then
    echo "supervisorctl: --data-dir requires a path" >&2
    exit 2
  fi
  shift
  if PYTHONPATH="$PY_DIR" "$PY" -c 'import sys,supervisor_common as sc; sys.exit(0 if sc.containment_ok(sys.argv[1]) else 1)' "$DATADIR" 2>/dev/null; then
    CLAUDE_PLUGIN_DATA="$DATADIR"
    export CLAUDE_PLUGIN_DATA
  else
    echo "supervisorctl: refused data dir (must not live inside a project or git worktree): $DATADIR" >&2
    exit 4
  fi
fi

# ---------------------------------------------------------------------------
# embedded python: forget (CT-16) and status (U16). Assigned with single quotes
# so the body is literal; it therefore contains NO single quote and NO $.
# argv: forget -> [cwd, all(0/1), yes(0/1)] ; status -> [cwd].
# ---------------------------------------------------------------------------
forget_py='
import sys, os, json, glob, shutil, signal, subprocess
import supervisor_common as sc

cwd = sys.argv[1]
do_all = sys.argv[2] == "1"
do_yes = sys.argv[3] == "1"

try:
    base = sc.data_dir(for_hook=False)
except sc.DataDirRefused:
    sys.stderr.write("refused: data dir failed the containment check\n")
    sys.exit(4)
except Exception as e:
    sys.stderr.write("refused: data dir: %s\n" % e)
    sys.exit(4)

def under(*parts):
    return os.path.join(base, *parts)

# ----- forget --all -----
if do_all:
    if not do_yes:
        sys.stdout.write("DRY RUN - supervisor forget --all\n")
        sys.stdout.write("WILL DELETE the ENTIRE supervisor data dir:\n")
        sys.stdout.write("  %s\n" % base)
        sys.stdout.write("This erases EVERY project history, ALL telemetry\n")
        sys.stdout.write("(including account-scoped telemetry/rate_limits.json),\n")
        sys.stdout.write("all resume state, and your config.json.\n")
        sys.stdout.write("Re-run with: forget --all --yes\n")
        sys.exit(3)
    if os.path.isdir(base):
        shutil.rmtree(base, ignore_errors=True)
    sys.stdout.write("Deleted the entire supervisor data dir: %s\n" % base)
    sys.exit(0)

# ----- per-project forget -----
key, src = sc.project_key(cwd)
proj = under("projects", key)

sids = []
try:
    with open(os.path.join(proj, "sessions.index"), "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if s and s not in sids:
                sids.append(s)
except Exception:
    pass

# pending sleepers to remove: those named for one of this project sids OR whose
# recorded cwd keys to this project (design U16 both clauses).
pend_targets = []   # (path, pid)
pend_dir = under("resume", "pending")
try:
    for name in sorted(os.listdir(pend_dir)):
        if not name.endswith(".json"):
            continue
        fp = os.path.join(pend_dir, name)
        pid = None
        pcwd = None
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as f:
                d = json.load(f)
            if isinstance(d, dict):
                pid = d.get("pid")
                pcwd = d.get("cwd")
        except Exception:
            pass
        keyed = name[:-5] in sids
        if not keyed and isinstance(pcwd, str) and pcwd:
            try:
                keyed = sc.project_key(pcwd)[0] == key
            except Exception:
                keyed = False
        if keyed:
            pend_targets.append((fp, pid))
except Exception:
    pass

# telemetry + awake targets that actually exist, for an honest dry-run listing.
tele_targets = []
lock_targets = []
for s in sids:
    tp = under("telemetry", "sessions", s + ".json")
    if os.path.exists(tp):
        tele_targets.append(tp)
    lp = under("awake", s + ".lock")
    if os.path.exists(lp):
        lock_targets.append(lp)

debug_log = under("logs", "debug.log")
ledger = under("resume", "state.json")

if not do_yes:
    sys.stdout.write("DRY RUN - supervisor forget (project %s)\n" % key)
    sys.stdout.write("project source: %s\n" % src)
    sys.stdout.write("WILL DELETE:\n")
    sys.stdout.write("  %s/  (events, digests, reports, sessions.index, meta)\n" % proj)
    for tp in tele_targets:
        sys.stdout.write("  %s\n" % tp)
    for lp in lock_targets:
        sys.stdout.write("  %s\n" % lp)
    for fp, _pid in pend_targets:
        sys.stdout.write("  %s  (armed sleeper - its process is signalled first)\n" % fp)
    if sids:
        sys.stdout.write("  attempts for %d session id(s) filtered out of %s\n" % (len(sids), ledger))
    if os.path.exists(debug_log):
        sys.stdout.write("  %s  (truncated to empty)\n" % debug_log)
    sys.stdout.write("WILL NOT DELETE:\n")
    sys.stdout.write("  %s  (account-scoped, shared across all projects)\n" % under("telemetry", "rate_limits.json"))
    sys.stdout.write("  any OTHER project under %s\n" % under("projects"))
    sys.stdout.write("Re-run with: forget --yes\n")
    sys.exit(3)

# ----- execute (--yes) -----
def sigterm_verified(pid):
    # SIGTERM a sleeper before deleting its pending file, but ONLY when the pid
    # is alive AND its command still looks like our resume infrastructure, so a
    # recycled/unrelated pid is never signalled (design U16 comm-verified).
    try:
        pid = int(pid)
    except Exception:
        return
    if pid <= 1:
        return
    try:
        os.kill(pid, 0)
    except Exception:
        return
    cmd = ""
    try:
        r = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2)
        cmd = r.stdout.decode("utf-8", "replace").strip().lower()
    except Exception:
        cmd = ""
    if ("supervisor" in cmd) or ("resume" in cmd):
        try:
            os.kill(pid, signal.SIGTERM)
        except Exception:
            pass

def unlink(path):
    try:
        os.unlink(path)
    except Exception:
        pass

for fp, pid in pend_targets:
    if pid is not None:
        sigterm_verified(pid)
    unlink(fp)
for tp in tele_targets:
    unlink(tp)
for lp in lock_targets:
    unlink(lp)

# filter this project sids out of the resume ledger
if sids:
    try:
        with open(ledger, "r", encoding="utf-8", errors="replace") as f:
            led = json.load(f)
    except Exception:
        led = None
    if isinstance(led, dict) and isinstance(led.get("attempts"), list):
        sidset = set(sids)
        kept = [a for a in led["attempts"]
                if not (isinstance(a, dict) and str(a.get("session")) in sidset)]
        if len(kept) != len(led["attempts"]):
            led["attempts"] = kept
            try:
                sc.atomic_write(ledger, json.dumps(led, separators=(",", ":")) + "\n")
            except Exception:
                pass

# remove the project store
if os.path.isdir(proj):
    shutil.rmtree(proj, ignore_errors=True)

# truncate debug.log to zero (kept, not removed)
if os.path.exists(debug_log):
    try:
        fd = os.open(debug_log, os.O_WRONLY | os.O_TRUNC)
        os.close(fd)
    except Exception:
        pass

sys.stdout.write("Deleted supervisor history for project %s.\n" % key)
sys.stdout.write("Kept: telemetry/rate_limits.json and all other projects.\n")
sys.exit(0)
'

status_py='
import sys, os, json, glob, time
import supervisor_common as sc

cwd = sys.argv[1]
try:
    base = sc.data_dir(for_hook=False)
except sc.DataDirRefused:
    sys.stderr.write("refused: data dir failed the containment check\n")
    sys.exit(4)
except Exception as e:
    sys.stderr.write("refused: data dir: %s\n" % e)
    sys.exit(4)

def size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0

def fmt_ts(v):
    try:
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(int(v)))
    except Exception:
        return str(v)

out = sys.stdout.write
out("Supervisor status\n")
out("data dir: %s\n" % base)

key, src = sc.project_key(cwd)
out("project:  %s\n" % key)
out("source:   %s\n" % src)

proj = os.path.join(base, "projects", key)
events = os.path.join(proj, "events.jsonl")
nev = 0
try:
    with open(events, "rb") as f:
        for _ln in f:
            nev += 1
except Exception:
    pass
out("store:    events=%d line(s), events.jsonl=%dB, digest.md=%dB\n" % (
    nev, size(events), size(os.path.join(proj, "digest.md"))))
reports = sorted(glob.glob(os.path.join(proj, "reports", "*.md")))
out("report:   %s\n" % (reports[-1] if reports else "(none)"))

cfg = sc.load_config()
def b(k):
    return str(bool(cfg.get(k))).lower()
out("config:   awake=%s auto_resume=%s telemetry=%s digest_enabled=%s capture_commands=%s capture_reads=%s\n" % (
    cfg.get("awake"), b("auto_resume"), b("telemetry"), b("digest_enabled"),
    b("capture_commands"), b("capture_reads")))

locks = sorted(glob.glob(os.path.join(base, "awake", "*.lock")))
if locks:
    out("awake locks:\n")
    for lp in locks:
        mode = None
        hpid = None
        try:
            with open(lp, "r", encoding="utf-8", errors="replace") as f:
                d = json.load(f)
            if isinstance(d, dict):
                mode = d.get("mode")
                hpid = d.get("holder_pid")
        except Exception:
            pass
        out("  %s mode=%s holder_pid=%s\n" % (os.path.basename(lp)[:-5], mode, hpid))
else:
    out("awake locks: none\n")

pend = sorted(glob.glob(os.path.join(base, "resume", "pending", "*.json")))
if pend:
    out("armed sleepers:\n")
    for pp in pend:
        pid = None
        due = None
        try:
            with open(pp, "r", encoding="utf-8", errors="replace") as f:
                d = json.load(f)
            if isinstance(d, dict):
                pid = d.get("pid")
                due = d.get("due")
        except Exception:
            pass
        out("  %s pid=%s due=%s\n" % (os.path.basename(pp)[:-5], pid, fmt_ts(due) if due is not None else "?"))
else:
    out("armed sleepers: none\n")

bindir = os.path.join(base, "bin")
copy = os.path.join(bindir, "supervisor-statusline.sh")
if os.path.exists(copy):
    if os.path.exists(os.path.join(bindir, ".stale")):
        out("statusline copy: outdated - rerun /supervisor:statusline\n")
    else:
        out("statusline copy: installed (%s)\n" % copy)
else:
    out("statusline copy: not installed\n")

sys.exit(0)
'

# --- dispatch ----------------------------------------------------------------
CMD="${1:-}"
if [ -z "$CMD" ]; then
  usage
  exit 2
fi
shift

case "$CMD" in
  recap)
    # The recap skill passes "$ARGUMENTS", so accept the bare word "full" as
    # well as "--full" (design U16 subcommand is `recap [--full]`).
    FULL=""
    if [ "$#" -gt 0 ]; then
      case "$1" in
        --full|full) FULL="--full"; shift ;;
        *) echo "recap: unexpected argument: $1" >&2; usage; exit 2 ;;
      esac
    fi
    if [ "$#" -ne 0 ]; then usage; exit 2; fi
    # shellcheck disable=SC2086
    exec "$PY" "$PY_DIR/digest.py" print $FULL --cwd "$PWD"
    ;;
  report)
    if [ "$#" -ne 0 ]; then usage; exit 2; fi
    exec "$PY" "$PY_DIR/digest.py" print --full --cwd "$PWD"
    ;;
  log)
    N=20
    if [ "$#" -gt 0 ]; then
      case "$1" in
        ''|*[!0-9]*) echo "log: count must be a positive integer: $1" >&2; usage; exit 2 ;;
        *) N="$1"; shift ;;
      esac
    fi
    if [ "$#" -ne 0 ]; then usage; exit 2; fi
    exec "$PY" "$PY_DIR/digest.py" print --log "$N" --cwd "$PWD"
    ;;
  forget)
    ALL=0
    YES=0
    for a in "$@"; do
      case "$a" in
        --all) ALL=1 ;;
        --yes) YES=1 ;;
        *) echo "forget: unexpected argument: $a" >&2; usage; exit 2 ;;
      esac
    done
    PYTHONPATH="$PY_DIR" "$PY" -c "$forget_py" "$PWD" "$ALL" "$YES"
    exit $?
    ;;
  config)
    SUB="${1:-}"
    [ "$#" -ge 1 ] && shift
    case "$SUB" in
      list)
        if [ "$#" -ne 0 ]; then usage; exit 2; fi
        exec "$PY" "$PY_DIR/supervisor_common.py" config-list
        ;;
      get)
        if [ "$#" -ne 1 ]; then usage; exit 2; fi
        exec "$PY" "$PY_DIR/supervisor_common.py" config-get "$1"
        ;;
      set)
        if [ "$#" -lt 2 ]; then usage; exit 2; fi
        exec "$PY" "$PY_DIR/supervisor_common.py" config-set "$@"
        ;;
      *)
        usage
        exit 2
        ;;
    esac
    ;;
  status)
    PYTHONPATH="$PY_DIR" "$PY" -c "$status_py" "$PWD"
    exit $?
    ;;
  *)
    echo "supervisorctl: unknown command: $CMD" >&2
    usage
    exit 2
    ;;
esac
