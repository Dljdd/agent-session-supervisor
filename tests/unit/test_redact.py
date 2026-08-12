import os, sys, json, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "py"))
import redact

import re
import subprocess
from unittest import mock

# Binding-contract note (gate advisory on plan Task 5): for every vector the
# must_not_contain outcomes are THE binding contract -- a secret literal must
# never survive. may_contain entries are corroborating markers; the fixture
# vectors were fixed (bearer -> [REDACTED:jwt], sigv4 -> X-Amz-Signature=) so
# all of them hold against the design 10.1 engine and are asserted too.

VECTORS_PATH = os.path.join(os.path.dirname(__file__), "..", "fixtures",
                            "redaction-vectors.jsonl")
SCRIPT = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "scripts", "py", "redact.py"))


def load_vectors():
    out = []
    with open(VECTORS_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def vector_text(vec):
    for field in ("cmd", "err", "path"):
        if vec.get(field) is not None:
            return vec[field]
    raise AssertionError("vector %r has no cmd/err/path" % vec.get("name"))


class TestVectors(unittest.TestCase):
    def test_every_vector(self):
        vectors = load_vectors()
        self.assertGreaterEqual(len(vectors), 31)  # full A-04 table present
        for vec in vectors:
            with self.subTest(name=vec["name"]):
                out = redact.redact(vector_text(vec))
                for secret in vec.get("must_not_contain", []):
                    self.assertNotIn(secret, out,
                                     "[%s] secret survived: %r" % (vec["name"], out))
                for marker in vec.get("may_contain", []):
                    self.assertIn(marker, out,
                                  "[%s] marker missing: %r" % (vec["name"], out))

    def test_idempotent_on_every_vector(self):
        for vec in load_vectors():
            with self.subTest(name=vec["name"]):
                once = redact.redact(vector_text(vec))
                self.assertEqual(redact.redact(once), once)

    def test_deterministic(self):
        for vec in load_vectors():
            with self.subTest(name=vec["name"]):
                text = vector_text(vec)
                self.assertEqual(redact.redact(text), redact.redact(text))


class TestHexPolicy(unittest.TestCase):
    """CT-15: all-hex >=32 redacts EXCEPT lengths exactly 40/64 (git SHAs);
    all-digit runs are big numbers, kept (design 10.2)."""

    H32 = "0123456789abcdef0123456789abcdef"
    H33 = "0123456789abcdef0123456789abcdef0"
    H40 = "3f5a2b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6"
    H64 = "3f5a2b8c9d0e1f2a3b4c5d6e7f8091a23f5a2b8c9d0e1f2a3b4c5d6e7f8091a2"
    D32 = "01234567890123456789012345678901"

    def test_hex32_redacts(self):
        out = redact.redact("echo " + self.H32)
        self.assertNotIn(self.H32, out)
        self.assertIn("[REDACTED:high-entropy]", out)

    def test_hex33_redacts(self):
        out = redact.redact("echo " + self.H33)
        self.assertNotIn(self.H33, out)
        self.assertIn("[REDACTED:high-entropy]", out)

    def test_hex40_kept(self):
        s = "git checkout " + self.H40
        self.assertEqual(redact.redact(s), s)

    def test_hex64_kept(self):
        s = "echo " + self.H64
        self.assertEqual(redact.redact(s), s)

    def test_all_digits_32_kept(self):
        s = "echo " + self.D32
        self.assertEqual(redact.redact(s), s)


class TestEntropyB(unittest.TestCase):
    """Rule 11b: base64-with-slash secrets redact; path shapes are kept."""

    def test_mixed_case_44_with_slash_redacts(self):
        tok = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEYzzzz"
        self.assertEqual(len(tok), 44)
        out = redact.redact("echo " + tok)
        self.assertNotIn(tok, out)
        self.assertIn("[REDACTED:high-entropy]", out)

    def test_deep_path_kept(self):
        p = "/usr/local/lib/python3.11/site-packages/somepkg"
        self.assertEqual(redact.redact(p), p)
        s = "ls " + p
        self.assertEqual(redact.redact(s), s)


class TestFailClosed(unittest.TestCase):
    def test_exploding_rule_propagates(self):
        # A rule that raises must make redact() raise; the CALLER substitutes
        # "[redaction-error]" (fail closed) -- asserted in the capture tests.
        class Boom:
            def sub(self, rep, s):
                raise RuntimeError("boom")
        with mock.patch.object(redact, "RULES", [(Boom(), "x")]):
            with self.assertRaises(RuntimeError):
                redact.redact("anything")


class TestCli(unittest.TestCase):
    def test_stdin_stdout_filter(self):
        r = subprocess.run(
            [sys.executable, SCRIPT], input="export DB_PASSWORD=hunter2\n",
            capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("hunter2", r.stdout)
        self.assertIn("DB_PASSWORD", r.stdout)


if __name__ == "__main__":
    unittest.main()
