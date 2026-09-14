# Compiler memory experiments

Use measurements to choose memory optimizations without changing the
production defaults speculatively. The [memory contract](../spec/memory-contract.md)
describes what is implemented; the [region contract](../region-mutable-state.md)
defines the boundary an arena experiment must preserve.

## Comparison protocol

Keep these two axes separate:

1. **Compiler runtime:** the supplied compiler Wasm's own bump, RC or GC
   representation. Record its hash, build source revision, generated flat
   source hash, build selectors and correctness evidence.
2. **Generated target:** the backend and RC selectors passed to that compiler.
   Hold these constant when comparing compiler implementations. A separate
   target-backend experiment compares execution of the generated programs.

The opt-in collector accepts two already-built compilers. It does not rebuild
generations, select a seed, or infer the compilers' memory modes from filenames.
Node 24+ and macOS or Linux with `/usr/bin/time` are required.

```bash
# Check the measurement protocol without building a compiler.
pkf run test-compare-compiler-memory

# A/A first: establish path/cache bias and wall-time noise using one artifact.
pkf run compare-compiler-memory -- \
  /path/to/bump.wasm /path/to/bump.wasm _build/memory-aa 4 closure

# Independent cold/warm pairs for both the compiler closure and full CLI.
pkf run compare-compiler-memory -- \
  /path/to/bump.wasm /path/to/rc.wasm _build/memory-bump-rc 4 full

# An intentional RC codegen change; execute semantic tests separately.
pkf run compare-compiler-memory -- \
  /path/to/before.wasm /path/to/after.wasm _build/memory-codegen 4 full --allow-codegen-diff
```

Use a new output directory for each invocation. The collector refuses to
overwrite an earlier run. Each successful directory contains `manifest.json`,
`samples.jsonl`, `summary.json`, and per-process logs/resource readings. A
failed run keeps diagnostics and completed samples but produces no success
summary. Large temporary compiler copies, target Wasm and caches are removed.

The manifest records the current checkout and tracked `lib` source digest
separately from the supplied compiler hashes: a checkout revision is **not**
proof that an input compiler was built from that checkout. Retain generation
manifests/flat-source hashes alongside the experiment when publishing results.

The protocol is fixed within one comparison:

- Target is linear RC (`VIBE_BACKEND=wasi`, `VIBE_RC=1`), with Wasm names off.
  Checked-module, experimental AST and body caches are off. Ambient `VIBE_*`
  and `NODE_*` selectors cannot change the experiment.
- Every sample starts a fresh process through the repository Node wrapper.
  The wrapper uses the collector's Node binary and its normal Wasm flags.
- Cold uses a new empty persistent-cache directory. Warm immediately uses the
  same populated directory. These labels concern application caches, not OS
  page caches, warmed JIT code or a persistent compiler instance.
- Artifact/cache paths have equal lengths across alternatives; the target
  output path is identical. Compiler order reverses each round (AB, BA, AB,
  BA). Use at least three rounds for decisions; four balances the order.
- Both compilers, both temperatures and every round must emit byte-identical,
  valid Wasm for the same input. Mismatches stop the comparison. This is an
  output-equivalence check, not a replacement for executing targeted tests.
  This collector compares runtime implementations that preserve generated code.
  An optimization to RC lowering intentionally changes that code: measure it
  with `--allow-codegen-diff`, which records the exception and still rejects
  output drift within a compiler across temperatures or rounds. Verify execution
  in bump, RC and RC-shadow separately. The default remains strict equality.
- Wall time includes process startup. Profiles run **separately** using
  `scripts/profile_compile.sh` with explicit isolated caches. Do not run other
  compiles or benchmarks alongside the measurement.

`closure` compiles `lib/@vibe/compiler/tests/codegen_lexer_test.vibe` with
`__no_entry__`; `full` also compiles `lib/@vibe/cli/entry.vibe` with `cli_main`.
These are filesystem compilation workloads, not elapsed time for the whole
seed-to-stage3 generation pipeline.

Report wall medians, the median paired ratio, raw spread, peak RSS, end RSS,
main heap pointer, linear-memory capacity and output/compiler sizes separately.
The collector does **not** measure live native-GC heap, GC pauses, allocator
call counts or total allocation volume. Missing metrics are unavailable,
never zero. Heap-pointer movement cannot substitute for them under RC reuse,
arenas or native GC.

## Region and GC target probes

Reuse the existing fixtures before inventing a compiler-wide arena. For each
target configuration (linear bump, linear RC, GC), compile with the same
explicit compiler, run the fixture's snapshots, then measure main-heap growth
in a separate execution. For example:

```bash
mkdir -p _build/region-observation
VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_PREOPEN_DIR="$PWD" \
  VIBE_BACKEND=gc VIBE_RC=0 \
  VIBE_BUILD_CACHE_DIR="$PWD/_build/region-observation/cache" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  /path/to/stage2.wasm fixtures/region_arena_bounded.vibe \
  _build/region-observation/list.wasm __no_entry__
bash scripts/run_wasm_vibe_host_runner.sh _build/region-observation/list.wasm
node scripts/region_arena_heap_delta.mjs _build/region-observation/list.wasm
```

