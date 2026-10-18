"""Sequential, source-bound build and regression evidence for issue3483."""
import json, os, subprocess, sys, shutil
from pathlib import Path
sys.path.insert(0,str(Path.cwd()/'bench/perf'))
import selfbuild_baseline as base
repo=Path.cwd();out=Path(__file__).resolve().parent
paths=subprocess.check_output(['git','ls-files','-c','-o','--exclude-standard','-z','--','lib','scripts','runtime/viberun']).split(b'\0')
paths={Path(os.fsdecode(p)) for p in paths if p}
paths.update(Path('lib/@vibe/compiler')/name for name in ['compiler_sources_bundle.vibe','cli_adapter_bundle.vibe','selfbuild_runtime_entry_bundle.vibe','_cli_adapter_module_source.vibe','cache/codegen_fingerprint.vibe'])
def sources():return {str(p):base.sha(repo/p) for p in sorted(paths) if (repo/p).is_file()}
before=sources();patch=subprocess.check_output(['git','diff','--binary','HEAD'])
(out/'source-overlay.patch').write_bytes(patch)
untracked=subprocess.check_output(['git','ls-files','-o','--exclude-standard','-z','--','lib','scripts']).split(b'\0')
for name in untracked:
 if name:
  rel=Path(os.fsdecode(name));dest=out/'untracked'/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(repo/rel,dest)
record={'base_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'sources':before,'patch_sha256':base.sha(out/'source-overlay.patch'),'steps':[],'complete':False}
base.write(out/'build-authority.json',record)
env=base.clean_env(repo)
def step(label,command,extra=None,expected=0):
 assert before==sources(),'source changed before '+label
 base.write(out/'stage.json',{'stage':label,'command':command})
 with (out/(label+'.log')).open('w') as log:
  result=subprocess.run(command,cwd=repo,env=env | (extra or {}),stdout=log,stderr=subprocess.STDOUT)
 assert before==sources(),'source changed during '+label
 record['steps'].append({'step':label,'returncode':result.returncode,'expected':expected,'log_sha256':base.sha(out/(label+'.log'))});base.write(out/'build-authority.json',record)
 if result.returncode!=expected:raise RuntimeError((label,result.returncode,'see log'))
 return (out/(label+'.log')).read_text()
gen=out/'generation'
step('generation',['bash','scripts/generations.sh','build','--out-dir',str(gen),'--stage3','--skip-run-validation'])
record['generation']=base.fixed_point(gen);compiler=str(gen/'stage2.wasm');record['compiler_sha256']=base.sha(compiler)
files=['lib/@vibe/lowering_worker/linear/body_reader_test.vibe','lib/@vibe/codegen/transport/body_string_copy_test.vibe','lib/@vibe/codegen/transport/body_codec_test.vibe','lib/@vibe/lowering_worker/linear/string_reader_test.vibe']
for rc in ['0','1','shadow']:
 step('unit-'+rc,['bash','scripts/vibe_test.sh',*files],{'VIBE_TEST_CLI_WASM':compiler,'VIBE_RC':rc})
 # Execute the actual newly compiled ownership/allocation oracle on native too.
 wasm=repo/'_build/vibe_test/lib_@vibe_lowering_worker_linear_body_reader_test.wasm'
 assert wasm.exists(),str(wasm)
 step('native-unit-'+rc,[str(repo/'runtime/viberun/target/release/viberun'),str(wasm)])
step('portable-gc',['bash','scripts/vibe_test.sh','lib/@vibe/codegen/transport/body_codec_test.vibe','lib/@vibe/codegen/transport/body_string_copy_test.vibe'],{'VIBE_TEST_CLI_WASM':compiler,'VIBE_TEST_BACKEND':'gc'})
# Replace only the optimized adapter in a separate source copy, preserving
# all test inputs/oracles. The long-name allocation budget must detect it.
negative=out/'slow-reference';negative.mkdir()
source=repo/'lib/@vibe/lowering_worker/linear/string_reader.vibe'
s=source.read_text().replace('CodegenBodyCache, codegen_body_cache_from_bytes_with_string_copy','CodegenBodyCache, codegen_body_cache_from_bytes, codegen_body_cache_from_bytes_with_string_copy')
old='codegen_body_cache_from_bytes_with_string_copy(bytes, copy_string_span)'
assert s.count(old)==1
s=s.replace(old,'codegen_body_cache_from_bytes(bytes)')
(negative/'string_reader.vibe').write_text(s)
shutil.copy2(repo/files[0],negative/'body_reader_test.vibe')
text=step('negative-slow-reference',['bash','scripts/vibe_test.sh',str(negative/'body_reader_test.vibe')],{'VIBE_TEST_CLI_WASM':compiler,'VIBE_RC':'0'},1)
assert 'long names have bounded copy allocation' in text and 'FAIL (compile)' not in text,text
record['negative_control']='Only adapter replaced by portable byte-wise reference; same ownership/truncation tests compile/run, long-name allocation oracle fails.'
step('images',['bash','scripts/build_taskgroup_functions.sh',compiler,str(out/'images')])
record['image_receipt']=json.loads((out/'images/build.json').read_text())
assert record['image_receipt']['compiler_sha256']==record['compiler_sha256']
assert record['image_receipt']['runner_sha256']==base.sha(out.parent/'baseline/engines/o0/viberun')
step('public-workers',['python3','scripts/test_taskgroup_functions.py',compiler,str(out/'images')])
assert patch==subprocess.check_output(['git','diff','--binary','HEAD'])
record['complete']=True;base.write(out/'build-authority.json',record)
base.write(out/'stage.json',{'stage':'complete'})
print('Fixpoint, source authority, unit/native/GC/negative controls and public-worker regressions complete.',flush=True)
