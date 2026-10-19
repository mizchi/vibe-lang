"""Fresh source reconstruction and sequential benchmark replay; no old success markers."""
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile

EXPERIMENT = Path(__file__).resolve().parent
BASELINE = '8bed6e9e61bb178af06cdb7fbae62d9bc19c6c7e'


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def git(cwd, *args):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True).strip()


def source_map(corpus):
    names = git(corpus, 'ls-files', '--', 'lib/', 'runtime/viberun/', 'scripts/',
                'bootstrap/seed.json', 'bench/perf/', 'Taskfile.pkl').splitlines()
    return {name: sha(corpus / name) for name in names if (corpus / name).is_file()}


def sources(workspace, repo):
    if workspace.exists():
        raise ValueError('use a new workspace; retain existing evidence')
    receipt = read(EXPERIMENT / 'archive.json')
    index_bytes = gzip.decompress((EXPERIMENT / receipt['index']).read_bytes())
    assert hashlib.sha256(index_bytes).hexdigest() == receipt['raw_index_sha256']
    assert sha(EXPERIMENT / receipt['archive']) == receipt['archive_sha256']
    index = {row['member']: row for row in json.loads(index_bytes)['entries']}
    with tarfile.open(EXPERIMENT / receipt['archive'], 'r:xz') as archive:
        def member(name):
            data = archive.extractfile(name).read()
            assert len(data) == index[name]['bytes']
            assert hashlib.sha256(data).hexdigest() == index[name]['sha256']
            return data
        proof = json.loads(member('records/after-format-validation-v1/result.json'))
        snapshot = member('records/after-format-validation-v1/candidate-sources.tar.gz')
    assert proof['head'] == BASELINE
    assert hashlib.sha256(snapshot).hexdigest() == proof['source_archive_sha256']
    assert git(repo, 'rev-parse', BASELINE) == BASELINE
    workspace.mkdir(parents=True)
    for lane in ['a0', 'b0']:
        corpus = workspace / lane
        subprocess.run(['git', 'clone', '--shared', '--no-checkout', str(repo), str(corpus)], check=True)
        subprocess.run(['git', 'checkout', '--detach', BASELINE], cwd=corpus, check=True)
        assert not git(corpus, 'status', '--porcelain')
    baseline = source_map(workspace / 'a0')
    with tarfile.open(fileobj=io.BytesIO(snapshot), mode='r:gz') as archive:
        archive.extractall(workspace / 'b0', filter='data')
    candidate = proof['source_sha256']
    for lane, expected in [('a0', baseline), ('b0', candidate)]:
        corpus = workspace / lane
        for name, digest in expected.items():
            assert sha(corpus / name) == digest, (lane, name)
        pin = read(corpus / 'bootstrap/seed.json')['seed']['artifact']['sha256']
        available = repo / 'bootstrap/seed/compiler.wasm'
        if available.is_file() and sha(available) == pin:
            (corpus / 'bootstrap/seed').mkdir(parents=True, exist_ok=True)
            shutil.copy2(available, corpus / 'bootstrap/seed/compiler.wasm')
    write(workspace / 'sources.json', {'source_reconstruction_complete': True,
        'scope': 'Source bytes only; no compiler, native runner, image or test success is inferred.',
        'baseline': BASELINE, 'source_maps': {'a0': baseline, 'b0': candidate},
        'candidate_snapshot_sha256': proof['source_archive_sha256'], 'driver_sha256': sha(__file__)})
    print('Source reconstruction complete; build producers/images normally next.', flush=True)


def verify_sources(workspace):
    metadata = read(workspace / 'sources.json')
    assert metadata['source_reconstruction_complete'] and metadata['baseline'] == BASELINE
    for lane, expected in metadata['source_maps'].items():
        corpus = workspace / lane
        assert git(corpus, 'rev-parse', 'HEAD') == BASELINE
        for name, digest in expected.items():
            assert sha(corpus / name) == digest, ('source changed', lane, name)
        unknown = git(corpus, 'ls-files', '--others', '--exclude-standard', '--',
                      'lib/', 'runtime/viberun/', 'scripts/').splitlines()
        assert not set(unknown).difference(expected), ('unexpected source', lane)
    return metadata


