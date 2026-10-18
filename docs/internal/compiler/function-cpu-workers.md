# Isolated CPU function generation

The experimental function route keeps ordinary whole-program checking and
lowering, prepares one canonical `LinkedFunctionPlan`, then emits disjoint
function ranges in native CPU worker processes. Each process owns a Wasmtime
Store, Instance and heap. Vibe `TaskGroup` owns waiting, failure and child
lifetimes through the existing opaque native CPU wave service. This provides
CPU parallelism across processes; it does not enable shared-memory threads or
concurrent entry into one compiler instance.

## Run in a checkout

Build images with the exact compiler selected by the CLI:

```sh
bash scripts/build_taskgroup_functions.sh /absolute/path/to/stage2.wasm
VIBE_CLI_WASM=/absolute/path/to/stage2.wasm \
  VIBE_UNSTABLE=1 VIBE_TASKGROUP_FUNCTIONS=1 \
  vibe build --jobs 4 main.vibe -o main.wasm
```

`VIBE_FUNCTION_ARTIFACT_DIR` selects another image directory.
`VIBE_FUNCTION_TRACE_OUT` writes a diagnostic timing report. Images are bound
to compiler and runner hashes, individual artifact hashes, payload versions
and the callback ABI. Callback ABI 2 requires allocator-correct SIMD BLAKE3;
rebuild ABI 1 images even when compiler and runner hashes are unchanged.
Rebuild them after selecting another compiler. The
ordinary command and the existing checker-worker route retain their defaults.
This experiment accepts `.vibe` core builds, target RC, and 1/2/4 workers.
Coverage, debug instrumentation, wasm-gc, persistent body-cache replay,
`--minify` and simultaneous module-lowering workers are refused. A failure
preserves the previous output and never falls back to another compiler route.
Installed-toolchain packaging is subsequent work.

## Ownership and transport

`@vibe/function_build` is the synchronous parent entry. Its scoped executor
receives the plan after normalization and lambda planning, before body output.
The ordinary compiler installs no executor and imports no native CPU service.
`@vibe/function_worker` is a separate build unit with codecs and the worker
entry. Its values contain mutable arrays and Bytes; they are not `Send`.

The parent sends shared tables once: function and constructor identities,
layout facts, the canonical string pool, lambda ranges, codegen flags, origin
maps and diagnostic locations. It omits the original merged statement AST.
The exception-presence fact is computed before constructing body inputs.
Each job carries only its assigned normalized bodies and source type hints.
A decoded context initially has unloaded body slots; a job validates its
whole payload before replacing the previous loaded range, and emission refuses
an unloaded range. This avoids replicating the whole normalized AST in every
worker and keeps the CLI corpus within the separate 64 MiB context and
64 MiB outstanding-job bounds.

Medium and large AST literals can reference the already checked shared string
pool. The encoder uses the existing content index and verifies the proposed
entry against the immutable pool before writing a reference. Missing or stale
lookups use ordinary string bytes. The checked decoder retains UTF-8, range
and input-boundary validation. Ordinary AST binary v4 cache bytes retain their
grammar; only versioned private worker envelopes opt into references.
String appends currently use a bounded byte-wise reference writer, not a
bulk-copy String ABI.

Context format 6 also interns repeated function identities in metadata. The
literal pool and `all_fn_names_list` are written as ordinary checked strings
first. Subsequent name arrays and map keys can reference that function-name
pool; names shorter than 16 bytes and names absent from it stay inline.
References keep the canonical array positions and first-occurrence behavior.
The decoder owns the initial UTF-8 strings, checks every reference index, and
shares only those immutable strings within its private heap. Per-job literal
references still use the original runtime-literal pool, independently of this
metadata pool. Source locations and product validation are unchanged.
Context format 7 adds the closure / ref-cell flag that narrows `rc_drop`'s
arms (`rc_closure_arms`, next to `rc_map_arms`). The build receipt and frontend
require context format 7; older images must be rebuilt. This transport change
does not enable native threads or select workers for the bootstrap.

Source locations are another input, independent of function ASTs. Division
guards consult the merged-source location table, so omitting it changes the
generated guard instructions and their line maps. The compact snapshot carries
paths, source ranges, synthesized-source placement flags and newline offsets.
A scoped override restores the previous location lookup on success and
exception. Workers receive no duplicate full source texts for this lookup.

