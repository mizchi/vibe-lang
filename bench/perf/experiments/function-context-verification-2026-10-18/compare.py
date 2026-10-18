"""Host context-verification A/B: fixed corpus, explicit matching runners, N3.

Copy this file into the staged ignored experiment directory. `stage` requires
before-authority.json, build-authority.json, preserved engines/a0 and engines/aa,
candidate-images, and the newly built source-bound native runner. `run` checks
all receipts and source hashes before/after. No timing is taken by stage.
"""
import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / 'bench/perf'))
import selfbuild_baseline as base

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['stage', 'run'])
a = parser.parse_args()
root = Path.cwd()
lab = Path(__file__).resolve().parent
before = json.loads((lab / 'before-authority.json').read_text())
built = json.loads((lab / 'build-authority.json').read_text())
workspace = Path(before['target_workspace'])
corpus = workspace / 'corpus'
meta = json.loads((workspace / 'workspace.json').read_text())
reference = json.loads((workspace / 'matrix/measurement.json').read_text())
assert reference['verified_complete']
engines = lab / 'engines'

def image_files():
    return {str(p.relative_to(lab)): base.sha(p)
            for lane in ['a0', 'b0', 'aa']
            for p in sorted((engines / lane).iterdir()) if p.is_file()}

def verify_sources():
    base.verify_source(corpus, meta)
    for name, digest in built['sources'].items():
        assert base.sha(root / name) == digest, ('source changed', name)
    assert base.sha(lab / 'source-overlay.patch') == built['patch_sha256']
    for name, digest in reference['input_sha256'].items():
        assert base.sha(corpus / name) == digest, ('target input changed', name)

verify_sources()
if a.action == 'stage':
    validated = json.loads((lab / 'validation.json').read_text())
    assert validated['complete'] and all(step['exit'] == 0 for step in validated['steps'])
    destination = engines / 'b0'
    destination.mkdir()
    receipt = json.loads((lab / 'candidate-images/build.json').read_text())
    native = root / 'runtime/viberun/target/release/viberun'
    assert receipt['runner_sha256'] == base.sha(native) != before['images']['runner_sha256']
    assert receipt['artifacts'] == before['images']['artifacts']
    assert receipt['compiler_sha256'] == before['images']['compiler_sha256']
    for name, digest in receipt['artifacts'].items():
        assert base.sha(lab / 'candidate-images' / name) == digest
        shutil.copy2(lab / 'candidate-images' / name, destination / name)
    shutil.copy2(lab / 'candidate-images/build.json', destination / 'build.json')
    shutil.copy2(engines / 'a0/compiler.wasm', destination / 'compiler.wasm')
    shutil.copy2(native, destination / 'viberun')
    for name in ['taskgroup_functions_frontend.mjs', 'taskgroup_lowering_frontend.mjs']:
        assert base.sha(root / 'scripts' / name) == base.sha(engines / 'a0' / name)
        shutil.copy2(root / 'scripts' / name, destination / name)
    for name, digest in before['files'].items():
        assert base.sha(lab / name) == digest, ('preserved before file changed', name)
    authority = {'files': image_files(), 'harness_sha256': base.sha(__file__),
                 'before_authority_sha256': base.sha(lab / 'before-authority.json'),
                 'build_authority_sha256': base.sha(lab / 'build-authority.json'),
                 'machine': meta['machine'], 'baseline_artifacts': reference['artifacts'],
                 'scope': before['scope'], 'protocol':
                 'Current main8f7f guest engines; native before/after source-bound runners differ. '
                 'Same frozen eeba68033 filesystem corpus, targetRC1; bump parent/worker and RC coordinator. '
                 'Three cold/warm rounds, reversed pair order, equal-length lane/cache/output paths, '
                 'fresh private guest caches, native JIT primed on another input, no overlapping builds/profiles. '
                 'Ordinary, same-driver serial, process workers1/2/4, ordinary identical-before A/A controls. '
                 'Whole public frontend wall and simultaneous process-tree RSS20ms. Full timelines only for p4; '
                 'phase boundaries are sampling bounds, not allocation lifetimes. Shared mappings may double count. '
                 'Not actual bootstrap/thread/default promotion.'}
    base.write(lab / 'comparison-authority.json', authority)
    print('Staged differing native runners with matching image receipts and identical guest engines.', flush=True)
    sys.exit()

authority = json.loads((lab / 'comparison-authority.json').read_text())
assert authority['files'] == image_files()
assert authority['harness_sha256'] == base.sha(__file__)
assert authority['before_authority_sha256'] == base.sha(lab / 'before-authority.json')
assert authority['build_authority_sha256'] == base.sha(lab / 'build-authority.json')
for lane in ['a0', 'b0', 'aa']:
    image = engines / lane
    receipt = json.loads((image / 'build.json').read_text())
    assert receipt['runner_sha256'] == base.sha(image / 'viberun')
    assert receipt['compiler_sha256'] == base.sha(image / 'compiler.wasm')
    assert receipt['function_abi'] == 'bump-core-tagged-callbacks-2'
    assert receipt['context_format'] == 6 and receipt['job_format'] == 2
    for name, digest in receipt['artifacts'].items():
        assert base.sha(image / name) == digest

