# CI test-execution speed & growth budget

Goal (2026-08-01): branch coverage is ~6% and needs to grow severalfold.
CI must stay **under 5 minutes** end-to-end as tests are added, so the
battery's cost model has to be sub-linear in test count. This page records
the measured cost model, the mechanisms that keep it flat, and the knobs to
turn as the suite grows.

## Where a unit-shard job's wall time goes (measured 2026-08-01)

| phase | cost | scaling behavior |
|---|---|---|
| runner setup (checkout, caches, node, wasmtime) | ~10-15s | flat |
| stage2 build | 0s on `stage2-v1-*` cache hit, ~30s on miss | flat |
| per-test COMPILE (test + its import closure through stage2) | ~1s (leaf) to ~6s (full compiler closure); **>90% of a cold battery** | linear in tests × closure size |
| per-test RUN (`_start`) | ~0.1-0.5s, except self-compile tests (below) | linear in tests |

Two test classes matter for the budget:

- **ordinary tests** (fixtures, stdlib, checker/parser/printer units):
  compile-dominated; run is ~0.1-0.5s. This is where coverage growth
  happens, so this class must be cheap to add to.
- **runtime-self-compile tests** (`s5_*`, `cache_probe_*`,
  `compiler_cache_*`, `codegen_heap_e2e`, ...): the test's RUN phase itself
  invokes the compiler, 5-50s each. Caching cannot help their run phase;
  they are bounded by shard placement (LPT) and the 300s run bound.

## Mechanism 1: compiled-test-wasm cache (unit_test_runner.sh)

Content-keyed reuse of each test file's compile output:

- entry dir = `_build/vibe_unit_out_cache/<sha16(stage2.wasm)>/` — any
  compiler change rotates the directory (stale dirs pruned at startup);
- per test: a `.deps` file (its import closure, recorded from one
  `VIBE_MODULE_PLAN` call at store time) + `<key>.wasm` where key =
  sha256(contract-salt + sha256 of every dep). Make-depfile staleness
  logic: an edit that changes the closure necessarily touches a file in
  the OLD closure, so the key misses and deps are re-planned. The contract
  salt folds in every `.vibei`/`index.vpkg` under `lib/` (contracts affect
  compile output; the plan already lists per-closure `index.vpkg` entries,
  the salt is belt-and-braces for cross-package contract edits);
- hit path = hash deps (~20-50ms, one `sha256sum` process) + run. No
  compiler invocation at all;
- store cost ≈ one plan call (~0.2-0.5s) after a successful compile+run;
  measured shard wall was unchanged cold-vs-cold (18.1s vs 18.2s);
- `VIBE_UNIT_OUT_CACHE=0` disables (use when regenerating
  `scripts/unit_test_weights.tsv`, or the recorded times will be
  hit-path times and skew the LPT shard balance).

Measured effect (local, 4 jobs, prebuilt stage2, 1/16-shards):

| shard | cold | warm |
|---|---|---|
| light (15/16) | ~15-20s | **1.9s** |
| mid (8/16) | 18.1s | **8.9s** |
| heaviest, run-dominated (0/16) | ~100s+ | 27.4s (inherent run time) |

CI persists the cache per shard in the `vibecache-v2-*` actions/cache
entry, keyed on the codegen fingerprint like the module-level compile
cache, so a compiler change rotates the CI entry too.

## Mechanism 2: weight-balanced shards (scale-out knob)

`VIBE_UNIT_TEST_SHARD=i/N` LPT-partitions the battery by recorded weights
(`scripts/unit_test_weights.tsv`); ci.yml's matrix is the only place N is
chosen (4 as of #1330's follow-up; was 3). Raising N is the release valve
when warm-shard wall approaches the budget: per-shard setup is ~15s flat,
so N can grow to ~8 before setup overhead matters.

## Growth budget

With the cache warm, adding an ordinary test costs its RUN time
(~0.1-0.5s) per battery, not its compile. At 4 shards / 4 jobs:

- +1000 ordinary tests ≈ +100-500s of run spread over 16 workers ≈
  **+6-30s per shard job** — comfortably inside 5 minutes.
- A compiler-touching PR pays a full cold battery (every closure changed):
  ~2-4min per shard today. This is the worst case that bounds shard count;
  it scales linearly with test count, so as coverage grows, raise the
  shard matrix (or move to batch compilation, below).

## Known limits / next levers

- **Cold-path batching**: each file today pays a fresh node start + stage2
  wasm instantiation + JIT re-warmup (~0.3-0.5s floor). One resident
  stage2 instance compiling many files (recycled when heap grows) would
  cut the cold battery severalfold; `VIBE_MODULE_PLAN`/#1239 laid the
  groundwork.
- The run-phase 300s bound and the runtime-self-compile class: those
  tests' cost is the compiler's own selfcompile speed (tracked by
  `scripts/selfcompile_kpi.sh` and the perf-metrics job).
- `coverage-suite` (main-only) re-runs the battery instrumented; it reuses
  none of this cache (instrumented output differs). It is off the PR
  critical path by design; revisit if main-push wall matters.
