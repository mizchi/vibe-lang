"""Separate before/after ownership/profile controls; never promotion timings.

Requires the complete unprofiled comparison. Both lanes use the exact same
archived corpus and equal-length private paths. Every artifact/product hash,
source receipt and real filesystem byte count is checked.
"""
import json, os, sys, time, uuid
from pathlib import Path
sys.path.insert(0,str(Path.cwd()/'bench/perf'))
import selfbuild_baseline as base
import selfbuild_profiles as profiles

lab=Path(sys.argv[1]).resolve(); workspace=lab/'baseline'; comparison=lab/'comparison'
measured=json.loads((comparison/'measurement.json').read_text())
assert measured['verified_complete'] and len(measured['samples'])==120,'Complete all unprofiled samples first'
authority=json.loads((comparison/'authority.json').read_text())
corpus=workspace/'corpus';meta=json.loads((workspace/'workspace.json').read_text())
base.verify_source(corpus,meta)
def verify_images():
    for name,digest in authority['files'].items():assert base.sha(comparison/name)==digest,('image changed',name)
verify_images()
out=lab/'transport-diagnostics';out.mkdir()
parent=out/'parent-profiles';parent.mkdir()
workers=out/'worker-profiles';workers.mkdir()
summary={'scope':'Separate controls and epoch CPU profiles. Not promotion walltime. Guest frontier/allocation/reserved pages and wire bytes are distinct from simultaneous RSS; do not sum independent per-process maxima.',
         'comparison_authority_sha256':base.sha(comparison/'authority.json'),'parent':[],'workers':[],'timelines':[]}
captures=[]
subjects=[('compiler','lib/@vibe/compiler/tests/codegen_lexer_test.vibe','__no_entry__'),('split-cli','lib/@vibe/cli/entry.vibe','cli_main')]
for lane in ['a0','b0']:
    images=comparison/lane; runner=images/'viberun'; laneout=parent/lane;laneout.mkdir()
    wrapper=laneout/'capture-runner.py';wrapper.write_text(profiles.CAPTURE);wrapper.chmod(0o755)
    receipt=json.loads((images/'build.json').read_text())
    for subject,source,entry in subjects:
        for index in range(5):
            private=laneout/f'{subject}-{index}';private.mkdir()
            config=private/'service.json'
            base.write(config,{'version':1,'worker':str(images/'worker.wasm'),'coordinator':str(images/'coordinator.component.wasm'),
                              'runner':str(wrapper if index==0 else runner),'cwd':str(corpus),'directory':str(private),'jobs':4})
            env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(laneout/f'{subject}-cache'),
                'VIBE_NATIVE_CACHE_DIR':str(comparison/'native-cache'),'VIBE_LOWERING_INPUT':source,'VIBE_LOWERING_OUTPUT':str(private/'out.wasm'),
                'VIBE_LOWERING_ENTRY':entry,'VIBE_LOWERING_DIRECTORY':str(private),'VIBE_LOWERING_MODE':'single','VIBE_FUNCTION_JOBS':'4',
                'VIBE_LOWERING_SERVICE_CONFIG':str(config),'SELFBUILD_NATIVE_RUNNER':str(runner),'SELFBUILD_CAPTURE':str(laneout/f'capture-{subject}')}
            if index>=2:env['VIBE_GUEST_PROFILE']=str(private/'cpu.json')
            profiles.run([str(runner),str(images/'compile.wasm')],corpus,env,private/'logs')
            assert base.sha(private/'out.wasm')==authority['baseline_artifacts'][subject]
            if index==1:
                summary['parent'].append({'lane':lane,'subject':subject,'temperature':'warm','guest_memory':base.guest_memory((private/'logs/stderr.log').read_text()),'path':str(private.relative_to(lab))})
            if index==0:
                capture=laneout/f'capture-{subject}/wave-0/capture.json'
                record=json.loads(capture.read_text());context=profiles.context_pool((capture.parent/'shared.context').read_bytes())
                assert context['context_format']==(4 if lane=='a0' else 6)
                if lane=='b0':assert context['context_format']==receipt['context_format']
                summary.setdefault('contexts',[]).append({'lane':lane,'subject':subject,'wire':context,'receipt_context_format':receipt['context_format'],
                    'qualification':'Original a0 metadata3/wire4 mismatch preserved; current b0 actual wire matches receipt.',
                    'jobs_bytes':sum(r['input_bytes'] for q in record['queues'] for r in q),'products_bytes':sum(r['product_bytes'] for q in record['queues'] for r in q)})
                captures.append((lane,subject,capture,record))
            print('parent',lane,subject,index,'hash matches',flush=True)
            base.write(out/'summary.json',summary)
