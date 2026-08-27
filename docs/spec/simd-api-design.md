# SIMD in vibe: what exists, and how to write a kernel

Updated 2026-08-26. This document describes the **current** state.

There are two supported ways to get wasm SIMD into generated code, and they
serve different callers.

## 1. Fused scan builtins (the compiler's own hot paths)

A fused builtin emits **one wasm loop** in which the `v128` chunk stays on the
operand stack for the whole scan, with a scalar tail.

**vibe has no vector value type.** A vector lives on the operand stack or in a
wasm local and never becomes a vibe value, so there is never anything to box.
That is an invariant of both mechanisms here, not an implementation detail of
either: a lowering that hands a vector back as a value has to heap-allocate it
(#2342 measured what that costs).

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
