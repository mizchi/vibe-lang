"""144 unprofiled paired RC1 filesystem builds; actual RC0 bootstrap is separate."""
import hashlib,json,platform,shutil,subprocess,sys,time
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation'
proof_dir=work/'after-format-validation-v1';proof=json.loads((proof_dir/'result.json').read_text());assert proof['complete'] and proof['source_unchanged']
control=json.loads((work/'measurement-control-v1/result.json').read_text());assert control['complete'] and control['source_unchanged']
assert json.loads((work/'oracles-after-format-v1/result.json').read_text())['complete']
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
out=work/'phase-lifetime-comparison-v2';out.mkdir()
corpus=work/'after-main-validation-v1/reference';assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=corpus,text=True).strip()==proof['head']
assert subprocess.check_output(['git','status','--porcelain'],cwd=corpus,text=True).strip()=='?? perf-smoke.vibe'
assert (corpus/'perf-smoke.vibe').read_text()=='fn main() -> Int { 7 - 3 }\n'
(corpus/'perf-smoke.vibe').write_text('fn main() -> Int { 7 - 3 }\n')
engines=out/'engines'
for lane,origin in [('a0','reference'),('b0','candidate'),('aa','reference'),('bb','candidate')]:
 dest=engines/lane;dest.mkdir(parents=True)
 for name in ['compile.wasm','worker.wasm','coordinator.component.wasm','build.json']:
  shutil.copy2((work/'after-main-validation-v1/reference-images' if origin=='reference' else proof_dir/'candidate-images')/name,dest/name)
 shutil.copy2((work/'after-main-validation-v1/reference-generation' if origin=='reference' else proof_dir/'candidate-generation')/'stage2.wasm',dest/'compiler.wasm')
 shutil.copy2((corpus if origin=='reference' else root)/'runtime/viberun/target/release/viberun',dest/'viberun')
 for name in ['taskgroup_functions_frontend.mjs','taskgroup_lowering_frontend.mjs']:
  shutil.copy2((corpus if origin=='reference' else root)/'scripts'/name,dest/name)
 receipt=base.function_image_receipt(dest)
 assert receipt['compiler_sha256']==base.sha(dest/'compiler.wasm')==proof[origin]['compiler_sha256']
 assert receipt['runner_sha256']==base.sha(dest/'viberun')==proof['runners'][origin]
 for name,h in receipt['artifacts'].items():assert base.sha(dest/name)==h
sources=dict(proof['source_sha256'])
# Measurement-only edits made after producer verification are explicit. They
# cannot relabel a compiler producer, runner, library or public frontend.
pending=json.loads((work/'pending-measurement/authority.json').read_text())
for p,identity in pending.items():
 assert p.startswith('bench/perf/') and sources[p]==identity['after'] and base.sha(root/p)==identity['after']
 sources[p]=identity['after']
files={str(p.relative_to(out)):base.sha(p) for p in sorted(engines.rglob('*')) if p.is_file()}
inputs={str(p.relative_to(corpus)):base.sha(p) for p in sorted((corpus/'lib').rglob('*')) if p.is_file()}
inputs['perf-smoke.vibe']=base.sha(corpus/'perf-smoke.vibe')
authority={'head':proof['head'],'producer_proof_sha256':base.sha(proof_dir/'result.json'),'measurement_control_proof_sha256':base.sha(work/'measurement-control-v1/result.json'),'files':files,'input_sha256':inputs,'candidate_source_sha256':sources,'driver_sha256':base.sha(__file__),'measurement_helper_sha256':base.sha(base.__file__),'measurement_only_edits':pending,'machine':{'kernel':platform.release(),'cpus':__import__('os').cpu_count(),'memory_bytes':__import__('os').sysconf('SC_PHYS_PAGES')*__import__('os').sysconf('SC_PAGE_SIZE'),'cpu':next(l.split(':',1)[1].strip() for l in Path('/proc/cpuinfo').read_text().splitlines() if l.startswith('model name'))},'format_transition':proof['format_changes'],'scope':'Final formatted candidate; original v1trial retained independently. Fixed same-current-main filesystem corpus, emitted targetRC1, process backend. Baseline ABI2 live parent; candidate ABI3 dropped preparation and fresh finisher. Matching source-bound producers/runners/receipts. Not actual targetRC0 bootstrap, native-thread or default promotion evidence.'}
base.write(out/'authority.json',authority)
def verify():
 assert base.sha(__file__)==authority['driver_sha256'] and base.sha(base.__file__)==authority['measurement_helper_sha256']
 assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==proof['head']
 for p,h in sources.items():assert base.sha(root/p)==h,('candidate source changed',p)
 for p,h in files.items():assert base.sha(out/p)==h,('image changed',p)
 for p,h in inputs.items():assert base.sha(corpus/p)==h,('input changed',p)
