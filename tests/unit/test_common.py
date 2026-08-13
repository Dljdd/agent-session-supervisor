import os, sys, json, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "py"))
import supervisor_common as sc

import glob
import hashlib
import re
import shutil
import stat
import subprocess
import time
from unittest import mock

SCRIPT = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "scripts", "py", "supervisor_common.py"))

# Env keys the module reads; every test starts from a clean slate.
MANAGED_ENV = [
    "CLAUDE_PLUGIN_DATA", "SUPERVISOR_DATA_DIR", "SUPERVISOR_TEST_MODE",
    "SUPERVISOR_NOW", "SUPERVISOR_FAKE_CLAUDE_PID", "CLAUDE_PROJECT_DIR",
    "HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
]

# Independent oracle for design spec section 4.4 (never read from the module).
EXPECTED_DEFAULTS = {
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


class Base(unittest.TestCase):
    def setUp(self):
        self._saved = {}
        for k in MANAGED_ENV:
            self._saved[k] = os.environ.pop(k, None)
        self.home = tempfile.mkdtemp(prefix="suphome.")
        self.addCleanup(shutil.rmtree, self.home, True)
        os.environ["HOME"] = self.home
        os.environ["GIT_CONFIG_GLOBAL"] = "/dev/null"
        os.environ["GIT_CONFIG_SYSTEM"] = "/dev/null"

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def tmpdir(self, prefix="supt."):
        d = tempfile.mkdtemp(prefix=prefix)
        self.addCleanup(shutil.rmtree, d, True)
        return d

    def use_store(self):
        """Point the module at a fresh sandbox store via the test-mode seam."""
        store = self.tmpdir("supstore.")
        os.environ["SUPERVISOR_TEST_MODE"] = "1"
        os.environ["SUPERVISOR_DATA_DIR"] = store
        return store

    def cli_env(self, **extra):
        env = {
            "PATH": self._saved.get("PATH") or os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.home,
            "LC_ALL": "C",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
        }
        env.update(extra)
        return env

    def run_cli(self, args, stdin_text=None, env=None):
        return subprocess.run(
            [sys.executable, SCRIPT] + args,
            input=stdin_text, capture_output=True, text=True, timeout=30,
            env=env if env is not None else self.cli_env())


def git(*args, cwd=None):
    subprocess.run(
        ["git"] + list(args), cwd=cwd, check=True, timeout=30,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class TestProjectKey(Base):
    # design spec section 4.2: ssh/scp/https/user:pass@/.git/trailing-slash/case
    # all normalize to one source string.
    REMOTES = [
        "git@github.com:Acme/Repo.git",
        "https://github.com/acme/repo/",
        "ssh://git@github.com/acme/repo",
        "https://alice:ghp_tok123@github.com/acme/repo.git",
        "ssh://git@github.com:22/acme/repo",
        "https://GitHub.com/ACME/Repo.git",
    ]

    def test_remote_normalization_table(self):
        repo = self.tmpdir("suprepo.")
        git("init", "-q", cwd=repo)
        want_src = "github.com/acme/repo"
        want_key = hashlib.sha256(want_src.encode()).hexdigest()[:12]
        first = True
        for url in self.REMOTES:
            with self.subTest(url=url):
                if first:
                    git("remote", "add", "origin", url, cwd=repo)
                    first = False
                else:
                    git("remote", "set-url", "origin", url, cwd=repo)
                key, src = sc.project_key(repo)
                self.assertEqual(src, want_src)
                self.assertEqual(key, want_key)
                # SEC-10: userinfo (including embedded tokens) never survives.
                self.assertNotIn("alice", src)
                self.assertNotIn("ghp_tok123", src)

    def test_plain_dir_uses_realpath(self):
        d = self.tmpdir("supplain.")
        key, src = sc.project_key(d)
        self.assertEqual(src, os.path.realpath(d))
        self.assertEqual(key, hashlib.sha256(src.encode()).hexdigest()[:12])
        self.assertTrue(re.match(r"^[0-9a-f]{12}$", key))


class TestSafeSid(Base):
    def test_accepts_clean_sid(self):
        self.assertEqual(sc.safe_sid("sess-01"), "sess-01")

    def test_substitutes_path_escape(self):
        out = sc.safe_sid("../../escape")
        self.assertTrue(re.match(r"^x[0-9a-f]{12}$", out), out)
        self.assertEqual(
            out, "x" + hashlib.sha256(b"../../escape").hexdigest()[:12])

    def test_substitutes_empty(self):
        self.assertTrue(re.match(r"^x[0-9a-f]{12}$", sc.safe_sid("")))

    def test_substitutes_overlong(self):
        self.assertTrue(re.match(r"^x[0-9a-f]{12}$", sc.safe_sid("a" * 200)))


class TestStringHelpers(Base):
    def test_escape_newlines(self):
        self.assertEqual(sc.escape_newlines("a\nb\r\nc"), "a\\nb\\nc")
        self.assertEqual(sc.escape_newlines("a\rb"), "a\\nb")

    def test_fence_escape(self):
        out = sc.fence_escape("x```y~~~~z")
        self.assertNotIn("```", out)
        self.assertNotIn("~~~", out)
        self.assertEqual(out, "x``y~~z")

    def test_cap_path(self):
        s = "/" + "a" * 299          # 300 chars
        out = sc.cap_path(s)
        self.assertEqual(len(out), 240)
        self.assertIn("…", out)
        self.assertEqual(out, s[:120] + "…" + s[-119:])
        self.assertEqual(sc.cap_path("/short"), "/short")

    def test_estimate_tokens(self):
        self.assertEqual(sc.estimate_tokens(""), 0)
        self.assertEqual(sc.estimate_tokens("a"), 1)
        self.assertEqual(sc.estimate_tokens("abcd"), 1)
        self.assertEqual(sc.estimate_tokens("abcde"), 2)

    def test_now_seam(self):
        os.environ["SUPERVISOR_NOW"] = "1753689600"
        self.assertEqual(sc.now(), 1753689600)
        del os.environ["SUPERVISOR_NOW"]
        self.assertLess(abs(sc.now() - int(time.time())), 5)


class TestAppendEvent(Base):
    def test_torn_tail_guard(self):
        d = self.tmpdir()
        path = os.path.join(d, "events.jsonl")
        with open(path, "wb") as f:
            f.write(b'{"partial')          # no trailing newline: torn tail
        ev = {"v": 1, "ts": 1, "s": "sess-0001", "k": "stop"}
        sc.append_event(path, ev)
        raw = open(path, "rb").read()
        self.assertTrue(raw.startswith(b'{"partial\n'),
                        "torn tail was not isolated onto its own line: %r" % raw[:32])
        self.assertTrue(raw.endswith(b"\n"))
        lines = [l for l in raw.split(b"\n") if l]
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0], b'{"partial')      # torn fragment isolated
        self.assertEqual(json.loads(lines[-1].decode()), ev)  # last line parses

    def test_oversize_drops_uh_before_dh(self):
        d = self.tmpdir()
        path = os.path.join(d, "events.jsonl")
        hashes = ["%012d" % i for i in range(200)]     # 200 fake snapshot hashes each
        ev = {"v": 1, "ts": 1, "s": "sess-0001", "k": "end", "reason": "other",
              "git": {"root": "/abs/project", "head": "f" * 40,
                      "dirty_n": 200, "untracked_n": 200,
                      "dh": list(hashes), "uh": list(hashes)}}
        sc.append_event(path, ev)
        raw = open(path, "rb").read()
        lines = [l for l in raw.split(b"\n") if l]
        self.assertEqual(len(lines), 1)
        self.assertLessEqual(len(lines[0]), 4096)      # CT-10 on-disk byte budget
        obj = json.loads(lines[0].decode())
        self.assertNotIn("uh", obj["git"])             # uh dropped first
        self.assertIn("dh", obj["git"])                # dh survived
        self.assertEqual(obj["git"]["dirty_n"], 200)   # counts stay
        self.assertEqual(obj["git"]["untracked_n"], 200)

    def test_oversize_event_dropped_never_torn(self):
        d = self.tmpdir()
        path = os.path.join(d, "events.jsonl")
        seed = {"v": 1, "ts": 1, "s": "s", "k": "stop"}
        sc.append_event(path, seed)
        big = {"v": 1, "ts": 2, "s": "s", "k": "bash", "c": "A" * 6000, "ok": True}
        sc.append_event(path, big)                     # no git lists to degrade
        lines = [l for l in open(path, "rb").read().split(b"\n") if l]
        self.assertEqual(len(lines), 1)                # event dropped entirely
        self.assertEqual(json.loads(lines[0].decode()), seed)


