# Memory management contract (linear / wasm-gc / Perceus RC)

Status: living spec (tracks issue #493). This document pins the *current*
behavior of the **compiler** toolchain (`lib/@vibe/compiler/`, `vibe/cli/`) and
records the intended direction. The retired MoonBit host (`src/`, #594) is
referenced only as historical context; nothing in `src/` is reachable from
the production CLI anymore.

Intended direction in one line: **wasm-gc is the long-term primary target;
the linear backend stays the production default and is gaining Perceus RC
so its "bump allocator, never free" leak becomes opt-out rather than the
only behavior.**

## Backend contract table

| | linear (today / default) | linear + Perceus RC (in progress) | wasm-gc |
|---|---|---|---|
| CLI entry | `compile --wasm` / `--wasm-linear`, `build --release`, `test`, `bench` | env opt-in `VIBE_RC` → `compile_source_wasi_only_rc`; **not** CLI-exposed | **not wired in the CLI** (`compile --wasm-gc` throws "not supported by selfhost cli yet"); reachable only via `VIBE_TEST_BACKEND=gc` / `VIBE_BENCH_BACKEND=gc` for host-import-free test/bench |
| value representation | tagged `i64` (2-bit tag) | same tagged `i64` | tagged `i64` with tuple/struct/ctor/closure data in guest linear memory (the backend enables Wasm-GC features but does not yet emit `struct.new` / `array.new` for user values) |
| allocation | bump allocator | bump + (planned head free-list) | guest-linear bump allocator + `memory.grow` |
| reclamation | **none (leaks linearly)** | Perceus dup/drop (analysis complete; drop **codegen Phase 3 WIP**) | **none for current user-value allocations**; Wasmtime tracing GC has no user allocations to reclaim yet |
| object lifetime | n/a | deterministic, eager (once Phase 3 lands) | current user values live to instance teardown; future Wasm-GC values will be non-deterministic/lazy |
| cycles | n/a | **leak (RC limitation)** | current bump allocations are retained; future Wasm-GC cycles are intended to be collected |
| known gaps | — | uniform object header only partly landed (tuples done, arrays/enums/closures pending); no drop emission yet; no wasmtime RC e2e gate | single-file only (referencing an imported name fails with `@gc_call ... unresolved`; an unused import is fine); `bench` blocks unsupported (#1701); builtin parity tracked in `scripts/builtin_parity_classification.tsv`; not CLI-reachable |
| intended status | production default | future linear default (opt-out leak) | long-term primary target |

The defaults above are exercised by the gate
(`scripts/compiler_gate.sh`), which compiles, runs, and self-reproduces
through the linear `--wasm` path; the RC analysis path is exercised by
`lib/@vibe/compiler/tests/perceus_rc_test.vibe`.

## Current CLI behavior (pin)

- `vibe compile --wasm <f>` / `--wasm-linear` → **linear** backend.
- `vibe compile --wasm-gc <f>` → **throws** (`vibe/cli/dispatch.vibe`); the
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
> longer true for the CLI; the table has been corrected to match the
> behavior pinned here.

## Perceus RC status — shipped as the linear default

RC **is** the linear default: compiling a program with `VIBE_RC` unset produces
a byte-identical module to `VIBE_RC=1`, and a different one to `VIBE_RC=0`
(measured 2026-08-20; pinned by `scripts/check_rc_default.sh`). The compiler's
own self-build stays pinned to bump (`scripts/generations.sh`) as a
**performance** choice — an RC self-build is ~1.7x wall and ~2.9x output size —
not because RC self-hosting is unproven; it reaches a byte-identical fixpoint.

This section previously read "experimental, in progress" and said "the
reclamation half is not finished", staging it as three phases of which the
first was *started* and the third *not started*. That describes the port, which
completed; the staged plan is history in `git log` and #493.

Canonical status and residual leaks:
[rc-cutover-readiness.md](rc-cutover-readiness.md). Representation details:
[uniform-value-repr.md](uniform-value-repr.md).

### RC limitations to keep documented

- **Cycles leak** — RC cannot reclaim reference cycles; this is a permanent
  semantic difference from wasm-gc. Policy (accept + document vs. weak refs /
  cycle collector) is deferred.
- **No RC reclamation today** — until Phase 3, `VIBE_RC=1` changes layout and
  runs the analysis but does not free; the production default (`--wasm`
  without `VIBE_RC`) leaks by design (bump allocator).

## Semantics alignment with wasm-gc

- Today the gc lane's user-value allocation model is also guest-linear bump
  allocation, not Wasmtime tracing GC. `scripts/test_gc_heap_accounting.sh`
  characterizes its exported `__heap_ptr` high-water after discarded-object
  churn; it is deliberately **not** a GC liveness or leak test. Wasmtime's
  CLI does not expose stable live-GC-heap telemetry for such a test.
- Once the backend emits Wasm-GC `struct.new` / `array.new` for user values,
  this section must be updated and the bump-high-water characterization
  replaced by an embedding-level live-heap/liveness test. At that point the
  memory model will differ fundamentally (eager RC vs. lazy GC), though absent
  finalizers observable results can still be made identical via a differential
  test (no-RC / RC / wasm-gc producing identical output).
- `Array::push` semantics already differ across backends (linear: in-place
  growable; wasm-gc: fixed-size, rebinds the local). Orthogonal to RC but
  must be reconciled or documented before unifying defaults.
- Value representations differ (tagged i64 vs. typed refs); RC does not
  change representation, so RC alone aligns lifetime observation, not layout.
  Remaining alignment is builtin parity (tracked by #415's parity gate).

## Relationship to issue #493

- ✅ memory-management contract table lives here (`docs/spec`).
- ✅ `compile --wasm` / `--wasm-gc` / `build --release` / `test` / `bench`
  backend defaults pinned above and exercised by the gate.
- ✅ README backend description reconciled with the current CLI.
- ✅ Perceus RC marked experimental opt-in; port status and the
  remaining Phase 3 work are tracked in `rc-port.md`.
- ✅ The "no reclamation / cycles leak" limitations are documented above.
