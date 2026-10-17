#!/usr/bin/env python3
"""Compare fixed bootstrap trees for validation-product reuse (#3482).

Inputs are private frozen workspaces prepared by selfbuild_baseline.py, with
workspace.json/source.tar and any explicitly hashed candidate overlay. This
uses the production ensure_generated + prebuilt-source compiler route and the
production portable-CLI build route. It never selects a compiler by recency.
"""
import argparse
import json
from pathlib import Path
import shutil
import statistics

import selfbuild_baseline as baseline

GENERATED = [
    'lib/@vibe/compiler/' + name for name in [
        'compiler_sources_bundle.vibe', 'cli_adapter_bundle.vibe',
        'selfbuild_runtime_entry_bundle.vibe', '_cli_adapter_module_source.vibe',
        'cache/codegen_fingerprint.vibe', '.generated.stamp', '.generated.inputs',
        '_cli_adapter_module_source.vibe.seed-validation.wasm',
        '_cli_adapter_module_source.vibe.seed-validation.json',
    ]
]


def authorities(workspaces):
    result = {}
    for name, workspace in workspaces.items():
        meta = json.loads((workspace / 'workspace.json').read_text())
        baseline.verify_source(workspace / 'corpus', meta)
        result[name] = meta
    left, right = result.values()
    for key in ['seed', 'machine']:
        if left[key] != right[key]:
            raise ValueError('comparison authority differs: ' + key)
    def compiler_files(meta):
        return {n: v for n, v in meta['tracked_files'].items()
                if n.startswith(('lib/', 'bootstrap/'))}
    if compiler_files(left) != compiler_files(right):
        raise ValueError('compiler/seed source changed in a build-protocol comparison')
    roots = [w / 'corpus' for w in workspaces.values()]
    if len(str(roots[0])) != len(str(roots[1])):
        raise ValueError('comparison corpus paths must have equal lengths')
    return result


def cold_reset(corpus, meta):
    for name in GENERATED + ['_build/merge_flatten_compiler.wasm',
                             '_build/merge_flatten_compiler.wasm.fingerprint']:
        if name in meta['tracked_files']:
            raise ValueError('refusing to remove maintained source: ' + name)
        (corpus / name).unlink(missing_ok=True)


def command(subject):
    if subject == 'compiler':
        return ['bash', '-euc',
            'bash scripts/ensure_generated.sh\n'
            'VIBE_PREBUILT_MODULE_SOURCE=lib/@vibe/compiler/_cli_adapter_module_source.vibe '
            'bash scripts/generations.sh build --stage3 --out-dir _build/reuse-measured-generation']
    if subject == 'portable-cli':
        return ['bash', 'scripts/build_cli_wasm.sh', '_build/reuse-measured-cli.wasm']
    raise ValueError('unknown workload: ' + subject)


def generation(corpus, subject):
    if subject == 'compiler':
        directory = corpus / '_build/reuse-measured-generation'
        data = baseline.fixed_point(directory)
    else:
        files = list((corpus / '_build/selfhost/generations').glob('*/generation.json'))
        if len(files) != 1:
            raise ValueError('portable CLI must have exactly one explicit producer')
        directory = files[0].parent
        data = json.loads(files[0].read_text())
        if baseline.sha(corpus / '_build/reuse-measured-cli.wasm') != data['stages']['stage2']['sha256']:
            raise ValueError('portable CLI publication differs from its producer')
    for name, row in data['stages'].items():
        if row is None:
            continue
        path = directory / ('stage0_seed.wasm' if name == 'stage0' else name + '.wasm')
        if baseline.sha(path) != row['sha256']:
            raise ValueError('stage bytes differ from producer: ' + name)
    return directory, data


def summarize(samples):
    rows = []
    for subject in ['compiler', 'portable-cli']:
        for temperature in ['cold', 'warm']:
            lanes = {}
            for lane in ['baseline', 'proposal']:
                selected = [s for s in samples if (s['subject'], s['temperature'], s['lane']) ==
                            (subject, temperature, lane)]
                if not selected:
                    continue
                wall = [s['wall_s'] for s in selected]
                rss = [s['process_tree_peak_rss_bytes'] / 2**20 for s in selected]
                lanes[lane] = {'n': len(selected), 'wall_s': statistics.median(wall),
                    'wall_range_s': [min(wall), max(wall)], 'rss_mib': statistics.median(rss),
                    'rss_range_mib': [min(rss), max(rss)]}
            if len(lanes) == 2:
                rows.append({'subject': subject, 'temperature': temperature, **lanes,
                    'wall_delta_percent': (lanes['proposal']['wall_s']/lanes['baseline']['wall_s']-1)*100,
                    'rss_delta_percent': (lanes['proposal']['rss_mib']/lanes['baseline']['rss_mib']-1)*100})
    return rows