verify()
rows=[];expected={}
report={'verified_complete':False,'expected_samples':144,'rounds':3,'authority_sha256':base.sha(out/'authority.json'),'samples':rows,'artifacts':expected,'protocol':'Unprofiled serial orchestration only. Ordinary before/after, both A/A controls, same-image serial, public process1/2/4. N3 cold/warm per configuration. Forward/reverse/forward paired order, equal-length engine/cache/output paths. Private parsed-source cache each round/lane/mode, cold then warm newprocess; other compiler caches off. Native code primed on another input; OS page cache warm. Public frontend includes receipt/image verification, source preparation, transport, child startup, validation/replay and publication. Native serial configuration prepared before command outside timing; no fallback. VIBE_MEM reports phase end guest counters without periodic guest sampling; RSS sum simultaneous process tree every20ms, shared mappings may double-count. p4 raw per-sample command identities retained; public frontend suppresses successful child stderr, so exact parent/worker guest counters require separate diagnostic replays. Candidate public traces retain both phase frontiers/reserved sizes. No concurrent builds/tests/CPU profiles and no edits during measurement.'}
def write():base.write(out/'measurement.json',report)
def command(lane,mode,source,entry,private):
 image=engines/lane;native=image/'viberun'
 env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_FS_COMPILE':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(private/'cache'),'VIBE_NATIVE_CACHE_DIR':str(out/'native-cache')}
 if mode=='o0':cmd=[str(native),str(image/'compiler.wasm'),source,str(private/'out.wasm'),entry]
 elif mode=='s0':
  cmd=base.function_parent_command(image,native)
  env.update(VIBE_LOWERING_MODE='serial',VIBE_LOWERING_INPUT=source,VIBE_LOWERING_ENTRY=entry,VIBE_LOWERING_OUTPUT=str(private/'out.wasm'))
  if base.function_image_receipt(image)['function_abi']=='bump-core-returning-phases-3':
   config=private/'service.json'
   base.write(config,{'version':1,'worker':str(image/'worker.wasm'),'runner':str(native),'coordinator':str(image/'coordinator.component.wasm'),'cwd':str(corpus),'directory':str(private),'jobs':1})
   env.update(VIBE_FUNCTION_JOBS='1',VIBE_LOWERING_DIRECTORY=str(private),VIBE_LOWERING_SERVICE_CONFIG=str(config))
 else:
  cmd=['node',str(image/'taskgroup_functions_frontend.mjs'),str(image/'compiler.wasm'),source,str(private/'out.wasm'),entry,mode[1],str(corpus),str(image),str(native)]
  env['VIBE_FUNCTION_TRACE_OUT']=str(private/'trace.json')
 return cmd,env
write()
for lane in ['a0','b0','aa','bb']:
 for mode in ['o0','s0','p1']:
  private=out/f'prime-{lane}-{mode}';private.mkdir();cmd,env=command(lane,mode,'perf-smoke.vibe','main',private)
  result=base.measure(cmd,corpus,env,private/'logs');assert (private/'out.wasm').is_file()
  print('prime',lane,mode,'ok',flush=True)
