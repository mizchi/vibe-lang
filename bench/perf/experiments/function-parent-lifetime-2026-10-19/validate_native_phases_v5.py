"""Fixed-source actual native lifecycle, matching images and real public CLI."""
import hashlib,json,os,subprocess,sys,tarfile,time
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation';out=work/'native-phases-integration-v5';out.mkdir()
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
spec=['lib/','runtime/viberun/','scripts/build_taskgroup_functions.sh','scripts/taskgroup_lowering_frontend.mjs','scripts/test_taskgroup_functions.py']
paths=set(subprocess.check_output(['git','diff','--name-only','HEAD','--',*spec],text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard','--',*spec],text=True).splitlines())
sources={p:sha(root/p) for p in sorted(paths)}
compiler=work/'filesystem-preparation/generation/stage2.wasm';prior=json.loads((work/'filesystem-preparation/build-result.json').read_text());assert prior['complete'] and sha(compiler)==prior['compiler_sha256']
with tarfile.open(out/'sources.tar.gz','w:gz') as a:
 for p in sorted(paths):a.add(root/p,arcname=p)
report={'complete':False,'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'source_sha256':sources,'source_archive_sha256':sha(out/'sources.tar.gz'),'compiler_sha256':sha(compiler),'scope':'Functional native returning phases and fresh finisher integration. Actual Store drop guarded by lifetime sentinel after existing cleanup; original returned receipt used. No benchmark/promotion/native-thread/default claim.','steps':[]}
def write():base.write(out/'result.json',report)
def verify():
 assert all(sha(root/p)==h for p,h in sources.items()),'Source edited during verification'
 assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==report['head']
def run(label,cmd):
 verify();start=time.monotonic()
 with (out/(label+'.log')).open('w') as f:
  p=subprocess.Popen([str(s) for s in cmd],cwd=root,env=base.clean_env(root),stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':label,'pid':p.pid,'start_ticks':Path(f'/proc/{p.pid}/stat').read_text().split()[21]};write();code=p.wait()
 report.pop('live_step');report['steps'].append({'name':label,'exit':code,'wall_s_diagnostic_only':time.monotonic()-start,'log_sha256':sha(out/(label+'.log'))});write();verify();print(label,code,flush=True)
 if code:print((out/(label+'.log')).read_text()[-9000:],flush=True);raise SystemExit(code)
write()
run('native-unit-all',['cargo','test','--release','--manifest-path','runtime/viberun/Cargo.toml'])
run('native-authority',['bash','scripts/ensure_viberun.sh'])
report['runner_sha256']=sha(root/'runtime/viberun/target/release/viberun');write()
run('images',['bash','scripts/build_taskgroup_functions.sh',compiler,out/'images'])
receipt=json.loads((out/'images/build.json').read_text())
assert receipt['compiler_sha256']==sha(compiler) and receipt['runner_sha256']==report['runner_sha256']
assert receipt['function_abi']=='bump-core-returning-phases-3' and receipt['phase_format']==1 and receipt['assembly_format']==1
for name,h in receipt['artifacts'].items():assert sha(out/'images'/name)==h
report['receipt']=receipt;write()
run('public-tests',['python3','scripts/test_taskgroup_functions.py',compiler,out/'images'])
assert sha(root/'runtime/viberun/target/release/viberun')==report['runner_sha256']
for name,h in receipt['artifacts'].items():assert sha(out/'images'/name)==h
report.update(complete=True,source_unchanged=True);write()
print('Actual native returning preparation/dropStore/freshfinisher plus all public jobs1/2/4 and failure gates pass.',flush=True)
