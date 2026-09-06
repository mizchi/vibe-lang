---
name: compiler-perf-profiling
description: Performance workflow for the vibe compiler — profiling a real compile with node --cpu-prof, running phase benches (__bench_ exports), reading hotspots, and the fix → fixpoint → regression validation loop. Use when compiles are slow, CI is slow, or a bench regressed.
---

# compiler perf profiling — measure before you fix

For the selfhost vibe compiler (linear/RC lane), profiling a **real compile
under node --cpu-prof** reaches the core far faster than guessing from
synthetic benches. #799 used this procedure to take a heavyweight compile
from 39s to 4s (~10x).

## 0. One command: scripts/profile_compile.sh

Bundles §1's cpu-prof + self-time aggregation and §3's memory stats (heap
high water / linear memory / RSS) into one command. Start here; drop down
to the manual steps below when you need to dig.

```bash
scripts/profile_compile.sh /tmp/gen/stage2.wasm            # default corpus
scripts/profile_compile.sh /tmp/gen/stage2.wasm foo.vibe 30
```

## 0.5 Control the persistent cache, or the numbers lie (#2393, #2394)

The FS compile lane consults the persistent caches under `_build/vibe_*`.
Their key namespace (`persistent_cache_version_tag()`,
`cache/persistent_cache.vibe`) embeds `codegen_fingerprint()` — a hash of
the compiler SOURCES — so entries written by one compiler are invisible to a
compiler built from different sources. That protects correctness, but it
does NOT protect a before/after comparison, because the trap is
**same-compiler warming with asymmetric preparation**:

- Anything that compiles with the candidate before you profile it — a
  build's run-validation, a stage3 self-compile, an output-equivalence
  byte-compare of the very corpus you are about to profile — pre-warms the
  candidate's namespace. If the baseline did not get the same preparation,
  you are comparing a cold baseline against a warm candidate.
- The fingerprint hashes sources, not the wasm: two stage2 builds from the
  SAME sources (e.g. with and without `VIBE_WASM_NAMES=1`) share one
  namespace, so earlier gate/suite runs on this machine may have warmed
  your "fresh" baseline — or not — without you choosing either.

Measured on the same corpus and machine: cold ~8.0s / 1.46GB heap_ptr vs
warm ~4.7s / 727MB. That gap is bigger than most real optimizations, and it
produced the wrong "−31% wall, −42% heap" claim in PR #2393 (semi-warm
baseline vs fully-warmed candidate; the cache-controlled cold-vs-cold
answer was +3.5%).

Protocol for ANY before/after comparison on this lane:

- Isolate the cache per run: `VIBE_BUILD_CACHE_DIR=$(mktemp -d)` (the
  override lives in `cache/cache_underlying.vibe`). Fresh dir = cold run;
  a second run in the same dir = warm run.
- Compare **cold-vs-cold AND warm-vs-warm**, never across temperatures.
  Both lanes matter: cold is CI / first build, warm is the dev inner loop.
- **N≥3 runs per configuration** — single-run wall deltas under ~5% are
  noise on a shared machine.
- **Alternate the order inside each interleaved pair (ABBA).** Measured
  2026-09-04 on the export-kinds memo: with the baseline first in every
  pair the candidate was slower in every pair (+3.7%); with the candidate
  first it was faster in every pair. The second run of a pair pays ~0.3 s
  on this machine, so a fixed order turns position into a result. Pool the
  rounds and report the median next to the profile delta; a slice whose
  whole cost is ~0.2 s sits at the wall noise floor and is judged on the
  profile and the deterministic heap_ptr, not on wall.
- `scripts/profile_compile.sh` does NOT isolate the cache; wrap it with
  `VIBE_BUILD_CACHE_DIR` yourself before trusting its wall/heap output.
- Cross-check against the PR perf-report's deterministic rows (selfcompile
  heap, B/op, fuel): if the report says ±0 and your local profile says
  −40%, the local measurement is contaminated — believe the deterministic
  lane and find the leak in your method first.

## 1. Profile a real compile first (most important)

