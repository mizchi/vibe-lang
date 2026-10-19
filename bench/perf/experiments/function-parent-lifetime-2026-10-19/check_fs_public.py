"""Current source matching public process images; no phase/thread performance claim."""
import hashlib,json,subprocess,sys,os
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';out=work/'public-fs-v1';out.mkdir(exist_ok=False)
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
build=json.loads((work/'filesystem-preparation/build-result.json').read_text());assert build['complete']
assert json.loads((work/'oracles-fs-v1/result.json').read_text())['complete']
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
compiler=work/'filesystem-preparation/generation/stage2.wasm';assert sha(compiler)==build['compiler_sha256']
report={'complete':False,'source_sha256':build['source_sha256'],'compiler_sha256':sha(compiler),'scope':'Shared filesystem and typed preparation current process worker compatibility; no Store release or native thread result.','steps':[]}
def verify():assert all(sha(root/p)==h for p,h in build['source_sha256'].items())
def write():base.write(out/'result.json',report)
for label,cmd in [('images',['bash','scripts/build_taskgroup_functions.sh',str(compiler),str(out/'images')]),('public-tests',['python3','scripts/test_taskgroup_functions.py',str(compiler),str(out/'images')])]:
 verify()
 with (out/(label+'.log')).open('w') as f:
  p=subprocess.Popen(cmd,cwd=root,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':label,'pid':p.pid,'start_ticks':Path(f'/proc/{p.pid}/stat').read_text().split()[21]};write();code=p.wait()
 report.pop('live_step');report['steps'].append({'name':label,'exit':code,'log_sha256':sha(out/(label+'.log'))});write();print(label,code,flush=True)
 if code:raise SystemExit(code)
 verify()
receipt=json.loads((out/'images/build.json').read_text());assert receipt['compiler_sha256']==sha(compiler)
assert receipt['runner_sha256']==sha(root/'runtime/viberun/target/release/viberun')
for name,h in receipt['artifacts'].items():assert sha(out/'images'/name)==h
report.update(complete=True,receipt=receipt,receipt_sha256=sha(out/'images/build.json'));write()
