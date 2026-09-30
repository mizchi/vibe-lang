import unittest
from review_lint_metadata_diff import filter_diff


class MetadataDiffTest(unittest.TestCase):
    def patch(self, before, after):
        self.snapshots = {'pass.vibe': (before, after)}
        return 'diff --git a/pass.vibe b/pass.vibe\n--- a/pass.vibe\n+++ b/pass.vibe\n@@ -1 +1 @@\n' + ''.join('-' + x + '\n' for x in before.splitlines()) + ''.join('+' + x + '\n' for x in after.splitlines())

    def filtered(self, diff):
        return filter_diff(diff, self.snapshots)

    def test_empty_metadata_only(self):
        before = 'ELet("__old", ECall(f, [ECall(g, [], 1)], 2), body, -1)'
        after = 'ELet("__old", ECall(f, [ECall(g, [], 1, [])], 2, []), body, -1)'
        self.assertNotIn('@@ ', self.filtered(self.patch(before, after)))

    def test_new_binder_is_still_reportable(self):
        before = 'ELet("__old", ECall(f, [], 2), body, -1)'
        after = 'ELet("__new", ECall(f, [], 2, []), body, -1)'
        diff = self.patch(before, after)
        self.assertEqual(diff, self.filtered(diff))

    def test_nonempty_resolution_retains_hunk(self):
        diff = self.patch('ECall(f, [], 2)', 'ECall(f, [], 2, [2])')
        self.assertEqual(diff, self.filtered(diff))

    def test_comment_removal_retains_hunk(self):
        diff = self.patch('ECall(f, [], 2) // review-lint: allow-fixed-synthetic-name', 'ECall(f, [], 2, [])')
        self.assertEqual(diff, self.filtered(diff))

    def test_string_contents_are_not_code(self):
        diff = self.patch('"ECall(f, [], 2)"', '"ECall(f, [], 2, [])"')
        self.assertEqual(diff, self.filtered(diff))

    def test_other_changes_in_same_hunk_remain(self):
        diff = self.patch('ECall(f, [], 2)\nlet x = 1', 'ECall(f, [], 2, [])\nlet x = 2')
        self.assertEqual(diff, self.filtered(diff))

    def test_interpolated_strings_remain_literal_tokens(self):
        diff = self.patch('ECall(f, ["\\{x}"], 2)', 'ECall(f, ["\\{x}"], 2, [])')
        self.assertNotIn('@@ ', self.filtered(diff))
        changed = self.patch('\"\\{ECall(f, [], 2)}\"', '\"\\{ECall(f, [], 2, [])}\"')
        self.assertEqual(changed, self.filtered(changed))

    def test_multiline_metadata_only(self):
        diff = self.patch('ECall(f, [], 2)', 'ECall(f, [], 2,\n [])')
        self.assertNotIn('@@ ', self.filtered(diff))


    def test_scope_change_outside_call_hunk_retains_file(self):
        before = 'fn f(x) { ELet("__x", ECall(g, [], 0), x, -1) }'
        after = 'fn f(__x) { ELet("__x", ECall(g, [], 0, []), x, -1) }'
        diff = self.patch(before, after)
        self.assertEqual(diff, self.filtered(diff))

    def test_forwarded_resolution_is_annotation_only(self):
        before = 'ECall(f, args, off) => ECall(f, args, off)'
        after = 'ECall(f, args, off, callee_resolution) => ECall(f, args, off, callee_resolution)'
        self.assertNotIn('@@ ', self.filtered(self.patch(before, after)))


if __name__ == '__main__':
    unittest.main()
