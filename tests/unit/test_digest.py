"""test_digest.py - unit tests for scripts/py/digest.py (design spec U8 / section 9).

Drives the pure builder and its helpers directly (TP-11): run grouping and
selection (9.1/9.2), signal aggregation (9.3), the fixed section order and
templates (9.4), the CT-9 drop ladder (9.6), relative time / duration (9.5),
the CT-4 budget over the FULL additionalContext (9.6), determinism (U-10), a
byte-exact golden (tests/fixtures/golden/digest-sample.txt), plus malformed-line
tolerance and path edge cases.
"""
import hashlib
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "py"))
import digest  # noqa: E402

GOLDEN = os.path.join(os.path.dirname(__file__), "..", "fixtures", "golden",
                      "digest-sample.txt")


def h12(p):
    return hashlib.sha256(p.encode("utf-8")).hexdigest()[:12]


def start(ts, s="s1", cwd="/repo", git=None, pid=None, src="startup"):
    e = {"v": 1, "ts": ts, "s": s, "k": "start", "src": src, "cwd": cwd}
    if git is not None:
        e["git"] = git
    if pid is not None:
        e["pid"] = pid
    return e


def end(ts, s="s1", reason="other", git=None, inf=False):
    e = {"v": 1, "ts": ts, "s": s, "k": "end", "reason": reason}
    if inf:
        e["reason"] = "inferred"
        e["inf"] = 1
    if git is not None:
        e["git"] = git
    return e


def edit(ts, p, s="s1", a=False):
    e = {"v": 1, "ts": ts, "s": s, "k": "edit", "p": p}
    if a:
        e["a"] = 1
    return e


def read(ts, p, s="s1", a=False):
    e = {"v": 1, "ts": ts, "s": s, "k": "read", "p": p}
    if a:
        e["a"] = 1
    return e


def bash(ts, c, ok, s="s1", e=None):
    d = {"v": 1, "ts": ts, "s": s, "k": "bash", "c": c, "ok": ok}
    if e is not None:
        d["e"] = e
    return d


class GoldenAndDeterminism(unittest.TestCase):
    def _golden_events(self):
        S = {"root": "/repo", "head": "HEAD1", "dirty_n": 0, "untracked_n": 0,
             "dh": [], "uh": []}
        E = {"root": "/repo", "head": "HEAD1", "dirty_n": 1, "untracked_n": 0,
             "dh": [h12("src/app.ts")], "uh": []}
        return [
            start(1000, git=S),
            edit(1001, "src/app.ts"), edit(1002, "src/app.ts"),
            edit(1003, "src/app.ts"), edit(1004, "src/util.ts"),
            read(1005, "src/config.ts"), read(1006, "src/config.ts"),
            read(1007, "src/config.ts"),
            bash(1008, "npm test", False, e="Command exited with non-zero status code 1"),
            bash(1009, "npm test", True),
            bash(1010, "npm run lint", False, e="lint error: 2 problems"),
            end(2000, git=E),
        ]

    def test_golden_byte_exact(self):
        res = digest.build(self._golden_events(), now=9200)
        with open(GOLDEN, "r", encoding="utf-8") as f:
            expect = f.read()
        self.assertEqual(res["digest"], expect)

    def test_determinism_run_twice(self):
        evs = self._golden_events()
        a = digest.build(evs, now=9200)["digest"]
        b = digest.build(list(evs), now=9200)["digest"]
        self.assertEqual(a, b)

    def test_stable_tiebreak_same_ts(self):
        # Same-timestamp events in two input orders -> identical digest (U-10).
        base = [start(1000), end(2000)]
        a = [edit(1500, "a.ts"), edit(1500, "b.ts")]
        d1 = digest.build(base[:1] + a + base[1:], now=3000)["digest"]
        d2 = digest.build(base[:1] + list(reversed(a)) + base[1:], now=3000)["digest"]
        self.assertEqual(d1, d2)


