"""Exercise the real Pkl DAG and shell dispatch with instrumented payloads.

Compiler/gate payloads are probes in a scratch checkout. The production Pkl
file, lane dispatcher, selftest lane and discovery/tree guard execute normally.
This tests execution ownership, not the correctness of the mocked payloads;
release-check separately executes the real payloads with its rebuilt compiler.
"""
import collections
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PKF = shutil.which('pkf')
CONTROL = ['scripts/compiler_gate.sh', 'scripts/check_gate_self_tests.sh',
           'tests/gates/selftests/run.sh', 'tests/gates/lib.sh', 'scripts/run_bounded.sh']
# Host classifiers and source queries do not execute generated Vibe programs.
# Ignore the lane's target-allocator default only for this audited set. Never
# ignore backend, cfg, compiler selection or an explicit capability override.
RC_INDEPENDENT = set('''
check_ast_binary_tags check_bench_corpus check_book_links check_builtin_emits
check_canonical_iterator_calls check_doc_classification check_doc_path_citations
check_documented_decls check_gate_portability check_gate_self_tests
check_gate_wiring check_gc_host_import_counts check_generated_stamp_report
check_grep_chunked_sweep check_grep_driver_parity check_grep_memory_budget
check_host_runtime_contract check_scripts_readme check_source_range_contract
check_task_inputs check_treesitter_artifacts check_treesitter_wasm_corpus
check_version_ladder lint_architecture_debt lint_method_style_naming
'''.split())
# Preserve the previously exercised sibling environments. Their equivalence
# across target allocators is not established by this ownership test.
ALLOCATOR_VARIANTS = set('''
check_body_cache_discard check_bodyless_impl_refusal check_book_console
check_builtin_shadowing check_compile_only_lanes check_daemon_memory_diagnostic
check_export_refusal check_freeze_surface check_host_remove_parity
check_host_semantic_parity check_import_reservation check_lambda_bound_refusal
check_telemetry_sidecar_guards reloc_crossbuild lint_review_regressions
'''.split())
KEYS = ['VIBE_RC', 'VIBE_STAGE2_WASM', 'VIBE_TEST_CLI_WASM',
        'COMPILE_ONLY_STAGE2', 'CAPABILITY_PREFLIGHT_STAGE2', 'VIBE_BACKEND',
        'GREP_PARITY_STAGE2', 'GREP_CHUNK_STAGE2', 'GREP_BUDGET_STAGE2',
        'VIBE_CFG', 'VIBE_UNSTABLE', 'VIBE_TEST_BACKEND']
OWN_TEST = 'tests/gates/release_selftests_test.sh'
LANE_COMPANIONS = {
    'tests/gates/lib_test.sh', 'scripts/reloc_crossbuild_test.sh',
    'scripts/checked_module_cache_parity_test.sh',
    'scripts/checked_module_cache_cost_test.sh', 'scripts/incremental_kpi_test.sh',
    'scripts/resolve_stage2_test.sh', 'scripts/run_bounded_test.sh',
    'scripts/host_capability_withhold_test.sh',
}

SHIM = r'''import json, os, sys
from pathlib import Path
a = sys.argv[1:]
kind = Path(sys.argv[0]).name
root = Path(os.environ['PROBE_ROOT'])
if kind == 'pkf':
    if a and a[0] == 'format':raise SystemExit(0)
    if a and a[0] == 'run': a += ['--no-cache']
    os.execv(os.environ['PROBE_PKF'],[os.environ['PROBE_PKF']]+a)
if kind == 'rustc':
    p=Path(a[a.index('-o')+1]);p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text('#!'+sys.executable+'\n');p.chmod(0o755)
    raise SystemExit(0)
if kind == 'bash' and '-c' in a:
    os.execv('/bin/bash',['/bin/bash']+a)
if kind in ['bash','python3']:
    if not a or a[0].startswith('-'):raise SystemExit(0)
    scripts=[(a[0],a[1:])]
elif kind == 'node':
    if '-e' in a or '--eval' in a:raise SystemExit(0)
    if '--test' in a:
        scripts=[(s,[]) for s in a if not s.startswith('-') and s.endswith(('.mjs','.cjs','.js'))]
    else:scripts=[(a[0],a[1:])] if a and not a[0].startswith('-') else []
else:scripts=[]
for s,extra_args in scripts:
    p=Path(s)
    if not p.is_absolute():p=Path.cwd()/p
    if not p.is_file():raise SystemExit('missing payload: '+s)
    try:name=str(p.resolve().relative_to(root))
    except ValueError:raise SystemExit('payload outside fixture: '+s)
    env={k:os.environ.get(k) for k in json.loads(os.environ['PROBE_KEYS'])}
    with open(os.environ['PROBE_TRACE'],'a') as f:
        f.write(json.dumps({'script':name,'env':env,'args':extra_args})+'\n')
    expected_kind={'.sh':'bash','.py':'python3','.js':'node','.mjs':'node','.cjs':'node'}.get(p.suffix)
    if expected_kind and kind!=expected_kind:raise SystemExit('wrong interpreter: '+s)
    if name in ['scripts/compiler_gate.sh','scripts/check_gate_self_tests.sh',
                'tests/gates/selftests/run.sh']:
        os.execv('/bin/bash',['/bin/bash']+a)
'''


