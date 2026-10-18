"""Instrument an isolated parent entry copy; never modify maintained source."""
import difflib
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path.cwd() / 'bench/perf'))
import selfbuild_baseline as base
import selfbuild_profiles as profiles

lab = Path(sys.argv[1]).resolve()
workspace = lab / 'baseline'
corpus = workspace / 'corpus'
candidate = lab / 'decoder-candidate'
images = candidate / 'images'
runner = workspace / 'engines/o0/viberun'
meta = json.loads((workspace / 'workspace.json').read_text())
matrix = json.loads((workspace / 'matrix/measurement.json').read_text())
assert matrix['verified_complete']
comparison=json.loads((candidate/'comparison/measurement.json').read_text())
assert comparison['verified_complete'] and comparison['aa_guest_memory_exact'] and len(comparison['samples'])==132
assert (candidate/'comparison.exit').read_text().strip()=='0'
build=json.loads((candidate/'build-authority.json').read_text());assert build['complete']
def verify_candidate():
    for path,digest in build['sources'].items():
        assert base.sha(Path.cwd()/path)==digest,('candidate source changed',path)
    receipt=json.loads((images/'build.json').read_text())
    assert receipt==build['image_receipt']
    for path,digest in receipt['artifacts'].items():
        assert base.sha(images/path)==digest,('candidate image changed',path)
verify_candidate()

assert (lab / 'diagnostic-controls.exit').read_text().strip() == '0'
receipt = base.image_receipts(workspace)
base.verify_source(corpus, meta)
out = candidate / 'parent-phase-probe'
out.mkdir()
source = out / 'compile.vibe'
original = (Path.cwd() / 'lib/@vibe/function_build/compile.vibe').read_text()
text = original

def replace(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)

replace('let plan_counts: Array[Int] = [0, 0]', '''let plan_counts: Array[Int] = [0, 0]
struct MemorySpan { phase: String; index: Int; bytes: Int; begin: Int; end: Int }
let memory_spans: Array[MemorySpan] = []
let execute_bounds: Array[Int] = [0, 0]
fn record_memory(phase: String, index: Int, byte_count: Int, begin: Int, end: Int) -> Unit {
  Array::push(memory_spans, MemorySpan::{ phase: phase, index: index, bytes: byte_count, begin: begin, end: end })
}''')
replace('  let bytes = write_function_context(Array::get(contexts, 0))', '''  let memory_begin = Profiler::heap_bytes()
  let bytes = write_function_context(Array::get(contexts, 0))
  let memory_end = Profiler::heap_bytes()
  record_memory("context-encode", -1, Bytes::length(bytes), memory_begin, memory_end)''')
replace('  Array::set(context_digest, 0, blake3_bytes_simd(bytes))', '''  let hash_begin = Profiler::heap_bytes()
  Array::set(context_digest, 0, blake3_bytes_simd(bytes))
  let hash_end = Profiler::heap_bytes()
  record_memory("context-hash", -1, Bytes::length(bytes), hash_begin, hash_end)''')
line='  let bytes = write_function_job_into(Array::get(input_buffer, 0), Array::get(contexts, 0), Array::get(context_digest, 0), total * index / jobs, total * (index + 1) / jobs)'
replace(line,'  let memory_begin = Profiler::heap_bytes()\n'+line+'\n  let memory_end = Profiler::heap_bytes()\n  record_memory("job-encode", index, Bytes::length(bytes), memory_begin, memory_end)')
replace('  Array::set(input_digests, index, blake3_bytes_simd(bytes))', '''  let hash_begin = Profiler::heap_bytes()
  Array::set(input_digests, index, blake3_bytes_simd(bytes))
  let hash_end = Profiler::heap_bytes()
  record_memory("job-hash", index, Bytes::length(bytes), hash_begin, hash_end)''')
replace('  if length > Array::get(product_capacity, 0) {','  let memory_begin = Profiler::heap_bytes()\n  if length > Array::get(product_capacity, 0) {')
replace('  clear_bytes(buffer)\n  buffer','''  clear_bytes(buffer)
  let memory_end = Profiler::heap_bytes()
  record_memory("product-buffer", index, length, memory_begin, memory_end)
  buffer''')
replace('  let bytes = Array::get(product_buffer, 0)\n  if input_digest', '  let hash_begin = Profiler::heap_bytes()\n  let bytes = Array::get(product_buffer, 0)\n  if input_digest')
replace('  let product = match linear_body_cache_from_bytes(bytes) {','''  let hash_end = Profiler::heap_bytes()
  record_memory("product-hash", index, Bytes::length(bytes), hash_begin, hash_end)
  let decode_begin = Profiler::heap_bytes()
  let product = match linear_body_cache_from_bytes(bytes) {''')
