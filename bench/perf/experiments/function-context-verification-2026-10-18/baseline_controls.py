"""Current-engine before controls on the unchanged historical fixed corpus."""
import json,subprocess,sys,time
from pathlib import Path
sys.path.insert(0,str(Path.cwd()/'bench/perf'))
import selfbuild_baseline as base
lab=Path(__file__).resolve().parent
record=json.loads((lab/'before-authority.json').read_text())
workspace=Path(record['target_workspace']);corpus=workspace/'corpus'
meta=json.loads((workspace/'workspace.json').read_text());matrix=json.loads((workspace/'matrix/measurement.json').read_text())
assert matrix['verified_complete']
def verify():
 base.verify_source(corpus,meta)
 for p,h in record['engine_sources'].items():assert base.sha(Path.cwd()/p)==h,('engine source changed',p)
 for p,h in record['files'].items():assert base.sha(lab/p)==h,('before image changed',p)
verify()
out=lab/'before-controls';out.mkdir();images=lab/'engines/a0';rows=[]
report={'complete':False,'scope':record['scope'],'samples':rows,'expected_samples':12,'sampling':'Actual per-sample process identities; simultaneous RSS20ms. Shared mappings can be double-counted. Phase boundary times are sampling bounds, not exact allocation lifetimes.'}
# Compilation cache priming is outside recorded samples and uses another input.
prime=out/'prime';prime.mkdir()
env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(prime/'cache'),'VIBE_NATIVE_CACHE_DIR':str(lab/'native-cache')}
cmd=['node',str(images/'taskgroup_functions_frontend.mjs'),str(images/'compiler.wasm'),'perf-smoke.vibe',str(prime/'out.wasm'),'main','4',str(corpus),str(images),str(images/'viberun')]
base.measure(cmd,corpus,env,prime/'logs')
original=base.snapshot
for subject,source,entry in [('compiler','lib/@vibe/compiler/tests/codegen_lexer_test.vibe','__no_entry__'),('split-cli','lib/@vibe/cli/entry.vibe','cli_main')]:
 for rnd in range(3):
  private=out/f'{subject}-{rnd}';private.mkdir()
  for temperature in ['cold','warm']:
   samples=[];history={};started=time.monotonic()
   def snapshot(root):
    values=original(root);now=time.monotonic()-started;processes={}
    for pid,(_,rss,cpu) in values.items():
     try:command=Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
     except OSError:command=''
     processes[pid]={'command':command,'rss_bytes':rss,'cpu_s':cpu}
     events=history.setdefault(pid,[])
     if not events or events[-1]['command']!=command:events.append({'s':now,'command':command})
    samples.append({'s':now,'processes':processes});return values
   env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(private/'cache'),'VIBE_NATIVE_CACHE_DIR':str(lab/'native-cache'),'VIBE_FUNCTION_TRACE_OUT':str(private/'trace.json')}
   cmd=['node',str(images/'taskgroup_functions_frontend.mjs'),str(images/'compiler.wasm'),source,str(private/'out.wasm'),entry,'4',str(corpus),str(images),str(images/'viberun')]
   base.snapshot=snapshot
   try:result=base.measure(cmd,corpus,env,private/temperature)
   finally:base.snapshot=original
   assert base.sha(private/'out.wasm')==matrix['artifacts'][subject]
   trace=json.loads((private/'trace.json').read_text());assert trace['workers']==4 and trace['context_serialization_count']==1
   active=[i for i,s in enumerate(samples) if any(p['command'].endswith('/worker.wasm ') for p in s['processes'].values())];assert active
   groups={'before_workers':samples[:active[0]],'workers_alive':samples[active[0]:active[-1]+1],'after_workers':samples[active[-1]+1:]};peaks={}
   for phase,values in groups.items():
    assert values
    peak=max(values,key=lambda s:sum(p['rss_bytes'] for p in s['processes'].values()))
    peaks[phase]={'s':peak['s'],'rss_bytes':sum(p['rss_bytes'] for p in peak['processes'].values()),'processes':peak['processes']}
   row=result|{'subject':subject,'round':rnd,'temperature':temperature,'artifact_sha256':base.sha(private/'out.wasm'),'trace':trace,'peaks':peaks}
   base.write(private/temperature/'timeline.json',{'row':row,'samples':samples,'exec_history':history})
   rows.append(row);base.write(out/'measurement.json',report)
   print(subject,rnd,temperature,round(row['wall_s'],3),{k:round(v['rss_bytes']/2**20,1) for k,v in peaks.items()},flush=True)
verify();assert len(rows)==12
report['complete']=True;base.write(out/'measurement.json',report)
print('Before controls complete: source/images/output hashes verified; all12 samples retained.',flush=True)