def run(workspaces, output, rounds):
    if rounds < 3:
        raise ValueError('at least three alternating rounds are required')
    meta = authorities(workspaces)
    output.mkdir(parents=True)  # Refuse accidental restart/overwrite.
    driver_sha = baseline.sha(__file__)
    helper_sha = baseline.sha(baseline.__file__)
    samples = []
    expected = {}
    report = {'schema': 1, 'issue': 3482, 'rounds': rounds,
        'driver_sha256': driver_sha, 'measurement_helper_sha256': helper_sha,
        'authority': {k: {'workspace_json_sha256': baseline.sha(v / 'workspace.json'),
                         'source_commit': meta[k]['source_commit'],
                         'source_tree': meta[k]['source_tree'],
                         'source_archive_sha256': meta[k].get('archive_sha256'),
                         'working_overlay': meta[k].get('working_overlay', {})} for k, v in workspaces.items()},
        'machine': meta['baseline']['machine'], 'seed': meta['baseline']['seed'],
        'protocol': 'Serial; baseline/proposal order alternates each round, as does workload order. '
            'Cold removes only owned generated artifacts and merge-tool image/stamp with fresh guest cache. '
            'Warm reuses those caches/stamps but rebuilds stage outputs. Compiler runs ensure_generated + '
            'prebuilt-source generations through stage3; portable CLI uses build_cli_wasm through stage2. '
            'CLI final-artifact cache and guest body/checked-module caches disabled. '
            'Fresh Node/JIT each invocation; warm OS pages. No CPU profiles or concurrent local tests. '
            'Simultaneous process-tree RSS sampled every20ms; shared mappings can be counted more than once. '
            'Packaging/installation/native-runner compilation excluded.',
        'samples': samples, 'verified_complete': False}
    for rnd in range(rounds):
        subjects = ['compiler', 'portable-cli'] if rnd % 2 == 0 else ['portable-cli', 'compiler']
        lanes = ['baseline', 'proposal'] if rnd % 2 == 0 else ['proposal', 'baseline']
        for subject in subjects:
            for lane in lanes:
                corpus = workspaces[lane] / 'corpus'
                baseline.verify_source(corpus, meta[lane])
                private = output / f'{rnd}-{subject}' / lane
                private.mkdir(parents=True)
                cold_reset(corpus, meta[lane])
                for temperature in ['cold', 'warm']:
                    raw = private / temperature
                    env = baseline.clean_env(corpus) | {
                        'VIBE_BUILD_CACHE_DIR': str(private / 'cache'), 'VIBE_MEM': '1',
                        'VIBE_WASM_MEMORY_STATS': '1', 'VIBE_TRACE_MONOTONIC': '1',
                        'VIBE_TRACE_OUT': str(raw / 'spans.ndjson'), 'VIBE_BUILD_CLI_WASM_NO_CACHE': '1'}
                    result = baseline.measure(['bash', 'scripts/trace_span.sh', subject, *command(subject)],
                                              corpus, env, raw)
                    directory, receipt = generation(corpus, subject)
                    hashes = {k: v['sha256'] for k, v in receipt['stages'].items() if v is not None}
                    if expected.setdefault(subject, hashes) != hashes:
                        raise ValueError('stage hashes differ across lanes/temperature/rounds')
                    log = (raw / 'run.log').read_text()
                    reused = 'reuse verified seed validation as stage1' in log
                    if reused != (lane == 'proposal'):
                        raise ValueError('measured route did not exercise expected reuse decision: ' + str(raw))
                    spans = [json.loads(line) for line in (raw / 'spans.ndjson').read_text().splitlines()]
                    if not spans or any(s['clock'] != 'monotonic' or s['rc'] or s['t1'] < s['t0'] for s in spans):
                        raise ValueError('invalid or failed monotonic phase spans')
                    baseline.write(raw / 'generation.json', receipt)
                    if subject == 'portable-cli':
                        shutil.copy2(directory / 'selfhost_bundle_generation.log', raw / 'bundle.log')
                    result.update(round=rnd, subject=subject, temperature=temperature, lane=lane,
                        stage_hashes=hashes, validation_reused=reused, spans=spans,
                        raw_directory=str(raw.relative_to(output)))
                    samples.append(result)
                    report['summary'] = summarize(samples)
                    baseline.write(output / 'measurement.json', report)
                    print(rnd, subject, lane, temperature, f"{result['wall_s']:.3f}s",
                          f"{result['process_tree_peak_rss_bytes']/2**20:.1f}MiB", flush=True)
    for lane, workspace in workspaces.items():
        baseline.verify_source(workspace / 'corpus', meta[lane])
    if baseline.sha(__file__) != driver_sha or baseline.sha(baseline.__file__) != helper_sha:
        raise ValueError('measurement driver changed during the run')
    if len(samples) != rounds * 8:
        raise ValueError('incomplete measurement matrix')
    report['verified_complete'] = True
    report['stage_hashes'] = expected
    baseline.write(output / 'measurement.json', report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('proposal', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    run({'baseline': args.baseline.resolve(), 'proposal': args.proposal.resolve()}, args.output.resolve(), args.rounds)


if __name__ == '__main__':
    main()