Repeat with `region_bytes_arena_bounded.vibe`. Use `VIBE_BACKEND=wasi` with
`VIBE_RC=0` / `1` for the two linear targets. Include copy-out, nesting and
`region_throw_unwind_test.vibe` when changing allocation or cleanup; the
Exception fixture requires the runner's exception-reference support when
measuring its heap delta. Compiler-generated Wasm must be validated before
interpreting a measurement.

For native GC coverage, use `gc_heap_churn_test.vibe`, the
`gc_direct_array_*` fixtures, and
`lib/@vibe/compiler/tests/gc_struct_opcode_snapshot_test.vibe`.
Check emitted native allocation instructions **and** value behavior. Reduced
linear heap growth alone cannot establish that engine collection is bounded
or faster. A GC-built full compiler has not been benchmarked by the initial
bump/RC comparison.

## Experiment queue and decision rules

Change one mechanism at a time. Record a hypothesis, a counterexample that
must remain correct, the measured result and the resulting decision. Replace
an experiment's pending decision with its measured conclusion; do not keep a
second document claiming a superseded design is current.

| Priority | Experiment | Required evidence before adoption |
| --- | --- | --- |
| 1 | Reduce redundant RC retains through borrow inference | Fewer `rc_dup` samples/calls on real checker/rewrite workloads; shared/escaping/indirect-call behavior preserved; cold and warm compile results and memory compared |
| 2 | Reuse scratch buffers or reserve known capacity | Reduced regrowth/allocation with copy-out cost included; no retained references across reset; improvements on both compiler runtime modes |
| 3 | Expand native GC representation for a bounded type/use case | Native opcode coverage, alias/mutation/ABI parity, engine-specific wall and RSS; live-GC metrics explicitly unavailable until instrumented |
| 4 | Enable a narrow RC region allocation path | RC free-list isolation, child ownership, regrowth, overflow, copy-out and unwind tests; measure bytes-only and reference-bearing collections separately |
| 5 | Reuse a host-compiled Module with a fresh Store per build | Split module load/AOT/JIT/instantiate/guest execution/teardown time; repeat builds without stale guest references; account for loss or externalization of persistent guest caches |

This order is a measured starting hypothesis, not a commitment to implement
every row. The initial RC profile identifies retains as the largest known
cost; it does not prove how much a particular borrow-inference change saves.
Host teardown already bounds the whole bump compiler run's lifetime, so a
host-only reset cannot remove generated RC instructions or establish a new
within-build lifetime boundary.

For each candidate:

1. Reproduce the intended effect and its correctness failure before editing.
2. Run targeted tests locally. For compiler changes, verify the appropriate
   self-reproduction and target-output equivalence; leave the full suite to CI.
3. Compare cold/cold and warm/warm on the same idle machine, with an A/A
   control. Wall changes within the observed spread remain inconclusive until
   supported by profile or deterministic allocation evidence.
4. Explain any memory increase even when wall improves. A smaller linear
   heap cannot by itself justify a claim of lower total memory under GC.
5. Change a default only after the relevant correctness/ABI gates and measured
   workload criteria hold. ADR-0092's RC/bump wall ratio of at most 1.2 is an
   existing self-build target, not a target met by today's implementation.

## CI budget

The comparison tasks are opt-in and are not dependencies of existing CI
gates. Keep the existing bounded `selfhost_build_metrics.mjs` series for
routine regression observation. Its probe/runtime/target protocol differs
from this direct compiler-artifact comparison; never merge the two series.

Promote an experiment only after measuring its collection cost and variance.
Prefer a small deterministic regression fixture on each PR and longer timing
matrices on demand or a scheduled lane. Do not make noisy wall/RSS readings
new per-PR failure thresholds without evidence that the threshold is stable.

## Initial evidence