class TestAtomicWrite(Base):
    def test_mode_0600_and_no_tmp_residue(self):
        d = self.tmpdir()
        p = os.path.join(d, "x.json")
        sc.atomic_write(p, '{"a":1}')
        self.assertEqual(open(p).read(), '{"a":1}')
        mode = stat.S_IMODE(os.stat(p).st_mode)
        self.assertEqual(mode, 0o600, oct(mode))
        self.assertEqual(glob.glob(os.path.join(d, "*tmp*")), [])
        self.assertEqual(glob.glob(os.path.join(d, ".*tmp*")), [])

    def test_unlink_on_error(self):
        d = self.tmpdir()
        p = os.path.join(d, "y.json")
        with mock.patch("os.replace", side_effect=OSError("boom")):
            with self.assertRaises(OSError):
                sc.atomic_write(p, "data")
        self.assertFalse(os.path.exists(p))
        self.assertEqual(glob.glob(os.path.join(d, "*tmp*")), [])
        self.assertEqual(glob.glob(os.path.join(d, ".*tmp*")), [])


class TestDataDir(Base):
    def test_plugin_data_wins(self):
        d = self.tmpdir()
        os.environ["CLAUDE_PLUGIN_DATA"] = d
        os.environ["SUPERVISOR_TEST_MODE"] = "1"
        os.environ["SUPERVISOR_DATA_DIR"] = "/elsewhere"
        self.assertEqual(sc.data_dir(), d)
        self.assertEqual(sc.data_dir(for_hook=False), d)

    def test_supervisor_dir_needs_test_mode(self):
        d = self.tmpdir()
        os.environ["SUPERVISOR_DATA_DIR"] = d          # no SUPERVISOR_TEST_MODE
        with self.assertRaises(sc.DataDirUnset):
            sc.data_dir()                              # hooks: no fallback (CT-12)
        fallback = os.path.join(self.home, ".claude", "plugins", "data",
                                "supervisor-inline")
        self.assertEqual(sc.data_dir(for_hook=False), fallback)

    def test_supervisor_dir_with_test_mode(self):
        d = self.tmpdir()
        os.environ["SUPERVISOR_TEST_MODE"] = "1"
        os.environ["SUPERVISOR_DATA_DIR"] = d
        self.assertEqual(sc.data_dir(), d)

    def test_nothing_resolved(self):
        with self.assertRaises(sc.DataDirUnset):
            sc.data_dir()
        fallback = os.path.join(self.home, ".claude", "plugins", "data",
                                "supervisor-inline")
        self.assertEqual(sc.data_dir(for_hook=False), fallback)

    def test_containment_rejects_git_worktree(self):
        repo = self.tmpdir("suprepo.")
        git("init", "-q", cwd=repo)
        os.environ["SUPERVISOR_TEST_MODE"] = "1"
        # The attack dir does not exist yet -- exactly the .envrc shape (A-20).
        os.environ["SUPERVISOR_DATA_DIR"] = os.path.join(repo, ".supervisor")
        with self.assertRaises(sc.DataDirRefused):
            sc.data_dir()
        with self.assertRaises(sc.DataDirRefused):
            sc.data_dir(for_hook=False)
        # An existing dir inside the worktree is refused just the same.
        inside = os.path.join(repo, "data")
        os.mkdir(inside)
        os.environ["SUPERVISOR_DATA_DIR"] = inside
        with self.assertRaises(sc.DataDirRefused):
            sc.data_dir()

    def test_containment_ok_rules(self):
        clean = self.tmpdir()
        self.assertTrue(sc.containment_ok(clean))
        proj = self.tmpdir("supproj.")
        os.environ["CLAUDE_PROJECT_DIR"] = proj
        self.assertFalse(sc.containment_ok(os.path.join(proj, "sub")))
        self.assertFalse(sc.containment_ok(proj))
        del os.environ["CLAUDE_PROJECT_DIR"]
        cwd_tmp = self.tmpdir("supcwd.")
        old = os.getcwd()
        os.chdir(cwd_tmp)
        try:
            self.assertFalse(sc.containment_ok(os.path.join(cwd_tmp, "store")))
        finally:
            os.chdir(old)


