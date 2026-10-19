"""Read-only required-format preflight once the observation controls finish."""
import json,subprocess,sys
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation'
assert json.loads((work/'serial-observation-comparison-v1/measurement.json').read_text())['verified_complete']
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
out=work/'format-check-v1';out.mkdir()
authority=json.loads((work/'phase-lifetime-comparison-v1/authority.json').read_text())
sources=authority['candidate_source_sha256'];assert all(base.sha(root/p)==h for p,h in sources.items())
paths=set(subprocess.check_output(['git','diff','--name-only','HEAD','--','lib/'],text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard','--','lib/'],text=True).splitlines())
paths=sorted(p for p in paths if p.endswith(('.vibe','.vpkg')))
(out/'files.txt').write_text('\n'.join(paths)+'\n')
report={'complete':False,'read_only':True,'source_sha256':sources,'files':paths};base.write(out/'result.json',report)
with (out/'run.log').open('w') as f:
 child=subprocess.Popen(['bash','scripts/run_vibe_fmt_batch.sh','check','1'],cwd=root,env=base.clean_env(root),stdin=subprocess.PIPE,stdout=f,stderr=subprocess.STDOUT,text=True)
 report['live_step']={'pid':child.pid,'start_ticks':Path(f'/proc/{child.pid}/stat').read_text().split()[21]};base.write(out/'result.json',report)
 child.communicate('\n'.join(paths)+'\n');code=child.returncode
report.pop('live_step');report['exit']=code
statuses={}
for line in (out/'run.log').read_text().splitlines():
 fields=line.split('\t')
 if len(fields)>=2 and fields[0] in ['OK','DIFF','ERROR','REFUSED']:statuses[fields[1]]=fields[0]
assert all(base.sha(root/p)==h for p,h in sources.items()),'Read-only format check changed sources'
report.update(complete=True,source_unchanged=True,statuses=statuses,needs_formatting=[p for p in paths if statuses.get(p)=='DIFF']);base.write(out/'result.json',report)
assert code==0 and set(statuses)==set(paths) and not any(v in ['ERROR','REFUSED'] for v in statuses.values()),(out/'run.log').read_text()[-7000:]
print('Read-only formatter checked',len(paths),'files;',len(report['needs_formatting']),'need formatting.',flush=True)
for path in report['needs_formatting']:print(path,flush=True)
