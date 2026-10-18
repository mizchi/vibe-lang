#!/usr/bin/env python3
"""Exercise real bootstrap scripts with an observable, failing seed runner."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import shlex
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent


class BootstrapReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for d in ['bootstrap/seed', 'scripts', 'lib/@vibe/compiler']:
            (self.root / d).mkdir(parents=True)
        compiler = self.root / 'lib/@vibe/compiler'
        (compiler / 'compiler_sources_manifest.tsv').write_text('core\tpolyfill.vibe\nentry\tcli_adapter.vibe\n')
        (compiler / 'polyfill.vibe').write_text('let answer = () -> Int { 42 }\n')
        (compiler / 'cli_adapter.vibe').write_text('import ./polyfill.vibe { answer }\nlet cli_main = () -> Int { answer() }\n')
        (self.root / 'bootstrap/seed/compiler.wasm').write_bytes(b'pinned-seed')
        seed = {'name': 'test', 'entry': 'lib/@vibe/compiler/cli_support.vibe', 'entry_name': 'cli_main',
            'artifact': {'path': 'bootstrap/seed/compiler.wasm', 'sha256': hashlib.sha256(b'pinned-seed').hexdigest()}}
        (self.root / 'bootstrap/seed.json').write_text(json.dumps({'schema': 1, 'seed': seed}))
        for name in ['generate_bundle.sh', 'trace_lib.sh', 'bundle_source_functions.py',
                     'seed_validation_receipt.py']:
            path = REPO / 'scripts' / name
            if path.exists():
                shutil.copy2(path, self.root / 'scripts' / name)
        for path in (REPO / 'scripts').glob('wasm_vibe_host_*.*'):
            if path.is_file():
                shutil.copy2(path, self.root / 'scripts' / path.name)
        (self.root / 'scripts/run_wasm_vibe_host_runner.sh').write_text('''#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --invoke ] && [ "$2" = cli_main ]
infile="$4"; outfile="$5"; entry="$6"
printf '%s %s %s\n' "$infile" "$outfile" "$entry" >> invocations.log
if [ "${VIBE_EMIT_MERGED_SOURCE:-0}" = 1 ] || [ "${VIBE_EMIT_MODULE_SOURCE:-0}" = 1 ]; then
  printf 'let cli_main = () -> Int { 42 }\nlet main = () -> Unit { () }\n' > "$outfile"
else
  if [ "${FAIL_VALIDATION:-0}" = 1 ] && [[ "$outfile" == *module_source_validate* ]]; then
    printf 'injected invalid-source diagnostic\n' > "$outfile.diag"
    exit 7
  fi
  printf 'wasm entry=%s\n' "$entry" > "$outfile"
fi
''')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('VIBE_')}
        self.env |= {'VIBE_PROJECT_ROOT': str(self.root), 'VIBE_BUNDLE_EXTRA_ENTRIES': '',
            'VIBE_GENERATION_VALIDATE_WASM': '0', 'VIBE_GENERATION_VALIDATE_RUN': '0',
            'VIBE_IMPORT_ABI': 'raw'}

    def build(self, entry='cli_main', prebuilt=None):
        env = self.env.copy()
        if prebuilt:
            env['VIBE_PREBUILT_MODULE_SOURCE'] = str(prebuilt)
        return subprocess.run(['bash', str(REPO / 'scripts/generations.sh'), 'build',
            '--out-dir', str(self.root / 'out'), '--entry-name', entry, '--stage3'],
            cwd=self.root, env=env, capture_output=True, text=True)

    def calls(self):
        return (self.root / 'invocations.log').read_text().splitlines()

    def test_generated_source_reuses_validation_at_both_entries(self):
        for entry in ['cli_main', 'main']:
            with self.subTest(entry=entry):
                (self.root / 'invocations.log').unlink(missing_ok=True)
                result = self.build(entry)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertIn('reuse verified seed validation as stage1', result.stderr)
                calls = self.calls()
                self.assertEqual(sum('module_source_validate.' in c for c in calls), 1)
                self.assertFalse(any('/stage1.wasm ' in c for c in calls))
                self.assertEqual(sum('/stage2.wasm ' in c for c in calls), 1)
                self.assertEqual(sum('/stage3.wasm ' in c for c in calls), 1)
                self.assertEqual((self.root / 'out/stage1.wasm').read_text(), f'wasm entry={entry}\n')
                self.assertEqual((self.root / 'out/stage2.wasm').read_bytes(), (self.root / 'out/stage3.wasm').read_bytes())

    def test_prebuilt_receipt_hit_and_mutated_product_fallback(self):
        self.env |= {'GITHUB_JOB': 'compiler-build', 'GITHUB_WORKFLOW': 'CI',
                     'RUNNER_NAME': 'producer', 'RUNNER_TRACKING_ID': 'producer-id',
                     'GITHUB_ARTIFACTS': '/producer/artifacts',
                     'GITHUB_ARTIFACTS_LIST': '/producer/artifact-list'}
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        # Use a separate destination, as ensure_generated -> bootstrap does.
        prebuilt = self.root / 'prepared.vibe'
        for suffix in ['', '.seed-validation.wasm', '.seed-validation.json']:
            prebuilt.with_name(prebuilt.name + suffix).write_bytes(
                Path(str(self.root / 'out/cli_adapter_module_source.vibe') + suffix).read_bytes())
        self.env |= {'GITHUB_JOB': 'compiler-gate', 'GITHUB_WORKFLOW': 'Flaker CI',
                     'RUNNER_NAME': 'consumer', 'RUNNER_TRACKING_ID': 'consumer-id',
                     'GITHUB_ARTIFACTS': '/consumer/artifacts',
                     'GITHUB_ARTIFACTS_LIST': '/consumer/artifact-list',
                     'COMPILER_GATE_LANE': 'bootstrap',
                     'COMPILER_GATE_SKIP_PREFLIGHT': '1',
                     'COMPILER_GATE_SKIP_STAGE2_ORACLES': '1'}
        (self.root / 'invocations.log').write_text('')
        result = self.build(prebuilt=prebuilt)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reuse verified seed validation as stage1', result.stderr)
        self.assertEqual(len(self.calls()), 2)
        Path(str(prebuilt) + '.seed-validation.wasm').write_bytes(b'broken-product')
        (self.root / 'invocations.log').write_text('')
        result = self.build(prebuilt=prebuilt)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no matching validation product; compile stage1', result.stderr)
        self.assertEqual(len(self.calls()), 3)
        self.assertNotEqual((self.root / 'out/stage1.wasm').read_bytes(), b'broken-product')

    def test_unsupported_abi_mismatch_compiles_fresh(self):
        # The fake seed has no raw ABI imports, so auto detection chooses the
        # tagged fallback. Its raw validation product must NOT satisfy stage1.
        del self.env['VIBE_IMPORT_ABI']
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('reuse verified seed validation as stage1', result.stderr)
        self.assertTrue(any('/stage1.wasm ' in c for c in self.calls()))

    def test_failed_validation_keeps_old_source_and_receipt(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        source = self.root / 'out/cli_adapter_module_source.vibe'
        old = {s: Path(str(source) + s).read_bytes() for s in ['', '.seed-validation.json', '.seed-validation.wasm']}
        self.env['FAIL_VALIDATION'] = '1'
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('injected invalid-source diagnostic', result.stderr)
        self.assertIn('#979 sticky-failure guard', result.stderr)
        for suffix, content in old.items():
            self.assertEqual(Path(str(source) + suffix).read_bytes(), content)

    def test_cwd_sensitive_python_keeps_caller_relative_publication(self):
        caller = self.root / 'caller'
        caller.mkdir()
        wrappers = self.root / 'python-shims'
        wrappers.mkdir()
        shim = wrappers / 'python3'
        shim.write_text('#!/usr/bin/env bash\nexport PYENV_DIR="$PWD"\nexec ' +
                        shlex.quote(sys.executable) + ' "$@"\n')
        shim.chmod(0o755)
        env = self.env | {'PATH': str(wrappers) + os.pathsep + self.env.get('PATH', ''),
                         'VIBE_ADAPTER_MODULE_SOURCE_OUT': 'published.vibe'}
        result = subprocess.run(['bash', str(self.root / 'scripts/generate_bundle.sh')],
                                cwd=caller, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        destination = caller / 'published.vibe'
        self.assertTrue(destination.is_file())
        receipt = json.loads(Path(str(destination) + '.seed-validation.json').read_text())
        self.assertEqual(receipt['request']['source_sha256'], hashlib.sha256(destination.read_bytes()).hexdigest())
        self.assertEqual(Path(str(destination) + '.seed-validation.wasm').read_text(), 'wasm entry=cli_main\n')
        self.assertFalse((self.root / 'published.vibe').exists())


if __name__ == '__main__':
    unittest.main()