class TestConfig(Base):
    def test_defaults_when_no_file(self):
        self.use_store()
        self.assertEqual(sc.load_config(), EXPECTED_DEFAULTS)

    def test_unknown_keys_ignored(self):
        store = self.use_store()
        with open(os.path.join(store, "config.json"), "w") as f:
            json.dump({"capture_reads": False, "zzz": 1}, f)
        cfg = sc.load_config()
        self.assertEqual(cfg["capture_reads"], False)
        self.assertNotIn("zzz", cfg)
        self.assertEqual(cfg["awake"], "auto")

    def test_wrong_types_replaced(self):
        store = self.use_store()
        with open(os.path.join(store, "config.json"), "w") as f:
            json.dump({"digest_max_tokens": "lots", "auto_resume": "yes",
                       "resume_extra_args": "nope", "awake": 3,
                       "resume_max_attempts": True}, f)
        cfg = sc.load_config()
        self.assertEqual(cfg["digest_max_tokens"], 400)
        self.assertEqual(cfg["auto_resume"], False)
        self.assertEqual(cfg["resume_extra_args"], [])
        self.assertEqual(cfg["awake"], "auto")
        self.assertEqual(cfg["resume_max_attempts"], 4)  # bool is not an int here

    def test_unparseable_file_means_defaults(self):
        store = self.use_store()
        with open(os.path.join(store, "config.json"), "w") as f:
            f.write("{oops")
        self.assertEqual(sc.load_config(), EXPECTED_DEFAULTS)

    def test_config_set_whitelist_and_protection(self):
        self.use_store()
        sc.config_set("capture_reads", False)
        self.assertEqual(sc.load_config()["capture_reads"], False)
        with self.assertRaises(sc.ConfigRefused):
            sc.config_set("auto_resume", True)          # protected, no ack
        sc.config_set("auto_resume", True, ack=True)
        self.assertEqual(sc.load_config()["auto_resume"], True)
        with self.assertRaises(sc.ConfigRefused):
            sc.config_set("nonsense_key", 1)            # not in whitelist
        with self.assertRaises(sc.ConfigRefused):
            sc.config_set("v", 2)                       # schema version not settable
        with self.assertRaises(sc.ConfigRefused):
            sc.config_set("awake", 3)                   # wrong type refused
        with self.assertRaises(sc.ConfigRefused):
            sc.config_set("resume_extra_args",
                          ["--dangerously-skip-permissions"], ack=True)
        sc.config_set("resume_extra_args", ["--plugin-dir", "/abs"], ack=True)
        self.assertEqual(sc.load_config()["resume_extra_args"],
                         ["--plugin-dir", "/abs"])


