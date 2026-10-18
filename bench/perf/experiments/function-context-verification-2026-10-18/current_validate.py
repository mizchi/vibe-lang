"""Fresh correctness proof after upstream3502; historical timings stay separate."""
import hashlib,json,subprocess,time
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent;out=lab/'current-main';out.mkdir()
steps=[];sources=None
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 if sources:
  for name,digest in sources.items():assert sha(root/name)==digest,('source changed during current-main validation',name)
def run(name,command):
 verify();start=time.monotonic()
 with (out/(name+'.log')).open('w') as log:result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
 steps.append({'name':name,'command':command,'exit':result.returncode,'wall_s':time.monotonic()-start})
 (out/'validation.json').write_text(json.dumps({'complete':False,'steps':steps},indent=2)+'\n')
 print(name,result.returncode,round(steps[-1]['wall_s'],3),flush=True)
 assert result.returncode==0,steps[-1]
 verify()
run('generated',['bash','scripts/ensure_generated.sh'])
paths=[Path(p) for p in subprocess.check_output(['git','ls-files','--','lib','scripts','runtime/viberun'],text=True).splitlines()]
paths += [Path('lib/@vibe/compiler')/p for p in ['compiler_sources_bundle.vibe','cli_adapter_bundle.vibe','selfbuild_runtime_entry_bundle.vibe','_cli_adapter_module_source.vibe','cache/codegen_fingerprint.vibe']]
sources={str(p):sha(root/p) for p in sorted(paths) if (root/p).is_file()}
base=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip();assert base=='8f999be77878bb2119cbf9c1f2fb944012ed51f1'
(out/'source-authority.json').write_text(json.dumps({'base_commit':base,'sources':sources,'scope':'Post-rebase correctness proof with upstream3502/context7; not a replay/relabel of the historical context6 timing samples.'},indent=2)+'\n')
run('rust-tests',['cargo','test','--release','--manifest-path','runtime/viberun/Cargo.toml','lowering_service::tests'])
run('native-runner',['bash','scripts/ensure_viberun.sh'])
run('generation',['bash','scripts/generations.sh','build','--stage3','--out-dir',str(out/'generation')])
compiler=out/'generation/stage2.wasm';manifest=json.loads((out/'generation/generation.json').read_text());assert manifest['result']['stage3_equal_stage2']
assert compiler.read_bytes()==(out/'generation/stage3.wasm').read_bytes()
assert sha(compiler)==manifest['stages']['stage2']['sha256']==manifest['stages']['stage3']['sha256']
run('function-images',['bash','scripts/build_taskgroup_functions.sh',str(compiler),str(out/'function-images')])
receipt=json.loads((out/'function-images/build.json').read_text());assert receipt['context_format']==7 and receipt['job_format']==2 and receipt['function_abi']=='bump-core-tagged-callbacks-2'
assert receipt['runner_sha256']==sha(root/'runtime/viberun/target/release/viberun') and receipt['compiler_sha256']==sha(compiler)
for name,digest in receipt['artifacts'].items():assert sha(out/'function-images'/name)==digest
run('public-functions',['python3','scripts/test_taskgroup_functions.py',str(compiler),str(out/'function-images')])
run('lowering-images',['bash','scripts/build_taskgroup_lowering.sh',str(compiler),str(out/'lowering-images')])
run('public-lowering',['python3','scripts/test_taskgroup_lowering.py',str(compiler),str(out/'lowering-images')])
verify()
(out/'validation.json').write_text(json.dumps({'complete':True,'base_commit':base,'steps':steps,'compiler_sha256':sha(compiler),'generation':manifest,'function_receipt':receipt,'lowering_receipt':json.loads((out/'lowering-images/build.json').read_text()),'runner_source_stamp':(root/'runtime/viberun/target/release/.viberun_srchash').read_text().strip(),'source_authority_sha256':sha(out/'source-authority.json'),'scope':'Fresh stage2==stage3 and real public suites on context7 after upstream3502. Historical context6 performance observations are not current-main timings.'},indent=2)+'\n')
print('Current-main context7 generation and all source-bound validation complete.',flush=True)
