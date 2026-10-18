"""Prepare source-bound current-main engines and frozen input corpus; no timings claimed."""
import hashlib,json,shutil,subprocess,sys,time
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()=='403d735929db48325c23252630725a0d16b5ab69'
assert not subprocess.check_output(['git','status','--porcelain'],text=True).strip()
steps=[];sources=None
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 if sources:
  for name,digest in sources.items():assert sha(root/name)==digest,('maintained engine source changed',name)
def run(name,command):
 verify();started=time.monotonic()
 with (lab/(name+'.log')).open('w') as log:result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
 steps.append({'name':name,'command':command,'exit':result.returncode,'wall_s':time.monotonic()-started})
 base.write(lab/'setup-validation.json',{'complete':False,'steps':steps})
 print(name,result.returncode,round(steps[-1]['wall_s'],3),flush=True);assert result.returncode==0,steps[-1]
 verify()
run('generated',['bash','scripts/ensure_generated.sh'])
paths=[Path(p) for p in subprocess.check_output(['git','ls-files','--','lib','scripts','runtime/viberun'],text=True).splitlines()]
generated=[Path('lib/@vibe/compiler')/name for name in ['compiler_sources_bundle.vibe','cli_adapter_bundle.vibe','selfbuild_runtime_entry_bundle.vibe','_cli_adapter_module_source.vibe','cache/codegen_fingerprint.vibe']]
paths+=generated;sources={str(p):sha(root/p) for p in sorted(paths) if (root/p).is_file()}
base.write(lab/'engine-source-authority.json',{'commit':'403d735929db48325c23252630725a0d16b5ab69','tree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip(),'sources':sources})
run('native-build',['bash','scripts/ensure_viberun.sh'])
run('generation',['bash','scripts/generations.sh','build','--stage3','--out-dir',str(lab/'generation')])
producer=base.fixed_point(lab/'generation');compiler=lab/'generation/stage2.wasm'
run('function-images',['bash','scripts/build_taskgroup_functions.sh',str(compiler),str(lab/'images')])
receipt=json.loads((lab/'images/build.json').read_text());native=root/'runtime/viberun/target/release/viberun'
assert receipt['compiler_sha256']==sha(compiler)==producer['stages']['stage2']['sha256']
assert receipt['runner_sha256']==sha(native) and receipt['context_format']==7 and receipt['job_format']==2 and receipt['function_abi']=='bump-core-tagged-callbacks-2'
for name,digest in receipt['artifacts'].items():assert sha(lab/'images'/name)==digest
workspace=lab/'baseline';base.freeze(workspace,'403d735929db48325c23252630725a0d16b5ab69');meta=json.loads((workspace/'workspace.json').read_text());corpus=workspace/'corpus'
for p in generated:
 (corpus/p).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/p,corpus/p)
base.verify_source(corpus,meta)
(corpus/'perf-smoke.vibe').write_text('fn main() -> Int { 7 - 3 }\n')
for lane in ['o0','a0']:
 out=workspace/'engines'/lane;out.mkdir(parents=True)
 shutil.copy2(compiler,out/'compiler.wasm');shutil.copy2(native,out/'viberun')
out=workspace/'engines/images';out.mkdir()
for name in [*receipt['artifacts'],'build.json']:shutil.copy2(lab/'images'/name,out/name)
for name in ['taskgroup_functions_frontend.mjs','taskgroup_lowering_frontend.mjs']:shutil.copy2(root/'scripts'/name,out/name)
inputs={str(p.relative_to(corpus)):sha(p) for p in sorted((corpus/'lib').rglob('*')) if p.is_file()}
engines={str(p.relative_to(workspace)):sha(p) for p in sorted((workspace/'engines').rglob('*')) if p.is_file()}
base.write(workspace/'engine-authority.json',{'source_commit':meta['source_commit'],'source_tree':meta['source_tree'],'archive_sha256':meta['archive_sha256'],'producer':producer,'receipt':receipt,'files':engines,'input_sha256':inputs,'generated_inputs':{str(p):sha(corpus/p) for p in generated},'engine_source_authority_sha256':sha(lab/'engine-source-authority.json'),'scope':'Clean403d73592 engines and same-revision frozen filesystem compiler/CLI source, including current generated inputs. TargetRC1 function-worker route; not an actual bootstrap walltime measurement. Separate ordinary, same-driver serial and process1/2/4 with ordinaryA/A controls required before diagnostics.'})
verify();base.verify_source(corpus,meta)
base.write(lab/'setup-validation.json',{'complete':True,'steps':steps,'receipt':receipt,'compiler_sha256':sha(compiler),'runner_source_stamp':(root/'runtime/viberun/target/release/.viberun_srchash').read_text().strip()})
print('Current-main compiler fixpoint, native runner, three matching images and frozen corpus staged.',flush=True)