replace('  let context = Array::get(contexts, 0)\n  let total = context.input.num_user_funcs','''  let decode_end = Profiler::heap_bytes()
  record_memory("product-decode", index, Bytes::length(bytes), decode_begin, decode_end)
  let context = Array::get(contexts, 0)
  let total = context.input.num_user_funcs''')
line='  validate_function_product(context.plan, context.input, product, total * index / jobs, total * (index + 1) / jobs)'
replace(line,'  let validate_begin = Profiler::heap_bytes()\n'+line+'\n  let validate_end = Profiler::heap_bytes()\n  record_memory("product-validate", index, Bytes::length(bytes), validate_begin, validate_end)')
line='  let context = function_context_new(plan, input, debug_break, debug_trace, enable_rc, rc_shadow)'
replace(line,'''  let execute_begin = Profiler::heap_bytes()
  Array::set(execute_bounds, 0, execute_begin)
  let context_begin = Profiler::heap_bytes()
'''+line+'''
  let context_end = Profiler::heap_bytes()
  record_memory("context-setup", -1, 0, context_begin, context_end)''')
replace('  let completed = compiler_lowering_run(jobs)', '''  let group_begin = Profiler::heap_bytes()
  let completed = compiler_lowering_run(jobs)
  let group_end = Profiler::heap_bytes()
  record_memory("worker-group", -1, 0, group_begin, group_end)''')
replace('  let mut merged = Array::get(products, 0)', '  let merge_begin = Profiler::heap_bytes()\n  let mut merged = Array::get(products, 0)')
replace('  let result = replay_function_products(context, merged)', '''  let merge_end = Profiler::heap_bytes()
  record_memory("product-merge", -1, 0, merge_begin, merge_end)
  let replay_begin = Profiler::heap_bytes()
  let result = replay_function_products(context, merged)
  let replay_end = Profiler::heap_bytes()
  record_memory("product-replay", -1, 0, replay_begin, replay_end)''')
replace('  Array::set(product_capacity, 0, 0)\n  result','''  Array::set(product_capacity, 0, 0)
  let execute_end = Profiler::heap_bytes()
  Array::set(execute_bounds, 1, execute_end)
  record_memory("execute-total", -1, 0, execute_begin, execute_end)
  result''')
replace('fn main() -> Unit allows Env + Exception + Fs {\n  configure_cfg_flags()', 'fn main() -> Unit allows Env + Exception + Fs + Console {\n  let main_begin = Profiler::heap_bytes()\n  configure_cfg_flags()')
line='  Fs::write_bytes(Env::get("VIBE_LOWERING_OUTPUT"), strip_executable_wasm_env(bytes, Env::get("VIBE_LOWERING_ENTRY")))'
replace(line,'''  let compile_end = Profiler::heap_bytes()
  record_memory("main-before-execute", -1, 0, main_begin, Array::get(execute_bounds, 0))
  record_memory("main-after-execute", -1, Bytes::length(bytes), Array::get(execute_bounds, 1), compile_end)
  let publish_begin = Profiler::heap_bytes()
'''+line+'''
  let publish_end = Profiler::heap_bytes()
  record_memory("publication", -1, Bytes::length(bytes), publish_begin, publish_end)
  let observer_final = Profiler::heap_bytes()
  for span in memory_spans {
    println("heap-span|" + span.phase + "|" + Int::to_string(span.index) + "|" + Int::to_string(span.bytes) + "|" + Int::to_string(span.begin) + "|" + Int::to_string(span.end))
  }
  println("heap-final|" + Int::to_string(observer_final))''')
