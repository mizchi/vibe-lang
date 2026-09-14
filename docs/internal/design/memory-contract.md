# Memory management contract

This is the current contract of the selfhost compiler. Experimental changes
and their acceptance evidence belong in
[compiler memory experiments](compiler-memory-experiments.md).

## Three mechanisms, two code-generation backends

- **Bump allocation / arenas** allocate sequentially. The main bump heap keeps
  allocations until the host tears down the execution environment. A separate
  region arena restores a saved pointer at scope exit and reuses its storage.
- **Perceus** is compiler ownership analysis and RC insertion/optimization.
  The linear RC backend emits retain/release and reuse operations; its runtime
  maintains object counts and free lists. Its allocator still bumps the main
  heap when no reusable block is available.
- **Wasm GC** provides engine-managed typed references. The GC backend emits
  native structs and arrays for eligible values. Other values still use the
  guest's linear memory, which Wasm GC does not collect object by object.

Perceus does not manage native Wasm-GC references. The embedding engine owns
their collection policy; the name "GC" does not prescribe a tracing algorithm
or a deterministic collection time.

| Property | Linear RC | Linear bump | Wasm-GC backend |
| --- | --- | --- | --- |
| Ordinary selection | Default; `VIBE_RC=1` | `VIBE_RC=0` | `VIBE_BACKEND=gc` at the compiler adapter |
| Representation | Tagged `i64` values and RC object headers; boxed floats where required | Untagged scalar values and linear heap pointers | Typed references for eligible structs/arrays; linear `i64` fallback elsewhere |
| Ordinary allocation | RC allocator / free-list reuse / bump fallback | Main bump heap | Engine-managed objects plus main linear bump heap |
| Individual release | Perceus-generated RC operations on managed objects | None | Engine-managed references only; no Perceus RC on the linear fallback |
| `region` collection storage | Dedicated arena **disabled**; ordinary collection allocation | Dedicated arena **enabled** | Dedicated arena **enabled in linear memory** |
| Cycles | RC alone cannot reclaim reference cycles | Retained until teardown | Native reference graphs are engine-managed; linear fallback remains outside that management |

The table describes normal compilation, without coverage/debug instrumentation.
`fs_lane_request` and `ss_lane_request` in
[`cli_adapter.vibe`](../../../lib/@vibe/compiler/cli_adapter.vibe) choose the
backend. GC selection precedes RC selection: setting `VIBE_RC=1` alongside
`VIBE_BACKEND=gc` does not add Perceus to the GC backend.

## Compiler execution versus generated program

The memory mode of a **running compiler** is fixed in its Wasm artifact.
`VIBE_RC` and `VIBE_BACKEND` passed to that compiler select the **program it
generates**. They do not rewrite the running compiler's allocator.

- Ordinary user-program compilation defaults to linear RC.
  [`check_rc_default.sh`](../../../scripts/check_rc_default.sh) checks that unset
  `VIBE_RC` and `VIBE_RC=1` produce identical output, distinct from bump.
- [`generations.sh`](../../../scripts/generations.sh) defaults the compiler
  self-build to `VIBE_RC=0`, while accepting an explicit override. Performance
  comparisons must therefore supply separately built compiler binaries.
- `vibe compile --wasm` / `--wasm-linear` use the normal compilation route.
  The explicit `--wasm-gc` compile flag is still rejected by
  [`dispatch.vibe`](../../../lib/@vibe/cli/dispatch.vibe), although the compiler
  adapter already accepts `VIBE_BACKEND=gc`.
- `VIBE_TEST_BACKEND=gc` and `VIBE_BENCH_BACKEND=gc` select the public GC
  test/bench routes. These resolve the filesystem import graph before final
  code generation; they are not restricted to a flat single source. Runtime
  capability/builtin parity remains a separate limitation, tracked in
  [`builtin_parity_classification.tsv`](../../../scripts/builtin_parity_classification.tsv).

An RC compiler reproducing its own artifact is useful evidence, but a bump
generation reaching a fixpoint does not establish that fact. In particular,
[`test_rc_bootstrap.sh`](../../../scripts/test_rc_bootstrap.sh) currently checks
fixpoint metadata without proving RC mode. Its default build inherits the
generation script's bump default. Record the actual compiler hashes and build
selectors when reporting RC self-hosting.

## Region arena boundaries

The arena stores `MutList` and `MutBytes` buffers, not every allocation made
inside a `region`. Ordinary tuples, strings and other values allocated in its
body retain their ordinary allocation path and may outlive the region.

Both the linear bump and GC backends reserve a separate **256 KiB** segment
when a module uses `__region_run`. They save/restore watermarks for up to
64 nested regions. Overflow allocations fall back to the main heap, and deeper
nesting skips that level's save/restore. Normal exit and Exception unwind
restore the arena; this is logical reuse, not shrinking linear memory or
returning pages to the OS. Copy-out results are allocated outside the arena.

The linear backend's `need_region_arena` explicitly requires `!enable_rc` in
[`linked_compile.vibe`](../../../lib/@vibe/compiler/codegen/wasi/linked_compile.vibe).
The GC backend enables it in
[`backend_body.vibe`](../../../lib/@vibe/compiler/codegen/gc/backend_body.vibe)
because these collection buffers are still linear-memory objects. See the
[region contract](region-mutable-state.md) for escape rules, exit coverage,
and prerequisites for an RC experiment.

## What the GC backend currently represents natively

[`backend_expr.vibe`](../../../lib/@vibe/compiler/codegen/gc/backend_expr.vibe)
emits `struct.new` and `array.new_default` for eligible typed bindings.
Supported cases include concrete local structs, local integer arrays, and
selected direct-call parameter/result/alias paths. Generic ABI crossings,
deeper closure captures, growable array operations, and initializer frames
can retain the linear representation. An array's native representation is
conditional on its uses, not merely its source-level type.

Existing checks distinguish these cases:

- [`gc_struct_opcode_snapshot_test.vibe`](../../../lib/@vibe/compiler/tests/gc_struct_opcode_snapshot_test.vibe)
  decodes emitted instructions for native struct construction/access.
- [`test_gc_heap_accounting.sh`](../../../scripts/test_gc_heap_accounting.sh)
  checks native array lowering and direct-call/fallback cases. Its heap-pointer
  check proves reduced **linear** allocation, not GC liveness.
- Region value, reclamation and Exception-unwind checks run on the GC backend
  in [`tests/gates/mid/run.sh`](../../../tests/gates/mid/run.sh).

## Reading memory measurements

| Metric | Meaning | Does not establish |
| --- | --- | --- |
| `__heap_ptr`, or its delta | Main linear allocator frontier / growth | Live objects; total allocation under RC reuse; region churn; native GC heap size |
| Linear memory pages / bytes | Current guest linear-memory capacity | Resident memory or live-object size |
| End RSS | Process resident memory at the reading | Peak memory or guest-only memory |
| Peak RSS | Peak resident memory reported by the host OS | Which allocator owns the memory; directly comparable values across engines/OSes |
| Native GC heap / collection data | Requires engine-specific telemetry | Anything, when no measurement was taken; record it as unavailable |

An arena may repeatedly allocate without moving `__heap_ptr`; RC may reuse
blocks without moving it; a native GC allocation may never touch it. Therefore
zero heap-pointer growth alone is not a proof of zero allocation or no leaks.
Correctness checks, memory readings and uninstrumented wall measurements are
separate evidence. For linear RC's residual limitations, see
[the RC default](rc-cutover-readiness.md).