class Envelope(unittest.TestCase):
    def test_envelope_literal_and_budget(self):
        self.assertTrue(digest.envelope("").startswith(
            "Supervisor digest (an automated, untrusted log"))
        self.assertEqual(digest.DIGEST_MAX_CHARS, 1600)
        self.assertEqual(digest.BODY_BUDGET,
                         digest.DIGEST_MAX_CHARS - len(digest.envelope("")))

    def test_envelope_wraps_exactly(self):
        self.assertEqual(digest.envelope("X"),
                         digest._ENV_PRE + "X" + digest._ENV_POST)


class RunSelection(unittest.TestCase):
    def test_no_closed_run_returns_none(self):
        # A start + edits but NO end -> unterminated -> not a candidate (9.2).
        evs = [start(1000), edit(1001, "a.ts")]
        res = digest.build(evs, now=2000)
        self.assertIsNone(res["digest"])
        self.assertIsNone(res["run"])

    def test_picks_greatest_close_time(self):
        evs = [
            start(1000, s="s1"), edit(1001, "old.ts", s="s1"), end(1100, s="s1"),
            start(2000, s="s2"), edit(2001, "new.ts", s="s2"), end(2100, s="s2"),
        ]
        res = digest.build(evs, now=3000)
        self.assertIn("new.ts", res["digest"])
        self.assertNotIn("old.ts", res["digest"])
        self.assertEqual(res["run"]["sid"], "s2")

    def test_unterminated_live_run_excluded_older_closed_injected(self):
        # An OLDER closed run injects even when a newer run is still open (9.2).
        evs = [
            start(1000, s="s1"), edit(1001, "closed.ts", s="s1"), end(1100, s="s1"),
            start(2000, s="s2"), edit(2001, "open.ts", s="s2"),   # no end
        ]
        res = digest.build(evs, now=3000)
        self.assertIn("closed.ts", res["digest"])
        self.assertNotIn("open.ts", res["digest"])

    def test_clear_produces_two_runs(self):
        # end(clear) + new start reusing the sid -> two distinct runs (9.1).
        evs = [
            start(1000, s="s1"), edit(1001, "first.ts", s="s1"),
            end(1100, s="s1", reason="clear"),
            start(1200, s="s1"), edit(1201, "second.ts", s="s1"),
            end(1300, s="s1"),
        ]
        runs = digest.group_runs(digest._normalize(evs))
        self.assertEqual(len(runs), 2)
        res = digest.build(evs, now=2000)
        self.assertIn("second.ts", res["digest"])
        self.assertNotIn("first.ts", res["digest"])

    def test_resurrection_voids_inferred_end(self):
        # An inferred end followed by a later signal is voided (9.1): the run is
        # no longer closed, so it is not a candidate.
        evs = [
            start(1000, s="s1"), edit(1001, "a.ts", s="s1"),
            end(1100, s="s1", inf=True),
            edit(5000, "late.ts", s="s1"),   # later signal voids the inferred end
        ]
        runs = digest.group_runs(digest._normalize(evs))
        self.assertEqual(len(runs), 1)
        self.assertFalse(runs[0]["closed"])

    def test_real_end_never_voided(self):
        evs = [
            start(1000, s="s1"), edit(1001, "a.ts", s="s1"),
            end(1100, s="s1"),
            edit(5000, "late.ts", s="s1"),   # a real end is NOT voided
        ]
        runs = digest.group_runs(digest._normalize(evs))
        self.assertTrue(runs[0]["closed"])