```bash
S2=<stage2.wasm>   # current stage2 (a scripts/generations.sh build artifact)
VIBE_PREOPEN_DIR="$PWD" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_NODE_EXTRA_FLAGS="$(printf '%s\n' --cpu-prof --cpu-prof-dir=/tmp --cpu-prof-name=compile.cpuprofile)" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$S2" \
  lib/@vibe/compiler/tests/codegen_lexer_test.vibe /tmp/out.wasm __no_entry__
```

**Go through the runner wrapper, never a bare `node --cpu-prof`.**
`VIBE_NODE_EXTRA_FLAGS` takes one flag per line (a value may contain
spaces; the `printf` above puts each flag on its own line). The
wrapper adds `--experimental-wasm-inlining` (V8 keeps its wasm-to-wasm
inliner off for MVP modules unless asked; `vibe test` / `vibe run` and every
gate run with it). A bare `node` profiles a compiler V8 never inlines, and
the small runtime helpers then show up as calls: measured 2026-09-06 on one
cold compile, `__rt_arr_get` 415 → 156 ms self, `__rt_eq` 291 → 114 ms,
`__rt_arr_len` 148 → 0 ms, wall 7.14 → 6.55 s once the flag was on. The
rows that survive inlining (`__rt_arr_push`, `__rt_str_eq`, `__rt_arr_new`)
are the real intrinsic costs; the rest was the profile's artifact.

Pick a heavyweight test that compiles the whole compiler closure
(codegen_*_test / cli_test / selfhost_s5_*). Aggregating self time:

```python
import json, collections
p = json.load(open("/tmp/compile.cpuprofile"))
nodes = {n["id"]: n for n in p["nodes"]}
c = collections.Counter()
for sid, dt in zip(p["samples"], p["timeDeltas"]):
    c[nodes[sid]["callFrame"]["functionName"] or "(anon)"] += dt
total = sum(c.values())
for fn, us in c.most_common(20):
    print(f"{us/1000:8.1f}ms {us*100/total:5.1f}%  {fn[:100]}")
```

### Reading the profile

- **wasm functions appear under their name-section names.** User functions
  look like `foo_exp_lib__vibe_compiler_..._vibe`; generated runtime
  helpers are `__rt_str_eq` / `__rt_arr_get` / `__rt_rc_drop` etc. (named
  since #799 — if a `wasm-function[N]` frame ranks high, that is a naming
  gap: add it to gen_sec_names in linked_compile.vibe).
- **Since ADR-0077 release builds strip the name section by default.**
  Rebuild the stage2/CLI wasm you profile **with `VIBE_WASM_NAMES=1`**
  (e.g. `VIBE_WASM_NAMES=1 bash scripts/generations.sh build --out-dir
  /tmp/prof_gen`). If every frame is `wasm-function[N]`, you are profiling
  a stripped wasm.
- **`(garbage collector)`** = V8. Usually caused by wasm linear-memory
  grow copies or allocation churn in the runner JS.
- **Runner JS functions** (findClosureEnv etc.) ranking high means a
  harness anomaly. In #799, `--invoke cli_main` first ran the whole
  compile once through the WASI-conventional `_start`, doubling the
  compile (the current runner skips pre-start for cli_main invokes;
  `VIBE_FORCE_RUN_INIT=1` restores the old behavior).
- A recurring historical pattern: **linear String scans over a huge flat
  name array** (array_contains_str / collect_free_vars-alikes). Per ident
  × thousands of names = O(N²). The fix shape: build a Map index once per
  compile and carry it on CompileCtx (see capture_name_index /
  collect_used_builtin_names).

## 2. Phase benches (secondary: relative comparison / regression checks)

A `bench "name" { ... }` block is exported as `__bench_<name>`. Run it via
the node runner's bench mode:

```bash
# compile (the same __no_entry__ sentinel as tests)
VIBE_PREOPEN_DIR="$PWD" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$S2" \
  lib/@vibe/compiler/parser_bench.vibe /tmp/b.wasm __no_entry__

# run (prints total µs; divide by N for µs/iter)
VIBE_PREOPEN_DIR="$PWD" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke "__bench_selfhost/parse_deep_binop_chain" \
  --bench-count 20 --bench-warmup 3 --bench-setup _start /tmp/b.wasm
```

Phase benches: selfhost_{lexer,parser,checker,codegen}_bench.vibe.

### Bench traps

