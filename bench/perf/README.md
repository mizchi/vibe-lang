# Performance benchmarks

CI heap KPI gate, micro benches, and perf-investigation postmortems for the
compiler / checker.

## Selfcompile KPI heap gate (CI, #987)

Driver: `scripts/selfcompile_kpi.sh <stage2.wasm> [input.vibe]`.

> The merge-base delta replacement and its isolated Docker validation lane are
> documented in
> [`docs/selfcompile-heap-policy.md`](../../docs/selfcompile-heap-policy.md).
> The workflow-dispatch lane is temporary validation scaffolding, not required
> CI. Until governance and final wiring land, the absolute gate below remains
> authoritative; the new policy does not relax it.

One real compile through a selfhost stage2, reporting `wall_ms` and
`heap_ptr_bytes` (linear backend bump-allocator high-water). With a cold
isolated `VIBE_BUILD_CACHE_DIR` the heap number is byte-deterministic across
repeated trials in one materialized tree, so — unlike wall time — the current
absolute gate can use it without flakes. The policy controller additionally
uses CLI-only `content-v1` stat tokens to make identical clean tree
reconstructions deterministic; this does not change the standalone/default
metadata token behavior described here. See the remaining isolation-validation,
governance, and metric-ABI boundaries in
[`docs/selfcompile-heap-policy.md`](../../docs/selfcompile-heap-policy.md).

CI wiring (`.github/workflows/ci.yml`, step "Selfcompile KPI heap gate"):
the compiler-gate job runs the script against its freshly-built stage2 and
fails when `heap_ptr_bytes` exceeds the committed baseline in
[`heap_baseline.txt`](heap_baseline.txt) by more than 10%
(`VIBE_KPI_MAX_HEAP_BYTES = baseline * 110 / 100`).

The baseline tracks the compiler itself: any change to
`lib/@vibe/compiler/` (or the default input file) can move it. During the
Phase A transition, rebaseline alongside intentional changes — in either
direction; ratchet it down after an allocation win so the old gate protects
the win. After Phase B this file remains investigation history only; it is not
an authority for the comparative gate:

```bash
bash scripts/generations.sh build --out-dir /tmp/kpi_gen
bash scripts/selfcompile_kpi.sh /tmp/kpi_gen/stage2.wasm
# -> copy heap_ptr_bytes into bench/perf/heap_baseline.txt
```

Commit the new number with the compiler change and note old -> new (and
why) in the PR.

## User edit-cycle baseline

Design and KPI contract: [`docs/incremental-build.md`](../../docs/incremental-build.md).
The first baseline measures the current one-shot `vibe check` path with an
isolated cache and temporary copy of a two-file project:

```bash
cargo build --release --manifest-path runtime/viberun/Cargo.toml
VIBE_EDIT_CYCLE_RUNS=5 pkf run kpi-edit-cycle -- \
  _build/selfhost/generations/<tag>/stage2.wasm \
  _build/edit-cycle-kpi.jsonl
```

Cases are cold, exact no-op with a preserved cache, comment-only edit, private
body edit, and public interface edit. Output is one JSON object per case/run;
median summaries go to stderr. Each successful check includes validated,
disabled-by-default `db_typecheck_fs` counters for planned, rechecked,
reused-without-a-body-parse, and failed/blocked modules plus parse operations.
Reuse can come from in-memory or persistent state; it is not a per-cache-class
hit counter. This initial probe does not yet measure a
resident LSP/runnable artifact or complete invalidation/codegen work. It is a
read-only baseline for deciding whether the existing persistent cache has a
user-visible effect before changing the artifact model. Shared-runner wall time
is advisory, not a blocking gate.

## Compiler output size ratchet (`scripts/size_ratchet.sh`, #1109-4)

The second blocking gate. It compiles every `bench/binary_size/*.vibe`
sample with the freshly-built stage2 and fails when any result exceeds its
entry in [`size_baseline.txt`](size_baseline.txt) by more than **2%**
(`VIBE_SIZE_TOLERANCE_PCT` overrides). Like the heap number these sizes are
byte-deterministic for a fixed (stage2, sample) pair, so the gate cannot
flake; the tolerance is tight because they move only when codegen itself
changes.

