# Selfcompile heap reduction (2026-10-20)

The ordinary cold selfcompile KPI falls from **1,203,071,168 to
953,336,600 bytes**, a 20.8% reduction. The candidate reports exactly the
same heap frontier in four trials. The approximate 950 MB target is reached
without changing the workload or increasing a gate.

The [machine-readable record](../../../bench/perf/analysis/selfcompile-heap-2026-10-20.json)
contains compiler identities, all paired samples, source receipts, A/A controls,
CPU and allocation diagnostics, and validation results.

## Workload and comparison

This is one ordinary stage2 filesystem compile of
`lib/@vibe/compiler/tests/codegen_lexer_test.vibe`, whose imports reach the
compiler. It measures the guest bump frontier, not the peak of the complete
seed-to-stage3 bootstrap or steady-state daemon memory.

The baseline is main commit `a67a659aafb8f06f2fce42e7f320b9e6ec8d252b`.
Before editing, its normal generation build verified stage2 == stage3 and
three ordinary cold KPI runs reproduced 1,203,071,168 bytes. The candidate
also verifies stage2 == stage3.

A separate controlled comparison freezes 1,699 tracked library files from
that main revision and its original generated codegen fingerprint. Both the
entry and imported dependencies are read with the process cwd set to this
frozen tree. All receipts match before and after the final measurements.
A negative control corrupts an imported copied dependency, requires the
corresponding parse error and no output, and restores the original bytes.

Four rounds alternate AB / BA / AB / BA. Each lane has an independent fresh
cache and equal-length compiler, cache and output paths; its second compile
uses that same cache for the warm sample. No builds, tests, allocation sampling
or CPU profiling run concurrently with these measurements. An independent
same-artifact A/A pair has exactly equal cold and warm heap values.

| Frozen main input | Before heap, MB | After heap, MB | Change | Before wall median, s | After wall median, s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold | 1,204.1 | 952.9 | -20.9% | 6.560 | 6.553 |
| Warm | 692.9 | 567.6 | -18.1% | 4.341 | 4.407 |

MB means 1,000,000 bytes. Every heap value is identical across its four
trials. All 16 generated Wasm files are byte-identical to the clean-main
output (`efcdcaac...6fbff5`). This change makes no throughput improvement
claim: cold wall medians are essentially equal; the observed warm median is
1.5% higher.

The ordinary runner's peak RSS medians also decrease: 1,325.2 to 1,076.4 MB
cold and 798.3 to 671.7 MB warm. Reserved Wasm pages stay unchanged at 18,663
cold and 12,442 warm; reservation, RSS and guest bump frontier are distinct.

## Allocation changes

Allocation-frontier sampling identified repeated temporary arrays, closure
creation, Option reboxing and output-buffer growth. A named compiler is
checked to have identical standard Wasm sections to the ordinary artifact.
Sampling preserves both the uninstrumented heap value and generated Wasm;
it is diagnostic evidence, never a wall-time measurement. CPU profiles are
collected separately, three cold/warm runs per compiler.

- `Array::make` and `make_with` reserve their known size. Hash-table growth
  moves existing immutable Option slots; misses reuse an empty slot's None.
  Alias lookup returns its existing Option after recording the rename.
- Callee restoration uses nested scratch windows, and evidence worklists
  append children directly. Empty callback-argument fallbacks are shared.
- Await, optional-perform, match-scrutinee and local heap-parameter passes
  leave a declaration's tree intact when it contains no applicable rewrite.
- Environment encoding reuses empty parts buffers, bounded to four buffers
  of at most 262,144 parts. Pure package-header scans have an eight-entry,
  1 MiB-per-source bound and defensive copies at mutable public boundaries;
  a conservative no-header check avoids unnecessary scanning.
- Constructor membership reads the definition's existing variant array;
  names are materialized only for diagnostics. Disabled provenance and
  failed binding lookup avoid constructing fresh None values per query.
- Async-iterator metadata masking records only existing nearest keys that
  need hiding. Ordinary binder masks remain, preserving lexical authority.
  Parameter shadow keys are skipped only when there is no outer environment.
- String membership uses a loop instead of allocating a recursive closure.
  Substitution allocates cycle scratch only for variable chains and maps
  function parameters directly into a sized array.
- Wasm serialization reserves the exact code-section size and a module
  capacity hint derived from completed payloads. Extra custom/debug sections
  can still grow the output normally.

The allocation profile still identifies lexing, empty-array construction,
map slot storage and dictionary desugaring as substantial remaining costs.

## Validation and gate

Targeted RC1 tests pass: 25 files / 248 test blocks. The added lifetime and
scope regressions also pass under shadow and bump modes: six files / 59
blocks in each. Collection tests pass on GC/Wasmtime; codec and header GC
artifacts pass through the production Node host, which supplies their
`vibe::env-get` import. Bare Wasmtime alone cannot instantiate those modules.
The separate RC-shadow recurrence fixture is compiled with its actual `main`
entry and executes to the expected `25377489`.

The full normal `pkf run release-check -j 1` passes: 126 tasks (22 cached,
104 executed). Its compiler-gate verified the stage2/stage3 fixed point; the
normal stage2 SHA matches the measured compiler. Compile-only lane checks
and their mutation controls also pass.

The annotated-lambda allocation oracle prepares both variants' shared AST
traversal scratch before counting per-invocation inference overhead. Its
512-byte limit is unchanged; unannotated positive controls still expose
roughly 34 KB of call-site table work. Its three test blocks pass under RC,
shadow and bump. Test-only preparation changes leave the generated compiler
inputs and the measured artifact unchanged.

The absolute baseline in `bench/perf/heap_baseline.txt` is ratcheted down
from 1,084,426,520 to 953,336,600 bytes. The existing 10% allowance is unchanged,
so its maximum becomes 1,048,670,260 bytes. Raw local evidence is retained under
`_build/selfcompile-heap-2026-10-20`.