def helper(workspace):
    path = workspace / 'b0/bench/perf/selfbuild_baseline.py'
    spec = importlib.util.spec_from_file_location('frozen_selfbuild_baseline', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def engines(workspace):
    verify_sources(workspace)
    base = helper(workspace)
    out = workspace / 'engines'
    out.mkdir()
    logs = workspace / 'setup-logs'
    logs.mkdir()
    steps = []
    for lane in ['a0', 'b0']:
        corpus = workspace / lane
        generation = workspace / 'producers' / lane
        images = workspace / 'images' / lane
        env = base.clean_env(corpus) | {'VIBE_BUILD_CACHE_DIR': str(workspace / ('setup-cache-' + lane)),
                                       'VIBE_NATIVE_CACHE_DIR': str(workspace / 'native-cache')}
        commands = [
            ['bash', 'scripts/ensure_seed.sh'], ['bash', 'scripts/ensure_viberun.sh'],
            ['bash', 'scripts/ensure_generated.sh'],
            ['bash', 'scripts/generations.sh', 'build', '--stage3', '--out-dir', str(generation)],
            ['bash', 'scripts/build_taskgroup_functions.sh', str(generation / 'stage2.wasm'), str(images)],
            ['bash', 'scripts/ensure_viberun.sh', '--check']]
        for number, command in enumerate(commands):
            verify_sources(workspace)
            log = logs / f'{lane}-{number}.log'
            with log.open('w') as stream:
                result = subprocess.run(command, cwd=corpus, env=env, stdout=stream, stderr=subprocess.STDOUT)
            steps.append({'lane': lane, 'command': command, 'exit': result.returncode, 'log_sha256': sha(log)})
            write(workspace / 'setup-progress.json', {'complete': False, 'steps': steps})
            assert result.returncode == 0, str(log)
        base.fixed_point(generation)
        for target in [lane, 'aa' if lane == 'a0' else 'bb']:
            directory = out / target
            directory.mkdir()
            for name in ['compile.wasm', 'worker.wasm', 'coordinator.component.wasm', 'build.json']:
                shutil.copy2(images / name, directory / name)
            shutil.copy2(generation / 'stage2.wasm', directory / 'compiler.wasm')
            shutil.copy2(corpus / 'runtime/viberun/target/release/viberun', directory / 'viberun')
            for name in ['taskgroup_functions_frontend.mjs', 'taskgroup_lowering_frontend.mjs']:
                shutil.copy2(corpus / 'scripts' / name, directory / name)
            check_image(base, directory)
    verify_sources(workspace)
    write(workspace / 'setup-progress.json', {'complete': True, 'steps': steps,
          'scope': 'Fresh normal producer fixpoints and source-checked native runners/images; no historical success markers.'})


def check_image(base, image):
    receipt = base.function_image_receipt(image)
    assert receipt['compiler_sha256'] == sha(image / 'compiler.wasm')
    assert receipt['runner_sha256'] == sha(image / 'viberun')
    for name, digest in receipt['artifacts'].items():
        assert sha(image / name) == digest, name
    return receipt


def matrix(workspace, input_engines, smoke):
    verify_sources(workspace)
    base = helper(workspace)
    corpus = workspace / 'a0'
    images = input_engines or workspace / 'engines'
    out = workspace / ('smoke' if smoke else 'matrix')
    out.mkdir()
    identities = {str(p.relative_to(images)): sha(p) for p in images.rglob('*') if p.is_file()}
    assert identities
    for lane in ['a0', 'b0', 'aa', 'bb']:
        check_image(base, images / lane)
    (corpus / 'perf-smoke.vibe').write_text('fn main() -> Int { 7 - 3 }\n')
    inputs = {str(p.relative_to(corpus)): sha(p) for p in (corpus / 'lib').rglob('*') if p.is_file()}
    inputs['perf-smoke.vibe'] = sha(corpus / 'perf-smoke.vibe')
    report = {'verified_complete': False, 'smoke_only': smoke, 'samples': [], 'artifacts': {},
        'driver_sha256': sha(__file__), 'source_metadata_sha256': sha(workspace / 'sources.json'),
        'input_sha256': inputs, 'engine_sha256': identities,
        'machine': {'kernel': platform.release(), 'cpus': os.cpu_count(),
                    'node': subprocess.check_output(['node', '--version'], text=True).strip()},
        'scope': 'Fresh filesystem targetRC1/process matrix. N3 forward/reverse/forward, both A/A controls, same-image serial and public process1/2/4. Cold private cache then warm new process; other compiler caches off; JIT primed on separate small input, OS pages warm. RSS simultaneous20ms process-tree sum, shared mappings may double-count. Smoke is tiny-input command verification only, never performance evidence. No source edits or concurrent heavy work.'}

    def verify():
        verify_sources(workspace)
        assert sha(__file__) == report['driver_sha256']
        assert all(sha(images / p) == h for p, h in identities.items())
        assert all(sha(corpus / p) == h for p, h in inputs.items())

    def command(lane, mode, source, entry, private):
        image = images / lane
        native = image / 'viberun'
        env = base.clean_env(corpus) | {'VIBE_RC': '1', 'VIBE_FS_COMPILE': '1', 'VIBE_MEM': '1',
              'VIBE_BUILD_CACHE_DIR': str(private / 'cache'), 'VIBE_NATIVE_CACHE_DIR': str(workspace / 'native-cache')}
        if mode == 'o0':
            cmd = [str(native), str(image / 'compiler.wasm'), source, str(private / 'out.wasm'), entry]
        elif mode == 's0':
            cmd = base.function_parent_command(image, native)
            env.update(VIBE_LOWERING_MODE='serial', VIBE_LOWERING_INPUT=source,
                       VIBE_LOWERING_ENTRY=entry, VIBE_LOWERING_OUTPUT=str(private / 'out.wasm'))
            if base.function_image_receipt(image)['function_abi'] == 'bump-core-returning-phases-3':
                config = private / 'service.json'
                base.write(config, {'version': 1, 'worker': str(image / 'worker.wasm'),
                    'runner': str(native), 'coordinator': str(image / 'coordinator.component.wasm'),
                    'cwd': str(corpus), 'directory': str(private), 'jobs': 1})
                env.update(VIBE_FUNCTION_JOBS='1', VIBE_LOWERING_DIRECTORY=str(private),
                           VIBE_LOWERING_SERVICE_CONFIG=str(config))
        else:
            cmd = ['node', str(image / 'taskgroup_functions_frontend.mjs'), str(image / 'compiler.wasm'),
                   source, str(private / 'out.wasm'), entry, mode[1], str(corpus), str(image), str(native)]
            env['VIBE_FUNCTION_TRACE_OUT'] = str(private / 'trace.json')
        return cmd, env

    verify()
    for lane in ['a0', 'b0', 'aa', 'bb']:
        for mode in ['o0', 's0', 'p1']:
            private = out / f'prime-{lane}-{mode}'
            private.mkdir()
            cmd, env = command(lane, mode, 'perf-smoke.vibe', 'main', private)
            base.measure(cmd, corpus, env, private / 'logs')
            assert (private / 'out.wasm').is_file()
    subjects = [('smoke', 'x', 'perf-smoke.vibe', 'main')] if smoke else [
        ('compiler', 'c', 'lib/@vibe/compiler/tests/codegen_lexer_test.vibe', '__no_entry__'),
        ('split-cli', 'l', 'lib/@vibe/cli/entry.vibe', 'cli_main')]
    for subject, prefix, source, entry in subjects:
        for rnd in range(1 if smoke else 3):
            modes = ['o0', 's0', 'p1', 'p2', 'p4']
            for mode in modes if rnd % 2 == 0 else reversed(modes):
                lanes = ['a0', 'b0', 'aa', 'bb'] if mode == 'o0' else ['a0', 'b0']
                for lane in lanes if rnd % 2 == 0 else reversed(lanes):
                    private = out / f'{prefix}{rnd}-{mode}-{lane}'
                    private.mkdir()
                    for temperature in ['cold', 'warm']:
                        verify()
                        (private / 'out.wasm').unlink(missing_ok=True)
                        (private / 'trace.json').unlink(missing_ok=True)
                        cmd, env = command(lane, mode, source, entry, private)
                        row = base.measure(cmd, corpus, env, private / temperature)
                        digest = sha(private / 'out.wasm')
                        assert report['artifacts'].setdefault(subject, digest) == digest
                        row['guest_memory'] = [base.guest_memory(line) for line in
                            (private / temperature / 'run.log').read_text().splitlines() if line.startswith('vibe::mem ')]
                        assert len(row['guest_memory']) == (0 if mode.startswith('p') else 1)
                        if mode.startswith('p'):
                            row['phases'] = read(private / 'trace.json')
                            assert row['phases']['workers'] == int(mode[1])
                            if lane == 'b0':
                                assert row['phases']['preparation_store_dropped_before_workers']
                                assert row['phases']['finisher_store_fresh'] and row['phases']['finisher_source_reads'] == 0
                        row.update(subject=subject, round=rnd, lane=lane, mode=mode,
                                   temperature=temperature, artifact_sha256=digest)
                        report['samples'].append(row)
                        write(out / 'measurement.json', report)
                        print(subject, rnd, mode, lane, temperature, round(row['wall_s'], 3), flush=True)
    expected = 24 if smoke else 144
    assert len(report['samples']) == expected
    for subject, _, _, _ in subjects:
        for rnd in range(1 if smoke else 3):
            for temperature in ['cold', 'warm']:
                for pair in [('a0', 'aa'), ('b0', 'bb')]:
                    rows = [r for r in report['samples'] if r['subject'] == subject and r['round'] == rnd
                            and r['temperature'] == temperature and r['mode'] == 'o0' and r['lane'] in pair]
                    assert len(rows) == 2 and rows[0]['guest_memory'] == rows[1]['guest_memory']
    verify()
    report.update(verified_complete=True, aa_guest_memory_exact=True)
    write(out / 'measurement.json', report)


def bootstrap(workspace):
    verify_sources(workspace)
    if (workspace / 'a0/perf-smoke.vibe').exists():
        raise ValueError('use a separate fresh workspace for actual bootstrap; retain the filesystem experiment')
    assert read(workspace / 'setup-progress.json')['complete']
    base = helper(workspace)
    out = workspace / 'bootstrap'
    out.mkdir()
    report = {'verified_complete': False, 'samples': [], 'artifacts': {},
        'source_metadata_sha256': sha(workspace / 'sources.json'), 'driver_sha256': sha(__file__),
        'scope': 'Fresh actual targetRC0 ordinary serial pipelines, compiler throughstage3 and portableCLI throughstage2. N3 alternating lanes/subjects, cold private parsed-source cache and deleted merge-tool image/stamp, warm reuse with all stages rebuilt. Setup/producer packaging excluded, OS pages warm, native cache shared. No threaded selection or promotion claim.'}
    runners = {lane: sha(workspace / lane / 'runtime/viberun/target/release/viberun') for lane in ['a0', 'b0']}
    for rnd in range(3):
        subjects = ['compiler', 'portable-cli']
        for subject in subjects if rnd % 2 == 0 else reversed(subjects):
            lanes = ['a0', 'b0']
            for lane in lanes if rnd % 2 == 0 else reversed(lanes):
                corpus = workspace / lane
                private = out / f'r{rnd}-{subject}-{lane}'
                private.mkdir()
                for temperature in ['cold', 'warm']:
                    verify_sources(workspace)
                    assert sha(__file__) == report['driver_sha256']
                    assert sha(corpus / 'runtime/viberun/target/release/viberun') == runners[lane]
                    if temperature == 'cold':
                        for suffix in ['', '.fingerprint']:
                            (corpus / ('_build/merge_flatten_compiler.wasm' + suffix)).unlink(missing_ok=True)
                    directory = private / temperature
                    env = base.clean_env(corpus) | {'VIBE_BUILD_CACHE_DIR': str(private / 'cache'),
                        'VIBE_NATIVE_CACHE_DIR': str(workspace / 'native-cache'), 'VIBE_MEM': '1',
                        'VIBE_TRACE_MONOTONIC': '1', 'VIBE_WASM_MEMORY_STATS': '1',
                        'VIBE_BUILD_CLI_WASM_NO_CACHE': '1', 'VIBE_TRACE_OUT': str(directory / 'spans.ndjson')}
                    generation = corpus / '_build/replay-generation'
                    command = (['bash', 'scripts/generations.sh', 'build', '--stage3', '--out-dir', str(generation)]
                               if subject == 'compiler' else ['bash', 'scripts/build_cli_wasm.sh', '_build/replay-cli.wasm'])
                    row = base.measure(['bash', 'scripts/trace_span.sh', subject, *command], corpus, env, directory)
                    spans = [json.loads(line) for line in (directory / 'spans.ndjson').read_text().splitlines()]
                    assert spans and all(s['clock'] == 'monotonic' and s['rc'] == 0 and s['t1'] >= s['t0'] for s in spans)
                    if subject == 'compiler':
                        receipt = base.fixed_point(generation)
                        digest = receipt['stages']['stage2']['sha256']
                    else:
                        digest = sha(corpus / '_build/replay-cli.wasm')
                        manifests = list((corpus / '_build/selfhost/generations').glob('*/generation.json'))
                        assert len(manifests) == 1
                        receipt = read(manifests[0])
                        assert receipt['stages']['stage2']['sha256'] == digest
                    assert report['artifacts'].setdefault(subject + '-' + lane, digest) == digest
                    write(directory / 'generation.json', receipt)
                    row.update(subject=subject, lane=lane, round=rnd, temperature=temperature,
                               artifact_sha256=digest, emitted_target_rc=0, worker_selected=False, spans=spans)
                    report['samples'].append(row)
                    write(out / 'measurement.json', report)
                    print(subject, rnd, lane, temperature, round(row['wall_s'], 3), flush=True)
    verify_sources(workspace)
    assert len(report['samples']) == 24
    report['verified_complete'] = True
    write(out / 'measurement.json', report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['sources', 'check-sources', 'engines', 'matrix', 'smoke', 'bootstrap'])
    parser.add_argument('workspace', type=Path)
    parser.add_argument('--repo', type=Path, default=EXPERIMENT.parents[3])
    parser.add_argument('--engines', type=Path, help='explicit receipt-checked existing images; smoke only')
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    if args.engines and args.command != 'smoke':
        parser.error('--engines is restricted to functional smoke; normal replay builds fresh producers')
    if args.command == 'sources':
        sources(workspace, args.repo.resolve())
    elif args.command == 'check-sources':
        verify_sources(workspace)
    elif args.command == 'engines':
        engines(workspace)
    elif args.command == 'bootstrap':
        bootstrap(workspace)
    else:
        if not args.engines:
            assert read(workspace / 'setup-progress.json')['complete']
        matrix(workspace, args.engines.resolve() if args.engines else None, args.command == 'smoke')


if __name__ == '__main__':
    main()
