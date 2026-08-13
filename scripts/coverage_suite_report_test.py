import json
import tempfile
import unittest
from pathlib import Path

from coverage_suite_report import build_report


class CoverageSuiteReportTest(unittest.TestCase):
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
