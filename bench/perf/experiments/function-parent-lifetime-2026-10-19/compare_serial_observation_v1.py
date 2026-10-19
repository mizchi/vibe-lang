"""Isolate changed native observation scope in serial controls, after profiles."""
import json,statistics,sys
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';comparison=work/'phase-lifetime-comparison-v1'
matrix=json.loads((comparison/'measurement.json').read_text());assert matrix['verified_complete']
assert json.loads((work/'phase-lifetime-diagnostics-v1/result.json').read_text())['complete']
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
authority=json.loads((comparison/'authority.json').read_text());corpus=work/'after-main-validation-v1/reference';out=work/'serial-observation-comparison-v1';out.mkdir()
report={'verified_complete':False,'expected_samples':36,'driver_sha256':base.sha(__file__),'matrix_sha256':base.sha(comparison/'measurement.json'),'samples':[],'scope':'Separate36unprofiled serial controls after the144sample matrix and CPU profiles. Same fixed currentmain filesystem source/targetRC1 and exact source-bound images. a0=historicalABI2serial without service-config observation; a1=EXACT SAME ABI2module/runner with native observation config installed; b0=currentABI3serial with required observation config. Only a0/a1 isolate the host scope. a1/b0 still include compiler/image/ABI changes. N3 alternating/reverse lane order, cold/warm private parsed-source caches, equal-length casepaths, shared primed native cache,20ms simultaneousRSS, no other builds/tests/profiles or edits. Artifact hashes must match the fullmatrix. This does not turn either serial control into worker/bootstrap promotion evidence.'}
def write():base.write(out/'measurement.json',report)
def verify():
 assert base.sha(__file__)==report['driver_sha256']
 for name,h in authority['candidate_source_sha256'].items():assert base.sha(root/name)==h
 for name,h in authority['files'].items():assert base.sha(comparison/name)==h
 for name,h in authority['input_sha256'].items():assert base.sha(corpus/name)==h
verify();write()
for subject,prefix,source,entry in [('compiler','c','lib/@vibe/compiler/tests/codegen_lexer_test.vibe','__no_entry__'),('split-cli','l','lib/@vibe/cli/entry.vibe','cli_main')]:
 for rnd in range(3):
  for variant in ['a0','a1','b0'] if rnd%2==0 else ['b0','a1','a0']:
   images=comparison/'engines'/('a0' if variant.startswith('a') else 'b0');runner=images/'viberun'
   private=out/f'{prefix}{rnd}-{variant}';private.mkdir();config=private/'service.json'
   base.write(config,{'version':1,'worker':str(images/'worker.wasm'),'coordinator':str(images/'coordinator.component.wasm'),'runner':str(runner),'cwd':str(corpus),'directory':str(private),'jobs':1})
   for temperature in ['cold','warm']:
    output=private/'out.wasm';output.unlink(missing_ok=True)
    env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_FS_COMPILE':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(private/'cache'),'VIBE_NATIVE_CACHE_DIR':str(comparison/'native-cache'),'VIBE_LOWERING_MODE':'serial','VIBE_LOWERING_INPUT':source,'VIBE_LOWERING_OUTPUT':str(output),'VIBE_LOWERING_ENTRY':entry,'VIBE_HOST_FS_SCOPE_OUT':str(private/'fs-scope.json'),'VIBE_HOST_FS_SCOPE_NONCE':variant}
    if variant!='a0':env.update(VIBE_LOWERING_SERVICE_CONFIG=str(config),VIBE_LOWERING_DIRECTORY=str(private),VIBE_FUNCTION_JOBS='1')
    result=base.measure(base.function_parent_command(images,runner),corpus,env,private/temperature)
    assert base.sha(output)==matrix['artifacts'][subject]
    scope=json.loads((private/'fs-scope.json').read_text());assert scope['nonce']==variant
    base.write(private/temperature/'fs-scope.json',scope)
    result.update(subject=subject,round=rnd,variant=variant,temperature=temperature,artifact_sha256=base.sha(output),guest_memory=base.guest_memory((private/temperature/'run.log').read_text()),host_fs_scope=scope,raw_directory=str((private/temperature).relative_to(out)))
    report['samples'].append(result);write();print(subject,rnd,variant,temperature,round(result['wall_s'],3),round(result['process_tree_peak_rss_bytes']/2**20,1),flush=True)
verify();assert len(report['samples'])==36
summary={}
for subject in ['compiler','split-cli']:
 for temperature in ['cold','warm']:
  medians={}
  for variant in ['a0','a1','b0']:
   selected=[r for r in report['samples'] if r['subject']==subject and r['temperature']==temperature and r['variant']==variant];assert len(selected)==3
   medians[variant]={'wall_s':statistics.median(r['wall_s'] for r in selected),'wall_min_s':min(r['wall_s'] for r in selected),'wall_max_s':max(r['wall_s'] for r in selected),'rss_mib':statistics.median(r['process_tree_peak_rss_bytes']/2**20 for r in selected)}
  summary[subject+'-'+temperature]={'medians':medians,'same_binary_scope_wall_percent':100*(medians['a1']['wall_s']/medians['a0']['wall_s']-1),'observation_matched_before_after_wall_percent':100*(medians['b0']['wall_s']/medians['a1']['wall_s']-1)}
report.update(verified_complete=True,source_unchanged=True,summary=summary);write();print('All36serial outputs match; isolated native observation and scope-matched controls complete.',flush=True)
