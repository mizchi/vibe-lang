"""Separate captured-worker A/B controls then guest CPU profiles; no whole-wall claims."""
import json,sys
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
workspace=lab/'baseline';corpus=workspace/'corpus';engines=lab/'engines'
comparison=json.loads((lab/'comparison.json').read_text());assert comparison['verified_complete']
authority=comparison['authority']
def verify():
 for name,h in authority['sources'].items():assert base.sha(root/name)==h,('maintained source changed',name)
 for name,h in authority['files'].items():assert base.sha(lab/name)==h,('engine changed',name)
 for name,h in json.loads((workspace/'engine-authority.json').read_text())['input_sha256'].items():assert base.sha(corpus/name)==h
verify();out=lab/'worker-replay';out.mkdir()
jobs=[];raw={}
for capture in sorted((workspace/'parent-profiles').glob('capture-*/*/capture.json')):
 record=json.loads(capture.read_text());subject=capture.parent.parent.name.removeprefix('capture-')
 raw[str(capture)]=base.sha(capture)
 for slot,queue in enumerate(record['queues']):
  assert queue
  private=out/f'{subject}-{slot}';private.mkdir()
  listing=private/'jobs.list';listing.write_text('\n'.join(str(capture.parent/row['name']) for row in queue))
  raw[str(capture.parent/'shared.context')]=base.sha(capture.parent/'shared.context')
  for row in queue:raw[str(capture.parent/row['name'])]=base.sha(capture.parent/row['name'])
  jobs.append((subject,slot,private,listing,capture,queue))
assert len(jobs)==8
def command(lane,listing,capture,profile=None):
 image=engines/lane
 env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_MEM':'1','VIBE_NATIVE_CACHE_DIR':str(lab/'native-cache'),'VIBE_LOWERING_WORKER_LIST':str(listing),'VIBE_LOWERING_SHARED_CONTEXT':str(capture.parent/'shared.context')}
 if profile:env['VIBE_GUEST_PROFILE']=str(profile)
 return [str(image/'viberun'),str(image/'worker.wasm')],env
def check_products(capture,queue):
 for row in queue:assert base.sha(capture.parent/(row['name']+'.product'))==row['product_sha256'],'captured product changed'
rows=[];profiles=[]
for subject,slot,private,listing,capture,queue in jobs:
 for rnd in range(3):
  for lane in ['a0','b0'] if rnd%2==0 else ['b0','a0']:
   cmd,env=command(lane,listing,capture)
   result=base.measure(cmd,corpus,env,private/f'{rnd}-{lane}')
   check_products(capture,queue)
   result.update(subject=subject,slot=slot,round=rnd,lane=lane,guest_memory=base.guest_memory((private/f'{rnd}-{lane}/run.log').read_text()))
   rows.append(result);base.write(out/'measurement.json',{'complete':False,'samples':rows})
   print(subject,slot,rnd,lane,round(result['wall_s'],4),flush=True)
assert len(rows)==48
verify()
for p,h in raw.items():assert base.sha(Path(p))==h,('captured input changed',p)
base.write(out/'measurement.json',{'complete':True,'samples':rows,'input_sha256':raw,'scope':'48 uninstrumented serial replays of8 actual403d coordinator ranges, alternating same-inputAB, three fresh processes each. NativeJIT already primed by full comparison. No parsed-source cache/temperature in worker-only replay. These are isolated range costs, not4concurrent workers or actual-bootstrap walltime.'})
# Profile after all uninstrumented replay samples, both lanes under the same
# fresh profiler configuration. Do not put sampled walls into A/B results.
import selfbuild_profiles as diagnostic
for subject,slot,private,listing,capture,queue in jobs:
 for rnd in range(3):
  for lane in ['a0','b0'] if rnd%2==0 else ['b0','a0']:
   destination=private/f'profile-{rnd}-{lane}'
   path=private/f'cpu-{rnd}-{lane}.json'
   cmd,env=command(lane,listing,capture,path)
   diagnostic.run(cmd,corpus,env,destination);check_products(capture,queue)
   p=json.loads(path.read_text());assert p['threads']
   profiles.append({'subject':subject,'slot':slot,'round':rnd,'lane':lane,'path':str(path.relative_to(lab)),'sha256':base.sha(path)})
   print(subject,slot,rnd,lane,'profile',flush=True)
assert len(profiles)==48
verify()
for p,h in raw.items():assert base.sha(Path(p))==h
base.write(out/'profiles.json',{'complete':True,'profiles':profiles,'input_sha256':raw,'all_products_match':True,'scope':'48 separate guest CPU profiles of the same captured ranges,3 perlane perslot. Inclusive samples overlap and host work is excluded. No profile wall is an uninstrumented timing.'})
print('All48 replay measurements and48 separate profiles/products verified.',flush=True)
