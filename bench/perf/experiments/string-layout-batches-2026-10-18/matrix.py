"""Current-main fixed-corpus baseline;72 unprofiled runs before any source edit."""
import json,shutil,sys,time
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
workspace=lab/'baseline';corpus=workspace/'corpus';authority=json.loads((workspace/'engine-authority.json').read_text());meta=json.loads((workspace/'workspace.json').read_text())
assert json.loads((lab/'setup-validation.json').read_text())['complete']
assert authority['source_commit']=='403d735929db48325c23252630725a0d16b5ab69'
engine_sources=json.loads((lab/'engine-source-authority.json').read_text())['sources']
def verify():
 base.verify_source(corpus,meta)
 for name,h in authority['files'].items():assert base.sha(workspace/name)==h,('engine changed',name)
 for name,h in authority['input_sha256'].items():assert base.sha(corpus/name)==h,('input changed',name)
 for name,h in engine_sources.items():assert base.sha(root/name)==h,('engine source changed',name)
verify();engines=workspace/'engines';images=engines/'images';native=engines/'o0/viberun'
receipt=json.loads((images/'build.json').read_text());assert receipt['compiler_sha256']==base.sha(engines/'o0/compiler.wasm') and receipt['runner_sha256']==base.sha(native)
assert receipt['context_format']==7 and receipt['function_abi']=='bump-core-tagged-callbacks-2'
for name,digest in receipt['artifacts'].items():assert base.sha(images/name)==digest
out=workspace/'matrix';out.mkdir()
def command(mode,source,entry,private):
 env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_FS_COMPILE':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(private/'cache'),'VIBE_NATIVE_CACHE_DIR':str(workspace/'native-cache')}
 if mode in ['o0','a0']:
  cmd=[str(engines/mode/'viberun'),str(engines/mode/'compiler.wasm'),source,str(private/'out.wasm'),entry]
 elif mode=='s0':
  cmd=[str(native),str(images/'compile.wasm')];env.update(VIBE_LOWERING_MODE='serial',VIBE_LOWERING_INPUT=source,VIBE_LOWERING_ENTRY=entry,VIBE_LOWERING_OUTPUT=str(private/'out.wasm'))
 else:
  cmd=['node',str(images/'taskgroup_functions_frontend.mjs'),str(engines/'o0/compiler.wasm'),source,str(private/'out.wasm'),entry,mode[1],str(corpus),str(images),str(native)]
  env['VIBE_FUNCTION_TRACE_OUT']=str(private/'trace.json')
 return cmd,env
for mode in ['o0','a0','s0','p1']:
 private=out/f'prime-{mode}';private.mkdir();cmd,env=command(mode,'perf-smoke.vibe','main',private);base.measure(cmd,corpus,env,private/'logs')
rows=[];expected={};report={'verified_complete':False,'expected_samples':72,'rounds':3,'source_commit':authority['source_commit'],'source_tree':authority['source_tree'],'authority_sha256':base.sha(workspace/'engine-authority.json'),'driver_sha256':base.sha(__file__),'machine':meta['machine'],'samples':rows,'artifacts':expected,'protocol':'Current403d73592 source and source-bound engines, fixed current-revision filesystem compiler/CLI corpus. EmittedtargetRC1, bump parent/worker, RC coordinator. OrdinaryA/A, same-driver serial and process1/2/4, three cold/warm rounds. Fresh process/private cache per round+mode, cold then warm; mode order forward/reverse/forward, equal-length paths. NativeJIT primed on another input. OS pages warm; checked-module/body/final-artifact caches off as specified by clean_env; parsed-source caches isolated per case. RSS simultaneous process-tree sum20ms; shared mappings can double count. p4 phase timelines use current command identities. No source edits/other builds/profiles overlap. Not actual selfbuild stage/default/native-thread enablement.'}
original=base.snapshot
variants=['o0','a0','s0','p1','p2','p4']
for subject,prefix,source,entry in [('compiler','c','lib/@vibe/compiler/tests/codegen_lexer_test.vibe','__no_entry__'),('split-cli','l','lib/@vibe/cli/entry.vibe','cli_main')]:
 for rnd in range(3):
  for mode in variants if rnd%2==0 else list(reversed(variants)):
   private=out/f'{prefix}{rnd}-{mode}';private.mkdir()
   for temperature in ['cold','warm']:
    (private/'out.wasm').unlink(missing_ok=True);(private/'trace.json').unlink(missing_ok=True)
    samples=[];started=time.monotonic()
    def snapshot(pid):
     values=original(pid);processes={}
     for child,(_,rss,cpu) in values.items():
      try:cmdline=Path(f'/proc/{child}/cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
      except OSError:cmdline=''
      processes[child]={'command':cmdline,'rss_bytes':rss,'cpu_s':cpu}
     samples.append({'s':time.monotonic()-started,'processes':processes});return values
    cmd,env=command(mode,source,entry,private)
    if mode=='p4':base.snapshot=snapshot
    try:result=base.measure(cmd,corpus,env,private/temperature)
    finally:base.snapshot=original
    digest=base.sha(private/'out.wasm');assert expected.setdefault(subject,digest)==digest,(subject,mode,rnd,temperature,'output mismatch')
    if mode in ['o0','a0','s0']:result['guest_memory']=base.guest_memory((private/temperature/'run.log').read_text())
    else:
     trace=json.loads((private/'trace.json').read_text());assert trace['workers']==int(mode[1])==trace['range_jobs'] and trace['preparation_count']==1 and trace['context_serialization_count']==1
     result['phases']=trace;shutil.copy2(private/'trace.json',private/temperature/'trace.json')
    if mode=='p4':
     active=[i for i,s in enumerate(samples) if any(p['command'].endswith('/worker.wasm ') for p in s['processes'].values())];assert active
     phases={'before_workers':samples[:active[0]],'workers_alive':samples[active[0]:active[-1]+1],'after_workers':samples[active[-1]+1:]};peaks={}
     for name,values in phases.items():
      assert values
      peak=max(values,key=lambda s:sum(p['rss_bytes'] for p in s['processes'].values()));peaks[name]={'s':peak['s'],'rss_bytes':sum(p['rss_bytes'] for p in peak['processes'].values()),'processes':peak['processes']}
     result['peaks']=peaks;base.write(private/temperature/'timeline.json',{'samples':samples})
    result.update(subject=subject,round=rnd,variant=mode,temperature=temperature,artifact_sha256=digest,raw_directory=str((private/temperature).relative_to(workspace)))
    rows.append(result);base.write(out/'measurement.json',report)
    print(subject,rnd,mode,temperature,round(result['wall_s'],3),round(result['process_tree_peak_rss_bytes']/2**20,1),flush=True)
assert len(rows)==72
for subject in ['compiler','split-cli']:
 for rnd in range(3):
  for temperature in ['cold','warm']:
   pairs=[r for r in rows if r['subject']==subject and r['round']==rnd and r['temperature']==temperature and r['variant'] in ['o0','a0']];assert len(pairs)==2 and pairs[0]['guest_memory']==pairs[1]['guest_memory'],('A/A mismatch',pairs)
verify();assert base.sha(__file__)==report['driver_sha256']
report.update(verified_complete=True,aa_guest_memory_exact=True,input_sha256=authority['input_sha256']);base.write(out/'measurement.json',report)
print('All72 current-main matrix samples match output; all12 A/A guest-memory pairs exact; authority unchanged.',flush=True)
