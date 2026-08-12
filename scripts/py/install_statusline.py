#!/usr/bin/env python3
"""install_statusline.py - the ONLY writer of ~/.claude/settings.json in this
plugin (design U18, critic SEC-08). The statusline skill narrates and the user
approves; all file mechanics live here so the model never hand-edits settings.

Subcommands:
  show                     print current statusLine + any local/project override
  install --data-dir <abs> self-contained copy into <data>/bin + settings edit
  remove                   restore the backed-up statusLine, else drop the key

install is idempotent (re-run -> "already installed", no write). Every settings
write is: load -> json.loads (unparseable input aborts, touches nothing) ->
timestamped backup -> minimal edit -> dump to a same-dir 0600 temp -> re-parse
the temp -> os.replace. Any exception exits non-zero with the original intact.
"""
import glob
import json
import os
import shutil
import sys
import time


def _home():
    return os.path.expanduser("~")


def _settings_path():
    return os.path.join(_home(), ".claude", "settings.json")


def _plugin_root():
    # scripts/py/install_statusline.py -> plugin root is two levels up.
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _now():
    v = os.environ.get("SUPERVISOR_NOW")
    if v:
        try:
            return int(v)
        except (TypeError, ValueError):
            pass
    return int(time.time())


def _target_command(data_dir):
    return os.path.join(data_dir, "bin", "supervisor-statusline.sh")


def _load_json(path):
    """Return (obj, existed). Missing file -> ({}, False). Unparseable -> raise."""
    if not os.path.exists(path):
        return {}, False
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if text.strip() == "":
        return {}, True
    return json.loads(text), True


