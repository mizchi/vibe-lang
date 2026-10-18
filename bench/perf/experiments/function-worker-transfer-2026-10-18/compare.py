"""Whole-build before/after transport comparison, N>=3, frozen inputs/images.

Run stage once, then run on an idle machine. No diagnostic times are promotion
samples. The old receipt's context_format3/actualwire4 is preserved as evidence.
"""
import argparse, collections, json, shutil, subprocess, sys
from pathlib import Path
sys.path.insert(0,str(Path.cwd()/'bench/perf'))
import selfbuild_baseline as base

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('action',choices=['stage','run'])
parser.add_argument('baseline',type=Path)
parser.add_argument('candidate_images',type=Path)
parser.add_argument('candidate_compiler',type=Path)
parser.add_argument('out',type=Path)
parser.add_argument('--rounds',type=int,default=3)
a=parser.parse_args()
if a.rounds<3:parser.error('at least three complete rounds are required')
workspace=a.baseline.resolve(); out=a.out.resolve(); corpus=workspace/'corpus'
meta=json.loads((workspace/'workspace.json').read_text())
original=json.loads((workspace/'matrix/measurement.json').read_text())
base.verify_source(corpus,meta)
before_receipt=base.image_receipts(workspace)
assert original['verified_complete'] and original['aa_guest_memory_exact'] and len(original['samples'])==72

def authority():
    return {str(p.relative_to(out)):base.sha(p) for lane in ['a0','b0'] for p in sorted((out/lane).iterdir()) if p.is_file()}

if a.action=='stage':
    out.mkdir()
    for lane,images,compiler,frontend in [
        ('a0',workspace/'engines/images',workspace/'engines/o0/compiler.wasm',corpus/'scripts'),
        ('b0',a.candidate_images.resolve(),a.candidate_compiler.resolve(),Path.cwd()/'scripts')]:
        directory=out/lane;directory.mkdir()
        receipt=json.loads((images/'build.json').read_text())
        assert receipt['compiler_sha256']==base.sha(compiler)
        assert receipt['runner_sha256']==base.sha(workspace/'engines/o0/viberun')
        for name,digest in receipt['artifacts'].items():
            assert base.sha(images/name)==digest
            shutil.copy2(images/name,directory/name)
        for name in ['taskgroup_functions_frontend.mjs','taskgroup_lowering_frontend.mjs']:
            shutil.copy2(frontend/name,directory/name)
        shutil.copy2(images/'build.json',directory/'build.json')
        shutil.copy2(compiler,directory/'compiler.wasm')
        shutil.copy2(workspace/'engines/o0/viberun',directory/'viberun')
    base.write(out/'authority.json',{'source_commit':meta['source_commit'],'fixed_corpus_archive_sha256':base.sha(workspace/'source.tar'),
        'source_overlay_sha256':base.sha(a.candidate_images.resolve()/'source-overlay.patch'),
        'candidate_build_authority_sha256':base.sha(a.candidate_images.resolve()/'source-authority.json'),
        'files':authority(),'script_sha256':base.sha(__file__),'baseline_artifacts':original['artifacts'],
        'protocol':'Fixed archived baseline corpus and generated inputs for both lanes. a0 original wire4/metadata3, b0 metadata-interning wire6. Per-round fresh guest cache, cold then warm in new processes. Native JIT primed separately. Equal-length lane/cache/output paths. Forward/reverse/forward AB order; no concurrent heavy jobs. Whole public process-worker frontend, supported targetRC1, parent/worker bump and coordinatorRC. Ordinary, same-driver serial and1/2/4 workers all measured. Simultaneous /proc RSS sampled20ms; shared mappings may be double-counted. This is not threaded bootstrap/default promotion.'})
    print('Staged immutable comparison lanes',flush=True)
    sys.exit()

record=json.loads((out/'authority.json').read_text())
assert record['files']==authority() and record['script_sha256']==base.sha(__file__)
inputs={name:base.sha(corpus/name) for name in original['input_sha256']}
assert inputs==original['input_sha256']
runner=lambda lane:out/lane/'viberun'