def run_probe(mutation=None, overrides=None, shard=None, targets=None, info_only=False, selected=False):
    if not PKF:
        raise AssertionError('pkf is required (the CI selftests lane installs it)')
    with tempfile.TemporaryDirectory(prefix='release-selftests-') as d:
        home=Path(d);project=home/'project';project.mkdir();bins=home/'bin';bins.mkdir()
        names=subprocess.check_output(['git','ls-files','--cached','--others',
                                       '--exclude-standard','scripts','tests'],
                                      cwd=ROOT,text=True).splitlines()
        for name in names:
            if not name.endswith(('.sh','.mjs','.cjs','.py','.vibex','.pkl','.txt')):
                continue
            p=project/name;p.parent.mkdir(parents=True,exist_ok=True)
            if name.endswith('.pkl') or name in CONTROL or name.startswith('scripts/gate_self_test_'):
                shutil.copyfile(ROOT/name,p)
            else:p.write_text('')
        shutil.copyfile(ROOT/'Taskfile.pkl',project/'Taskfile.pkl')
        for name in CONTROL:
            p=project/name;p.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/name,p)
        (project/'.gitignore').write_text('*\n')
        compiler=project/'_build/selfhost/generations/probe/stage2.wasm'
        compiler.parent.mkdir(parents=True);compiler.write_bytes(b'ownership probe')
        if mutation:mutation(project)
        subprocess.run(['git','init','-q'],cwd=project,check=True)
        subprocess.run(['git','add','-f','Taskfile.pkl','.gitignore',*CONTROL],cwd=project,check=True)
        subprocess.run(['git','-c','user.name=probe','-c','user.email=probe@example.invalid',
                        'commit','-qm','ownership fixture'],cwd=project,check=True)
        for name in ['bash','node','python3','rustc','cargo','pkf']:
            p=bins/name;p.write_text('#!'+sys.executable+'\n'+SHIM);p.chmod(0o755)
        trace=home/'trace.jsonl';env=os.environ.copy()
        for k in list(env):
            if k.startswith(('VIBE_','COMPILER_GATE_','GREP_','CAPABILITY_PREFLIGHT_')):
                env.pop(k)
        env.pop('BASH_ENV',None)
        env.update(PATH=str(bins)+os.pathsep+os.environ['PATH'],PROBE_ROOT=str(project),
                   PROBE_TRACE=str(trace),PROBE_PKF=PKF,PROBE_KEYS=json.dumps(KEYS),
                   VIBE_STAGE2_WASM=str(compiler))
        if overrides:env.update(overrides)
        if shard is None:
            command=[PKF,'run',*(targets or ['release-check']),'--no-cache','-j','1']
        else:
            env['COMPILER_GATE_SELFTESTS_SHARD']=shard
            command=[str(bins/'bash'),'scripts/compiler_gate.sh','selftests']
        if selected:command=[str(bins/'bash'),'scripts/compiler_gate.sh']
        info=subprocess.run([PKF,'info','--json'],cwd=project,env=env,text=True,
                            capture_output=True,check=True,timeout=30)
        tasks=json.loads(info.stdout)['tasks']
        if info_only:return [],tasks
        r=subprocess.run(command,cwd=project,env=env,text=True,capture_output=True,timeout=120)
        if r.returncode:
            raise AssertionError('probe command failed:\n'+r.stdout[-3000:]+r.stderr[-1000:])
        events=[json.loads(s) for s in trace.read_text().splitlines()] if trace.exists() else []
        return events,tasks


def identity(script, env, args=()):
    env=dict(env)
    if Path(script).stem.removesuffix('_test') in RC_INDEPENDENT:
        env['VIBE_RC']=None
    values=[]
    for k in KEYS:
        v=env.get(k)
        if v and v.endswith('/_build/selfhost/generations/probe/stage2.wasm'):
            v='$COMPILER'
        values.append(v)
    return script,tuple(values),tuple(args)


