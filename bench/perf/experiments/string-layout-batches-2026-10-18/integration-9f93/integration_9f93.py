"""Fresh functional integration of PR3522 with main3510/3515; no performance rerun."""
import json,subprocess,sys,time
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent;out=lab/'integration-9f93';out.mkdir()
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()=='78217f0adef84eee87a8c1172ab88833c653ca45'
merge_head=subprocess.check_output(['git','rev-parse','MERGE_HEAD'],text=True).strip();assert merge_head.startswith('9f93e38d4')
assert subprocess.run(['git','diff','--quiet']).returncode==0
paths=[Path(p) for p in subprocess.check_output(['git','ls-files','--','lib','scripts','runtime/viberun'],text=True).splitlines()]
sources={str(p):base.sha(p) for p in paths if p.is_file()};generated={};steps=[];producer=None
compiler=out/'generation/stage2.wasm';native=root/'runtime/viberun/target/release/viberun'
def verify():
 for p,h in sources.items():assert base.sha(root/p)==h,('integration source changed',p)
 for p,h in generated.items():assert base.sha(root/p)==h,('generated input changed',p)
 if producer:assert base.sha(compiler)==producer['stages']['stage2']['sha256']
def run(name,command,env=None):
 verify();started=time.monotonic()
 with (out/(name+'.log')).open('w') as log:r=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
 steps.append({'name':name,'command':command,'exit':r.returncode,'wall_s':time.monotonic()-started})
 base.write(out/'validation.json',{'complete':False,'steps':steps})
 print(name,r.returncode,round(steps[-1]['wall_s'],3),flush=True);assert r.returncode==0,steps[-1];verify()
run('generated',['bash','scripts/ensure_generated.sh'])
run('native',['bash','scripts/ensure_viberun.sh'])
run('generation',['bash','scripts/generations.sh','build','--stage3','--out-dir',str(out/'generation')])
producer=base.fixed_point(out/'generation')
generated={str(Path('lib/@vibe/compiler')/p):base.sha(root/'lib/@vibe/compiler'/p) for p in ['compiler_sources_bundle.vibe','cli_adapter_bundle.vibe','selfbuild_runtime_entry_bundle.vibe','_cli_adapter_module_source.vibe','cache/codegen_fingerprint.vibe']}
base.write(out/'source-authority.json',{'main_commit':merge_head,'premerge_branch_head':'78217f0adef84eee87a8c1172ab88833c653ca45','staged_tree':subprocess.check_output(['git','write-tree'],text=True).strip(),'sources':sources,'generated':generated,'producer':producer,'scope':'Fresh functional integration after main3510/3515; original403d performance data unchanged. No new performance claim.'})
run('function-images',['bash','scripts/build_taskgroup_functions.sh',str(compiler),str(out/'images')])
test='lib/@vibe/compiler/tests/codegen_layout_fingerprint_test.vibe'
for mode in ['bump','rc','shadow','gc']:
 output=out/('fingerprint-'+mode+'.wasm')
 env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':{'bump':'0','rc':'1','shadow':'shadow','gc':'1'}[mode],'VIBE_BUILD_CACHE_DIR':str(out/('fingerprint-cache-'+mode))}
 if mode=='gc':env['VIBE_BACKEND']='gc'
 run('compile-fingerprint-'+mode,[str(native),str(compiler),test,str(output),'__no_entry__'],env)
 run('fingerprint-'+mode+'-node',['bash','scripts/run_wasm_vibe_host_runner.sh','--invoke','_start',str(output)],env)
 if mode=='gc':run('fingerprint-gc-wasmtime',['wasmtime','run','-W','gc=y,function-references=y,exceptions=y','--invoke','_start',str(output)],env)
 else:run('fingerprint-'+mode+'-native',[str(native),str(output)],env)
env=base.clean_env(root)|{'VIBE_TEST_CLI_WASM':str(compiler),'VIBE_RC':'1','VIBE_BUILD_CACHE_DIR':str(out/'regression-cache')}
run('cache-and-runtime-regressions',['bash','scripts/vibe_test.sh','lib/@vibe/compiler/tests/codegen_body_cache_persist_test.vibe','lib/@vibe/compiler/tests/body_cache_edit_classes_test.vibe','lib/@vibe/compiler/tests/codegen_body_cache_test.vibe','lib/@vibe/compiler/tests/runtime_size_trim_test.vibe'],env)
run('public-functions',['python3','scripts/test_taskgroup_functions.py',str(compiler),str(out/'images')])
env=base.clean_env(root)|{'VIBE_CLI_WASM':str(compiler.relative_to(root)),'VIBE_RUNNER':'runtime/viberun/target/release/viberun'}
run('mutate-relative-paths',['bash','scripts/vibe_mutate_test.sh'],env)
verify();receipt=json.loads((out/'images/build.json').read_text());assert receipt['compiler_sha256']==base.sha(compiler)
for p,h in receipt['artifacts'].items():assert base.sha(out/'images'/p)==h
base.write(out/'validation.json',{'complete':True,'steps':steps,'producer':producer,'receipt':receipt,'source_authority_sha256':base.sha(out/'source-authority.json'),'scope':'Functional integration on main9f93 with own unchanged optimization. Original403d performance data are historical; no retiming/relabeling. Full imported fingerprint graph runs GC after3515, unlike historical403d controls. Required release-check/normalhooks/CI still follow.'})
print('Fresh integration and allmatchingreceipts passed.',flush=True)
