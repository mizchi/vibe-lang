"""Audit all24completed real serial pipeline controls and recorded budgets."""
from pathlib import Path
import hashlib,json,math,statistics
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';out=work/'actual-bootstrap-comparison-v1'
record=json.loads((out/'measurement.json').read_text());assert record['verified_complete'] and len(record['samples'])==24
result={'scope':'Actual targetRC0 serial compiler-through-stage3 and portableCLI-through-stage2. Baseline main8bed and exact archived formatted candidate overlay. This audits ordinary-route regression/ceilings; no actual worker or native-thread/default promotion claim. No filesystemRC1numbers are substituted.','head':record['head'],'groups':{},'ordinary_regression':{},'every_compiler_fixed_point':True,'compiler_fixpoints_checked':0,'artifact_identity_checked':True}
limits={'compiler':{'cold':208,'warm':166,'rss_mib':3634},'portable-cli':{'cold':170,'warm':129,'rss_mib':3641}}
result.update(raw_record_sha256={},raw_process_records_checked=0,monotonic_span_records_checked=0)
def read_record(path):
 raw=path.read_bytes()
 result['raw_record_sha256'][str(path.relative_to(out))]=hashlib.sha256(raw).hexdigest()
 return raw
for setup in record['setup']:
 assert setup['exit']==0
 path=out/(setup['label']+'.log')
 assert hashlib.sha256(read_record(path)).hexdigest()==setup['log_sha256']
for row in record['samples']:
 assert row['returncode']==0 and math.isfinite(row['wall_s']) and row['wall_s']>0
 assert row['process_tree_peak_rss_bytes']>0 and row['process_tree_peak_processes']>0
 directory=out/row['raw_directory']
 raw=json.loads(read_record(directory/'processes.json'))
 assert raw['processes'] and all(row[key]==value for key,value in raw.items() if key!='processes')
 result['raw_process_records_checked']+=1
 spans=[json.loads(line) for line in read_record(directory/'spans.ndjson').splitlines()]
 assert spans==row['spans'] and spans
 assert all(span['clock']=='monotonic' and span['rc']==0 and span['t1']>=span['t0'] for span in spans)
 assert sum(span['name']==row['subject'] for span in spans)==1
 result['monotonic_span_records_checked']+=1
 manifest=json.loads(read_record(directory/'generation.json'))
 assert manifest['source']['commit']==record['head']
 assert manifest['source']['dirty']==(row['lane']=='b0')
 read_record(directory/'run.log');read_record(directory/'bundle.log')
assert result['raw_process_records_checked']==result['monotonic_span_records_checked']==24
for subject in ['compiler','portable-cli']:
 for temperature in ['cold','warm']:
  groups={}
  for lane in ['a0','b0']:
   rows=sorted([r for r in record['samples'] if r['subject']==subject and r['temperature']==temperature and r['lane']==lane],key=lambda r:r['round']);assert [r['round'] for r in rows]==[0,1,2]
   walls=[r['wall_s'] for r in rows];rss=[r['process_tree_peak_rss_bytes']/2**20 for r in rows]
   for row in rows:
    assert row['emitted_target_rc']==0 and not row['worker_selected']
    assert row['artifact_sha256']==record['artifacts'][subject+'-'+lane]
    manifest=json.loads((out/row['raw_directory']/'generation.json').read_text())
    if subject=='compiler':
     assert manifest['result']['stage3_equal_stage2'] and manifest['stages']['stage2']['sha256']==manifest['stages']['stage3']['sha256']==row['artifact_sha256'];result['compiler_fixpoints_checked']+=1
    else:assert manifest['stages']['stage2']['sha256']==row['artifact_sha256']
   groups[lane]={'n':3,'wall_s':{'median':statistics.median(walls),'min':min(walls),'max':max(walls),'values':walls},'simultaneous_tree_rss_mib':{'median':statistics.median(rss),'min':min(rss),'max':max(rss),'values':rss},'ceiling_checks':{'wall_median_within_recorded_budget':statistics.median(walls)<=limits[subject][temperature],'rss_median_within_recorded_budget':statistics.median(rss)<=limits[subject]['rss_mib'],'all_samples_below4096mib':max(rss)<=4096}}
  key=subject+'-'+temperature;result['groups'][key]=groups
  change=(groups['b0']['wall_s']['median']/groups['a0']['wall_s']['median']-1)*100
  result['ordinary_regression'][key]={'wall_percent':change,'rss_percent':(groups['b0']['simultaneous_tree_rss_mib']['median']/groups['a0']['simultaneous_tree_rss_mib']['median']-1)*100,'wall_interpretation':'inconclusive below5percent' if abs(change)<5 else ('higher median' if change>0 else 'lower median'),'candidate_within105percent_baseline_wall':change<=5}
  print(key,'wall',round(groups['a0']['wall_s']['median'],3),'->',round(groups['b0']['wall_s']['median'],3),'s, RSS',round(groups['a0']['simultaneous_tree_rss_mib']['median'],1),'->',round(groups['b0']['simultaneous_tree_rss_mib']['median'],1),'MiB',flush=True)
assert result['compiler_fixpoints_checked']==12
result['measurement_sha256']=hashlib.sha256((out/'measurement.json').read_bytes()).hexdigest()
path=out/'summary.json';assert not path.exists();path.write_text(json.dumps(result,indent=2)+'\n')
print('All24pipeline artifacts and12compiler fixed points audited. Budget/ordinary regression decisions recorded; native-thread/default promotion remains unproven.',flush=True)
