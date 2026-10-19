"""Real-image serial control, memory/sampler cleanup, and per-phase CPU profiles."""
import hashlib,json,os,subprocess,sys
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';out=work/'native-phase-observation-v2';out.mkdir()
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
proof=json.loads((work/'native-phases-integration-v4/result.json').read_text());assert proof['complete']
sources=proof['source_sha256'];assert all(sha(root/p)==h for p,h in sources.items())
runner=root/'runtime/viberun/target/release/viberun';compiler=work/'filesystem-preparation/generation/stage2.wasm';images=work/'native-phases-integration-v4/images'
assert sha(runner)==proof['runner_sha256']
report={'complete':False,'scope':'Functional observation-path checks only. Serial parity, standard sampler/profiler cleanup and fresh finisher admission. No timing or RSS comparison/promotion claim.','source_sha256':sources,'runner_sha256':sha(runner),'compiler_sha256':sha(compiler),'rows':[]}
project=out/'project';project.mkdir();(project/'main.vibe').write_text('fn make(n: Int) -> (Int) -> Int { (x) -> x - n }\nfn main() -> Int { let f = make(3); f(100) }\n')
def write():base.write(out/'result.json',report)
def verify():assert all(sha(root/p)==h for p,h in sources.items())
def run(label,cmd,env):
 verify()
 with (out/(label+'.log')).open('w') as f:
  p=subprocess.Popen([str(v) for v in cmd],cwd=project,env=env,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':label,'pid':p.pid,'start_ticks':Path(f'/proc/{p.pid}/stat').read_text().split()[21]};write();code=p.wait()
 report.pop('live_step');write();verify()
 assert code==0,(label,code,(out/(label+'.log')).read_text()[-7000:])
 return out/(label+'.log')
env=base.clean_env(project)|{'VIBE_LIB':str(root/'lib'),'VIBE_RC':'1','VIBE_NATIVE_CACHE_DIR':str(out/'native-cache')}
ordinary=out/'ordinary.wasm'
run('ordinary',[runner,compiler,'main.vibe',ordinary,'main'],env|{'VIBE_FS_COMPILE':'1','VIBE_BUILD_CACHE_DIR':str(out/'ordinary-cache')})
assert ordinary.exists() and ordinary.stat().st_size>0
for label,mode,options in [('serial','serial',{}),('sampled','single',{'VIBE_MEM':'1','VIBE_MEM_SAMPLE_MS':'1'}),('profiled','single',{'VIBE_GUEST_PROFILE':str(out/'guest-profile.json'),'VIBE_GUEST_PROFILE_INTERVAL_US':'1000'})]:
 directory=out/label;directory.mkdir();output=directory/'out.wasm'
 config=directory/'service.json';config.write_text(json.dumps({'version':1,'worker':str(images/'worker.wasm'),'runner':str(runner),'coordinator':str(images/'coordinator.component.wasm'),'cwd':str(project),'directory':str(directory),'jobs':2}))
 selected=env|{'VIBE_LOWERING_INPUT':'main.vibe','VIBE_LOWERING_ENTRY':'main','VIBE_LOWERING_MODE':mode,'VIBE_FUNCTION_JOBS':'2','VIBE_LOWERING_DIRECTORY':str(directory),'VIBE_LOWERING_SERVICE_CONFIG':str(config),'VIBE_LOWERING_OUTPUT':str(output),'VIBE_BUILD_CACHE_DIR':str(directory/'cache'),'VIBE_HOST_FS_SCOPE_OUT':str(directory/'fs-scope.json'),'VIBE_HOST_FS_SCOPE_NONCE':label}|options
 log=run(label,[runner,'--function-phases',images/'compile.wasm'],selected)
 assert output.read_bytes()==ordinary.read_bytes(),(label,'ordinary/phase bytes differ')
 scope=json.loads((directory/'fs-scope.json').read_text());assert scope['nonce']==label and scope['read_file_calls']>0
 row={'label':label,'mode':mode,'module_sha256':sha(output),'stdout_log_sha256':sha(log),'host_fs_scope':scope}
 report['rows'].append(row);write()
 if mode=='single':
  service=json.loads((directory/'service-report.json').read_text())
  assert service['preparation_store_dropped_before_workers'] and service['finisher_store_fresh'] and service['finisher_source_reads']==0
  row['service_report']=service;write()
 if label=='sampled':
  text=log.read_text();assert text.count('vibe::mem ') == 2,text[-3000:]
  row['memory_report_count']=text.count('vibe::mem ');write()
 if label=='profiled':
  profiles={}
  for phase in ['function_phase_prepare','function_phase_finish']:
   path=out/('guest-profile.json.'+phase);data=json.loads(path.read_text())
   assert isinstance(data,dict) and path.stat().st_size>64
   profiles[phase]={'path':str(path),'sha256':sha(path),'bytes':path.stat().st_size,'keys':list(data)}
  row['profile_outputs']=profiles;write()
 print(label,'ordinary bytes match; observation cleanup correct',flush=True)
report.update(complete=True,source_unchanged=True);write()
