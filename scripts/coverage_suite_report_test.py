import json
import tempfile
import unittest
from pathlib import Path

from coverage_suite_report import build_report


class CoverageSuiteReportTest(unittest.TestCase):
    def write_cov(self, directory, entry, *, hit, total, hit_fns, missed_fns, branch_hit=0, branch_total=0):
        path = directory / (entry.replace("/", "_").removesuffix(".vibe") + ".json")
        path.write_text(json.dumps({
            "hit": hit, "total": total,
            "hit_fns": hit_fns, "missed_fns": missed_fns,
            "branch": {"hit": branch_hit, "total": branch_total},
        }))

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


if __name__ == "__main__":
    unittest.main()