assert text != original and text.count('record_memory(') == 17
# Keep the executor's Exception-only effect contract. The pure marker is
# replaced at the Wasm instrumentation boundary with a read of exported
# __heap_ptr; main independently checks the real Profiler capability.
text = text.replace('Profiler::heap_bytes()', 'diagnostic_heap_bytes(1)')
text = 'export fn diagnostic_heap_bytes(one: Int) -> Int = wasm\n"i64.const 0"\n\n' + text
assert text.count('allows Env + Exception + Fs + Console {') == 1
text = text.replace('allows Env + Exception + Fs + Console {', 'allows Env + Exception + Fs + Console + Profiler::heap_bytes {')
needle = '  let observer_final = diagnostic_heap_bytes(1)\n  for span in memory_spans {'
assert text.count(needle) == 1
text = text.replace(needle, '  let observer_final = diagnostic_heap_bytes(1)\n  let profiler_final = Profiler::heap_bytes()\n  if profiler_final != observer_final { throw("raw heap observer differs from Profiler") } else ()\n  for span in memory_spans {')
source.write_text(text)
(out / 'instrumentation.patch').write_text(''.join(difflib.unified_diff(original.splitlines(True),text.splitlines(True),fromfile='lib/@vibe/function_build/compile.vibe',tofile=str(source))))
compiler = candidate / 'generation/stage2.wasm'
engine = source.parent / 'compile.wasm'
env = base.clean_env(Path.cwd()) | {'VIBE_RC': '0', 'VIBE_FS_COMPILE': '1', 'VIBE_IMPORT_ABI': 'raw',
    'VIBE_WASM_NAMES': '1', 'VIBE_WASM_KEEP_EXPORTS': '1', 'VIBE_BUILD_CACHE_DIR': str(source.parent / 'build-cache')}
profiles.run(['bash','scripts/run_wasm_vibe_host_runner.sh','--invoke','cli_main',str(compiler),str(source),str(engine),'main'],Path.cwd(),env,out/'build')
# Post-build diagnostic instrumentation: one validated marker body only.
def integer(data, position):
    value = shift = 0
    while True:
        byte = data[position]; position += 1
        value |= (byte & 127) << shift
        if byte < 128: return value, position
        shift += 7
        assert shift < 36

def leb(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128); value >>= 7
    result.append(value)
    return bytes(result)

def name(data, position):
    length, position = integer(data, position)
    return data[position:position + length].decode(), position + length

raw = engine.read_bytes(); assert raw[:8] == b'\0asm\x01\0\0\0'
sections = []; position = 8
while position < len(raw):
    kind = raw[position]; position += 1
    length, position = integer(raw, position)
    sections.append((kind, raw[position:position + length])); position += length
imports = 0; exports = {}
for kind, data in sections:
    if kind == 2:
        count, position = integer(data, 0)
        for _ in range(count):
            _, position = name(data, position); _, position = name(data, position)
            assert data[position] == 0, 'diagnostic supports function imports only'
            position += 1; _, position = integer(data, position); imports += 1
        assert position == len(data)
    if kind == 7:
        count, position = integer(data, 0)
        for _ in range(count):
            label, position = name(data, position); tag = data[position]; position += 1
            index, position = integer(data, position); exports[label] = (tag, index)
        assert position == len(data)
assert exports['__heap_ptr'] == (3, 0)
heap_globals = next(data for kind, data in sections if kind == 6)
_, position = integer(heap_globals, 0)
assert heap_globals[position:position + 2] == b'\x7f\x01', 'mutable i32 heap global required'
tag, function = exports['diagnostic_heap_bytes']; assert tag == 0
ordinal = function - imports; assert ordinal >= 0
rebuilt = bytearray(raw[:8]); before_body = after_body = None
for kind, data in sections:
    if kind == 10:
        count, position = integer(data, 0); bodies = []
        assert ordinal < count
        for index in range(count):
            length, position = integer(data, position); body = data[position:position + length]; position += length
            if index == ordinal:
                before_body = body
                assert body == b'\x00\x42\x00\x0b', ('unexpected marker body', body.hex())
                # locals=0; global.get heap(0); i64.extend_i32_u;
                # local.get one; i64.mul; end. Caller passes Int1.
                body = b'\x00\x23\x00\xad\x20\x00\x7e\x0b'
                after_body = body
            bodies.append(leb(len(body)) + body)
        assert position == len(data)
        data = leb(count) + b''.join(bodies)
    rebuilt.extend(bytes([kind]) + leb(len(data)) + data)
assert before_body is not None and after_body is not None
unpatched = source.parent / 'compile-unpatched.wasm'; unpatched.write_bytes(raw)
engine.write_bytes(rebuilt)
wasm_patch = {'method': 'Replace only the validated i64.const0 marker body with a read of the exported mutable i32 heap global. All other section payloads and function bodies remain unchanged.',
              'heap_global_index': 0, 'marker_function_index': function, 'original_body_hex': before_body.hex(), 'new_body_hex': after_body.hex(),
              'unpatched_sha256': base.sha(unpatched), 'instrumented_sha256': base.sha(engine),
              'calibration': 'Main grants Profiler::heap_bytes and requires exact equality with the inserted observer before printing. Native final raw heap_peak is independently checked.'}
base.write(out / 'wasm-instrumentation.json', wasm_patch)

