"""24 alternating actual RC0 bootstrap controls after filesystem diagnostics."""
import json,os,shutil,subprocess,sys,time
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';matrix_dir=work/'phase-lifetime-comparison-v1'
matrix=json.loads((matrix_dir/'measurement.json').read_text());diagnostic=json.loads((work/'phase-lifetime-diagnostics-v1/result.json').read_text())
assert matrix['verified_complete'] and len(matrix['samples'])==144 and diagnostic['complete']
assert json.loads((work/'serial-observation-comparison-v1/measurement.json').read_text())['verified_complete']
authority=json.loads((matrix_dir/'authority.json').read_text());head=authority['head'];assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==head
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
out=work/'actual-bootstrap-comparison-v1';out.mkdir()
report={'verified_complete':False,'expected_samples':24,'rounds':3,'head':head,'driver_sha256':base.sha(__file__),'measurement_helper_sha256':base.sha(base.__file__),'matrix_sha256':base.sha(matrix_dir/'measurement.json'),'diagnostic_sha256':base.sha(work/'phase-lifetime-diagnostics-v1/result.json'),'samples':[],'artifacts':{},'setup':[],'protocol':'Actual compiler-through-stage3 and portable-CLI-through-stage2 on exact main8bed and archived candidate overlay, emitted targetRC0. Default serial route on both; NO worker/native-thread selection or promotion claim. Fresh equal-length source checkouts a0/b0; candidate maintained sources+ownednewfiles overlay, seed and corresponding source-bound native binaries/stamps verified normally. Three alternating cold/warm pairs per lane/subject; reverse lane and subject order in alternate rounds. Cold removes only selected isolated merge-tool artifact/stamp and starts fresh guest cache; warm reuses both but regenerates all stage outputs. Each invocation starts fresh Node/guest processes; OS pages warm. Source generation, seed validation/reuse and all stages included. Setup/compiler packaging excluded. Captured compiler outputs differ by source implementation; require each lane artifact identity across temperatures/rounds and every compiler stage2==stage3. Filesystem common-input output identity is proven separately by the144sample comparison.20ms simultaneous process-tree RSS; shared mappings may double-count. No concurrent builds/tests/profiles or source edits.'}
def write():base.write(out/'measurement.json',report)
def verify_root():
 assert base.sha(__file__)==report['driver_sha256'] and base.sha(base.__file__)==report['measurement_helper_sha256']
 assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==head
 for p,h in authority['candidate_source_sha256'].items():assert base.sha(root/p)==h,('candidate root source changed',p)
def setup(label,cmd,cwd,env):
 verify_root()
 with (out/(label+'.log')).open('w') as f:
  child=subprocess.Popen([str(v) for v in cmd],cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'phase':'setup','label':label,'pid':child.pid,'start_ticks':Path(f'/proc/{child.pid}/stat').read_text().split()[21]};write();code=child.wait()
 report.pop('live_step');report['setup'].append({'label':label,'exit':code,'log_sha256':base.sha(out/(label+'.log'))});write();assert code==0,(label,(out/(label+'.log')).read_text()[-6000:]);verify_root()
write();sources={};corpora={}
for lane in ['a0','b0']:
 corpus=out/lane;corpora[lane]=corpus
 setup('clone-'+lane,['git','clone','--shared','--no-checkout',root,corpus],root,base.clean_env(root))
 setup('checkout-'+lane,['git','checkout','--detach',head],corpus,base.clean_env(corpus))
 assert not subprocess.check_output(['git','status','--porcelain'],cwd=corpus,text=True).strip()
 if lane=='b0':
  for name,h in authority['candidate_source_sha256'].items():
   dest=corpus/name;dest.parent.mkdir(parents=True,exist_ok=True);assert base.sha(root/name)==h;shutil.copy2(root/name,dest)
 (corpus/'bootstrap/seed').mkdir(parents=True,exist_ok=True);shutil.copy2(root/'bootstrap/seed/compiler.wasm',corpus/'bootstrap/seed/compiler.wasm')
 assert base.sha(corpus/'bootstrap/seed/compiler.wasm')==json.loads((corpus/'bootstrap/seed.json').read_text())['seed']['artifact']['sha256']
 origin=work/'after-main-validation-v1/reference' if lane=='a0' else root
 target=corpus/'runtime/viberun/target/release';target.mkdir(parents=True)
 for name in ['viberun','.viberun_srchash']:shutil.copy2(origin/'runtime/viberun/target/release'/name,target/name)
 setup('runner-authority-'+lane,['bash','scripts/ensure_viberun.sh','--check'],corpus,base.clean_env(corpus))
 paths=set(subprocess.check_output(['git','ls-files','--','lib/','scripts/','runtime/viberun/','bootstrap/seed.json','Taskfile.pkl'],cwd=corpus,text=True).splitlines())
 if lane=='b0':paths.update(name for name in authority['candidate_source_sha256'] if name.startswith(('lib/','scripts/','runtime/viberun/')))
 sources[lane]={name:base.sha(corpus/name) for name in sorted(paths) if (corpus/name).is_file()}
 report.setdefault('source_authority',{})[lane]={'maintained_source_sha256':sources[lane],'runner_sha256':base.sha(target/'viberun'),'runner_stamp':(target/'.viberun_srchash').read_text().strip(),'seed_sha256':base.sha(corpus/'bootstrap/seed/compiler.wasm')};write()
