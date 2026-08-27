# SIMD in vibe: what exists, and how to write a kernel

Updated 2026-08-26 (#2342). This document describes the **current** state. The
three-layer design it used to propose — a first-class `V128` type with 12
`v128_*` intrinsics as "Layer 1", composed into vibe-level patterns as
"Layer 2" — was measured and retired; the record is in §4.

There are two supported ways to get wasm SIMD into generated code, and they
serve different callers.

## 1. Fused scan builtins (the compiler's own hot paths)

A fused builtin emits **one wasm loop** in which the `v128` chunk stays on the
operand stack for the whole scan, with a scalar tail. No value of vector type
ever exists at the vibe level, so there is nothing to box.

| builtin | signature | caller |
| :--- | :--- | :--- |
| `simd_skip_ws` | `(Bytes, Int, Int) -> Int` | none (see §3) |
| `simd_scan_alnum` | `(Bytes, Int, Int) -> Int` | none |
| `simd_scan_alnum_str` | `(String, Int, Int) -> Int` | none |
| `simd_scan_string_special_str` | `(String, Int, Int) -> Int` | `lib/@vibe/parser/lexer.vibe` |
| `simd_scan_line_end_str` | `(String, Int, Int) -> Int` | `lib/@vibe/parser/lexer.vibe` |

Adding one costs a compiler change: a row in `core/builtin_registry.vibe`, a
body in `codegen/builtin_bodies/` or an inline lowering in
`codegen/expr/compile_call.vibe`, and one index arm per lane. That is
affordable for a handful of scanners the compiler itself runs, and it does not
scale to a data-structure library — which is what §2 is for.

Instruction emitters live in `codegen/wasm_emit/simd.vibe` (0xFD prefix +
LEB128 sub-opcode); composable sequences are in `simd_patterns.vibe`.

## 2. Inline wasm (library kernels)

`fn f(b: Bytes, n: Int) -> Int = wasm "..."` (#805, ADR-0072) is how a library
writes a SIMD kernel without touching the compiler. It has `v128` locals, the
full lane/bitwise/compare/shuffle set, and structured control flow, so the
vector stays in a local for the whole loop.

Worked examples: `lib/@vibe/blake3/simd.vibe` (a full BLAKE3 compression) and
`bench/bench_simd_*.vibe` (byte search, rank, an i32 column sum, a
group-of-16 hash probe).

Limits, all of them live: linear backend only (the wasm-gc backend rejects
inline wasm), `Int` and `Bytes` parameters only, and no `call` between kernels
(#2348). The ABI is the raw tagged one — see the cheatsheet's inline-wasm
section.

## 3. What the measurements said

**A fused scanner only pays where the runs are long.** The whitespace-run
distribution of the compiler's own source (447 files, 2.97 MB):

| metric | value |
| :--- | ---: |
| whitespace runs | 352,183 |
| runs >= 16 bytes | 1,363 (**0.39%**) |
| whitespace bytes inside those runs | 26,114 / 707,349 (**3.69%**) |
| runs of exactly 1 byte | 272,786 (**77%**) |

99.6% of runs are shorter than a vector, so a 16-byte-granular path almost
never fires and the scalar tail does the work. That is why `simd_skip_ws` is
**not** wired into the lexer: it would add setup cost to the common case and
change nothing else. (The lexer also tracks comments and `saw_newline` over
`String`, so a `Bytes` scanner does not drop in.) It stays as the worked
example of unboxed SIMD codegen, and as a building block for scanning large
data/whitespace blocks, where the distribution is the other way round.

**rank/select is a popcount story, not a SIMD story.** `bench/bench_simd_rank.vibe`,
32 Kibit: a vibe loop 159834 ns, `i64.popcnt` 465 ns, `v128.load` + two
popcounts 365 ns, `i8x16.popcnt` with a horizontal sum 518 ns. One scalar
instruction carries 344x of the 438x. Tracked as #2344.

**The honest baseline is a native builtin.** A 4 KiB byte search: hand-written
SIMD kernel 248 ns, native scalar `String::index_of` 352 ns, a vibe-level loop
25001 ns. 1.4x over the builtin, 101x over the loop. Quoting the second number
as the value of SIMD would be quoting the cost of not having a builtin.

Full write-up and the rest of the proposal: [../simd-data-structures.md](../simd-data-structures.md).

## 4. Retired: the `V128` value type and its 12 intrinsics (#536, #696 -> #2342)

`v128_load` / `v128_store` / `v128_splat_i8x16` / `v128_eq_i8x16` /
`v128_le_u_i8x16` / `v128_ge_u_i8x16` / `v128_and` / `v128_or` / `v128_not` /
`v128_bitmask_i8x16` / `v128_any_true` / `v128_all_true_i8x16`, and the
`CtNamed("V128", [])` type behind them, **no longer exist**.

They were removed because the representation could not be fixed cheaply: a
`V128` value was a tagged pointer to a 16-byte heap block with no RC header, so
every intrinsic bump-allocated 16 bytes that nothing ever freed. Measured on
the same algorithm, 4 KiB byte search, 500 iters
(`bench/bench_simd_bytes_find.vibe`):

| lane | ns/op | B/op |
| :--- | ---: | ---: |
| inline-wasm kernel | 248 | 0 |
| the same algorithm through the intrinsics | 5564 | **8048** |

22x slower, and 2 unreclaimable bytes allocated per byte scanned. Nothing in
the tree used them except their own fixture. The surface nevertheless
type-checked and read like the supported way to write SIMD, which made it a
trap rather than an option — so it is gone rather than documented as slow.

The alternative considered was to keep the type and reject any `V128` that
escapes a function body, lowering the rest to a wasm local (the shape of
ADR-0090's `let mut` escape analysis). That buys a composable vector type
which §2 already provides at zero cost, and pays a new analysis pass and a new
diagnostic class for it.

`tests/gates/mid/run.sh` step 40 now asserts the names stay unresolvable: a
retired surface that quietly comes back is worse than one that never left.
