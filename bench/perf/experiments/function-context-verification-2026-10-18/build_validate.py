import hashlib,json,subprocess,time
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
record=json.loads((lab/'build-authority.json').read_text());steps=[]
compiler=root/'_build/function-worker-parent-memory-3483-20261018/decoder-candidate/generation/stage2.wasm'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 for p,h in record['sources'].items():assert sha(root/p)==h,('source changed during validation',p)
def run(name,command):
 verify();started=time.monotonic()
 with (lab/(name+'.log')).open('w') as out:result=subprocess.run(command,stdout=out,stderr=subprocess.STDOUT)
 step={'name':name,'command':list(map(str,command)),'exit':result.returncode,'wall_s':time.monotonic()-started};steps.append(step)
 (lab/'validation.json').write_text(json.dumps({'complete':False,'steps':steps},indent=2)+'\n')
 print(name,result.returncode,round(step['wall_s'],3),flush=True);assert result.returncode==0,step
 verify()
run('generated-check',['bash','scripts/ensure_generated.sh','--check'])
run('rust-tests-final',['cargo','test','--release','--manifest-path','runtime/viberun/Cargo.toml','lowering_service::tests'])
run('native-build',['bash','scripts/ensure_viberun.sh'])
run('function-images',['bash','scripts/build_taskgroup_functions.sh',str(compiler),str(lab/'candidate-images')])
before=json.loads((lab/'before-authority.json').read_text())
receipt=json.loads((lab/'candidate-images/build.json').read_text())
assert receipt['compiler_sha256']==sha(compiler)==before['images']['compiler_sha256']
assert receipt['artifacts']==before['images']['artifacts']
assert receipt['runner_sha256']==sha(root/'runtime/viberun/target/release/viberun')!=before['images']['runner_sha256']
run('public-functions',['python3','scripts/test_taskgroup_functions.py',str(compiler),str(lab/'candidate-images')])
run('lowering-images',['bash','scripts/build_taskgroup_lowering.sh',str(compiler),str(lab/'lowering-images')])
run('public-lowering',['python3','scripts/test_taskgroup_lowering.py',str(compiler),str(lab/'lowering-images')])
verify()
(lab/'validation.json').write_text(json.dumps({'complete':True,'steps':steps,'receipt':receipt,'runner_source_stamp':(root/'runtime/viberun/target/release/.viberun_srchash').read_text().strip()},indent=2)+'\n')
print('All source-bound validation complete; guest images unchanged, native runner receipt updated.',flush=True)
