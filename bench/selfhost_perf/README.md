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

### `-Oz` is the default, not `-O3`

Counter-intuitive but verified: under `moonrun`, **`-Oz` is faster
than `-O3`**. moonrun is interpreter-flavoured, so wallclock tracks
the dispatched-instruction count. -O3 unrolls loops and inlines
aggressively, which grows instruction count and *hurts* moonrun.
-Oz minimizes instruction count and ships smaller — strict win on
this runtime.

Variant comparison on examples/basics.vibe (compile-lite, hyperfine
--warmup 2 --runs 8):

| variant            | mean ms   | wasm size | ratio vs raw |
| ------------------ | --------- | --------- | ------------ |
| raw release        | 284.4     | 2.78 MB   | 1.00×        |
| -O3                | 138.4     | 3.07 MB   | 2.06×        |
| **-Oz** (default)  | **116.5** | **2.01 MB** | **2.44×**  |
| -O3 then -Oz       | 141.2     | 2.96 MB   | 2.01×        |

Override with `WASM_OPT_LEVEL=-O3` (etc.) for downstream targets that
have a different cost model (a JIT/AOT runtime would prefer -O3
since instruction count is no longer the bottleneck).

### End-to-end memory bench

`examples/basics.vibe` (single-run hyperfine, --warmup 1 --runs 3):

| metric              | host    | self (raw debug) | self (release + -Oz) | ratio (raw → opt) |
| ------------------- | ------- | ---------------- | -------------------- | ----------------- |
| compile mean ms     | 38.7 ms | 247 ms           | **129.0 ms**         | 6.25× → **3.33×** |
| compile peak RSS    | 16.4 MB | 100 MB           | **73.7 MB**          | 6.18× → **4.51×** |
| check mean ms       | 106 ms  | 285 ms           | **204.7 ms**         | 2.66× → **1.92×** |
| check peak RSS      | 22.3 MB | 70.0 MB          | **52.6 MB**          | 3.09× → **2.35×** |
| compile wasm size   | —       | 6.82 MB          | **2.00 MB**          | -71%              |
| check wasm size     | —       | 3.04 MB          | **0.91 MB**          | -70%              |