**Gated: what the compiler PRODUCES. Not gated: what the compiler IS.** A
codegen regression here makes every user program bigger, so it is worth
blocking on. The compiler's own artifacts (`stage2.wasm`, the committed
bundles, the flat module source) legitimately grow whenever a feature lands
— ADR-0076 追記34 V2 alone added ~2.4% — so gating them would fight ordinary
development. The perf report below still tracks them.

The gate also fails when the baseline lists a sample that no longer exists,
so the table cannot silently drift out of sync with the corpus.

```bash
bash scripts/generations.sh build --out-dir /tmp/size_gen
bash scripts/size_ratchet.sh /tmp/size_gen/stage2.wasm --print
# -> copy the reported lines into bench/perf/size_baseline.txt
```

Same discipline as the heap baseline: rebaseline in either direction with
the codegen change, ratcheting DOWN after a size win so the gate protects
it, and note old -> new (and why) in the PR.

## Continuous perf tracking (per-PR report + main history)

The `perf-metrics` job in `.github/workflows/ci.yml` runs on every PR and every main push, after `compiler-gate`, reusing its stage2 and generated artifacts
(non-blocking — the blocking allocation gate stays in ci.yml's KPI step):

- `scripts/bench_metrics.sh <stage2.wasm> [out.json]` collects one snapshot:
  - **deterministic**: selfcompile `heap_ptr_bytes` (cold cache), stage2 /
    committed-bundle / flat-module-source byte sizes, compiled wasm size of
    every `bench/binary_size/` sample, `bytes_per_op` of every `bench {}`
    block listed in [`tracked_benches.txt`](tracked_benches.txt), and the
    **exec corpus** (below),
  - **advisory** (wall time, noisy on shared runners): selfcompile `wall_ms`
    (median of 3) and `ns_p50` per tracked bench — recorded in the snapshot
    for history, **not rendered** in the report (below).
- `scripts/bench_report.mjs current.json [baseline.json]` renders the
  markdown comparison — **deterministic rows only**, flagged at ±2%. Advisory
  wall times are deliberately absent: runner-speed variance swung every wall
  row ±15-40% on unrelated PRs, which made the section noise for human and
  LLM readers alike (the #1207/#1867 reports are the record). The readings
  stay in the `bench-data` snapshots for offline analysis.
- **Per-PR**: the workflow upserts a sticky "📊 Perf report" comment on the
  PR (marker `<!-- vibe-perf-report -->`), comparing against the latest
  main snapshot. Pushing new commits updates the same comment.
- **History**: every main push appends the snapshot to the `bench-data`
  branch (`data/main.jsonl`, one JSON object per line, plus `latest.json` =
  the PR baseline). Plot or diff over time straight from that branch:

  ```bash
  git fetch origin bench-data
  git show origin/bench-data:data/main.jsonl | tail -20 \
    | node -e 'process.stdin.on("data",()=>{}); ...'   # or jq
  ```

### Exec corpus: deterministic fuel / memory / backend parity (`bench/exec/`)

Wall time on shared runners kept producing perf reports where every advisory
row swung ±15-40% on unrelated PRs (see #1207 and the calibration section
below — sometimes the calibration factor itself lands outside the plausible
range and the whole advisory section falls back to raw noise). The exec
corpus replaces "how fast did this run today" with a number the runner
cannot touch: **wasmtime fuel**, charged per executed instruction from a
static cost table. For the pure, input-free programs in
[`bench/exec/`](../exec/README.md) a fuel reading is byte-stable across
machines and runs — it moves only when codegen (or the scenario source)
changes, so the report flags it tightly (±2%) like the other deterministic
rows. Fuel IS a function of the wasmtime version; the snapshot records it
(`exec.wasmtime`) and the report omits fuel deltas when the two snapshots
metered on different versions.

Per scenario the snapshot records, for **both** the linear and the wasm-gc
backend: fuel, wasm size, and (linear) bump-heap `allocated` + `committed`
bytes — plus two correctness checks whose failure is rendered louder than
any perf delta (silent-wrong is the worst failure class,
`docs/issue-triage.md`): the linear stdout must equal the committed golden
(`bench/exec/expected/`), and the gc stdout must equal the linear stdout.
A scenario the gc backend cannot compile/run is recorded per scenario with
the compiler's own diagnostic (e.g. `higher_order`: `GC codegen: unknown
constructor or function: Array::map`) — the gc feature gap stays visible in
every report instead of unmeasured. The corpus is deliberately **general
user-shaped programs** (strings, sorting, closures, ADT interpreter, bytes /
bit ops, tokenizing, sieve, records) rather than yet another view of the
selfhost compiler — `parser_bench` already covers that side.

The fuel meter lives in viberun (`VIBE_FUEL=1` → `vibe::fuel consumed=<n>`
on stderr, one machine-readable line, fresh `.wasm` only — a `.cwasm` was
serialized without fuel instrumentation). It composes with the existing
`VIBE_MEM=1` report.

### Test coverage in the perf report (main-only measurement)

The report's "Test coverage" section shows the selfhost suite's **union**
rates (function / branch — each source function/branch counted once, #1556)
with a percentage-point trend vs the previous measurement. The numbers come
from ci.yml's `coverage-suite` job, which is **main-only** (it re-runs the
whole test battery instrumented — too expensive per PR): after the ratchet
gate it extracts a compact snapshot (`scripts/coverage_bench_snapshot.mjs`)
and appends it to the `bench-data` branch (`coverage_latest.json` +
`data/coverage.jsonl`, same retry pattern as the perf snapshot). The perf
workflow fetches `coverage_latest.json` alongside the perf baseline and
passes it to `bench_report.mjs` as the third argument.

Because the measurement is main-only, the section is labeled **"measured on
main, not this PR"** — a PR's perf comment shows the repo's current coverage
and its main-to-main trend, never the PR's own effect (implying otherwise
would be silently wrong). The entry-weighted rates are deliberately not
shown: their denominator dilutes with every added test entry, which reads as
a regression when coverage actually grew (see the rebaseline notes in
`scripts/coverage_suite.sh`). The blocking ratchet stays in the
coverage-suite job itself. Tests: `pkf run test-perf-report`.

### Runner normalization (calibration) — history-only since the exec corpus

> **Status:** the calibration record is still collected into every snapshot
> (it remains the honest way to diagnose "was that swing the runner or the
> code?" when reading `bench-data` history offline), but `bench_report.mjs`
> no longer renders advisory wall times at all, so it no longer applies the
> runner factor to anything. The mechanism below is kept documented because
> the snapshots still carry the fields and history spans both eras.

Shared CI runners vary in raw speed from run to run — a PR's own diff has
nothing to do with it. The #1207 investigation caught this directly: its
perf report showed every single advisory metric slower by +20-64%, and an
unrelated docs-only PR (#1206) landed immediately before it showed the
*opposite* uniform swing (-15% to -27%). Both are the signature of
runner-to-runner variance, not a real regression — confirmed by rebuilding
both commits on the same machine back-to-back, which showed only
normal-range noise.

To make that visible automatically instead of requiring a manual
same-machine re-run every time a report looks off, `bench_metrics.sh` also
benches one fixed, already-tracked series (`alloc_bench.vibe`'s
`build_100`, ~10us/op — large enough to avoid the sub-100ns measurement
noise a tiny bench like `pure_bench.vibe`'s `fib30` shows) compiled against
the **committed seed** (`bootstrap/seed/compiler.wasm`) instead of the PR's
own freshly built stage2. The seed only changes on a deliberate bootstrap
bump (`docs/bootstrap.md`), so this reading is comparable across almost
every historical snapshot and isolates "how fast is this runner right now"
from anything about the PR's own codegen. The result is stored as a
`calibration: { label, ns_p50, seed_sha256, runner_sha256, bench_sha256 }`
field in the snapshot JSON.

All three hashes are recorded and compared, not just the seed: the viberun
runner binary and the calibration bench source are both read from the
*current checkout*, so a PR that changes `runtime/viberun` or
`bench/regression/alloc_bench.vibe` would otherwise have that real change
misread as pure host-speed drift and divided out of every advisory delta.
`bench_report.mjs` only applies the runner factor when all three hashes
are present and equal on both snapshots; otherwise it falls back to raw,
unnormalized deltas with a note explaining why.

The calibration source must be a bench the seed can *always* compile.
`lib/@vibe/compiler/*.vibe` bench files (e.g. `parser_bench.vibe`) are out —
they evolve with the compiler and routinely use syntax an older seed
doesn't understand yet (confirmed by hand: an older seed fails outright to
compile the current `parser_bench.vibe`). `bench/regression/*.vibe` files
are plain, syntax-stable programs with no such risk, which is why
`alloc_bench.vibe` was picked over a `lib/@vibe/compiler/` bench.

`bench_report.mjs` divides the current snapshot's calibration `ns_p50` by
the baseline's to get a `runnerFactor`, and divides every advisory
(wall-time) reading by that factor before computing its Δ — so a runner
that's uniformly N% slower today no longer shows up as an N% regression on
every single benchmark. Deterministic metrics (heap, sizes, bytes/op) are
never normalized; they don't depend on runner speed to begin with.

A single calibration series is not trusted outside the inclusive
**0.85–1.18×** plausibility range. Such a reading is reported as a `runner
mismatch`, and advisory rows show raw deltas rather than normalized warning
conclusions. This is deliberately fail-open: an uncorrected noisy reading is
more honest than dividing every row by an implausible factor. Normalization is
also skipped, falling back to raw deltas with a note in the report, when either
snapshot lacks calibration data (e.g. an older snapshot predating this
feature) or any recorded calibration input hash differs between them (for
example, a bootstrap bump landed between the two commits, making the readings
not comparable).

To track a new micro bench, add its file to `tracked_benches.txt` (keep the
whole list fast — it runs on every PR). To track a new size sample, drop a
standalone `main`-entry program into `bench/binary_size/`. Run locally:

```bash
bash scripts/generations.sh build --out-dir /tmp/gen
cargo build --release --manifest-path runtime/viberun/Cargo.toml  # micro benches
bash scripts/bench_metrics.sh /tmp/gen/stage2.wasm /tmp/m.json
node scripts/bench_report.mjs /tmp/m.json            # vs no baseline
```

## Micro: vibe bench probes

Files:
- `lib/@vibe/compiler/lexer_hotspot_probe.vibe` + `lexer_bench.vibe`
- `lib/@vibe/compiler/parser_hotspot_probe.vibe` + `parser_bench.vibe`
- `lib/@vibe/compiler/parser_control_bench.vibe` (optional `parser-control` phase)
- `lib/@vibe/compiler/checker_hotspot_probe.vibe` + `checker_bench.vibe`
- `lib/@vibe/compiler/bundle_bench.vibe` (optional `bundle` phase)
- `lib/@vibe/compiler/codegen_bench.vibe` (optional `codegen` phase)

Driver: `scripts/profile_compile.sh` → `pkf run bench-compile-hotspots -- <stage2.wasm>`.
(`scripts/bench_selfhost_compile_hotspots.sh` and its `just` recipe were
replaced in #851.)

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

15 / 15 micro-benches pass:

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
| `check_seq_chain_96`          | 15,203    |
| `check_nested_if_64`          | 15,960    |
| `check_large_match_48`        | 16,312    |
| `check_deep_binop_64`         | 16,687    |
| `check_chained_lets_64`       | 17,357    |
| `parse_deep_binop_chain`      | 207,601   |
| `lex_checker_vibe`            | 213,214   |
| `lex_token_payload_walk`     | 214,297   |
| `lex_synthetic_keyword_heavy`| 214,320   |
| `lex_lexer_vibe`              | 219,514   |
| `lex_parser_vibe`             | 221,608   |
| `parse_wide_match`            | 226,311   |
| `parse_parser_vibe`           | 331,918   |
| `parse_checker_vibe`          | 332,891   |
| `parse_lexer_vibe`            | 363,787   |
| `loader_manifest_list`        | 114,054   |
| `loader_manifest_groups`      | 148,944   |

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