original=base.snapshot
for subject,prefix,source,entry in [('compiler','c','lib/@vibe/compiler/tests/codegen_lexer_test.vibe','__no_entry__'),('split-cli','l','lib/@vibe/cli/entry.vibe','cli_main')]:
 for rnd in range(3):
  verify()
  modes=['o0','s0','p1','p2','p4']
  for mode in modes if rnd%2==0 else list(reversed(modes)):
   lanes=['a0','b0','aa','bb'] if mode=='o0' else ['a0','b0']
   for lane in lanes if rnd%2==0 else list(reversed(lanes)):
    private=out/f'{prefix}{rnd}-{mode}-{lane}';private.mkdir()
    for temperature in ['cold','warm']:
     (private/'out.wasm').unlink(missing_ok=True);(private/'trace.json').unlink(missing_ok=True)
     samples=[];start=time.monotonic()
     def snapshot(pid):
      values=original(pid);current={}
      for child,(_,rss,cpu) in values.items():
       try:cmdline=Path(f'/proc/{child}/cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
       except OSError:cmdline=''
       current[child]={'command':cmdline,'rss_bytes':rss,'cpu_s':cpu}
      samples.append({'s':time.monotonic()-start,'processes':current});return values
     cmd,env=command(lane,mode,source,entry,private)
     if mode=='p4':base.snapshot=snapshot
     try:result=base.measure(cmd,corpus,env,private/temperature)
     finally:base.snapshot=original
     digest=base.sha(private/'out.wasm');assert expected.setdefault(subject,digest)==digest,(subject,rnd,mode,lane,temperature,'output differs')
     memory=[base.guest_memory(line) for line in (private/temperature/'run.log').read_text().splitlines() if line.startswith('vibe::mem ')]
     assert len(memory)==(0 if mode.startswith('p') else 1),('unexpected guest observations',lane,mode,len(memory))
     result['phase_guest_memory']=memory
     if mode.startswith('p'):
      trace=json.loads((private/'trace.json').read_text());assert trace['workers']==int(mode[1])==trace['range_jobs'] and trace['preparation_count']==1 and trace['context_serialization_count']==1
      if lane=='b0':assert trace['preparation_store_dropped_before_workers'] and trace['finisher_store_fresh'] and trace['finisher_source_reads']==0 and 0<trace['completed_product_bytes']<=256*1024*1024
      result['phases']=trace;shutil.copy2(private/'trace.json',private/temperature/'trace.json')
     if mode=='p4':
      active=[i for i,s in enumerate(samples) if any(p['command'].endswith('/worker.wasm ') for p in s['processes'].values())];assert active
      groups={'before_workers':samples[:active[0]],'workers_alive':samples[active[0]:active[-1]+1],'after_workers':samples[active[-1]+1:]};peaks={}
      for name,values in groups.items():
       assert values;peak=max(values,key=lambda s:sum(p['rss_bytes'] for p in s['processes'].values()))
       peaks[name]={'s':peak['s'],'rss_bytes':sum(p['rss_bytes'] for p in peak['processes'].values()),'processes':peak['processes']}
      result['peaks']=peaks;base.write(private/temperature/'timeline.json',{'samples':samples,'scope':'20ms command-derived bounds, not exact native phase transition timestamps. All values are simultaneous process-tree observations.'})
     result.update(subject=subject,round=rnd,mode=mode,lane=lane,temperature=temperature,artifact_sha256=digest,raw_directory=str((private/temperature).relative_to(out)))
     rows.append(result);write();print(subject,rnd,mode,lane,temperature,round(result['wall_s'],3),round(result['process_tree_peak_rss_bytes']/2**20,1),flush=True)
assert len(rows)==144
for subject in ['compiler','split-cli']:
 for rnd in range(3):
  for temperature in ['cold','warm']:
   for pair in [('a0','aa'),('b0','bb')]:
    selected=[r for r in rows if r['subject']==subject and r['round']==rnd and r['temperature']==temperature and r['mode']=='o0' and r['lane'] in pair]
    assert len(selected)==2 and selected[0]['phase_guest_memory']==selected[1]['phase_guest_memory'],('A/A differs',subject,rnd,temperature,pair)
verify();report.update(verified_complete=True,aa_guest_memory_exact=True);write()
print('All144 artifacts and24 A/A guest-memory pairs agree. Whole-build promotion remains separately evaluated.',flush=True)
