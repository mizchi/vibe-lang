"""Fresh candidate compiler and cross-lane fingerprint regression validation."""
import json,subprocess,sys,time
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
compiler=lab/'candidate-generation/stage2.wasm'
producer=base.fixed_point(compiler.parent)
record=json.loads((lab/'fingerprint-candidate-source.json').read_text())
steps=[]
def verify():
 for p,h in record['files'].items():assert base.sha(root/p)==h,('candidate source changed',p)
 assert base.sha(compiler)==producer['stages']['stage2']['sha256']
def run(name,command,env=None,expected=0):
 verify();start=time.monotonic()
 with (lab/(name+'.log')).open('w') as log:r=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=1200)
 step={'name':name,'command':list(map(str,command)),'exit':r.returncode,'wall_s':time.monotonic()-start,'expected_exit':expected}
 steps.append(step);base.write(lab/'candidate-validation.json',{'complete':False,'steps':steps})
 print(name,r.returncode,round(step['wall_s'],3),flush=True)
 assert (r.returncode==0 if expected==0 else r.returncode!=0),step
 verify()
run('candidate-generated-check',['bash','scripts/ensure_generated.sh','--check'])
native=root/'runtime/viberun/target/release/viberun'
test='lib/@vibe/compiler/tests/codegen_layout_fingerprint_test.vibe'
for mode in ['bump','rc','shadow','gc']:
 out=lab/f'test-{mode}.wasm'
 env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':{'bump':'0','rc':'1','shadow':'shadow','gc':'1'}[mode],'VIBE_BUILD_CACHE_DIR':str(lab/f'test-{mode}-cache')}
 if mode=='gc':env['VIBE_BACKEND']='gc'
 selected_test=str(lab/'gc-fingerprint-probe.vibe') if mode=='gc' else test
 run('compile-'+mode,[str(native),str(compiler),selected_test,str(out),'__no_entry__'],env)
 run('run-'+mode+'-node',['bash','scripts/run_wasm_vibe_host_runner.sh','--invoke','_start',str(out)],env)
 if mode=='gc':
  run('run-gc-wasmtime',['wasmtime','run','-W','gc=y,function-references=y,exceptions=y','--invoke','_start',str(out)],env)
 else:run('run-'+mode+'-native',[str(native),str(out)],env)

# A fifth unreduced Horner step can overflow the Int representation. The real
# public fingerprint test must compile this variant and then reject its bytes.
target='lib/@vibe/compiler/codegen/common_base/common_base_codegen_body_cache_from_bytes.vibe'
source=(root/target).read_text()
assert source.count('while k + 4 <= len {')==1
mutant=source.replace('while k + 4 <= len {','while k + 5 <= len {',1)
needle='    let b3 = String::char_code_at(sv, k + 3)\n'
assert mutant.count(needle)==1
mutant=mutant.replace(needle,needle+'    let b4 = String::char_code_at(sv, k + 4)\n',1)
for multiplier,modulus in [(131,2147483647),(137,2147483629)]:
 before=f' * {multiplier} + b3) % {modulus}'
 after=f' * {multiplier} + b3) * {multiplier} + b4) % {modulus}'
 assert mutant.count(before)==1
 mutant=mutant.replace(before,after,1)
 # One extra opening parenthesis for the fifth Horner step.
 which='h1' if multiplier==131 else 'h2'
 before=f'{which} = (((('
 assert mutant.count(before)==1
 mutant=mutant.replace(before,f'{which} = (((((',1)
assert mutant.count('    k = k + 4\n')==1
mutant=mutant.replace('    k = k + 4\n','    k = k + 5\n',1)
path=lab/'fivebyte-overflow-mutant.vibe';path.write_text(mutant)
for mode,rc in [('bump','0'),('rc','1')]:
 out=lab/f'mutant-{mode}.wasm'
 env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':rc,'VIBE_BUILD_CACHE_DIR':str(lab/f'mutant-{mode}-cache'),'VIBE_SOURCE_OVERLAY':str(root/target),'VIBE_SOURCE_OVERLAY_WITH':str(path)}
 run('compile-fivebyte-'+mode,[str(native),str(compiler),test,str(out),'__no_entry__'],env)
 assert base.sha(out)!=base.sha(lab/f'test-{mode}.wasm'),'overlay did not change tested binary'
 run('reject-fivebyte-'+mode,[str(native),str(out)],base.clean_env(root),expected=1)
env=base.clean_env(root)|{'VIBE_TEST_CLI_WASM':str(compiler),'VIBE_BUILD_CACHE_DIR':str(lab/'regression-cache'),'VIBE_RC':'1'}
run('body-cache-regressions',['bash','scripts/vibe_test.sh',
 'lib/@vibe/compiler/tests/codegen_body_cache_persist_test.vibe',
 'lib/@vibe/compiler/tests/body_cache_edit_classes_test.vibe',
 'lib/@vibe/compiler/tests/codegen_body_cache_test.vibe'],env)
run('public-functions',['python3','scripts/test_taskgroup_functions.py',str(compiler),str(lab/'candidate-images')])
verify()
receipt=json.loads((lab/'candidate-images/build.json').read_text())
assert receipt['compiler_sha256']==base.sha(compiler)
for p,h in receipt['artifacts'].items():assert base.sha(lab/'candidate-images'/p)==h
base.write(lab/'candidate-validation.json',{'complete':True,'steps':steps,'producer':producer,'receipt':receipt,'source_authority':record,'mutant_sha256':base.sha(path),'scope':'Actual candidate compiler; bump/RC/shadow plusGC and scalar persisted oracle. Fivebyte overflow mutation must compile then trap on bump andRC. Real public function-worker suite, output/guard regressions.'})
print('Candidate source-bound correctness validated.',flush=True)