def command(lane,mode,source,entry,private):
    directory=out/lane
    env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_FS_COMPILE':'1','VIBE_MEM':'1',
        'VIBE_BUILD_CACHE_DIR':str(private/'cache'),'VIBE_NATIVE_CACHE_DIR':str(out/'native-cache')}
    if mode=='o0':
        cmd=[str(runner(lane)),str(directory/'compiler.wasm'),source,str(private/'out.wasm'),entry]
    elif mode=='s0':
        cmd=[str(runner(lane)),str(directory/'compile.wasm')]
        env.update(VIBE_LOWERING_MODE='serial',VIBE_LOWERING_INPUT=source,VIBE_LOWERING_OUTPUT=str(private/'out.wasm'),VIBE_LOWERING_ENTRY=entry)
    else:
        cmd=['node',str(directory/'taskgroup_functions_frontend.mjs'),str(directory/'compiler.wasm'),source,str(private/'out.wasm'),entry,
             mode[1],str(corpus),str(directory),str(runner(lane))]
        env['VIBE_FUNCTION_TRACE_OUT']=str(private/'trace.json')
    return cmd,env

runs=out/'runs';runs.mkdir()
for lane in ['a0','b0']:
    for mode in ['o0','s0','p1']:
        private=runs/f'prime-{lane}-{mode}';private.mkdir()
        cmd,env=command(lane,mode,'perf-smoke.vibe','main',private)
        base.measure(cmd,corpus,env,private/'logs')
rows=[]
report={'authority':record,'samples':rows,'verified_complete':False,'expected_samples':2*5*2*2*a.rounds,'rounds':a.rounds}
for subject,prefix,source,entry in [('compiler','c','lib/@vibe/compiler/tests/codegen_lexer_test.vibe','__no_entry__'),
                                   ('split-cli','l','lib/@vibe/cli/entry.vibe','cli_main')]:
    for rnd in range(a.rounds):
        for mode in ['o0','s0','p1','p2','p4']:
            for lane in (['a0','b0'] if rnd%2==0 else ['b0','a0']):
                private=runs/f'{prefix}{rnd}-{mode}-{lane}';private.mkdir()
                for temperature in ['cold','warm']:
                    (private/'out.wasm').unlink(missing_ok=True)
                    (private/'trace.json').unlink(missing_ok=True)
                    cmd,env=command(lane,mode,source,entry,private)
                    result=base.measure(cmd,corpus,env,private/temperature)
                    digest=base.sha(private/'out.wasm')
                    assert digest==original['artifacts'][subject],(subject,lane,mode,'artifact differs')
                    if mode in ['o0','s0']:
                        result['guest_memory']=base.guest_memory((private/temperature/'run.log').read_text())
                    else:
                        trace=json.loads((private/'trace.json').read_text())
                        assert trace['workers']==int(mode[1]) and trace['context_serialization_count']==1 and trace['range_jobs']==int(mode[1])
                        result['phases']=trace
                        shutil.copy2(private/'trace.json',private/temperature/'trace.json')
                    result.update(subject=subject,round=rnd,mode=mode,lane=lane,temperature=temperature,artifact_sha256=digest,
                                  raw_directory=str((private/temperature).relative_to(out)))
                    rows.append(result);base.write(out/'measurement.json',report)
                    print(subject,rnd,mode,lane,temperature,f"{result['wall_s']:.3f}s",f"{result['process_tree_peak_rss_bytes']/2**20:.1f}MiB",flush=True)
assert len(rows)==report['expected_samples']
base.verify_source(corpus,meta)
assert record['files']==authority() and record['script_sha256']==base.sha(__file__)
assert all(base.sha(corpus/name)==digest for name,digest in inputs.items())
assert before_receipt==base.image_receipts(workspace)
report['verified_complete']=True
base.write(out/'measurement.json',report)
print('All comparisons complete; inputs, images and artifacts verified.',flush=True)