for lane,subject,capture,record in captures:
    laneout=workers/lane;laneout.mkdir(exist_ok=True)
    for slot,queue in enumerate(record['queues']):
        if not queue:continue
        private=laneout/f'{subject}-{slot}';private.mkdir()
        listing=private/'jobs.list';listing.write_text('\n'.join(str(capture.parent/r['name']) for r in queue))
        for index in range(4):
            nonce=str(uuid.uuid4());scope=private/'host-io.json'
            env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_MEM':'1','VIBE_NATIVE_CACHE_DIR':str(comparison/'native-cache'),
                'VIBE_LOWERING_WORKER_LIST':str(listing),'VIBE_LOWERING_SHARED_CONTEXT':str(capture.parent/'shared.context')}
            if index:env['VIBE_GUEST_PROFILE']=str(private/f'cpu-{index}.json')
            else:env.update(VIBE_HOST_FS_SCOPE_OUT=str(scope),VIBE_HOST_FS_SCOPE_NONCE=nonce)
            profiles.run([str(comparison/lane/'viberun'),str(comparison/lane/'worker.wasm')],corpus,env,private/str(index))
            for row in queue:assert base.sha(capture.parent/(row['name']+'.product'))==row['product_sha256']
            if index==0:
                counters=json.loads(scope.read_text())
                assert counters['nonce']==nonce and counters['read_bytes_calls']==1+len(queue)
                assert counters['read_bytes_returned_bytes']==record['context_bytes']+sum(r['input_bytes'] for r in queue)
                summary['workers'].append({'lane':lane,'subject':subject,'slot':slot,'guest_memory':base.guest_memory((private/'0/stderr.log').read_text()),
                    'host_io':counters,'product_hashes_match':True,'path':str(private.relative_to(lab))})
            print('worker',lane,subject,slot,index,'products match',flush=True)
            base.write(out/'summary.json',summary)
profiles.summarize(out)
timeline=out/'rss-timeline';timeline.mkdir()
original_snapshot=base.snapshot
for subject,source,entry in subjects:
    for lane in ['a0','b0']:
        private=timeline/f'{subject}-{lane}';private.mkdir()
        for temperature in ['cold','warm']:
            samples=[];names={};started=time.monotonic()
            def snapshot(root):
                values=original_snapshot(root)
                for pid in values:
                    if pid not in names:
                        try:names[pid]=Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
                        except OSError:continue
                samples.append({'s':time.monotonic()-started,'processes':{pid:{'rss_bytes':v[1],'cpu_s':v[2]} for pid,v in values.items()}})
                return values
            base.snapshot=snapshot
            images=comparison/lane
            env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_FS_COMPILE':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(private/'cache'),
                'VIBE_NATIVE_CACHE_DIR':str(comparison/'native-cache'),'VIBE_FUNCTION_TRACE_OUT':str(private/f'{temperature}-trace.json')}
            command=['node',str(images/'taskgroup_functions_frontend.mjs'),str(images/'compiler.wasm'),source,str(private/'out.wasm'),entry,'4',str(corpus),str(images),str(images/'viberun')]
            result=base.measure(command,corpus,env,private/temperature)
            assert base.sha(private/'out.wasm')==authority['baseline_artifacts'][subject]
            ids={pid for pid,cmd in names.items() if cmd.endswith('/worker.wasm ')}
            active=[i for i,s in enumerate(samples) if ids & set(s['processes'])];assert active
            groups={'before_workers':samples[:active[0]],'workers_alive':samples[active[0]:active[-1]+1],'after_workers':samples[active[-1]+1:]}
            peaks={}
            for phase,values in groups.items():
                if not values:continue
                peak=max(values,key=lambda s:sum(p['rss_bytes'] for p in s['processes'].values()))
                peaks[phase]={'s':peak['s'],'rss_bytes':sum(p['rss_bytes'] for p in peak['processes'].values()),'processes':peak['processes']}
            observation={'lane':lane,'subject':subject,'temperature':temperature,'artifact_sha256':base.sha(private/'out.wasm'),'peaks':peaks,'commands':names,
                         'qualification':'Diagnostic replay only; sampled20ms simultaneous RSS, shared pages may be counted repeatedly; worker boundaries quantized by sampling.'}
            base.write(private/temperature/'timeline.json',{'observation':observation,'samples':samples})
            summary['timelines'].append(observation);base.write(out/'summary.json',summary)
            print('timeline',lane,subject,temperature,{k:round(v['rss_bytes']/2**20,1) for k,v in peaks.items()},flush=True)
base.snapshot=original_snapshot
verify_images();base.verify_source(corpus,meta)
summary.update(verified_complete=True,counts={'parent_runs':20,'worker_runs':64,'timeline_runs':8})
base.write(out/'summary.json',summary)
print('All diagnostic outputs/products, source and image authority verified.',flush=True)
