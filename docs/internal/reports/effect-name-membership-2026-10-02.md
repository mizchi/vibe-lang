# Effect name membership: CPU and allocation measurements

The baseline is `c8ea715e81236aea1d4729074d857271a8ebd57b` (PR #3266).
The candidate changes only the representation of name membership and the
storage used by two read-only AST walks. It preserves the existing conservative
shadowing rules and the ordered purity fixpoint.

## Change

- The program-local binder census stores names in a `MutSet[String]`, reset
  for every program, instead of deduplicating and searching a string array.
- Visible pure lambda discovery builds a membership set from `pure_fns`
  once per pass. The result remains an array: existing duplicates and
  append order are preserved, and an appended name becomes visible immediately.
  The initial set capacity accounts for the known input length.
- Binder collection and lambda candidate collection use the existing
  `expr_children_push` / `expr_child_at` / `expr_children_pop` stack, avoiding
  a fresh child array at every interior AST node. Each recursive walk preserves
  its caller's window.

There is no change to package contracts, the builtin registry, effect decisions,
or emitted program behavior. No performance ceiling or gate tolerance changed.

## Profile evidence

Profiles compile `lib/@vibe/cli/main.vibex` through the standard runner wrapper.
The named artifacts have identical executable sections to their production
stage2 counterparts at profiling time. The final import-header formatting changes
only the equal-length cache fingerprint string in the compiler data section;
all instruction, type, and table sections remain byte-identical. The quantitative
comparison below uses the final formatted artifact and sources. Each temperature has an isolated cache, with a fresh
process for the cold run and another process using the same cache for warm.

The warm self-time observations are diagnostic single profiles, rather than
the wall-time headline measurements:

| Function | Baseline | Candidate |
| --- | ---: | ---: |
| `edp_str_array_contains` in queries | 3,837.7 ms | 309.3 ms |
| `edp_collect_binders` in queries | 1,865.5 ms | 333.3 ms |
| `edp_note_pat_binders` in queries | 1,091.9 ms | 48.1 ms |

## Controlled comparison

Each compiler compiles its own frozen source tree. Compiler, cache, source-root,
and output paths have equal lengths. Four interleaved rounds alternate the
compiler order (ABBA). Each sample starts a fresh process; cold uses an empty
cache, warm uses the corresponding cold cache. Checked-module and body caches
are off. No local builds or tests run alongside these measurements.

Prelude results use the unchanged `scripts/selfhost_build_metrics.mjs` collector
and `scripts/prelude_split_memory.vibex` probe. Both snapshots split into
314 modules. The CLI corpus also includes the generated compiler source bundles,
regenerated separately from each snapshot; its host wall timer is monotonic.

| Allocation reading | Baseline bytes | Candidate bytes | Change |
| --- | ---: | ---: | ---: |
| Prelude whole, cold | 1,032,997,648 | 1,021,363,752 | -1.13% |
| Prelude whole, warm | 630,916,168 | 619,206,184 | -1.86% |
| Prelude production split, cold | 1,346,523,496 | 1,333,306,304 | -0.98% |
| Prelude production split, warm | 944,441,992 | 931,148,696 | -1.41% |
| CLI whole, cold | 3,506,714,760 | 3,307,102,104 | -5.69% |
| CLI whole, warm | 2,716,322,816 | 2,516,638,472 | -7.35% |

These are bump-heap allocation readings, not live heap or host RSS. CLI readings
are the final heap pointer; prelude readings are the probe's allocation delta.
They agree within each configuration across all four samples.

| Wall median | Baseline ms | Candidate ms | Change |
| --- | ---: | ---: | ---: |
| Prelude whole, cold | 6,133 | 5,847 | -4.66% |
| Prelude whole, warm | 4,565 | 4,466 | -2.17% |
| Prelude production split, cold | 6,773 | 6,717 | -0.83% |
| Prelude production split, warm | 5,013 | 4,904 | -2.17% |
| CLI whole, cold | 24,727 | 16,776 | -32.16% |
| CLI whole, warm | 19,123 | 11,597 | -39.36% |

For four samples, wall summaries use the upper middle observation, matching
the collector median rule.

The small prelude wall differences are advisory and below the usual 5% noise
threshold. The larger CLI reduction agrees with the targeted CPU profiles.

## Artifact identity and behavior

The fresh seed -> stage1 -> stage2 -> stage3 build reaches a byte-identical
stage2/stage3 fixpoint. Stage2 grows from 3,907,620 to 3,907,803 bytes (+183).
Its SHA-256 is
`b0b250de0edc39033a82d913453672dbaafad644f46b6b7b55c449758fb948d8`.
The production source census (compiler manifest plus CLI sources, excluding
generated bundles and unit tests) stays at 575 files and grows by 697 bytes.

Compiling the same current inputs with the baseline and candidate produces
byte-identical Wasm for the compiler lexer test, the new membership test,
the pure helper fixture, the shadowed local lambda fixture, and the labeled
inline lambda argument fixture. This equivalence comparison holds source
contents fixed; the own-source performance comparison intentionally compiles
different implementations of the compiler helpers and embedded source bundles.

The new four-test regression covers nested binder kinds, reset between
programs, preservation of an enclosing scratch window by both collectors,
ordered purity dependency growth, existing duplicate entries, and rejection
of same-spelled effectful or non-lambda bindings. It runs on the RC lane and
on GC with the native host runner (the compiler helpers import `vibe::env-get`).
All 1,559 active unit-test files pass with the candidate stage2 supplied explicitly.
That full corpus ran before final import-header formatting; the section comparison
above proves its compiler instructions are identical to the final artifact.
The four RC/GC regressions and five output-equivalence cases were rerun with
the final artifact.

The required formatter self-test exposed two remaining wall-clock-dependent
rebuild assertions. They now create a dependency timestamp explicitly newer
than the cached artifact, prove replacement by atomic-publication inode identity,
and restore the dependency timestamp afterward. This changes only the test;
the formatter cache implementation and gate thresholds are unchanged. The
full `scripts/vibe_fmt_parse_guard_test.sh` passes.

Required `pkf run release-check` passes: 118 tasks, 109 run and 9 input-matched
cache hits. Its compiler gate independently reproduces the same stage2/stage3
fixpoint as the measured final artifact.

Raw samples, cache protocol, source and generated-bundle hashes, compiler
identity, output equivalence hashes, and diagnostic CPU counters:
`bench/perf/analysis/effect-name-membership-2026-10-02.json`.