def command(lane, mode, source, entry, private):
    image = engines / lane
    native = image / 'viberun'
    env = base.clean_env(corpus) | {'VIBE_RC': '1', 'VIBE_FS_COMPILE': '1', 'VIBE_MEM': '1',
        'VIBE_BUILD_CACHE_DIR': str(private / 'cache'), 'VIBE_NATIVE_CACHE_DIR': str(lab / 'native-cache')}
    if mode == 'o0':
        cmd = [str(native), str(image / 'compiler.wasm'), source, str(private / 'out.wasm'), entry]
    elif mode == 's0':
        cmd = [str(native), str(image / 'compile.wasm')]
        env.update(VIBE_LOWERING_MODE='serial', VIBE_LOWERING_INPUT=source,
                   VIBE_LOWERING_OUTPUT=str(private / 'out.wasm'), VIBE_LOWERING_ENTRY=entry)
    else:
        cmd = ['node', str(image / 'taskgroup_functions_frontend.mjs'), str(image / 'compiler.wasm'),
               source, str(private / 'out.wasm'), entry, mode[1], str(corpus), str(image), str(native)]
        env['VIBE_FUNCTION_TRACE_OUT'] = str(private / 'trace.json')
    return cmd, env

runs = lab / 'comparison'
runs.mkdir()
for lane in ['a0', 'b0']:
    for mode in ['o0', 's0', 'p1']:
        private = runs / f'prime-{lane}-{mode}'
        private.mkdir()
        cmd, env = command(lane, mode, 'perf-smoke.vibe', 'main', private)
        base.measure(cmd, corpus, env, private / 'logs')
rows = []
report = {'authority': authority, 'samples': rows, 'verified_complete': False,
          'expected_samples': 132, 'rounds': 3}
original = base.snapshot
for subject, prefix, source, entry in [
        ('compiler', 'c', 'lib/@vibe/compiler/tests/codegen_lexer_test.vibe', '__no_entry__'),
        ('split-cli', 'l', 'lib/@vibe/cli/entry.vibe', 'cli_main')]:
    for rnd in range(3):
        for mode in ['o0', 's0', 'p1', 'p2', 'p4']:
            lanes = ((['a0', 'b0', 'aa'] if rnd % 2 == 0 else ['aa', 'b0', 'a0'])
                     if mode == 'o0' else (['a0', 'b0'] if rnd % 2 == 0 else ['b0', 'a0']))
            for lane in lanes:
                private = runs / f'{prefix}{rnd}-{mode}-{lane}'
                private.mkdir()
                for temperature in ['cold', 'warm']:
                    samples = []
                    started = time.monotonic()
                    def snapshot(pid):
                        values = original(pid)
                        current = {}
                        for child, (_, rss, cpu) in values.items():
                            try:
                                cmdline = Path(f'/proc/{child}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
                            except OSError:
                                cmdline = ''
                            current[child] = {'command': cmdline, 'rss_bytes': rss, 'cpu_s': cpu}
                        samples.append({'s': time.monotonic() - started, 'processes': current})
                        return values
                    cmd, env = command(lane, mode, source, entry, private)
                    if mode == 'p4':
                        base.snapshot = snapshot
                    try:
                        result = base.measure(cmd, corpus, env, private / temperature)
                    finally:
                        base.snapshot = original
                    digest = base.sha(private / 'out.wasm')
                    assert digest == reference['artifacts'][subject], (subject, mode, lane, 'output differs')
                    if mode in ['o0', 's0']:
                        result['guest_memory'] = base.guest_memory((private / temperature / 'run.log').read_text())
                    else:
                        trace = json.loads((private / 'trace.json').read_text())
                        assert trace['workers'] == int(mode[1]) == trace['range_jobs']
                        assert trace['context_serialization_count'] == 1
                        result['phases'] = trace
                        shutil.copy2(private / 'trace.json', private / temperature / 'trace.json')
                    if mode == 'p4':
                        active = [i for i, sample in enumerate(samples) if any(
                            p['command'].endswith('/worker.wasm ') for p in sample['processes'].values())]
                        assert active
                        phases = {'before_workers': samples[:active[0]],
                                  'workers_alive': samples[active[0]:active[-1] + 1],
                                  'after_workers': samples[active[-1] + 1:]}
                        result['peaks'] = {}
                        for name, values in phases.items():
                            assert values
                            peak = max(values, key=lambda sample: sum(p['rss_bytes'] for p in sample['processes'].values()))
                            result['peaks'][name] = {'s': peak['s'],
                                'rss_bytes': sum(p['rss_bytes'] for p in peak['processes'].values()),
                                'processes': peak['processes']}
                        base.write(private / temperature / 'timeline.json', {'samples': samples})
                    result.update(subject=subject, round=rnd, mode=mode, lane=lane, temperature=temperature,
                                  artifact_sha256=digest, raw_directory=str((private / temperature).relative_to(lab)))
                    rows.append(result)
                    base.write(lab / 'comparison.json', report)
                    print(subject, rnd, mode, lane, temperature, f"{result['wall_s']:.3f}s",
                          f"{result['process_tree_peak_rss_bytes'] / 2**20:.1f}MiB", flush=True)
assert len(rows) == report['expected_samples']
for subject in ['compiler', 'split-cli']:
    for rnd in range(3):
        for temperature in ['cold', 'warm']:
            pair = [r for r in rows if r['subject'] == subject and r['round'] == rnd
                    and r['temperature'] == temperature and r['mode'] == 'o0' and r['lane'] in ['a0', 'aa']]
            assert len(pair) == 2 and pair[0]['guest_memory'] == pair[1]['guest_memory'], ('A/A differs', pair)
verify_sources()
assert authority['files'] == image_files() and authority['harness_sha256'] == base.sha(__file__)
report.update(verified_complete=True, aa_guest_memory_exact=True)
base.write(lab / 'comparison.json', report)
print('All132 comparison outputs match; all12 A/A guest-memory pairs match; sources/images unchanged.', flush=True)
