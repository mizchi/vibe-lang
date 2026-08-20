# Memory management contract (linear / wasm-gc / Perceus RC)

Status: living spec (tracks issue #493). This document pins the *current*
behavior of the **compiler** toolchain (`lib/@vibe/compiler/`, `vibe/cli/`) and
records the intended direction. The retired MoonBit host (`src/`, #594) is
referenced only as historical context; nothing in `src/` is reachable from
the production CLI anymore.

Direction in one line: **wasm-gc is the long-term primary target; the linear
backend is the production default, and Perceus RC is what it does — the "bump
allocator, never free" behavior is now the opt-out (`VIBE_RC=0`) rather than
the only behavior.**

## Backend contract table

| | linear + Perceus RC (**the default**) | linear, bump only (`VIBE_RC=0`) | wasm-gc |
|---|---|---|---|
| CLI entry | `compile --wasm` / `--wasm-linear`, `build --release`, `test`, `bench` — i.e. everything, with `VIBE_RC` unset | env opt-out `VIBE_RC=0`; **not** CLI-exposed | **not wired in the CLI** (`compile --wasm-gc` throws "not supported by selfhost cli yet"); reachable only via `VIBE_TEST_BACKEND=gc` / `VIBE_BENCH_BACKEND=gc` for host-import-free test/bench |
| value representation | tagged `i64` (1-bit tag on the shipped RC lane) | same tagged `i64` | tagged `i64` with tuple/struct/ctor/closure data in guest linear memory (the backend enables Wasm-GC features but does not yet emit `struct.new` / `array.new` for user values) |
| allocation | `__rc_alloc` + free-list | bump allocator | guest-linear bump allocator + `memory.grow` |
| reclamation | Perceus dup/drop, **eager and deterministic** (bounded heap: `heap(N1) == heap(N2)`) | **none (leaks linearly)** | **none for current user-value allocations**; Wasmtime tracing GC has no user allocations to reclaim yet |
| object lifetime | deterministic, eager | n/a (never freed) | current user values live to instance teardown; future Wasm-GC values will be non-deterministic/lazy |
| cycles | **leak (permanent RC limitation)** | n/a (nothing is freed) | current bump allocations are retained; future Wasm-GC cycles are intended to be collected |
| known gaps | cycles leak; a matched heap field bound but **unused** over-keeps (write `_`); replay-based handlers spill past ~16K performs per `handle` | — | single-file only (referencing an imported name fails with `@gc_call ... unresolved`; an unused import is fine); `bench` blocks unsupported (#1701); builtin parity tracked in `scripts/builtin_parity_classification.tsv`; not CLI-reachable |
| intended status | production default | escape hatch and bump-vs-RC baseline | long-term primary target |

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
- `VIBE_RC` unset == `VIBE_RC=1` (byte-identical output, measured 2026-08-20
  and pinned by `scripts/check_rc_default.sh`). `VIBE_RC=0` opts back out to
  bump. Not surfaced as a CLI flag either way.
- The compiler's own self-build is pinned to bump in `scripts/generations.sh`
  — a **performance** choice (~1.7x wall, ~2.9x output size), not a
  correctness one.

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
- **`VIBE_RC=0` does not reclaim** — the bump lane never frees, by design. It
  is the escape hatch and the baseline the RC regression probe compares
  against, not the default.
- **A matched heap field bound but unused over-keeps** — a safe over-keep, not
  a use-after-free; write `_` for a field you do not use.

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
- ✅ Perceus RC **shipped as the linear default**; status and residual leaks
  in [rc-cutover-readiness.md](rc-cutover-readiness.md), design in
  [rc-port.md](rc-port.md).
- ✅ The cycles-leak limitation and the residual over-keep are documented above.
