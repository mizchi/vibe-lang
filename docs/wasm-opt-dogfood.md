# wasm_opt dogfooding — vibe optimizer vs binaryen `wasm-opt`

The size optimizer in [`vibe/wasm/wasm_opt`](../vibe/wasm/wasm_opt) is written in
vibe and optimizes vibe-compiled wasm. This note records how we benchmark it
against binaryen's `wasm-opt` and where we currently stand.

## Measurement loops

### Inline (CI) — small fixtures
We embed real wasm modules inline as byte arrays in `vibe test` and call
`minify_converge` on them — runs the real compiled optimizer with no host FS
dependency. See `fixtures_inline_test.vibe`.

### End-to-end on real compiler output (local dogfood)
To validate/measure on *real, non-trivial* programs we run the optimizer over
the selfhost compiler's own output. The selfhost CLI's low-level path
(`cli_main`) executes effectful `main` (the host compiler's final-expression
model does not), so we host-build a selfhost compiler with an opt-in
post-optimize hook and drive it via the node host runner:

```bash
# 1) local-only hook in vibe/cli/selfhost.vibe: gate maybe-minify on
#    VIBE_MINIFY_PASS (import minify_converge etc. from ../wasm/wasm_opt). DO
#    NOT COMMIT — it couples wasm_opt into the selfhost compiler (+~700 KB) and
#    the fixed seed cannot self-compile it.
# 2) host-build the dogfood compiler (~8s):
vibe compile --wasm --force-cabi-realloc vibe/cli/selfhost_entry.vibe -o /tmp/sc.wasm
# 3) compile a sample with/without a pass, then validate + run:
export VIBE_PREOPEN_DIR="$(pwd)"
bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main /tmp/sc.wasm \
  examples/selfhost_features.vibe out.wasm main           # baseline
VIBE_MINIFY_PASS=minify bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  /tmp/sc.wasm examples/selfhost_features.vibe out.min.wasm main
wasm-opt --all-features out.min.wasm -o /dev/null         # validate
bash scripts/run_wasm_vibe_host_runner.sh --invoke _start out.min.wasm  # run (compare result)
```

This loop **caught a critical correctness bug**: `decode_instr` did not consume
the immediates of `throw`/`try_table`, so minify corrupted *every* effectful
program (vibe effects compile to wasm exception handling). Real-code validation
is what surfaced it — the inline fixtures had no exception handling. Fixed in
`decode_instr`; regression-tested in `wasm_opt_test.vibe`.

Validated real-code results (output VALID per wasm-opt, runs to the same value
as the baseline):

| program (selfhost-compiled) | baseline | vibe minify | runs | wasm-opt -Oz |
|-----------------------------|---------:|------------:|------|-------------:|
| examples/selfhost_features  |     4153 |         861 | 0    |          707 |
| examples/perform_handle     |     4613 |         867 | 86   |          720 |

~80% reduction on real output; ~80–150 B behind `wasm-opt -Oz`.

### Function inlining (`inline_calls`) — closes most of the real-code gap

Disassembling `rec.vibe` (selfhost-compiled, baseline 53 functions):

- our `minify` **before** `inline_calls`: **53 → 6 functions** (DCE is correct —
  all 6 survivors are genuinely `call`-reachable from `_start`/`main`).
- our `minify` **with** `inline_calls`: **→ 4 functions**, 393 B.
- `wasm-opt -Oz`: **→ 3 functions**, 371 B.

The functions wasm-opt removes are small single-use helpers it **inlines** into
their callers, which then become dead; that cascade also frees their globals and
tags. `inline_calls` implements that lever: it picks a non-root callee that is
`call`ed exactly once (and not self-recursive), inlines its body at the single
call site (storing args into appended param locals, wrapping the body in a
`block` of the callee's result type, remapping the callee's locals by `+base`,
and rewriting top-level `return` to `br <depth>`), and lets the following DCE
delete the now-uncalled callee. One inline per pass; `converge` repeats.

It is **conservative for correctness**: it bails on any callee whose body
contains `br`/`br_if`/`br_table`, `try_table`, or `throw`, because those branch
targets / exception scopes would shift when the body is wrapped in the inliner's
block. This is what keeps effectful programs (vibe effects → wasm EH) valid —
`perform_handle` stays VALID and runs to the same value with `inline_calls`
active. (`inline_empty_calls` still handles empty `() -> ()` callees separately.)

With `inline_calls` the rec gap to `wasm-opt -Oz` is **22 B** (393 vs 371), down
from ~80–150 B. The remaining delta is the unused-global / unused-tag cleanup
that a deeper inline cascade unlocks.

Correctness has been validated end-to-end on 7 real programs (arrays, recursion,
strings, enums/match, loops, plus examples/selfhost_features and
examples/perform_handle): every `minify` output (now including `inline_calls`)
is VALID under wasm-opt and runs to the same result as the baseline. Reductions
range 79–90%:

| program          | baseline | vibe minify | red% | valid | runs-match |
|------------------|---------:|------------:|-----:|-------|-----------|
| arr              |     4001 |         843 |  79% | ✅    | ✅ (15)    |
| rec              |     3848 |         393 |  90% | ✅    | ✅ (55)    |
| str              |     3926 |         610 |  84% | ✅    | ✅ (0)     |
| enum/match       |     3922 |         491 |  87% | ✅    | ✅ (20)    |
| loop             |     3855 |         536 |  86% | ✅    | ✅ (5050)  |
| selfhost_features|     4153 |         861 |  79% | ✅    | ✅ (0)     |
| perform_handle   |     4613 |         867 |  81% | ✅    | ✅ (86)    |

