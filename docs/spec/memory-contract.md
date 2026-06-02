# Memory management contract (linear / wasm-gc / Perceus RC)

Status: draft (tracks issue #493). This document pins the *current*
behavior and records the intended direction: **wasm-gc stays the primary
target; when wasm-gc is not available, the linear backend uses Perceus
RC as its first (default) reclamation strategy**, replacing the current
"bump allocator, never free" default.

## Backend contract table

| | linear (today) | linear + Perceus RC | wasm-gc |
|---|---|---|---|
| default entry points | `compile --wasm`, `build --release`, `test`, `bench` | opt-in `enable_rc` (not CLI-exposed) | `compile --wasm-gc`, env opt-in for test/bench |
| value representation | tagged `i64` (2-bit tag) | same tagged `i64` | typed refs (struct / array), unboxed scalars |
| allocation | bump allocator | bump + head-only exact-fit free-list | engine heap |
| reclamation | **none (leaks)** | Perceus dup/drop, free on `rc==0` | engine GC (tracing) |
| object lifetime | n/a | deterministic, eager | non-deterministic, lazy |
| cycles | n/a | **leak (RC limitation)** | collected |
| known gaps | — | while-loop body drop, cycles, closure env drop (unverified), borrow inference scope | builtin parity (53 vs 169), coverage instrumentation, fixed-size arrays |
| intended status | legacy / opt-out | **future linear default** | primary target |

## Intended direction

1. wasm-gc remains the main backend (ADR-0036) for engines that support
   the GC proposal.
2. For engines without wasm-gc, the linear backend should default to
   Perceus RC instead of the leaky bump allocator. This makes
   "no-reclamation bump" the explicit legacy / opt-out path.
3. A backend-selection step decides wasm-gc vs linear+RC; this selection
   logic does not exist yet (see gaps below).

## What already works (Perceus RC)

- Branch-sensitive dup/drop analysis, scope-end drops, reuse tokens
  (`src/frontend/perceus_poc.mbt`).
- Recursive field-drop for tuple / array / record / map / enum / view
  types (`src/codegen/wasm_codegen_rc.mbt:411-589`). Strings and bytes
  are leaf objects freed directly by the outer `rc_drop`.
- Borrow optimization for field-access-only bindings.
- Head-only exact-fit free-list reclamation.
- Binary-size optimization (ADR-0038, 1.95x → 1.49x) and code isolation
  (ADR-0049): RC code is confined to two files; the wasm-gc backend does
  not depend on it.

## Gaps to make Perceus RC the linear default

### A. Correctness blockers

- **A-1 while-loop / for-in body drops** — per-iteration `let` bindings
  are not dropped. Pinned as a known leak
  (`src/tests/vibe_wasm_eval_test.mbt:4228`). Top-priority blocker:
  loops are a hot path and must not leak for RC to replace bump.
- **A-2 closure environment drop** — `emit_rc_drop_fields` has no
  closure-specific branch; captured heap in closure envs needs
  wasmtime-level verification.
- **A-3 borrow inference scope** — only `__index` is recognized as a
  borrow; broaden to all borrowed parameters.
- **A-4 cycles** — RC cannot reclaim cycles. Decide policy: accept and
  document the leak, or add weak refs / a cycle collector. This is a
  permanent semantic difference from wasm-gc.

### B. Verification gaps

- **B-1** `enable_rc` is exercised only by the in-tree wasm interpreter
  (`src/tests/vibe_wasm_eval_test.mbt`); there is no wasmtime-backed RC
  e2e gate. Default-ing RC requires real-engine validation of
  free / free-list reuse.
- **B-2** `rc_debug` counters are interpreter-only.
- **B-3** No parity/gate test pins the RC default.
- **B-4** No differential test asserting that no-RC / RC / wasm-gc
  produce identical observable results — this is the concrete way to
  verify "linear+RC semantics match wasm-gc".

### C. Productization / wiring

- **C-1** `enable_rc` is not CLI-exposed and defaults false.
- **C-2** `build --release` / `test` / `bench` backend selection does not
  consider RC.
- **C-3** Free-list is head-only / exact-fit
  (`src/codegen/wasm_codegen_rc.mbt:204-245`): no coalescing, no
  segregated lists; fragmentation grows under long runs.
- **C-4** Stale doc comment: `wasm_codegen_rc.mbt:52-55` still says
  "free is a no-op (bump allocator)" although a free-list is
  implemented.
- **C-5** 8-byte RC header + dup/drop instruction overhead; benchmark
  before defaulting.

### D. Selfhost

- The selfhost compiler (`vibe/compiler/`) has **no** Perceus/RC. Its
  linear backend is a pure bump allocator that never frees. Making
  Perceus the selfhost default requires porting ~4100 LOC
  (`perceus_poc.mbt` + `wasm_codegen_rc.mbt`) to vibe, following
  src-first → parity gate → selfhost per CLAUDE.md.

### E. Semantics alignment with wasm-gc

- Memory model differs fundamentally (eager RC vs lazy GC) but, absent
  finalizers, observable program results can be made identical — verify
  via B-4.
- `Array::push` semantics already differ across backends (linear:
  in-place growable; wasm-gc: fixed-size, rebinds local). Orthogonal to
  RC but must be reconciled or documented before unifying defaults.
- Value representations differ (tagged i64 vs typed refs); RC does not
  change this, so RC alone aligns only lifetime observation, not
  representation. Remaining alignment is builtin parity, gated by
  `src/tests/codegen_parity_test.mbt`.

### F. Backend auto-selection

- There is no logic to detect "is wasm-gc available?" at build/run time
  and fall back to linear+RC. Without it, "wasm-gc else Perceus" cannot
  be automatic and RC stays manual opt-in.

## Relationship to issue #493

This advances #493 Direction C from option 2 (expose a flag) toward
option 2.5 (make RC the linear default). The contract table above is the
memory-management table requested by #493's acceptance criteria.
