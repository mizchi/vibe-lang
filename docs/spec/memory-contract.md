# Memory management contract (linear / wasm-gc / Perceus RC)

Status: living spec (tracks issue #493). This document pins the *current*
behavior of the **selfhost** toolchain (`lib/@vibe/compiler/`, `vibe/cli/`) and
records the intended direction. The retired MoonBit host (`src/`, #594) is
referenced only as historical context; nothing in `src/` is reachable from
the production CLI anymore.

Intended direction in one line: **wasm-gc is the long-term primary target;
the linear backend stays the production default and is gaining Perceus RC
so its "bump allocator, never free" leak becomes opt-out rather than the
only behavior.**

## Backend contract table (selfhost)

| | linear (today / default) | linear + Perceus RC (in progress) | wasm-gc |
|---|---|---|---|
| selfhost CLI entry | `compile --wasm` / `--wasm-linear`, `build --release`, `test`, `bench` | env opt-in `VIBE_RC` → `compile_source_wasi_only_rc`; **not** CLI-exposed | **not wired in the selfhost CLI** (`compile --wasm-gc` throws "not supported by selfhost cli yet"); reachable only via `VIBE_TEST_BACKEND=gc` / `VIBE_BENCH_BACKEND=gc` for host-import-free test/bench |
| value representation | tagged `i64` (2-bit tag) | same tagged `i64` | linear-memory layout for tuple/struct/ctor + wasm-gc `struct`/`ref` for refcell/closure |
| allocation | bump allocator | bump + (planned head free-list) | engine heap |
| reclamation | **none (leaks linearly)** | Perceus dup/drop (analysis complete; drop **codegen Phase 3 WIP**) | engine GC (tracing) |
| object lifetime | n/a | deterministic, eager (once Phase 3 lands) | non-deterministic, lazy |
| cycles | n/a | **leak (RC limitation)** | collected |
| known gaps | — | uniform object header only partly landed (tuples done, arrays/enums/closures pending); no drop emission yet; no wasmtime RC e2e gate | HOF / Iterator codegen gaps (`docs/spec/iterable-touch-points.md`); builtin parity; not CLI-reachable |
| intended status | production default | future linear default (opt-out leak) | long-term primary target |

The defaults above are exercised by the selfhost gate
(`scripts/compiler_gate.sh`), which compiles, runs, and self-reproduces
through the linear `--wasm` path; the RC analysis path is exercised by
`lib/@vibe/compiler/perceus_rc_test.vibe` (`test-selfhost-perceus`).

## Current CLI behavior (pin)

- `vibe compile --wasm <f>` / `--wasm-linear` → **linear** backend.
- `vibe compile --wasm-gc <f>` → **throws** (`vibe/cli/selfhost.vibe`); the
  wasm-gc backend lives in `lib/@vibe/compiler/codegen/gc/` but is not selectable
  from the compile CLI. `#683` / `#415` track making it CLI-reachable and
  parity-gated.
- `vibe build --release` → linear (same codegen as `compile --wasm`).
- `vibe test` / `vibe bench` → linear by default; `VIBE_TEST_BACKEND=gc` /
  `VIBE_BENCH_BACKEND=gc` opt into wasm-gc for pure (no HTTP/FS) cases.
- `VIBE_RC=1` selects the experimental RC preprocessing path
  (`compile_source_wasi_only_rc`); not surfaced as a CLI flag.

> README note: the README "Runtime Targets" table historically described the
> MoonBit-host `vibe_compile_wasi` where `--wasm` selected wasm-gc. That is no
> longer true for the selfhost CLI; the table has been corrected to match the
> behavior pinned here.

## Perceus RC status (selfhost) — experimental, in progress

RC was **ported to selfhost** (it is no longer src/-only), but the
reclamation half is not finished. Detailed staged plan:
[rc-port.md](rc-port.md); readiness:
[selfhost-rc-cutover-readiness.md](selfhost-rc-cutover-readiness.md).

- **Phase 1 — uniform object header (prerequisite):** *started*. RC's drop
  helper needs a `[type_id][length]` header to recurse; the selfhost linear
  layout is otherwise headerless. Records/structs already carried a header;
  tuples now take one under `enable_rc` (type_id 3). Arrays / enums /
  closures still pending. Guarded by `CompileCtx.enable_rc`, proven
  output-equivalent by the parity gates; strings/bytes stay headerless
  (leaf objects). Leak profiler baseline: 16 B/iteration (bump, no RC);
  RC-mode tuple loop 24 B/iter (still leaking until Phase 3).
- **Phase 2 — analysis pass:** *complete (bar cross-branch balancing)*.
  `build_perceus_plan` in `lib/@vibe/compiler/perceus/index.vibe` mirrors the
  validated `src/` semantics on the selfhost expression-oriented AST: calls
  / field access / array index arg0 are borrows; pure-borrow / unused
  non-scalar bindings get a scope-end drop; multiply-used owning references
  dup. 14/14 isolation tests (`perceus_rc_test.vibe`).
- **Phase 3 — drop codegen + free-list:** *not started*. Emitting the
  dup/drop instructions and a reclaiming allocator is what actually drops
  per-iteration heap growth to ~0 (the concrete leak-fixed acceptance
  criterion) and what a wasmtime RC e2e gate would assert.

### RC limitations to keep documented

- **Cycles leak** — RC cannot reclaim reference cycles; this is a permanent
  semantic difference from wasm-gc. Policy (accept + document vs. weak refs /
  cycle collector) is deferred.
- **No RC reclamation today** — until Phase 3, `VIBE_RC=1` changes layout and
  runs the analysis but does not free; the production default (`--wasm`
  without `VIBE_RC`) leaks by design (bump allocator).

## Semantics alignment with wasm-gc

- The memory model differs fundamentally (eager RC vs. lazy GC) but, absent
  finalizers, observable results can be made identical — the way to verify
  this is a differential test (no-RC / RC / wasm-gc producing identical
  observable output), which does not exist yet.
- `Array::push` semantics already differ across backends (linear: in-place
  growable; wasm-gc: fixed-size, rebinds the local). Orthogonal to RC but
  must be reconciled or documented before unifying defaults.
- Value representations differ (tagged i64 vs. typed refs); RC does not
  change representation, so RC alone aligns lifetime observation, not layout.
  Remaining alignment is builtin parity (tracked by #415's parity gate).

## Relationship to issue #493

- ✅ memory-management contract table lives here (`docs/spec`).
- ✅ `compile --wasm` / `--wasm-gc` / `build --release` / `test` / `bench`
  backend defaults pinned above and exercised by the selfhost gate.
- ✅ README backend description reconciled with the selfhost CLI.
- ✅ Perceus RC marked experimental opt-in; selfhost port status and the
  remaining Phase 3 work are tracked in `rc-port.md`.
- ✅ The "no reclamation / cycles leak" limitations are documented above.
