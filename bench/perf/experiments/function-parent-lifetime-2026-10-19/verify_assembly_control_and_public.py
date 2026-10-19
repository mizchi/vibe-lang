"""Compiled borrowed-span negative control, then fresh public process integration."""
import hashlib,json,os,subprocess,sys
from pathlib import Path
root=Path.cwd();lab=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';out=lab/'assembly-integration-v1';out.mkdir()
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
proof=json.loads((lab/'assembly-v7/result.json').read_text());assert proof['complete']
sources=proof['source_sha256'];assert all(sha(root/p)==h for p,h in sources.items())
runner=lab.parent/'baseline/engines/o0/viberun';compiler=lab/'filesystem-preparation/generation/stage2.wasm'
assert sha(compiler)==proof['compiler_sha256'] and sha(runner)==proof['runner_sha256']
target=root/'lib/@vibe/function_worker/assembly.vibe';original=target.read_text()
needle='  let r = linear_string_reader(bytes)\n';assert original.count(needle)==1
mutant=original.replace(needle,'  let r = ast_binary_reader_with_string_copy(bytes, fa_borrowed_span)\n')
mutant=mutant.replace('  AstBinaryReader,\n','  AstBinaryReader, ast_binary_reader_with_string_copy,\n',1)
mutant+='''\n// Test-only control: illegally let borrowed byte spans escape as owned strings.
fn fa_borrowed_view(bytes: Bytes) -> String = wasm
"local.get $bytes i32.wrap_i64 i32.load offset=8 i64.extend_i32_u i64.const32 i64.shl"
"local.get $bytes i32.wrap_i64 i32.load offset=4 i64.extend_i32_u i64.or"

fn fa_borrowed_span(bytes: Bytes, at: Int, length: Int) -> String {
  String::substring(fa_borrowed_view(bytes), at, at + length)
}
'''
mutant=mutant.replace('i64.const32','i64.const 32')
overlay=out/'borrowed-span-mutant.vibe';overlay.write_text(mutant);assert mutant!=original
report={'complete':False,'source_sha256':sources,'compiler_sha256':sha(compiler),'runner_sha256':sha(runner),'scope':'Actual compiled assembly ownership negative control and public legacy-process compatibility. Full Store-release phases and performance remain unimplemented.','steps':[],'control':{'overlay_sha256':sha(overlay),'hosts':{}}}
def write():base.write(out/'result.json',report)
def verify():assert all(sha(root/p)==h for p,h in sources.items()),'source changed during verification'
def run(label,cmd,env):
 verify()
 with (out/(label+'.log')).open('w') as f:
  p=subprocess.Popen([str(s) for s in cmd],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':label,'pid':p.pid,'start_ticks':Path(f'/proc/{p.pid}/stat').read_text().split()[21]};write();code=p.wait()
 report.pop('live_step');report['steps'].append({'name':label,'exit':code,'log_sha256':sha(out/(label+'.log'))});write();verify()
 return code
module=out/'borrowed-span-mutant.wasm';env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':'1','VIBE_BUILD_CACHE_DIR':str(out/'compile-cache'),'VIBE_NATIVE_CACHE_DIR':str(out/'native-cache'),'VIBE_SOURCE_OVERLAY':str(target),'VIBE_SOURCE_OVERLAY_WITH':str(overlay)}
code=run('mutant-compile',[runner,compiler,root/'lib/@vibe/compiler/tests/function_assembly_test.vibe',module,'__no_entry__'],env)
assert code==0 and module.is_file() and module.stat().st_size>0,('control did not compile',(out/'mutant-compile.log').read_text())
assert not module.with_suffix('.wasm.diag').exists() or module.with_suffix('.wasm.diag').stat().st_size==0
green=next(r['module_sha256'] for r in proof['rows'] if r['mode']=='1')
assert sha(module)!=green,'mutant did not change executable'
report['control']['module_sha256']=sha(module);write()
for host,cmd in [('native',[runner,module]),('node',['bash','scripts/run_wasm_vibe_host_runner.sh',module])]:
 code=run('mutant-'+host,cmd,base.clean_env(root));log=out/('mutant-'+host+'.log')
 report['control']['hosts'][host]={'exit':code,'log_sha256':sha(log),'failure_output':log.read_text()[-4000:]};write()
 assert code!=0 and 'check_assembly' in log.read_text(),('ownership mutant was not detected',host,log.read_text())
print('Actual borrowed-span ownership mutant rejected on both hosts.',flush=True)
env=base.clean_env(root)
for label,cmd in [('images',['bash','scripts/build_taskgroup_functions.sh',compiler,out/'images']),('public-tests',['python3','scripts/test_taskgroup_functions.py',compiler,out/'images'])]:
 code=run(label,cmd,env);print(label,code,flush=True)
 if code:raise RuntimeError((out/(label+'.log')).read_text()[-5000:])
receipt=json.loads((out/'images/build.json').read_text());assert receipt['compiler_sha256']==sha(compiler)
assert receipt['runner_sha256']==sha(root/'runtime/viberun/target/release/viberun')
for name,h in receipt['artifacts'].items():assert sha(out/'images'/name)==h
verify();report.update(complete=True,receipt=receipt,source_unchanged=True);write()
print('Owned assembly negative control and fresh public jobs1/2/4 integration pass.',flush=True)