def _atomic_write_settings(path, obj):
    """Dump -> same-dir 0600 temp -> re-parse the temp -> os.replace."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, 0o700, exist_ok=True)
    tmp = os.path.join(d, ".settings.json.suptmp%d" % os.getpid())
    try:
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        os.unlink(tmp)
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, sort_keys=True)
            f.write("\n")
        # prove the bytes we just wrote parse before they become the real file
        with open(tmp, "r", encoding="utf-8") as f:
            json.load(f)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _statusline_of(path):
    try:
        obj, _ = _load_json(path)
    except (OSError, ValueError):
        return None
    if isinstance(obj, dict):
        sl = obj.get("statusLine")
        if isinstance(sl, dict):
            return sl
    return None


def _copy_self_contained(data_dir):
    """Copy statusline.sh (data dir baked in) + telemetry.py into <data>/bin/."""
    root = _plugin_root()
    src_sh = os.path.join(root, "scripts", "statusline.sh")
    src_py = os.path.join(root, "scripts", "py", "telemetry.py")
    bindir = os.path.join(data_dir, "bin")
    os.makedirs(bindir, 0o700, exist_ok=True)
    with open(src_sh, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")
    baked = 'SUPERVISOR_BAKED_DATA_DIR="%s"' % data_dir
    replaced = False
    for i, ln in enumerate(lines):
        if ln.startswith("SUPERVISOR_BAKED_DATA_DIR="):
            lines[i] = baked
            replaced = True
            break
    if not replaced:
        raise RuntimeError("statusline.sh has no SUPERVISOR_BAKED_DATA_DIR line to bake")
    dst_sh = _target_command(data_dir)
    with open(dst_sh, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    os.chmod(dst_sh, 0o700)
    dst_py = os.path.join(bindir, "telemetry.py")
    shutil.copyfile(src_py, dst_py)
    os.chmod(dst_py, 0o600)
    return dst_sh


def cmd_show(_args):
    sp = _settings_path()
    sl = _statusline_of(sp)
    if sl is None:
        print("current statusLine (user settings): (none)")
    else:
        print("current statusLine (user settings): %s"
              % json.dumps(sl, sort_keys=True))
    local = os.path.join(_home(), ".claude", "settings.local.json")
    lsl = _statusline_of(local)
    if lsl is not None:
        print("override in settings.local.json: %s (this may take precedence)"
              % json.dumps(lsl, sort_keys=True))
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    psp = os.path.join(proj, ".claude", "settings.json")
    psl = _statusline_of(psp)
    if psl is not None:
        print("override in project .claude/settings.json: %s (this may take precedence)"
              % json.dumps(psl, sort_keys=True))
    return 0


def cmd_install(args):
    data_dir = None
    i = 0
    while i < len(args):
        if args[i] == "--data-dir" and i + 1 < len(args):
            data_dir = args[i + 1]
            i += 2
            continue
        i += 1
    if not data_dir:
        sys.stderr.write("install: --data-dir <abs> is required\n")
        return 2
    data_dir = os.path.abspath(data_dir)
    target = _target_command(data_dir)

    sp = _settings_path()
    try:
        obj, existed = _load_json(sp)
    except ValueError as e:
        sys.stderr.write("install: %s is not valid JSON, refusing to touch it (%s)\n"
                         % (sp, e))
        return 1
    if not isinstance(obj, dict):
        sys.stderr.write("install: %s does not hold a JSON object, refusing to touch it\n" % sp)
        return 1

    cur = obj.get("statusLine")
    if isinstance(cur, dict) and cur.get("command") == target:
        # Ensure the copy exists even on a re-run, then report idempotent success.
        _copy_self_contained(data_dir)
        print("already installed")
        return 0

    # Copy the self-contained artifacts first; only then edit settings.
    _copy_self_contained(data_dir)

    if existed:
        # Each install that edits settings backs up its OWN pre-edit state. If a
        # same-epoch backup already exists (fixed clock / two installs in one
        # second), pick a fresh suffixed name so `remove` can restore THIS state
        # (newest by mtime), never a stale earlier snapshot.
        base = "%s.supervisor-bak-%d" % (sp, _now())
        backup = base
        n = 1
        while os.path.exists(backup):
            backup = "%s-%d" % (base, n)
            n += 1
        shutil.copyfile(sp, backup)
        os.chmod(backup, 0o600)

    obj["statusLine"] = {"type": "command", "command": target}
    _atomic_write_settings(sp, obj)
    try:
        os.chmod(sp, 0o600)
    except OSError:
        pass
    print("installed: statusLine -> %s" % target)
    if isinstance(cur, dict):
        print("previous statusLine backed up: %s" % json.dumps(cur, sort_keys=True))
    # Report overrides that could shadow the user-settings statusLine.
    cmd_show([])
    return 0


def _newest_backup():
    sp = _settings_path()
    baks = glob.glob(sp + ".supervisor-bak-*")
    if not baks:
        return None
    baks.sort(key=lambda p: os.path.getmtime(p))
    return baks[-1]


def cmd_remove(_args):
    sp = _settings_path()
    try:
        obj, existed = _load_json(sp)
    except ValueError as e:
        sys.stderr.write("remove: %s is not valid JSON, refusing to touch it (%s)\n"
                         % (sp, e))
        return 1
    if not existed or not isinstance(obj, dict):
        print("nothing to remove (no user settings)")
        return 0

    restored = None
    bak = _newest_backup()
    if bak is not None:
        try:
            bobj, _ = _load_json(bak)
            if isinstance(bobj, dict) and isinstance(bobj.get("statusLine"), dict):
                restored = bobj["statusLine"]
        except (OSError, ValueError):
            restored = None

    if restored is not None:
        obj["statusLine"] = restored
    else:
        obj.pop("statusLine", None)
    _atomic_write_settings(sp, obj)
    try:
        os.chmod(sp, 0o600)
    except OSError:
        pass
    if restored is not None:
        print("removed: restored statusLine from backup")
    else:
        print("removed: statusLine key deleted")
    return 0


def main(argv=None):
    os.umask(0o077)
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        sys.stderr.write("usage: install_statusline.py show|install --data-dir <abs>|remove\n")
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "show":
        return cmd_show(rest)
    if cmd == "install":
        return cmd_install(rest)
    if cmd == "remove":
        return cmd_remove(rest)
    sys.stderr.write("usage: install_statusline.py show|install --data-dir <abs>|remove\n")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        sys.stderr.write("install_statusline.py: %s\n" % e)
        sys.exit(1)
