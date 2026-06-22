# wasm_opt dogfooding — vibe optimizer vs binaryen `wasm-opt`

The size optimizer in [`vibe/wasm/wasm_opt`](../vibe/wasm/wasm_opt) is written in
vibe and optimizes vibe-compiled wasm. This note records how we benchmark it
against binaryen's `wasm-opt` and where we currently stand.

## Measurement loop

`Fs::read_bytes` is declared but has no codegen support (host MVP backend and
selfhost WASI codegen both only implement `read_file`/`write_bytes`), so the
optimizer cannot yet be driven as a file-reading CLI. We measure instead by
**embedding real wasm modules inline** as byte arrays in `vibe test` and calling
`minify_converge` on them — this runs the real compiled optimizer with no host
FS dependency. See `fixtures_inline_test.vibe`.

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
| rume_gain            |   65 |           33 |                ~56-64 | gap (table DCE) |
| base64 (real)        | 9024 |         6962 |                ~8700 | gap (body opts) |

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
- section stripping, `local.tee`, `drop`/`br_if 0` elimination, local coalescing.

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
   elimination via dataflow) is the top remaining lever; our peephole only does
   the adjacent `local.set x; local.get x -> local.tee x` case. A real
   simplify-locals needs per-function def/use dataflow.

These are tracked as follow-up work; each is validated with the
`wasm-opt`/`wasmtime` oracle loop above before landing.