class Aggregation(unittest.TestCase):
    def test_edit_counts_and_sort(self):
        evs = [start(1000),
               edit(1001, "a.ts"), edit(1002, "a.ts"), edit(1003, "a.ts"),
               edit(1004, "b.ts"), edit(1005, "b.ts"),
               edit(1006, "c.ts"),
               end(2000)]
        res = digest.build(evs, now=3000)
        body = res["digest"]
        self.assertIn("  Edited a.ts ×3", body)
        self.assertIn("  Edited b.ts ×2", body)
        self.assertIn("  Edited c.ts", body)          # n==1 has no ×
        self.assertNotIn("c.ts ×", body)
        # count desc then path asc: a before b before c
        self.assertLess(body.index("a.ts"), body.index("b.ts"))
        self.assertLess(body.index("b.ts"), body.index("c.ts"))

    def test_subagent_edits_count_reads_excluded(self):
        evs = [start(1000),
               edit(1001, "a.ts", a=True), edit(1002, "a.ts"),
               read(1003, "r.ts", a=True), read(1004, "r.ts", a=True),
               read(1005, "r.ts", a=True),
               end(2000)]
        res = digest.build(evs, now=3000)
        self.assertIn("  Edited a.ts ×2", res["digest"])   # subagent edit counts
        self.assertNotIn("never edited", res["digest"])    # subagent reads excluded

    def test_failed_command_grouping_and_last_error(self):
        evs = [start(1000),
               bash(1001, "npm test", False, e="first error"),
               bash(1002, "npm test", False, e="second error"),
               end(2000)]
        res = digest.build(evs, now=3000)
        self.assertIn('  FAILED ×2  npm test — "second error"', res["digest"])

    def test_read_never_edited_threshold(self):
        evs = [start(1000),
               read(1001, "x.ts"), read(1002, "x.ts"),           # count 2 -> omitted
               read(1003, "y.ts"), read(1004, "y.ts"), read(1005, "y.ts"),
               end(2000)]
        res = digest.build(evs, now=3000)
        self.assertIn("  Read ×3   y.ts — never edited", res["digest"])
        self.assertNotIn("x.ts", res["digest"])

    def test_read_then_edited_not_reported(self):
        evs = [start(1000),
               read(1001, "z.ts"), read(1002, "z.ts"), read(1003, "z.ts"),
               edit(1004, "z.ts"),
               end(2000)]
        res = digest.build(evs, now=3000)
        self.assertNotIn("never edited", res["digest"])


class SectionOrder(unittest.TestCase):
    def test_fixed_order_and_zero_sections_omitted(self):
        S = {"root": "/repo", "head": "H", "dirty_n": 0, "untracked_n": 0,
             "dh": [], "uh": []}
        E = {"root": "/repo", "head": "H", "dirty_n": 0, "untracked_n": 0,
             "dh": [], "uh": []}
        evs = [start(1000, git=S),
               edit(1001, "e.ts"),
               bash(1002, "cmd-x", False, e="boom"),
               bash(1003, "cmd-y", False, e="b"), bash(1004, "cmd-y", True),
               read(1005, "r.ts"), read(1006, "r.ts"), read(1007, "r.ts"),
               edit(1008, "rev.ts"),                       # reverted (not in E)
               end(2000, git=E)]
        body = digest.build(evs, now=3000)["digest"]
        i_ed = body.index("Edited")
        i_fa = body.index("FAILED")
        i_te = body.index("Tests")
        i_re = body.index("REVERTED")
        i_rd = body.index("Read ×")
        self.assertTrue(i_ed < i_fa < i_te < i_re < i_rd)

    def test_no_git_no_reverted_section(self):
        evs = [start(1000), edit(1001, "a.ts"), end(2000)]  # no git snapshots
        body = digest.build(evs, now=3000)["digest"]
        self.assertNotIn("REVERTED", body)


class RedGreen(unittest.TestCase):
    def _arrow(self, seq):
        evs = [start(1000)]
        t = 1001
        for ok in seq:
            evs.append(bash(t, "npm test", ok, e="e"))
            t += 1
        evs.append(end(t + 10))
        return digest.build(evs, now=t + 100)["digest"]

    def test_fail_then_pass_is_red_green(self):
        self.assertIn("npm test  red → green", self._arrow([False, True]))

    def test_pass_then_fail_is_green_red(self):
        self.assertIn("npm test  green → red", self._arrow([True, False]))

    def test_fail_pass_fail_is_green_red(self):
        # latest state wins: ends failing after a pass -> regression (green->red)
        self.assertIn("npm test  green → red", self._arrow([False, True, False]))

    def test_single_polarity_no_transition(self):
        self.assertNotIn("→", self._arrow([True, True]))
        self.assertNotIn("→", self._arrow([False, False]))

    def test_lone_pass_after_interrupt_no_transition(self):
        # capture drops interrupts, so the builder sees only one pass -> nothing.
        self.assertNotIn("→", self._arrow([True]))


