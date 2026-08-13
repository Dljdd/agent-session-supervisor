"""test_capture.py — unit tests for scripts/py/capture.py (design spec U6).

Drives capture.main(argv, stdin_text, env) against a throwaway tmp store and
asserts the exact appended event dict, the config gates (§4.4), self-noise
drops (§8.2), interrupt drop, CT-11 newline escaping, §10 redaction on c/e/p,
path relativization, git snapshots (§7), CT-10 oversize degradation, boundary
events (--start/--stop/--end + sessions.index + sid_raw §4.3), and a 100-way
concurrent multiprocessing append (§8.3, A-02 at unit scale).

Env is managed directly on os.environ (mirroring tests/unit/test_common.py) so
the supervisor_common helpers — which read os.environ — see the sandbox store.
"""
import glob
import hashlib
import json
import multiprocessing
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "py"))
import capture  # noqa: E402
import supervisor_common as sc  # noqa: E402

NOW = 1753689600
GENV = {
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
}
MANAGED_ENV = [
    "CLAUDE_PLUGIN_DATA", "SUPERVISOR_DATA_DIR", "SUPERVISOR_TEST_MODE",
    "SUPERVISOR_NOW", "SUPERVISOR_FAKE_CLAUDE_PID", "CLAUDE_PROJECT_DIR",
    "CLAUDE_PLUGIN_ROOT", "HOME",
    "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
    "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME",
    "GIT_COMMITTER_EMAIL", "SUPERVISOR_DISABLE",
]
PLUGIN_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _shash(p):
    return hashlib.sha256(p.encode("utf-8", "replace")).hexdigest()[:12]


def _slurp(path, binary=False):
    with open(path, "rb" if binary else "r") as f:
        return f.read()


# --- module-level worker for the multiprocessing concurrency test -----------
def _concurrent_worker(env_dict, payload_json):
    os.environ.clear()
    os.environ.update(env_dict)
    # Re-import inside the (possibly spawned) child and drive one capture.
    import capture as cap  # noqa
    cap.main([], stdin=payload_json, env=os.environ)