The remaining gap is dominated by `moonrun`'s wasm interpretation
overhead; bigger wins after this point require a faster runtime
(wasmtime AOT, blocked on WASI-binding reshape — selfhost wasi entry
imports `spectest::print_char` plus ~30 `__moonbit_fs_unstable::*`
ABI functions; the project has a parallel `selfhost_compiler.wasm`
component path under `scripts/build_selfhost_cli_direct_component.sh`
that runs under wasmtime via WASI Preview2 + a small `Env`/`Fs`
shim, but exercising it requires `wac` + a Rust adapter component
build that isn't wired into the bench drivers yet). Tracked under
TODO #295.

### Other levers surveyed (already in place, no new work needed)

- **`vibe run` persistent artifact cache** (cli_run_cmd.mbt,
  `run_monolithic_cache_paths`): hashes source files, reuses the
  cached `.wasm` when content unchanged. Verified: cold ~1146 ms,
  warm ~107 ms = **10× speedup** on sample.vibe. Note `compile-lite`
  intentionally bypasses this cache because it is the bench's
  measurement point.
- **`vibe compile` imports + library cache** (cli_compile_cmd.mbt
  l.510): same source-hash gate around library wasm regeneration.
- **`session-http` daemon** (cli_session.mbt): auto-spawned by
  `vibe run` / `vibe test` when a self-bin is resolvable
  (`VIBE_USE_SESSION_HTTP=0` to disable). Amortizes startup across
  many short invocations from LSP / batch test runners. **Caveat**:
  for one-shot small-input invocations, the IPC overhead loses to
  direct execution — measured 42 ms (no-session, cache-warm) vs
  108 ms (session-http) on sample.vibe. The daemon wins only when
  the client makes many requests in sequence.

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

**Was blocked** by a host-CLI codegen pathology (not a closure
capture gap as originally hypothesized). **Now unblocked** by three
opt-in env hatches; the underlying `@wite.optimize_binary_for_size`
scaling issue is left for a future fix.

### Root cause

`vibe bench` calibration compiles each bench body via
`compile_module_wasm_with_opt_level` with `no_dce=true`,
`debug_errors=true`, `opt_level=Some("-Oz")`, `http_host_imports=true`,
`fs_host_imports=true`. The smoking gun is the `-Oz` step: it does NOT
shell out to binaryen `wasm-opt`, it runs the in-process MoonBit
optimizer `@wite.optimize_binary_for_size` (mizchi/wite package).

That in-process optimizer is **pathological on no-DCE 4-5 MB
selfhost-import wasm**: a single -Oz pass hangs >4 minutes vs ~5
seconds for the equivalent binaryen `wasm-opt -Oz` on the same input.
Verified by isolating flags on `vibe compile vibe/compiler/selfhost_loader_collect_bench.vibe`:

| flags                                    | outcome             |
| ---------------------------------------- | ------------------- |
| `--no-dce`                               | 8.3 s, 4.94 MB out  |
| `--no-dce -Oz`                           | >4 min hang         |
| `--no-dce --debug-errors -Oz`            | >4 min hang         |
| `--no-dce --debug-errors`                | >3 min hang         |

### Real fix: shell out to binaryen wasm-opt (commit `cc63caa`)

`vibe bench` calibration now compiles the bench wrapper with
`opt_level=None` (raw wasm — fast) and then pipes the bytes through
the binaryen `wasm-opt` CLI for the requested level. Resolution
order:

1. `~/.moon/bin/moon-wasm-opt` (binaryen v125 bundled with moonbit;
   always compatible with moon-emitted wasm)
2. PATH `wasm-opt`, only if its version line parses as `>= 118`
   (Ubuntu 24.04's apt v108 and `cargo install wasm-opt`'s v116
   cannot parse moon-emitted wasm)

If neither is found / shell-out fails, `vibe bench` falls back to
the in-process `@wite.optimize_binary_for_size` path — same
pathological behaviour as before, but compatibility-preserving.
If @wite ALSO fails, raw bytes are used (un-optimized timing —
each iter slower, but the bench still completes and relative
numbers stay meaningful).

This makes selfhost-import benches work out-of-the-box: as of
`cc63caa`, `selfhost_loader_collect_bench.vibe` finishes calibration
in 11.9 s with no env hatches set (the previous workaround required
all three of `VIBE_BENCH_NO_DCE=0`, `VIBE_BENCH_DEBUG_ERRORS=0`,
`VIBE_BENCH_OPT_LEVEL=none`).

### Optional env hatches (mostly historical now)

| env var                     | default | effect                                                    |
| --------------------------- | ------- | --------------------------------------------------------- |
| `VIBE_BENCH_NO_DCE=0`       | true    | turns DCE on so unreachable selfhost code paths get pruned |
| `VIBE_BENCH_DEBUG_ERRORS=0` | true    | drops `--debug-errors`-equivalent throw-string preservation |
| `VIBE_BENCH_OPT_LEVEL=none` | -Oz     | skips optimization entirely (raw bytes — useful for un-opt timing comparisons) |

The shell-out path is the default workaround for `-Oz`, so the
hatches are no longer required to unblock selfhost benches; they
remain useful for environments without binaryen, for measuring
un-optimized iteration cost, or for sanity comparisons.

### Verified results

15 / 15 selfhost micro-benches pass:

| file                                        | wallclock | benches |
| ------------------------------------------- | --------- | ------- |
| `selfhost_lexer_bench.vibe`                 | 3.8 s     | 5/5     |
| `selfhost_parser_bench.vibe`                | 8.1 s     | 5/5     |
| `selfhost_checker_bench.vibe`               | 10.8 s    | 5/5     |
| `selfhost_loader_collect_bench.vibe`        | 12.3 s    | 2/2     |

Per-iteration medians (μs, 1-iter calibration on no-opt wasm so these
are upper bounds):

| bench                                  | median μs |
| -------------------------------------- | --------- |
| `selfhost/check_seq_chain_96`          | 15,203    |
| `selfhost/check_nested_if_64`          | 15,960    |
| `selfhost/check_large_match_48`        | 16,312    |
| `selfhost/check_deep_binop_64`         | 16,687    |
| `selfhost/check_chained_lets_64`       | 17,357    |
| `selfhost/parse_deep_binop_chain`      | 207,601   |
| `selfhost/lex_checker_vibe`            | 213,214   |
| `selfhost/lex_token_payload_walk`     | 214,297   |
| `selfhost/lex_synthetic_keyword_heavy`| 214,320   |
| `selfhost/lex_lexer_vibe`              | 219,514   |
| `selfhost/lex_parser_vibe`             | 221,608   |
| `selfhost/parse_wide_match`            | 226,311   |
| `selfhost/parse_parser_vibe`           | 331,918   |
| `selfhost/parse_checker_vibe`          | 332,891   |
| `selfhost/parse_lexer_vibe`            | 363,787   |
| `selfhost/loader_manifest_list`        | 114,054   |
| `selfhost/loader_manifest_groups`      | 148,944   |

Lex / parse / loader cases are dominated by per-iteration runtime
startup (calibration runs only 1 iteration for selfhost-heavy
imports because each iter is already > 100 ms). The five checker
cases skip I/O entirely (synthetic Expr trees, in-memory) and land
at 15-17 ms per iter — the first credible per-call cost view we
have for the selfhost type-checker.

### Real fix

Out of this session's scope. The underlying improvement targets are:

1. Fix `@wite.optimize_binary_for_size` scaling on no-DCE 4-5 MB
   wasm (or short-circuit to `wasm-opt` shell-out when one is
   available), so the env hatches stop being necessary.
2. Pre-compile heavy probe imports into a runtime artifact and have
   the bench harness only compile the bench body, removing the
   transitive selfhost compile from the hot path entirely.

Tracked under TODO #295 ("selfhost perf gap cutover 水準まで").

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

   Implemented and reverted. Commits `e099f56` (StrIntIndex with
   djb2 hash + power-of-2 buckets, plain `Array::push`/`Array::get`
   only, no `Map[K,V]`) and `397d083` (microbench file). Reverted in
   `67cf7d7` + `832d315` after measuring both layers:

   **Microbench** (`bench/bench_str_int_index.vibe`, vibe bench
   compiled backend, 5 runs × 100k batch, N=100):

   | op             | linear (μs/op) | hashed (μs/op) | speedup |
   | -------------- | -------------- | -------------- | ------- |
   | last           | 0.6488         | 0.1305         | 4.97×   |
   | mid            | 0.4039         | 0.1092         | 3.70×   |
   | missing        | 0.4359         | 0.1060         | 4.11×   |

   The bucket lookup IS faster — proves the data structure is sound.

   **Integration** (canonical selfhost wasm via node host runner,
   hyperfine `--warmup 3 --runs 8`):

   | input        | N user fns | old (linear)    | strint           |
   | ------------ | ---------- | --------------- | ---------------- |
   | sample.vibe  |  1         | 1.201 ± 0.015 s | 1.190 ± 0.084 s  |
   | medium.vibe  | 65         | 2.075 ± 0.027 s | 2.077 ± 0.035 s  |

   Within noise. Math: ~50 resolve_func calls per compile × 0.4μs
   saved each = 20μs total — invisible in a 2 s wallclock dominated
   by node + wasm instantiation. Wider tests (N≈100, N≈200) crashed
   the canonical selfhost compiler (parser stack overflow on long
   binop chains, deep let-chain overflow), so the cross-over where
   StrIntIndex would surface in user-visible time is past current
   selfhost feature gaps.

   **Decision: not adopted.** The 4-5× microbench speedup is real
   but doesn't translate to measurable improvement at any selfhost
   workload size we can currently exercise; the +140 lines + ~8 KB
   wasm + extra struct to maintain don't pay rent yet. The
   microbench file (`bench/bench_str_int_index.vibe`) is kept as the
   reference experiment so a future revisit can re-run it with an
   updated cross-over threshold.

4. **The bigger lever** for selfhost perf on small-to-medium inputs
   remains `wasm-opt -O3` (already wired) and the moonrun → wasmtime
   AOT switch (blocked on WASI binding reshape), not algorithmic
   improvements.
