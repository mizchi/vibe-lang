"""Sequential build, current-main paired oracles, public receipt-bound workers."""
import hashlib,json,subprocess,os,sys
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';result=work/'filesystem-validation.json';assert not result.exists()
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
scripts=['build_fs_preparation.py','check_fs_oracles_v1.py','check_fs_public.py']
authority={s:sha(work/s) for s in scripts}
for s in scripts:compile((work/s).read_text(),str(work/s),'exec')
report={'complete':False,'driver_sha256':authority,'steps':[],'scope':'Shared filesystem preparation intermediate correctness only; no Store release or perf claim.'}
def write():base.write(result,report)
write()
for s in scripts:
 assert all(sha(work/p)==h for p,h in authority.items())
 with (work/(s+'.log')).open('w') as f:
  p=subprocess.Popen(['python3','-u',str(work/s)],cwd=root,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'driver':s,'pid':p.pid,'start_ticks':Path(f'/proc/{p.pid}/stat').read_text().split()[21]};write();code=p.wait()
 report.pop('live_step');report['steps'].append({'driver':s,'exit':code,'log_sha256':sha(work/(s+'.log'))});write();print(s,code,flush=True)
 if code:raise SystemExit(code)
report['complete']=True;write()