def verify():
 verify_root()
 for lane,corpus in corpora.items():
  for name,h in sources[lane].items():assert base.sha(corpus/name)==h,('measured maintained source changed',lane,name)
  assert base.sha(corpus/'runtime/viberun/target/release/viberun')==report['source_authority'][lane]['runner_sha256']
verify()
for rnd in range(3):
 for subject in ['compiler','portable-cli'] if rnd%2==0 else ['portable-cli','compiler']:
  for lane in ['a0','b0'] if rnd%2==0 else ['b0','a0']:
   verify();corpus=corpora[lane];private=out/f'r{rnd}-{subject}-{lane}';private.mkdir()
   for temperature in ['cold','warm']:
    if temperature=='cold':
     for suffix in ['', '.fingerprint']:(corpus/('_build/merge_flatten_compiler.wasm'+suffix)).unlink(missing_ok=True)
    directory=private/temperature
    env=base.clean_env(corpus)|{'VIBE_BUILD_CACHE_DIR':str(private/'cache'),'VIBE_NATIVE_CACHE_DIR':str(out/'native-cache'),'VIBE_MEM':'1','VIBE_TRACE_MONOTONIC':'1','VIBE_WASM_MEMORY_STATS':'1','VIBE_BUILD_CLI_WASM_NO_CACHE':'1','VIBE_TRACE_OUT':str(directory/'spans.ndjson')}
    generation=corpus/'_build/measured-generation'
    cmd=['bash','scripts/generations.sh','build','--stage3','--out-dir',str(generation)] if subject=='compiler' else ['bash','scripts/build_cli_wasm.sh','_build/measured-cli.wasm']
    report['live_step']={'phase':'measurement','round':rnd,'subject':subject,'lane':lane,'temperature':temperature,'directory':str(directory)};write()
    result=base.measure(['bash','scripts/trace_span.sh',subject,*cmd],corpus,env,directory)
    report.pop('live_step');write()
    spans=[json.loads(line) for line in (directory/'spans.ndjson').read_text().splitlines()]
    assert spans and all(s.get('clock')=='monotonic' and s['t1']>=s['t0'] and s['rc']==0 for s in spans)
    result['spans']=spans
    if subject=='compiler':receipt=base.fixed_point(generation);digest=receipt['stages']['stage2']['sha256'];producer=generation
    else:
     digest=base.sha(corpus/'_build/measured-cli.wasm');manifests=list((corpus/'_build/selfhost/generations').glob('*/generation.json'));assert len(manifests)==1
     receipt=json.loads(manifests[0].read_text());assert receipt['stages']['stage2']['sha256']==digest;producer=manifests[0].parent
    key=subject+'-'+lane;assert report['artifacts'].setdefault(key,digest)==digest,('unstable bootstrap output',key)
    base.write(directory/'generation.json',receipt);shutil.copy2(producer/'selfhost_bundle_generation.log',directory/'bundle.log')
    if temperature=='cold':
     for suffix in ['', '.seedflat', '.flatten']:shutil.copy2(corpus/('_build/merge_flatten_compiler.log'+suffix),directory/('seed-tool.log'+suffix))
    log=(directory/'run.log').read_text();result['guest_memory_observations']=[base.guest_memory(line) for line in log.splitlines() if line.startswith('vibe::mem ')]
    result.update(subject=subject,lane=lane,round=rnd,temperature=temperature,artifact_sha256=digest,raw_directory=str(directory.relative_to(out)),emitted_target_rc=0,worker_selected=False)
    report['samples'].append(result);write();verify();print(subject,rnd,lane,temperature,round(result['wall_s'],3),round(result['process_tree_peak_rss_bytes']/2**20,1),flush=True)
assert len(report['samples'])==24
verify();report['verified_complete']=True;write();print('All24actualRC0serial pipeline controls retain artifact identity and every compiler fixpoint; no worker/default promotion is claimed.',flush=True)
