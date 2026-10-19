"""Continue supported integration; retain full-graph GC3512 as a separate failure."""
import json,re,subprocess,sys,time
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent;out=lab/'integration-9f93'
sys.path.insert(0,str(root/'bench/perf'));import selfbuild_baseline as base
record=json.loads((out/'source-authority.json').read_text());initial=json.loads((out/'validation.json').read_text())
assert not initial['complete'] and initial['steps'][-1]['name']=='fingerprint-gc-node' and initial['steps'][-1]['exit']!=0
(out/'attempt1-validation.json').write_text(json.dumps(initial,indent=2)+'\n')
compiler=out/'generation/stage2.wasm';producer=base.fixed_point(compiler.parent);native=root/'runtime/viberun/target/release/viberun'
steps=[]
def verify():
 for key in ['sources','generated']:
  for p,h in record[key].items():assert base.sha(root/p)==h,('integration source changed',p)
 assert base.sha(compiler)==producer['stages']['stage2']['sha256']
def run(name,command,env=None,expect=0,needle=None):
 verify();started=time.monotonic();log=out/(name+'.log')
 with log.open('w') as stream:r=subprocess.run(command,env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=1800)
 step={'name':name,'command':command,'exit':r.returncode,'expected':'zero' if expect==0 else 'nonzero','wall_s':time.monotonic()-started,'log_sha256':base.sha(log)};steps.append(step)
 base.write(out/'followup-progress.json',{'complete':False,'steps':steps});print(name,r.returncode,round(step['wall_s'],3),flush=True)
 assert (r.returncode==0 if expect==0 else r.returncode!=0),step
 if needle:assert needle in log.read_text(),(step,needle)
 verify()
verify()
gcenv=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':'1','VIBE_BACKEND':'gc','VIBE_BUILD_CACHE_DIR':str(out/'gc-control-cache')}
# Main input graph, compiled with this integration producer. Explicitly not a
# separate unmodified-main compiler producer or a performance measurement.
target='lib/@vibe/compiler/codegen/common_base/common_base_codegen_body_cache_from_bytes.vibe';test='lib/@vibe/compiler/tests/codegen_layout_fingerprint_test.vibe'
main=record['main_commit'];main_body=out/'main-body-cache.vibe';main_test=out/'main-fingerprint-test.vibe'
main_body.write_bytes(subprocess.check_output(['git','show',main+':'+target]));main_test.write_bytes(subprocess.check_output(['git','show',main+':'+test]))
mainenv=gcenv|{'VIBE_SOURCE_OVERLAY':str(root/target),'VIBE_SOURCE_OVERLAY_WITH':str(main_body),'VIBE_BUILD_CACHE_DIR':str(out/'main-input-gc-cache')}
mainwasm=out/'main-input-gc.wasm'
run('compile-main-input-gc',[str(native),str(compiler),str(main_test),str(mainwasm),'__no_entry__'],mainenv)
run('main-input-gc-node',['bash','scripts/run_wasm_vibe_host_runner.sh','--invoke','_start',str(mainwasm)],gcenv,expect=1,needle='data segment')
assert 'out of bounds' in (out/'main-input-gc-node.log').read_text()
# Extract only exact implementation definitions, retaining every complete
# independent scalar/legacy test. This scopes algorithm GC, not import graph.
source=(root/target).read_text();equal=(root/'lib/@vibe/compiler/codegen/common_base/common_base.vibe')
chunks=[];probes={}
for name in ['bcc_int_lists_equal','bcc_fp_byte','bcc_fp_int','bcc_fp_string','bcc_fp_new','bcc_fp_emit','bcc_layout_fp_strings','bcc_layout_fp_strings_upto']:
 text=source
 match=re.search(r'^(?:export )?fn '+name+r'\(',text,re.M)
 if match is None:
  matches=[]
  for p in (root/'lib/@vibe/compiler/codegen/common_base').glob('*.vibe'):
   t=p.read_text();m=re.search(r'^(?:export )?fn '+name+r'\(',t,re.M)
   if m:matches.append((p,t,m))
  assert len(matches)==1,name
  p,text,match=matches[0]
 end=text.index('\n}',match.start())+2;chunk=text[match.start():end];chunks.append(chunk);probes[name]=base.sha(root/target) if text==source else base.sha(p)
