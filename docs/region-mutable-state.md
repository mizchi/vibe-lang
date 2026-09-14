# Region-bound mutable storage (ADR-0090)

`region r { ... }` introduces a fresh lifetime token for mutable collection
storage. `MutList` and `MutBytes`, copy-out exits, escape checks, and arena
reclamation on the linear bump and Wasm-GC backends are implemented. Dedicated
arena allocation under Perceus RC and region variables in public effect rows
are not implemented.

This document describes the current contract. See
[memory management](spec/memory-contract.md) for backend selection and
[compiler memory experiments](internal/compiler-memory-experiments.md) for
measurement and adoption criteria. ADR-0090 supersedes ADR-0060's proposed
retrofit of `Write[r]` onto ordinary `let mut`.

## Language surface

The parser lowers `region r { body }` to an immediate `__region_run` lambda.
The checker binds `r` to a fresh rigid skolem **before** checking the body;
local generalization cannot quantify that lifetime away. The token is
second-class: constructors require the actual region token, and cannot accept
an arbitrary integer or a token forwarded through a generic parameter.

| Collection | Operations | Copy-out exit |
| --- | --- | --- |
| `MutList[T, r]` | `empty(r)`, `push`, `get`, `length`, `truncate` | `freeze` to `FrozenArray[T]`; `to_array` to `Array[T]` |
| `MutBytes[r]` | `empty(r)`, `push`, `append`, `length` | `to_bytes` to `Bytes` |

These operations are compiler-recognized calls. `MutList` element inference
still uses a tolerant `CtUnknown` slot; it is not a fully inferred generic
collection API. Explicit constructor type application and taking the region
builtins as first-class values are outside this implementation's supported
surface. `MutMap` and `MutSet` are not implemented as region collections.

`MutList::freeze` / `to_array` and `MutBytes::to_bytes` copy the backing storage
to the ordinary heap. Later writes to the mutable buffer cannot change an
already copied result. This is a storage copy, not a recursive clone of all
elements. It also ensures the returned buffer does not point into storage
that the region will reuse. `FrozenArray::from_array` is a different operation
and must not be used to infer these exits' implementation.

Normal heap allocation inside a region keeps its normal lifetime. Allocation
routing follows the collection operation and the buffer's storage, rather
than switching every allocation in the dynamic scope to the arena.

## Escape checking