The parent reuses one owned input buffer. Native input/context receipts bind
each result to its exact input, and product checks run before publication into
module tables. Checks cover complete function identity and range, lambda
coverage and ownership, aligned metadata, paired funcref/blind-reference logs,
known table slots, body-relative offsets, and line-map rows. The coordinator
replays complete products in canonical order and publishes the output only
after module validation and source freshness verification succeed. Coverage
ranges remain unplanned, so coverage builds use the ordinary serial route;
explicitly selecting this experiment with coverage is an error.

Within each owning function, lambda rows must follow their increasing planned
indices. Different owners may interleave, and complete function ranges may
arrive in reverse order. Both replay implementations append an owner's rows
rather than sorting them, so the validator checks that each nonfirst lambda's
predecessor has already appeared before any coordinator table is changed.
This enforces the existing replay contract without changing the wire format.

## Replay and engine policy

Auxiliary cache rows previously required a full scan per replayed function.
A stable owner index now groups lambda, table-slot, blind-reference and
line-map row positions once. Replay preserves the reference scan's row order,
including sparse owners and reversed slice merges, with total work linear in
functions plus metadata. The old scan remains an equivalence oracle and the
fallback for an owner outside the indexed key space. Ordinary compilation
without cache hits allocates no auxiliary replay index. Persistent cache
filtering still happens before index construction.

Core compiler and worker images follow the bootstrap compiler's bump allocation
policy. The Async coordinator remains RC. Target RC is a separate setting:
building an RC target does not require an RC implementation of the compiler.
The native service supplies tagged callback Int arguments; the bump parent
explicitly decodes that boundary. The build receipt records this ABI and all
three engine policies. Using an RC parent as the serial control confounded
early experiments by approximately doubling its compile time.

## Validation and measurement

`pkf run test-taskgroup-functions` builds images and exercises the real public
CLI at 1/2/4 workers. It compares complete Wasm and executes subtraction,
builtin shadowing, division, nested closures, exceptions, long unpooled
identifiers and a large Unicode literal. Refused settings, trace aliases, changed images, stale callback ABI,
invalid source and a receipt-bound trapping native worker preserve previous
output. Compiler tests compare snapshot/range replay in both target RC modes,
run under shadow RC, and reject malformed jobs/products before mutation.
A Red/Green probe removes the location snapshot and confirms that parity fails.
Indexed replay is compared with the old scan across interleaved and sparse
owners, out-of-index fallback and disabled line maps.

The [measurement receipt](../../../bench/perf/analysis/native-function-workers-2026-10-17.json)
distinguishes ordinary compilation, the same-driver serial control, and
1/2/4-worker complete builds. Promotion requires repeated cold/warm walltime
and aggregate process-tree RSS, with native compilation caches primed, isolated
guest caches, one frozen corpus and complete output equivalence. Worker-phase
timings alone are not a whole-build speedup. The route remains opt-in while
transport, worker setup and coordinator costs exceed the saved emission time.
The report's `finalize_ms` includes canonical replay and module assembly;
external walltime also includes frontend verification and publication.

The [2026-10-18 transfer report](../reports/function-worker-transfer-2026-10-18.md)
records 120 alternating before/after complete builds for metadata interning.
Context size and worker allocations fall; whole-wall changes remain below the
5% threshold and the parallelism memory/overhead gates still fail. Its raw
record separates retained wire buffers, owned decoded strings, reserved pages
and simultaneous RSS, including the parent floor after workers exit.

The [bounded context-verification report](../reports/function-context-verification-2026-10-18.md) records 132 further controlled builds on the same fixed corpus, with matching receipts for the differing native runners. Post-wave SHA-256 verification now uses a fixed 64 KiB scratch buffer before product reads; same-length edits, truncation and extra bytes preserve old output on refusal. All outputs and A/A controls agree, but whole-build walltime and peak RSS show no improvement. Parent preparation, transfer and replay costs remain blockers.

## Reproduce the selfbuild baseline

The `compiler` bootstrap workload runs `scripts/generations.sh build --stage3`,
including source generation and validation. The `portable-cli` workload runs
`scripts/build_cli_wasm.sh` with its artifact cache disabled: it rebuilds the
flat adapter with entry `main` through stage2. Their dependency stages remain
serial. The function-worker matrix separately compiles a compiler-sized test
closure and `lib/@vibe/cli/entry.vibe` through the filesystem compiler.

