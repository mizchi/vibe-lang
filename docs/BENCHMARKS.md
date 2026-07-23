# Benchmarks

Continuously-runnable regression signals, as opposed to one-off measurement
notes (e.g. `docs/archive/adr/0038-perceus-rc-binary-optimization.md`).
Currently covers wasm binary size; other categories (compile throughput,
runtime perf) live in `bench/` and `docs/pl-survey-2026-07.md`'s roadmap.

## WASM Binary Size

Methodology and case set: [`bench/binary_size/README.md`](../bench/binary_size/README.md)
(modeled on [almide](https://github.com/almide/almide)'s `docs/BENCHMARKS.md`
— see `docs/pl-survey-2026-07.md`, issue #1056). Run with:

```bash
bash scripts/bench_binary_size.sh [cli.wasm]
```

### Measured 2026-07-22 (`bootstrap/seed/compiler.wasm`, linear backend)

| program | `VIBE_RC=0` (bump, prod default) | `VIBE_RC=1` (Perceus RC) | `wasm-opt -Oz` |
|---|---:|---:|---:|
| hello_world | 5,740 B | 6,988 B | n/a (wasm-opt not installed in this environment) |
| fizzbuzz | 6,112 B | 7,469 B | n/a |
| fib | 5,701 B | 6,958 B | n/a |
| closure_indirect | 5,838 B | 7,194 B | n/a |
| variant_float | 6,347 B | 9,306 B | n/a |

RC's header + dup/drop instrumentation costs roughly 1.2–1.5x on these small
programs (largest on `variant_float`, which allocates the most distinct heap
shapes: an array of enum values). See
`docs/archive/adr/0038-perceus-rc-binary-optimization.md` for the RC binary
size optimizations already applied (br_table dispatch, conditional free-list,
etc.) and `docs/spec/rc-port.md` for RC's overall status (Phase 3, drop
codegen, in progress).

### #1056 rc-check elision pass — measured impact on this suite: none (expected)

Issue #1056's Phase B added a narrow, occurrence-local optimization to
`lib/@vibe/compiler/perceus/perceus.vibe` (`build_perceus_plan`'s `ELet`
alias handling) that elides a dup+drop pair for an alias binding
(`let a = t`) that would otherwise duplicate `t`'s reference but is never
itself referenced — the dup and the alias's own unconditional scope-end drop
are a provable no-op on the same memory with no intervening read (see the
`#1056` comment at that call site for the full argument, and
`lib/@vibe/compiler/tests/perceus_rc_test.vibe`'s
`"unused alias with other remaining uses is elided"` test for the isolated
before/after case).

Neither this 5-program bench suite nor the compiler's own (much larger)
self-hosted source happens to contain that pattern today — recompiling
`lib/@vibe/compiler/_cli_adapter_module_source.vibe` under `VIBE_RC=1` with
the pre-#1056 seed vs. the post-#1056 compiler produces **byte-identical**
output (4,376,075 B either way). The pattern is real (almide's
`alias_safety.rs` targets the analogous "provably unaliased/unused value"
case for a different, COW-guard-shaped construct) and plausible in
machine-generated code (derive-generated accessors, normalization-inserted
bindings), so the pass is kept as a zero-cost-when-unused safety net rather
than reverted for lack of a present-day win; re-run this bench (and the
self-compile comparison above) after any future change that could introduce
the pattern.
