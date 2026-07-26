# wasm_opt dogfooding — vibe optimizer vs binaryen `wasm-opt`

The size optimizer in [`lib/@vibe/optimizer`](../lib/@vibe/optimizer) is written in
vibe and optimizes vibe-compiled wasm. This note records how we benchmark it
against binaryen's `wasm-opt` and where we currently stand.

## Measurement loops

### Inline (CI) — small fixtures
We embed real wasm modules inline as byte arrays in `vibe test` and call
`minify_converge` on them — runs the real compiled optimizer with no host FS
dependency. See `fixtures_inline_test.vibe`.

### End-to-end on real compiler output (local dogfood)
To validate/measure on *real, non-trivial* programs we run the optimizer over
the compiler's own output. The CLI's low-level path
(`cli_main`) executes effectful `main` (the retired MoonBit host compiler's
final-expression model did not), so we host-build a compiler with an opt-in
post-optimize hook and drive it via the node host runner:

```bash
# 1) local-only hook in lib/@vibe/cli/dispatch.vibe: gate maybe-minify on
#    VIBE_MINIFY_PASS (import minify_converge etc. from ../../lib/@vibe/optimizer). DO
#    NOT COMMIT — it couples wasm_opt into the compiler (+~700 KB) and
#    the fixed seed cannot self-compile it.
# 2) host-build the dogfood compiler (~8s):
vibe compile --wasm --force-cabi-realloc lib/@vibe/cli/entry.vibe -o /tmp/sc.wasm
# 3) compile a sample with/without a pass, then validate + run:
export VIBE_PREOPEN_DIR="$(pwd)"
bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main /tmp/sc.wasm \
  examples/compiler_features.vibe out.wasm main           # baseline
VIBE_MINIFY_PASS=minify bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  /tmp/sc.wasm examples/compiler_features.vibe out.min.wasm main
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

| program | baseline | vibe minify | runs | wasm-opt -Oz |
|-----------------------------|---------:|------------:|------|-------------:|
| examples/compiler_features  |     4153 |         834 | 0    |          707 |
| examples/perform_handle     |     4613 |         858 | 86   |          720 |

~80% reduction on real output; on small programs now at or below `wasm-opt -Oz`
(rec: 366 vs 371). The larger examples still trail (general body-level
simplify-locals is the remaining lever).

### Function inlining (`inline_calls`) — closes most of the real-code gap

Disassembling `rec.vibe` (baseline 53 functions):

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

The cleanup that inlining unlocks is now also implemented:

- **`drop_unused_globals`** — removes globals never referenced by code
  (`global.get`/`global.set`) and never exported, renumbering the survivors in
  code and export entries. Bails on imported globals or any `global.get` inside
  init/offset exprs.
- **`drop_unused_tags`** — removes tags never referenced by `throw` /
  `try_table` catch clauses and never exported, renumbering throw/try_table and
  export tag indices. Bails on imported tags.

After an inline cascade frees a helper's globals/tags, these drop them. On `rec`
this brings vibe `minify` to **366 B — smaller than `wasm-opt -Oz` (371 B)** —
with the same global/tag counts (1 global, 1 tag) wasm-opt produces. `minify`
was 393 B before these passes.

Validated numbers (every output VALID under wasm-opt and
run-matching the baseline):

| program          | baseline | vibe minify | red% | wasm-opt -Oz |
|------------------|---------:|------------:|-----:|-------------:|
| rec              |     3848 |     **366** |  90% |          371 |
| enum/match       |     3922 |         464 |  88% |            — |
| loop             |     3855 |         509 |  87% |            — |
| str              |     3926 |         583 |  85% |            — |
| arr              |     4001 |         816 |  80% |            — |
| compiler_features |     4153 |         834 |  80% |          707 |
| perform_handle   |     4613 |         858 |  81% |          720 |

Correctness has been validated end-to-end on 7 real programs (arrays, recursion,
strings, enums/match, loops, plus examples/compiler_features and
examples/perform_handle): every `minify` output (now including `inline_calls`)
is VALID under wasm-opt and runs to the same result as the baseline. Reductions
range 79–90%:

| program          | baseline | vibe minify | red% | valid | runs-match |
|------------------|---------:|------------:|-----:|-------|-----------|
| arr              |     4001 |         816 |  80% | ✅    | ✅ (15)    |
| rec              |     3848 |         366 |  90% | ✅    | ✅ (55)    |
| str              |     3926 |         583 |  85% | ✅    | ✅ (0)     |
| enum/match       |     3922 |         464 |  88% | ✅    | ✅ (20)    |
| loop             |     3855 |         509 |  87% | ✅    | ✅ (5050)  |
| compiler_features |     4153 |         834 |  80% | ✅    | ✅ (0)     |
| perform_handle   |     4613 |         858 |  81% | ✅    | ✅ (86)    |

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
- **local copy-propagation** (`propagate_local_copies`) — a conservative slice
  of `simplify-locals`: deletes self-copy pairs (`local.get $x; local.set $x`)
  and forwards `local.get $a; local.set $b` to the single later use of `$b` when
  `$a` is not rewritten in between (then `$b` is dead for coalesce/DCE). This is
  the safe, bytecode-level subset; the rest of `simplify-locals`' win is
  AST-level expression sinking, which needs an expression IR we don't build.
  Helps copy-heavy code (e.g. array loops: `arr` 816 → 781 B).
- **dead `block` removal** (`remove_dead_blocks`) — binaryen's
  `remove-unused-brs` analog. Runs right after `inline_calls`, where inlined
  call bodies leave `block` scopes that nothing branches to. A `block` (`0x02`)
  is unwrapped (header + matching `end` dropped) only in the fully safe case: no
  `br`/`br_if`/`br_table` **or** `try_table` catch label targets it, and no
  inner branch escapes it — so removal changes no branch's meaning and needs no
  label renumbering. `loop`/`if`/`try_table` are never removed. Correct
  `try_table` handling is load-bearing for effectful code: catch labels resolve
  in the scope *enclosing* the try_table (its own label not counted, target at
  `sp - 2 - label`), so a catch that targets or crosses a block pins it.
  Validated on real effectful output (`perform_handle`, runs to 86) and shrinks
  `compiler_features` 834 → 824 B.

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

## 2026-07-25 — standalone artifact + real-corpus gate (#1107 Phase 2)

The extraction blocker above is resolved: `Fs::read_bytes`/`Fs::write_bytes`
work under both hosts, so the optimizer now ships as an **independent
artifact** instead of a local-only hook:

- `scripts/vibe_opt.vibex` — standalone entry (`vibe-opt <in.wasm> <out.wasm>`,
  runs `minify_converge`; anomaly guard writes the input through unchanged).
- `bash scripts/build_vibe_opt.sh` — builds `_build/vibe-opt.wasm` (~300 KB)
  with the committed seed (or `$VIBE_STAGE2_WASM`). The compiler itself stays
  uncoupled, per the constraint at the top of this note.
- `vibe build --minify` (runtime/vibe) — opt-in post-processing of the
  compiled executable via the artifact (`$VIBE_OPT_WASM` /
  `$TOOLCHAIN_DIR/lib/vibe-opt.wasm` / `_build/vibe-opt.wasm`).
- `bash scripts/minify_gate.sh` (pkf task `minify-gate`) — the
  semantics-preservation gate: for a runnable corpus (effectful, closure/
  `call_indirect`, variant+float, string-heavy), compile → run baseline →
  minify → `wasmtime compile -W exceptions=y` validate → run → require
  identical stdout + exit code and a size that never grows.

First run of that gate over real programs caught **three latent correctness
bugs**, all fixed in `wasm_opt.vibe`:

1. `remove_unused_types` collected/remapped type refs only from the func +
   import sections; `call_indirect`'s typeidx immediate and func-type
   blocktypes in code bodies were neither rooted nor renumbered
   (closure_indirect: "type index out of bounds").
2. `find_reachable` (the stubbing `dce`'s reachability) rooted only exports,
   while `dce_remove` used the full root set (exports + start + elem +
   `ref.func`). Round 2 of `minify_converge` takes the `dce` fallback branch
   once `dce_remove` has converged, which then stubbed closure bodies still
   live through the funcref table (closure_indirect: runtime `unreachable`).
3. `decode_instr` had no case for `f32.const`/`f64.const` (0x43/0x44): the raw
   little-endian constant bytes were parsed as opcodes, and any byte that
   looked like `local.get/set/tee` was "remapped" by `inline_calls`' `+base`
   local rewrite, silently corrupting float constants (variant_float: prints
   65 instead of 31).

Gate corpus results after the fixes (baseline → minified):
hello_world 6,988→404 B (-94%), fib 6,958→368 B (-94%), fizzbuzz 7,469→897 B
(-87%), closure_indirect 7,194→1,208 B (-83%), variant_float 9,306→2,635 B
(-71%), perform_handle 8,108→896 B (-88%), compiler_features 7,805→1,487 B
(-80%). All VALID and run-identical. Baselines here are ADR-0077-stripped
release outputs — the two layers compose.

## 2026-07-26 — RC アロケータ律速の発見と per-pass 実行 (#1109-1)

dist CLI (1.4MB) への 1 round が 4m20s、vibec core (4.9MB) は round 1 が
時間内に終わらない問題を `node --cpu-prof` で調査した結果:

- **self 時間の 97.4% が `__rt_rc_alloc`** — vibe-opt.wasm が Perceus RC で
  ビルドされており、optimizer のアロケーションパターン (モジュール全体の
  Bytes/span 配列を pass ごとに再構築) で free-list 探索が退化していた。
- 対策: `build_vibe_opt.sh` が **`VIBE_RC=0` (bump) でビルド**するよう変更。
  round-per-process 運用ではメモリはプロセス破棄で回収されるので bump で
  問題ない。効果: **1 round 4m20s → 9.4s (約26倍)**、出力は RC 版と
  バイト同一。vibe-opt.wasm 自体も 300KB → 60KB。
- ただし bump では **4.9MB 入力の 1 round が wasm の 4GB 上限を突破**する
  (heap_ptr wrap → OOB trap)。`vibe-opt --pass <name>` + `minify_wasm.sh
  --per-pass` で **1 pass = 1 プロセス**に分割 (17 invocations/round)。
  小 corpus で per-pass == single-round の結果一致を確認。

実測 (bump + per-pass 後):

| 対象 | before | after | 時間 |
|---|---:|---:|---:|
| dist CLI (converge 16 rounds) | 1,459,037 B | 1,398,525 B (-4.1%) | 59s |
| vibec core (`--keep-exports compile_cli_request,memory,__heap_ptr`) | 4,917,753 B | 3,750,335 B (**-23%**) | 1m45s |

vibec の縮小 core は componentize + jco transpile 後もブラウザ PoC
(in-memory compile → WebAssembly.instantiate → 42) を全て通過。
`build_vibec.sh` はこの縮小を既定で行う (`VIBE_VIBEC_NO_MINIFY=1` で skip)。

残レバー: dist CLI の -4% は cli_main から真に到達可能なコードが大半で
あることを意味する。次の伸び代は body-level simplify-locals (上記の
2026-07-25 節) と、vibec の request プロトコル面だけに絞ったさらに狭い
entry の検討。