class Base(unittest.TestCase):
    def setUp(self):
        self._saved = {}
        for k in MANAGED_ENV:
            self._saved[k] = os.environ.pop(k, None)
        self.root = tempfile.mkdtemp(prefix="supcap.")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.data = os.path.join(self.root, "data")
        self.home = os.path.join(self.root, "home")
        self.proj = os.path.join(self.root, "proj")
        for d in (self.data, self.home, self.proj):
            os.makedirs(d, exist_ok=True)
        os.environ.update({
            "HOME": self.home,
            "CLAUDE_PLUGIN_DATA": self.data,
            "SUPERVISOR_DATA_DIR": self.data,
            "SUPERVISOR_TEST_MODE": "1",
            "CLAUDE_PROJECT_DIR": self.proj,
            "CLAUDE_PLUGIN_ROOT": PLUGIN_ROOT,
            "SUPERVISOR_NOW": str(NOW),
            "SUPERVISOR_FAKE_CLAUDE_PID": "12345",
        })
        os.environ.update(GENV)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    # --- helpers ------------------------------------------------------------
    def git(self, *args):
        e = dict(os.environ)
        e.update(GENV)
        subprocess.run(["git", "-C", self.proj] + list(args), check=True,
                       timeout=30, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, env=e)

    def run_capture(self, payload, argv=None):
        if isinstance(payload, dict):
            payload = json.dumps(payload)
        return capture.main(list(argv or []), stdin=payload, env=os.environ)

    def events(self):
        out = []
        for p in sorted(glob.glob(os.path.join(self.data, "projects", "*", "events.jsonl"))):
            with open(p, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        out.append(json.loads(line))
        return out

    def one_event(self):
        evs = self.events()
        self.assertEqual(len(evs), 1, "expected exactly one event, got %r" % (evs,))
        return evs[0]

    def write_config(self, **over):
        cfg = {k: (list(v) if isinstance(v, list) else v)
               for k, v in sc.CONFIG_DEFAULTS.items()}
        cfg.update(over)
        os.makedirs(self.data, exist_ok=True)
        with open(os.path.join(self.data, "config.json"), "w", encoding="utf-8") as f:
            json.dump(cfg, f)

    # --- payload builders ---------------------------------------------------
    def p_edit(self, fp=None, tool="Edit", sid="sess-0001", **extra):
        d = {"session_id": sid, "cwd": self.proj, "hook_event_name": "PostToolUse",
             "tool_name": tool, "tool_input": {"file_path": fp or os.path.join(self.proj, "src/foo.ts")},
             "duration_ms": 12}
        d.update(extra)
        return d

    def p_read(self, fp=None, sid="sess-0001", **extra):
        d = {"session_id": sid, "cwd": self.proj, "hook_event_name": "PostToolUse",
             "tool_name": "Read", "tool_input": {"file_path": fp or os.path.join(self.proj, "src/verify.ts")},
             "duration_ms": 3}
        d.update(extra)
        return d

    def p_bash(self, cmd="npm test", ms=6120, sid="sess-0001", **extra):
        d = {"session_id": sid, "cwd": self.proj, "hook_event_name": "PostToolUse",
             "tool_name": "Bash", "tool_input": {"command": cmd}, "duration_ms": ms}
        d.update(extra)
        return d

    def p_bashfail(self, cmd="npm test", err="Command exited with non-zero status code 1",
                   ms=4187, interrupt=False, sid="sess-0001"):
        return {"session_id": sid, "cwd": self.proj, "hook_event_name": "PostToolUseFailure",
                "tool_name": "Bash", "tool_input": {"command": cmd}, "error": err,
                "is_interrupt": interrupt, "duration_ms": ms}


# ---------------------------------------------------------------------------
# exact event dicts (plan §6 I/O table)
# ---------------------------------------------------------------------------
class TestExactEvents(Base):
    def test_edit(self):
        self.assertEqual(self.run_capture(self.p_edit()), 0)
        self.assertEqual(self.one_event(),
                         {"v": 1, "ts": NOW, "s": "sess-0001", "k": "edit", "p": "src/foo.ts"})

    def test_write_is_edit_kind(self):
        self.run_capture(self.p_edit(tool="Write"))
        self.assertEqual(self.one_event()["k"], "edit")

    def test_notebookedit_uses_notebook_path(self):
        d = {"session_id": "sess-0001", "cwd": self.proj, "hook_event_name": "PostToolUse",
             "tool_name": "NotebookEdit",
             "tool_input": {"notebook_path": os.path.join(self.proj, "nb.ipynb")}}
        self.run_capture(d)
        self.assertEqual(self.one_event(),
                         {"v": 1, "ts": NOW, "s": "sess-0001", "k": "edit", "p": "nb.ipynb"})

    def test_read(self):
        self.run_capture(self.p_read())
        self.assertEqual(self.one_event(),
                         {"v": 1, "ts": NOW, "s": "sess-0001", "k": "read", "p": "src/verify.ts"})

    def test_bash_pass(self):
        self.run_capture(self.p_bash())
        self.assertEqual(self.one_event(),
                         {"v": 1, "ts": NOW, "s": "sess-0001", "k": "bash",
                          "c": "npm test", "ok": True, "ms": 6120})

    def test_bash_fail(self):
        self.run_capture(self.p_bashfail())
        self.assertEqual(self.one_event(),
                         {"v": 1, "ts": NOW, "s": "sess-0001", "k": "bash", "c": "npm test",
                          "ok": False, "e": "Command exited with non-zero status code 1",
                          "ms": 4187})

    def test_missing_duration_no_ms(self):
        d = self.p_bash()
        del d["duration_ms"]
        self.run_capture(d)
        self.assertNotIn("ms", self.one_event())

    def test_subagent_flag(self):
        self.run_capture(self.p_bash(agent_id="agent-1"))
        ev = self.one_event()
        self.assertEqual(ev["a"], 1)


# ---------------------------------------------------------------------------
# routing negatives / edge cases
# ---------------------------------------------------------------------------
class TestRoutingEdges(Base):
    def test_empty_stdin_no_write(self):
        self.assertEqual(self.run_capture(""), 0)
        self.assertEqual(self.events(), [])

    def test_garbage_stdin_no_write(self):
        self.assertEqual(self.run_capture("}{not json"), 0)
        self.assertEqual(self.events(), [])

    def test_json_non_object_no_write(self):
        self.assertEqual(self.run_capture("[1,2,3]"), 0)
        self.assertEqual(self.events(), [])

    def test_unknown_tool_no_write(self):
        self.run_capture(self.p_edit(tool="Grep"))
        self.assertEqual(self.events(), [])

    def test_unknown_hook_no_write(self):
        d = self.p_edit()
        d["hook_event_name"] = "PreToolUse"
        self.run_capture(d)
        self.assertEqual(self.events(), [])

    def test_read_response_content_never_stored(self):
        self.run_capture(self.p_read())
        raw = _slurp(glob.glob(os.path.join(self.data, "projects", "*", "events.jsonl"))[0])
        self.assertNotIn("CANARY", raw)


# ---------------------------------------------------------------------------
# config gates (§4.4)
# ---------------------------------------------------------------------------
class TestGates(Base):
    def test_capture_reads_false_drops_read(self):
        self.write_config(capture_reads=False)
        self.run_capture(self.p_read())
        self.assertEqual(self.events(), [])

    def test_capture_reads_true_keeps_read(self):
        self.write_config(capture_reads=True)
        self.run_capture(self.p_read())
        self.assertEqual(len(self.events()), 1)

    def test_capture_commands_false_drops_pass(self):
        self.write_config(capture_commands=False)
        self.run_capture(self.p_bash())
        self.assertEqual(self.events(), [])

    def test_capture_commands_false_failure_placeholder_no_e(self):
        self.write_config(capture_commands=False)
        self.run_capture(self.p_bashfail())
        ev = self.one_event()
        self.assertEqual(ev["c"], "[command capture disabled]")
        self.assertEqual(ev["ok"], False)
        self.assertNotIn("e", ev)
        self.assertEqual(ev["ms"], 4187)

    def test_capture_subagents_false_drops_subagent(self):
        self.write_config(capture_subagents=False)
        self.run_capture(self.p_bash(agent_id="agent-1"))
        self.assertEqual(self.events(), [])

    def test_capture_subagents_false_keeps_main_agent(self):
        self.write_config(capture_subagents=False)
        self.run_capture(self.p_bash())
        self.assertEqual(len(self.events()), 1)

    def test_interrupt_drops(self):
        self.run_capture(self.p_bashfail(interrupt=True))
        self.assertEqual(self.events(), [])


# ---------------------------------------------------------------------------
# cleaning: CT-11 newline escaping, §10 redaction, relativization, cap
# ---------------------------------------------------------------------------
class TestCleaning(Base):
    def test_newline_escaped_in_command(self):
        self.run_capture(self.p_bash(cmd="a\nb"))
        self.assertEqual(self.one_event()["c"], "a\\nb")

    def test_command_redacted(self):
        self.run_capture(self.p_bash(cmd="export API_KEY=sk-abcdefghijklmnop0123"))
        c = self.one_event()["c"]
        self.assertNotIn("sk-abcdefghijklmnop0123", c)
        self.assertIn("REDACTED", c)

    def test_error_redacted(self):
        self.run_capture(self.p_bashfail(err="token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        e = self.one_event()["e"]
        self.assertNotIn("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", e)

    def test_path_token_redacted(self):
        fp = "/tmp/deploy/ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345.json"
        self.run_capture(self.p_read(fp=fp))
        p = self.one_event()["p"]
        self.assertNotIn("ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345", p)

    def test_absolute_path_when_outside_cwd(self):
        self.run_capture(self.p_edit(fp="/elsewhere/x.ts"))
        self.assertEqual(self.one_event()["p"], "/elsewhere/x.ts")

    def test_path_exactly_at_cwd_is_dot(self):
        self.run_capture(self.p_edit(fp=self.proj))
        self.assertEqual(self.one_event()["p"], ".")

    def test_command_truncated_to_300(self):
        self.run_capture(self.p_bash(cmd="x" * 5000))
        c = self.one_event()["c"]
        self.assertLessEqual(len(c), 300)
        self.assertTrue(c.endswith("…"))

    def test_error_truncated_to_200(self):
        self.run_capture(self.p_bashfail(err="y" * 5000))
        e = self.one_event()["e"]
        self.assertLessEqual(len(e), 200)


# ---------------------------------------------------------------------------
# self-noise (§8.2 rules 1-4)
# ---------------------------------------------------------------------------
class TestSelfNoise(Base):
    def test_rule1_path_under_data_dir(self):
        fp = os.path.join(self.data, "projects", "abc", "digest.md")
        self.run_capture(self.p_read(fp=fp))
        self.assertEqual(self.events(), [])

    def test_rule4_path_under_plugin_root(self):
        fp = os.path.join(PLUGIN_ROOT, "scripts", "statusline.sh")
        self.run_capture(self.p_read(fp=fp))
        self.assertEqual(self.events(), [])

    def test_rule2_command_contains_data_dir(self):
        self.run_capture(self.p_bash(cmd="cat %s/config.json" % self.data))
        self.assertEqual(self.events(), [])

    def test_rule3_command_contains_supervisorctl(self):
        self.run_capture(self.p_bash(cmd='"$ROOT"/scripts/supervisorctl.sh recap'))
        self.assertEqual(self.events(), [])

    def test_rule3_command_contains_scripts_py(self):
        self.run_capture(self.p_bash(cmd="python3 /x/scripts/py/digest.py print"))
        self.assertEqual(self.events(), [])

    def test_control_command_still_records(self):
        self.run_capture(self.p_bash(cmd="npm test"))
        self.assertEqual(len(self.events()), 1)


# ---------------------------------------------------------------------------
# boundary events (--start / --stop / --end), sessions.index, sid_raw
# ---------------------------------------------------------------------------
class TestBoundary(Base):
    def p_start(self, source="startup", sid="sess-0001"):
        return {"session_id": sid, "cwd": self.proj, "hook_event_name": "SessionStart",
                "source": source}

    def test_start_non_git(self):
        self.run_capture(self.p_start(), argv=["--start"])
        ev = self.one_event()
        self.assertEqual(ev, {"v": 1, "ts": NOW, "s": "sess-0001", "k": "start",
                              "src": "startup", "cwd": self.proj, "pid": 12345})

    def test_start_appends_sessions_index(self):
        self.run_capture(self.p_start(), argv=["--start"])
        self.run_capture(self.p_start(), argv=["--start"])  # dedup
        idxs = glob.glob(os.path.join(self.data, "projects", "*", "sessions.index"))
        self.assertEqual(len(idxs), 1)
        lines = [l.strip() for l in _slurp(idxs[0]).splitlines() if l.strip()]
        self.assertEqual(lines, ["sess-0001"])

    def test_stop(self):
        self.run_capture({"session_id": "sess-0001", "cwd": self.proj,
                          "hook_event_name": "Stop"}, argv=["--stop"])
        self.assertEqual(self.one_event(),
                         {"v": 1, "ts": NOW, "s": "sess-0001", "k": "stop"})

    def test_end(self):
        self.run_capture({"session_id": "sess-0001", "cwd": self.proj,
                          "hook_event_name": "SessionEnd", "reason": "other"},
                         argv=["--end"])
        ev = self.one_event()
        self.assertEqual(ev["k"], "end")
        self.assertEqual(ev["reason"], "other")

    def test_sid_escape_uses_safe_sid_and_sid_raw(self):
        self.run_capture(self.p_start(sid="../../escape"), argv=["--start"])
        ev = self.one_event()
        self.assertEqual(ev["s"], sc.safe_sid("../../escape"))
        self.assertNotEqual(ev["s"], "../../escape")
        self.assertEqual(ev["sid_raw"], "../../escape")
        # No path component anywhere is the raw sid.
        for dirpath, dirnames, filenames in os.walk(self.root):
            for name in dirnames + filenames:
                self.assertNotIn("..", name)
                self.assertNotIn("escape", name)

    def test_sid_empty_no_sid_raw(self):
        self.run_capture(self.p_start(sid=""), argv=["--start"])
        ev = self.one_event()
        self.assertEqual(ev["s"], sc.safe_sid(""))
        self.assertNotIn("sid_raw", ev)


# ---------------------------------------------------------------------------
# git snapshot (§7) — start/end in a real repo
# ---------------------------------------------------------------------------
class TestGitSnapshot(Base):
    def make_repo(self):
        self.git("init", "-q")
        with open(os.path.join(self.proj, "base.txt"), "w") as f:
            f.write("base\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "init")

    def test_start_snapshot_membership(self):
        self.make_repo()
        # dirty base.txt, add an untracked file.
        with open(os.path.join(self.proj, "base.txt"), "a") as f:
            f.write("more\n")
        with open(os.path.join(self.proj, "new.txt"), "w") as f:
            f.write("u\n")
        self.run_capture({"session_id": "sess-0001", "cwd": self.proj,
                          "hook_event_name": "SessionStart", "source": "startup"},
                         argv=["--start"])
        ev = self.one_event()
        git = ev["git"]
        self.assertEqual(git["root"], os.path.realpath(self.proj))
        self.assertEqual(len(git["head"]), 40)
        self.assertGreaterEqual(git["dirty_n"], 1)
        self.assertGreaterEqual(git["untracked_n"], 1)
        self.assertIn(_shash("base.txt"), git["dh"])
        self.assertIn(_shash("new.txt"), git["uh"])
        # No worktree filename ever stored in plaintext (SEC-07).
        raw = _slurp(glob.glob(os.path.join(self.data, "projects", "*", "events.jsonl"))[0])
        self.assertNotIn("new.txt", raw)

    def test_git_snapshots_off_no_git_object(self):
        self.make_repo()
        self.write_config(git_snapshots=False)
        self.run_capture({"session_id": "sess-0001", "cwd": self.proj,
                          "hook_event_name": "SessionStart", "source": "startup"},
                         argv=["--start"])
        self.assertNotIn("git", self.one_event())


# ---------------------------------------------------------------------------
# CT-10 oversize degradation via capture (snapshot-bearing event)
# ---------------------------------------------------------------------------
class TestOversize(Base):
    def test_start_oversize_snapshot_degrades(self):
        big = {"root": "/p", "head": "f" * 40, "dirty_n": 300, "untracked_n": 300,
               "dh": ["%012d" % i for i in range(300)],
               "uh": ["%012d" % i for i in range(300)]}
        orig = capture.git_snapshot
        capture.git_snapshot = lambda cwd: dict(big)
        try:
            self.run_capture({"session_id": "sess-0001", "cwd": self.proj,
                              "hook_event_name": "SessionStart", "source": "startup"},
                             argv=["--start"])
        finally:
            capture.git_snapshot = orig
        path = glob.glob(os.path.join(self.data, "projects", "*", "events.jsonl"))[0]
        raw = _slurp(path, binary=True)
        lines = [l for l in raw.split(b"\n") if l]
        self.assertEqual(len(lines), 1)
        self.assertLessEqual(len(lines[0]), 4096)
        ev = json.loads(lines[0].decode())
        self.assertNotIn("uh", ev["git"])   # uh dropped first (CT-10)


# ---------------------------------------------------------------------------
# store failure never raises (exit 0)
# ---------------------------------------------------------------------------
class TestFailSafe(Base):
    def test_missing_env_no_write_exit0(self):
        for k in ("CLAUDE_PLUGIN_DATA", "SUPERVISOR_DATA_DIR", "SUPERVISOR_TEST_MODE"):
            os.environ.pop(k, None)
        before = sorted(os.listdir(self.home))
        self.assertEqual(self.run_capture(self.p_edit()), 0)
        self.assertEqual(self.events(), [])
        self.assertEqual(sorted(os.listdir(self.home)), before)

    def test_unwritable_store_exit0(self):
        # Point the store at a path whose parent cannot be created.
        os.environ["CLAUDE_PLUGIN_DATA"] = "/proc/nonexistent/nope/data"
        os.environ["SUPERVISOR_DATA_DIR"] = "/proc/nonexistent/nope/data"
        self.assertEqual(self.run_capture(self.p_edit()), 0)


# ---------------------------------------------------------------------------
# concurrency: 100 processes append 100 intact unique lines (A-02 at unit scale)
# ---------------------------------------------------------------------------
class TestConcurrency(Base):
    def test_100_processes_100_intact_lines(self):
        env_dict = dict(os.environ)
        procs = []
        for i in range(100):
            payload = json.dumps(self.p_bash(cmd="npm test #%d" % i))
            p = multiprocessing.Process(target=_concurrent_worker, args=(env_dict, payload))
            procs.append(p)
        for p in procs:
            p.start()
        for p in procs:
            p.join(30)
        path = glob.glob(os.path.join(self.data, "projects", "*", "events.jsonl"))[0]
        raw = _slurp(path, binary=True)
        lines = [l for l in raw.split(b"\n") if l.strip()]
        self.assertEqual(len(lines), 100)
        markers = set()
        for l in lines:
            obj = json.loads(l.decode("utf-8"))   # every line intact & parseable
            markers.add(obj["c"])
        self.assertEqual(len(markers), 100)        # no loss, no merge


if __name__ == "__main__":
    unittest.main()
