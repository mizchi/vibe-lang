"""Current-main paired modules and compiled negative controls; no timings."""
import hashlib,json,subprocess,sys,time,os
from pathlib import Path
root=Path.cwd();lab=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3';work=lab/'typed-module-preparation';out=work/'oracles-main8bed-v1';assert not out.exists();out.mkdir()
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
build=json.loads((work/'after-main-validation-v1/result.json').read_text());assert build['complete']
runner=root/'runtime/viberun/target/release/viberun'
sources=build['source_sha256'];assert all(sha(root/p)==h for p,h in sources.items())
engines={'reference':work/'after-main-validation-v1/reference-generation/stage2.wasm','candidate':work/'after-main-validation-v1/candidate-generation/stage2.wasm'}
report={'complete':False,'source_sha256':sources,'compiler_sha256':{k:sha(p) for k,p in engines.items()},'runner_sha256':sha(runner),'scope':'Functional shared-filesystem and ordinary/default prepared-boundary integration, source fixed on8bed6e9e6 after qualified handler changes. Puremain vs candidate output identity; actual overlay compiled for negative controls. Paired functional compiler outputs and compiled negative controls only; Store lifetime is independently tested, no performance claim.','pairs':[],'controls':[]}
def write():base.write(out/'result.json',report)
def run(label,cmd,env):
 log=out/(label+'.log')
 with log.open('w') as f:
  p=subprocess.Popen([str(s) for s in cmd],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'label':label,'pid':p.pid,'start_ticks':Path(f'/proc/{p.pid}/stat').read_text().split()[21]};write();code=p.wait()
 report.pop('live_step');write()
 return code,log
def pair(label,src,entry,options,execute=False):
 modules=[]
 for which,compiler in engines.items():
  module=out/(label+'-'+which+'.wasm')
  env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':'1','VIBE_BUILD_CACHE_DIR':str(out/(label+'-'+which+'-cache')),'VIBE_NATIVE_CACHE_DIR':str(out/'native-cache')}|options
  code,log=run(label+'-'+which+'-compile',[runner,compiler,src,module,entry],env)
  assert code==0 and module.is_file() and module.stat().st_size>0,(label,which,log.read_text())
  assert not module.with_suffix('.wasm.diag').exists() or not module.with_suffix('.wasm.diag').stat().st_size
  modules.append(module)
 assert modules[0].read_bytes()==modules[1].read_bytes(),('paired output differs',label)
 row={'label':label,'source':str(src),'source_sha256':sha(src),'entry':entry,'options':options,'module_sha256':sha(modules[1]),'bytes':modules[1].stat().st_size,'byte_identity':True,'hosts':{}}
 report['pairs'].append(row);write()
 if execute:
  for host,cmd in [('native',[runner,modules[1]]),('node',['bash','scripts/run_wasm_vibe_host_runner.sh',modules[1]])]:
   code,log=run(label+'-'+host,cmd,base.clean_env(root));row['hosts'][host]={'exit':code,'log_sha256':sha(log)};write()
   assert code==0,(label,host,log.read_text())
 print(label,'byte-identical',flush=True)
 return modules[1]
fixtures={
'unit':'fn main() -> Unit allows Console { println("unit") }\n',
'closure':'let seed = 23\nfn helper(a: Int, b: Int) -> Int { a - b }\nfn main() -> Int {\n let f = (x: Int) -> helper(seed, x)\n f(5)\n}\n',
'exception':'fn main() -> Int allows Exception {\n handle { throw("boom") } with { Exception::Throw(_) => { 7 } }\n}\n',
'division':'fn divide(n: Int) -> Int {\n n / 0\n}\nfn main() -> Int { divide(7) }\n'}
for label,text in fixtures.items():
 src=out/(label+'.vibe');src.write_text(text)
 for mode,opts in [('bump',{'VIBE_RC':'0'}),('rc',{}),('shadow',{'VIBE_RC':'shadow'}),('coverage',{'VIBE_COVERAGE':'1'}),('trace',{'VIBE_DEBUG':'1'}),('break',{'VIBE_DEBUG_BREAK':'1'}),('names',{'VIBE_WASM_NAMES':'1'})]:
  pair(label+'-'+mode,src,'main',opts,False)
for file in ['linked_section_facts_test.vibe','linked_compile_prov_inert_test.vibe','body_cache_edit_classes_test.vibe','function_worker_context_test.vibe','function_worker_lambda_order_test.vibe','linked_module_preparation_test.vibe','file_module_preparation_test.vibe']:
 for mode in ['0','1','shadow']:
  pair(file+'-'+mode,root/'lib/@vibe/compiler/tests'/file,'__no_entry__',{'VIBE_RC':mode},True)
target=root/'lib/@vibe/compiler/codegen/wasi/linked_module_preparation.vibe';original=target.read_text()
control_sources={}
needle='lc_execute_function_plan(prepared.functions, prepared.input,'
assert original.count(needle)==1
replan=original.replace(needle,'lc_build_function_bodies(prepared.input,').replace('  lc_execute_function_plan\n','  lc_build_function_bodies\n')
scope='  with_merged_offset_locations(prepared.locations, () -> {\n';assert original.count(scope)==1 and original.count('\n  })\n')==1
ambient=original.replace(scope,'  (() -> {\n').replace('\n  })\n','\n  })()\n')
for label,text in [('replan',replan),('ambient',ambient)]:
 overlay=out/(label+'-mutant.vibe');overlay.write_text(text);assert text!=original
 module=out/(label+'-mutant.wasm')
 env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':'1','VIBE_BUILD_CACHE_DIR':str(out/(label+'-cache')),'VIBE_NATIVE_CACHE_DIR':str(out/'native-cache'),'VIBE_SOURCE_OVERLAY':str(target),'VIBE_SOURCE_OVERLAY_WITH':str(overlay)}
 code,log=run(label+'-compile',[runner,engines['candidate'],root/'lib/@vibe/compiler/tests/linked_module_preparation_test.vibe',module,'__no_entry__'],env)
 assert code==0 and module.is_file() and module.stat().st_size>0,('negativecontrol did not compile',label,log.read_text())
 assert not module.with_suffix('.wasm.diag').exists() or module.with_suffix('.wasm.diag').stat().st_size==0
 green=next(row['module_sha256'] for row in report['pairs'] if row['label']=='linked_module_preparation_test.vibe-1')
 assert sha(module)!=green,'mutation did not change executable'
 row={'label':label,'overlay_sha256':sha(overlay),'target':str(target),'module_sha256':sha(module),'hosts':{}};report['controls'].append(row);write()
 for host,cmd in [('native',[runner,module]),('node',['bash','scripts/run_wasm_vibe_host_runner.sh',module])]:
  code,log=run(label+'-'+host,cmd,base.clean_env(root));row['hosts'][host]={'exit':code,'log_sha256':sha(log),'failure_output':log.read_text()[-2500:]};write()
  assert code!=0,('negativecontrol accepted',label,host)
 print(label,'compiled mutant rejected on both hosts',flush=True)
assert all(sha(root/p)==h for p,h in sources.items()),'source edited during tests'
report.update(complete=True,source_unchanged=True);write()
print('All paired current-main outputs and2compiled negativecontrols pass.',flush=True)
