"""Rebuild the final formatted source; keep original v1 trials independently bound."""
import json,subprocess,sys,tarfile
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';out=work/'after-format-validation-v1';out.mkdir()
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
old=json.loads((work/'after-main-validation-v1/result.json').read_text());authority=json.loads((work/'phase-lifetime-comparison-v1/authority.json').read_text());fmt=json.loads((work/'format-apply-v1/authority-after.json').read_text());assert old['complete'] and fmt['complete']
assert json.loads((work/'serial-observation-comparison-v1/measurement.json').read_text())['verified_complete']
sources=dict(authority['candidate_source_sha256'])
for name,row in fmt['changes'].items():assert sources[name]==row['before'];sources[name]=row['after']
assert all(base.sha(root/name)==h for name,h in sources.items())
for name,h in authority['input_sha256'].items():assert base.sha(work/'after-main-validation-v1/reference'/name)==h
with tarfile.open(out/'candidate-sources.tar.gz','w:gz') as archive:
 for name in sorted(sources):archive.add(root/name,arcname=name)
report={'complete':False,'head':old['head'],'source_sha256':sources,'source_archive_sha256':base.sha(out/'candidate-sources.tar.gz'),'driver_sha256':base.sha(__file__),'format_changes':fmt['changes'],'format_patch_sha256':base.sha(work/'format-apply-v1/format.patch'),'reference':old['reference'],'reference_proof_sha256':base.sha(work/'after-main-validation-v1/result.json'),'runners':old['runners'],'steps':[],'scope':'Final formatted candidate producer/fixpoint/images and functional verification. Baseline8bed producer and frozen corpus unchanged and reused with original proof. Original v1performance/profile records remain bound to pre-format source; final performance comparison will be recorded separately.'}
(reference_link:=out/'reference').symlink_to(work/'after-main-validation-v1/reference',target_is_directory=True)
def write():base.write(out/'result.json',report)
def verify():
 assert all(base.sha(root/name)==h for name,h in sources.items()),'Source changed during verification'
 assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==report['head']
 assert base.sha(__file__)==report['driver_sha256']
def run(label,cmd):
 verify()
 with (out/(label+'.log')).open('w') as f:
  child=subprocess.Popen([str(v) for v in cmd],cwd=root,env=base.clean_env(root)|{'VIBE_BUILD_CACHE_DIR':str(out/'build-cache'),'VIBE_NATIVE_CACHE_DIR':str(out/'native-cache')},stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':label,'pid':child.pid,'start_ticks':Path(f'/proc/{child.pid}/stat').read_text().split()[21]};write();code=child.wait()
 report.pop('live_step');report['steps'].append({'name':label,'exit':code,'log_sha256':base.sha(out/(label+'.log'))});write();verify();print(label,code,flush=True)
 if code:raise RuntimeError(label+': '+(out/(label+'.log')).read_text()[-6000:])
write()
run('native-authority',['bash','scripts/ensure_viberun.sh','--check'])
assert base.sha(root/'runtime/viberun/target/release/viberun')==report['runners']['candidate']
run('format-check',['bash','-c','bash scripts/run_vibe_fmt_batch.sh check 1 < "$1"','format-check',work/'format-check-v1/files.txt'])
lines=(out/'format-check.log').read_text().splitlines();statuses=[line.split('\t') for line in lines if line.startswith(('OK\t','DIFF\t','ERROR\t','REFUSED\t'))];assert len(statuses)==28 and all(row[0]=='OK' for row in statuses)
run('generated',['bash','scripts/ensure_generated.sh'])
run('candidate-generation',['bash','scripts/generations.sh','build','--stage3','--out-dir',out/'candidate-generation'])
receipt=base.fixed_point(out/'candidate-generation');compiler=out/'candidate-generation/stage2.wasm'
report['candidate']={'stage2_equals_stage3':True,'compiler_sha256':base.sha(compiler),'generation_sha256':base.sha(out/'candidate-generation/generation.json'),'source':receipt['source']};write()
run('candidate-images',['bash','scripts/build_taskgroup_functions.sh',compiler,out/'candidate-images'])
image_receipt=base.function_image_receipt(out/'candidate-images');assert image_receipt['compiler_sha256']==base.sha(compiler) and image_receipt['runner_sha256']==report['runners']['candidate']
for name,h in image_receipt['artifacts'].items():assert base.sha(out/'candidate-images'/name)==h
report['candidate']['receipt']=image_receipt;write()
run('candidate-public-tests',['python3','scripts/test_taskgroup_functions.py',compiler,out/'candidate-images'])
runner=root/'runtime/viberun/target/release/viberun'
for file in ['linked_section_facts_test.vibe','linked_module_preparation_test.vibe','file_module_preparation_test.vibe','function_assembly_test.vibe']:
 for mode in ['0','1','shadow']:
  label=file+'-'+mode;module=out/(label+'.wasm')
  # Keep the producer/code fixed; only the emitted target policy differs.
  command=['env','VIBE_FS_COMPILE=1','VIBE_RC='+mode,'VIBE_BUILD_CACHE_DIR='+str(out/(label+'-cache')),str(runner),str(compiler),str(root/'lib/@vibe/compiler/tests'/file),str(module),'__no_entry__']
  run('compile-'+label,command);assert module.is_file() and module.stat().st_size>0
  assert not module.with_suffix('.wasm.diag').exists() or module.with_suffix('.wasm.diag').stat().st_size==0
  for host,cmd in [('native',[runner,module]),('node',['bash','scripts/run_wasm_vibe_host_runner.sh',module])]:run('run-'+label+'-'+host,cmd)
verify();report.update(complete=True,source_unchanged=True);write();print('Formatted source, current producer fixpoint/images, public gates and24 foundation runs pass.',flush=True)
