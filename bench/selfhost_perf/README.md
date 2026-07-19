# Selfhost performance benchmarks

Macro and micro benches for the self-hosted vibe compiler / checker.

## Macro: stage-level wallclock

Driver: `scripts/bench_selfhost_perf.sh` → `pkf run bench-selfhost-perf`.

Compares host CLI vs selfhost wasm (under `moonrun`) on the cases listed in
`cases.txt`. Median of N runs (default 3) per phase per stage; emits ratio
gates that `pkf run test-selfhost-perf-gate` enforces.

Output: `_build/bench/selfhost_perf/{summary,stage_summary}.{e2e,in-memory}.tsv`.

### Compiler artifact selection

By default the selfhost side still uses the historical MoonBit-built
compiler wasm:

```bash
_build/wasm/<debug|release>/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm
```

To measure the vibe-side CLI compiler path, opt into the selfhost CLI
core artifact:

```bash
VIBE_SELFHOST_PERF_COMPILER_KIND=cli-core scripts/bench_selfhost_perf.sh
```

This builds `lib/@vibe/cli/entry.vibe` to
`_build/bench/selfhost_cli_core/index_stage1.wasm` via
`scripts/build_selfhost_cli_core.sh`, then runs the normal
`compile-lite` bench commands against that wasm. Because this artifact
uses the vibe host ABI (`vibe::env-get`, `vibe::fs-read-file`, etc.),
the compiler side runs through `scripts/run_wasm_vibe_host_runner.sh`
instead of `vibewt`; `VIBE_SELFHOST_PERF_RUNTIME` still controls the
MoonBit-built checker runner when `VIBE_SELFHOST_PERF_CHECKER_KIND=moonbit`.
When `VIBE_SELFHOST_PERF_COMPILER_KIND=cli-core`, the checker side also
defaults to `cli-core`, so both compile and check requests go through the
vibe-side CLI artifact. Override with
`VIBE_SELFHOST_PERF_CHECKER_KIND=moonbit|cli-core`.

For `cli-core`, compile/selfhost requests default to a JSONL daemon mode
inside `scripts/wasm_vibe_host_runner.js`
(`VIBE_SELFHOST_PERF_COMPILE_DAEMON=1`). This keeps the Node host runner
and WebAssembly instance warm across all cases, matching the checker
daemon's amortized mode. Set `VIBE_SELFHOST_PERF_COMPILE_DAEMON=0` to
measure cold per-invocation runner cost; those numbers include Node
startup and are not comparable to the wasmtime `vibe_compile_wasi` gate.
`VIBE_SELFHOST_PERF_CHECK_DAEMON=1` enables the same daemon shape for
checker requests.

### wasmtime AOT runtime (default, #402 Phase 2)

The bench driver's `VIBE_SELFHOST_PERF_RUNTIME` defaults to
`wasmtime-aot`. It runs the stage1 wasm under a small Rust wasmtime
host (`runtime/moonrun_wasmtime`, binary `vibewt`) that
re-implements the moonbit `--target wasm` import surface
(`spectest::print_char` + `__moonbit_{fs,time,sys}_unstable::*`,
32 functions) and Cranelift-JITs the module. `wasmtime-aot` also
`precompile`s each stage1 wasm to a `.cwasm` sibling so subsequent
instantiations skip Cranelift entirely.

Opt back into the legacy `moonrun` (v8 interp) path with
`VIBE_SELFHOST_PERF_RUNTIME=moonrun` — useful in environments
without a rust toolchain. The CI KPI step uses `wasmtime-aot` with
tightened TOTAL-ratio caps: `compile 2.0 / check 5.0` (was 10.0 /
8.5 under moonrun). Sized against measured CI baselines (compile
~1.00, check ~2.88 with `VIBE_USE_SESSION_HTTP=0`) to catch
moonrun-class regressions while absorbing CI's ±30% variance band.

Measured on the default 5-case set (debug profile wasm, no wasm-opt,
median of 3 runs):

| case                                  | moonrun ratio | wasmtime-aot ratio | ratio speedup |
| ------------------------------------- | ------------- | ------------------ | ------------- |
| examples/basics.vibe                  | 6.22          | 1.21               | **5.1×**      |
| bench/compiler_size/cases/base64.vibe | 5.75          | 1.81               | **3.2×**      |
| bench/compiler_size/cases/effects.vibe| 5.70          | 0.98               | **5.8×**      |
| bench/compiler_size/cases/module_export.vibe | 5.31   | 1.00               | **5.3×**      |
| bench/compiler_size/cases/module_import.vibe | 5.82   | 1.05               | **5.6×**      |

