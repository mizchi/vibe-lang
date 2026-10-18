"""Diagnostic phase replay with per-sample command identity across exec.

The earlier RSS totals are valid; its first-observed command cache can retain a
shell/fork parent's pre-exec name. Preserve v1 and use this for phase attribution.
No walltime here is a promotion sample.
"""
import json, sys, time
from pathlib import Path
sys.path.insert(0,str(Path.cwd()/'bench/perf'))
import selfbuild_baseline as base
lab=Path(sys.argv[1]).resolve();comparison=lab/'comparison';corpus=lab/'baseline/corpus'
record=json.loads((comparison/'authority.json').read_text())
assert json.loads((comparison/'measurement.json').read_text())['verified_complete']
def verify():
    for name,digest in record['files'].items():assert base.sha(comparison/name)==digest,name
verify()
out=lab/'transport-diagnostics/rss-timeline-v2';out.mkdir()
original=base.snapshot;observations=[]
for subject,source,entry in [('compiler','lib/@vibe/compiler/tests/codegen_lexer_test.vibe','__no_entry__'),('split-cli','lib/@vibe/cli/entry.vibe','cli_main')]:
    for lane in ['a0','b0']:
        private=out/f'{subject}-{lane}';private.mkdir()
        for temperature in ['cold','warm']:
            samples=[];history={};started=time.monotonic()
            def snapshot(root):
                values=original(root);now=time.monotonic()-started;rows={}
                for pid,(_,rss,cpu) in values.items():
                    try:command=Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
                    except OSError:command=''
                    rows[pid]={'rss_bytes':rss,'cpu_s':cpu,'command':command}
                    events=history.setdefault(pid,[])
                    if not events or events[-1]['command']!=command:events.append({'s':now,'command':command})
                samples.append({'s':now,'processes':rows})
                return values
            base.snapshot=snapshot;images=comparison/lane
            env=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_FS_COMPILE':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(private/'cache'),
                'VIBE_NATIVE_CACHE_DIR':str(comparison/'native-cache'),'VIBE_FUNCTION_TRACE_OUT':str(private/f'{temperature}-trace.json')}
            command=['node',str(images/'taskgroup_functions_frontend.mjs'),str(images/'compiler.wasm'),source,str(private/'out.wasm'),entry,'4',str(corpus),str(images),str(images/'viberun')]
            base.measure(command,corpus,env,private/temperature)
            assert base.sha(private/'out.wasm')==record['baseline_artifacts'][subject]
            active=[i for i,s in enumerate(samples) if any(p['command'].endswith('/worker.wasm ') for p in s['processes'].values())]
            assert active
            groups={'before_workers':samples[:active[0]],'workers_alive':samples[active[0]:active[-1]+1],'after_workers':samples[active[-1]+1:]}
            peaks={}
            for phase,values in groups.items():
                if not values:continue
                peak=max(values,key=lambda s:sum(p['rss_bytes'] for p in s['processes'].values()))
                peaks[phase]={'s':peak['s'],'rss_bytes':sum(p['rss_bytes'] for p in peak['processes'].values()),'processes':peak['processes']}
            observation={'subject':subject,'lane':lane,'temperature':temperature,'artifact_sha256':base.sha(private/'out.wasm'),'peaks':peaks,
                'scope':'20ms diagnostic replay only; per-sample /proc command identities across exec, simultaneous RSS, shared mappings may be double-counted. No independent-process peak summation. Boundaries quantized by sampling.'}
            base.write(private/temperature/'timeline.json',{'observation':observation,'samples':samples,'exec_history':history})
            observations.append(observation);base.write(out/'summary.json',{'complete':False,'observations':observations})
            print(subject,lane,temperature,{k:round(v['rss_bytes']/2**20,1) for k,v in peaks.items()},flush=True)
base.snapshot=original;verify()
base.write(out/'summary.json',{'complete':True,'observations':observations,'supersedes':'v1 first-command-cache classification only; retain original totals and data. This replays8configs separately; it is not another promotion comparison.'})
print('Per-sample process identity, all outputs and images verified.',flush=True)
