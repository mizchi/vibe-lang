# Selfhost performance benchmarks

Macro and micro benches for the self-hosted vibe compiler / checker. Pair
with `bench/selfhost_check_parity` and `bench/selfhost_cutover` to keep
host vs selfhost output equivalent.

## Macro: stage-level wallclock

Driver: `scripts/bench_selfhost_perf.sh` → `just bench-selfhost-perf`.

Compares host CLI vs selfhost wasm (under `moonrun`) on the cases listed in
`cases.txt`. Median of N runs (default 3) per phase per stage; emits ratio
gates that `just test-selfhost-perf-gate` enforces.

Output: `_build/bench/selfhost_perf/{summary,stage_summary}.{e2e,in-memory}.tsv`.

## Memory: peak RSS + wallclock

Driver: `scripts/bench_selfhost_memory.sh` → `just bench-selfhost-memory`.

Combines `hyperfine` (stable wallclock, std-dev, JSON export) with
`/usr/bin/time -v` (peak resident-set size in KB) and reports the
selfhost/host ratio per phase per case. Optional gates:
`VIBE_SELFHOST_MEMORY_MAX_RSS_RATIO` / `VIBE_SELFHOST_MEMORY_MAX_RSS_KB`.

Linux only — relies on GNU `/usr/bin/time -v`'s `Maximum resident set size`
field. macOS users need `gnu-time` (`brew install gnu-time`) and to point
`/usr/bin/time` at it via PATH.

Output: `_build/bench/selfhost_memory/rss_summary.tsv` and
`_build/bench/selfhost_memory/hyperfine/<case>.<phase>.json`.

### wasm-opt -O3 step

Both `bench_selfhost_perf.sh` and `bench_selfhost_memory.sh` invoke
`build_selfhost_wasi_opt.sh` (env: `VIBE_SELFHOST_PERF_WASM_OPT` /
`VIBE_SELFHOST_MEMORY_WASM_OPT`, default `auto`) to pipe the release
selfhost wasm through binaryen `wasm-opt -O3` before measurement.

The helper resolves the wasm-opt binary in this order:

1. `WASM_OPT_BIN` env override.
2. `~/.moon/bin/moon-wasm-opt` (binaryen v125 bundled with moonbit;
   always compatible with moon-emitted wasm).
3. PATH `wasm-opt`, only if its binaryen version is `>= 118`.

If none qualify, the helper falls back to raw release wasm with a
warning (no measurement loss, just no speedup).

**Don't `cargo install wasm-opt`**: crates.io is fixed at
`wasm-opt v0.116.1` (binaryen v116) which fails on moon-emitted wasm
with "block cannot pop from outside" — same failure mode as Ubuntu
24.04's apt binaryen v108. Use the moon-bundled binary instead.

Effect on `examples/basics.vibe` (single-run hyperfine, --warmup 1
--runs 3, May 2026):

| metric              | host    | self (raw debug) | self (release + O3) | ratio gain |
| ------------------- | ------- | ---------------- | ------------------- | ---------- |
| compile mean ms     | 39.6 ms | 247 ms           | **134.9 ms**        | 6.25× → **3.41×** |
| compile peak RSS    | 16.2 MB | 100 MB           | **80.9 MB**         | 6.18× → **4.99×** |
| check mean ms       | 107 ms  | 285 ms           | **193 ms**          | 2.66× → **1.80×** |
| check peak RSS      | 22.5 MB | 70.0 MB          | **73.2 MB**         | 3.09× → **3.25×** |
| compile wasm size   | —       | 6.82 MB          | **3.07 MB**         | -55% |
| check wasm size     | —       | 3.04 MB          | **1.27 MB**         | -58% |

(Smaller artifacts also help cold-start RSS for the compiler wasm in
particular.) The remaining gap is dominated by `moonrun`'s
WASM-execution overhead; bigger wins after this point require either
a faster runtime (wasmtime AOT, currently blocked on WASI-binding
reshape since selfhost wasi entry imports `spectest::print_char`) or
algorithmic work on the moonbit-side compiler. Tracked under TODO #295.

## Micro: vibe bench probes (currently blocked)

Files:
- `vibe/compiler/lexer_hotspot_probe.vibe` + `selfhost_lexer_bench.vibe`
- `vibe/compiler/parser_hotspot_probe.vibe` + `selfhost_parser_bench.vibe`
- `vibe/compiler/checker_hotspot_probe.vibe` + `selfhost_checker_bench.vibe`

Driver (host CLI compiled backend):
`scripts/bench_selfhost_compile_hotspots.sh` → `just bench-selfhost-compile-hotspots`.

