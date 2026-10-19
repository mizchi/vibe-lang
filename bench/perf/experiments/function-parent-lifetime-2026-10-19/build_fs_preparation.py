"""Fresh source-bound filesystem/shared preparation producer and regressions."""
import hashlib,json,os,subprocess,sys,tarfile,time
from pathlib import Path
root=Path.cwd();lab=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3';work=lab/'typed-module-preparation';out=work/'filesystem-preparation'
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
result=out/'build-result.json';assert not result.exists()
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
paths=set(subprocess.check_output(['git','diff','--name-only','HEAD','--','lib/'],text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard','lib/'],text=True).splitlines())
sources={p:sha(root/p) for p in sorted(paths)}
prior=json.loads((work/'build-result.json').read_text());assert prior['complete'] and prior['head']==subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
reference=work/'reference-generation/stage2.wasm';assert sha(reference)==prior['reference']['compiler_sha256']
with tarfile.open(out/'candidate-sources.tar.gz','w:gz') as a:
 for p in sorted(paths):a.add(root/p,arcname=p)
report={'complete':False,'head':prior['head'],'source_sha256':sources,'driver_sha256':sha(__file__),'source_archive_sha256':sha(out/'candidate-sources.tar.gz'),'reference':prior['reference'],'reference_proof':str(work/'build-result.json'),'steps':[],'scope':'Shared actual filesystem prepare/check/lowering observations; cache-off deferred module, same ordinary on/verify cache suffix. Intermediate functional validation only; no Store release or timing claim.'}
runner=lab/'baseline/engines/o0/viberun';report['runner_sha256']=sha(runner)
def write():base.write(result,report)
def verify():
 assert all(sha(root/p)==h for p,h in sources.items()),'Source changed during verification'
 assert sha(__file__)==report['driver_sha256']
 assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==report['head']
def run(name,cmd,env):
 verify();start=time.monotonic()
 with (out/(name+'.log')).open('w') as f:
  p=subprocess.Popen([str(s) for s in cmd],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':name,'pid':p.pid,'start_ticks':Path(f'/proc/{p.pid}/stat').read_text().split()[21]};write();code=p.wait()
 report.pop('live_step');report['steps'].append({'name':name,'exit':code,'wall_s_diagnostic_only':time.monotonic()-start,'log_sha256':sha(out/(name+'.log'))});write()
 print(name,code,flush=True)
 if code:raise RuntimeError(name+': '+(out/(name+'.log')).read_text()[-4000:])
 verify()
write()
env=base.clean_env(root)|{'VIBE_NATIVE_CACHE_DIR':str(out/'build-native-cache'),'VIBE_BUILD_CACHE_DIR':str(out/'build-cache')}
run('generated',['bash','scripts/ensure_generated.sh'],env)
run('generation',['bash','scripts/generations.sh','build','--stage3','--out-dir',out/'generation'],env)
assert (out/'generation/stage2.wasm').read_bytes()==(out/'generation/stage3.wasm').read_bytes()
report['compiler_sha256']=sha(out/'generation/stage2.wasm');report['stage2_equals_stage3']=True;report['generation_sha256']=sha(out/'generation/generation.json');write()
for file in ['linked_module_preparation_test.vibe','file_module_preparation_test.vibe']:
 for mode in ['0','1','shadow']:
  label=file+'-'+mode;module=out/(label+'.wasm')
  env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':mode,'VIBE_BUILD_CACHE_DIR':str(out/(label+'-cache')),'VIBE_NATIVE_CACHE_DIR':str(out/'test-native-cache')}
  run('test-compile-'+label,[runner,out/'generation/stage2.wasm',root/'lib/@vibe/compiler/tests'/file,module,'__no_entry__'],env)
  assert module.is_file() and module.stat().st_size>0
  assert not module.with_suffix('.wasm.diag').exists() or not module.with_suffix('.wasm.diag').stat().st_size
  for host,cmd in [('native',[runner,module]),('node',['bash','scripts/run_wasm_vibe_host_runner.sh',module])]:
   run('test-run-'+label+'-'+host,cmd,base.clean_env(root))
verify();report.update(complete=True,source_unchanged=True);write()
print('Shared filesystem preparation compilerfixpoint and12fresh-producer/both-host regressions pass.',flush=True)