tests=(root/test).read_text();end=tests.index('\n}')+2;test_payload=tests[end:];probe=out/'gc-exact-probe.vibe';probe.write_text('\n\n'.join(chunks)+test_payload)
assert test_payload.count('\ntest ')==3
base.write(out/'gc-extraction.json',{'probe_sha256':base.sha(probe),'production_file_sha256':probes,'test_sha256':base.sha(root/test),'scope':'Exact current definitions and every scalar/legacy test; imports removed only. Not fullimportgraphGC.'})
probewasm=out/'gc-exact-probe.wasm'
run('compile-gc-exact-probe',[str(native),str(compiler),str(probe),str(probewasm),'__no_entry__'],gcenv)
run('gc-exact-probe-node',['bash','scripts/run_wasm_vibe_host_runner.sh','--invoke','_start',str(probewasm)],gcenv)
run('gc-exact-probe-wasmtime',['wasmtime','run','-W','gc=y,function-references=y,exceptions=y','--invoke','_start',str(probewasm)],gcenv)
# Repeat the compiled overflow negative control against this current producer.
mutant=source.replace('while k + 4 <= len {','while k + 5 <= len {',1);assert mutant!=source
needle='    let b3 = String::char_code_at(sv, k + 3)\n';assert mutant.count(needle)==1
mutant=mutant.replace(needle,needle+'    let b4 = String::char_code_at(sv, k + 4)\n',1)
for var,mult,mod in [('h1',131,2147483647),('h2',137,2147483629)]:
 before=f' * {mult} + b3) % {mod}';assert mutant.count(before)==1
 mutant=mutant.replace(before,f' * {mult} + b3) * {mult} + b4) % {mod}',1);assert mutant.count(var+' = ((((')==1;mutant=mutant.replace(var+' = ((((',var+' = (((((',1)
assert mutant.count('    k = k + 4\n')==1;mutant=mutant.replace('    k = k + 4\n','    k = k + 5\n',1)
mutant_path=out/'fivebyte-overflow-mutant.vibe';mutant_path.write_text(mutant)
for mode,rc in [('bump','0'),('rc','1')]:
 output=out/('fivebyte-'+mode+'.wasm');env=base.clean_env(root)|{'VIBE_FS_COMPILE':'1','VIBE_RC':rc,'VIBE_BUILD_CACHE_DIR':str(out/('fivebyte-cache-'+mode)),'VIBE_SOURCE_OVERLAY':str(root/target),'VIBE_SOURCE_OVERLAY_WITH':str(mutant_path)}
 run('compile-fivebyte-'+mode,[str(native),str(compiler),test,str(output),'__no_entry__'],env)
 assert base.sha(output)!=base.sha(out/('fingerprint-'+mode+'.wasm'))
 run('reject-fivebyte-'+mode,[str(native),str(output)],base.clean_env(root),expect=1,needle='__test_string layout batches preserve every byte, offset and tail')
env=base.clean_env(root)|{'VIBE_TEST_CLI_WASM':str(compiler),'VIBE_RC':'1','VIBE_BUILD_CACHE_DIR':str(out/'regression-cache')}
run('cache-and-runtime-regressions',['bash','scripts/vibe_test.sh','lib/@vibe/compiler/tests/codegen_body_cache_persist_test.vibe','lib/@vibe/compiler/tests/body_cache_edit_classes_test.vibe','lib/@vibe/compiler/tests/codegen_body_cache_test.vibe','lib/@vibe/compiler/tests/runtime_size_trim_test.vibe'],env)
run('public-functions',['python3','scripts/test_taskgroup_functions.py',str(compiler),str(out/'images')])
env=base.clean_env(root)|{'VIBE_CLI_WASM':str(compiler.relative_to(root)),'VIBE_RUNNER':'runtime/viberun/target/release/viberun'}
run('mutate-relative-paths',['bash','scripts/vibe_mutate_test.sh'],env)
verify();receipt=json.loads((out/'images/build.json').read_text());assert receipt['compiler_sha256']==base.sha(compiler)
for p,h in receipt['artifacts'].items():assert base.sha(out/'images'/p)==h
base.write(out/'validation.json',{'complete':True,'scope':'Supportedlinear integration and exactalgorithmGC only; fullimportgraphGCremainsknown3512failure, notpassed. No performance rerun.','initial_attempt_sha256':base.sha(out/'attempt1-validation.json'),'initial_attempt':initial,'followup_steps':steps,'producer':producer,'receipt':receipt,'source_authority_sha256':base.sha(out/'source-authority.json'),'known_gc_limitation':{'issue':3512,'candidate_fullgraph_node_exit':initial['steps'][-1]['exit'],'main_input_control':'Unmodifiedmain9f93 test/bodycache sources, compiled byintegrationproducer; compilepass, samefullgraphdata-segmentinstantiationfailure. Thisisnotanunmodifiedmaincompilerproducer.','main_commit':main,'main_body_sha256':base.sha(main_body),'main_test_sha256':base.sha(main_test),'extracted_algorithm_gc_passes':True}})
base.write(out/'followup-progress.json',{'complete':True,'steps':steps});print('Supportedintegrationcomplete; fullgraphGC3512retainedseparately.',flush=True)