class DropLadder(unittest.TestCase):
    """CT-9 stepwise: build an explicit sig, drive render_body at tuned budgets."""

    def setUp(self):
        self.sig = {
            "edits": [("e1", 5), ("e2", 4), ("e3", 3), ("e4", 2), ("e5", 1)],
            "fails": [("cmdF1", 3, "E" * 90), ("cmdF2", 2, "F" * 90),
                      ("cmdF3", 1, "G" * 90), ("cmdF4", 1, "H" * 90)],
            "tests": [("cmdT1", "red → green"), ("cmdT2", "green → red"),
                      ("cmdT3", "red → green")],
            "reverted": ["r1", "r2", "r3"],
            "reads": [("rd1", 5), ("rd2", 4), ("rd3", 3)],
        }

    def _body(self, edits, fails, tests, reverted, reads, err_len=80):
        lines = []
        for p, n in edits:
            lines.append(digest._prep(digest._edit_line(p, n)))
        for c, n, e in fails:
            lines.append(digest._prep(digest._fail_line(c, n, e, err_len)))
        for c, a in tests:
            lines.append(digest._prep(digest._test_line(c, a)))
        for p in reverted:
            lines.append(digest._prep(digest._revert_line(p)))
        for p, n in reads:
            lines.append(digest._prep(digest._read_line(p, n)))
        return "\n".join(lines)

    def _at(self, expected):
        # length strictly decreases each rung, so budget == len(expected) yields
        # exactly `expected` (the first stage that fits).
        self.assertEqual(digest.render_body(self.sig, len(expected)), expected)

    def test_full_when_budget_ample(self):
        s = self.sig
        full = self._body(s["edits"], s["fails"], s["tests"], s["reverted"], s["reads"])
        self.assertEqual(digest.render_body(s, 100000), full)

    def test_step1_reads_dropped_first(self):
        s = self.sig
        self._at(self._body(s["edits"], s["fails"], s["tests"], s["reverted"], []))

    def test_step2_tests_beyond_first(self):
        s = self.sig
        self._at(self._body(s["edits"], s["fails"], s["tests"][:1], s["reverted"], []))

    def test_step3a_edits_beyond_top3(self):
        s = self.sig
        self._at(self._body(s["edits"][:3], s["fails"], s["tests"][:1], s["reverted"], []))

    def test_step3b_edits_beyond_top1(self):
        s = self.sig
        self._at(self._body(s["edits"][:1], s["fails"], s["tests"][:1], s["reverted"], []))

    def test_step4_err80_to_40(self):
        s = self.sig
        self._at(self._body(s["edits"][:1], s["fails"], s["tests"][:1],
                            s["reverted"], [], err_len=40))

    def test_step5_fails_beyond_first(self):
        s = self.sig
        self._at(self._body(s["edits"][:1], s["fails"][:1], s["tests"][:1],
                            s["reverted"], [], err_len=40))

    def test_step6_reverted_beyond_first(self):
        s = self.sig
        self._at(self._body(s["edits"][:1], s["fails"][:1], s["tests"][:1],
                            s["reverted"][:1], [], err_len=40))

    def test_step7_hard_truncate_line_boundary(self):
        s = self.sig
        # A budget below the smallest single-line rung forces the final hard
        # truncate at a line boundary; never mid-line.
        out = digest.render_body(s, 5)
        self.assertTrue(all(ln.startswith("  ") for ln in out.split("\n") if ln))
        self.assertLessEqual(len(out), 5)


