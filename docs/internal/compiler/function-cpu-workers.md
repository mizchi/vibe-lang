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
and the callback ABI. Rebuild them after selecting another compiler. The
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