- **A bench file with module-level lets requires `--bench-setup _start`**
  (hitting a bench export before module init throws on uninitialized
  globals).
- **`_start` smoke-runs every bench body once.** One throwing bench takes
  the whole module down.
- **A probe that reads files must direct-call `Fs::read_file`, not
  `perform Fs::ReadFile`** (an unhandled perform always throws — the
  #768/#794 direct-call convention).
- **Watch for stale bench corpora**: after the package move (#753),
  `syntax/lexer.vibe` became a 14-line re-export shim and a bench kept
  measuring it. Suspicious speed (~80µs) means suspect the corpus.
- **Measure on an idle machine.** Never alongside a background regression
  run or build.

## 3. Other vibe-specific measurement tools

| tool | what it gives you |
|---|---|
| `Profiler::now_us` | wall time of any region (used by the cache_probe_*_bench_test family) |
| `Profiler::heap_bytes` | allocation volume of any region (bump-heap pointer; the allocation twin of now_us — bump never frees, so the delta = bytes allocated in the region) |
| `vibe test --coverage` | function/branch hit bitmaps (whether it ran; not how often) |
| debug_trace (`vibe.trace` section) | function-entry execution order (first 4096) |
| runner `--bench-count` + `--mem` family | ns/op, bytes/op (bump-heap delta) |

### Memory measurement (runner side, no guest changes)

- **`VIBE_WASM_MEMORY_STATS=1`**: prints one `[wasm-memory] ... pages=
  bytes= heap_ptr= rss=` line to stderr at the end of a run/bench.
  heap_ptr is the bump high water. Reference: one heavyweight
  full-closure compile (codegen_lexer_test) ≈ heap 362MB / RSS 428MB
  (measured 2026-07).
- **`VIBE_PROFILE_MEMORY_MARKS=1`**: prints `[profile-memory] mark=N ...`
  every time the guest calls `Profiler::now_us`. A profiled compile (the
  full CLI entry's `--profile-tsv` / `VIBE_PROFILE_TSV`) calls now_us at
  stage boundaries, so you get per-stage memory progression. **Note**: a
  generation's stage2 (flat low-level entry) has no profiled path and
  emits no marks — use the dist / `vibe/cli` entry wasm.
- To measure a region from inside the guest, use `Profiler::heap_bytes`
  (table above).

## 4. After a fix, validate in exactly this order

```bash
# a. bundle regen (mandatory when compiler source was touched)
VIBE_REGEN_MODULE_SOURCE=1 \
  VIBE_ADAPTER_MODULE_SOURCE_OUT=lib/@vibe/compiler/_cli_adapter_module_source.vibe \
  bash scripts/generate_bundle.sh

# b. stage rebuild + fixpoint (stage2 == stage3 is non-negotiable)
bash scripts/generations.sh build --out-dir /tmp/gen --stage3 --skip-run-validation
cmp /tmp/gen/stage2.wasm /tmp/gen/stage3.wasm

# c. optimization equivalence: compile the same file with the pre-fix and
#    post-fix stage2 and byte-compare the outputs (a pure optimization
#    must match). NOTE: this step compiles your profiling corpus with the
#    candidate — it warms the candidate's cache namespace, so run any §0.5
#    wall/heap measurement with an isolated VIBE_BUILD_CACHE_DIR, never
#    from the leftover default cache state.

# d. re-profile (did the targeted hotspots disappear?)

# e. full regression
VIBE_STAGE2_WASM=/tmp/gen/stage2.wasm bash scripts/unit_test_runner.sh
```

### Validation traps (all stepped on for real)

- **Allocation churn surfaces on the RC lane**: rebuilding a large nested
  structure per call (CtFn/Array tables and the like) works on bump but
  fails RC in-process compile tests with OOB. Memoize with a module-level
  let (module lets initialize exactly once —
  fixtures/module_let_memo_test.vibe is the spec).
- **Parallel regression runs vs cache tests**: tests that inspect
  persistent-cache state race a parallel fan-out (the runner already puts
  tests whose path contains "cache" in a serial tail). One parallel
  failure → re-run it alone first to disambiguate.
- Do not edit the runner's .sh/.js while a regression run is in flight
  (bash reads scripts incrementally; you corrupt the behavior of the
  running process).
