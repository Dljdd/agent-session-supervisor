#!/bin/sh
# lib/detach.sh - sup_detach CMD [ARGS...]: daemonize CMD in its own session so it
# survives the hook process, hook timeouts, and terminal process-group signals.
# Prints the daemon PID on success, nothing on failure.
sup_detach() {
  _dt_py=$(command -v python3 2>/dev/null)
  if [ -n "$_dt_py" ]; then
    "$_dt_py" - "$@" <<'PYEOF'
import os, sys
args = sys.argv[1:]
if not args:
    sys.exit(0)
r, w = os.pipe()
pid = os.fork()
if pid > 0:
    os.close(w)
    data = os.read(r, 32).decode(errors="replace").strip()
    os.waitpid(pid, 0)
    if data:
        print(data)
    sys.exit(0)
os.close(r)
os.setsid()
pid2 = os.fork()
if pid2 > 0:
    os.write(w, str(pid2).encode())
    os._exit(0)
os.close(w)
devnull = os.open(os.devnull, os.O_RDWR)
os.dup2(devnull, 0); os.dup2(devnull, 1); os.dup2(devnull, 2)
try:
    os.execvp(args[0], args)
except Exception:
    os._exit(127)
PYEOF
  else
    ( nohup "$@" </dev/null >/dev/null 2>&1 & echo $! ) 2>/dev/null
  fi
}
