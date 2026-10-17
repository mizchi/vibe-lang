# Reuse of seed validation as stage1 (2026-10-17)

The verified seed validation product replaces the repeated seed-to-stage1
compile. Source/seed/entry/runner/tools/options and product hashes are bound
by a receipt; a mismatch uses the ordinary compile. Stage2 and stage3 remain
separate rebuilds. This is the first bounded optimization selected in #3482.

## Controlled whole-build comparison

Each configuration has three samples per workload and temperature. Workload
and baseline/candidate order alternate between rounds. Node/JIT processes are
fresh and OS source pages are warm. Private guest caches are isolated per pair;
checked-module, body and final CLI artifact caches are disabled. No profiles
or other local tests overlap the timed matrix. Packaging and installation are
excluded. The earlier pilot is not pooled into these results.

The controlled environment sets `VIBE_UNSTABLE=1`, `VIBE_LIB` to each frozen
checkout, `VIBE_IMPORT_ABI=raw`, and the build scripts retain target bump
allocation (`VIBE_RC=0`). Exact selected settings are in the raw record.
The required release-check separately exercises the ordinary task environment.

Compiler: `ensure_generated.sh` followed by prebuilt-source generation through
stage3. Cold removes only the private generated files/stamp and merge-tool
image/stamp; warm retains them, so source generation is an up-to-date check.
Portable CLI: the production `build_cli_wasm.sh` through stage2, target `main`;
warm retains the merge tool but the builder still regenerates flat source.

| Workload | Cache | Before wall median [range], s | After wall median [range], s | Wall delta | Before / after median peak RSS, MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| compiler | cold | 259.085 [258.632–260.331] | 213.939 [208.813–215.022] | -17.43% | 3482.1 / 3479.5 |
| compiler | warm | 143.473 [142.521–143.713] | 98.129 [93.282–99.139] | -31.60% | 3480.0 / 3482.5 |
| portable-cli | cold | 203.206 [188.823–203.402] | 158.804 [148.436–158.935] | -21.85% | 3485.8 / 3488.3 |
| portable-cli | warm | 153.532 [143.455–153.998] | 109.116 [100.272–109.805] | -28.93% | 3473.6 / 3471.5 |

## Host phase attribution

Phase medians below are independent observations. The validation span is part
of preparation; overlapping spans must not be added to reconstruct total wall.

| Workload/cache | Lane | Seed validation, s | Seed → stage1 or reuse, s | Stage1 → stage2, s | Stage2 → stage3, s |
| --- | --- | ---: | ---: | ---: | ---: |
| compiler/cold | baseline | 44.700 | 44.969 | 45.899 | 45.699 |
| compiler/cold | proposal | 45.090 | 0.243 | 45.894 | 45.005 |
| compiler/warm | baseline | — | 44.796 | 45.865 | 45.889 |
| compiler/warm | proposal | — | 0.253 | 46.037 | 45.070 |
| portable-cli/cold | baseline | 44.781 | 44.757 | 45.332 | — |
| portable-cli/cold | proposal | 44.546 | 0.237 | 45.295 | — |
| portable-cli/warm | baseline | 44.615 | 44.594 | 45.811 | — |
| portable-cli/warm | proposal | 44.239 | 0.178 | 45.730 | — |

RSS sums simultaneously resident processes every 20 ms; shared mappings may
be counted more than once. It is separate from guest allocation volume, heap
frontier and reserved pages. The raw record retains every sample and spread. The largest candidate peak
was 3490.8 MiB, below the 4,096 MiB whole-build ceiling.

## Correctness and source authority

All 24 runs exit successfully; every stage hash agrees across configuration,
round and temperature. All 12 compiler runs verify stage2 == stage3. The actual
stage2 target entry is observed in the sampled process command (`cli_main`
for the compiler, `main` for portable CLI), separately from the fixed seed ABI.
All 12 candidate runs log receipt reuse; all 12 ordinary controls compile stage1.

The fixed compiler sources are archive `96e31d1ff60208f3c26b82c7c220ed77871d2a73`
plus an exact recorded build-script overlay. Compiler library sources and seed
are equal in both lanes. Frozen-file/archive hashes establish authority;
the generation driver can observe the enclosing developer checkout in its
`source.commit/dirty` fields. The report records the overlay and driver hashes.
Subsequent CI and documentation-index edits wire the receipt tests into
compiler-build and register this report. Their before/after hashes are recorded
separately; no measured builder code changed.

[Raw samples, phase medians, paired deltas and hashes](../../../bench/perf/analysis/seed-validation-reuse-2026-10-17.json).

## Remaining work

The serial compiler stage1-to-stage2 and stage2-to-stage3 compiles remain.
Cold builds also retain merge-tool construction and source validation. The
prototype native process workers still need lower transport/live-set cost
(#3483), actual bounded native-thread execution (#3484), bump-target/bootstrap
and installed-toolchain integration (#3485), and the full promotion gate
(#3486). Default CPU parallelism remains unchanged.

The absolute walltime targets proposed in #3481 use another source/protocol;
this comparison does not claim that the eventual threaded rollout passes them.
The raw record exposes same-source wall and memory deltas for the current route.
