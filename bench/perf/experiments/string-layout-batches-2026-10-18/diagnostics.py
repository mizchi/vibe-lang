"""Separate current-main parent/worker profiles and captured-wire accounting.

Requires the complete unprofiled72sample matrix. Diagnostic walls never enter
promotion samples. Reuse maintained profilers with a strict current-engine
receipt verifier; no historical-bootstrap receipt is fabricated.
"""
import collections,json,sys
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
import selfbuild_profiles as profiles
workspace=lab/'baseline';corpus=workspace/'corpus'
authority=json.loads((workspace/'engine-authority.json').read_text());meta=json.loads((workspace/'workspace.json').read_text());matrix=json.loads((workspace/'matrix/measurement.json').read_text());sources=json.loads((lab/'engine-source-authority.json').read_text())['sources']
assert matrix['verified_complete'] and matrix['aa_guest_memory_exact'] and len(matrix['samples'])==72
assert matrix['authority_sha256']==base.sha(workspace/'engine-authority.json')
def verify_receipts(path):
 assert Path(path).resolve()==workspace
 base.verify_source(corpus,meta)
 for p,h in authority['files'].items():assert base.sha(workspace/p)==h,('engine changed',p)
 for p,h in authority['input_sha256'].items():assert base.sha(corpus/p)==h,('input changed',p)
 for p,h in sources.items():assert base.sha(root/p)==h,('source changed',p)
 return authority['receipt']
verify_receipts(workspace)
for name in ['compile.wasm','worker.wasm']:
 data=(workspace/'engines/images'/name).read_bytes();assert profiles.without_names(data)!=data,('missing native profile function names',name)
base.image_receipts=verify_receipts
base.write(lab/'diagnostic-authority.json',{'driver_sha256':base.sha(__file__),'maintained_profiles_sha256':base.sha(root/'bench/perf/selfbuild_profiles.py'),'maintained_measurement_sha256':base.sha(root/'bench/perf/selfbuild_baseline.py'),'engine_authority_sha256':base.sha(workspace/'engine-authority.json'),'source_commit':authority['source_commit'],'scope':'Captured real current-main worker inputs/products, parent and worker guest-only CPU profiles, three warm repeats. No instrumented walltime enters72sample baseline or futureAB. Raw literal text remains private; public breakdown includes length/hash only.'})
profiles.parents(workspace);verify_receipts(workspace)
profiles.workers(workspace);verify_receipts(workspace)
profiles.memory(workspace);profiles.summarize(workspace)
# Preserve all guest counters, not only top35/100, so individual string/copy
# helpers can be tested without losing them below the summary cutoff.
full={}
for path in sorted(workspace.glob('*-profiles/**/cpu*.json')):
 p=json.loads(path.read_text());selfs=collections.Counter();inclusive=collections.Counter()
 for thread in p['threads']:
  table=thread['stackTable'];frames=thread['frameTable'];functions=thread['funcTable'];strings=thread['stringArray']
  def name(stack):return strings[functions['name'][frames['func'][table['frame'][stack]]]]
  for stack in thread['samples']['stack']:
   if stack is None:continue
   selfs[name(stack)]+=1;seen=set()
   while stack is not None:seen.add(name(stack));stack=table['prefix'][stack]
   inclusive.update(seen)
 assert sum(selfs.values())>0
 full[str(path.relative_to(workspace))]={'self':dict(selfs),'inclusive':dict(inclusive),'total_samples':sum(selfs.values()),'sha256':base.sha(path)}
assert len(full)==30,len(full)
verify_receipts(workspace)
base.write(lab/'full-guest-profile-counters.json',full)
base.write(lab/'diagnostics-complete.json',{'complete':True,'source_commit':authority['source_commit'],'profile_count':len(full),'authority_sha256':base.sha(lab/'diagnostic-authority.json'),'memory_summary_sha256':base.sha(workspace/'memory-summary.json'),'profile_summary_sha256':base.sha(workspace/'profile-summary.json'),'full_counters_sha256':base.sha(lab/'full-guest-profile-counters.json'),'all_profile_outputs_match_baseline':True,'scope':'Guestepoch inclusive ancestors overlap. Wire payload bytes != live decoded heap != RSS. Host work excluded by guest sampler. Raw process-tree RSS belongs to the separate unprofiled matrix.'})
print('All30 separate current-main profiles, captured products and wire/memory controls verified.',flush=True)
