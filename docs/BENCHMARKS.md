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

> The numbers in this section are the **linear** backend (the default lane)
> tracked over time. For the same case set measured across *backends* — linear
> vs `VIBE_BACKEND=gc`, and where the two cross over — see
> [`wasm/code-size-linear-vs-gc.md`](wasm/code-size-linear-vs-gc.md)
> (`scripts/measure_backend_code_size.sh`). Short version: wasm-gc pays a fixed
> ~4 KB runtime prelude to save ~6% per byte of user code, so it only comes out
> smaller above ~35 KB of linear output.

### Measured 2026-07-25 (post-#1107 Phase 4 funcref-table minimization)

The element section now registers only the table slots codegen actually
materialized a closure value for (run-compressed active segments; unused
slots stay `ref.null`). Small programs shed a few entries; the dist CLI
sheds most of its table (2,751 entries / 5,446 B → 117 entries / 265 B,
stage2 1,447,135 → 1,442,550 B) — and, more importantly, the downstream
DCE root set collapses with it (`docs/wasm-opt-dogfood.md`).

| program | `VIBE_RC=0` (bump, prod default) | `VIBE_RC=1` (Perceus RC) |
|---|---:|---:|
| hello_world | 771 B | 792 B |
| fizzbuzz | 1,204 B | 1,334 B |
| fib | 726 B | 756 B |
| closure_indirect | 946 B | 2,609 B |
| variant_float | 2,493 B | 5,328 B |

### Measured 2026-07-25 (post-ADR-0077 release strip)

ADR-0077 changed what "as shipped" means for executables: the compiler now
stubs generated runtime helpers no reachable body calls (`unreachable`
one-instruction bodies at unchanged indices), drops the `name` custom
section, and filters exports down to what runners address by name
(`VIBE_WASM_NAMES=1` / `VIBE_WASM_KEEP_EXPORTS=1` opt out).

| program | `VIBE_RC=0` (bump, prod default) | `VIBE_RC=1` (Perceus RC) | vs 07-22 rc0 |
|---|---:|---:|---:|
| hello_world | 780 B | 801 B | -86% |
| fizzbuzz | 1,214 B | 1,344 B | -80% |
| fib | 736 B | 766 B | -87% |
| closure_indirect | 948 B | 2,611 B | -84% |
| variant_float | 2,504 B | 5,339 B | -61% |

The RC premium also collapses on the tiny cases (hello_world 780 vs 801 B):
most of the old 1.2–1.5x gap was the always-emitted RC-variant helper
bodies, which are now stubbed when unused. The dist CLI wasm itself sheds
the name section (163KB) + 700-odd `*_exp_lib__*` module-linking exports
(56KB): 1,656,107 → 1,409,578 B (-14.9%) for the same source compiled
unstripped vs stripped.

### Measured 2026-07-22 (`bootstrap/seed/compiler.wasm`, linear backend — pre-strip baseline)

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
etc.) and `docs/spec/rc-cutover-readiness.md` for RC's overall status (drop
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
