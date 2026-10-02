# Binary Size Regression Bench

`bench/binary_size/` is a small, fixed set of standalone programs used to
track the size of the wasm the compiler produces. The old product/compiler
bundle-size monitors (`bench/bundle_size/`, `bench/compiler_size/`) were
removed in #2150; this directory is the live size bench.

Modeled on the benchmark set documented in
[almide](https://github.com/almide/almide)'s benchmark notes (see
`docs/internal/reports/pl-survey-2026-07.md` and issue #1056): five small
programs, each stressing a different codegen shape, measured "as shipped"
(raw compiled output, no post-processing).

## Case Set

| File | Shape stressed |
|------|-----------------|
| `hello_world.vibe` | minimal program (single `println`) |
| `fizzbuzz.vibe` | iterative loop with conditionals (1..100) |
| `fib.vibe` | recursive function calls |
| `closure_indirect.vibe` | higher-order functions / closures called indirectly |
| `variant_float.vibe` | algebraic-type match + floating-point arithmetic |

`variant_float.vibe` carries an `Int` payload in its enum rather than a
`Double`; the comment at the top of the file records why.

## Gate

`scripts/size_ratchet.sh <stage2.wasm>` compiles every sample on the default
linear RC lane and fails when one grows more than 2% over
`bench/perf/size_baseline.txt`. The sizes are byte-deterministic for a fixed
compiler and sample. CI runs it after building stage2; `pkf run release-check`
does not, so run it by hand on a change that can move codegen size. The
baseline file's header explains how to rebaseline.

## Comparing the two linear lanes

```bash
bash scripts/bench_binary_size.sh [cli.wasm]
```

Defaults to the committed seed (`bootstrap/seed/compiler.wasm`, fetched by
`scripts/ensure_seed.sh`); pass a freshly built `stage1`/`stage2`
(`scripts/generations.sh build`) to measure an in-flight compiler change.

Reports, per program: byte size with `VIBE_RC=0` (bump, no reclamation) and
`VIBE_RC=1` (Perceus RC, the default; see
`docs/internal/design/perceus-reuse.md` and
`docs/internal/design/uniform-value-repr.md`); plus, best-effort, the
`VIBE_RC=0` size after `wasm-opt -Oz` when `wasm-opt` is on `PATH` (optional,
as in almide's own methodology — this repo does not vendor binaryen, so that
column commonly reads `n/a`; `lib/@vibe/optimizer`'s own `minify_converge` is
vibe's in-house analogue, see `docs/internal/operations/wasm-opt-dogfood.md`,
but is not wired into this script to keep it dependency-free).

`docs/internal/operations/BENCHMARKS.md` holds recorded snapshots with their
measurement dates.
