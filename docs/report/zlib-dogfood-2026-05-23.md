# vibe Dogfood: zlib in vibe (2026-05-23)

## Goal

Build a real, non-trivial library entirely in vibe and observe both the
*write-ability* (what hurts, what doesn't) and the *execution speed* of
the compiled wasm output. Target: a self-contained DEFLATE + zlib codec
that round-trips against Python's `zlib.compress` reference vectors.

## Result

A working library at `vibe/x/zlib/` — ~700 lines of impl, 146 of tests,
115 of bench. Tests `9/9` pass; bench produces stable per-op numbers
(see §[Numbers](#numbers)).

| File | Lines | What |
|---|---:|---|
| `adler32.vibe` | 28 | RFC 1950 checksum |
| `bitstream.vibe` | 136 | LSB-first bit reader / writer |
| `huffman.vibe` | 115 | canonical Huffman code-length → decode table |
| `inflate.vibe` | 225 | DEFLATE decode (stored / fixed / dynamic Huffman) |
| `deflate.vibe` | 44 | stored-block encode |
| `zlib.vibe` | 73 | header + DEFLATE + Adler-32 trailer |
| `index.vibe` | 24 | public re-exports |
| `zlib_test.vibe` | 146 | round-trip + Python zlib reference vectors |
| `bench.vibe` | 115 | throughput bench (`vibe bench`) |

## Backend comparison (wasm-gc vs wasm-linear)

A standalone driver (`standalone_bench.vibe`) was compiled twice with
`vibe compile`, once per backend, and timed via `wasmtime run`. The
driver does:

- adler32 over 16 KB × 200 calls
- deflate_stored 16 KB × 200 calls
- inflate over the 16 KB stored payload × 50 calls

| backend | wasm size | wall time (3 runs) | speedup |
|---|---:|---:|---:|
| `--wasm-linear` | **61,542 B** | 244 / 207 / 199 ms | 1.0× |
| `--wasm-gc` | **7,733 B** | 117 / 112 / 112 ms | **~1.9×** |

Subtracting ~50 ms of wasmtime startup, the GC backend is **~2.7× faster
on the actual work** and **~8× smaller as a binary**. Same source, same
optimization level (both debug), same wasmtime invocation. The gap is
entirely from codegen differences: the linear backend emits explicit
linear-memory ops + a hand-rolled allocator, while wasm-gc lets us hand
the structures (BitReader/HuffTable/Bytes/Array) directly to the host
runtime's GC.

## Throughput numbers (default backend = wasm-gc)

`vibe bench vibe/x/zlib/bench.vibe` (host vibe.exe, debug build,
default backend = wasm-gc compiled, wasmtime 45):

| bench | per-op | derived throughput |
|---|---:|---:|
| adler32 / 1 KB | 31.65 μs ± 0.83 | **32 MB/s** |
| adler32 / 16 KB | 513 μs ± 7 | **32 MB/s** |
| adler32 / 64 KB | 2.05 ms ± 50 | **32 MB/s** |
| deflate_stored / 1 KB | 30.5 μs ± 0.5 | **34 MB/s** |
| deflate_stored / 16 KB | 490 μs ± 54 | **33 MB/s** |
| deflate_stored / 64 KB | 1.88 ms ± 30 | **35 MB/s** |
| inflate (stored) / 1 KB | 110 μs ± 1.6 | **9.5 MB/s** |
| inflate (stored) / 16 KB | 1.69 ms ± 15 | **9.7 MB/s** |
| inflate (fixed Huffman, 50 B out) | 41.4 μs ± 4 | n/a (tiny) |
| zlib round-trip / 4 KB (repetitive) | 682 μs ± 8 | ~6 MB/s |

Steady-state Adler-32 and deflate_stored throughput is ~32–35 MB/s.
inflate is ~3× slower than deflate_stored at the same size, which
matches expectation: the Huffman / RLE-decode inner loop does
byte-at-a-time bit reads and length/distance lookups, whereas stored
deflate is essentially a memcpy with bit-aligned framing.

The fixed-Huffman bench shows there's measurable per-call overhead
(~41 μs for ~50 B of output) — table construction dominates short
inputs. A real-world inflate would amortize this over many KB.

## Write-ability notes

### Worked well

- **Pattern matching + enum**: `match peek(tokens, p) { TPlus => …, _ => … }`
  in `parse_supers` (earlier work) and DEFLATE block dispatch felt
  exactly like writing OCaml/Rust. Codegen is one-step from the source.
- **`with { Error }` + `throw`**: the bit-stream EOF and Huffman
  validation paths used `throw "..."` directly. No try/catch ceremony at
  the call site — callers either propagate via `with { Error }` or
  handle with `?`. The library API ended up clean: `inflate(data) ->
  Bytes with { Error }`.
- **`Bytes` ops**: `Bytes::new / push / get / append / blit / slice` are
  exactly the right primitives for a compression codec; no need to drop
  to lower-level Array[Int].
- **Bit operators**: `<<`, `>>`, `&`, `|`, `^` worked at full
  expressivity. The "no `~`" caveat noted in CLAUDE.md was a non-issue —
  `x ^ 0xFFFF` was just as readable as `~x`.
- **`vibe check` + `vibe test`**: edit / re-check / re-test cycle was
  fast enough (~1 s for a single file) and the error messages
  consistently pointed at the right token span.

### Friction

- **`mut` on struct fields not supported**. `struct BitReader { mut
  byte_pos: Int; mut bit_pos: Int }` is a parse error; vibe's struct
  fields are immutable. Worked around by holding a `state: Array[Int]`
  of length 2 and writing `Array::set(r.state, 0, byte_pos)`. This
  costs an Array allocation + extra indirection per BitReader, and the
  reader/writer code became ~25% longer than the natural form. *(Issue
  candidate: structural support for mutable fields, or a first-class
  `Cell[T]` / `Ref[T]`.)*

- **No `return` statement**. Early-return inside a `while` had to be
  rewritten as a `let mut found = -1; while … && found < 0 { … }`
  pattern. Workable but adds a state variable; the Huffman decode_symbol
  loop is one example. Not a blocker, but several spots ended up
  noticeably less direct than the C/Rust equivalent.

- **`(args) -> Type { body }` is deprecated**. Every `let fn = (x: T) ->
  R { body }` triggered a `deprecated function style` warning telling
  me to use `let fn: (T) -> R = (x) -> { body }` instead. Two issues:
  (1) the warning is *very* verbose (multi-line caret marker on every
  match) so a single deprecated definition floods 8+ output lines;
  (2) `vibe fmt` auto-converts, but a fresh contributor writing from
  the cheatsheet hits this on every function. Either bump the
  deprecation to `silent` until removal, or compress the warning
  format.

- **Unused-import warning for type-only imports**. `huffman.vibe`
  imports `BitReader` solely to annotate `decode_symbol`'s parameter
  type and gets `warning: unused import: BitReader`. The import is
  type-checked as used. Probably the usage scanner only counts
  value-position references. Cosmetic but noisy.

- **Empty-array literals**. There's no `[]: Array[Int]` form; vibe
  needs `Array::slice([0], 0, 0)` (or an explicit one-element seed
  + truncate). This is documented in the codebase but it's a paper cut
  every time you build an accumulator. *(See `let empty_int_array = ()
  -> Array[Int]` helpers in `huffman.vibe`, `inflate.vibe`, etc. —
  that helper exists three times across this small library.)*

- **No tuple destructuring inside `match` arms with side effects**.
  Wanted to write `let (litlen_t, dist_t) = if btype == 1 {
  (fixed_litlen_table(), fixed_dist_table()) } else {
  read_dynamic_tables(r) }` — it worked, but only because both branches
  produce the same tuple type *and* `with { Error }` on both. When I
  briefly returned `(...)` from one branch and `read_dynamic_tables(r)`
  (a `with { Error }` call) from the other, effect inference complained
  the if's branches had inconsistent effects. Fix was small (just
  propagate `with { Error }` upward), but the error message was about
  "branch effect mismatch" rather than "this branch has Error but the
  other doesn't" — took an extra read to triangulate.

### Numbers I'd improve

- **Per-call overhead is large for short inputs.** 41 μs to inflate
  ~50 B is ~1.2 MB/s, vs ~10 MB/s asymptotic. Most of that is Huffman
  table construction (288 + 30 symbols sorted into a flat layout) and
  warmup, not the actual decode loop. A reusable fixed-table singleton
  would close most of the gap; vibe doesn't have a top-level "thunked
  lazy" form right now, so I'd need to wrap them in a `Array[HuffTable]`
  cache module-level. Out of scope for this dogfood.

- **inflate at 9.5 MB/s** is order-of-magnitude slower than
  `zlib_inflate` (typically 100+ MB/s native). Expected — vibe is
  compiled to wasm and inflate is bit-stream / branch-heavy. A faster
  variant would build a flat 9-bit lookup table for the fixed Huffman
  block and inline the length / distance extra-bits logic.

## Summary

vibe is *clearly* up to writing real algorithms — DEFLATE inflate (the
hardest piece) fell out in ~225 lines and worked first-try against a
Python reference vector once the syntax issues were fixed. The
showstopper for performance-sensitive systems code is the missing
mutable-struct-field support (forced Array[Int]-as-cell pattern), and
the cosmetic papercut is the deprecated function-style warning. Neither
blocks anything. inflate throughput of ~10 MB/s puts vibe in the same
ballpark as "small interpreter on wasmtime" — fine for tooling, not yet
competitive with native zlib for hot paths.

## Open follow-ups (suggested issues)

1. `mut` field syntax on structs (or first-class `Cell[T]` / `Ref[T]`).
2. `[]: Array[Int]` empty-array literal sugar (eliminate
   `Array::slice([x], 0, 0)` helpers).
3. Quieten `deprecated function style` warning — it shouldn't take 8
   lines per occurrence.
4. Type-only imports should count as "used" by the import-usage scanner.
