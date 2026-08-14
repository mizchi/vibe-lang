import json
import os
import tempfile
import unittest
from unittest import mock

import coverage_tracks


class CoverageTracksTest(unittest.TestCase):
    def run_with(self, suite=None, corpus=None, argv=(), env=None):
        with tempfile.TemporaryDirectory() as temp:
            suite_path = os.path.join(temp, "suite.json")
            corpus_path = os.path.join(temp, "corpus.json")
            if suite is not None:
                with open(suite_path, "w", encoding="utf-8") as handle:
                    json.dump(suite, handle)
            if corpus is not None:
                with open(corpus_path, "w", encoding="utf-8") as handle:
                    json.dump(corpus, handle)
            patches = {"SUITE": suite_path, "CORPUS": corpus_path}
            patches.update(env or {})
            with mock.patch.multiple(coverage_tracks, **patches):
                return coverage_tracks.main(list(argv))

    def suite_report(self, hit, total, rate, exact=True):
        return {"branch_union": {"hit": hit, "total": total, "rate": rate, "exact": exact}}

    def corpus_report(self, hit, total):
        return {"files": 12, "branch": {"hit": hit, "total": total}}

    def test_reports_both_tracks(self):
        rc = self.run_with(self.suite_report(26894, 46469, 57.88), self.corpus_report(10703, 26738))
        self.assertEqual(rc, 0)

    def test_check_passes_when_both_clear_their_floors(self):
        rc = self.run_with(
            self.suite_report(26894, 46469, 57.88), self.corpus_report(10703, 26738), argv=["--check"]
        )
        self.assertEqual(rc, 0)

    def test_check_fails_below_the_in_process_floor(self):
        rc = self.run_with(
            self.suite_report(100, 1000, 10.0), self.corpus_report(10703, 26738), argv=["--check"]
        )
        self.assertEqual(rc, 1)

    def test_a_missing_track_fails_the_check_rather_than_passing_quietly(self):
        # The whole point of two tracks is that each covers what the other
        # cannot see. A run that measured only one must not report "gate ok" --
        # an unbuilt or stale report is exactly where a regression hides.
        rc = self.run_with(self.suite_report(26894, 46469, 57.88), None, argv=["--check"])
        self.assertEqual(rc, 1)

    def test_no_report_at_all_is_distinguished_from_a_failure(self):
        # Exit 2, not 1: "nothing was measured" is a setup problem for the
        # caller to fix, not a coverage regression to investigate.
        rc = self.run_with(None, None, argv=["--check"])
        self.assertEqual(rc, 2)

    def test_a_lower_bound_union_skips_its_ratchet_instead_of_failing(self):
        # Same rule as coverage_suite.sh: never fail on a number the run could
        # not measure exactly.
        rc = self.run_with(
            self.suite_report(100, 1000, 10.0, exact=False),
            self.corpus_report(10703, 26738),
            argv=["--check"],
        )
        self.assertEqual(rc, 0)

    def test_self_compile_rate_is_computed_from_hit_and_total(self):
        with tempfile.TemporaryDirectory() as temp:
            corpus_path = os.path.join(temp, "corpus.json")
            with open(corpus_path, "w", encoding="utf-8") as handle:
                json.dump(self.corpus_report(10703, 26738), handle)
            with mock.patch.multiple(coverage_tracks, SUITE=os.path.join(temp, "none.json"),
                                     CORPUS=corpus_path):
                rows = coverage_tracks.tracks()
        self.assertEqual([r["track"] for r in rows], ["self-compile"])
        self.assertEqual(rows[0]["rate"], 40.03)


if __name__ == "__main__":
    unittest.main()
