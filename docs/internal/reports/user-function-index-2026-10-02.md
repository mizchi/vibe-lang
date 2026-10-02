# User function lookup: reuse the existing sorted view

Baseline: `b1523dcbb21bf09db2d982b852d3683520fa5f5c` (PR #3267), whose
tracked tree is identical to main at `519d113604eabc49e00410e178375e0a133b8ff3`.
`func_table_user_index_of` was a forward string scan of the user-function
prefix for every resolved call. A real warm CLI compile attributed 399.1 ms
of self time to it before this change.

Fresh named diagnostic profiles of the frozen CLI inputs observe 374.0 ms
of warm self time in this helper on the baseline and 1.2 ms on the candidate.
The shared `bsearch_leftmost` helper rises from 42.2 to 44.7 ms. These are
single CPU profiles, separate from the four-round wall-time comparison.

## Change and invariants

When both sorted-view arrays cover the function table, binary search finds
the equal-name run and the lookup returns the smallest original table position
within the user prefix. It returns a table position, not a Wasm function index.
Equal names may be reordered: a builtin ahead of duplicate users in the sorted
view must not hide the first user. Nonpositive prefixes remain empty and
oversized prefixes clip to the table length. Missing or partial views retain
the original forward scan, including the GC backend's unsorted tables.

There is no new map, table field, import, package contract, builtin identifier,
or caller change. The resolved call and ownership path remains the same.

## Controlled phase comparison

The probe has 8,192 users and three appended builtins. Every invocation makes
96 lookups and asserts both its result checksum and an unchanged heap pointer.
Lazy table and query initialization occurs before the heap mark; `_start`
smoke-runs the cases outside timing. Each sample is a fresh process through
the standard wrapper, with three warmups and 20 timed invocations.
Four rounds alternate baseline/candidate order. Both probe programs are built
with the same baseline compiler, isolating the changed helper source.

| Case | Baseline ns/lookup | Candidate ns/lookup | Change |
| --- | ---: | ---: | ---: |
| `builtin_names` | 16,548.7 | 204.5 | -98.76% |
| `existing_users` | 23,197.9 | 283.5 | -98.78% |
| `without_sorted_view` | 16,411.8 | 14,881.1 | -9.33% |

All lookup cases allocate zero bytes. The phase speedup is not the whole
compiler speedup. The fallback case is a control rather than a targeted change.

## Real compilation comparison

Each compiler compiles its own frozen source tree, with regenerated bundles.
Compiler, source, cache and output paths have equal lengths. Four interleaved
ABBA rounds use an empty isolated cache for cold and that same cache for warm,
with a fresh process per sample. Checked-module and body caches are off.
No other builds or tests run during measurements. The wall timer is monotonic.
Four-sample summaries use the upper middle observation, matching the collector.
The production census stays at 575 files, growing by 717 bytes and 20 lines.
Both production splits remain 314 modules.

| Allocation reading | Baseline bytes | Candidate bytes | Change |
| --- | ---: | ---: | ---: |
| Prelude whole, cold | 1,021,144,528 | 1,021,218,392 | +0.0072% |
| Prelude whole, warm | 619,101,992 | 619,144,584 | +0.0069% |
| Prelude production split, cold | 1,333,059,888 | 1,333,134,104 | +0.0056% |
| Prelude production split, warm | 931,017,312 | 931,060,248 | +0.0046% |
| CLI whole, cold | 3,306,664,184 | 3,306,779,432 | +0.0035% |
| CLI whole, warm | 2,516,435,200 | 2,516,520,032 | +0.0034% |

These are bump-heap allocation readings, not live heap or RSS. CLI readings
are the final heap pointer; prelude readings are the probe's allocation delta.
Values reproduce across all four observations. The small increases include
the larger compiler source closure; no new lookup storage is allocated.

| Wall median | Baseline ms | Candidate ms | Change |
| --- | ---: | ---: | ---: |
| Prelude whole, cold | 5,808 | 5,695 | -1.95% |
| Prelude whole, warm | 4,346 | 4,236 | -2.53% |
| Prelude production split, cold | 6,478 | 6,319 | -2.45% |
| Prelude production split, warm | 4,819 | 4,752 | -1.39% |
| CLI whole, cold | 17,367 | 16,380 | -5.68% |
| CLI whole, warm | 11,769 | 11,179 | -5.01% |

The prelude wall changes are below the usual 5% noise threshold. CLI changes
are modest and should be read alongside the diagnostic CPU profiles rather
than as a precise universal speedup.

## Validation

Fresh seed -> stage1 -> stage2 -> stage3 reaches a byte-identical fixpoint.
Stage2 grows by 347 bytes to 3,908,150 bytes, SHA-256
`6be3a8b0c2a2fb7a85849e017c83290c3ae9402a59122c44e177d728e2f86e89`. Both named profile artifacts have byte-identical
noncustom sections to their production counterparts.

Five same-current-input compilations produce byte-identical output with both
compilers, including the new lookup regression and compiler lexer test.
The regression covers duplicate users/builtins, nonstable equal-name metadata,
prefix bounds, empty tables, missing/partial views and position/index distinction.

The unmodified imported GC test cannot instantiate on either implementation:
the existing backend reserves 64 KiB while this large closure's static data
exceeds it. A separate probe adds a supported region allocation to provision
sufficient initial memory, then runs all four original tests unchanged.
This optimization does not change GC memory emission.

All 1,560 active unit-test files pass with the fresh candidate stage2 supplied
explicitly. The four regressions pass on RC and on the region-initialized GC
probe. Required `pkf run release-check` passes: 118 tasks, 104 run and 14
input-matched cache hits. Its compiler gate independently reproduces the same
fixpoint hash. A later generation task rebuilds only the standard stage2;
the retained manual stage2/stage3 pair remains identical to that artifact.
AST-required pre-commit checks pass with the fresh candidate supplied explicitly.

Raw samples, hashes, profile counters and reproduction sources:
`bench/perf/analysis/user-function-index-2026-10-02.json`.
