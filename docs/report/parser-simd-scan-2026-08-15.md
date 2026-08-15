# Parser SIMD scan assessment (2026-08-15)

This note evaluates the lexer pipeline from
[SIMD Lexer Pipeline: classify, carve, coalesce, compress](https://gist.github.com/mizchi/1ba06e646dbc6396a50798a2f9678d15)
against vibe's current selfhost parser.

## Existing advantages

vibe already has three prerequisites that the pipeline recommends:

- `String` is a UTF-8 byte string, so a `v128.load` does not need a UTF-16
  gather;
- `lex_with_offsets` produces separate token, start, and end arrays;
- parsing is unfused and performs lookahead over the completed token stream.

The compiler also has allocation-free fused SIMD scan bodies for whitespace
and identifier bytes. They keep `v128` values on the operand stack instead of
boxing every intrinsic result.

## Identifier experiment: do not integrate

Replacing `scan_ident_end` with the existing `simd_scan_alnum_str` was neutral
on `lexer_keyword_bench.vibe`:

| implementation | median time for the benchmark body |
|---|---:|
| scalar | about 93.1 us |
| fused SIMD | about 93.0 us |

The difference is below run-to-run noise. Typical identifiers are too short to
repay SIMD setup, matching the earlier whitespace-run result in
`docs/spec/simd-api-design.md`. The experiment also exposed a tooling gap:
`#zero_alloc` does not yet recognize `simd_scan_alnum_str` as allocation-free,
although its fused runtime body allocates nothing.

## Where the bytes are

A census of the 946 tracked `lib/**/*.vibe` and `lib/**/*.vpkg` files gives the
following opportunity sizes. String runs are bytes between quote/backslash
events; comment runs are bytes after `//` until newline. The identifier count is
a lexical upper bound because the simple census also sees words in strings and
comments.

| run class | total runs | runs >= 16 B | bytes in runs >= 16 B |
|---|---:|---:|---:|
| identifier-shaped | 1,160,550 | 45,275 | 1,063,603 |
| ordinary string segment | 60,337 | 15,253 | 635,324 |
| line comment body | 41,884 | 37,994 | 2,486,838 |

Long comments and ordinary string segments are therefore better SIMD targets
than identifiers or whitespace.

## Recommended next slice

Add specialized fused, unboxed scanners rather than exposing per-operation
`V128` values to lexer code:

1. `simd_scan_line_end_str(String, pos, len) -> Int` finds LF while skipping
   ordinary 16-byte chunks. Wire it into `skip_until_newline` with a scalar
   tail.
2. `simd_scan_string_special_str(String, pos, len) -> Int` finds the next
   quote, backslash, interpolation dollar, newline, or control byte. Keep the
   existing scalar state machine for the returned sparse event.
3. Teach the `#zero_alloc` call graph that these fused scalar-result builtins
   are allocation-free, using the builtin registry as the source of truth.

Phase 1 of #1868 introduces the second scanner as
`simd_scan_string_special_str`, with a scalar-oracle fixture on both linear and
GC backends. It reports quote, backslash, or an ASCII control byte. Compiler
source integration remains intentionally separate: it requires the next seed
to know the builtin and must still pass the benchmark gates below.

The isolated 1 KiB ordinary-run benchmark (`bench_simd_string_special.vibe`)
measured 42 ns p50 for the fused scanner versus 2,417 ns p50 for the scalar
byte loop on the same local Wasmtime runner, with 0 B/op in both lanes. This
only establishes that the primitive has enough headroom: lexer integration
still has to include dispatch/setup cost and representative-source A/B data.

Do not start with a full classify/compress token tape. `Token` is still a rich
enum and identifiers/string tokens materialize substrings, so making every
punctuation position into a bitmap would add a second representation before
removing the first. A compact token-kind tape becomes worthwhile only together
with lazy source slices or a token ABI change.

## Acceptance gates

The SIMD follow-up should carry three benchmark lanes:

- representative compiler source: no statistically significant regression;
- comment-heavy source with 32-256 byte comment bodies: clear improvement;
- string-heavy source with long ordinary spans plus escape/interpolation
  controls: byte-identical tokens and clear improvement.

Allocation must remain unchanged, `#zero_alloc` must stay on the scalar wrapper,
and both linear and GC backends must run the same correctness fixtures because
`String` remains in linear memory on both lanes.
