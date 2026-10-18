"""Reproduction helper added after measurement: original full-import GC control."""
import argparse,json,subprocess,sys
from pathlib import Path
root=Path.cwd();sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace',type=Path,required=True)
parser.add_argument('--out',type=Path,required=True)
args=parser.parse_args();w=args.workspace.resolve();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
assert not (out/'gc-graph-control.json').exists(),'refuse to replace an existing control'
corpus=w/'corpus';meta=json.loads((w/'workspace.json').read_text())
compiler=w/'engines/o0/compiler.wasm';native=w/'engines/o0/viberun'
authority=json.loads((w/'engine-authority.json').read_text())
def verify_inputs():
 base.verify_source(corpus,meta)
 for name,digest in authority['input_sha256'].items():
  assert base.sha(corpus/name)==digest,('frozen input changed',name)
verify_inputs()
assert base.sha(compiler)==authority['receipt']['compiler_sha256']
assert base.sha(native)==authority['receipt']['runner_sha256']
test='lib/@vibe/compiler/tests/codegen_layout_fingerprint_test.vibe';wasm=out/'baseline-original-gc.wasm'
env=base.clean_env(corpus)|{'VIBE_FS_COMPILE':'1','VIBE_RC':'1','VIBE_BACKEND':'gc','VIBE_BUILD_CACHE_DIR':str(out/'baseline-gc-cache')}
command=[str(native),str(compiler),test,str(wasm),'__no_entry__']
with (out/'baseline-original-gc-compile.log').open('w') as log:r=subprocess.run(command,cwd=corpus,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=180)
assert r.returncode==0 and wasm.is_file(),'control must compile'
command=['bash',str(corpus/'scripts/run_wasm_vibe_host_runner.sh'),'--invoke','_start',str(wasm)]
with (out/'baseline-original-gc-run.log').open('w') as log:r=subprocess.run(command,cwd=corpus,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=60)
text=(out/'baseline-original-gc-run.log').read_text()
assert r.returncode!=0 and 'data segment' in text and 'out of bounds' in text,text
verify_inputs()
base.write(out/'gc-graph-control.json',{'original_graph_run_exit':r.returncode,'original_test_sha256':base.sha(corpus/test),'compiler_sha256':base.sha(compiler),'baseline_output_sha256':base.sha(wasm),'run_log_sha256':base.sha(out/'baseline-original-gc-run.log'),'scope':'Fresh reproduction of the unchanged frozen403d full-importGC graph, separate from historical timing samples; no source modifications.'})
print('Original full-importGC control reproduced.',flush=True)