Run via:

```bash
VIBE_SELFHOST_PERF_RUNTIME=wasmtime-aot pkf run bench-selfhost-perf-wasmtime
# or directly
scripts/bench_selfhost_perf.sh
```

Set `VIBE_SELFHOST_PERF_RUNTIME=wasmtime` to skip the AOT step (loses
the per-invocation Cranelift cost). Set `MOONRUN_WT_BIN` to point at a
prebuilt `vibewt` (otherwise the driver builds it on first use).

### Runtime-aware wasm-opt level

Each runtime has a different sweet-spot for binaryen's optimization
level — interpreters benefit from `-Oz` (instruction count), JITs
benefit from `-O3` (loop unrolling, inlining). When the bench leaves
`VIBE_SELFHOST_PERF_WASM_OPT_LEVEL` on `auto` (the default), the
driver picks per-runtime:

| runtime         | default level | rationale                                |
| --------------- | ------------- | ---------------------------------------- |
| moonrun         | `-Oz`         | v8 interp: instruction count wins        |
| wasmtime / -aot | `-O3`         | Cranelift JIT: loop unrolling pays off   |

Measured (release, examples/basics + base64 + effects, mean compile ratio):

| wasm-opt level | moonrun | wasmtime-aot |
| -------------- | ------- | ------------ |
| `-Oz`          | 2.48    | 1.02         |
| `-O3`          | 3.11    | **0.85**     |
| `-O4`          | 3.15    | 0.85         |

With auto level on wasmtime-aot the TOTAL compile ratio drops to
**0.80** (selfhost now beats host on these cases). The driver also
writes `_build/wasm/opt/.opt_level` so a runtime switch triggers a
single rebuild of the opt artifact, never a silent level mismatch.

Override with `VIBE_SELFHOST_PERF_WASM_OPT_LEVEL=-Oz|-O3|-O4|-Os|...`.

The same wins survive on the canonical CI artifact (release profile +
binaryen `wasm-opt -Oz`):

| case (release+Oz)                     | moonrun ratio | wasmtime-aot ratio |
| ------------------------------------- | ------------- | ------------------ |
| examples/basics.vibe                  | 2.64          | 1.14               |
| bench/compiler_size/cases/base64.vibe | 3.30          | 1.14               |
| bench/compiler_size/cases/effects.vibe| 2.48          | 0.98               |
| bench/compiler_size/cases/module_export.vibe | 2.49   | 0.95               |
| bench/compiler_size/cases/module_import.vibe | 2.56   | 1.00               |

Average ratio drop ~2.6× on opt'd wasm (still above the 1.5-2× target).

**Output parity**: `scripts/test_vibewt_parity.sh` (`pkf run
test-vibewt-parity`) compiles each case under both runtimes and
verifies the emitted `.wasm` is byte-identical. As of 2026-05-17 all
5 default cases match SHA-256 on both debug and release+Oz profiles.

**Import drift guard**: `scripts/check_vibewt_imports.sh` (`pkf
run check-vibewt-imports`) dumps the `--target wasm` import
surface from stage1 compile + check artifacts and diffs against
`runtime/moonrun_wasmtime/expected_imports.txt`. Fails if moonbit ever
emits a new host import we haven't wired into vibewt's
`register_imports()`. Refresh with
`scripts/check_vibewt_imports.sh --update` after implementing
the new import.

Both guards run in the `selfhost-runtime-parity` CI job (required).

`scripts/bench_selfhost_memory.sh` also accepts
`VIBE_SELFHOST_MEMORY_RUNTIME=wasmtime-aot` so peak-RSS measurement
can compare moonrun's v8 heap vs wasmtime's linear memory. It mirrors
the perf bench's auto opt-level (`-Oz` for moonrun, `-O3` for
wasmtime/-aot); override with `VIBE_SELFHOST_MEMORY_WASM_OPT_LEVEL`.
Both benches share `_build/wasm/opt/` and consult `.opt_level` so a
runtime switch rebuilds the wasm-opt artifact rather than silently
benching against the wrong level.

## Selfcompile KPI heap gate (CI, #987)

Driver: `scripts/selfcompile_kpi.sh <stage2.wasm> [input.vibe]`.

One real compile through a selfhost stage2, reporting `wall_ms` and
`heap_ptr_bytes` (linear backend bump-allocator high-water). With a cold
isolated `VIBE_BUILD_CACHE_DIR` the heap number is **byte-deterministic**
for a fixed (stage2, input) pair, so — unlike wall time — it gates CI
without flakes.

