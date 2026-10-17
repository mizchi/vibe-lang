"""Reject invalid bootstrap comparisons before accepting timing evidence."""
import json
from pathlib import Path
import tempfile
import unittest

import selfbuild_baseline as baseline
import selfbuild_reuse as reuse


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.workspaces = {n: self.root / n for n in ['baseline', 'proposal']}
        for workspace in self.workspaces.values():
            corpus = workspace / 'corpus'
            (corpus / 'bootstrap/seed').mkdir(parents=True)
            (corpus / 'lib').mkdir()
            (corpus / 'lib/source.vibe').write_text('fn main() -> Int { 42 }')
            (corpus / 'bootstrap/seed/compiler.wasm').write_bytes(b'seed')
            meta = {'tracked_files': {'lib/source.vibe': {'sha256': baseline.sha(corpus / 'lib/source.vibe')}},
                    'seed': {'artifact': {'sha256': baseline.sha(corpus / 'bootstrap/seed/compiler.wasm')}},
                    'machine': {'node': 'same'}}
            baseline.write(workspace / 'workspace.json', meta)

    def test_changed_compiler_cannot_be_relabelled_as_same_input(self):
        reuse.authorities(self.workspaces)
        workspace = self.workspaces['proposal']
        source = workspace / 'corpus/lib/source.vibe'
        source.write_text('fn main() -> Int { 43 }')
        meta = json.loads((workspace / 'workspace.json').read_text())
        meta['tracked_files']['lib/source.vibe']['sha256'] = baseline.sha(source)
        baseline.write(workspace / 'workspace.json', meta)
        with self.assertRaisesRegex(ValueError, 'compiler/seed source changed'):
            reuse.authorities(self.workspaces)

    def test_cold_reset_cannot_remove_tracked_input(self):
        workspace = self.workspaces['baseline']
        corpus = workspace / 'corpus'
        path = reuse.GENERATED[0]
        (corpus / path).parent.mkdir(parents=True)
        (corpus / path).write_text('maintained input')
        meta = {'tracked_files': {path: {'sha256': baseline.sha(corpus / path)}}}
        with self.assertRaisesRegex(ValueError, 'refusing to remove maintained source'):
            reuse.cold_reset(corpus, meta)
        self.assertEqual((corpus / path).read_text(), 'maintained input')

    def test_route_matches_production_prebuilt_and_portable_cli(self):
        compiler = reuse.command('compiler')[-1]
        self.assertIn('bash scripts/ensure_generated.sh', compiler)
        self.assertIn('VIBE_PREBUILT_MODULE_SOURCE=', compiler)
        self.assertIn('--stage3', compiler)
        self.assertNotIn('--skip-run-validation', compiler)
        self.assertEqual(reuse.command('portable-cli')[1], 'scripts/build_cli_wasm.sh')
        with self.assertRaises(ValueError):
            reuse.command('unknown')

    def test_cli_publication_must_match_actual_selected_producer(self):
        corpus = self.workspaces['baseline'] / 'corpus'
        generation = corpus / '_build/selfhost/generations/explicit'
        generation.mkdir(parents=True)
        wasm = generation / 'stage2.wasm'
        wasm.write_bytes(b'actual producer')
        baseline.write(generation / 'generation.json', {'stages': {'stage2': {'sha256': baseline.sha(wasm)}}})
        (corpus / '_build/reuse-measured-cli.wasm').write_bytes(b'stale published output')
        with self.assertRaisesRegex(ValueError, 'publication differs'):
            reuse.generation(corpus, 'portable-cli')


if __name__ == '__main__':
    unittest.main()
