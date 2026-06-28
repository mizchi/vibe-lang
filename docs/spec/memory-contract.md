# Memory management contract (linear / wasm-gc / Perceus RC)

Status: draft (tracks issue #493). This document pins the *current*
behavior and records the intended direction: **wasm-gc stays the primary
target; when wasm-gc is not available, the linear backend uses Perceus
RC as its first (default) reclamation strategy**, replacing the current
"bump allocator, never free" default.

> **Selfhost note (2026-06-28):** the MoonBit host (`src/`) was retired in
> #594 (selfhost-only). The `src/*.mbt` paths cited below are historical;
> the live equivalents are under `vibe/compiler/` — in particular the
> Perceus RC analysis is now **ported to selfhost** at
> `vibe/compiler/perceus/index.vibe` (RC test `vibe/compiler/perceus_rc_test.vibe`,
> runnable RC bootstrap gate wired live via #556). Section D below — which
> previously stated the selfhost compiler has *no* Perceus/RC — is updated
> accordingly.

## Backend contract table

| | linear (today) | linear + Perceus RC | wasm-gc |
|---|---|---|---|
| default entry points | `compile --wasm`, `build --release`, `test`, `bench` | opt-in `enable_rc` (not CLI-exposed) | `compile --wasm-gc`, env opt-in for test/bench |
| value representation | tagged `i64` (2-bit tag) | same tagged `i64` | typed refs (struct / array), unboxed scalars |
| allocation | bump allocator | bump + head-only exact-fit free-list | engine heap |
| reclamation | **none (leaks)** | Perceus dup/drop, free on `rc==0` | engine GC (tracing) |
| object lifetime | n/a | deterministic, eager | non-deterministic, lazy |
| cycles | n/a | **leak (RC limitation)** | collected |
| known gaps | — | temporary/discarded-value drops, cycles, closure env drop (unverified), borrow inference scope, no wasmtime e2e gate | builtin parity (53 vs 169), coverage instrumentation, fixed-size arrays |
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

- **A-1 nested-block body drops** — *done*. Bindings that leave the scope
  of a nested block were not dropped, leaking per loop iteration / branch.
  Now wired for `while`, `for-in` (desugared before Perceus), `if`/`else`
  arms, `match` arms, and bare block expressions. The codegen threads the
  current statement site (`CodegenCtx.rc_stmt_site`) so each nested construct
  derives its Perceus action prefix, and `p2_emit_block` keys loop/branch
  scope-end drops to the last body statement. Regression tests assert
  per-iteration / per-branch balance via the `rc_debug` counters.
- **A-1b temporary / discarded-value drops** — *open*. Heap that is never
  bound to a name still leaks: builtin intermediates and discarded
  expression results (e.g. a `for-in`'s ArrayBuilder and its frozen result
  array when the loop is used as a statement). Constant w.r.t. iteration
  count, but a real remaining leak.
- **A-2 closure environment drop** — *done*. Closures that capture heap
  leaked their env block and the captured values. Two fixes: (1) Perceus
  treats a call as a *borrow* of the callee binding, so a closure stays
  live across calls and is dropped at scope end (top-level fn names /
  builtins resolve to no local binding, so this is a no-op for them);
  (2) `rc_has_closure` is now derived from the authoritative funcs list
  (any capturing closure) rather than a scan that used a mismatched span
  key for parameterized closures, so the RC drop helper actually emits its
  `obj_fn` capture-recursion branch. Verified balanced on the interpreter
  and correct on wasmtime (`rc e2e: closure capturing heap value`).
- **A-3 borrow inference scope** — only `__index` is recognized as a
  borrow; broaden to all borrowed parameters.
- **A-4 cycles** — RC cannot reclaim cycles. Decide policy: accept and
  document the leak, or add weak refs / a cycle collector. This is a
  permanent semantic difference from wasm-gc.

### B. Verification gaps

- **B-1** *done*. A wasmtime-backed RC e2e gate now exists
  (`src/tests/vibe_wasm_rc_e2e_test.mbt`, run via the `test-wasm-rc-e2e`
  task on `--target native`). It compiles representative programs with
  `enable_rc=true` and runs them on wasmtime, asserting correct results
  (incl. a 1000-iteration loop-stress checksum that would corrupt under a
  reuse-while-live bug). This immediately surfaced — and drove the fix
  for — an invalid `block`/`br_if` ordering in the rc_dup/rc_drop emitters:
  the tag-check condition was pushed *outside* the enclosing block, which
  the lenient in-tree interpreter accepted but wasmtime rejects ("expected
  i32 but nothing on stack"). RC had never produced spec-valid wasm before
  this gate.
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

- **Perceus RC is now ported to the selfhost compiler** (`vibe/compiler/`):
  the analysis lives at `vibe/compiler/perceus/index.vibe`, with an
  RC-mode linear compile path (`compile_source_wasi_only_rc` /
  `compile_wasi_module_rc`, opt-in via `VIBE_RC=1`) and a runnable RC
  bootstrap gate wired into the live gate (#556). The default selfhost
  linear backend is still a pure bump allocator that never frees; RC is
  opt-in, mirroring the (retired) host. Remaining selfhost-side work is the
  same correctness/verification/productization items in A–C above, now
  tracked against `vibe/` rather than the retired `src/` tree.

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