The initial artifacts were built from revision `6c14f734d` (merged as #2780)
using the same generated flat source, with Wasm names enabled:

Flat-source SHA-256:
`4e94faeddcdd619195cf965f3b9ab04c86041dbb6d11cd3a316a02f871cd3208`.

| Compiler runtime | SHA-256 | Bytes |
| --- | --- | ---: |
| Bump | `c671c81c34abd2bc9a027b9b4ce1819411f10feeb2cc52801c6e89e0b51a63e4` | 3,617,045 |
| RC | `d30fefd36c47342de6f867a9b7ae774aa65c152eefd7a42159eda5a8ad4b3baf` | 5,673,548 |

The RC compiler reproduced its own RC artifact and regenerated the original
bump artifact byte-for-byte. The same pair produced matching target artifacts
for an RC array probe (result `42`) and `gc_backend_smoke_test.vibe` (result
`101557`). These checks establish the measured paths, not full backend parity.

A separate isolated cold CPU profile on the compiler closure sampled
`__rt_rc_dup` at 3.171 s / 41.3%, `__rt_rc_drop` at 0.329 s / 4.3%, and
`__rt_rc_alloc` at 0.186 s / 2.4% of 7.672 s total RC samples. It includes
current representation differences; it is not an allocator-only comparison.
These samples are diagnostic evidence from the initial investigation and are
not the uninstrumented wall measurements collected by the new script.

### Controlled compiler comparison, 2026-09-14

Node 24.21.0, macOS arm64, Apple M5. Four rounds per configuration, using the
collector above against the same compiler sources on merge `6aa35ec64`.
The [baseline data](compiler-memory-baseline.json) retains all 32 samples,
the A/A control, compiler/source identities and protocol hash. Absolute wall
times from separate invocations are not comparable: machine load changed
between the A/A control and this comparison.

| Input / cache | Bump wall median | RC wall median | RC / bump | Median paired ratio |
| --- | ---: | ---: | ---: | ---: |
| Compiler closure / cold | 2.084 s | 6.852 s | 3.29 | 3.23 |
| Compiler closure / warm | 1.428 s | 4.490 s | 3.14 | 3.14 |
| CLI / cold | 5.105 s | 14.906 s | 2.92 | 2.91 |
| CLI / warm | 4.034 s | 11.183 s | 2.77 | 2.81 |

These wall readings have visible spread: closure cold bump 1.984–2.637 s and
RC 6.323–7.281 s; warm bump 1.314–2.040 s and RC 4.335–4.754 s. This supports
the large RC gap, not precise forecasts of small optimization gains.

Memory figures below are medians in decimal GB. Each metric has its own
scope; in particular a lower end RSS does not imply a lower peak RSS.

| Input / cache | Main heap pointer, bump → RC | Linear capacity, bump → RC | Peak RSS, bump → RC |
| --- | --- | --- | --- |
| Compiler closure / cold | 0.957 → 1.058 | 1.223 → 1.223 | 1.199 → 1.570 |
| Compiler closure / warm | 0.629 → 0.685 | 0.817 → 0.837 | 0.865 → 1.188 |
| CLI / cold | 2.668 → 2.696 | 3.568 → 3.461 | 2.850 → 3.007 |
| CLI / warm | 2.071 → 2.011 | 2.419 → 2.208 | 2.247 → 2.464 |

All target artifacts matched within each input across the two compilers,
temperatures and rounds. A/A used the same bump artifact in both positions:
heap-pointer and linear-memory readings agreed exactly, with wall median
ratios 0.987 cold and 1.011 warm (paired ratios 0.996 and 1.035).

**Decision:** retain the bump self-build default. Investigate redundant
retains first; use scratch-storage experiments as the next independent
memory-reduction track. RC's smaller CLI linear-memory capacity alone does
not justify its wall-time and peak-RSS costs on these workloads.

### Direct recursion and binder scratch, 2026-09-14

The first two experiments now have implementations and
[raw measurements](compiler-retain-scratch.json). Direct recursive functions
infer borrowed parameters by starting with eligible positions and removing
consumed ones until stable. The current solver closes all direct-call
dependencies, including mutual recursion; see the fixed-point experiment below.
Program-wide disqualifiers are linked first: a temporary argument in another
module must also propagate through recursive argument permutations.
Indirect calls, captures, shadowing and duplicate declarations stay conservative.
Whole-program and per-module inference share the same pass.
Global aliases and bodyless declarations have authoritative ownership entries;
labeled and optional parameter names are canonicalized before shadow checks.

The second change reuses the binder-name work array in
`md_shadow_zeroed_bmasks`. The walk cannot re-enter the query, clears its string
references before returning, and keeps returned mask arrays independent. A
warmed query with no matching callee shadow allocates 0 bytes, down from 28;
tests also preserve results across subsequent queries with different shadows.

The RC compiler contains **89,317 → 86,208 retain call sites** (−3,109,
3.5%). A separate cold profile of the staged scratch candidate samples `rc_dup` at 3,177 → 2,832 ms, with
39 ms inside the added analysis. These profiles are single runs; they explain
the change rather than supply additional wall-time replicates.

Four alternating pairs per input/temperature, Node 24.21.0 on Apple M5:

| Workload | Retain-only RC wall, paired median | Retain-only RC heap pointer | Additional scratch heap reduction |
|---|---:|---:|---:|
| Closure, cold | −1.6% | −2.7% | 1.7 MB |
| Closure, warm | −3.0% | −2.1% | 1.7 MB |
| CLI, cold | −3.6% | −1.9% | 2.7 MB |
| CLI, warm | −1.7% | −1.2% | 2.7 MB |

Scratch-only paired wall changes range from −0.5% to +1.4%; no wall-time
gain is established for that small change. Its generated outputs match the
retain-only compiler byte for byte across both workloads and temperatures.
The retain-only and scratch-only runs compile different source snapshots;
compare alternatives within each run, not absolute times between runs.

The staged scratch candidate's initial bump comparison reported +1.3%/+7.3% wall on
the closure (cold/warm) and +2.4%/+3.0% on the CLI. The same-artifact control
has exactly equal heap pointers and linear-memory capacities, but wall ratios
still vary. An extended **eight-pair closure comparison** reports −2.6% cold
and +0.1% warm; the initial 7.3% increase did not reproduce. A separate warm
bump profile spends 14 ms of about 1.4 s in the new analysis. CLI wall changes
remain within the control's spread. Bump heap changes are small increases:
less than 0.001% for the closure and about 0.02–0.03% for the CLI.
The declaration index and mask snapshot add allocations to borrow inference;
the reported bump delta is the net cost after scratch reuse and codegen changes.
All initial, control and extended samples are retained in the data file.

The final candidate includes the global-alias and labeled-parameter shadow
guards. Its separate four-pair comparison against the original baseline is:

| Workload | RC wall, paired median | RC heap pointer | Bump wall, paired median |
|---|---:|---:|---:|
| Closure, cold | -8.9% | -2.9% | +3.1% |
| Closure, warm | -10.5% | -2.4% | +4.9% |
| CLI, cold | +5.2% | -2.0% | +2.6% |
| CLI, warm | -3.1% | -1.4% | +1.5% |

The final RC heap reductions reproduce in every sample. Wall time does not
establish a consistent improvement: CLI cold is slower in this run, and bump
also shows small increases. These remain within the observed control spread;
that is uncertainty, not proof that no regression exists. Keep watching the CI
performance report rather than claiming all builds are faster. The final bump
heap increases are below 0.005% on the closure and about 0.02–0.03% on the CLI.

Validation: 81 relevant compiler tests and 13 collector tests pass. Both
stage2 and stage3 agree byte for byte. The final RC compiler reproduces both
the RC and bump compiler artifacts. Runtime ownership probes agree in bump,
RC and RC-shadow. Full regression remains with CI; no benchmark task was
added to a required CI dependency.

**Decision:** keep both changes. The measured gain is fewer retains and lower
RC heap pressure; scratch reuse adds a small deterministic allocation saving.
Continue to measure wall time with paired controls before attributing small
changes to implementation cost. These results do not meet the RC cutover
criterion.

### Free-variable scope scratch, 2026-09-14

The next bounded scratch change reuses the lexical-scope array in
`collect_free_vars_indexed_sc`. The scope walk already pushes and truncates
names inside a query, but previously copied the parameter array and regrew
that new buffer on every query. Its private scratch now retains capacity
between queries and clears all names before returning. The walker only reads
AST data and cannot re-enter an indexed query; capture results keep their own
arrays. Capture rules, result ordering and the public API are unchanged.
Retained capacity is bounded by the largest scope visited in that compiler
instance, rather than by the number of queries; names do not survive a reset.

The allocation regression compares a warmed scoped query with a leaf query,
excluding AST construction and keeping result allocation on both sides.
Additional scope allocation falls from **32 bytes to 0**. Tests preserve input
arrays and earlier capture results across later calls, nested scopes,
labeled/optional parameters, enclosing shadows and the let-rec collision
fallback's second query.

The [raw measurements](compiler-free-var-scratch.json) record the compiler
identities, all comparison samples and separate CPU profiles. The baseline
includes the direct-recursion and binder-scratch changes above. Both compiler
runtimes generate linear RC targets; the ordinary strict output-equivalence
protocol applies. These are filesystem compiles of the compiler closure and
full CLI, not the complete seed-to-stage3 pipeline.

Four alternating pairs per workload/temperature on Node 24.21.0, Apple M5.
Wall columns show medians in seconds; the paired column reports the median
candidate/baseline ratio from individual pairs. Heap reductions are decimal MB.

| Workload | Bump wall, before → after | RC wall, before → after | Paired wall change, bump / RC | Heap-pointer reduction, bump / RC |
|---|---:|---:|---:|---:|
| Closure, cold | 1.992 → 1.980 | 6.064 → 6.028 | −0.6% / −0.3% | 1.98 / 3.47 MB |
| Closure, warm | 1.321 → 1.339 | 4.145 → 4.107 | +0.9% / −0.9% | 1.98 / 3.46 MB |
| CLI, cold | 5.126 → 5.116 | 14.240 → 13.734 | −0.2% / −3.3% | 3.52 / 6.04 MB |
| CLI, warm | 3.957 → 3.953 | 10.860 → 10.449 | −0.4% / −2.6% | 3.51 / 6.03 MB |

Heap reductions reproduce in every sample: 0.13–0.31% on bump and
0.23–0.52% on RC. **Linear-memory capacity is unchanged** in all comparisons.
Peak RSS medians fall only 0.1–0.4%; the data records RSS independently from
the heap pointer, rather than treating this as a large process-memory saving.
The same-artifact A/A control has exactly equal heap pointers and linear
capacities. All 96 comparison samples produce identical target Wasm within
each comparison workload, across both compilers, temperatures and rounds.

Wall improvements remain inconclusive. The A/A paired medians range from
−0.5% to +2.2%, with individual pairs spanning −8.3% to +4.1%. RC CLI cold
looks faster in aggregate, but its four pairs are +0.4%, +0.0%, −6.7% and
−7.1%. Separate RC profiles put the indexed query at 264 → 259 ms cold and
270 → 263 ms warm, including its callees; these single profiles do not
establish a large CPU reduction.

Validation: 62 related tests in 12 files pass, including ownership probes in
bump, RC and RC-shadow. Stage2 equals stage3, and the RC compiler reproduces
both compiler artifacts. Three closure fixtures also pass 17 tests per target
when rechecked with RC and RC-shadow. The full suite remains in CI, with no
additional timing jobs or required benchmark dependencies.

**Decision:** keep the small scope-storage change for its deterministic heap
reduction in both compiler runtimes. Keep the bump default and make no claim
of a consistent wall-time or linear-capacity improvement.

### Direct callee name scans, 2026-09-14

Free-variable analysis reconstructed an `EIdent` node to scan the name of a
direct call. It then recursively visited that temporary node and discarded it.
`collect_free_var_name` now accepts the existing name, and reads, callees and
assignment targets share its binding judgment. This removes both temporary
construction sites and the duplicated read/write logic without changing
capture order or the public API.

The helper preserves the precedence of local bindings, enclosing locals and
global names. The inline-builtin skip stays at call sites; a bare identifier
still counts as a reference. The used-builtin scan and the throw-payload
special case keep their existing behavior. A non-throw `perform` still builds
an `Option` while classifying its arguments: removing the temporary identifier
does not imply that every possible callee scan allocates nothing.

A regression compares a prebuilt direct call with a bare identifier using the
same name and binding context. On bump, the additional allocation drops from
24 bytes to 0 for both local-bound and global callees. RC's first query drops
from 32 bytes of heap-pointer growth to 0; its next query already reuses the
temporary's block on the baseline. The RC number measures heap growth, not
allocation volume.

The [raw measurements](compiler-free-var-callee.json) compare compilers built
from the latest main plus the scope-scratch change above, before and after
this direct-name change. That baseline isolates the new mechanism from the
earlier scratch work and intervening ownership fixes. Both runtimes generate
the same linear RC targets using the strict output-equivalence protocol.

Four alternating pairs per workload/temperature, Node 24.21.0 on Apple M5.
Wall columns show medians in seconds; the paired column is the median of the
individual candidate/baseline ratios. Heap changes are candidate minus baseline.

| Workload | Bump wall, before → after | RC wall, before → after | Paired wall change, bump / RC | Bump heap change | RC heap change |
|---|---:|---:|---:|---:|---:|
| Closure, cold | 2.003 → 2.070 | 6.192 → 6.190 | +0.3% / +0.1% | −3.33 MB | −2,456 B |
| Closure, warm | 1.392 → 1.361 | 4.225 → 4.209 | +0.1% / −1.0% | −3.32 MB | −1,152 B |
| CLI, cold | 5.221 → 5.184 | 13.867 → 13.838 | −1.7% / −0.1% | −5.69 MB | +7,624 B |
| CLI, warm | 4.074 → 4.227 | 10.522 → 10.422 | +1.9% / +0.0% | −5.69 MB | +5,256 B |

Bump heap reductions of 0.21–0.52% reproduce in every sample. RC heap
changes are tiny, including the CLI increases; none of the comparisons changes
linear-memory capacity. Peak RSS changes range from −0.31% to +0.14%, rather
than establishing a large resident-memory saving. A/A heap pointers and
linear capacities agree exactly. All 96 samples retain strict target-byte
equality within each comparison workload, across compilers and temperatures.

The generated RC visitor has two fewer allocator call sites (2 → 0).
Retain call sites across the visitor and new name helper fall from 318 to
302 (300 in the visitor, 2 in the helper). Separate RC profiles put the indexed query, including its
callees, at 239 → 202 ms cold and 248 → 200 ms warm. Those single profiles
support the reduction in local work, but do not establish a whole-build speedup.
Wall readings remain noisy: A/A individual pairs span −8.5% to +3.9%, and
the bump comparison has pairs as wide as −18.9% to +20.7%. These samples are
retained rather than filtered from the reported medians.

Validation: 79 related tests in 15 files pass, including Perceus plan checks,
shadowing, capture ordering and builtin import coverage. Four of those files
also pass 22 tests each under bump and RC-shadow. Stage2 equals stage3, and
the RC compiler reproduces both compiler artifacts. Formatter checks pass;
full regression remains in CI without new required benchmark jobs.

**Decision:** keep the direct-name scan for its bump allocation reduction and
simpler shared binding logic. The measured RC benefit is less work in the
profiled query, with effectively unchanged heap pressure. Keep the bump
default and do not claim a consistent wall-time improvement.

### Annotated local lambda inference, 2026-09-14

`fill_lambda_params` now returns immediately when every parameter already has
an annotation, including a lambda with no parameters. Call-site heap inference
only fills missing annotations, so walking the enclosing scope and building
call classifications could not change these lambdas. The top-level inference
entry already had the same guard. Local `ELet` and `ELetRec` now share it.

Recursive elaboration still visits a lambda's body before considering its
parameter annotations. An unannotated inner lambda therefore still receives
heap inference inside an annotated outer lambda. Mixed parameter lists retain
exact explicit annotations and continue to infer the missing ones.

The allocation regression compares two prebuilt ASTs with 128 calls in the
same continuation, with and without a lambda at the local binding. It allows
512 bytes for fixed rewrite costs and RC free-list reuse, but rejects the
unused call classification table. The baseline exceeds this budget in both
bump and RC. RC heap-pointer growth is not total allocation volume.

The [raw measurements](compiler-annotated-lambda-inference.json) compare the
previous direct-callee compiler with this guard, using the same final target
sources and the strict output-equivalence protocol. Both compiler runtimes
emit linear RC targets. These are filesystem builds of the compiler closure
and CLI, not timings for the complete seed-to-stage3 pipeline.

Four alternating pairs per workload/temperature, Node 24.21.0 on Apple M5.
Wall columns show medians in seconds. Paired changes are the median of the
individual candidate/baseline ratios; heap changes are decimal MB.

| Workload | Bump wall, before → after | RC wall, before → after | Paired wall change, bump / RC | Heap change, bump / RC |
|---|---:|---:|---:|---:|
| Closure, cold | 2.451 → 2.405 | 7.235 → 7.741 | +3.1% / −3.1% | −10.74 / −10.73 MB |
| Closure, warm | 1.591 → 1.571 | 4.447 → 5.130 | −1.1% / +16.9% | −10.74 / −10.73 MB |
| CLI, cold | 5.718 → 5.800 | 16.471 → 16.416 | +2.6% / +1.3% | −10.75 / −10.74 MB |
| CLI, warm | 4.529 → 4.490 | 11.333 → 12.382 | +1.6% / +4.2% | −10.76 / −10.75 MB |

Heap reductions reproduce in every pair: 0.40–1.70% on bump and
0.40–1.60% on RC. Linear-memory capacity is unchanged except for RC CLI warm, where it
grows by 1,900,544 bytes (+0.09%) despite the lower heap pointer. The geometric
growth policy in `lib/@vibe/compiler/codegen/wasm_emit/extra.vibe` depends on
the allocation sequence, so the heap pointer and final capacity are separate
metrics. A/A heap pointers
and capacities agree exactly. Peak RSS median changes range from
−1.2% to −0.4%; the report keeps resident memory separate
from the heap pointer. All 128 samples produce identical target bytes
within each comparison workload, across compilers, temperatures and rounds.

Wall time remains inconclusive. Individual A/A pairs span −5.8% to
+6.9%; bump pairs span −13.4% to +36.0%, and RC pairs
span −17.0% to +46.3%. All samples, including slow candidate
runs, remain in the report. Separate RC profiles put local lambda inference at
8.7 → 1.3 ms cold and 10.0 → 1.3 ms warm,
including callees. These single profiles are diagnostic, not extra wall-time
replicates.

The unexpectedly slow RC warm samples triggered another four RC closure pairs
and a matching RC A/A control. Individual pairs in that additional A/A control
span −12.8% to +74.7% even though both lanes use the same artifact. Both
follow-up comparisons remain in the raw report alongside the initial table.

| RC closure | Follow-up A/A paired change | Follow-up candidate paired change | Pooled eight-pair candidate change |
|---|---:|---:|---:|
| Cold | +0.5% | +7.4% | +3.0% |
| Warm | +6.9% | +6.1% | +6.1% |

These controls do not demonstrate a speedup or exclude a small regression.
A quieter host or the existing CI metrics must resolve wall-time performance.

Validation: 225 related tests in eight files pass; four files also pass
13 tests each under bump and RC-shadow. Stage2 equals stage3, and the RC
compiler reproduces both compiler artifacts. Formatter checks pass. Full
regression remains in CI with no new required benchmark job.

**Decision:** keep the small early return for the deterministic heap reduction
in both compiler runtimes. Keep the bump default; no consistent wall-time
speedup or reduction in allocated linear-memory capacity is established.

### Callee binding lookup, 2026-09-14

Direct-call free-variable analysis used to search the same local and global
name tables in both the inline-builtin filter and `collect_free_var_name`.
The name helper now resolves bindings once and applies the builtin skip only
when the caller requests it. The common argument walk also replaces two
identical loops. No public API or scratch-storage contract changes.

Local binders still precede enclosing locals, which precede globals and
builtin skipping. The skip applies only to capture callees: ordinary reads,
assignment targets and used-builtin queries preserve their prior behavior.
The `perform`/throw special case and recursive self-collision fallback keep
using the same lexical analysis. Regression tests cover builtin names shadowed
at all three levels, captured argument ordering, repeated names and the
used-builtin query's different treatment of inline calls.

A deterministic RC probe makes 100 queries over 256 direct global calls with
16 local names. Wasmtime fuel falls from 330,042,001 to 269,824,701 (−18.25%),
including setup. The baseline fails the 300-million-fuel budget and the
candidate passes. Both probe binaries were built by the same baseline
compiler around the source edit and print the same result. This is executed
Wasm instruction cost, not a wall-time prediction. The source, runner hash,
compiler hash and probe hashes are retained in the
[raw measurements](compiler-free-var-binding-lookup.json).

The build comparison uses the annotated-lambda compiler as its baseline.
Both compilers read the same final target source snapshot. Bump and RC compiler
runtimes both generate linear RC targets with names stripped. Each sample uses
a new process; cold starts with an empty isolated persistent cache and warm
reuses that cache. Compiler, cache and output paths have equal lengths across
lanes, and execution order alternates. These are filesystem builds of the
compiler closure and full CLI, not complete seed-to-stage3 pipeline timings.

Four alternating pairs per workload and temperature, Node 24.21.0 on Apple M5.
Wall columns are medians in seconds; paired changes are medians of individual
candidate/baseline ratios. Heap changes are bytes.

| Workload | Bump wall, before → after | RC wall, before → after | Paired wall change, bump / RC | Heap change, bump / RC |
|---|---:|---:|---:|---:|
| Closure, cold | 2.758 → 2.908 | 6.169 → 6.222 | +4.6% / +1.1% | −4,552 / −4,864 B |
| Closure, warm | 2.002 → 1.920 | 4.165 → 4.234 | −7.0% / +1.0% | −2,168 / −2,344 B |
| CLI, cold | 7.019 → 6.456 | 13.927 → 13.912 | −4.4% / −0.8% | −10,976 / −11,512 B |
| CLI, warm | 4.956 → 4.978 | 10.457 → 10.418 | −0.2% / −0.4% | −5,656 / −5,960 B |

Individual A/A wall pairs span −11.1% to +20.3% on bump and
−20.9% to +36.1% on RC. Candidate pairs span
−19.2% to +31.5% on bump and −10.8% to +12.4% on RC.
All samples remain in the report. A/A heap pointers and linear capacities
agree exactly; all 128 samples preserve target-byte equality within each
comparison workload across compilers and temperatures.

The heap reductions repeat in every pair but are only 2–12 KB (less than
0.001%); linear-memory capacity is unchanged in every condition. Peak RSS
median changes range from −0.08% to +0.28%, without a meaningful memory win.

Separate RC profiles put the complete indexed free-variable query at
210.5 → 176.3 ms cold (−16.2%) and 190.3 → 177.5 ms warm (−6.7%), including
callees. The helper itself now contains the builtin checks, so moving time
between it and its caller is not an optimization signal; these figures cover
the entire query. Each profile is a single diagnostic run, not an additional
uninstrumented timing replicate.

Validation: 84 related tests in 16 files pass; four files also pass 24 tests
each under bump and RC-shadow. Stage2 equals stage3, and the RC compiler
reproduces both compiler artifacts. Formatter and documentation checks pass.
Full regression remains in CI without a new benchmark job.

**Decision:** keep the smaller shared binding path for its deterministic
instruction-cost reduction and lower local query time. Whole-build wall time
remains inconclusive, including the slower closure readings; the small heap
changes do not establish a meaningful memory reduction. Keep the bump default.

### Region and native GC observations, 2026-09-14

The same bump compiler built the following fixtures in all three target
modes. Values passed before reading `__heap_ptr` around `_start`, with
`__no_entry__` compilation (the fixture's tests execute). These are **growth
measurements for existing implementations**, not before/after speedups.

| Fixture workload | Linear bump | Linear RC | Wasm-GC |
| --- | ---: | ---: | ---: |
| 200 regions × 500 list pushes | 6,408 B | 16,204 B | 3,208 B |
| 200 regions × 500 byte pushes | 8,008 B | 204,008 B | 3,208 B |

RC's low list growth is compatible with ordinary RC reuse; it does not prove
an arena exists there. Byte storage follows a different allocation path.
The byte-buffer result motivates a bounded scratch/RC-arena experiment, but
does not establish an end-to-end compiler win or safety for heap-valued lists.

Seven region fixtures passed on each backend: both boundedness cases,
release/nesting, list copy-out, byte copy-out, Exception unwind and local
capture provenance. Three escape probes (container, helper and closure)
were rejected with the expected region diagnostic. Two additional GC fixtures
passed: array churn emitted seven native `array.new_default` instructions;
the local-struct fixture emitted four user `struct.new` instructions plus
the runtime's reference-cell construction. GC live-heap/collection-pause
measurements remain unavailable. These focused checks do not replace full CI.

### Borrow-parameter fixed point, 2026-09-14

RC borrow inference now solves direct-call dependencies to a fixed point,
including deep wrappers and mutually recursive components. It starts with
globally eligible parameter bits and removes a bit when the existing ownership
judgment finds a consuming use. A reverse call graph schedules affected callers;
there is no arbitrary round cap. Global call-site disqualifiers apply before
iteration, and callee shadows are suppressed for each body. Captures, indirect
calls, aliases, duplicate declarations, and excluded entry points remain
conservative. Whole-program and module-link entries use the same solver.

This is ownership optimization, not the language safety borrow checker. It
changes caller retains and callee drops together; it does not change arena
lifetimes, the RC runtime, or the wasm-gc representation. The separate body-local
round-0 oracle remains available for module decomposition checks.

The Red case was an eight-wrapper reader chain: only its last two functions
were borrowed. The candidate classifies all eight in either declaration order.
A probe over the same baseline flat compiler AST changes `rewrite_expr`'s mask
from 0 to 22: `gens`, `traits`, and `dict_binds` become borrowed. `struct_sets`
and `fn_returns` remain owned; non-identifier call sites also keep `expr` and
`var_types` owned. This probe runs before later whole-program lowering.

The measured RC compiler contains **87,251 → 75,905 retain call sites**
(−13.0%); within `rewrite_expr`, **1,012 → 730** (−27.9%). Its Wasm size falls
from 5,675,999 to 5,517,647 bytes. A separate diagnostic profile measures the
borrow query, including descendants, at **235.7 → 127.8 ms cold** and
**219.3 → 122.0 ms warm**. Immediate `rewrite_expr` calls to `rc_dup` sample at
136.2 → 55.7 ms cold and 145.3 → 56.8 ms warm. Total `rc_dup` self time is
2,786.0 → 2,114.8 ms cold and 1,932.3 → 1,223.0 ms warm. These single profiles
explain where work changed; they are not additional wall-time replicates.

[Raw comparisons, controls, profiles, and validation](compiler-borrow-worklist.json)
contain four alternating pairs per workload/temperature, plus bump and RC A/A
controls: 128 samples on Node 24.21.0, Apple M5. Every cold sample starts with an
empty private cache; its warm partner is a new process using that populated
cache. Other compiler caches are disabled; the OS cache is uncontrolled. The
generated target always uses linear RC. The runtime column describes the
compiler executing the build.

| Compiler runtime | Input / cache | Wall median, before → after | Paired wall change | Heap-pointer change | Linear-capacity change |
|---|---|---:|---:|---:|---:|
| Bump | Closure / cold | 3.153 → 3.179 s | +0.6% | −8.551 MB | 0 |
| Bump | Closure / warm | 2.032 → 2.094 s | −2.4% | −8.550 MB | +6.881 MB |
| Bump | CLI / cold | 7.313 → 7.464 s | +3.0% | −0.797 MB | 0 |
| Bump | CLI / warm | 5.659 → 5.641 s | −4.7% | −0.796 MB | 0 |
| RC | Closure / cold | 7.001 → 6.005 s | −15.4% | −22.793 MB | 0 |
| RC | Closure / warm | 4.842 → 3.773 s | −20.7% | −17.765 MB | 0 |
| RC | CLI / cold | 15.337 → 15.373 s | +0.1% | −25.681 MB | 0 |
| RC | CLI / warm | 11.332 → 10.573 s | −12.7% | −16.653 MB | 0 |

Paired changes are medians of within-round ratios, not ratios of the two
medians. Heap and capacity deltas repeat exactly in all four pairs. Lower heap
consumption does not guarantee lower reserved capacity: the bump warm closure
reserves an additional 6.881 MB despite using 8.550 MB less heap. RC peak RSS
medians decline by 1.7–3.5%; bump declines by 0.1–0.7%, but the A/A CLI-cold RC
control itself reports a 14.1% RSS decline, so these are not established peak-RSS
savings.

Wall-time precision is limited by substantial shared-machine variation. A/A
pairs range from −31.9% to +7.4% for bump and −28.0% to +60.7% for RC, despite
exactly equal heap and capacity. The RC closure cold candidate is faster in all
four pairs and CLI warm in all four, but closure warm has a slower pair and CLI
cold shows no median improvement. Keep the complete samples and do not turn the
favorable medians into a guaranteed speedup or dismiss the bump cold increases.

Generated RC instructions intentionally differ across implementations. Each
compiler's outputs match across temperatures and rounds, and the bump/RC runtime
variants of each implementation produce identical targets. The measured closure
test exports execute successfully, and both generated CLI programs compile and
run the same recursive ownership probe with result `88`. The 267 related tests,
25 bump tests, and 25 RC-shadow tests pass; stage2 equals stage3 and the RC
compiler reproduces both RC and bump compiler artifacts.

The measured comparison isolates this change on #2791 (`886f3486f`). Afterward,
main's #2790/#2794 assignment-retain fixes were integrated at `702c134b7`, along
with contract comment corrections and removal of unused round-0 oracle state.
The rebased compiler passes 274 related
tests and 25 additional tests each in bump and RC-shadow, stage2 equals stage3,
and RC reproduces both compiler variants. The assignment-retain leak guard
uses 164 B over 20,000 iterations (limit: 2,000 B). The final oracle cleanup
passes another 36 related tests, stage2/stage3 equality, and RC reproduction of
both artifacts. Rebased artifacts and validation are recorded separately in the data file; the table does not
attribute those extra changes to the borrow worklist.

**Decision:** keep the fixed-point solver. It removes the one-round limitation,
reduces generated retains and deterministic heap consumption, and replaces the
separate production scans with less code. Precise wall-time and peak-RSS gains
remain uncertain. Keep the bump self-build default and existing CI performance
observations; no required CI job or benchmark dependency is added.
