# Resolved MutList callees — 2026-10-01

Dated implementation and measurement record for the next vertical slice of
[#3255](https://github.com/mizchi/vibe-lang/issues/3255), after the MutBytes
slice in [#3264](https://github.com/mizchi/vibe-lang/pull/3264).

## Scope and remaining boundaries

The seven direct MutList operations (`empty`, `push`, `freeze`, `to_array`,
`get`, `length`, `truncate`) now carry operation IDs 6–12. Source checking
resolves lexical/module bindings before assigning a builtin identity. The
checker, RC and GC dispatch, runtime aliases and synthesized references read
the same shared operation metadata. Both backends use the existing shared
region copy-out recipe. Seven checker spelling arms were removed (48 → 41).

The typed-lowering carrier now reserves 16 identity bits, with one shared
rebase helper used by memo union, provider cloning and inline cloning. Binary
AST v3 retains its varint layout and validates identities through the operation
registry; unknown IDs are refused. Codegen source fingerprints invalidate
older cached carriers. See [the binary ABI contract](../compiler/ast_binary_abi.md).

Definition/local/constructor identities, the remaining 41 spelling arms,
effect/ownership/allocation/capture classification and rename guards remain
follow-up work. A spelling lookup still exists at source resolution and the
explicit synthesized-reference factory. MutList builtin values have no
first-class signature: `let f = MutList::length` retains its `unknown name`
rejection. First-class program functions in that namespace remain supported.

## Baseline and behavior

Baseline commit: `64647bd07a8f1cb22f0b65e34d65fb6110b5693f`.
Its compiler sources match the pre-existing MutBytes review generation.
Baseline stage2/stage3 SHA-256:
`d32bf4eae97e239d48be4e7f087caf98f5a68071f916468a1d3ef43157c905b5`.
Candidate stage2/stage3 SHA-256:
`023f92375b11c5e3b7ac0c4411718607ed203bb8238c88f8057ae7000d753ad3`.
The candidate is a fresh selfhost fixpoint from the changed sources.

Before migration, both new fixtures passed on RC, and the direct runtime
fixture passed on GC. The GC import/re-export fixture failed with `expected
Int, got MutList`: a private entry-module `MutList::push(Int, Int)` captured a
dependency builtin during the flattened whole-program check. The GC filesystem
driver now protects references outside a private definition's source unit
before that check, after module checking and export validation. Definitions
and owned references retain their source names for trait-method checking;
the normal post-check rename still owns definition names and ABI tables.
Both fixtures then pass on both backends. An initial attempt to move the
complete rename earlier failed the existing trait-method dot-call gate; the
final implementation shares its source-unit analysis without moving definitions.
Two new unit tests pin private/published/local binding distinctions and
idempotence, and the existing trait-method fixture passes on both backends. The low-level GC unit helper collects checker identities before
emission while retaining its deliberately unchecked backend probes; source
drivers still enforce source errors.

Validation of the candidate includes:

- Full compiler unit corpus: **1,555/1,555 files passed**. This includes five new
  MutList tests and the twelve existing MutBytes tests.
- All seven operations, scalar reads, noncommutative arguments, private and
  lexical shadows, imports/re-exports and explicit synthesized references.
- Binary transport, invalid IDs, mixed typed rows, all three carrier rebases,
  and offsets producing packed values above 32 bits.
- Independent `freeze`/`to_array` snapshots after truncation and region reuse.
  Both families' direct/import fixtures are wired into the existing GC/shadow
  compiler gate.
- Isolated cold/warm filesystem caches on RC and GC, including a manual
  long-source-offset probe; identical negative diagnostics before/after on
  both backends for forged region tokens, non-Int indices/truncate lengths
  and unsupported builtin values.
- Builtin parity and binary tag gates; source size remains below 3,000 lines
  per compiler file.

## Controlled measurements

[Raw samples and provenance](../../../bench/perf/analysis/resolved-mutlist-callees-2026-10-01.json)
contain 32 samples: four cold and four warm runs per compiler and corpus.
The harness uses independent persistent caches per round/compiler, equal-width
paths, alternating AB/BA order, one process per sample and no concurrent builds
or tests. Node 24.7.0, Linux x64, Ryzen 7 7700; target linear RC, compiler bump
allocation. Checked-module/experimental-AST/body caches are disabled. OS caches
are uncontrolled. `heap_ptr` measures cumulative compiler allocation, not live
memory or target-region reclamation.

| Corpus | Cache | Baseline median wall | Candidate median wall | Wall change | Paired wall ratio | Allocation change | Peak RSS change |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Closure | Cold | 10,213.17 ms | 10,182.28 ms | −0.303% | 0.9981 | +0.0072% | −0.030% |
| Closure | Warm | 8,197.78 ms | 8,116.45 ms | −0.992% | 0.9946 | +0.0115% | +0.489% |
| Cli | Cold | 26,341.48 ms | 26,490.38 ms | +0.565% | 1.0065 | +0.0026% | −0.680% |
| Cli | Warm | 20,337.89 ms | 20,458.43 ms | +0.593% | 1.0071 | +0.0033% | −0.136% |

This is a semantic refactor; these small wall/RSS changes do not establish a
speedup. Allocation increased by 96,864–103,840 bytes per run. Generated
closure and CLI wasm outputs are byte-identical across all runs and compilers.
The compiler artifact shrank from 3,907,403 to 3,907,185 bytes (−218 bytes).

A census of tracked `lib/@vibe/compiler` `.vibe`/`.vpkg` files, excluding
`/tests/` and `*_test.vibe`, has 566 files before/after, 12,353,618 → 12,353,481
bytes and 314,852 → 314,860 lines. The largest file is `file_compile.vibe`,
2,951 → 2,952 lines; no production module was added. All identity channels
remain explicitly parameterized, without new process-global state.