Baselines come from binaryen (installed via `npm i binaryen`):

```bash
wasm-opt -Oz --all-features fixture.wasm -o out.wasm   # size baseline
wasm-opt --all-features our_output.wasm -o /dev/null   # validate our output
```

`wasm-opt` is also used as an **independent validator**: hand-computed expected
outputs for the DCE/renumbering tests are confirmed VALID by `wasm-opt` and run
to the correct value by `wasmtime` before being asserted byte-for-byte in
`wasm_opt_test.vibe`.

## Current numbers (vs `wasm-opt -Oz`)

| fixture              | orig | wasm-opt -Oz | vibe minify_converge | status |
|----------------------|-----:|-------------:|---------------------:|--------|
| br_to_exit           |   26 |            8 |                    8 | ✅ match |
| elided-br            |   33 |            8 |                    8 | ✅ match |
| directize_gain       |   56 |           50 |                   50 | ✅ match |
| complexBinaryNames   |   73 |           41 |                   41 | ✅ match |
| rume_gain            |   65 |           33 |                   33 | ✅ match |
| base64 (real)        | 9024 |         6962 |                ~8700 | gap (body opts) |

Five of six match `wasm-opt -Oz` exactly; every fixture output above is
byte-identical to a module that `wasm-opt` validates and `wasmtime` runs.

## What we do

- **converge** — fixed-point loop (`wasm-opt --converge` analog).
- **true DCE** (`dce_remove`) — physically removes unreachable functions and
  renumbers all references (calls, exports, start, **element/table segments**).
  Roots = exports + start + element-referenced funcs. This is what reaches
  parity on the export-less / dead-function fixtures.
- **constant folding** — i32 arith/shift/compare + `eqz`, 32-bit-correct
  wraparound; identity elimination for i32 and i64 (`x+0`, `x*1`, `x<<0`, …);
  `nop` removal.
- **empty-void-call inlining** (`inline_empty_calls`) — deletes `call F` where F
  is an empty `() -> ()` function (a no-op); the callee then becomes dead and is
  removed by DCE. Reaches parity on complexBinaryNames.
- **table.size folding + table DCE** (`fold_table_size`, `drop_unused_tables`) —
  `table.size t` folds to the table's declared minimum (when no `table.grow` and
  no imported tables); once no table opcode remains and no table is exported, the
  table and element sections are dropped and the element-only functions collapse.
  Reaches parity on rume_gain.
- section stripping, `local.tee`, `drop`/`br_if 0` elimination, local coalescing.

A prerequisite fix landed here too: `decode_instr` now consumes the immediates
of every `0xFC`-prefixed op (table/memory bulk ops). Previously `table.size`'s
table index was misparsed as a separate instruction, which `nop`/peephole could
corrupt — so the old "rume reduction" was actually invalid output.

## Gap analysis / roadmap toward `wasm-opt` parity

The remaining gaps are **not** dead-function removal (we match wasm-opt's
function count on the structural fixtures; on base64 all 10 functions are
genuinely reachable in our call graph). They need:

1. **Table-entry DCE** (rume_gain → 33): after `directize` removes every
   `call_indirect`, the table is never indexed, so its element segments and
   table-only functions are dead and can be dropped. Requires proving the table
   is unused (no `call_indirect`/`table.*`, not exported/imported).
2. **Function inlining beyond empty void callees** (general): inlining small
   non-empty callees. (Empty `() -> ()` callees are already handled, which
   brought complexBinaryNames to parity.)
3. **Body-level optimization** (base64 → 6962): the bulk of base64 is its code
   section. Per-pass `wasm-opt` measurement on base64 (9024 B) shows the biggest
   single levers are dataflow on locals:

   | wasm-opt pass                   | base64 size |
   |---------------------------------|------------:|
   | `--simplify-locals`             |        8312 |
   | `--coalesce-locals`             |        8675 |
   | `--precompute`                  |        8917 |
   | `--optimize-instructions`       |        8912 |
   | `--remove-unused-module-elements` |      8963 |
   | (`-Oz`, all combined)           |        6962 |

   `simplify-locals` (copy propagation / redundant `local.set`/`local.get`
   elimination via dataflow) is the top remaining lever. We currently do the
   provably-safe local adjacencies — `local.set x; local.get x -> local.tee x`
   and `local.tee x; drop -> local.set x` — but the bulk of the win is
   control-flow-aware copy propagation of a value from its `local.set` to a
   later single `local.get`.

   **Blocker:** that transform is only safe with per-function def/use dataflow,
   and shipping it responsibly needs validating the optimizer's output on the
   real target (base64). We can validate small hand-built cases offline with
   `wasm-opt`/`wasmtime`, but cannot yet extract `minify`'s output for an
   arbitrary embedded module: `Fs::read_bytes` is unimplemented and the host
   runner does not execute an effectful `main`'s `Fs::write_bytes`. Unblocking
   output extraction (or a `vibe wasm-opt` CLI once `Fs::read_bytes` lands) is
   the prerequisite for landing dataflow simplify-locals.

These are tracked as follow-up work; each is validated with the
`wasm-opt`/`wasmtime` oracle loop above before landing.