def companions():
    found=set()
    for p in (ROOT/'scripts').iterdir():
        n=p.name
        if not (n.startswith(('check_','lint_')) or n.endswith(('_gate.sh','_oracle.mjs'))):
            continue
        if n.endswith(('_test.sh','_test.py','_test.mjs','.test.mjs','.test.py','.test.vibex')):
            continue
        base=p.with_suffix('')
        for tail in ['_test.sh','.test.mjs','_test.py']:
            t=Path(str(base)+tail)
            if t.is_file():
                found.add(str(t.relative_to(ROOT)));break
    return found


def verify(events,tasks,standalone=True,shards=1,variants=()):
    counts=collections.Counter(identity(e['script'],e['env'],e.get('args',())) for e in events)
    calls=collections.Counter(e['script'] for e in events)
    for name in ['scripts/compiler_gate.sh','tests/gates/selftests/run.sh',
                 'scripts/check_gate_self_tests.sh']:
        assert calls[name]==shards,(name,calls[name],shards)
    if standalone:
        assert calls['tests/gates/bootstrap/run.sh']==1,'bootstrap missing from release'
        order=[e['script'] for e in events]
        assert order.index('tests/gates/bootstrap/run.sh')<order.index('tests/gates/selftests/run.sh')
    if (ROOT/OWN_TEST).is_file():assert calls[OWN_TEST]==1,('ownership test missing/duplicated',calls[OWN_TEST])
    primary=dict.fromkeys(KEYS);primary.update(VIBE_RC='0',VIBE_STAGE2_WASM='$COMPILER')
    covered=companions() | LANE_COMPANIONS
    expected={identity(p,primary) for p in covered}
    cap='scripts/check_capability_preflight_test.sh'
    expected.add(identity(cap,dict(primary,CAPABILITY_PREFLIGHT_STAGE2='$COMPILER')))
    if standalone:
        for n in ALLOCATOR_VARIANTS:
            expected.add(identity('scripts/'+n+'_test.sh',dict(primary,VIBE_RC=None)))
        # pkf info omits Task.env. Declare deliberately introduced variants in
        # the independent oracle, then verify their actual runtime environment.
        # Uninventoried variants fail closed instead of being normalized away.
        for script,extra,args in variants:
            assert set(extra)<=set(KEYS),('unclassified task environment',sorted(extra))
            expected.add(identity(script,{**primary,'VIBE_RC':None,**extra},args))
    relevant={k:v for k,v in counts.items() if k[0] in covered}
    assert set(relevant)==expected,('missing/extra variants',sorted(map(str,expected-set(relevant))),
                                   sorted(map(str,set(relevant)-expected)))
    duplicates={str(k):v for k,v in relevant.items() if v!=1}
    assert not duplicates,('duplicate selftest execution',duplicates)


def replace_once(p,old,new):
    s=p.read_text();assert s.count(old)==1,(p,old,s.count(old))
    changed=s.replace(old,new);assert changed!=s;p.write_text(changed)


def owned_tasks(tasks):
    out=[]
    for base in sorted(RC_INDEPENDENT-{'check_gate_self_tests'}):
        command='bash scripts/'+base+'_test.sh'
        matches=[t for t in tasks if t.get('cmd')==command]
        assert len(matches)==1,(command,'standalone task missing/ambiguous')
        assert matches[0].get('visibility')=='public',command
        out.append(matches[0])
    return out


def verify_inputs(tasks):
    by_name={t['name']:t for t in tasks}
    for name in ['release-compiler-gate','compiler-gate']:
        owner=set(by_name[name].get('inputs',[]))
        assert {'Taskfile.pkl','.github/pkfire-version','scripts/gate_self_test*.txt'}<=owner,(name,'graph/pin input missing')
        assert 'ensure-viberun' in by_name[name].get('deps',[]),(name,'runner prerequisite missing')
        for t in owned_tasks(tasks):
            missing=set(t.get('inputs',[]))-owner
            assert not missing,('delegated input missing',name,t['name'],sorted(missing))
            if shlex.split(t['cmd'])[1] in {
                'scripts/check_documented_decls_test.sh',
                'scripts/check_grep_memory_budget_test.sh',
                'scripts/check_grep_chunked_sweep_test.sh',
                'scripts/check_grep_driver_parity_test.sh',
                'scripts/check_source_range_contract_test.sh',
            }:
                assert 'generation' in t.get('deps',[]),(t['name'],'compiler prerequisite missing')
    assert 'generation' in by_name['check-source-ranges'].get('deps',[]),('check-source-ranges','compiler prerequisite missing')


