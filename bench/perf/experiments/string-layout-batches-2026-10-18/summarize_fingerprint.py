"""Summarize only completed authority-bound comparison and diagnostic records."""
import collections,json,statistics,sys
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
r=json.loads((lab/'comparison.json').read_text())
wr=json.loads((lab/'worker-replay/measurement.json').read_text())
pr=json.loads((lab/'worker-replay/profiles.json').read_text())
assert r['verified_complete'] and r['aa_guest_memory_exact'] and len(r['samples'])==132
assert wr['complete'] and len(wr['samples'])==48
assert pr['complete'] and pr['all_products_match'] and len(pr['profiles'])==48
v=json.loads((lab/'candidate-validation.json').read_text());assert v['complete']
steps={x['name']:x for x in v['steps']}
for mode in ['bump','rc']:
 assert steps['compile-fivebyte-'+mode]['exit']==0
 assert steps['reject-fivebyte-'+mode]['exit']!=0
 assert '__test_string layout batches preserve every byte, offset and tail' in (lab/('reject-fivebyte-'+mode+'.log')).read_text()
gc=json.loads((lab/'gc-graph-control.json').read_text())
gc_after=json.loads((lab/'gc-graph-candidate-control.json').read_text())
assert gc['original_graph_run_exit']!=0 and gc_after['compile_exit']==0 and gc_after['run_exit']!=0
assert base.sha(lab/'candidate-full-graph-gc-run.log')==gc_after['run_log_sha256']
assert 'data segment' in (lab/'baseline-original-gc-run.log').read_text()
for q in [131,137]:
 assert (2**31-1)*q**4+255*(q**3+q*q+q+1)<2**60
def stats(xs):
 assert len(xs)==3,len(xs)
 return {'median':statistics.median(xs),'min':min(xs),'max':max(xs),'n':len(xs)}
def pair(rows,metric):
 a=sorted((x for x in rows if x['lane']=='a0'),key=lambda x:x['round'])
 b=sorted((x for x in rows if x['lane']=='b0'),key=lambda x:x['round'])
 assert len(a)==len(b)==3 and [x['round'] for x in a]==[x['round'] for x in b]
 av=[metric(x) for x in a];bv=[metric(x) for x in b]
 am=statistics.median(av);bm=statistics.median(bv)
 return {'before':stats(av),'after':stats(bv),'median_change_percent':(bm/am-1)*100 if am else None,'paired_change_percent':[(y/x-1)*100 if x else None for x,y in zip(av,bv)]}
routes=[]
for subject in ['compiler','split-cli']:
 for mode in ['o0','s0','p1','p2','p4']:
  for temperature in ['cold','warm']:
   rows=[x for x in r['samples'] if x['subject']==subject and x['mode']==mode and x['temperature']==temperature and x['lane']!='aa']
   result={'subject':subject,'mode':mode,'temperature':temperature,'wall_s':pair(rows,lambda x:x['wall_s']),'rss_mib':pair(rows,lambda x:x['process_tree_peak_rss_bytes']/2**20)}
   if mode.startswith('p'):
    result['independent_phase_ms']={key:pair(rows,lambda x,key=key:x['phases'][key]) for key in ['prepare_ms','worker_ms','finalize_ms']}
   if mode=='p4':
    result['sampled_phase_peak_rss_mib']={key:pair(rows,lambda x,key=key:x['peaks'][key]['rss_bytes']/2**20) for key in ['before_workers','workers_alive','after_workers']}
   routes.append(result)
replays=[]
for subject in ['compiler','split-cli']:
 for slot in range(4):
  rows=[x for x in wr['samples'] if x['subject']==subject and x['slot']==slot]
  replays.append({'subject':subject,'slot':slot,'wall_s':pair(rows,lambda x:x['wall_s']),'rss_mib':pair(rows,lambda x:x['process_tree_peak_rss_bytes']/2**20),'guest_memory_before':[x['guest_memory'] for x in rows if x['lane']=='a0'],'guest_memory_after':[x['guest_memory'] for x in rows if x['lane']=='b0']})
profile_groups={}
for row in pr['profiles']:
 path=lab/row['path'];assert base.sha(path)==row['sha256']
 key=(row['subject'],row['lane']);group=profile_groups.setdefault(key,{'self':collections.Counter(),'inclusive':collections.Counter(),'profiles':0,'samples':0})
 group['profiles']+=1
 for t in json.loads(path.read_text())['threads']:
  st=t['stackTable'];ft=t['frameTable'];fn=t['funcTable'];ss=t['stringArray']
  for stack in t['samples']['stack']:
   if stack is None:continue
   names=[]
   while stack is not None:
    names.append(ss[fn['name'][ft['func'][st['frame'][stack]]]]);stack=st['prefix'][stack]
   group['self'][names[0]]+=1;group['inclusive'].update(set(names));group['samples']+=1
profile_summary=[]
for (subject,lane),group in sorted(profile_groups.items()):
 assert group['profiles']==12
 helpers={}
 for target in ['bcc_fp_string','ast_binary_utf8_span_ok','hash_string','str_table_new','read_function_context']:
  helpers[target]={}
  for kind in ['self','inclusive']:
   count=sum(n for name,n in group[kind].items() if name.startswith(target+'_'))
   helpers[target][kind]={'samples':count,'percent':count/group['samples']*100}
 profile_summary.append({'subject':subject,'lane':lane,'profiles':12,'total_guest_samples':group['samples'],'helpers':helpers,'self_top20':group['self'].most_common(20)})
authority=r['authority']
for name,h in authority['sources'].items():assert base.sha(root/name)==h,('measured source changed',name)
for name,h in authority['files'].items():assert base.sha(lab/name)==h,('measured engine changed',name)
out={'verified_complete':True,'source_base':authority['base_commit'],'comparison_sha256':base.sha(lab/'comparison.json'),'replay_measurement_sha256':base.sha(lab/'worker-replay/measurement.json'),'profile_record_sha256':base.sha(lab/'worker-replay/profiles.json'),'routes':routes,'range_replays':replays,'profiles':profile_summary,'qualifications':['Fixed403d filesystem compiler/CLI, emittedRC1/processbackend; not actualtargetRC0bootstrap or native-thread promotion.','20ms simultaneous process-tree RSS can doublecount shared mappings; allocation/frontier/pages are separate.','N3 perconfiguration; changes below prespecified5% remain inconclusive as whole-wall gains.','Independent phase medians and inclusive profile ancestors cannot be added.','Captured range replays are isolated serial costs, not the duration of concurrent worker waves.','GC exact extractedalgorithm passes; original fullcommon_base graph fails identically,tracked3512.']}
base.write(lab/'fingerprint-analysis.json',out)
for row in routes:print(row['subject'],row['mode'],row['temperature'],round(row['wall_s']['before']['median'],3),'->',round(row['wall_s']['after']['median'],3),round(row['wall_s']['median_change_percent'],2),'%')
for row in profile_summary:print('profile',row['subject'],row['lane'],row['helpers']['bcc_fp_string'])
