#!/usr/bin/env python3
"""Mutation tests for bootstrap validation-product reuse (#3482)."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).with_name('seed_validation_receipt.py')


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'scripts/wasm_vibe_host_runner.js').write_text('host-v1')
        self.runner = self.root / 'scripts/run_wasm_vibe_host_runner.sh'
        self.runner.write_text('runner-v1')
        self.source = self.root / 'source.vibe'
        self.source.write_text('export fn cli_main() -> Int { 42 }\n')
        self.seed = self.root / 'seed.wasm'
        self.seed.write_bytes(b'seed-v1')
        self.product = self.root / 'checked.wasm'
        self.product.write_bytes(b'validated-wasm')
        self.request = self.root / 'request.json'
        self.published = self.root / 'published.vibe'
        self.out = self.root / 'stage1.wasm'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('VIBE_')}

    def invoke(self, mode, *args, entry='cli_main', env=None):
        return subprocess.run([sys.executable, str(HELPER), mode,
            '--root', str(self.root), '--scripts', str(self.root / 'scripts'),
            '--source', str(self.source), '--seed', str(self.seed),
            '--runner', str(self.runner), '--entry', entry, *map(str, args)],
            env=self.env | (env or {}), capture_output=True, text=True)

    def save_request(self):
        result = self.invoke('request')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.request.write_text(result.stdout)

    def publish(self):
        self.save_request()
        result = self.invoke('publish', '--request', self.request,
                             '--product', self.product, '--destination', self.published)
        self.assertEqual(result.returncode, 0, result.stderr)

    def consume(self, **kwargs):
        return self.invoke('consume', '--receipt-source', self.published,
                           '--destination', self.out, **kwargs)

    def test_copied_source_reuses_exact_product(self):
        self.publish()
        self.out.write_bytes(b'old-complete-output')
        result = self.consume()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.out.read_bytes(), self.product.read_bytes())
        self.assertEqual(self.published.read_bytes(), self.source.read_bytes())

    def test_mutations_refuse_without_touching_old_output(self):
        for target in ['source', 'seed', 'runner', 'host', 'product', 'receipt', 'published']:
            with self.subTest(target=target):
                self.publish()
                self.out.write_bytes(b'old-complete-output')
                paths = {'source': self.source, 'seed': self.seed, 'runner': self.runner,
                    'host': self.root / 'scripts/wasm_vibe_host_runner.js',
                    'product': Path(str(self.published) + '.seed-validation.wasm'),
                    'receipt': Path(str(self.published) + '.seed-validation.json'),
                    'published': self.published}
                path = paths[target]
                original = path.read_bytes()
                path.write_bytes(original + b'changed')
                self.assertNotEqual(self.consume().returncode, 0)
                self.assertEqual(self.out.read_bytes(), b'old-complete-output')
                path.write_bytes(original)

    def test_entry_and_unknown_environment_change_refuse(self):
        self.publish()
        for kwargs in [{'entry': 'main'}, {'env': {'VIBE_NEW_COMPILER_OPTION': '1'}},
                       {'env': {'NODE_OPTIONS': '--no-warnings'}},
                       {'env': {'VIBE_IMPORT_ABI': 'tagged'}},
                       {'env': {'VIBE_RC': '1'}}]:
            with self.subTest(kwargs=kwargs):
                self.assertNotEqual(self.consume(**kwargs).returncode, 0)
                self.assertFalse(self.out.exists())

    def test_failed_or_interrupted_producer_preserves_previous_publication(self):
        self.publish()
        old_source = self.published.read_bytes()
        old_receipt = Path(str(self.published) + '.seed-validation.json').read_bytes()
        self.save_request()
        self.source.write_text('invalid candidate')
        result = self.invoke('publish', '--request', self.request,
                             '--product', self.product, '--destination', self.published)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.published.read_bytes(), old_source)
        self.assertEqual(Path(str(self.published) + '.seed-validation.json').read_bytes(), old_receipt)
        self.source.write_bytes(old_source)
        Path(str(self.published) + '.seed-validation.wasm').write_bytes(b'interrupted-new-product')
        self.assertNotEqual(self.consume().returncode, 0)

    def test_missing_or_old_schema_receipt_refuses(self):
        self.assertNotEqual(self.consume().returncode, 0)
        self.publish()
        receipt = Path(str(self.published) + '.seed-validation.json')
        data = json.loads(receipt.read_text()); data['schema'] = -1
        receipt.write_text(json.dumps(data))
        self.assertNotEqual(self.consume().returncode, 0)

    def test_malformed_json_shapes_refuse_cleanly_and_preserve_output(self):
        self.publish()
        receipt = Path(str(self.published) + '.seed-validation.json')
        self.out.write_bytes(b'old-complete-output')
        for value in [None, [], {'schema': 1, 'request': []}, {'schema': 1, 'request': 7}]:
            with self.subTest(value=value):
                receipt.write_text(json.dumps(value))
                result = self.consume()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('Traceback', result.stderr)
                self.assertEqual(self.out.read_bytes(), b'old-complete-output')

    def test_policy_and_path_sensitive_modes_refuse(self):
        for name in ['VIBE_POLICY_RAW_FS_ROOT', 'VIBE_FS_COMPILE', 'VIBE_INPUT',
                     'VIBE_OUTPUT', 'VIBE_ENTRY', 'VIBE_LINE_MAP', 'VIBE_EMIT_MODULE_SOURCE',
                     'VIBE_WASM_NAMES', 'VIBE_NODE_EXTRA_FLAGS', 'VIBE_ENTRY_TESTMETA_OUT']:
            with self.subTest(name=name):
                self.assertNotEqual(self.invoke('request', env={name: '1'}).returncode, 0)

    def test_orchestration_environment_does_not_change_request(self):
        first = self.invoke('request')
        second = self.invoke('request', env={'VIBE_ADAPTER_MODULE_SOURCE_OUT': '/output',
            'VIBE_MODULE_SOURCE_ENTRY_NAME': 'cli_main', 'VIBE_TRACE_OUT': '/trace',
            'VIBE_GENERATION_VALIDATE_RUN': '0', 'GITHUB_ACTION': '__run_2'})
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(first.stdout), json.loads(second.stdout))

    def test_restored_ci_product_survives_job_identity_but_not_compile_changes(self):
        self.env |= {'GITHUB_JOB': 'compiler-build', 'GITHUB_WORKFLOW': 'CI',
            'GITHUB_WORKFLOW_REF': 'mizchi/vibe-lang/.github/workflows/ci.yml@main',
            'GITHUB_WORKFLOW_SHA': 'workflow-a', 'GITHUB_RUN_ID': '100',
            'GITHUB_SHA': 'commit-a', 'GITHUB_REF': 'refs/heads/main',
            'GITHUB_EVENT_NAME': 'push', 'GITHUB_HEAD_REF': '',
            'GITHUB_RUN_NUMBER': '10', 'GITHUB_RUN_ATTEMPT': '1',
            'GITHUB_ACTOR': 'builder', 'GITHUB_ACTOR_ID': '1',
            'GITHUB_TRIGGERING_ACTOR': 'builder', 'GITHUB_EVENT_PATH': '/event/a.json',
            'RUNNER_NAME': 'runner-a', 'RUNNER_TRACKING_ID': 'tracking-a',
            'RUNNER_TEMP': '/runner/a/temp'}
        self.publish()
        self.env |= {'GITHUB_JOB': 'compiler-gate', 'GITHUB_WORKFLOW': 'Flaker CI',
            'GITHUB_WORKFLOW_REF': 'mizchi/vibe-lang/.github/workflows/flaker-ci.yml@main',
            'GITHUB_WORKFLOW_SHA': 'workflow-b', 'GITHUB_RUN_ID': '200',
            'GITHUB_SHA': 'commit-b', 'GITHUB_REF': 'refs/pull/1/merge',
            'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_HEAD_REF': 'feature',
            'GITHUB_RUN_NUMBER': '20', 'GITHUB_RUN_ATTEMPT': '2',
            'GITHUB_ACTOR': 'tester', 'GITHUB_ACTOR_ID': '2',
            'GITHUB_TRIGGERING_ACTOR': 'tester', 'GITHUB_EVENT_PATH': '/event/b.json',
            'RUNNER_NAME': 'runner-b', 'RUNNER_TRACKING_ID': 'tracking-b',
            'RUNNER_TEMP': '/runner/b/temp'}
        result = self.consume()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.out.read_bytes(), self.product.read_bytes())
        for changed in [{'VIBE_RC': '1'}, {'VIBE_IMPORT_ABI': 'tagged'},
                        {'VIBE_NODE_WASM_FLAGS': '--stack-size=4096'},
                        {'VIBE_NEW_COMPILER_OPTION': '1'},
                        {'GITHUB_UNKNOWN_COMPILER_OPTION': '1'}]:
            with self.subTest(changed=changed):
                self.out.write_bytes(b'previous-complete-output')
                self.assertNotEqual(self.consume(env=changed).returncode, 0)
                self.assertEqual(self.out.read_bytes(), b'previous-complete-output')

    def test_ci_step_file_commands_do_not_invalidate_the_validated_product(self):
        names = ['GITHUB_ENV', 'GITHUB_OUTPUT', 'GITHUB_PATH', 'GITHUB_STATE',
                 'GITHUB_STEP_SUMMARY', 'GITHUB_ARTIFACTS', 'GITHUB_ARTIFACTS_LIST']
        self.env |= {name: '/runner/producer/' + name for name in names}
        self.publish()
        self.env |= {name: '/runner/consumer/' + name for name in names}
        result = self.consume()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.out.read_bytes(), self.product.read_bytes())


if __name__ == '__main__':
    unittest.main()
