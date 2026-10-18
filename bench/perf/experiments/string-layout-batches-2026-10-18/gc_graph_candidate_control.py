"""Retain a separate full-import GC control after all performance work ends."""
import json,subprocess,sys
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
assert json.loads((lab/'worker-replay/profiles.json').read_text())['complete']
authority=json.loads((lab/'comparison-authority.json').read_text())
for p,h in authority['sources'].items():assert base.sha(root/p)==h
compiler=lab/'candidate-generation/stage2.wasm';base.fixed_point(compiler.parent)
test='lib/@vibe/compiler/tests/codegen_layout_fingerprint_test.vibe'
out=lab/'candidate-full-graph-gc.wasm'
env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':'1','VIBE_BACKEND':'gc','VIBE_BUILD_CACHE_DIR':str(lab/'candidate-full-graph-gc-cache')}
native=root/'runtime/viberun/target/release/viberun'
cmd=[str(native),str(compiler),test,str(out),'__no_entry__']
with (lab/'candidate-full-graph-gc-compile.log').open('w') as log:r=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=180)
assert r.returncode==0 and out.is_file(),'full-graph control must compile first'
cmd=['bash','scripts/run_wasm_vibe_host_runner.sh','--invoke','_start',str(out)]
with (lab/'candidate-full-graph-gc-run.log').open('w') as log:r=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=60)
text=(lab/'candidate-full-graph-gc-run.log').read_text()
assert r.returncode!=0 and 'data segment' in text and 'out of bounds' in text,text
base.write(lab/'gc-graph-candidate-control.json',{'compile_exit':0,'run_exit':r.returncode,'compiler_sha256':base.sha(compiler),'test_sha256':base.sha(root/test),'module_sha256':base.sha(out),'run_log_sha256':base.sha(lab/'candidate-full-graph-gc-run.log'),'scope':'Separate full-import graph GC control after uninstrumented matrix/replays and CPU profiles. Expanded current test compiles then fails at active data-segment instantiation,matching original403d control; isolated exact-function algorithm probe passes.3512 remains open.'})
for p,h in authority['sources'].items():assert base.sha(root/p)==h
print('Candidate full-importGC failure independently retained; no full-graphGC pass claimed.',flush=True)