These bench files type-check clean (`vibe check ...` passes) and define
per-case probes that exercise the selfhost lexer / parser / checker against
real selfhost sources and synthetic shapes (deep binop chains, wide match,
chained let / ESeq sequences).

**Currently blocked**: `vibe bench`'s `compile-lite` calibration step pulls
in the imported selfhost compiler modules and either errors with
"unsupported: closure-capture / unknown name" or hangs in calibration —
same gap as `selfhost_hotspots_bench.vibe` (see `cases.txt` header
comment). Until compile-lite supports the closure / capture paths these
probes need, run only the macro and memory benches above.

When that gap closes (TODO #295: "selfhost perf gap cutover 水準まで"),
these micro-benches will surface per-phase hotspots — lexer keyword_lookup
cost, parser infix-chain dispatch, env_lookup walk depth — without I/O or
wasm-runtime overhead.

## String-keyed lookup: postmortem on the "hash index" attempt

A natural target for the selfhost perf gap is the string-keyed
linear scans in codegen: `resolve_func` walks `FuncTable.names` and
`lookup_ctor` walks `CtorTable.names` per call site / per pattern arm.
For an N-function module this is O(N) per resolution, and the cost
appears in every `compile_expr` recursion.

Adding a `name_index: Map[String, Int]` to both tables and rewriting
`resolve_func` / `lookup_ctor` to do `Map::has_key` + `Map::get` was
implemented in commits `0f32aa2` + `e011e4a` and then reverted in
`fad9703` + `85aff03` after on-target measurement showed **no
improvement** even with N=50 user functions:

| input                  | old (linear) | indexed (Map) |
| ---------------------- | ------------ | ------------- |
| sample.vibe (1 func)   | 1.225 s      | 1.241 s       |
| heavy.vibe (13 funcs)  | 2.061 s      | 2.083 s       |
| big.vibe (50 funcs)    | 2.038 s      | 2.030 s       |

(Each measurement: hyperfine --warmup 1 --runs 5 invoking the
canonical selfhost wasm via run_wasm_vibe_host_runner.sh; differences
are within standard deviation.)

**Root cause**: vibe's runtime `Map[K, V]` in the WASM linear backend
is itself a linear search — see `wasm_codegen_builtin_collection.mbt`,
"Map::has_key (linear search for key, return tagged bool)" and
"Map::get (linear search for key, return value)". So the indexed
path performs `has_key` (O(N)) + `get` (O(N)) = 2N work per call,
which is strictly worse than the original O(N) array walk it
replaced. Even on the host CLI (MoonBit-implemented `vibe.exe`)
the same builtin emits a linear scan, so the host doesn't see a
win either.

Implications for any future "string-keyed lookup speedup" work in the
selfhost compiler:

1. **Hash-keyed lookup via `Map[String, _]` is a no-op** until vibe's
   runtime upgrades `Map` to a real hash table.
2. **Sorted index + binary search** also won't help directly — the
   per-comparison cost is still a string equality walk, and N is
   small enough that constant factors dominate.
3. **A custom hash-bucket structure** (parallel arrays of
   `Array[(String, Int)]` indexed by `hash(name) mod K`) IS still
   tractable inside codegen and would benefit even on the existing
   linear `Map`.

   Implemented in `e099f56` as `StrIntIndex` in
   `vibe/compiler/codegen/common_base/index.vibe` (djb2 hash, power-of-2
   bucket count chosen by `str_int_index_default_buckets`, plain
   `Array::push` / `Array::get` only). Sanity-verified end-to-end:

   | input        | N (user fns) | old (linear)  | strint        |
   | ------------ | ------------ | ------------- | ------------- |
   | sample.vibe  | 1            | 1.201 ± 0.015 s | 1.190 ± 0.084 s |
   | medium.vibe  | 65           | 2.075 ± 0.027 s | 2.077 ± 0.035 s |

   No measurable change at this scale because node + wasm
   instantiation dominates the ~2s wallclock; the codegen phase
   itself is ~50 ms and the lookup work is a small fraction of that.
   For the optimization to surface, the canonical selfhost compiler
   needs to handle workloads with N >> 65 (currently blocked by
   feature gaps — long binop chains overflow the parser stack at
   N≈100, deeply nested let-chains crash even sooner).

   Kept in place as scaffolding: `resolve_func` uses the index when
   populated and falls back to the original linear scan otherwise,
   so legacy callers keep working unchanged.

4. **The bigger lever** for selfhost perf on small-to-medium inputs
   remains `wasm-opt -O3` (already wired) and the moonrun → wasmtime
   AOT switch (blocked on WASI binding reshape), not algorithmic
   improvements.
