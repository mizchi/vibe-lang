"""Reproduction convenience supplied after measurement; not a measured driver.

Run from a clean checkout of main8f7f95477. The before setup must finish before
applying the candidate patch. Native runner and compiler/image receipts are
explicit. Use a fresh ignored lab; never overwrite historical measurement data.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

root = Path.cwd()
sys.path.insert(0, str(root / 'bench/perf'))
import selfbuild_baseline as base

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['before', 'candidate', 'negative'])
parser.add_argument('lab', type=Path)
parser.add_argument('--workspace', type=Path)
parser.add_argument('--compiler', type=Path)
parser.add_argument('--images', type=Path)
a = parser.parse_args()
lab = a.lab.resolve()

def source_hashes():
    paths = [Path(p) for p in subprocess.check_output(
        ['git', 'ls-files', '--', 'lib', 'scripts', 'runtime/viberun'], text=True).splitlines()]
    paths += [Path('lib/@vibe/compiler') / name for name in [
        'compiler_sources_bundle.vibe', 'cli_adapter_bundle.vibe',
        'selfbuild_runtime_entry_bundle.vibe', '_cli_adapter_module_source.vibe',
        'cache/codegen_fingerprint.vibe']]
    return {str(p): base.sha(root / p) for p in sorted(paths) if (root / p).is_file()}

if a.action == 'before':
    assert all([a.workspace, a.compiler, a.images]), 'explicit workspace/compiler/images required'
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == '8f7f95477ded1dc62d743d900a8635e7fdccaed2'
    assert not subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()
    compiler, images, workspace = a.compiler.resolve(), a.images.resolve(), a.workspace.resolve()
    meta = json.loads((workspace / 'workspace.json').read_text())
    matrix = json.loads((workspace / 'matrix/measurement.json').read_text())
    base.verify_source(workspace / 'corpus', meta)
    assert matrix['verified_complete'] and matrix['aa_guest_memory_exact']
    producer = base.fixed_point(compiler.parent)
    receipt = json.loads((images / 'build.json').read_text())
    native = root / 'runtime/viberun/target/release/viberun'
    assert receipt['compiler_sha256'] == base.sha(compiler) == producer['stages']['stage2']['sha256']
    assert receipt['runner_sha256'] == base.sha(native)
    for name, digest in receipt['artifacts'].items():
        assert base.sha(images / name) == digest
    lab.mkdir()
    for lane in ['a0', 'aa']:
        output = lab / 'engines' / lane
        output.mkdir(parents=True)
        for name in receipt['artifacts']:
            shutil.copy2(images / name, output / name)
        shutil.copy2(images / 'build.json', output / 'build.json')
        shutil.copy2(compiler, output / 'compiler.wasm')
        shutil.copy2(native, output / 'viberun')
        for name in ['taskgroup_functions_frontend.mjs', 'taskgroup_lowering_frontend.mjs']:
            shutil.copy2(root / 'scripts' / name, output / name)
    record = {'engine_source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              'engine_source_tree': subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], text=True).strip(),
              'engine_sources': source_hashes(), 'target_workspace': str(workspace),
              'target_corpus_commit': meta['source_commit'], 'images': receipt,
              'scope': 'Fixed eeba68033 filesystem compiler/CLI corpus. Current main8f7f guest engines; '
              'before/after native runner receipts differ. Not an actual-bootstrap performance comparison.',
              'files': {str(p.relative_to(lab)): base.sha(p) for p in sorted((lab / 'engines').rglob('*')) if p.is_file()}}
    base.write(lab / 'before-authority.json', record)
elif a.action == 'candidate':
    before = json.loads((lab / 'before-authority.json').read_text())
    sources = source_hashes()
    changed = sorted(p for p, digest in sources.items() if before['engine_sources'].get(p) != digest)
    assert changed == ['runtime/viberun/src/lowering_service.rs', 'scripts/test_taskgroup_functions.py'], changed
    patch = subprocess.check_output(['git', 'diff', '--', *changed])
    (lab / 'source-overlay.patch').write_bytes(patch)
    base.write(lab / 'build-authority.json', {
        'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'patch_sha256': base.sha(lab / 'source-overlay.patch'), 'sources': sources,
        'scope': 'Host-only streaming context verification. Guest compiler sources unchanged; '
        'current source runner and matching3 images rebuilt by build_validate.py.'})
else:
    crate = lab / 'negative-crate'
    crate.mkdir()
    for name in ['Cargo.toml', 'Cargo.lock']:
        shutil.copy2(root / 'runtime/viberun' / name, crate / name)
    shutil.copytree(root / 'runtime/viberun/src', crate / 'src')
    path = crate / 'src/lowering_service.rs'
    text = path.read_text()
    start = text.index('    let mut reader = reader.take(INPUT_LIMIT as u64 + 1);')
    end = text.index('\n    Ok(())\n}', start)
    buffered = '''    let mut context = Vec::new();
    reader.take(INPUT_LIMIT as u64 + 1).read_to_end(&mut context)?;
    if context.len() != expected_bytes || <[u8; 32]>::from(Sha256::digest(&context)) != expected_hash {
        bail!("lowering: shared context changed after preparation");
    }'''
    path.write_text(text[:start] + buffered + text[end:])
    print('Run cargo test --release for context_verification_has_bounded_read_requests with this manifest. '
          'Compilation must succeed, and the test must fail with context read request exceeds64KiB.')
