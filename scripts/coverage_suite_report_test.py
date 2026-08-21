import io
import json
import re
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from coverage_suite_report import build_report, main


class CoverageSuiteReportTest(unittest.TestCase):
    def test_default_gate_uses_union_and_absolute_ratchets_not_weighted_rates(self):
        script = (Path(__file__).parent / "coverage_suite.sh").read_text()

        def default_for(name):
            match = re.search(
                rf'^{name}="\$\{{VIBE_SUITE_[A-Z_]+:-([^}}]+)\}}"$',
                script,
                re.MULTILINE,
            )
            self.assertIsNotNone(match, f"missing default for {name}")
            return match.group(1)

        # Entry-weighted rates are denominator-diluted whenever a test imports
        # more code. Keep them observable and opt-in, but do not fail main by
        # default on values that are not source coverage.
        self.assertEqual(default_for("MIN_POINT"), "0")
        self.assertEqual(default_for("MIN_BRANCH"), "0")

        # The monotonic absolute-hit and source-union ratchets remain active.
        self.assertGreater(int(default_for("MIN_FN_HIT")), 0)
        self.assertGreater(int(default_for("MIN_BRANCH_HIT")), 0)
        self.assertGreater(int(default_for("MIN_FUNCTION_UNION_HIT")), 0)
        self.assertGreater(float(default_for("MIN_FUNCTION_UNION")), 0)
        self.assertGreater(int(default_for("MIN_BRANCH_UNION_HIT")), 0)
        self.assertGreater(float(default_for("MIN_BRANCH_UNION")), 0)

        invocation = re.search(
            r'^python3 scripts/coverage_suite_report\.py .+$',
            script,
            re.MULTILINE,
        )
        self.assertIsNotNone(invocation)
        self.assertIn('"$MIN_FUNCTION_UNION_HIT"', invocation.group(0))
        self.assertIn('"$MIN_FUNCTION_UNION"', invocation.group(0))

    def test_function_union_ratchets_fail_independently_of_weighted_rates(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cov = root / "coverage"
            cov.mkdir()
            log = root / "run.log"
            report = root / "report.json"
            log.write_text("ok   test_a.vibe\n")
            self.write_cov(
                cov,
                "test_a.vibe",
                hit=100,
                total=100,
                hit_fns=["covered"],
                missed_fns=["missed"],
            )
            output = io.StringIO()
            with redirect_stdout(output):
                result = main([
                    str(log), str(cov), str(report),
                    "0", "0", "0", "0", "0", "0", "0",
                    "2", "60",
                ])

        self.assertEqual(result, 1)
        self.assertIn("FUNCTION_UNION_HIT ratchet", output.getvalue())
        self.assertIn("FUNCTION_UNION)", output.getvalue())

    def write_cov(self, directory, entry, *, hit, total, hit_fns, missed_fns, branch_hit=0, branch_total=0,
                  branch_per_fn=None):
        path = directory / (entry.replace("/", "_").removesuffix(".vibe") + ".json")
        branch = {"hit": branch_hit, "total": branch_total}
        if branch_per_fn is not None:
            branch["per_fn"] = branch_per_fn
        path.write_text(json.dumps({
            "hit": hit, "total": total,
            "hit_fns": hit_fns, "missed_fns": missed_fns,
            "branch": branch,
        }))

    def build(self, cases, log_lines=None):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cov = root / "coverage"
            cov.mkdir()
            log = root / "run.log"
            log.write_text(log_lines or "".join(f"ok   {entry}\n" for entry in cases))
            for entry, kwargs in cases.items():
                self.write_cov(cov, entry, **kwargs)
            return build_report(str(log), str(cov))

    def test_keeps_entry_weighted_metrics_separate_from_function_union(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cov = root / "coverage"
            cov.mkdir()
            log = root / "run.log"
            log.write_text("ok   test_a.vibe\nok   test_b.vibe\n")
            self.write_cov(cov, "test_a.vibe", hit=1, total=3, hit_fns=["shared", "a"], missed_fns=["b"], branch_hit=1, branch_total=4)
            self.write_cov(cov, "test_b.vibe", hit=1, total=3, hit_fns=["shared", "b"], missed_fns=["a"], branch_hit=2, branch_total=4)

            report = build_report(str(log), str(cov))

        self.assertEqual(report["entry_weighted"]["function"], {"hit": 2, "total": 6, "rate": 33.33})
        self.assertEqual(report["entry_weighted"]["branch"], {"hit": 3, "total": 8, "rate": 37.5})
        self.assertEqual(report["function_union"], {"hit": 3, "total": 3, "rate": 100.0})
        self.assertNotIn("fn_rate", report)
        self.assertNotIn("branch_rate", report)

    def test_branch_union_counts_each_source_branch_once(self):
        # `shared` is linked by both entries, which take opposite branches of
        # it.  Entry-weighted sees 2 of 4 (the function's branches counted
        # twice); the union sees the source truth: both branches are covered.
        common = dict(hit=1, total=1, hit_fns=["shared"], missed_fns=[])
        report = self.build({
            "test_a.vibe": dict(**common, branch_hit=1, branch_total=2,
                                branch_per_fn={"shared": {"total": 2, "hit": 1, "mask": "10"}}),
            "test_b.vibe": dict(**common, branch_hit=1, branch_total=2,
                                branch_per_fn={"shared": {"total": 2, "hit": 1, "mask": "01"}}),
        })

        self.assertEqual(report["entry_weighted"]["branch"], {"hit": 2, "total": 4, "rate": 50.0})
        self.assertEqual(report["branch_union"], {"hit": 2, "total": 2, "rate": 100.0, "exact": True})

    def test_branch_union_widens_to_the_largest_shape_seen_for_a_function(self):
        # The same source function can lower to a different branch count per
        # entry program (specialization).  The union must not lose the extra
        # branches, and unhit trailing ordinals stay counted as missed.
        common = dict(hit=1, total=1, hit_fns=["f"], missed_fns=[])
        report = self.build({
            "test_a.vibe": dict(**common, branch_hit=1, branch_total=2,
                                branch_per_fn={"f": {"total": 2, "hit": 1, "mask": "10"}}),
            "test_b.vibe": dict(**common, branch_hit=1, branch_total=4,
                                branch_per_fn={"f": {"total": 4, "hit": 1, "mask": "0100"}}),
        })

        self.assertEqual(report["branch_union"], {"hit": 2, "total": 4, "rate": 50.0, "exact": True})

    def test_branch_union_is_flagged_inexact_without_masks(self):
        # A coverage JSON from before masks existed still contributes its
        # denominator, so the union stays a lower bound rather than claiming
        # branches it cannot prove -- but it must announce that it is one.
        report = self.build({
            "test_a.vibe": dict(hit=1, total=1, hit_fns=["f"], missed_fns=[],
                                branch_hit=1, branch_total=2,
                                branch_per_fn={"f": {"total": 2, "hit": 1}}),
        })

        self.assertEqual(report["branch_union"], {"hit": 0, "total": 2, "rate": 0.0, "exact": False})

    def test_same_named_test_blocks_in_different_entries_stay_distinct(self):
        # Codex review on #1668: `__test_<name>` carries no source qualification,
        # so two entries that spell a test block the same lower to the same
        # function name. Real case in the suite: hashmap_test.vibe and
        # sortedmap_test.vibe both declare `test "empty map"` and their blocks
        # have DIFFERENT branch counts (2 vs 4). Keyed on the name alone the
        # union merges them -- the denominator loses the smaller one and a
        # branch taken in one test marks a different branch covered in the
        # other. Both blocks must be counted separately: 1 + 2 of 2 + 4.
        common = dict(hit=1, total=1, hit_fns=[], missed_fns=[])
        report = self.build({
            "a_test.vibe": dict(**common, branch_hit=1, branch_total=2,
                                branch_per_fn={"__test_empty map": {"total": 2, "hit": 1, "mask": "10"}}),
            "b_test.vibe": dict(**common, branch_hit=2, branch_total=4,
                                branch_per_fn={"__test_empty map": {"total": 4, "hit": 2, "mask": "0110"}}),
        })

        self.assertEqual(report["branch_union"], {"hit": 3, "total": 6, "rate": 50.0, "exact": True})

    def test_entry_local_names_do_not_split_genuinely_shared_functions(self):
        # The other half of the same rule: plenty of genuinely shared ids also
        # lack a source suffix (`Array::map`, `T::equals`). Folding the entry
        # into THOSE would inflate the denominator instead, so only the
        # synthesized per-entry names may be qualified.
        common = dict(hit=1, total=1, hit_fns=[], missed_fns=[])
        report = self.build({
            "a_test.vibe": dict(**common, branch_hit=1, branch_total=2,
                                branch_per_fn={"Array::map": {"total": 2, "hit": 1, "mask": "10"}}),
            "b_test.vibe": dict(**common, branch_hit=1, branch_total=2,
                                branch_per_fn={"Array::map": {"total": 2, "hit": 1, "mask": "01"}}),
        })

        self.assertEqual(report["branch_union"], {"hit": 2, "total": 2, "rate": 100.0, "exact": True})

    def test_function_union_separates_per_entry_start_wrappers(self):
        # Every entry emits its own `_start`. Counting them as one function is
        # the same merge bug on the function metric -- it was there before the
        # branch union existed.
        report = self.build({
            "a_test.vibe": dict(hit=1, total=2, hit_fns=["_start"], missed_fns=["shared"]),
            "b_test.vibe": dict(hit=0, total=2, hit_fns=[], missed_fns=["_start", "shared"]),
        })

        # `shared` counted once (missed in both); the two `_start`s counted
        # separately, one hit.
        self.assertEqual(report["function_union"], {"hit": 1, "total": 3, "rate": 33.33})

    def test_failing_entries_contribute_no_branch_union(self):
        report = self.build(
            {"test_a.vibe": dict(hit=0, total=1, hit_fns=[], missed_fns=["f"],
                                 branch_hit=0, branch_total=2,
                                 branch_per_fn={"f": {"total": 2, "hit": 0, "mask": "00"}})},
            log_lines="FAIL test_a.vibe\n",
        )

        self.assertEqual(report["branch_union"], {"hit": 0, "total": 0, "rate": 0.0, "exact": True})


if __name__ == "__main__":
    unittest.main()
