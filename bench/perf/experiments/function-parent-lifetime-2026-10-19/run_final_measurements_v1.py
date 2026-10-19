"""One serial controller for final fixed-source measurements; no source mutation."""
import json,subprocess,sys,time
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation'
assert json.loads((work/'oracles-after-format-v1/result.json').read_text())['complete']
proof=json.loads((work/'after-format-validation-v1/result.json').read_text());assert proof['complete'] and proof['source_unchanged']
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
out=work/'final-measurements-v1';out.mkdir()
steps=['compare_phase_lifetime_v2.py','summarize_phase_lifetime_v2.py','profile_phase_lifetime_v2.py','compare_actual_bootstrap_v2.py']
for name in steps:compile((work/name).read_text(),str(work/name),'exec')
report={'complete':False,'driver_sha256':base.sha(__file__),'step_driver_sha256':{name:base.sha(work/name) for name in steps},'source_sha256':proof['source_sha256'],'head':proof['head'],'steps':[],'scope':'Sequential final-source144filesystem comparison, aggregation, separateCPU/guestmemory diagnostic replays, then24actualRC0serial bootstrap controls. No concurrent builds/tests/profiles or source/index edits. The controller performs no source mutations. Timing numbers live only in their source-bound measurement reports, not controller durations.'}
def write():base.write(out/'result.json',report)
def verify():
 assert base.sha(__file__)==report['driver_sha256']
 assert all(base.sha(work/name)==h for name,h in report['step_driver_sha256'].items())
 assert all(base.sha(root/name)==h for name,h in report['source_sha256'].items()),'Source changed while final measurements ran'
 assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==report['head']
verify();write()
for name in steps:
 verify()
 with (out/(name+'.log')).open('w') as f:
  child=subprocess.Popen(['python3','-u',str(work/name)],cwd=root,env=base.clean_env(root),stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':name,'pid':child.pid,'start_ticks':Path(f'/proc/{child.pid}/stat').read_text().split()[21],'log':str(out/(name+'.log'))};write();code=child.wait()
 report.pop('live_step');report['steps'].append({'name':name,'exit':code,'log_sha256':base.sha(out/(name+'.log'))});write();verify();print(name,code,flush=True)
 if code:
  print((out/(name+'.log')).read_text()[-6500:],flush=True);raise SystemExit(code)
verify();report['complete']=True;write();print('Final source-bound filesystem timings, separate diagnostics and actual serial-bootstrap controls all complete.',flush=True)