class BudgetBoundary(unittest.TestCase):
    def test_full_additional_context_within_1600(self):
        evs = [start(1000)]
        for i in range(200):
            # long multibyte paths to stress the char budget (9.6, CT-4)
            evs.append(edit(1001 + i, "src/módulo/компонент/файл%03d.ts" % i))
        evs.append(end(4000))
        res = digest.build(evs, now=6000)
        ctx = digest.envelope(res["digest"])
        self.assertLessEqual(len(ctx), digest.DIGEST_MAX_CHARS)
        self.assertLess(len(ctx), 9000)
        self.assertLessEqual(len(res["digest"]), digest.BODY_BUDGET)

    def test_render_never_cuts_mid_line(self):
        sig = {"edits": [("файл-очень-длинный-путь-%02d.ts" % i, 1) for i in range(20)],
               "fails": [], "tests": [], "reverted": [], "reads": []}
        for budget in (0, 10, 37, 61, 130, 400):
            out = digest.render_body(sig, budget)
            self.assertLessEqual(len(out), budget)
            for ln in out.split("\n"):
                if ln:
                    self.assertTrue(ln.startswith("  "))

    def test_configurable_max_tokens(self):
        evs = [start(1000)]
        for i in range(80):
            evs.append(edit(1001 + i, "src/some/dir/file%02d.ts" % i))
        evs.append(end(3000))
        # 300 tokens -> 1200 char budget over the FULL additionalContext.
        res = digest.build(evs, now=4000, cfg={"digest_max_tokens": 300})
        self.assertLessEqual(len(digest.envelope(res["digest"])), 1200)

    def _budget_filling_events(self):
        # 5 long edits + 4 long unique failing commands: the natural body far
        # exceeds the budget, so the render fills to the cap either way — which
        # is exactly what makes the `reserve` observable.
        evs = [start(1000)]
        t = 1001
        for i in range(5):
            evs.append(edit(t, "src/dir%02d/" % i + "e" * 180 + ".ts"))
            t += 1
        for i in range(4):
            evs.append(bash(t, "cmd%02d " % i + "c" * 180, False, e="E" * 180))
            t += 1
        evs.append(end(3000))
        return evs

    def test_reserve_shrinks_digest_to_leave_room_for_trailer(self):
        # A caller that appends a fixed trailer to the SAME additionalContext
        # (the one-time first-run note, cli_inject) reserves its length so the
        # WHOLE string — envelope + trailer — still fits CT-4's 1600 (§9.6).
        evs = self._budget_filling_events()
        full = digest.envelope(digest.build(evs, now=5000)["digest"])
        self.assertLessEqual(len(full), digest.DIGEST_MAX_CHARS)   # existing cap
        reserve = 300
        ctx = digest.envelope(
            digest.build(evs, now=5000, reserve=reserve)["digest"])
        # the reserved digest leaves >= `reserve` chars of headroom …
        self.assertLessEqual(len(ctx) + reserve, digest.DIGEST_MAX_CHARS)
        # … and the reservation genuinely shrank a budget-filling digest.
        self.assertLess(len(ctx), len(full))


class RelativeTimeAndDuration(unittest.TestCase):
    def test_rel_time_table(self):
        self.assertEqual(digest.rel_time(0), "just now")
        self.assertEqual(digest.rel_time(119), "just now")
        self.assertEqual(digest.rel_time(120), "2 min ago")
        self.assertEqual(digest.rel_time(47 * 60), "47 min ago")
        self.assertEqual(digest.rel_time(3600), "60 min ago")
        self.assertEqual(digest.rel_time(7200), "2 hours ago")
        self.assertEqual(digest.rel_time(3600 + 3600), "2 hours ago")
        self.assertEqual(digest.rel_time(3600 * 24), "24 hours ago")  # <48h
        self.assertEqual(digest.rel_time(3600 * 47), "47 hours ago")  # <48h
        self.assertEqual(digest.rel_time(172800), "2 days ago")       # >=48h
        self.assertEqual(digest.rel_time(3600 * 49), "2 days ago")
        # singular pluralization branch (defensive; unreachable via boundaries)
        self.assertEqual(digest._round_half(1.0), 1)

    def test_dur_table(self):
        self.assertEqual(digest.dur(45), "45s")
        self.assertEqual(digest.dur(59), "59s")
        self.assertEqual(digest.dur(60), "1 min")
        self.assertEqual(digest.dur(2820), "47 min")
        self.assertEqual(digest.dur(6000), "1h 40m")
        self.assertEqual(digest.dur(7500), "2h 05m")

    def test_negative_clamped(self):
        self.assertEqual(digest.rel_time(-5), "just now")
        self.assertEqual(digest.dur(-5), "0s")


