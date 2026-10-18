"""Frozen403d corpus; exact byte-compatible fingerprint batching,132 AB/AA runs."""
import json,shutil,subprocess,sys,time
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
workspace=lab/'baseline';corpus=workspace/'corpus';meta=json.loads((workspace/'workspace.json').read_text());reference=json.loads((workspace/'matrix/measurement.json').read_text())
assert reference['verified_complete'] and len(reference['samples'])==72
assert json.loads((lab/'candidate-validation.json').read_text())['complete']
engines=lab/'engines'
def image_files():
 return {str(p.relative_to(lab)):base.sha(p) for lane in ['a0','b0','aa'] for p in sorted((engines/lane).iterdir()) if p.is_file()}
if not (lab/'comparison-authority.json').exists():
 assert not engines.exists()
 for lane in ['a0','b0','aa']:
  dest=engines/lane;dest.mkdir(parents=True)
  current=lab/'candidate-images' if lane=='b0' else workspace/'engines/images'
  for name in ['compile.wasm','worker.wasm','coordinator.component.wasm','build.json']:
   shutil.copy2(current/name,dest/name)
  shutil.copy2(lab/'candidate-generation/stage2.wasm' if lane=='b0' else workspace/'engines/o0/compiler.wasm',dest/'compiler.wasm')
  shutil.copy2(workspace/'engines/o0/viberun',dest/'viberun')
  for name in ['taskgroup_functions_frontend.mjs','taskgroup_lowering_frontend.mjs']:
   shutil.copy2(workspace/'engines/images'/name,dest/name)
 paths=[Path(p) for p in subprocess.check_output(['git','ls-files','--','lib','scripts','runtime/viberun'],text=True).splitlines()]
 paths += [Path('lib/@vibe/compiler')/n for n in ['compiler_sources_bundle.vibe','cli_adapter_bundle.vibe','selfbuild_runtime_entry_bundle.vibe','_cli_adapter_module_source.vibe','cache/codegen_fingerprint.vibe']]
 authority={'base_commit':meta['source_commit'],'files':image_files(),'sources':{str(p):base.sha(root/p) for p in sorted(paths) if p.is_file()},'patch_sha256':base.sha(lab/'fingerprint-candidate.patch'),'harness_sha256':base.sha(__file__),'scope':'Frozen403d filesystem compiler/CLI corpus, targetRC1. Candidate4byte fingerprint batching and tests only. Same native runner; context7/job2/ABI2 unchanged. Three alternating cold/warm AB; ordinary AA equalpaths/privatecaches. Separate diagnostic CPU profiles. No source edits or concurrent heavywork. Timings are not actualtargetRC0 bootstrap or native-thread promotion.'}
 base.write(lab/'comparison-authority.json',authority)
authority=json.loads((lab/'comparison-authority.json').read_text())
def verify_sources():
 base.verify_source(corpus,meta)
 for p,h in authority['sources'].items():assert base.sha(root/p)==h,('candidate source changed',p)
 for p,h in reference['input_sha256'].items():assert base.sha(corpus/p)==h,('target input changed',p)
 assert authority['files']==image_files() and authority['harness_sha256']==base.sha(__file__)
 assert authority['patch_sha256']==base.sha(lab/'fingerprint-candidate.patch')
verify_sources()
for lane in ['a0','b0','aa']:
 image=engines/lane;receipt=json.loads((image/'build.json').read_text())
 assert receipt['compiler_sha256']==base.sha(image/'compiler.wasm')
 assert receipt['runner_sha256']==base.sha(image/'viberun')==base.sha(engines/'a0/viberun')
 assert receipt['function_abi']=='bump-core-tagged-callbacks-2' and receipt['context_format']==7 and receipt['job_format']==2
 for p,h in receipt['artifacts'].items():assert base.sha(image/p)==h

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
