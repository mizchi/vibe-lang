"""Strict completed-matrix aggregation; never promote RC1 observations as bootstrap."""
from pathlib import Path
import json,statistics
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';directory=work/'phase-lifetime-comparison-v1'
p=directory/'measurement.json';data=json.loads(p.read_text());assert data['verified_complete'] and data['aa_guest_memory_exact'] and len(data['samples'])==144
rows=data['samples'];output=directory/'summary.json';assert not output.exists()
def stats(values):
 assert len(values)==3
 return {'n':3,'median':statistics.median(values),'min':min(values),'max':max(values),'values':values}
def select(subject,temp,mode,lane):
 selected=sorted([r for r in rows if r['subject']==subject and r['temperature']==temp and r['mode']==mode and r['lane']==lane],key=lambda r:r['round']);assert [r['round'] for r in selected]==[0,1,2]
 return selected
def metrics(selected):
 result={'wall_s':stats([r['wall_s'] for r in selected]),'simultaneous_tree_rss_mib':stats([r['process_tree_peak_rss_bytes']/2**20 for r in selected])}
 if selected[0]['mode']=='p4':
  result['phase_tree_rss_mib']={name:stats([r['peaks'][name]['rss_bytes']/2**20 for r in selected]) for name in ['before_workers','workers_alive','after_workers']}
 if selected[0]['phase_guest_memory']:
  result['guest_memory']={name:stats([r['phase_guest_memory'][0][name] for r in selected]) for name in ['heap_base','heap_peak','allocated','committed']}
 if 'phases' in selected[0]:
  # Raw diagnostic scopes differ by ABI: never divide the old callback and
  # new returning-phase timers and call that a measured pass speedup.
  result['raw_phase_fields']={name:stats([r['phases'][name] for r in selected]) for name in ['prepare_ms','worker_ms','finalize_ms','shared_context_bytes','peak_queued_input_bytes'] if all(name in r['phases'] for r in selected)}
  if selected[0]['lane']=='b0':
   result['raw_phase_fields'].update({name:stats([r['phases'][name] for r in selected]) for name in ['completed_product_bytes','prepare_heap_end','prepare_memory_bytes','finish_heap_end','finish_memory_bytes']})
 return result
def percent(before,after):return 100*(after/before-1)
report={'source':'8bed6e9e61bb178af06cdb7fbae62d9bc19c6c7e + archived implementation overlay','scope':'144unprofiled fixed filesystem targetRC1 process-backend observations. Actual RC0 bootstrap integration/native threads/default gate remain unproven. Raw phase clocks differ by ABI; CPU ancestors cannot be converted to these whole-wall deltas. Process-tree RSS is a simultaneous sum sampled20ms; shared mappings may double-count. Phase bounds come from observed worker command intervals, not exact native event timestamps.','subjects':{},'whole_bootstrap_promotion':{'evaluated':False,'reason':'Actual targetRC0 worker integration is not present; filesystem corpus numbers cannot establish the stage/install or actual pipeline ceilings.'},'noise_rule':'Median whole-wall differences below5% are inconclusive. Report all three observations, min/max and independent A/A controls; no single-pair speedup claim.'}
for subject in ['compiler','split-cli']:
 temperatures={};report['subjects'][subject]=temperatures
 for temperature in ['cold','warm']:
  groups={f'{mode}-{lane}':metrics(select(subject,temperature,mode,lane)) for mode in ['o0','s0','p1','p2','p4'] for lane in (['a0','b0','aa','bb'] if mode=='o0' else ['a0','b0'])}
  comparisons={}
  for mode in ['o0','s0','p1','p2','p4']:
   a=groups[mode+'-a0'];b=groups[mode+'-b0'];wall=percent(a['wall_s']['median'],b['wall_s']['median']);rss=percent(a['simultaneous_tree_rss_mib']['median'],b['simultaneous_tree_rss_mib']['median'])
   row={'wall_percent':wall,'rss_percent':rss,'wall_conclusion':'inconclusive under5% threshold' if abs(wall)<5 else ('lower median' if wall<0 else 'higher median')}
   if mode=='p4':row['phase_rss_percent']={name:percent(a['phase_tree_rss_mib'][name]['median'],b['phase_tree_rss_mib'][name]['median']) for name in a['phase_tree_rss_mib']}
   comparisons[mode]=row
  aa={}
  for a,b in [('a0','aa'),('b0','bb')]:
   before=groups['o0-'+a];after=groups['o0-'+b]
   assert all(before['guest_memory'][name]['values']==after['guest_memory'][name]['values'] for name in before['guest_memory'])
   aa[a+'-'+b]={'wall_percent':percent(before['wall_s']['median'],after['wall_s']['median']),'guest_counters_exact':True}
  ordinary=groups['o0-b0'];serial=groups['s0-b0'];four=groups['p4-b0'];one=groups['p1-b0']
  relative_gates={'scope':'Only relative filesystem gates; this is not actual-bootstrap/default promotion.',
   'p4_at_least5pct_faster_than_ordinary':four['wall_s']['median']<=ordinary['wall_s']['median']*.95,
   'p4_at_least5pct_faster_than_same_image_serial':four['wall_s']['median']<=serial['wall_s']['median']*.95,
   'p4_rss_at_most110pct_ordinary':four['simultaneous_tree_rss_mib']['median']<=ordinary['simultaneous_tree_rss_mib']['median']*1.1,
   'p4_absolute_rss_below4096mib':max(four['simultaneous_tree_rss_mib']['values'])<=4096,
   'forced_one_wall_at_most105pct_same_image_serial':one['wall_s']['median']<=serial['wall_s']['median']*1.05,
   'forced_one_rss_at_most105pct_same_image_serial':one['simultaneous_tree_rss_mib']['median']<=serial['simultaneous_tree_rss_mib']['median']*1.05}
  temperatures[temperature]={'groups':groups,'before_after':comparisons,'aa':aa,'relative_gates':relative_gates}
  print(subject,temperature,'P4 wall',round(groups['p4-a0']['wall_s']['median'],3),'->',round(four['wall_s']['median'],3),'s; RSS',round(groups['p4-a0']['simultaneous_tree_rss_mib']['median'],1),'->',round(four['simultaneous_tree_rss_mib']['median'],1),'MiB',flush=True)
output.write_text(json.dumps(report,indent=2)+'\n')
print('Whole-matrix medians, min/max, all24 A/A pairs and relative gates recorded; actual-bootstrap promotion not evaluated.',flush=True)
