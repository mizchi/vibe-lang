"""Fresh current-main and combined-candidate producers, sequential and source-bound."""
import hashlib,json,os,shutil,subprocess,sys,tarfile,time
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation'
out=work/'after-main-validation-v1';out.mkdir()
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip();assert head=='8bed6e9e61bb178af06cdb7fbae62d9bc19c6c7e'
paths=set(subprocess.check_output(['git','ls-files','--','lib/','runtime/viberun/','scripts/','bootstrap/seed.json','bench/perf/','Taskfile.pkl'],text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard','--','lib/','runtime/viberun/','scripts/'],text=True).splitlines())
sources={p:sha(root/p) for p in sorted(paths) if (root/p).is_file()}
with tarfile.open(out/'candidate-sources.tar.gz','w:gz') as archive:
 for p in sorted(sources):archive.add(root/p,arcname=p)
report={'complete':False,'head':head,'source_sha256':sources,'source_archive_sha256':sha(out/'candidate-sources.tar.gz'),'driver_sha256':sha(__file__),'steps':[],'scope':'Fresh puremain8bed and combined candidate generation fixpoints, functional output/replay/lifecycle regressions. Step durations are diagnostic only, not promotion timings or actual native-thread enablement.'}
def write():base.write(out/'result.json',report)
def verify():
 assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==head
 assert all(sha(root/p)==h for p,h in sources.items()),'Source changed during build/test'
 assert sha(__file__)==report['driver_sha256']
def run(label,cmd,cwd,env):
 verify();start=time.monotonic()
 with (out/(label+'.log')).open('w') as f:
  child=subprocess.Popen([str(p) for p in cmd],cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':label,'pid':child.pid,'start_ticks':Path(f'/proc/{child.pid}/stat').read_text().split()[21]};write();code=child.wait()
 report.pop('live_step');report['steps'].append({'name':label,'exit':code,'diagnostic_wall_s':time.monotonic()-start,'log_sha256':sha(out/(label+'.log'))});write();verify();print(label,code,flush=True)
 if code:raise RuntimeError(label+': '+(out/(label+'.log')).read_text()[-6000:])
write()
reference=out/'reference'
run('clone-reference',['git','clone','--shared','--no-checkout',root,reference],root,base.clean_env(root))
run('checkout-reference',['git','checkout','--detach',head],reference,base.clean_env(reference))
assert not subprocess.check_output(['git','status','--porcelain'],cwd=reference,text=True).strip()
(reference/'bootstrap/seed').mkdir(parents=True,exist_ok=True)
shutil.copy2(root/'bootstrap/seed/compiler.wasm',reference/'bootstrap/seed/compiler.wasm')
seed=json.loads((reference/'bootstrap/seed.json').read_text())['seed']['artifact']['sha256'];assert sha(reference/'bootstrap/seed/compiler.wasm')==seed
# Reuse a previously verified exact-source runner only through its normal hash
# check. Any source/toolchain mismatch triggers the ordinary rebuild, not a stamp edit.
previous=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/baseline'
authority=json.loads((previous/'engine-authority.json').read_text())
assert not subprocess.check_output(['git','diff',authority['source_commit'],head,'--','runtime/viberun/','scripts/ensure_viberun.sh'],text=True).strip()
old=previous/'engines/o0/viberun';assert sha(old)==authority['files']['engines/o0/viberun']
old_target=previous/'corpus/runtime/viberun/target/release';assert sha(old_target/'viberun')==sha(old)
target=reference/'runtime/viberun/target/release';target.mkdir(parents=True)
for name in ['viberun','.viberun_srchash']:shutil.copy2(old_target/name,target/name)
run('reference-runner-authority',['bash','scripts/ensure_viberun.sh'],reference,base.clean_env(reference))
run('candidate-runner-authority',['bash','scripts/ensure_viberun.sh'],root,base.clean_env(root))
report['runners']={'reference':sha(target/'viberun'),'candidate':sha(root/'runtime/viberun/target/release/viberun')};write()
for lane,corpus in [('reference',reference),('candidate',root)]:
 env=base.clean_env(corpus)|{'VIBE_NATIVE_CACHE_DIR':str(out/(lane+'-native-cache')),'VIBE_BUILD_CACHE_DIR':str(out/(lane+'-build-cache'))}
 run(lane+'-generated',['bash','scripts/ensure_generated.sh'],corpus,env)
 generation=out/(lane+'-generation')
 run(lane+'-generation',['bash','scripts/generations.sh','build','--stage3','--out-dir',generation],corpus,env)
 manifest=base.fixed_point(generation)
 report[lane]={'stage2_equals_stage3':True,'compiler_sha256':sha(generation/'stage2.wasm'),'generation_sha256':sha(generation/'generation.json'),'source':manifest['source']};write()
 compiler=generation/'stage2.wasm'
 run(lane+'-images',['bash','scripts/build_taskgroup_functions.sh',compiler,out/(lane+'-images')],corpus,base.clean_env(corpus))
 receipt=json.loads((out/(lane+'-images')/'build.json').read_text())
 assert receipt['compiler_sha256']==sha(compiler) and receipt['runner_sha256']==report['runners'][lane]
 assert receipt['function_abi']==('bump-core-tagged-callbacks-2' if lane=='reference' else 'bump-core-returning-phases-3')
 for name,h in receipt['artifacts'].items():assert sha(out/(lane+'-images')/name)==h
 report[lane]['receipt']=receipt;write()
compiler=out/'candidate-generation/stage2.wasm';runner=root/'runtime/viberun/target/release/viberun'
run('candidate-public-tests',['python3','scripts/test_taskgroup_functions.py',compiler,out/'candidate-images'],root,base.clean_env(root))
for file in ['linked_section_facts_test.vibe','linked_module_preparation_test.vibe','file_module_preparation_test.vibe','function_assembly_test.vibe']:
 for mode in ['0','1','shadow']:
  label=file+'-'+mode;module=out/(label+'.wasm')
  env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':mode,'VIBE_BUILD_CACHE_DIR':str(out/(label+'-cache')),'VIBE_NATIVE_CACHE_DIR':str(out/'test-native-cache')}
  run('compile-'+label,[runner,compiler,root/'lib/@vibe/compiler/tests'/file,module,'__no_entry__'],root,env)
  assert module.is_file() and module.stat().st_size>0
  assert not module.with_suffix('.wasm.diag').exists() or module.with_suffix('.wasm.diag').stat().st_size==0
  for host,cmd in [('native',[runner,module]),('node',['bash','scripts/run_wasm_vibe_host_runner.sh',module])]:
   run('run-'+label+'-'+host,cmd,root,base.clean_env(root))
verify();report.update(complete=True,source_unchanged=True);write()
print('Fresh main/candidate fixpoints, receipt-bound images, public worker gates and all24 foundation host/mode runs pass.',flush=True)
