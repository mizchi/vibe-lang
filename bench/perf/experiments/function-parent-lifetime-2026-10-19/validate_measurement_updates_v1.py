"""Apply prepared helper edits only after fixed-source verification is terminal."""
import json,shutil,subprocess,sys,time
from pathlib import Path
root=Path.cwd();work=root/'_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation'
proof=json.loads((work/'after-main-validation-v1/result.json').read_text());assert proof['complete'] and proof['source_unchanged']
paired=json.loads((work/'oracles-main8bed-v1/result.json').read_text());assert paired['complete'] and paired['source_unchanged']
pending=work/'pending-measurement';changes=json.loads((pending/'authority.json').read_text())
out=work/'measurement-control-v1';out.mkdir()
import hashlib
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert all(sha(root/p)==h for p,h in proof['source_sha256'].items())
for name,row in changes.items():
 assert name.startswith('bench/perf/') and sha(root/name)==row['before'] and sha(pending/Path(name).name)==row['after']
 shutil.copy2(pending/Path(name).name,root/name)
sources=proof['source_sha256']|{name:row['after'] for name,row in changes.items()}
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
report={'complete':False,'head':proof['head'],'source_sha256':sources,'measurement_only_changes':changes,'producer_proof_sha256':sha(work/'after-main-validation-v1/result.json'),'paired_proof_sha256':sha(work/'oracles-main8bed-v1/result.json'),'steps':[],'scope':'Measurement helpers only changed after source-bound producer and functional verification. Real same-image serial controls exercise actual ABI2/ABI3 images; no unprofiled timing/RSS claim.'}
def write():base.write(out/'result.json',report)
def verify():assert all(sha(root/p)==h for p,h in sources.items())
def run(label,cmd,cwd,env):
 verify()
 with (out/(label+'.log')).open('w') as f:
  child=subprocess.Popen([str(v) for v in cmd],cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
  report['live_step']={'name':label,'pid':child.pid,'start_ticks':Path(f'/proc/{child.pid}/stat').read_text().split()[21]};write();code=child.wait()
 report.pop('live_step');report['steps'].append({'name':label,'exit':code,'log_sha256':sha(out/(label+'.log'))});write();verify();print(label,code,flush=True)
 assert code==0,(label,(out/(label+'.log')).read_text()[-6000:])
write()
run('measurement-tests',['python3','-m','unittest','discover','-s','bench/perf','-p','test_selfbuild_*.py'],root,base.clean_env(root))
expected=None
for lane in ['reference','candidate']:
 workspace=out/lane;corpus=workspace/'corpus';corpus.mkdir(parents=True)
 (corpus/'lib').symlink_to(root/'lib',target_is_directory=True)
 (corpus/'main.vibe').write_text('fn make(n: Int) -> (Int) -> Int { (x) -> x - n }\nfn main() -> Int { let f = make(3); f(100) }\n')
 engines=workspace/'engines';images=engines/'images';shutil.copytree(work/'after-main-validation-v1'/(lane+'-images'),images)
 native=engines/'o0/viberun';native.parent.mkdir()
 shutil.copy2((work/'after-main-validation-v1/reference' if lane=='reference' else root)/'runtime/viberun/target/release/viberun',native)
 compiler=engines/'o0/compiler.wasm';shutil.copy2(work/'after-main-validation-v1'/(lane+'-generation')/'stage2.wasm',compiler)
 ordinary=corpus/'ordinary.wasm'
 env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_FS_COMPILE':'1','VIBE_BUILD_CACHE_DIR':str(corpus/'ordinary-cache'),'VIBE_NATIVE_CACHE_DIR':str(out/'native-cache')}
 run(lane+'-ordinary',[native,compiler,'main.vibe',ordinary,'main'],corpus,env)
 target=corpus/'serial.wasm'
 command,selected=base.matrix_command(workspace,'s0','main.vibe',target,'main',corpus/'serial-cache',corpus/'trace.json')
 selected['VIBE_NATIVE_CACHE_DIR']=str(out/'native-cache')
 run(lane+'-serial',command,corpus,selected)
 assert target.is_file() and target.read_bytes()==ordinary.read_bytes()
 digest=sha(target)
 if expected is None:expected=digest
 assert expected==digest
 run(lane+'-execute',[native,target],corpus,base.clean_env(corpus))
 assert (out/(lane+'-execute.log')).read_text().strip()=='97'
 if lane=='candidate':
  absent=corpus/'init-only.wasm';assert not absent.exists()
  run('init-only-is-not-a-compile',[native,images/'compile.wasm'],corpus,selected|{'VIBE_LOWERING_OUTPUT':str(absent)})
  assert not absent.exists(),'The init-only negative control unexpectedly compiled'
report.update(complete=True,source_unchanged=True,artifact_sha256=expected);write()
print('Measurement unit/refusal tests and actual ABI2/ABI3 serial parity pass; init-only control produces no artifact.',flush=True)
