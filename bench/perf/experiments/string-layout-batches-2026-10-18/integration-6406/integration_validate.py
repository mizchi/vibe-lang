"""Fresh source-bound integration after main6406; not historical performance data."""
import json,os,subprocess,sys,time
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent;out=lab/'integration-6406';out.mkdir()
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()=='6406ca9f6df1081a5ef40244b2fc6fe3d892474a'
assert subprocess.run(['git','diff','--quiet']).returncode==0
paths=[Path(p) for p in subprocess.check_output(['git','ls-files','--','lib','scripts','runtime/viberun'],text=True).splitlines()]
sources={str(p):base.sha(p) for p in paths if p.is_file()};generated=None;steps=[]
def verify():
 for p,h in sources.items():assert base.sha(root/p)==h,('integration source changed',p)
 if generated:
  for p,h in generated.items():assert base.sha(root/p)==h,('generated input changed',p)
def run(name,command,env=None):
 verify();started=time.monotonic()
 with (out/(name+'.log')).open('w') as log:r=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=1200)
 steps.append({'name':name,'command':command,'exit':r.returncode,'wall_s':time.monotonic()-started})
 base.write(out/'validation.json',{'complete':False,'steps':steps})
 print(name,r.returncode,round(steps[-1]['wall_s'],3),flush=True);assert r.returncode==0,steps[-1];verify()
run('generated',['bash','scripts/ensure_generated.sh'])
run('native',['bash','scripts/ensure_viberun.sh'])
run('generation',['bash','scripts/generations.sh','build','--stage3','--out-dir',str(out/'generation')])
producer=base.fixed_point(out/'generation');compiler=out/'generation/stage2.wasm'
generated={str(Path('lib/@vibe/compiler')/p):base.sha(root/'lib/@vibe/compiler'/p) for p in ['compiler_sources_bundle.vibe','cli_adapter_bundle.vibe','selfbuild_runtime_entry_bundle.vibe','_cli_adapter_module_source.vibe','cache/codegen_fingerprint.vibe']}
base.write(out/'source-authority.json',{'base_commit':'6406ca9f6df1081a5ef40244b2fc6fe3d892474a','staged_tree':subprocess.check_output(['git','write-tree'],text=True).strip(),'sources':sources,'generated':generated,'producer':producer,'scope':'Fresh functional integration after3514 and mutation-gate path normalization, not a new performance measurement. Historical132AB+48replays/78profiles remain bound to403d overlay.'})
run('function-images',['bash','scripts/build_taskgroup_functions.sh',str(compiler),str(out/'images')])
for mode in ['0','1','shadow']:
 env=base.clean_env(root)|{'VIBE_TEST_CLI_WASM':str(compiler),'VIBE_RC':mode,'VIBE_BUILD_CACHE_DIR':str(out/('fingerprint-cache-'+mode))}
 run('fingerprint-'+mode,['bash','scripts/vibe_test.sh','lib/@vibe/compiler/tests/codegen_layout_fingerprint_test.vibe'],env)
env=base.clean_env(root)|{'VIBE_TEST_CLI_WASM':str(compiler),'VIBE_RC':'1','VIBE_BUILD_CACHE_DIR':str(out/'regression-cache')}
run('cache-and-runtime-regressions',['bash','scripts/vibe_test.sh','lib/@vibe/compiler/tests/codegen_body_cache_persist_test.vibe','lib/@vibe/compiler/tests/body_cache_edit_classes_test.vibe','lib/@vibe/compiler/tests/codegen_body_cache_test.vibe','lib/@vibe/compiler/tests/runtime_size_trim_test.vibe'],env)
run('public-functions',['python3','scripts/test_taskgroup_functions.py',str(compiler),str(out/'images')])
env=base.clean_env(root)|{'VIBE_CLI_WASM':str(compiler.relative_to(root)),'VIBE_RUNNER':'runtime/viberun/target/release/viberun'}
run('mutate-relative-paths',['bash','scripts/vibe_mutate_test.sh'],env)
verify();receipt=json.loads((out/'images/build.json').read_text())
assert receipt['compiler_sha256']==base.sha(compiler)
for p,h in receipt['artifacts'].items():assert base.sha(out/'images'/p)==h
base.write(out/'validation.json',{'complete':True,'steps':steps,'producer':producer,'receipt':receipt,'source_authority_sha256':base.sha(out/'source-authority.json'),'scope':'Functional integration on6406 with owned overlay; codegenbytes include3514 and are compared only against contemporaneous ordinary references. Historical performance records remain unchanged; required finalrelease-check/normalhooks/hostedCI/review still follow.'})
print('All fresh current-main integration checks and matching receipts pass.',flush=True)
