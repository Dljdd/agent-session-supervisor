"""test_maintain.py - unit tests for scripts/py/maintain.py (design U7).

Rotation threshold, retention by faked mtimes, reconciliation of unterminated
runs (dead-pid crash close, live-pid skip via the monkeypatched comm check,
no-pid 30-min rule, the not-yet-idle case, idempotence), awake-lock sweep,
resume-pending cleanup, permission re-assert, and forget dry-run/execute.

No test sleeps; the one spawned process (a live-pid stand-in) is tracked and
killed in tearDown.
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "py"))
import maintain  # noqa: E402
import supervisor_common as sc  # noqa: E402

NOW = 1753689600
DEAD_PID = 2147480000
GENV = {
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
}


def wf(path, text):
    with open(path, "w") as f:
        f.write(text)


class Base(unittest.TestCase):
    def setUp(self):
        self.T = tempfile.mkdtemp(prefix="suptest.")
        self.data = os.path.join(self.T, "data")
        self.proj = os.path.join(self.T, "proj")
        os.makedirs(self.data, 0o700)
        os.makedirs(self.proj, 0o700)
        self._env0 = dict(os.environ)
        os.environ["CLAUDE_PLUGIN_DATA"] = self.data
        os.environ["CLAUDE_PROJECT_DIR"] = self.proj
        os.environ["SUPERVISOR_NOW"] = str(NOW)
        os.environ["SUPERVISOR_TEST_MODE"] = "1"
        os.environ.pop("SUPERVISOR_FAKE_LOOKS_CLAUDE", None)
        os.environ.update(GENV)
        self._procs = []
        self.pdir = sc.project_dir(self.proj, for_hook=True)
        self.events = os.path.join(self.pdir, "events.jsonl")

    def tearDown(self):
        for p in self._procs:
            try:
                p.kill()
                p.wait(timeout=3)
            except Exception:
                pass
        os.environ.clear()
        os.environ.update(self._env0)
        shutil.rmtree(self.T, ignore_errors=True)

    def git(self, *args):
        e = dict(os.environ)
        e.update(GENV)
        subprocess.run(["git", "-C", self.proj] + list(args), check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=e)

    def mk_git(self):
        self.git("init", "-q")
        wf(os.path.join(self.proj, "base.txt"), "base\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "init")

    def seed(self, *evs):
        for ev in evs:
            sc.append_event(self.events, ev)

    def read(self):
        return sc.read_events([self.events])

    def spawn_live(self):
        p = subprocess.Popen(["sleep", "30"])
        self._procs.append(p)
        return p.pid


class Rotation(Base):
    def test_rotate_over_10mb(self):
        with open(self.events, "wb") as f:
            f.truncate(11 * 1024 * 1024)
        maintain._rotate(self.pdir)
        self.assertTrue(os.path.exists(self.events + ".1"))
        self.assertFalse(os.path.exists(self.events))

    def test_no_rotate_under_threshold(self):
        with open(self.events, "wb") as f:
            f.truncate(9 * 1024 * 1024 + 900 * 1024)   # ~9.9 MB
        maintain._rotate(self.pdir)
        self.assertFalse(os.path.exists(self.events + ".1"))
        self.assertTrue(os.path.exists(self.events))

    def test_rotate_replaces_previous_archive(self):
        arc = self.events + ".1"
        wf(arc, "old archive\n")
        with open(self.events, "wb") as f:
            f.truncate(11 * 1024 * 1024)
        maintain._rotate(self.pdir)
        self.assertEqual(os.path.getsize(arc), 11 * 1024 * 1024)


class Retention(Base):
    def test_prune_old_archive_keep_young(self):
        arc = self.events + ".1"
        wf(arc, "x\n")
        os.utime(arc, (NOW - 31 * 86400, NOW - 31 * 86400))
        maintain._retention(self.pdir, NOW)
        self.assertFalse(os.path.exists(arc))

        wf(arc, "x\n")
        os.utime(arc, (NOW - 29 * 86400, NOW - 29 * 86400))
        maintain._retention(self.pdir, NOW)
        self.assertTrue(os.path.exists(arc))

    def test_prune_old_reports(self):
        rdir = os.path.join(self.pdir, "reports")
        os.makedirs(rdir, 0o700)
        old = os.path.join(rdir, "a.md")
        young = os.path.join(rdir, "b.md")
        wf(old, "o")
        wf(young, "y")
        os.utime(old, (NOW - 40 * 86400, NOW - 40 * 86400))
        os.utime(young, (NOW - 5 * 86400, NOW - 5 * 86400))
        maintain._retention(self.pdir, NOW)
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(young))

    def test_sessions_capped_to_500(self):
        sess = os.path.join(self.pdir, "sessions.jsonl")
        with open(sess, "w") as f:
            for i in range(600):
                f.write(json.dumps({"s": "s%d" % i, "t0": i}) + "\n")
        maintain._retention(self.pdir, NOW)
        with open(sess) as f:
            lines = [ln for ln in f if ln.strip()]
        self.assertEqual(len(lines), 500)


class Reconcile(Base):
    def _start(self, ts, pid=None, sid="s1"):
        ev = {"v": 1, "ts": ts, "s": sid, "k": "start", "src": "startup",
              "cwd": self.proj}
        if pid is not None:
            ev["pid"] = pid
        return ev

    def _count_inferred(self):
        return sum(1 for e in self.read()
                   if e.get("k") == "end" and e.get("inf") == 1)

    def test_crashed_dead_pid_gets_one_inferred_end_with_git(self):
        self.mk_git()
        self.seed(self._start(NOW - 3600, pid=DEAD_PID),
                  {"v": 1, "ts": NOW - 3600, "s": "s1", "k": "edit", "p": "a.ts"})
        n = maintain.reconcile(self.pdir, self.proj, NOW)
        self.assertEqual(n, 1)
        ends = [e for e in self.read() if e.get("k") == "end"]
        self.assertEqual(len(ends), 1)
        self.assertEqual(ends[0].get("reason"), "inferred")
        self.assertEqual(ends[0].get("inf"), 1)
        self.assertIn("git", ends[0])                 # snapshot at reconcile time

    def test_live_pid_not_closed(self):
        pid = self.spawn_live()
        os.environ["SUPERVISOR_FAKE_LOOKS_CLAUDE"] = "1"
        self.seed(self._start(NOW - 3600, pid=pid),
                  {"v": 1, "ts": NOW - 3600, "s": "s1", "k": "edit", "p": "a.ts"})
        n = maintain.reconcile(self.pdir, self.proj, NOW)
        self.assertEqual(n, 0)
        self.assertEqual(self._count_inferred(), 0)

    def test_live_pid_via_monkeypatch(self):
        pid = self.spawn_live()
        orig = maintain._looks_claude
        maintain._looks_claude = lambda p: True
        try:
            self.seed(self._start(NOW - 3600, pid=pid),
                      {"v": 1, "ts": NOW - 3600, "s": "s1", "k": "edit", "p": "a.ts"})
            self.assertEqual(maintain.reconcile(self.pdir, self.proj, NOW), 0)
        finally:
            maintain._looks_claude = orig

    def test_no_pid_uses_30min_rule(self):
        self.seed(self._start(NOW - 3600),   # 60 min old, no pid
                  {"v": 1, "ts": NOW - 3600, "s": "s1", "k": "edit", "p": "a.ts"})
        self.assertEqual(maintain.reconcile(self.pdir, self.proj, NOW), 1)

    def test_recent_run_not_closed(self):
        self.seed(self._start(NOW - 600),    # 10 min old -> still active
                  {"v": 1, "ts": NOW - 600, "s": "s1", "k": "edit", "p": "a.ts"})
        self.assertEqual(maintain.reconcile(self.pdir, self.proj, NOW), 0)

    def test_idempotent(self):
        self.seed(self._start(NOW - 3600),
                  {"v": 1, "ts": NOW - 3600, "s": "s1", "k": "edit", "p": "a.ts"})
        self.assertEqual(maintain.reconcile(self.pdir, self.proj, NOW), 1)
        self.assertEqual(maintain.reconcile(self.pdir, self.proj, NOW), 0)
        self.assertEqual(self._count_inferred(), 1)

    def test_already_closed_run_untouched(self):
        self.seed(self._start(NOW - 3600),
                  {"v": 1, "ts": NOW - 3600, "s": "s1", "k": "edit", "p": "a.ts"},
                  {"v": 1, "ts": NOW - 3500, "s": "s1", "k": "end", "reason": "other"})
        self.assertEqual(maintain.reconcile(self.pdir, self.proj, NOW), 0)


class Sweep(Base):
    def test_full_sweep_runs_clean(self):
        self.seed({"v": 1, "ts": NOW - 3600, "s": "s1", "k": "start",
                   "src": "startup", "cwd": self.proj},
                  {"v": 1, "ts": NOW - 3600, "s": "s1", "k": "edit", "p": "a.ts"})
        rc = maintain.sweep(self.proj, NOW)
        self.assertEqual(rc, 0)
        self.assertEqual(sum(1 for e in self.read()
                             if e.get("k") == "end" and e.get("inf") == 1), 1)

    def test_perm_reassert(self):
        loose = os.path.join(self.pdir, "loose.txt")
        wf(loose, "x")
        os.chmod(loose, 0o644)
        maintain._perm_reassert(self.data)
        self.assertEqual(os.stat(loose).st_mode & 0o077, 0)


class AwakeSweep(Base):
    def _lock(self, name, obj):
        adir = os.path.join(self.data, "awake")
        os.makedirs(adir, 0o700, exist_ok=True)
        p = os.path.join(adir, name)
        wf(p, json.dumps(obj))
        return p

    def test_dead_claude_pid_lock_removed(self):
        p = self._lock("s1.lock", {"v": 1, "mode": "caffeinate",
                                   "holder_pid": DEAD_PID, "claude_pid": DEAD_PID,
                                   "ts": NOW})
        maintain._awake_sweep(self.data, NOW)
        self.assertFalse(os.path.exists(p))

    def test_aged_lock_removed(self):
        p = self._lock("s2.lock", {"v": 1, "mode": "caffeinate",
                                   "holder_pid": DEAD_PID, "claude_pid": DEAD_PID,
                                   "ts": NOW - 40 * 3600})
        maintain._awake_sweep(self.data, NOW)
        self.assertFalse(os.path.exists(p))

    def test_garbage_lock_removed(self):
        adir = os.path.join(self.data, "awake")
        os.makedirs(adir, 0o700, exist_ok=True)
        p = os.path.join(adir, "junk.lock")
        wf(p, "not json")
        maintain._awake_sweep(self.data, NOW)
        self.assertFalse(os.path.exists(p))


class ResumeCleanup(Base):
    def test_dead_pending_removed(self):
        pend = os.path.join(self.data, "resume", "pending")
        os.makedirs(pend, 0o700, exist_ok=True)
        p = os.path.join(pend, "s1.json")
        wf(p, json.dumps({"v": 1, "pid": DEAD_PID, "cwd": self.proj}))
        maintain._resume_cleanup(self.data, NOW, sc.load_config())
        self.assertFalse(os.path.exists(p))

    def test_stale_attempt_lock_removed(self):
        rdir = os.path.join(self.data, "resume")
        os.makedirs(rdir, 0o700, exist_ok=True)
        lock = os.path.join(rdir, "attempt.lock")
        wf(lock, "x")
        os.utime(lock, (NOW - 3600, NOW - 3600))   # 1 h old > 30+5 min
        maintain._resume_cleanup(self.data, NOW, sc.load_config())
        self.assertFalse(os.path.exists(lock))

    def test_old_ledger_entries_pruned(self):
        rdir = os.path.join(self.data, "resume")
        os.makedirs(rdir, 0o700, exist_ok=True)
        state = os.path.join(rdir, "state.json")
        wf(state, json.dumps({"v": 1, "attempts": [
            {"ts": NOW - 20 * 86400, "session": "old"},
            {"ts": NOW - 1 * 86400, "session": "recent"},
        ]}))
        maintain._resume_cleanup(self.data, NOW, sc.load_config())
        with open(state) as f:
            obj = json.load(f)
        sessions = [a["session"] for a in obj["attempts"]]
        self.assertEqual(sessions, ["recent"])


class Forget(Base):
    def test_dry_run_exit3(self):
        wf(os.path.join(self.pdir, "sessions.index"), "s1\n")
        cap = io.StringIO()
        old = sys.stdout
        sys.stdout = cap
        try:
            rc = maintain.forget(self.proj, all_flag=False, yes=False)
        finally:
            sys.stdout = old
        self.assertEqual(rc, 3)
        self.assertIn("DRY RUN", cap.getvalue())
        self.assertTrue(os.path.exists(self.pdir))   # nothing deleted

    def test_yes_deletes_project(self):
        wf(os.path.join(self.pdir, "sessions.index"), "s1\n")
        cap = io.StringIO()
        old = sys.stdout
        sys.stdout = cap
        try:
            rc = maintain.forget(self.proj, all_flag=False, yes=True)
        finally:
            sys.stdout = old
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(self.pdir))

    def test_all_dry_run_exit3(self):
        cap = io.StringIO()
        old = sys.stdout
        sys.stdout = cap
        try:
            rc = maintain.forget(self.proj, all_flag=True, yes=False)
        finally:
            sys.stdout = old
        self.assertEqual(rc, 3)
        self.assertTrue(os.path.exists(self.data))


if __name__ == "__main__":
    unittest.main()
