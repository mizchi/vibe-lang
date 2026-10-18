"""Separate control/IO/RSS replays; none of these walls are promotion samples."""
import json
import os
from pathlib import Path
import sys
import time
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path.cwd() / 'bench/perf'))
import selfbuild_baseline as base
import selfbuild_profiles as profiles

lab = Path(sys.argv[1]).resolve()
workspace = lab / 'baseline'
corpus = workspace / 'corpus'
images = workspace / 'engines/images'
runner = workspace / 'engines/o0/viberun'
meta = json.loads((workspace / 'workspace.json').read_text())
matrix = json.loads((workspace / 'matrix/measurement.json').read_text())
assert matrix['verified_complete'] and matrix['aa_guest_memory_exact']
assert json.loads((lab / 'native-diagnostics-stage.json').read_text())['status'] == 'completed'
assert (lab / 'native-diagnostics-pipeline.exit').read_text().strip() == '0'
receipt = base.image_receipts(workspace)
assert receipt == matrix['receipts']
base.verify_source(corpus, meta)
out = lab / 'diagnostic-controls'
out.mkdir()
summary = {'complete': False, 'source_commit': meta['source_commit'],
           'harness_sha256': base.sha(__file__), 'matrix_sha256': base.sha(workspace / 'matrix/measurement.json'),
           'scope': 'Separate diagnostics, not promotion walltime. Guest memory is not aggregate RSS. RSS uses actual command identity at every sample, follows exec, and may count shared mappings repeatedly.',
           'parents': [], 'workers': [], 'rss': []}

def save():
    base.write(out / 'summary.json', summary)

save()
subjects = [('compiler', 'lib/@vibe/compiler/tests/codegen_lexer_test.vibe', '__no_entry__'),
            ('split-cli', 'lib/@vibe/cli/entry.vibe', 'cli_main')]
for subject, source, entry in subjects:
    family = workspace / 'parent-profiles'
    private = family / f'{subject}-4'
    private.mkdir()
    config = private / 'service.json'
    base.write(config, {'version': 1, 'worker': str(images / 'worker.wasm'),
                       'coordinator': str(images / 'coordinator.component.wasm'), 'runner': str(runner),
                       'cwd': str(corpus), 'directory': str(private), 'jobs': 4})
    env = base.clean_env(corpus) | {'VIBE_RC': '1', 'VIBE_MEM': '1',
        'VIBE_BUILD_CACHE_DIR': str(family / f'{subject}-cache'),
        'VIBE_NATIVE_CACHE_DIR': str(workspace / 'native-cache'), 'VIBE_LOWERING_INPUT': source,
        'VIBE_LOWERING_OUTPUT': str(private / 'out.wasm'), 'VIBE_LOWERING_ENTRY': entry,
        'VIBE_LOWERING_DIRECTORY': str(private), 'VIBE_LOWERING_MODE': 'single',
        'VIBE_FUNCTION_JOBS': '4', 'VIBE_LOWERING_SERVICE_CONFIG': str(config),
        'SELFBUILD_NATIVE_RUNNER': str(runner), 'SELFBUILD_CAPTURE': str(family / f'capture-{subject}')}
    profiles.run([str(runner), str(images / 'compile.wasm')], corpus, env, private / 'logs')
    assert base.sha(private / 'out.wasm') == matrix['artifacts'][subject]
    memory = base.guest_memory((private / 'logs/stderr.log').read_text())
    compared = []
    for index in (1, 2, 3):
        observed = base.guest_memory((family / f'{subject}-{index}/logs/stderr.log').read_text())
        assert observed == memory, (subject, index, memory, observed)
        compared.append(str(family / f'{subject}-{index}/cpu.json'))
    summary['parents'].append({'subject': subject, 'guest_memory': memory,
        'artifact_sha256': base.sha(private / 'out.wasm'), 'profiled_memory_exact': True,
        'profile_paths': compared, 'control_path': str(private)})
    save()
    print('parent warm unprofiled control:', subject, 'three profiles match exact guest counters', flush=True)