The current bootstrap invokes the low-level `cli_main` directly. The function
executor is installed by the separate `@vibe/function_build` parent image.
Worker selection therefore needs the integration tracked by #3485 before it
can change the bootstrap critical path.

Default bootstrap stages emit a bump target (`VIBE_RC=0`); the current native
function frontend, parent executor and service accept target RC1. Integration
also needs validated support for the bootstrap's emitted target. Compiler-engine
allocation and emitted-target allocation are separate decisions, so changing
the target merely to enter the experimental route would change the workload.

On Linux with Python 3.12+, Node and the pinned Rust toolchain, prepare a current
runner first, then run these commands sequentially on an idle host:

```sh
bash scripts/ensure_seed.sh
bash scripts/ensure_viberun.sh
baseline_workspace=_build/selfbuild-baseline
python3 bench/perf/selfbuild_baseline.py prepare "$baseline_workspace" --ref HEAD
python3 bench/perf/selfbuild_baseline.py clock "$baseline_workspace"
python3 bench/perf/selfbuild_baseline.py bootstrap "$baseline_workspace"
python3 bench/perf/selfbuild_baseline.py images "$baseline_workspace"
python3 bench/perf/selfbuild_baseline.py matrix "$baseline_workspace"
python3 bench/perf/selfbuild_profiles.py named "$baseline_workspace"
python3 bench/perf/selfbuild_profiles.py ordinary "$baseline_workspace"
python3 bench/perf/selfbuild_profiles.py parents "$baseline_workspace"
python3 bench/perf/selfbuild_profiles.py workers "$baseline_workspace"
python3 bench/perf/selfbuild_profiles.py memory "$baseline_workspace"
python3 bench/perf/selfbuild_profiles.py startup "$baseline_workspace"
python3 bench/perf/selfbuild_profiles.py validation "$baseline_workspace"
python3 bench/perf/selfbuild_profiles.py summarize "$baseline_workspace"
```

Use a fresh workspace for a new experiment. The drivers retain raw logs,
source/seed/image receipts, stage fixed points, process samples and profiles;
existing measurement directories are preserved. Bootstrap cold samples start
with an absent merge-tool image and a fresh guest cache. Warm samples retain
both while regenerating every stage output. The matrix primes native machine
code with another input and isolates each parsed-source cold/warm pair;
checked-module, body and final-artifact caches are off. Each configuration has
at least three samples with alternating order.

Walltime uses a monotonic clock. `VIBE_TRACE_MONOTONIC=1` gives the same clock
to host spans across processes; the recorded host-only instrumentation patch
allows an older archived source to use this clock too. Realtime clock steps
under WSL can corrupt a duration even when both timestamps look valid.
`trace_report.mjs` refuses a tree with mixed clock origins. CPU profiles and
captured worker replays run after the timed matrix. Their timings describe
instrumented diagnostics and do not enter the walltime budget.

The small-input startup controls use empty guest caches on both sides while
comparing cold and reused native machine code. They report the net cache/JIT
effect for the complete driver. The validation probe separately checks whether
a seed compile of the same flat source reproduces the measured stage1 bytes;
any reuse implementation still needs source, option and publication receipts.

`pkf run test-selfbuild-measurement` tests receipt refusals, exact capture,
profile attribution and clock behavior. It is part of `release-check`; CI also
runs these tests before building the compiler. This task does not run the
long measurement itself.

## Feedback to the language and libraries

These are proposals, not existing language guarantees:

1. A CPU execution capability for `TaskGroup`, with bounded parallel map and
   the same cancellation/join rules. Cooperative `Async` tasks alone cannot
   parallelize a CPU-bound compiler function. Scheduling should accept owned
   input and return owned results without a compiler-specific host intrinsic.
2. Derived, bounded wire codecs and explicit immutable snapshots. The manually
   maintained body-input codec shows the cost of transporting large typed
   records. A frozen outer array alone does not make nested mutable AST arrays
   `Send`; ownership and deep immutability need explicit representation.
3. A safe bulk UTF-8 append into Bytes. Private inline-Wasm functions currently
   cannot accept String parameters, so transport uses a byte-wise writer.
   A supported primitive should check capacity before mutation and preserve
   the String lifetime on both allocation policies and the GC backend.
4. Explicit task-local diagnostic/compiler context. The missing source-location
   table demonstrated that isolating mutable output does not capture readonly
   instance globals. Scoped context propagation should make that dependency
   visible when CPU jobs are created.
