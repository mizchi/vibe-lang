# Vibe profiling: memory and benchmarking design

This document describes Vibe's measurement infrastructure and its current
implementation. The memory profiler is directly tied to the allocation model.

## Memory model

Every tier below reads the exported global `__heap_ptr`, the frontier of the
main linear allocator. It only moves forward. What a frontier delta means
depends on the lane the program was compiled for (the
[memory contract](memory-contract.md) defines the lanes):

- **Linear RC** (the default for `vibe run`, `vibe build` and `vibe bench`):
  Perceus releases objects onto free lists, and later allocations reuse those
  blocks without moving the frontier. A delta is **frontier growth**, not total
  allocation: a loop that frees what it allocates can report 0 B while it
  allocates on every iteration, and the peak frontier is not the peak live
  set either.
- **Linear bump** (`VIBE_RC=0`): nothing is freed, so within one execution the
  delta is the total allocated and the peak equals the total. Compile with
  `VIBE_RC=0` when a measurement must count allocations, as the
  `bench/bench_*.vibe` write-ups that quote B/op as allocation do.
- **Wasm GC** (`VIBE_BACKEND=gc`, opt-in): native GC objects never touch the
  frontier; only values that stay in linear memory do.

On the bump lane and the Wasm-GC backend, `MutList` / `MutBytes` storage
inside a `region` lives in a separate arena and does not move `__heap_ptr`
while the arena has room. The RC lane has no dedicated arena.

These tiers are therefore allocation profiles by frontier growth, rate and
site, not live-set profiles. Host allocations such as `vibe_alloc_packed_str`
bump the same `__heap_ptr`, so the value covers guest and host heap use
together.

## Implementation tiers by cost

| Tier | Measurement | Instrumentation | Status |
|---|---|---|---|
| **1** | Total heap and peak from the `__heap_ptr` delta | None | Implemented: `vibe run --mem` |
| **2** | `memory.grow` event timeline | Host only | Implemented as part of `--mem` |
| **3** | Allocation timeline sampling | Host only, using epochs | Implemented: `--mem-sample` |
| **4** | Per-function allocation attribution, similar to massif or heaptrack | Reuses break-build `dbg_break` instrumentation | Implemented: `--alloc-site` |

## Tier 1: `vibe run --mem`

The runner reads `__heap_ptr` before and after `_start` and reports the delta as
`allocated`. This requires no instrumentation and has nearly zero overhead.
Reports go to stderr without contaminating program stdout.

```text
$ vibe run --mem prog.vibex
<program stdout>
vibe::mem heap_base=131144 heap_peak=258152 allocated=127008 committed=4194304
vibe: memory — allocated 124.0 KiB (127008 B), peak heap 252.1 KiB, committed 4.0 MiB
```

- `vibe::mem ...` is machine-readable for benchmark harnesses and CI.
- `vibe: memory — ...` is human-readable.

