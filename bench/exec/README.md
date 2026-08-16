# Execution scenario corpus (deterministic fuel / memory / backend parity)

`bench/exec/` is a small, fixed set of **general programs** — the kind of code
the compiler produces for users, deliberately NOT the selfhost compiler
compiling itself — used by the continuous perf pipeline
(`scripts/bench_metrics.sh` → `.github/workflows/perf.yml`) to answer three
questions with **deterministic, rule-based measurements**:

1. **How many instructions does generated code take to run?** Each scenario is
   compiled by the freshly-built stage2 and executed once under viberun with
   wasmtime **fuel metering** (`VIBE_FUEL=1`, `vibe::fuel consumed=<n>`). Fuel
   is charged per executed instruction from a static cost table, so for these
   pure, input-free programs the number is **byte-stable across machines and
   runs** — CI runner speed cannot touch it. It moves only when codegen (or the
   scenario source) changes, so the report can flag tight (±2%) deltas without
   the wall-time noise problem (`bench/perf/README.md` "Runner normalization").
2. **How does the wasm-gc backend compare?** Every scenario is also compiled
   with `VIBE_BACKEND=gc` and run the same way. Per scenario the snapshot
   records gc fuel and the gc÷linear ratio — the first continuous speed
   comparison between the two lanes. A scenario the gc backend cannot compile
   or run is recorded as a per-scenario status (e.g. `higher_order` fails
   today with `GC codegen: unknown constructor or function: Array::map`), so
   the gc feature gap is visible in every report instead of unmeasured.
3. **Is the output right?** Each scenario prints a deterministic result
   summary. The linear output is compared against the committed golden file in
   `expected/`, and the gc output against the linear output (backend parity).
   A mismatch is a **silent-wrong candidate** (the worst failure class,
   `docs/issue-triage.md` P0) and is flagged loudly in the perf report.

## Scenario set

| File | Shape stressed |
|------|----------------|
| `string_ops.vibe` | string growth by concat, substring/index_of scans, split |
| `sort_ints.vibe` | recursive quicksort over `Array[Int]`, binary search |
| `higher_order.vibe` | closures, `Array::map`/`filter`/`fold`, indirect calls |
| `expr_eval.vibe` | enum tree build + recursive `match` interpreter |
| `base64.vibe` | `Bytes` + shift/mask bit manipulation |
| `json_scan.vibe` | byte-level tokenizer over JSON-shaped text (user parsing code, not the selfhost parser) |
| `sieve.vibe` | `Bytes` flag table, memory-heavy loops |
| `records_pipeline.vibe` | struct construct/rebuild, `Option` lookup + match |
| `int_wrap.vibe` | Int overflow wrap (#1877): 63-bit two's-complement, iterated LCG checksum |

## Rules for scenarios

- **Pure and input-free**: no `Fs`/`Http`/`Env`/clock — determinism is the
  entire point. Anything the program "randomizes" comes from a fixed-seed
  PRNG (a MINSTD Lehmer LCG `seed * 48271 % 2147483647` is the pattern used
  here). Since #1877, Int overflow wraps at 63 bits identically on every
  backend, so even overflow-heavy arithmetic is parity-safe —
  `int_wrap.vibe` pins exactly that contract.
- **Single file, no imports**: the gc lane is a single-file compile
  (`VIBE_BACKEND=gc`, no `VIBE_FS_COMPILE`), so scenarios must not import.
- **Entry is `let main = () -> Int`** (same shape as `bench/binary_size/`).
- **Print a short deterministic summary** (a few `println` lines: sizes,
  checksums) — that's what the golden/parity check compares. Keep output
  small; it is committed under `expected/`.
- Keep one run **under ~1s** on a laptop; fuel does not need long runs to be
  precise (it is exact), the workload just has to be big enough that codegen
  changes dominate the fixed startup cost.

## Adding / changing a scenario

```bash
# build a stage2, or use the committed seed for a quick local pass
bash scripts/generations.sh build --out-dir /tmp/gen
cargo build --release --manifest-path runtime/viberun/Cargo.toml

# compile + run both lanes, regenerate the golden file
bash scripts/bench_metrics.sh /tmp/gen/stage2.wasm /tmp/m.json
node scripts/bench_report.mjs /tmp/m.json
```

Commit the new/updated `expected/<name>.txt` together with the scenario.
Changing a scenario resets its fuel history on the `bench-data` branch —
fine, but say so in the PR. The linear vs gc parity check must pass (or the
scenario's gc status must be a *compile/run* failure documenting a real gc
gap, never a mismatch).
