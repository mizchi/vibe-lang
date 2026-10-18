"""Archive completed raw evidence, preserving original bytes under gzip."""
import gzip,hashlib,json,sys
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'bench/perf'))
import selfbuild_baseline as base
a=json.loads((lab/'fingerprint-analysis.json').read_text());assert a['verified_complete']
r=json.loads((lab/'comparison.json').read_text());assert r['verified_complete']
p=json.loads((lab/'worker-replay/profiles.json').read_text());assert p['complete']
baseline=lab/'baseline';destination=root/'bench/perf/experiments/string-layout-batches-2026-10-18'
destination.mkdir(parents=True,exist_ok=False)
entries=[]
def save(source,name,compress=False):
 data=source.read_bytes();target=destination/(name+('.gz' if compress else ''))
 target.parent.mkdir(parents=True,exist_ok=True)
 stored=gzip.compress(data,mtime=0) if compress else data
 target.write_bytes(stored)
 assert (gzip.decompress(target.read_bytes()) if compress else target.read_bytes())==data
 entries.append({'path':str(target.relative_to(destination)),'source':str(source.relative_to(lab)),'raw_bytes':len(data),'raw_sha256':hashlib.sha256(data).hexdigest(),'stored_sha256':hashlib.sha256(stored).hexdigest()})
for name in ['setup_baseline.py','matrix.py','diagnostics.py','validate_candidate.py','fingerprint_compare.py','worker_replay_compare.py','gc_graph_candidate_control.py','summarize_fingerprint.py','archive_fingerprint.py']:
 save(lab/name,name)
for name in ['setup-validation.json','diagnostic-authority.json','diagnostics-complete.json','engine-source-authority.json','full-guest-profile-counters.json','hotspot-callers.json','fingerprint-candidate-source.json','comparison-authority.json','comparison.json','candidate-validation.json','candidate-validation-gc-graph-failure.json','gc-graph-control.json','gc-probe-authority.json','gc-graph-candidate-control.json']:
 save(lab/name,'records/'+name,True)
save(lab/'fingerprint-candidate.patch','measured-implementation.patch',True)
save(lab/'fivebyte-overflow-mutant.vibe','negative/fivebyte-overflow-mutant.vibe',True)
save(lab/'gc-fingerprint-probe.vibe','gc-fingerprint-probe.vibe',True)
for name in ['workspace.json','engine-authority.json','matrix/measurement.json','profile-summary.json','memory-summary.json']:
 save(baseline/name,'baseline/'+name,True)
for family in ['generation','candidate-generation']:
 save(lab/family/'generation.json',family+'/generation.json',True)
for family in ['images','candidate-images']:
 save(lab/family/'build.json',family+'/build.json')
for name in ['measurement.json','profiles.json']:
 save(lab/'worker-replay'/name,'worker-replay/'+name,True)
for path in sorted(lab.glob('*.log')):
 save(path,'logs/'+path.name,True)
for path in sorted(baseline.glob('*-profiles/**/cpu*.json')):
 save(path,'profiles/baseline/'+str(path.relative_to(baseline)),True)
for row in p['profiles']:
 path=lab/row['path'];assert base.sha(path)==row['sha256']
 save(path,'profiles/replay/'+str(path.relative_to(lab/'worker-replay')),True)
# Raw logs and sampled phase timelines from every uninstrumented measurement.
before=json.loads((baseline/'matrix/measurement.json').read_text())
for row in before['samples']:
 directory=baseline/row['raw_directory']
 for path in sorted(directory.iterdir()):
  if path.suffix in ['.log','.json']:save(path,'baseline/'+str(path.relative_to(baseline)),True)
for row in r['samples']:
 directory=lab/row['raw_directory']
 for path in sorted(directory.iterdir()):
  if path.suffix in ['.log','.json']:save(path,str(path.relative_to(lab)),True)
for path in sorted((lab/'worker-replay').rglob('*.log')):
 save(path,str(path.relative_to(lab)),True)
# Analysis keeps individual records under their original scope; never pool
# captured-range samples into the whole-compile medians.
analysis=root/'bench/perf/analysis/string-layout-batches-2026-10-18.json'
base.write(analysis,a)
base.write(destination/'manifest.json',{'complete':True,'analysis_sha256':base.sha(analysis),'entries':entries,'scope':'Exact executed drivers, source/producer/engine authorities, uninstrumented results, profiles and negative-control logs. Gzip preserves original whitespace/EOF bytes. Wasm binaries and39MB literal payloads are not committed; verified hashes and frozen source revision reproduce them.'})
print('Archived',len(entries),'entries; verify manifest before commit.',flush=True)