CI wiring (`.github/workflows/ci.yml`, step "Selfcompile KPI heap gate"):
the compiler-gate job runs the script against its freshly-built stage2 and
fails when `heap_ptr_bytes` exceeds the committed baseline in
[`heap_baseline.txt`](heap_baseline.txt) by more than 10%
(`VIBE_KPI_MAX_HEAP_BYTES = baseline * 110 / 100`).

The baseline tracks the compiler itself: any change to
`lib/@vibe/compiler/` (or the default input file) can move it. Rebaseline
alongside intentional changes — in either direction; ratchet it down after
an allocation win so the gate protects the win:

```bash
bash scripts/generations.sh build --out-dir /tmp/kpi_gen
bash scripts/selfcompile_kpi.sh /tmp/kpi_gen/stage2.wasm
# -> copy heap_ptr_bytes into bench/selfhost_perf/heap_baseline.txt
```

Commit the new number with the compiler change and note old -> new (and
why) in the PR.

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
overhead. The `wasmtime-aot` runtime variant addresses this directly
(see "wasmtime AOT runtime" below for the measured ~5× ratio drop).

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

## Micro: vibe bench probes

Files:
- `lib/@vibe/compiler/lexer_hotspot_probe.vibe` + `lexer_bench.vibe`
- `lib/@vibe/compiler/parser_hotspot_probe.vibe` + `parser_bench.vibe`
- `lib/@vibe/compiler/parser_control_bench.vibe` (optional `parser-control` phase)
- `lib/@vibe/compiler/checker_hotspot_probe.vibe` + `checker_bench.vibe`
- `lib/@vibe/compiler/bundle_bench.vibe` (optional `bundle` phase)
- `lib/@vibe/compiler/codegen_bench.vibe` (optional `codegen` phase)

Driver (host CLI compiled backend):
`scripts/bench_selfhost_compile_hotspots.sh` → `just bench-selfhost-compile-hotspots`.

These bench files type-check clean (`vibe check ...` passes) and define
per-case probes that exercise the selfhost lexer / parser / checker against
real selfhost sources and synthetic shapes (deep binop chains, wide match,
chained let / ESeq sequences, closure-heavy codegen).
`parser_bench.vibe` also includes parse-only probes with lazy
token caches, plus statement/type/expression subcategory probes, so parser
work can be separated from file read + lex noise before tuning.
`parser_control_bench.vibe` keeps the small block / if / match
parser-control probes in a separate bench file to reduce calibration
interaction with the larger file-level parser probes.
`bundle_bench.vibe` covers both source-heavy grouped merge
(`bundle_grouped_merge_*`) and group-heavy manifest shapes
(`bundle_many_groups_*`) so source concatenation changes and per-group
cache overhead can be tuned separately.

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
Verified by isolating flags on `vibe compile lib/@vibe/compiler/loader_collect_bench.vibe`:

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
`cc63caa`, `loader_collect_bench.vibe` finishes calibration
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
| `lexer_bench.vibe`                 | 3.8 s     | 5/5     |
| `parser_bench.vibe`                | 8.1 s     | 5/5     |
| `checker_bench.vibe`               | 10.8 s    | 5/5     |
| `loader_collect_bench.vibe`        | 12.3 s    | 2/2     |

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

TODO #295 ("selfhost perf gap cutover 水準まで") originally tracked
both items. The wasmtime AOT runtime (above) addresses lever #4 and
lever #2 partially.

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

## Linked-build `contains_name` / `contains_path` scans (#533)

`#533` re-opened the question of the linear `contains_name`
(`lib/@vibe/compiler/entry/source_compile/wasi_only/linked_helpers.vibe`,
3 sites) and `contains_path`
(`.../linked_artifacts.vibe`, 2 sites) scans that the linked-build
path uses to filter re-exported names and to dedup direct dependency
paths. Both delegate to helpers in `lib/@vibe/compiler/module_graph_path.vibe`.

