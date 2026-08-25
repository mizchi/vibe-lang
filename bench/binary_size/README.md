# Binary Size Regression Bench

`bench/binary_size/` is a small, fixed set of standalone programs used to
track wasm output size over time. The old product/compiler bundle-size
monitors (`bench/bundle_size/`, `bench/compiler_size/`) were removed in
#2150; this directory is the live size bench.

Modeled on the benchmark set documented in
[almide](https://github.com/almide/almide)'s `docs/BENCHMARKS.md`
(see `docs/pl-survey-2026-07.md` and issue #1056): five small programs, each
stressing a different codegen shape, measured "as shipped" (raw compiled
output, no post-processing).

## Case Set

| File | Shape stressed |
|------|-----------------|
| `hello_world.vibe` | minimal program (single `println`) |
| `fizzbuzz.vibe` | iterative loop with conditionals (1..100) |
| `fib.vibe` | recursive function calls |
| `closure_indirect.vibe` | higher-order functions / closures called indirectly |
| `variant_float.vibe` | algebraic-type match + floating-point arithmetic |

`variant_float.vibe` uses an `Int`-payload enum (not `Double`-payload) — a
`Double`-typed enum constructor field matched back out currently traps with
"memory access out of bounds" on the default (bump, no RC) backend, even in
the smallest possible repro (single-variant enum, one field, one match arm).
That is a pre-existing codegen bug unrelated to this bench or to Perceus RC;
see the comment at the top of the file. Tracked separately from #1056.

## Running

```bash
bash scripts/bench_binary_size.sh [cli.wasm]
```

Defaults to the committed seed (`bootstrap/seed/compiler.wasm`); pass a
freshly built `stage1`/`stage2` (`scripts/generations.sh build`) to measure
an in-flight compiler change before it lands in a new seed.

Reports, per program: byte size with `VIBE_RC=0` (bump, no reclamation —
today's production default) and `VIBE_RC=1` (Perceus RC — see
`docs/spec/rc-port.md`); plus, best-effort, the `VIBE_RC=0` size after
`wasm-opt -Oz` when `wasm-opt` is on `PATH` (optional, as in almide's own
methodology — this repo does not vendor binaryen, so that column commonly
reads `n/a`; `lib/@vibe/optimizer`'s own `minify_converge` is vibe's
in-house analogue, see `docs/wasm-opt-dogfood.md`, but is not wired into
this script to keep it dependency-free).

## Golden Rule

There is no automated budget/ratchet gate for this bench yet — it is a
manual/CI-optional regression signal. `docs/BENCHMARKS.md` holds the last
recorded snapshot with its measurement date; re-run and update both together
when investigating a size change.
