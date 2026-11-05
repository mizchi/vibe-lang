"""Each compiler builds its own source; move snapshots through one fixed guest root."""
import hashlib, json, os, re, shutil, statistics, subprocess, time
from pathlib import Path
import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('baseline_root', type=Path)
parser.add_argument('candidate_root', type=Path)
parser.add_argument('baseline_wasm', type=Path)
parser.add_argument('candidate_wasm', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--ast-cache', choices=('0', '1'), default='0')
parser.add_argument('--same-source', action='store_true', help='Both compilers consume the candidate snapshot; require identical output across compilers too.')
args = parser.parse_args()
candidate = args.candidate_root.resolve()
baseline = args.baseline_root.resolve()
work = args.output.resolve()
work.mkdir(exist_ok=False)
active = work / 'active'
sources = {'a': candidate if args.same_source else baseline, 'b': candidate}
snapshots = {}
artifacts = {'a': args.baseline_wasm.resolve(), 'b': args.candidate_wasm.resolve()}
generated = ('compiler_sources_bundle.vibe', 'cli_adapter_bundle.vibe', 'selfbuild_runtime_entry_bundle.vibe', '_cli_adapter_module_source.vibe', 'cache/codegen_fingerprint.vibe')
receipt = {'protocol': 'Each compiler compiles its own checkout snapshot. Snapshots move through the SAME literal root, compiler, cache and output paths, avoiding path-length and path-content bias. Isolated caches per lane and round; cold then warm in fresh Node processes; AB/BA/AB order; RC=0; compiler/test runs isolated.', 'commits': {}, 'artifacts': {}, 'runs': []}
receipt['ast_cache'] = args.ast_cache
receipt['same_source'] = args.same_source
if args.same_source:
    receipt['protocol'] = receipt['protocol'].replace('Each compiler compiles its own checkout snapshot.', 'Both compilers compile the same candidate snapshot; outputs must be identical across compilers.')
for lane, source in sources.items():
    subprocess.run(['git', 'diff', '--exit-code'], cwd=source, check=True, capture_output=True)
    receipt['commits'][lane] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    receipt.setdefault('trees', {})[lane] = subprocess.check_output(['git', 'write-tree'], cwd=source, text=True).strip()
    dest = work / ('stored-' + lane)
    dest.mkdir()
    snapshots[lane] = dest
    subprocess.run(['git', 'checkout-index', '--all', '--prefix=' + str(dest) + '/'], cwd=source, check=True, capture_output=True)
    for rel in generated:
        p = dest / 'lib/@vibe/compiler' / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / 'lib/@vibe/compiler' / rel, p)
    (dest / '_build').mkdir(exist_ok=True)
    shutil.copy2(artifacts[lane], dest / '_build/compiler.wasm')
    receipt['artifacts'][lane] = hashlib.sha256(artifacts[lane].read_bytes()).hexdigest()
for corpus, entry in [('lib/@vibe/compiler/tests/codegen_lexer_test.vibe', '__no_entry__'), ('lib/@vibe/compiler/cli_adapter.vibe', 'cli_main')]:
    tag = 'kpi' if entry == '__no_entry__' else 'cli'
    for round_no in range(3):
        for lane in ('a', 'b') if round_no % 2 == 0 else ('b', 'a'):
            snapshots[lane].rename(active)
            try:
                cache = active / f'_build/cache-{tag}-{round_no}'
                assert not cache.exists()
                cache.mkdir()
                env = dict({k: v for k, v in os.environ.items() if not k.startswith('VIBE_')}, VIBE_INTERNAL_TRUSTED_SOURCE='1', VIBE_FS_COMPILE='1', VIBE_RC='0', VIBE_IMPORT_ABI='raw', VIBE_PREOPEN_DIR=str(active), VIBE_BUILD_CACHE_DIR=str(cache), VIBE_WASM_MEMORY_STATS='1', VIBE_EXPERIMENTAL_AST_CACHE=args.ast_cache, PWD=str(active))
                for temperature in ('cold', 'warm'):
                    output = active / '_build/output.wasm'
                    output.unlink(missing_ok=True)
                    start = time.monotonic()
                    p = subprocess.run(['bash', 'scripts/run_wasm_vibe_host_runner.sh', '--invoke', 'cli_main', str(active / '_build/compiler.wasm'), corpus, str(output), entry], cwd=active, env=env, capture_output=True, text=True, timeout=900)
                    wall = time.monotonic() - start
                    log = work / f'{tag}-{round_no}-{lane}-{temperature}.log'
                    log.write_text(p.stdout + p.stderr)
                    diag = Path(str(output) + '.diag')
                    assert p.returncode == 0 and p.stdout.strip() == '0' and output.exists(), (str(log), diag.read_text() if diag.exists() else p.stderr[-2000:])
                    heaps = re.findall('\\[wasm-memory\\].*?heap_ptr=(\\d+)', p.stderr)
                    assert heaps, str(log)
                    row = {'corpus': tag, 'round': round_no, 'lane': lane, 'temperature': temperature, 'heap_ptr': int(heaps[-1]), 'wall_seconds': wall, 'output_bytes': output.stat().st_size, 'output_sha256': hashlib.sha256(output.read_bytes()).hexdigest()}
                    receipt['runs'].append(row)
                    print(json.dumps(row), flush=True)
                    (work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
                shutil.copy2(active / '_build/output.wasm', work / (tag + '-' + lane + '.wasm'))
                shutil.rmtree(cache)
            finally:
                active.rename(snapshots[lane])
receipt['medians'] = {tag: {temp: {lane: {metric: statistics.median((x[metric] for x in receipt['runs'] if x['corpus'] == tag and x['temperature'] == temp and (x['lane'] == lane))) for metric in ('heap_ptr', 'wall_seconds')} for lane in ('a', 'b')} for temp in ('cold', 'warm')} for tag in ('kpi', 'cli')}
for tag in ('kpi', 'cli'):
    for lane in ('a', 'b'):
        assert len({x['output_sha256'] for x in receipt['runs'] if x['corpus'] == tag and x['lane'] == lane}) == 1
    if args.same_source:
        assert len({x['output_sha256'] for x in receipt['runs'] if x['corpus'] == tag}) == 1
(work / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt['medians']), flush=True)
for snapshot in snapshots.values():
    assert snapshot.parent == work and (not (snapshot / '.git').exists())
    shutil.rmtree(snapshot)