**Re-classification (matches the #366 survey verdict).**

- `contains_name`: bounded by one re-export selection (`wanted_names`,
  ≈1–5 names) scanned once per pub statement of one source file —
  per-module, not whole-program. #366 measured ≈5–150 ops.
- `contains_path`: bounded by one entry file's unique imports
  (D ≈ 5–30), so the dedup is `O(D²)` with small D (≤ ~900 ops in
  #366's survey).

Both are dominated by the surrounding `Fs::ReadFile` + `lex` + `parse`
of the very same files, so the string-equality scans are not the
linked-build hotspot.

**Why we do not change the algorithm.**

1. **`Map[String, Bool]` is a no-op.** The selfhost runtime emits
   `Map::has_key`/`Map::get` as linear searches
   (`wasm_codegen_builtin_collection.mbt`); the dedicated runtime
   upgrade issue (#395) was closed *not-planned*. See the
   "String-keyed lookup" postmortem above.
2. **Sorted index + binary search does not help** — per-comparison
   cost is still a string-equality walk and D/W are small enough that
   constant factors dominate (same conclusion as the `resolve_func`
   postmortem above).
3. **A custom hash-bucket (`StrIntIndex`) does not pay rent.** The
   reverted experiment above showed a real 4–5× microbench win that
   did not translate to measurable selfhost wallclock at any workload
   size we can exercise.
4. **Sort + merge dedup of `dep_paths` is unsafe, not merely low-ROI.**
   The dedup must preserve first-occurrence order: `dep_paths` order
   flows into `linked_imports`, which `compile_wasi_module_linked_impl`
   (`lib/@vibe/compiler/codegen/wasi/linked_compile.vibe`) turns into wasm
   import-section indices and emission order. Reordering would change
   the emitted binary and break selfhost reproducibility/parity. This
   rules out the "input order normalization / sort + merge" option from
   the #533 scope on correctness grounds.

**Decision (per-module sites): keep the linear scans, order-preserving,
as-is.** The sites are annotated with these bounds and the reorder
hazard in `module_graph_path.vibe` and `linked_artifacts.vibe` so a
future contributor does not re-attempt the unsafe sort+merge.

### Whole-graph visited/scheduled sets → bucketed `path_set` (#533, round 2)

The re-grounding pass found the ACTUAL unbounded sites were not the
per-module scans above but the graph-traversal dedup structures, which
test membership against a set that grows to every module of the
program, once per import edge:

- `merge_sources.vibe` `collect_merged_stmts_recursive_impl` — `visited`
  linear scan per import edge → O(edges × modules).
- `loader/index.vibe` `collect_sources_rec` — same shape, and it runs on
  every manifest-less multi-module `vibe build/check` (FS collect).
- `loader/manifest_sources.vibe` × 3 worklist collectors — the
  `scheduled_set` was a `Map[String, Bool]`, and the runtime `Map::set`
  copies the WHOLE map per insert (O(N) each → O(N²) copying) on top of
  the linear `Map::has_key` per edge. These loops also carried a
  pop-time `contains_path(visited, current)` guard that could never
  fire (worklist entries are unique by construction) yet cost another
  full scan per node.

All of these are membership-only — output order always comes from the
recursion / the separate insertion-ordered `visited` array — so they
were switched to `path_set_new/contains/add`
(`module_graph_path.vibe`): 64 buckets of `Array[String]` keyed by a
masked djb2 hash, mutable `Array::push`-based, no runtime `Map`
involvement. This does NOT contradict the StrIntIndex postmortem above:
that experiment targeted `resolve_func` (~50 lookups per compile,
constant-size table); these sites do `edges × modules` work that grows
quadratically with project size.

**Measured** (probe entries appended to the flat bundle calling
`collect_sources_rec` directly, 10 iterations over a synthetic
501-module / ~1800-edge layered DAG, node host runner, means of 6
alternating runs): probe wallclock 232 ms → 190 ms; net collect phase
≈10.2 ms → ≈6.0 ms per walk (**-41%**). Cold-cache end-to-end
`VIBE_FS_COMPILE` of the same tree is unchanged (~600 ms, dominated by
read/lex/parse/check/codegen) and the emitted wasm is byte-identical
old vs new. Selfhost bundle compile KPI is unaffected (the flat bundle
has no imports, so the collectors see 1 module).

**Crash fix found by the same measurement** (would otherwise block any
~200+ module cold-cache FS compile): the inline `__to_string` handler
(linear `compile_call.vibe` and its gc port
`backend_builtins_numeric.vibe`) ran `memory.copy` into the fresh
allocation BEFORE bumping global 0 and running the heap grow check.
When the previous allocation left the heap pointer within a few bytes
of the memory end (the grow check only guarantees the pointer itself is
addressable, not a page of headroom), the copy trapped with "memory
access out of bounds" inside `compact_string_fingerprint` during the
persistent-cache key build. Reordered to bump + grow check first, then
copy. A cold-cache 501-module compile crashed deterministically before
the fix and passes after it.
