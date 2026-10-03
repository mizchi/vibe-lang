"""Actual CPU workers, serial product parity, bounded slots and cancellation.

Run after compiling the standalone worker and rebuilding viberun.
This is an experimental functional oracle, not a performance benchmark.
"""
import json, os, selectors, shutil, signal, subprocess, time
from pathlib import Path

import argparse, tempfile
parser=argparse.ArgumentParser(description='Real TaskGroup checker process and checked-product oracle')
parser.add_argument('--compiler',type=Path,required=True)
parser.add_argument('--runner',type=Path,required=True)
parser.add_argument('--worker',type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
out=Path(tempfile.mkdtemp(prefix='checker-taskgroup-',dir=root/'_build'))
runner=args.runner.resolve();compiler=args.compiler.resolve();worker=args.worker.resolve()
assert all(p.is_file() for p in [runner,compiler,worker])
base={k:v for k,v in os.environ.items() if not k.startswith('VIBE_')}
base.update(VIBE_NATIVE_CACHE_DIR=str(out/'native-cache'))

def ticks(pid):
    try:
        fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
        return int(fields[11])+int(fields[12])
    except (FileNotFoundError, ProcessLookupError):
        return None

# Generate fixed TaskGroup programs: the host supplies only prepared snapshots.
# Do not replace real checking with timer futures or canned checker results.
head='import @vibe/concurrent/experimental { TaskGroup, TaskHandle }\nlet run: () -> Int with Async + Exception = () -> {\n TaskGroup::run((g) -> {\n'
for name,ids,count in [('one',[0],1),('two',[0,1],1),('four',list(range(4)),1),('repeat',[0],2),('failure',[0,1],1)]:
    text=head
    for i in ids:
        body=''.join(f'let s{j} = await(host_future_named("checker-{i}"))\nif s{j} != 0 {{ throw("worker failed") }} else ()\n' for j in range(count))
        text+=f'let t{i} = TaskGroup::spawn_suspend(g, () -> Int with Async + Exception {{\n{body}0\n}})\n'
        for j in range(count):
            job=out/f'{name}-job{i}-{j}';job.mkdir()
            manifest=f'version\t1\npath\t{out}/source{i}.vibe\n'
            if name=='failure' and i==1:
                mutated=manifest.replace('version\t1\n','version\t999\n')
                assert mutated!=manifest and 'version\t999\n' in mutated
                manifest=mutated
            (job/'job.txt').write_text(manifest)
            (job/'source.vibe').write_text('\n'.join(f'fn f{k}(x: Int) -> Int {{ x + {k} }}' for k in range(1000))+'\nfn double_id(x: Double) -> Double { x }\nexport fn main() -> Int { let d = double_id(1.5); if d == 1.5 { f999(1) } else { 0 } }\n')
    text+='TaskGroup::pump_all(g)\n'+' + '.join(f'TaskHandle::join(t{i})' for i in ids)+'\n })\n}\n'
    src=out/f'{name}.vibe';src.write_text(text)
    env={**base,'VIBE_FS_COMPILE':'1','VIBE_LIB':str(root/'lib'),'VIBE_PREOPEN_DIR':str(root),
         'VIBE_IMPORT_ABI':'raw','VIBE_RC':'1','VIBE_UNSTABLE':'1','VIBE_RUNNER_EXIT_WITH_RESULT':'1',
         'VIBE_BUILD_CACHE_DIR':str(out/'compile-cache')}
    with (out/f'{name}-compile.log').open('w') as log:
        result=subprocess.run(['bash',str(root/'scripts/run_wasm_vibe_host_runner.sh'),'--invoke','cli_main',str(compiler),str(src),str(out/f'{name}.component.wasm'),'run'],cwd=root,env=env,stdout=log,stderr=log,timeout=120)
    assert result.returncode==0,(name,(out/f'{name}-compile.log').read_text())
    assert (out/f'{name}.component.wasm').read_bytes()[:8]==b'\0asm\x0d\0\x01\0'
    queues=[[str(out/f'{name}-job{i}-{j}') for j in range(count)] if i in ids else [] for i in range(4)]
    (out/f'{name}.json').write_text(json.dumps({'version':1,'wasm':str(worker),'cwd':str(root),'queues':queues}))

# Warm native compilation before the CPU progress oracle. This is a functional
# concurrency check, never a speed claim; jobs still run in fresh processes.
prewarm=out/'prewarm';prewarm.mkdir()
for f in ['job.txt','source.vibe']:shutil.copy2(out/'one-job0-0'/f,prewarm/f)
result=subprocess.run([str(runner),str(worker),str(prewarm),str(prewarm/'worker.out'),'__no_entry__'],cwd=root,env=base,capture_output=True,timeout=30)
assert result.returncode==0,result.stderr.decode()

rows=[]
for name in ['one','two','four','repeat','failure']:
    env={**base,'VIBE_CHECKER_WORKERS':str(out/f'{name}.json'),'VIBE_CHECKER_WORKER_TRACE':'1'}
    proc=subprocess.Popen([str(runner),str(out/f'{name}.component.wasm')],env=env,cwd=root,
                          stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    selector=selectors.DefaultSelector();selector.register(proc.stderr,selectors.EVENT_READ)
    events=[];log=[];previous={};overlap=[];start=time.monotonic();buffer=b''
    while proc.poll() is None:
        if time.monotonic()-start>=30:
            os.killpg(proc.pid, signal.SIGKILL);proc.wait()
            raise AssertionError('coordinator timeout')
        for key,_ in selector.select(.025):
            block=os.read(key.fd,65536)
            if not block: selector.unregister(key.fileobj);continue
            buffer+=block
            while b'\n' in buffer:
                line,buffer=buffer.split(b'\n',1);line=line.decode();log.append(line)
                if line.startswith('vibe-checker-worker '): events.append(json.loads(line.split(' ',1)[1]))
        current={e['pid']:ticks(e['pid']) for e in events if e['event']=='started'}
        progressing=[pid for pid,value in current.items() if value is not None and pid in previous and value>previous[pid]]
        if len(progressing)>1: overlap.append(progressing)
        previous={pid:value for pid,value in current.items() if value is not None}
    tail=buffer+proc.stderr.read()
    for line in tail.decode().splitlines():
        log.append(line)
        if line.startswith('vibe-checker-worker '): events.append(json.loads(line.split(' ',1)[1]))
    stdout=proc.stdout.read().decode();selector.close()
    (out/f'{name}-run.log').write_text(stdout+'\n'+'\n'.join(log)+'\n')
    assert proc.returncode==(1 if name=='failure' else 0),(name,proc.returncode,log)
    if name!='failure': assert stdout.strip()=='0',(name,stdout)
    started=[e for e in events if e['event']=='started']
    assert len(started)==({'one':1,'two':2,'four':4,'repeat':2,'failure':2}[name]),events
    for e in started:
        assert not Path(f"/proc/{e['pid']}").exists(),('unreaped worker',e)
    if name in ['two','four']: assert overlap,('no measured overlapping CPU progress',name,events)
    if name=='failure':
        assert any(e['event'] in ['cancelled','dropped'] for e in events),('no sibling cancellation',events)
        assert not (out/'failure-job0-0/outcome.txt').exists(), 'cancelled job unexpectedly committed'
    else:
        plan=json.loads((out/f'{name}.json').read_text())
        for queue in plan['queues']:
            for job in queue:
                job=Path(job);assert (job/'outcome.txt').read_text().strip()=='ok'
                fp=(job/'fingerprint.out').read_text().strip()
                assert (job/'cache.out').read_text().startswith('checked-worker-cache\t1\t'+fp+'\nversion\t11\n')
                import re
                assert re.search(r'module_typed_lowering_offsets\tcount\t[1-9][0-9]*\n', (job/'cache.out').read_text()), 'missing actual Double lowering rows'
                control=out/f'control-{job.name}';control.mkdir()
                for f in ['job.txt','source.vibe']: shutil.copy2(job/f,control/f)
                result=subprocess.run([str(runner),str(compiler),str(control),str(control/'worker.out'),'__no_entry__'],
                                      cwd=root,env={**base,'VIBE_MODULE_JOB_DIR':'1','VIBE_IMPORT_ABI':'raw'},
                                      capture_output=True,timeout=30)
                assert result.returncode==0,result.stderr.decode()
                for f in ['outcome.txt','env.out','cache.out','fingerprint.out']:
                    assert (job/f).read_bytes()==(control/f).read_bytes(),(name,f)
    rows.append(dict(case=name,exit_code=proc.returncode,events=events,cpu_overlap_windows=overlap,
                     products_match_serial=name!='failure',all_workers_reaped=True))
    (out/'results.json').write_text(json.dumps({'status':'running','rows':rows},indent=2)+'\n')
    print(name,'passed',len(overlap),'shared windows of positive child CPU progress',flush=True)
(out/'results.json').write_text(json.dumps({'status':'running configuration and slot controls','scope':'functional CPU concurrency and ownership proof; not a timing comparison','rows':rows},indent=2)+'\n')

# Check mode/CFG initialization against the established CLI, including a real
# effect-row diagnostic that disappears in the explicit unchecked mode.
mode_outcomes=[]
for number,(cfg,checked) in enumerate([('',None),('', '0'),(' dev ,, ', '0'),('release','0')]):
    products=[]
    for image,label in [(worker,'worker'),(compiler,'serial')]:
        job=out/f'mode-{number}-{label}';job.mkdir()
        (job/'job.txt').write_text(f'version\t1\npath\t{out}/mode.vibe\n')
        (job/'source.vibe').write_text('#cfg(dev)\nexport fn selected() -> Int { 1 }\n#cfg(release)\nexport fn selected() -> String { "release" }\nexport fn failure() -> Int { throw("failure") }\n')
        env={**base,'VIBE_MODULE_JOB_DIR':'1','VIBE_CFG':cfg}
        if checked is not None:env['VIBE_CHECK_ERROR_ROW']=checked
        result=subprocess.run([str(runner),str(image),str(job),str(job/'worker.out'),'__no_entry__'],cwd=root,env=env,capture_output=True,timeout=30)
        assert result.returncode==0,result.stderr.decode()
        products.append({f:(job/f).read_bytes() if (job/f).exists() else None for f in ['outcome.txt','env.out','diag.txt','cache.out','fingerprint.out']})
    assert products[0]==products[1],('worker configuration differs from CLI',number)
    mode_outcomes.append(products[0])
assert mode_outcomes[0]['outcome.txt'] != mode_outcomes[1]['outcome.txt'], 'effect-row control did not change the actual checker outcome'
assert mode_outcomes[2]['env.out'] != mode_outcomes[3]['env.out'], 'CFG control did not change the checked interface'
print('checked/unchecked error rows and CFG match CLI products',flush=True)

# A repeated simultaneous request on one slot must reject oversubscription
# and release the first worker even when the host call traps.
src=out/'oversubscribe.vibe'
src.write_text('let run: () -> Int with Async = () -> { let a = host_future_named("checker-0"); let b = host_future_named("checker-0"); await(a) + await(b) }\n')
with (out/'oversubscribe-compile.log').open('w') as log:
    result=subprocess.run(['bash',str(root/'scripts/run_wasm_vibe_host_runner.sh'),'--invoke','cli_main',str(compiler),str(src),str(out/'oversubscribe.component.wasm'),'run'],cwd=root,env={**base,'VIBE_IMPORT_ABI':'raw','VIBE_RC':'1','VIBE_RUNNER_EXIT_WITH_RESULT':'1'},stdout=log,stderr=log,timeout=60)
assert result.returncode==0
queues=[[],[],[],[]]
for i in range(2):
    job=out/f'oversubscribe-job{i}';job.mkdir()
    for f in ['job.txt','source.vibe']:shutil.copy2(out/'one-job0-0'/f,job/f)
    queues[0].append(str(job))
plan={'version':1,'wasm':str(worker),'cwd':str(root),'queues':queues}
path=out/'oversubscribe.json';path.write_text(json.dumps(plan))
result=subprocess.run([str(runner),str(out/'oversubscribe.component.wasm')],cwd=root,env={**base,'VIBE_CHECKER_WORKERS':str(path),'VIBE_CHECKER_WORKER_TRACE':'1'},capture_output=True,timeout=30)
assert result.returncode==1 and b'previous worker is still owned' in result.stderr,result.stderr.decode()
events=[json.loads(line.split(' ',1)[1]) for line in result.stderr.decode().splitlines() if line.startswith('vibe-checker-worker ')]
started=[e for e in events if e['event']=='started'];assert len(started)==1,events
assert not Path(f"/proc/{started[0]['pid']}").exists(),'worker survived failed host call'
plan['version']=2;path.write_text(json.dumps(plan))
result=subprocess.run([str(runner),str(out/'oversubscribe.component.wasm')],cwd=root,env={**base,'VIBE_CHECKER_WORKERS':str(path),'VIBE_CHECKER_WORKER_TRACE':'1'},capture_output=True,timeout=30)
assert result.returncode==1 and b'expected version 1' in result.stderr and b'vibe-checker-worker ' not in result.stderr,result.stderr.decode()
print('slot bound, trap cleanup and invalid-plan controls passed',flush=True)
(out/'results.json').write_text(json.dumps({'status':'passed','scope':'functional CPU concurrency and ownership proof; not a timing comparison','rows':rows,'configuration_parity_cases':4,'oversubscription_rejected':True,'trap_reaped_worker':True,'invalid_plan_rejected_before_spawn':True},indent=2)+'\n')
print("retained checker TaskGroup oracle:",out,flush=True)