class TestValidateExtraArgs(Base):
    def test_accepts_whitelisted_pairs(self):
        sc.validate_extra_args([])
        sc.validate_extra_args(["--plugin-dir", "/x"])
        sc.validate_extra_args(["--model", "opus", "--add-dir", "/y"])
        sc.validate_extra_args(["--settings", "/s", "--fallback-model", "m"])

    def test_rejects(self):
        for bad in (
            "not-a-list",
            [1, 2],
            ["--plugin-dir"],                            # missing value
            ["--rm", "-rf"],                             # flag not in allow-set
            ["--settings", "x", "--allowedTools", "Bash"],
            ["--mcp-config", "f"],
            ["--plugin-dir", "/x", "--dangerously-skip-permissions"],
            ["--model", "opus", "extra"],                # odd token count
        ):
            with self.subTest(bad=bad):
                with self.assertRaises(sc.ConfigRefused):
                    sc.validate_extra_args(bad)


class TestCli(Base):
    def test_key_subcommand(self):
        d = self.tmpdir()
        r = self.run_cli(["key", d])
        self.assertEqual(r.returncode, 0, r.stderr)
        want = hashlib.sha256(os.path.realpath(d).encode()).hexdigest()[:12]
        self.assertEqual(r.stdout.strip(), want)

    def test_cfg_subcommand(self):
        store = self.tmpdir("supstore.")
        env = self.cli_env(SUPERVISOR_TEST_MODE="1", SUPERVISOR_DATA_DIR=store)
        r = self.run_cli(["cfg", "awake", "auto"], env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "auto")
        with open(os.path.join(store, "config.json"), "w") as f:
            json.dump({"awake": "off"}, f)
        r = self.run_cli(["cfg", "awake", "auto"], env=env)
        self.assertEqual(r.stdout.strip(), "off")
        r = self.run_cli(["cfg", "capture_reads", "true"], env=env)
        self.assertEqual(r.stdout.strip(), "true")       # shell-comparable bools
        r = self.run_cli(["cfg", "no_such_key", "dflt"], env=env)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "dflt")

    def test_config_set_get_cli(self):
        store = self.tmpdir("supstore.")
        env = self.cli_env(SUPERVISOR_TEST_MODE="1", SUPERVISOR_DATA_DIR=store)
        r = self.run_cli(["config-set", "auto_resume", "true"], env=env)
        self.assertEqual(r.returncode, 4)                # refused: protected key
        self.assertFalse(os.path.exists(os.path.join(store, "config.json")))
        r = self.run_cli(["config-set", "auto_resume", "true",
                          "--i-understand-quota-spend"], env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        cfg_path = os.path.join(store, "config.json")
        self.assertTrue(os.path.exists(cfg_path))
        self.assertEqual(stat.S_IMODE(os.stat(cfg_path).st_mode), 0o600)
        r = self.run_cli(["config-get", "auto_resume"], env=env)
        self.assertEqual(r.stdout.strip(), "true")
        r = self.run_cli(["config-set", "awake", "off"], env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_cli(["config-get", "awake"], env=env)
        self.assertEqual(r.stdout.strip(), "off")
        r = self.run_cli(["config-list"], env=env)
        self.assertEqual(r.returncode, 0)
        listed = json.loads(r.stdout)
        self.assertEqual(listed["awake"], "off")
        self.assertEqual(listed["auto_resume"], True)

    def test_stdin_vars_plain(self):
        payload = json.dumps({"session_id": "sess-0001", "source": "startup",
                              "cwd": "/sandbox/proj",
                              "hook_event_name": "SessionStart"})
        r = self.run_cli(["stdin-vars"], stdin_text=payload)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(),
                         "SID='sess-0001' SRC='startup' CWD='/sandbox/proj'")

    def test_stdin_vars_hostile_sid_and_quote(self):
        payload = json.dumps({"session_id": "../../escape", "source": "startup",
                              "cwd": "/tmp/o'brien"})
        r = self.run_cli(["stdin-vars"], stdin_text=payload)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout.strip()
        # SID is the safe_sid substitute: usable directly as a path component.
        m = re.match(r"^SID='(x[0-9a-f]{12})' SRC='startup' CWD=", out)
        self.assertIsNotNone(m, out)
        # The line is eval-safe: bash round-trips the quoted cwd exactly.
        rt = subprocess.run(
            ["/bin/bash", "-c", 'eval "$1"; printf %s "$CWD"; printf ":%s" "$SID"',
             "bash", out],
            capture_output=True, text=True, timeout=30, env=self.cli_env())
        self.assertEqual(rt.stdout, "/tmp/o'brien:" + m.group(1))

    def test_stdin_vars_garbage_is_silent(self):
        r = self.run_cli(["stdin-vars"], stdin_text="not json")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")


class TestFindClaudePid(Base):
    def test_seam(self):
        os.environ["SUPERVISOR_TEST_MODE"] = "1"
        os.environ["SUPERVISOR_FAKE_CLAUDE_PID"] = "4242"
        self.assertEqual(sc.find_claude_pid(), 4242)

    def test_returns_int_or_none(self):
        # Ancestry-dependent (the test may itself run under a real claude);
        # only the type contract is asserted here -- 01-libs.sh drives the
        # positive/negative walk with wrapper processes.
        out = sc.find_claude_pid()
        self.assertTrue(out is None or isinstance(out, int))


if __name__ == "__main__":
    unittest.main()