`allocated = heap_peak - heap_base`. On the bump lane (`VIBE_RC=0`) nothing is
freed, so this is the total allocated during the execution; on the default RC
lane it is frontier growth, and blocks reused from the free lists do not count
(see [Memory model](#memory-model)). Pure computational programs have
`allocated=0`. `committed` is the total number of bytes in Wasm memory.

When `VIBE_MEM=1` is set by `--mem`, the runner reads `__heap_ptr` through
`read_heap_ptr`, reads the memory size, and emits the result with
`report_memory`, including after a trap. Tests live in
`scripts/test_vibe_mem.sh`.

## Tier 2: growth timeline

During `--mem`, the runner records every `memory.grow` through Wasmtime's
`ResourceLimiter` implementation, `MemLimiter`. Both guest `memory.grow` and
host `Memory::grow` calls for bump-allocated strings pass through this limiter,
so the timeline covers both sides without guest instrumentation.

```text
$ vibe run --mem grow.vibex
vibe::mem heap_base=131144 heap_peak=6270152 allocated=6139008 committed=6291456 grow_events=32
vibe: memory — allocated 5.9 MiB …, committed 6.0 MiB, 32 growth event(s)
vibe::memgrow t_us=2066 from=4194304 to=4259840 pages=+1
vibe::memgrow t_us=2107 from=4259840 to=4325376 pages=+1
…
vibe:   growth 4.0 MiB -> 6.0 MiB across 32 event(s), 2.07 ms … 2.50 ms
```

Each `vibe::memgrow` line is machine-readable. `t_us` is elapsed time from the
start of the run, `from` and `to` are byte counts, and `pages` is the number of
added pages.

The generated Wasm starts with 64 pages, or 4 MiB, as selected by
`default_wasi_memory_min_pages`. A program that stays below 4 MiB produces no
growth and reports `grow_events=0`. This tier is therefore a coarse committed-
page timeline. Use tier 3 to observe fine-grained allocation inside the initial
memory. The example also shows the bump allocator growing one 64 KiB page at a
time; larger growth chunks could reduce host calls.

## Tier 3: timeline sampling

`vibe run --mem-sample[=MS]` defaults to a 1 ms interval. A background thread
increments the Wasmtime engine epoch. At guest checkpoints such as function
entries and loop back edges, the epoch-deadline callback reads `__heap_ptr`.
This exposes heap movement inside the initial 4 MiB where tier 2 sees no growth.
The mechanism is host-only and needs no guest instrumentation. Epoch checks are
enabled only for `--mem-sample`, so ordinary runs and `vibe bench` are
unaffected.

```text
$ vibe run --mem-sample long.vibex
vibe::memsample t_us=1235 heap=2459624
vibe::memsample t_us=2314 heap=4571336
…
vibe: heap samples — 12 over 1.21 ms … 13.36 ms, 2.4 MiB -> 19.2 MiB (peak 19.2 MiB)
```

Each `vibe::memsample` line is machine-readable. `t_us` is elapsed time and
`heap` is `__heap_ptr` in bytes. The number of samples depends on execution time
and interval; a program faster than one interval may produce no samples.

## Tier 4: per-function allocation attribution

`vibe run --alloc-site[=N]` provides by-frame allocation profiling similar to
massif or heaptrack by reusing the break build without new instrumentation.
Break code generation emits `vibe::dbg_break` at every user-function entry and
`vibe::dbg_line` at statement boundaries for debugger breakpoints and stepping.
The runner treats both hooks as sample points. It reads `__heap_ptr` and credits
the frontier growth since the previous sample to the innermost function active
at that time, `frame[0]` of the backtrace.

Refreshing the backtrace at statement boundaries means allocations in a caller
after a helper returns are normally credited to the caller. This avoids a
common error from entry-only sampling. `dbg_break` fires independently of
`let` or `mut`, so every function is covered, including functions containing
pure mutable loops. Reusing the break build leaves the default self-compile path
byte-identical.

```text
$ vibe run --alloc-site sites.vibex
1250
vibe::allocsite fn=heavy line=1 bytes=181200
vibe::allocsite fn=light line=7 bytes=1456
vibe: alloc sites — 2 function(s), 178.4 KiB attributed total, top 2 shown
```

Each `vibe::allocsite` line is machine-readable. `fn` is the function name,
`line` is its declaration line resolved through the funcmap or `?`, and `bytes`
is the attributed heap growth. Reports go to stderr. `=N` or
`VIBE_ALLOC_SITE_TOP` limits the number of reported functions and defaults to
20. `VIBE_ALLOC_SITE=1` enables the runner logic. The launcher compiles with
the same instrumentation as `--break` but does not set `VIBE_BREAK`, so it does
not pause.

Attribution is an approximation at function granularity, not line granularity.
It assigns the entire delta between sample points to one function. Because it
uses `__heap_ptr`, it measures frontier growth rather than live memory, and on
the RC lane an allocation served from a free list is credited to nobody. Taking
a backtrace at every sample also makes `--alloc-site` slower than a normal run.

A remaining misattribution occurs when a caller allocates after a helper call
inside a region with no statement boundary, such as a `while` loop containing
only mutable assignments. Mutable declarations and assignments do not emit
`dbg_line`, so the tail delta can be credited to the most recently sampled
callee. For example, a large allocation in
`let x = helper(); let mut t=""; while … { t = concat(t, …) }` may be credited
to `helper`. Exact per-allocation attribution requires either a hook at every
allocation site or a return hook. That heavier opt-in instrumentation is beyond
the runner-only implementation. Tests live in
`scripts/test_vibe_alloc_site.sh`.

## `vibe bench`

Vibe already had `bench "name" { }` syntax and `vibe::profile-now-us`, but did
not have a measurement harness. `viberun --bench` adds the harness without
changing code generation:

- It repeatedly invokes a restartable test entry on one warm instance, using
  warmup calls before measurement.
- It times each call with `Instant` and reads `__heap_ptr` around the batch to
  report bytes per operation using tier 1. On the default RC lane that is
  frontier growth per operation; compile with `VIBE_RC=0` to count
  allocations.
- It reports minimum, p50, p95, mean, operations per second, and bytes per
  operation.

```text
$ vibe bench examples/simple_bench.vibe
vibe::bench label=simple_bench.vibe iters=1000 ns_min=47 ns_p50=49 ns_p95=51 ns_mean=49 ops_per_sec=20408163 bytes_per_op=0
bench simple_bench.vibe: 1000 iters — 49 ns/op (min 47 ns, p50 49 ns, p95 51 ns), 20.4M ops/s, 0 B/op
```

Usage is `vibe bench <file> [--iters N] [--warmup N]`. The `vibe::bench` line is
machine-readable for CI and comparisons. Environment variables are
`VIBE_BENCH_ITERS`, `VIBE_BENCH_WARMUP`, and `VIBE_BENCH_LABEL`. Tests live in
`scripts/test_vibe_bench.sh`.

### Wasmtime guest CPU profiles

`vibe profile <file.vibex> --out profile.json --interval-us 1000` captures a
function-level Wasm guest CPU profile through Wasmtime `GuestProfiler`. The
output is Firefox processed-profile JSON and can be opened at
<https://profiler.firefox.com/>. The profile is flushed after both successful
execution and a guest trap.

`vibe bench <file.vibe> --guest-profile <directory> --interval-us 1000`
produces one JSON file per `__bench_<name>` block. Profiling starts after that
block's warmup. The profiler changes execution cost, so latency values from a
profiled invocation are diagnostic only. Use an unprofiled invocation for KPI
or regression comparisons.

Both modes require fresh `.wasm`. An ordinary `.cwasm` was compiled without
epoch-interruption checkpoints and is rejected rather than silently producing
an empty profile. Function names come from the Wasm name section. Vibe
`vibe.linemap` source-line attribution is not yet included.

### Per-benchmark-block granularity

For a no-entry build, code generation exports every `bench "name" { }` block as
`__bench_<name>`. Normal builds and compiler self-compilation remain
byte-identical. The runner enumerates these exports, measures each block on its
own warm instance, and emits one line labeled `<file>::<name>`. A Wasm module
without `__bench_*` exports, such as output from an older compiler or a file
containing only `test` blocks, falls back to measuring the entire `_start` at
file granularity.

```text
$ vibe bench multi_bench.vibe
vibe::bench label=multi_bench.vibe::light iters=1000 ns_min=… … bytes_per_op=0
bench multi_bench.vibe::light: 1000 iters — … ns/op …
vibe::bench label=multi_bench.vibe::heavy iters=1000 ns_min=… … bytes_per_op=0
bench multi_bench.vibe::heavy: 1000 iters — … ns/op …
```

The export logic is in
`lib/@vibe/compiler/codegen/wasi/linked_compile_module_sections.vibe`, where the
export section adds `__bench_*` names from `test_fn_names` to
`all_export_names`. The runner's
`bench` function enumerates module exports and selects per-block measurement or
the fallback. `scripts/test_vibe_bench.sh` covers the behavior.

Potential accuracy improvements include:

- inner batching to amortize per-call overhead for nanosecond-scale work;
- separate reports for the linear and GC backends;
- regression detection against a baseline keyed by label, backend, and source
  hash, with percentage regressions suitable for a CI gate.

## Measurement cautions

- `profile-now-us` reads a host wall clock. Microbenchmarks must batch work.
- On the bump lane nothing is reclaimed, so peak equals total allocation by
  definition. On the RC lane the frontier stops growing once the free lists
  cover the workload's churn, so a flat frontier is not proof of zero
  allocation or of no leak; compare against `VIBE_RC=0`.
- Measurements are inherently noisy; use repetition and robust statistics.
