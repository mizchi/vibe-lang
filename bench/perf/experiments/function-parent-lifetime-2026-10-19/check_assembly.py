"""Real assembly decoder/replayer tests compiled from the fixed library source."""
import argparse,hashlib,json,os,subprocess,sys,tarfile
from pathlib import Path
root=Path.cwd();lab=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation'
args=argparse.ArgumentParser();args.add_argument('--name',required=True);args.add_argument('--modes',default='1');args=args.parse_args()
out=lab/args.name;out.mkdir()
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
paths=set(subprocess.check_output(['git','diff','--name-only','HEAD','--','lib/'],text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard','lib/'],text=True).splitlines())
sources={p:sha(root/p) for p in sorted(paths)}
compiler=lab/'filesystem-preparation/generation/stage2.wasm';runner=lab.parent/'baseline/engines/o0/viberun'
build=json.loads((lab/'filesystem-preparation/build-result.json').read_text());assert build['complete'] and sha(compiler)==build['compiler_sha256']
with tarfile.open(out/'source.tar.gz','w:gz') as a:
 for p in sorted(paths):a.add(root/p,arcname=p)
report={'complete':False,'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'source_sha256':sources,'compiler_sha256':sha(compiler),'runner_sha256':sha(runner),'source_archive_sha256':sha(out/'source.tar.gz'),'scope':'Actual AST-free assembly packet/replay library code compiled by current source-bound filesystem producer. No Store release, native phase or benchmark claim.','rows':[]}
def write():base.write(out/'result.json',report)
def verify():assert all(sha(root/p)==h for p,h in sources.items()),'Source changed during verification'
def run(name,cmd,env):
 verify()
 with (out/(name+'.log')).open('w') as f:
  p=subprocess.Popen([str(s) for s in cmd],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT);report['live_step']={'name':name,'pid':p.pid,'start_ticks':Path(f'/proc/{p.pid}/stat').read_text().split()[21]};write();code=p.wait()
 report.pop('live_step');write();verify()
 return code
write()
for mode in args.modes.split(','):
 module=out/('test-'+mode+'.wasm');env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':mode,'VIBE_BUILD_CACHE_DIR':str(out/('cache-'+mode)),'VIBE_NATIVE_CACHE_DIR':str(out/'native-cache')}
 code=run('compile-'+mode,[runner,compiler,root/'lib/@vibe/compiler/tests/function_assembly_test.vibe',module,'__no_entry__'],env)
 row={'mode':mode,'compile_exit':code,'hosts':{}};report['rows'].append(row);write()
 diag=module.with_suffix('.wasm.diag')
 if code or not module.exists() or not module.stat().st_size or (diag.exists() and diag.stat().st_size):
  print((out/('compile-'+mode+'.log')).read_text()[-4000:],flush=True)
  if diag.exists():print(diag.read_text()[:5000],flush=True)
  raise SystemExit(code or 1)
 row['module_sha256']=sha(module);write();print('compile',mode,'ok',flush=True)
 for host,cmd in [('native',[runner,module]),('node',['bash','scripts/run_wasm_vibe_host_runner.sh',module])]:
  name=mode+'-'+host;code=run(name,cmd,base.clean_env(root));row['hosts'][host]={'exit':code,'log_sha256':sha(out/(name+'.log'))};write()
  print(host,mode,code,flush=True)
  if code:print((out/(name+'.log')).read_text()[-8000:],flush=True);raise SystemExit(code)
report.update(complete=True,source_unchanged=True);write();print('Real owned assembly packets, canonical products, disposal/mutation/refusal tests pass.',flush=True)
