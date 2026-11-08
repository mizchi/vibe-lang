"""Exercise explicit checked-module policies across fresh Wasm processes."""
import argparse, hashlib, json, os, subprocess
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('root', type=Path)
p.add_argument('compiler', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
root, compiler, work = (x.resolve() for x in (a.root, a.compiler, a.output))
work.mkdir(exist_ok=False)
source = Path(__file__).with_name('cache_probe.vibe').resolve()
image = work / 'probe.wasm'
runner = root / 'scripts/run_wasm_vibe_host_runner.sh'
env = {k:v for k,v in os.environ.items() if not k.startswith('VIBE_')}
env.update(VIBE_PREOPEN_DIR=str(root), VIBE_FS_COMPILE='1', VIBE_RC='0', VIBE_IMPORT_ABI='raw', VIBE_BUILD_CACHE_DIR=str(work/'compile-cache'))
r = subprocess.run(['bash',str(runner),'--invoke','cli_main',str(compiler),str(source.relative_to(root)),str(image),'main'],cwd=root,env=env,capture_output=True,text=True,timeout=900)
(work/'compile.log').write_text(r.stdout+r.stderr)
assert r.returncode == 0 and r.stdout.strip() == '0' and image.exists(), (r.stdout, Path(str(image)+'.diag').read_text() if Path(str(image)+'.diag').exists() else r.stderr)
subprocess.run(['wasm-tools','validate',str(image)],check=True)
program = work/'source.vibe'
program.write_text('export let value = 42\n')
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
receipt = {'compiler_sha256':sha(compiler), 'probe_sha256':sha(source), 'image_sha256':sha(image), 'runs':[]}
def run(label, mode, fresh=None, handoff=None, stats=None, flags='alpha', poison=False, failure=False):
    cfg = dict(env,VIBE_BUILD_CACHE_DIR=str(work/'cache'),CHECKED_POLICY_SOURCE=str(program),CHECKED_POLICY_MODE=mode,CHECKED_POLICY_FLAGS=flags,CHECKED_POLICY_POISON='1' if poison else '0')
    r = subprocess.run(['bash',str(runner),'--invoke','_start',str(image)],cwd=root,env=cfg,capture_output=True,text=True,timeout=240)
    (work/(label+'.log')).write_text(r.stdout+r.stderr)
    row = {'label':label,'mode':mode,'flags':flags,'exit':r.returncode}
    if failure:
        assert r.returncode != 0 and 'checked module cache verification mismatch:' in r.stdout+r.stderr, (label,r.stdout,r.stderr)
    else:
        assert r.returncode == 0, (label,r.stdout,r.stderr)
        f=r.stdout.strip().split('\t')
        if poison:
            assert f[0]=='poison' and len(f)==2, f
            row['key']=f[1]
        else:
            assert f[0]=='checked-policy' and len(f)==8, (label,f)
            row.update(fresh=f[1]=='true',handoff=int(f[2]),stats=tuple(map(int,f[3:6])),captures=int(f[6]),key=f[7])
            assert (row['fresh'],row['handoff'],row['stats'],row['captures'])==(fresh,handoff,stats,3), row
    receipt['runs'].append(row)
    (work/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('PASS '+label,flush=True)
    return row
cold_off=run('off-cold','off',True,-1,(0,0,0))
assert not Path(cold_off['key']).exists()
cold=run('on-cold','on',True,1,(0,1,1))
key=Path(cold['key']);token=key.stat().st_mtime_ns;digest=sha(key)
run('on-warm','on',False,1,(1,0,1))
run('off-warm','off',True,-1,(0,0,0))
run('verify-warm','verify',True,1,(0,1,1))
assert key.stat().st_mtime_ns==token and sha(key)==digest
key.write_bytes(b'\xff')
run('malformed-on','on',True,1,(0,1,1))
key.write_bytes(b'\xff')
run('malformed-verify','verify',True,1,(0,1,1))
program.write_text('export let value = 43\nexport let extra = true\n')
edited=run('edited','on',True,2,(0,1,1));newkey=Path(edited['key'])
assert newkey!=key
run('edited-warm','on',False,2,(1,0,1))
run('poison','on',poison=True)
poison_hash=sha(newkey)
run('valid-mismatch','verify',failure=True)
assert sha(newkey)==poison_hash
newkey.write_bytes(b'\xff')
run('recovered','verify',True,2,(0,1,1))
other=run('namespace-cold','on',True,2,(0,1,1),flags='beta')
assert other['key']!=edited['key']
run('namespace-warm','on',False,2,(1,0,1),flags='beta')
