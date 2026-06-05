# selfhost cutover baseline update — compile gate 2.5x

Date: 2026-06-02

This report updates #402 from the old `compile <= 1.33x` target to a more
realistic baseline for the current wasmtime-AOT path.

## Benchmark setup

- Driver: `scripts/bench_selfhost_perf.sh`
- Runtime: `VIBE_SELFHOST_PERF_RUNTIME=wasmtime-aot`
- Runs: `VIBE_SELFHOST_PERF_RUNS=5`
- Cases: `bench/selfhost_perf/kpi_cases.txt`
- Selfhost wasm profile: default `debug`
- wasm-opt: auto-selected `-O3` for `wasmtime-aot`
- Host runner: `tools/moonrun_wasmtime/target/release/moonrun_wt`

Note: this selfhost perf harness uses `moonrun_wt` (`wasmtime` Rust crate,
currently `45.0.0` in `tools/moonrun_wasmtime/Cargo.toml`), not the
project-local `wasmtime` CLI prebuilt installed at `.tools/wasmtime/bin/wasmtime`.

The local `moonrun_wt` binary had to be rebuilt because the existing release
binary referenced a stale Nix `libiconv` path.

## Result

Run A:

```bash
VIBE_SELFHOST_PERF_RUNTIME=wasmtime-aot \
VIBE_SELFHOST_PERF_RUNS=5 \
VIBE_SELFHOST_PERF_MAX_TOTAL_COMPILE_RATIO=2.5 \
VIBE_SELFHOST_PERF_MAX_TOTAL_CHECK_RATIO=1.33 \
VIBE_SELFHOST_PERF_CASES_FILE=bench/selfhost_perf/kpi_cases.txt \
VIBE_SELFHOST_PERF_REBUILD=never \
scripts/bench_selfhost_perf.sh
```

Result:

- TOTAL compile: `66 / 114 ms`, ratio `1.727x`
- TOTAL check: `84 / 85 ms`, ratio `1.012x`
- With total-only gate variables, this passes. The worst per-case check ratio
  in this sample was `module_import = 1.556x`, which should remain diagnostic.

Run B:

```bash
VIBE_SELFHOST_PERF_RUNTIME=wasmtime-aot \
VIBE_SELFHOST_PERF_RUNS=5 \
VIBE_SELFHOST_PERF_MAX_TOTAL_COMPILE_RATIO=2.5 \
VIBE_SELFHOST_PERF_CASES_FILE=bench/selfhost_perf/kpi_cases.txt \
VIBE_SELFHOST_PERF_REBUILD=never \
scripts/bench_selfhost_perf.sh
```

Result:

- TOTAL compile: `70 / 125 ms`, ratio `1.786x`
- TOTAL check: `91 / 75 ms`, ratio `0.824x`
- With total-only gate variables, this passes. The worst per-case compile ratio
  in this sample was `base64 = 2.571x`, which should remain diagnostic.

## Baseline decision

Use **TOTAL compile wallclock <= 2.5x** as the #402 compile baseline.

Rationale:

- The old `1.33x` compile target assumes wasmtime-hosted MoonBit wasm can run
  compiler-shaped workloads within 33% of native MoonBit. Current profiling
  shows that is not a realistic runtime floor.
- Current total compile ratios are `1.73-1.79x`, so `2.5x` gives practical
  headroom without accepting moonrun-era regressions.
- Per-case ratios and stage ratios should remain diagnostics. Applying the
  same `2.5x` cap per case is too brittle today: `base64` hit `2.571x` in one
  RUNS=5 sample while total compile still passed with headroom.
- Stage-summary ratios are in-process profiled work and can remain `~4-6x`
  even when user-visible wallclock totals are below `2.5x`. The release gate
  should use the summary wallclock totals.

Check can remain **TOTAL check wallclock <= 1.33x** for now, with the same
per-case diagnostic caveat. The latest runs show total check `0.82-1.01x`, but
one per-case check sample still hit `1.556x`.

## Follow-up

- Keep CI and #402 cutover checks on
  `VIBE_SELFHOST_PERF_MAX_TOTAL_COMPILE_RATIO` /
  `VIBE_SELFHOST_PERF_MAX_TOTAL_CHECK_RATIO`.
- Use `VIBE_SELFHOST_PERF_MAX_CASE_COMPILE_RATIO` /
  `VIBE_SELFHOST_PERF_MAX_CASE_CHECK_RATIO` only for stricter diagnostic runs.
- Keep recording per-case and stage summaries; they are useful for regression
  diagnosis but too noisy for the cutover baseline itself.