def remove_launcher_input(project):
    p=project/'Taskfile.pkl';s=p.read_text()
    start=s.index('local releaseCompilerGate = new Task {')
    end=s.index('local releaseCheck = new Task {',start)
    block=s[start:end];old='    "runtime/vibe"\n'
    assert block.count(old)==1
    replace_once(p,block,block.replace(old,''))


def remove_compiler_prerequisite(project):
    p=project/'Taskfile.pkl';s=p.read_text()
    start=s.index('local testCheckGrepDriverParity = new Task {')
    end=s.index('local checkCliLineTermination',start)
    block=s[start:end];old='deps { selfhostGeneration; ensureViberun }'
    assert block.count(old)==1
    replace_once(p,block,block.replace(old,'deps { ensureViberun }'))


def add_sibling(project,variant=False):
    p=project/'Taskfile.pkl'
    replace_once(p,'    releaseCompilerGate\n',
                 '    releaseCompilerGate\n    testCheckGrepDriverParity\n')
    if variant:
        replace_once(p,'local testCheckGrepDriverParity = new Task {',
                     'local testCheckGrepDriverParity = new Task {\n  env { ["VIBE_BACKEND"] = "gc" }')


def main():
    events,tasks=run_probe();verify(events,tasks)
    verify_inputs(tasks)
    print('release-selftests: real Pkl graph and shell dispatch execute each owned variant once')
    poison={'COMPILER_GATE_LANE':'early','COMPILER_GATE_SELFTESTS_SHARD':'1/3',
            'VIBE_GATE_SELF_TESTS_RUN':'0','VIBE_GATE_SELF_TESTS_SHARD':'2/3',
            'VIBE_GATE_SELF_TEST_ROOT':'/not-a-checkout',
            'VIBE_GATE_SELF_TEST_BASELINE':'not-a-real-gate'}
    verify(*run_probe(overrides=poison))
    print('release-selftests: inherited lane/shard/skip/scratch selectors cannot narrow release')
    verify(*run_probe(lambda p:add_sibling(p,True)),variants=[
        ('scripts/check_grep_driver_parity_test.sh',{'VIBE_BACKEND':'gc'},()),
    ])
    print('release-selftests: an explicit backend variant is preserved')
    standalone=owned_tasks(tasks)
    direct,_=run_probe(targets=[t['name'] for t in standalone])
    calls=collections.Counter(e['script'] for e in direct)
    for t in standalone:
        assert calls[shlex.split(t['cmd'])[1]]==1,t['name']
    assert not calls['scripts/compiler_gate.sh'],'standalone unexpectedly runs full gate'
    print('release-selftests: all delegated standalone tasks remain executable')
    selected,_=run_probe(overrides={'COMPILER_GATE_LANE':'early'},selected=True)
    assert [e['script'] for e in selected]==['scripts/compiler_gate.sh','tests/gates/early/run.sh']
    print('release-selftests: standalone compiler-gate still supports lane selection')
    mutations={
        'duplicate dependency':lambda p:add_sibling(p),
        'missing execution edge':lambda p:replace_once(p/'Taskfile.pkl','    releaseCompilerGate\n',''),
        'disabled lane dispatch':lambda p:replace_once(p/'scripts/compiler_gate.sh',
                                                    '  bash "$script"\n','  : "$script"\n'),
        'disabled payload dispatch':lambda p:replace_once(p/'scripts/check_gate_self_tests.sh',
            'env -u VIBE_GATE_SELF_TESTS_SHARD bash "$1"',': "$1"'),
    }
    for label,mutation in mutations.items():
        try:verify(*run_probe(mutation))
        except AssertionError as error:
            # A broken fixture/failed command is not an ownership finding.
            assert 'probe command failed' not in str(error),str(error)
            print('release-selftests: red verified:',label)
        else:raise AssertionError('accepted mutation: '+label)
    try:verify_inputs(run_probe(remove_launcher_input,info_only=True)[1])
    except AssertionError as error:
        assert 'delegated input missing' in str(error),str(error)
        print('release-selftests: red verified: missing delegated cache input')
    else:raise AssertionError('accepted missing runtime/vibe input')
    try:verify_inputs(run_probe(remove_compiler_prerequisite,info_only=True)[1])
    except AssertionError as error:
        assert 'compiler prerequisite missing' in str(error),str(error)
        print('release-selftests: red verified: missing compiler prerequisite')
    else:raise AssertionError('accepted missing generation dependency')
    events=[]
    for i in range(3):
        part,tasks=run_probe(shard=f'{i}/3');events.extend(part)
    verify(events,tasks,standalone=False,shards=3)
    print('release-selftests: CI shards partition every variant exactly once')


if __name__=='__main__':main()