class HeaderCost(unittest.TestCase):
    def _evs(self):
        return [start(1000, s="s1"), edit(1001, "a.ts", s="s1"), end(2000, s="s1")]

    def test_no_telemetry_no_cost(self):
        res = digest.build(self._evs(), now=3000, telemetry=None)
        self.assertNotIn("$", res["digest"].splitlines()[0])

    def test_cost_present_when_positive(self):
        res = digest.build(self._evs(), now=3000,
                           telemetry={"s1": {"total_cost_usd": 1.2}})
        self.assertIn(", $1.20", res["digest"].splitlines()[0])

    def test_zero_cost_omitted(self):
        res = digest.build(self._evs(), now=3000,
                           telemetry={"s1": {"total_cost_usd": 0.0}})
        self.assertNotIn("$", res["digest"].splitlines()[0])


class MalformedTolerance(unittest.TestCase):
    def test_non_dict_entries_skipped(self):
        evs = [None, 5, "garbage", ["x"],
               start(1000), edit(1001, "a.ts"), {"junk": True}, end(2000)]
        res = digest.build(evs, now=3000)
        self.assertIn("a.ts", res["digest"])

    def test_events_missing_ts(self):
        evs = [{"s": "s1", "k": "start", "src": "startup", "cwd": "/x"},
               {"s": "s1", "k": "edit", "p": "a.ts"},
               {"s": "s1", "k": "end", "reason": "other"}]
        res = digest.build(evs, now=3000)   # missing ts -> defaults, no crash
        self.assertIsNotNone(res["digest"])


class PathEdgeCases(unittest.TestCase):
    def test_per_line_cap_200(self):
        longp = "d/" + ("x" * 300) + ".ts"
        evs = [start(1000), edit(1001, longp), edit(1002, longp), end(2000)]
        body = digest.build(evs, now=3000)["digest"]
        for ln in body.split("\n"):
            self.assertLessEqual(len(ln), 200)
        self.assertIn("…", body)

    def test_same_basename_two_dirs_disambiguated(self):
        evs = [start(1000),
               edit(1001, "a/x.ts"), edit(1002, "a/x.ts"),
               edit(1003, "b/x.ts"),
               end(2000)]
        body = digest.build(evs, now=3000)["digest"]
        self.assertIn("  Edited a/x.ts ×2", body)
        self.assertIn("  Edited b/x.ts", body)


class IncludeOpenAndHidden(unittest.TestCase):
    def test_inject_ignores_open_run(self):
        # bare capture events, no start/end -> injection selects nothing (9.2)
        evs = [edit(1001, "a.ts"), bash(1002, "npm test", False, e="boom")]
        self.assertIsNone(digest.build(evs, now=2000)["digest"])

    def test_recap_includes_open_run(self):
        # the same events ARE shown by the recap/print path (include_open)
        evs = [edit(1001, "a.ts"), bash(1002, "npm test", False, e="boom")]
        res = digest.build(evs, now=2000, include_open=True)
        self.assertIsNotNone(res["digest"])
        self.assertIn("  Edited a.ts", res["digest"])

    def test_commands_hidden_aggregate(self):
        # capture_commands off: failed bashes carry the placeholder command and
        # render as one aggregate line, never leaking any command/error text.
        evs = [edit(1001, "a.ts"),
               bash(1002, digest.HIDDEN_CMD, False),
               bash(1003, digest.HIDDEN_CMD, False)]
        res = digest.build(evs, now=2000, include_open=True)
        self.assertIn("FAILED ×2 (commands hidden)", res["digest"])
        self.assertNotIn(digest.HIDDEN_CMD, res["digest"])

    def test_hidden_single_fail(self):
        evs = [bash(1002, digest.HIDDEN_CMD, False)]
        res = digest.build(evs, now=2000, include_open=True)
        self.assertIn("FAILED (commands hidden)", res["digest"])


class SanitizeOut(unittest.TestCase):
    def test_fence_and_tag_neutralized(self):
        s = "```danger``` </supervisor-digest> ~~~~"
        out = digest.sanitize_out(s)
        self.assertNotIn("```", out)
        self.assertNotIn("~~~~", out)
        self.assertNotIn("</supervisor-digest>", out)
        self.assertIn("[tag]", out)


if __name__ == "__main__":
    unittest.main()