record = {'source_commit': meta['source_commit'], 'original_source_sha256': base.sha(Path.cwd()/'lib/@vibe/function_build/compile.vibe'), 'candidate_build_authority_sha256':base.sha(candidate/'build-authority.json'), 'selected_image_receipt': build['image_receipt'],
    'instrumented_source_sha256': base.sha(source), 'patch_sha256': base.sha(out/'instrumentation.patch'),
    'compiler_sha256': base.sha(compiler), 'original_parent_sha256': base.sha(images/'compile.wasm'),
    'instrumented_parent_sha256': base.sha(engine), 'wasm_instrumentation': wasm_patch, 'image_receipts': receipt, 'samples': [], 'complete': False,
    'scope': 'Diagnostic entry-copy only. Precise bump-frontier boundaries, not walltime wins. Parent spans worker-group/execute-total contain child spans; never sum inclusive ancestors. Recorder storage and printing add small outside-region allocations. Final Profiler pointer is calibrated against native raw heap_peak.'}
base.write(out/'summary.json',record)
for subject, input_path, entry in [('compiler','lib/@vibe/compiler/tests/codegen_lexer_test.vibe','__no_entry__'),('split-cli','lib/@vibe/cli/entry.vibe','cli_main')]:
    for index in range(4):
        private=out/f'{subject}-{index}';private.mkdir()
        config=private/'service.json'
        base.write(config,{'version':1,'worker':str(images/'worker.wasm'),'coordinator':str(images/'coordinator.component.wasm'),'runner':str(runner),'cwd':str(corpus),'directory':str(private),'jobs':4})
        selected=base.clean_env(corpus)|{'VIBE_RC':'1','VIBE_MEM':'1','VIBE_BUILD_CACHE_DIR':str(out/f'{subject}-cache'),'VIBE_NATIVE_CACHE_DIR':str(workspace/'native-cache'),'VIBE_LOWERING_INPUT':input_path,'VIBE_LOWERING_OUTPUT':str(private/'out.wasm'),'VIBE_LOWERING_ENTRY':entry,'VIBE_LOWERING_DIRECTORY':str(private),'VIBE_LOWERING_MODE':'single','VIBE_FUNCTION_JOBS':'4','VIBE_LOWERING_SERVICE_CONFIG':str(config)}
        profiles.run([str(runner),str(engine)],corpus,selected,private/'logs')
        assert base.sha(private/'out.wasm')==matrix['artifacts'][subject]
        stdout=(private/'logs/stdout.log').read_text().splitlines()
        spans=[]
        for line in stdout:
            if line.startswith('heap-span|'):
                _,phase,number,size,begin,end=line.split('|')
                begin,end=int(begin),int(end)
                assert end>=begin>0,(phase,begin,end)
                spans.append({'phase':phase,'index':int(number),'input_bytes':int(size),'begin':begin,'end':end,'allocated_bytes':end-begin})
        final=[int(line.split('|')[1]) for line in stdout if line.startswith('heap-final|')]
        assert len(final)==1 and spans
        memory=base.guest_memory((private/'logs/stderr.log').read_text())
        assert final[0]<=memory['heap_peak'] and memory['heap_peak']-final[0]<1024*1024,('Profiler raw-byte unit calibration failed',final,memory)
        for phase in ['job-encode','job-hash','product-buffer','product-hash','product-decode','product-validate']:
            rows=[s for s in spans if s['phase']==phase]
            assert len(rows)==4 and {s['index'] for s in rows}=={0,1,2,3},phase
        service=json.loads((private/'service-report.json').read_text())
        assert service['workers']==4 and service['preparation_count']==1
        sample={'subject':subject,'index':index,'temperature':'cold' if index==0 else 'warm','spans':spans,'guest_memory':memory,'profiler_final':final[0],'profiler_to_native_final_gap_bytes':memory['heap_peak']-final[0],'output_sha256':base.sha(private/'out.wasm'),'path':str(private)}
        record['samples'].append(sample);base.write(out/'summary.json',record)
        print('phase probe',subject,index,'output and profiler units verified',flush=True)
base.verify_source(corpus,meta)
assert base.image_receipts(workspace)==receipt and base.sha(source)==record['instrumented_source_sha256']
for subject in ['compiler','split-cli']:
    samples=[s for s in record['samples'] if s['subject']==subject and s['temperature']=='warm']
    assert len(samples)==3
    assert samples[0]['spans']==samples[1]['spans']==samples[2]['spans'],subject
verify_candidate()
record['complete']=True;base.write(out/'summary.json',record)
print('Parent phase allocation probe complete; all outputs, raw-counter units and warm repeated spans agree.',flush=True)
