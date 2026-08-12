"""test_gitstate.py - U-06 revert-set unit tests (design 9.3 / CT-17, critic
SF-03). Exercises the pure `digest._compute_reverted(run, edited_paths)` over
hand-built start/end git snapshots: created-then-deleted, modified-then-restored,
kept change, path-outside-repo, subdirectory cwd with cwd-relative paths,
truncated hash lists, and a changed HEAD.
"""
import hashlib
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "py"))
import digest  # noqa: E402


def h12(p):
    return hashlib.sha256(p.encode("utf-8")).hexdigest()[:12]


def snap(root="/repo", head="H", dirty=(), untracked=(),
         dirty_n=None, untracked_n=None):
    dh = [h12(p) for p in dirty]
    uh = [h12(p) for p in untracked]
    return {
        "root": root, "head": head,
        "dirty_n": len(dh) if dirty_n is None else dirty_n,
        "untracked_n": len(uh) if untracked_n is None else untracked_n,
        "dh": dh, "uh": uh,
    }


def run(cwd, S, E):
    return {"cwd": cwd, "start_git": S, "end_git": E}


class RevertSet(unittest.TestCase):
    def test_created_then_deleted_untracked_is_revert(self):
        S = snap()                                   # clean at start
        E = snap()                                   # file gone at end
        r = run("/repo", S, E)
        self.assertEqual(digest._compute_reverted(r, {"new.ts"}), ["new.ts"])

    def test_modified_then_restored_tracked_is_revert(self):
        S = snap()                                   # clean at start
        E = snap()                                   # restored -> clean at end
        r = run("/repo", S, E)
        self.assertEqual(digest._compute_reverted(r, {"mod.ts"}), ["mod.ts"])

    def test_kept_change_is_not_revert(self):
        S = snap()
        E = snap(dirty=("kept.ts",))                 # change survives at end
        r = run("/repo", S, E)
        self.assertEqual(digest._compute_reverted(r, {"kept.ts"}), [])

    def test_dirty_at_start_cannot_be_adjudicated(self):
        S = snap(dirty=("already.ts",))              # already dirty at start
        E = snap()
        r = run("/repo", S, E)
        self.assertEqual(digest._compute_reverted(r, {"already.ts"}), [])

    def test_path_outside_repo_ignored(self):
        S = snap()
        E = snap()
        r = run("/repo", S, E)
        # resolves above the repo root -> skipped, no crash, not reverted
        self.assertEqual(digest._compute_reverted(r, {"../outside.ts"}), [])

    def test_subdir_cwd_sf03(self):
        # cwd is a subdirectory of the repo root; event paths are cwd-relative.
        # A kept edit must NOT report REVERTED; a deleted one MUST (critic SF-03).
        S = snap(root="/repo")
        E = snap(root="/repo", dirty=("pkg/src/keep.ts",))
        r = run("/repo/pkg", S, E)
        out = digest._compute_reverted(r, {"src/keep.ts", "src/gone.ts"})
        self.assertIn("src/gone.ts", out)
        self.assertNotIn("src/keep.ts", out)

    def test_truncated_hash_list_suppresses(self):
        S = snap()
        # dirty_n exceeds len(dh): membership absence is unprovable -> suppress
        E = snap(dirty=("other.ts",), dirty_n=200)
        r = run("/repo", S, E)
        self.assertEqual(digest._compute_reverted(r, {"maybe.ts"}), [])

    def test_changed_head_suppresses(self):
        S = snap(head="AAA")
        E = snap(head="BBB")                         # a commit happened
        r = run("/repo", S, E)
        self.assertEqual(digest._compute_reverted(r, {"x.ts"}), [])

    def test_missing_git_returns_empty(self):
        self.assertEqual(
            digest._compute_reverted({"cwd": "/repo", "start_git": None,
                                      "end_git": None}, {"x.ts"}), [])

    def test_start_missing_head_or_root(self):
        S = {"dirty_n": 0, "untracked_n": 0, "dh": [], "uh": []}  # no head/root
        E = snap()
        self.assertEqual(digest._compute_reverted(run("/repo", S, E), {"x.ts"}), [])

    def test_multiple_reverts_sorted(self):
        S = snap()
        E = snap()
        out = digest._compute_reverted(run("/repo", S, E), {"b.ts", "a.ts", "c.ts"})
        self.assertEqual(out, ["a.ts", "b.ts", "c.ts"])

    def test_absolute_edited_path_inside_repo(self):
        S = snap(root="/repo")
        E = snap(root="/repo")
        out = digest._compute_reverted(run("/repo", S, E), {"/repo/deep/x.ts"})
        self.assertEqual(out, ["/repo/deep/x.ts"])


if __name__ == "__main__":
    unittest.main()
