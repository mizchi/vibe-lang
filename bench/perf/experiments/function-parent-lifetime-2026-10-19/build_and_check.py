"""Sequential current-main reference and typed-preparation generation; no timings."""
import hashlib,json,os,subprocess,sys,tarfile,time
from pathlib import Path
root=Path.cwd();lab=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3';out=lab/'typed-module-preparation'
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
result=out/'build-result.json';assert not result.exists()
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
paths=set(json.loads((out/'before/authority.json').read_text())['source_sha256'])|{'lib/@vibe/compiler/codegen/wasi/linked_module_preparation.vibe','lib/@vibe/compiler/tests/linked_module_preparation_test.vibe'}
sources={p:sha(root/p) for p in sorted(paths)}
with tarfile.open(out/'candidate-sources.tar.gz','w:gz') as a:
 for p in sorted(paths):a.add(root/p,arcname=p)
report={'complete':False,'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'source_sha256':sources,'driver_sha256':sha(__file__),'source_archive_sha256':sha(out/'candidate-sources.tar.gz'),'steps':[],'scope':'Typed preparation and canonical dispatcher intermediate functional verification. Pure committed9273 reference rebuilt separately. Timings are diagnostic orchestration metadata, not benchmarks. No parent Store release implemented.'}
runner=lab/'baseline/engines/o0/viberun';report['runner_sha256']=sha(runner)
def write():base.write(result,report)
def verify():
 assert all(sha(root/p)==h for p,h in sources.items()),'Source changed during generation/tests'
 assert sha(__file__)==report['driver_sha256']
def run(name,cmd,cwd,env):
 verify();start=time.monotonic()
 with (out/(name+'.log')).open('w') as f:
  p=subprocess.Popen([str(s) for s in cmd],cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':name,'pid':p.pid,'start_ticks':Path(f'/proc/{p.pid}/stat').read_text().split()[21]};write();code=p.wait()
 report.pop('live_step');report['steps'].append({'name':name,'exit':code,'wall_s_diagnostic_only':time.monotonic()-start,'log_sha256':sha(out/(name+'.log'))});write()
 print(name,code,flush=True)
 if code:raise RuntimeError(name+': '+(out/(name+'.log')).read_text()[-4000:])
 verify()
write()
for lane,corpus in [('reference',out/'reference-main'),('candidate',root)]:
 if lane=='reference':
  assert subprocess.check_output(['git','status','--porcelain'],cwd=corpus,text=True).strip()==''
 env=base.clean_env(corpus)|{'VIBE_NATIVE_CACHE_DIR':str(out/(lane+'-native-cache')),'VIBE_BUILD_CACHE_DIR':str(out/(lane+'-build-cache'))}
 run(lane+'-generated',['bash','scripts/ensure_generated.sh'],corpus,env)
 run(lane+'-generation',['bash','scripts/generations.sh','build','--stage3','--out-dir',out/(lane+'-generation')],corpus,env)
 gen=out/(lane+'-generation');manifest=json.loads((gen/'generation.json').read_text())
 assert (gen/'stage2.wasm').read_bytes()==(gen/'stage3.wasm').read_bytes()
 report[lane]={'stage2_equals_stage3':True,'compiler_sha256':sha(gen/'stage2.wasm'),'generation_sha256':sha(gen/'generation.json')}
 write()
compiler=out/'candidate-generation/stage2.wasm'
for mode in ['0','1','shadow']:
 module=out/('preparation-'+mode+'.wasm')
 env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':mode,'VIBE_BUILD_CACHE_DIR':str(out/('test-cache-'+mode)),'VIBE_NATIVE_CACHE_DIR':str(out/'test-native-cache')}
 run('test-compile-'+mode,[runner,compiler,root/'lib/@vibe/compiler/tests/linked_module_preparation_test.vibe',module,'__no_entry__'],root,env)
 for host,cmd in [('native',[runner,module]),('node',['bash','scripts/run_wasm_vibe_host_runner.sh',module])]:
  run('test-run-'+mode+'-'+host,cmd,root,base.clean_env(root))
 verify()
report.update(complete=True,source_unchanged=True,regression_modes=['0','1','shadow'],regression_hosts=['native','node']);write()
print('Both normal generation fixpoints and all6 fresh-producer deferred-preparation runs pass.',flush=True)