for capture in sorted((workspace / 'parent-profiles').glob('capture-*/*/capture.json')):
    record = json.loads(capture.read_text())
    family = capture.parent.parent.name
    context_sha = base.sha(capture.parent / 'shared.context')
    context = profiles.context_pool((capture.parent / 'shared.context').read_bytes())
    assert context['context_format'] == 6
    for slot, queue in enumerate(record['queues']):
        if not queue:
            continue
        private = workspace / 'worker-profiles' / f'{family}-{capture.parent.name}-{slot}'
        listing = private / 'jobs.list'
        assert listing.read_text().splitlines() == [str(capture.parent / row['name']) for row in queue]
        log = private / '4-io-control'
        log.mkdir()
        scope = log / 'host-io.json'
        nonce = str(uuid.uuid4())
        env = base.clean_env(corpus) | {'VIBE_RC': '1', 'VIBE_MEM': '1',
            'VIBE_NATIVE_CACHE_DIR': str(workspace / 'native-cache'),
            'VIBE_LOWERING_WORKER_LIST': str(listing),
            'VIBE_LOWERING_SHARED_CONTEXT': str(capture.parent / 'shared.context'),
            'VIBE_HOST_FS_SCOPE_OUT': str(scope), 'VIBE_HOST_FS_SCOPE_NONCE': nonce}
        profiles.run([str(runner), str(images / 'worker.wasm')], corpus, env, log / 'logs')
        counters = json.loads(scope.read_text())
        assert counters['nonce'] == nonce
        assert counters['read_bytes_calls'] == 1 + len(queue)
        assert counters['read_bytes_returned_bytes'] == record['context_bytes'] + sum(row['input_bytes'] for row in queue)
        memory = base.guest_memory((log / 'logs/stderr.log').read_text())
        for index in range(4):
            assert base.guest_memory((private / str(index) / 'stderr.log').read_text()) == memory, (family, slot, index)
        for row in queue:
            assert base.sha(capture.parent / (row['name'] + '.product')) == row['product_sha256']
        assert base.sha(capture.parent / 'shared.context') == context_sha
        summary['workers'].append({'family': family, 'slot': slot, 'guest_memory': memory,
            'io': counters, 'context': context, 'products_match': True, 'all_four_previous_guest_counters_exact': True,
            'control_path': str(log)})
        save()
        print('worker IO/memory control:', family, slot, 'products, bytes, nonce and guest counters match', flush=True)

original = base.snapshot
for subject, source, entry in subjects:
    private = out / 'rss' / subject
    private.mkdir(parents=True)
    for temperature in ('cold', 'warm'):
        samples = []
        history = {}
        started = time.monotonic()
        def snapshot(root):
            values = original(root)
            now = time.monotonic() - started
            rows = {}
            for pid, (_, rss, cpu) in values.items():
                try:
                    command = Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
                except OSError:
                    command = ''
                rows[pid] = {'rss_bytes': rss, 'cpu_s': cpu, 'command': command}
                events = history.setdefault(pid, [])
                if not events or events[-1]['command'] != command:
                    events.append({'s': now, 'command': command})
            samples.append({'s': now, 'processes': rows})
            return values
        base.snapshot = snapshot
        command, env = base.matrix_command(workspace, 'p4', source, private / 'out.wasm', entry,
                                          private / 'cache', private / f'{temperature}-trace.json')
        try:
            base.measure(command, corpus, env, private / temperature)
        finally:
            base.snapshot = original
        assert base.sha(private / 'out.wasm') == matrix['artifacts'][subject]
        active = [i for i, sample in enumerate(samples)
                  if any(p['command'].endswith('/worker.wasm ') for p in sample['processes'].values())]
        assert active
        groups = {'before_workers': samples[:active[0]],
                  'workers_alive': samples[active[0]:active[-1] + 1],
                  'after_workers': samples[active[-1] + 1:]}
        peaks = {}
        for phase, values in groups.items():
            assert values, (subject, temperature, phase)
            peak = max(values, key=lambda s: sum(p['rss_bytes'] for p in s['processes'].values()))
            peaks[phase] = {'s': peak['s'], 'rss_bytes': sum(p['rss_bytes'] for p in peak['processes'].values()),
                            'processes': peak['processes']}
        observation = {'subject': subject, 'temperature': temperature, 'peaks': peaks,
                       'artifact_sha256': base.sha(private / 'out.wasm'),
                       'scope': 'Separate p4 diagnostic replay, 20ms simultaneous RSS. Commands sampled across exec; phase boundaries quantized by sampling. Never sum independent process maxima.'}
        base.write(private / temperature / 'timeline.json', {'observation': observation, 'samples': samples, 'exec_history': history})
        summary['rss'].append(observation)
        save()
        print('RSS phases:', subject, temperature, {k: round(v['rss_bytes'] / 2**20, 1) for k, v in peaks.items()}, flush=True)

base.verify_source(corpus, meta)
assert base.image_receipts(workspace) == receipt
assert base.sha(__file__) == summary['harness_sha256']
assert len(summary['parents']) == 2 and len(summary['workers']) == 8 and len(summary['rss']) == 4
summary['complete'] = True
save()
print('All separate controls, products, IO, source and image authority verified.', flush=True)