Region-dependent values must remain within their lifetime. Current checks
include returned values, outer assignments, aggregate/container writes, and
closures carrying region-dependent captures. Capture provenance is retained
in checked function types (#1938); enforcement is no longer only a check of
the terminal lambda's syntax. The negative `fixtures/err_region_escape_*`
cases and positive region-local closures in
[`tests/gates/late/run.sh`](../tests/gates/late/run.sh) pin these paths.

Key implementations are the `__region_run` / collection branches and the
region-sensitive call/write/capture checks in
[`checker.vibe`](../lib/@vibe/compiler/checker/checker.vibe).
The parser-generated literal lambda receives the bind-before-check handling;
the internal non-literal `__region_run(f)` fallback is not a public lifetime
API and does not provide the same generalization guarantee.

This is not yet the proposed public effect-row contract `with r`. The
checker's implementation also records a limitation in attributing the region
lambda body's effects to its enclosing function. Do not describe lifetime
checking as completed region-effect inference, or extend the allocation scope
on that assumption. Ordinary `let mut` retains its existing closure-capture
semantics.

## Arena implementation

| Backend | Region collection storage |
| --- | --- |
| Linear bump (`VIBE_RC=0`) | Dedicated linear-memory arena |
| Linear RC | Ordinary collection allocation; no dedicated arena |
| Wasm-GC | Dedicated linear-memory arena; these buffers are not native GC objects |

The layout is shared through helpers in
[`common_base.vibe`](../lib/@vibe/compiler/codegen/common_base/common_base.vibe):

```text
bump pointer | nesting depth | 64 saved pointers | aligned 256 KiB data segment
```

- The arena is reserved separately from the main heap when the module uses a
  region. It does not reset the main `__heap_ptr`.
- Region entry saves the arena pointer. Exit restores it, allowing subsequent
  regions to reuse the storage. Nested regions restore in LIFO order.
- `MutList` and `MutBytes` allocation and regrowth use the arena while space
  is available. Regrowth checks the existing buffer's address to choose its
  allocation path.
- Capacity overflow falls back to the main bump heap. Nesting deeper than
  64 skips that level's save/restore; an enclosing saved watermark can still
  reclaim the storage later. These cases reduce reclamation rather than
  overwrite live storage.
- Both backends restore on normal exit and Exception unwind (#1937), using
  the backend's Exception tag. This does not establish equivalent cleanup
  for every algebraic-effect suspension/unwind route.
- Resetting the pointer makes bytes reusable; it does not shrink Wasm linear
  memory or return the segment to the OS or an RC free list.

Region bodies can still allocate closure environments, ordinary heap values,
and copy-out results. The arena does not imply constant total heap usage for
an arbitrary loop, and it is not an arena for the compiler's entire AST.
Likewise, reclaiming buffer storage does not reclaim an arbitrary cyclic graph
of ordinary heap objects stored in the buffer.

The backend setup is in
[`linked_compile.vibe`](../lib/@vibe/compiler/codegen/wasi/linked_compile.vibe)
and [`backend_body.vibe`](../lib/@vibe/compiler/codegen/gc/backend_body.vibe).
The GC backend's `MutList` / `MutBytes` paths use the same linear arena
despite native GC allocation being available for other values.

## Requirements for an RC arena experiment

RC currently disables the dedicated arena. An arena block must not enter the
ordinary free list: a later bulk reset could otherwise allow the same bytes
to be allocated twice.

A candidate implementation must preserve both sides of ownership:

1. Keep arena blocks out of the normal free list, including replaced growth
   buffers. `emit_rc_free_push` is a candidate integration point, not a
   completed implementation.
2. Preserve the RC representation/header contract, or explicitly implement a
   distinct representation at every operation that can consume it.
3. Keep required releases of **ordinary RC objects referenced by elements**.
   Returning early from `rc_drop` solely because a buffer lies in the arena
   can leak its children. Bulk storage reuse alone does not justify removing
   all retain/release operations.
4. Cover regrowth, copy-out ownership, shared elements, nested regions,
   capacity overflow and Exception unwind with value and reclamation checks.

`MutBytes` and `MutList` have different ownership/layout requirements; a
byte-buffer experiment cannot establish safety for reference-bearing lists.
Run this as an opt-in experiment and measure end-to-end compile cost before
changing a default. Broader AST arenas additionally need a proven phase
boundary and handling for values that survive that boundary.

## Existing observations and checks

- `fixtures/region_arena_bounded.vibe`: 200 regions, 500 list pushes each.
- `fixtures/region_bytes_arena_bounded.vibe`: 200 regions, 500 byte pushes each.
- `fixtures/region_arena_release_ok.vibe`: reuse, nesting, growth, and ordinary
  heap values that may leave the region.
- `fixtures/region_ok_freeze_copies_out.vibe`: independence of copied results.
- `fixtures/region_throw_unwind_test.vibe`: repeated Exception cleanup.

[`region_arena_heap_delta.mjs`](../scripts/region_arena_heap_delta.mjs) reads
the main heap pointer around `_start`. Value snapshots alone cannot detect
an arena that stopped reclaiming, so the late gate checks linear bump
reclamation and the mid gate checks GC reclamation independently. These are
linear-heap observations, not native GC liveness measurements. Current
measurements and their exact compiler identities are recorded in the
[experiment record](internal/compiler-memory-experiments.md).

The first useful compiler workloads to investigate are scratch buffers whose
contents are consumed inside the region and only a small result escapes.
When the whole accumulated buffer must leave, measure the copy-out and
segment-reservation cost as well as the saved growth allocations.
