"""Separate real parent/worker guest diagnostics, only after unprofiled timings."""
import json,shutil,subprocess,sys
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';comparison=work/'phase-lifetime-comparison-v2'
matrix=json.loads((comparison/'measurement.json').read_text());assert matrix['verified_complete'] and len(matrix['samples'])==144
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base;import selfbuild_profiles as profiles
authority=json.loads((comparison/'authority.json').read_text());corpus=work/'after-main-validation-v1/reference'
out=work/'phase-lifetime-diagnostics-v2';out.mkdir()
report={'complete':False,'comparison_sha256':base.sha(comparison/'measurement.json'),'driver_sha256':base.sha(__file__),'parent_runs':[],'worker_runs':[],'scope':'Diagnostics only, after the144unprofiled runs. Warmup then3guest CPU profiles per parent/worker. Parent Store frontiers, reserved bytes and allocation volume are distinct from the simultaneously measured process-tree RSS. Inclusive CPU ancestors overlap; host/idle costs are not inferred from guest samples. No diagnostic walltime is a promotion sample.'}
def write():base.write(out/'result.json',report)
def verify():
 for name,h in authority['candidate_source_sha256'].items():assert base.sha(root/name)==h,('source changed',name)
 for name,h in authority['files'].items():assert base.sha(comparison/name)==h,('engine changed',name)
 for name,h in authority['input_sha256'].items():assert base.sha(corpus/name)==h,('input changed',name)
 assert base.sha(__file__)==report['driver_sha256']
def run(label,cmd,env):
 directory=out/label;directory.mkdir()
 with (directory/'run.log').open('w') as f:
  child=subprocess.Popen([str(v) for v in cmd],cwd=corpus,env=env,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':label,'pid':child.pid,'start_ticks':Path(f'/proc/{child.pid}/stat').read_text().split()[21]};write();code=child.wait()
 report.pop('live_step');write();assert code==0,(label,(directory/'run.log').read_text()[-6000:])
 return directory/'run.log'
verify();write()
wrapper=out/'capture-runner.py';wrapper.write_text(profiles.CAPTURE);wrapper.chmod(0o755)
for subject,source,entry in [('compiler','lib/@vibe/compiler/tests/codegen_lexer_test.vibe','__no_entry__'),('split-cli','lib/@vibe/cli/entry.vibe','cli_main')]:
 for lane in ['a0','b0']:
  verify();images=comparison/'engines'/lane;runner=images/'viberun'
  for index in range(4):
   private=out/f'{subject}-{lane}-{index}';private.mkdir()
   config=private/'service.json'
   base.write(config,{'version':1,'worker':str(images/'worker.wasm'),'coordinator':str(images/'coordinator.component.wasm'),'runner':str(wrapper if index==0 else runner),'cwd':str(corpus),'directory':str(private),'jobs':4})
   env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(out/f'{subject}-{lane}-cache'),'VIBE_NATIVE_CACHE_DIR':str(comparison/'native-cache'),'VIBE_LOWERING_INPUT':source,'VIBE_LOWERING_OUTPUT':str(private/'out.wasm'),'VIBE_LOWERING_ENTRY':entry,'VIBE_LOWERING_DIRECTORY':str(private),'VIBE_LOWERING_MODE':'single','VIBE_FUNCTION_JOBS':'4','VIBE_LOWERING_SERVICE_CONFIG':str(config),'SELFBUILD_NATIVE_RUNNER':str(runner),'SELFBUILD_CAPTURE':str(out/f'capture-{subject}-{lane}')}
   if index:env['VIBE_GUEST_PROFILE']=str(private/'cpu.json')
   log=run(f'parent-{subject}-{lane}-{index}',base.function_parent_command(images,runner),env)
   assert base.sha(private/'out.wasm')==matrix['artifacts'][subject]
   memory=[base.guest_memory(line) for line in log.read_text().splitlines() if line.startswith('vibe::mem ')]
   assert len(memory)==(2 if lane=='b0' else 1)
   row={'subject':subject,'lane':lane,'index':index,'guest_memory':memory,'artifact_sha256':base.sha(private/'out.wasm'),'log_sha256':base.sha(log)}
   if index:
    paths=([private/'cpu.json'] if lane=='a0' else [private/'cpu.json.function_phase_prepare',private/'cpu.json.function_phase_finish'])
    row['profiles']={str(p.relative_to(out)):base.sha(p) for p in paths}
    for p in paths:assert isinstance(json.loads(p.read_text()),dict) and p.stat().st_size>64
   report['parent_runs'].append(row);write();print('parent',subject,lane,index,'ok',flush=True)
  capture_files=list((out/f'capture-{subject}-{lane}').glob('*/capture.json'));assert len(capture_files)==1
  capture=capture_files[0];record=json.loads(capture.read_text())
  for slot,queue in enumerate(record['queues']):
   if not queue:continue
   private=out/f'worker-{subject}-{lane}-{slot}';private.mkdir()
   listing=private/'jobs.list';listing.write_text('\n'.join(str(capture.parent/r['name']) for r in queue))
   for index in range(4):
    env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_MEM':'1','VIBE_NATIVE_CACHE_DIR':str(comparison/'native-cache'),'VIBE_LOWERING_WORKER_LIST':str(listing),'VIBE_LOWERING_SHARED_CONTEXT':str(capture.parent/'shared.context')}
    if index:env['VIBE_GUEST_PROFILE']=str(private/f'cpu-{index}.json')
    log=run(f'worker-{subject}-{lane}-{slot}-{index}',[runner,images/'worker.wasm'],env)
    for row in queue:assert base.sha(capture.parent/(row['name']+'.product'))==row['product_sha256']
    memory=[base.guest_memory(line) for line in log.read_text().splitlines() if line.startswith('vibe::mem ')];assert len(memory)==1
    row={'subject':subject,'lane':lane,'slot':slot,'index':index,'guest_memory':memory[0],'log_sha256':base.sha(log)}
    if index:
     path=private/f'cpu-{index}.json';assert isinstance(json.loads(path.read_text()),dict)
     row['profile']={'path':str(path.relative_to(out)),'sha256':base.sha(path)}
    report['worker_runs'].append(row);write();print('worker',subject,lane,slot,index,'ok',flush=True)
verify();report.update(complete=True,source_unchanged=True);write()
print('Separate guest diagnostics match every measured artifact and captured worker product.',flush=True)
