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
