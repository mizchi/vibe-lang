# Compile-only body-cache residue (#2497)

The named compile-only compiler still carried replay, edit relocation and
harvest processing although its production lanes always passed an empty input
cache and a discard-only output cache. Those mutable records were an implicit
policy that entry reachability and constant-Bool folding could not recover.

The production wrappers now pass a literal `body_cache_enabled = false` through
preparation, finishing and built-in serial body emission. Existing cache APIs
pass `true`, and registered function executors retain their callback ABI and
cache/transport protocol. The existing Bool-parameter pass then removes the
false arms and ordinary reachability removes the helpers they alone called.
The `no-dce` wrapper also needs the explicit policy: it is reachable from the
production filesystem lane and otherwise keeps the enabled call alive.

This is not a new language feature or an allocator decision. RC remains the
default, bump remains explicitly selectable, grants are forwarded unchanged,
and cfg, unstable authorization and generated-source trust remain inputs to
each compilation. Production line maps are retained.

## Source and artifact identity

Baseline source: `616d2e2667479202f8d8187d5af0bf0ea9fbd073`.
Both ordinary compilers were built from the pinned seed with names, including
stage3 and compile/run validation. Each stage2 equals its stage3 byte for byte.
Each named compile-only artifact was then built by its own stage2, without a
compiler resolver fallback. Exact artifact and changed-source hashes are in
`results.json`; the generated flat-source hashes are recorded below.

| Artifact | Baseline SHA-256 | Candidate SHA-256 |
| --- | --- | --- |
| Full stage2/stage3 | `03b7ef43ff9c4807c5c0c12a4ee5b6574154c150a99212f79fe42746879ba678` | `a56b5cc406464e2145c92f47ba13cf58f6af44311e1faff6eaf014fe80d5eecc` |
| Full flat source | `9471cfefb7d86d99a152fbce7d3c68b498822e815441cd6ff2528d719df61b31` | `e03594df0cc8cee6bea5581ead460d992d40ce1ed37cd505f596225a10cf7f92` |
| Compile-only Wasm | `6cdce6db3b4a974f0673ab8e76de20bc9e1f73b73e96d6b2b30a914aaa2e990d` | `45f863534db10e695fa2241a896dc3f974e1c202820533d7f567a95731fede68` |

## Size attribution

Measured with `scripts/wasm_func_sizes.mjs`, using named artifacts on both
sides. File size includes names; function-body bytes exclude section framing,
body-length prefixes and name/debug/data sections.

| Measure | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Named file bytes | 6,153,032 | 6,094,429 | -58,603 (-0.95%) |
| Code-section payload bytes | 4,880,522 | 4,832,380 | -48,142 (-0.99%) |
| Function-body bytes | 4,862,735 | 4,814,754 | -47,981 (-0.99%) |
| Defined functions (all named) | 11,551 | 11,446 | -105 |
| `codegen_body_cache_*` / `bcc_*` function bytes | 13,750 (31 functions) | 1,971 (12) | -11,779 |
| `linked_body_cache_*` module function bytes | 20,947 (55 functions) | 541 (4) | -20,406 |

The last two rows are disjoint, narrow name/module groups, not all code in a
file whose name mentions caching. Shared cache constructors, fingerprints and
a few preparation helpers remain. The replay/record, source-edit reindex,
string-relocation and edit-agreement witnesses checked by the lane gate are
absent. This closes one measured processing family, not every remaining state
field in `CompileCtx`.

## Cost and equivalence protocol

Run `measure.py BASELINE.wasm CANDIDATE.wasm _build/NEW_DIRECTORY` from the
checkout with no build or test running. Both explicit artifacts compile the
same current source. They move through the same literal compiler path, and
all runs use the same literal cache/output paths. Each pair starts with a
fresh private cache, runs cold then warm in separate Node processes, and is
removed before the next pair. Three rounds alternate AB/BA/AB. The compiler
and output use bump (`VIBE_RC=0`); cfg, authorization and cache controls are
recorded explicitly. The host runner wrapper supplies the normal Node/Wasm
flags. `VIBE_SKIP_RUN_INIT=1` prevents the runner from invoking `_start`
before the compile-only export, and `VIBE_RUNNER_EXIT_WITH_RESULT=1` propagates
its status. The harness refuses repeated result lines. An initial trial
without the skip flag was rejected for executing twice and is excluded. No
seed fallback or output-artifact memo participates.

The workloads are `codegen_lexer_test.vibe` with `__no_entry__` and the full
`cli_adapter.vibe` with `cli_main`, through the compile-only compiler's
`cli_main_compile_only` export. All output hashes must agree across both
compilers, all temperatures and all rounds for each workload.

`heap_ptr` is the bump heap high-water pointer, including static data, not
peak RSS or retained/live memory. Small wall-time changes are not evidence of
a speedup on their own. Raw runs, medians, code-section payload sizes and
selected per-function attribution are in `results.json`.

All 24 output hashes agree within each workload. The medians show no wall-time
improvement beyond the noise floor. Deterministic bump high-water reductions
are about 0.58 MiB for the compiler test and 1.12 MiB for the CLI closure.

| Workload | Cache | Baseline wall | Candidate wall | Wall change | Baseline heap MiB | Candidate heap MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Compiler test | cold | 9.034 s | 8.900 s | -1.48% | 1,130.658 | 1,130.079 |
| Compiler test | warm | 4.716 s | 4.714 s | -0.04% | 625.972 | 625.389 |
| CLI closure | cold | 18.712 s | 18.873 s | +0.86% | 2,435.511 | 2,434.389 |
| CLI closure | warm | 10.392 s | 10.345 s | -0.45% | 1,323.332 | 1,322.207 |

## Regression controls

The lane gate keeps the six refusal probes and RC/bump acceptance. It now also
checks the measured cache-processing witnesses and switches cfg and unstable
inputs in both directions with one artifact/cache. The real reserved Iterator
provenance carrier is refused, accepted with out-of-band generated-source
trust, then refused again, on both RC and bump single-source lanes.

The gate's self-test retains stripped-name, GC-leak, full-CLI-acceptance and
real-artifact controls, and adds a real named body-cache-replay leak. The old
compile-only artifact fails the new absence check. The production-line-map
unit test uses located parsing and proves that renaming the source file changes
the output. A populated cache whose bodies are poisoned is ignored with the
policy disabled, and nothing is harvested; changing that policy back to true
reaches real replay and fails with `blind reloc: offset outside the body`.

Local regression validation passed all 21 targeted files / 123 tests separately
under bump, RC and shadow (369 tests), capability-import reachability, and all
2,041 active unit-test files with the explicit candidate stage2 and compiled
output caching disabled. The final unit run used four workers. An initial
eight-worker run exhausted local disk while making private caches; after
verified archival, all three affected files passed from fresh isolated caches
with both baseline and candidate, and the complete four-worker rerun passed
without code changes.

The ordinary release gate also exposed one stale existing diagnostic expectation
for `err_impl_method_bound_alias_impl_binder`. Both baseline and candidate emit
the same rejection in entry/no-entry and first/repeated invocations: the
imported alias `T = Int` is displayed as `StringMap[Int]`. Only that TSV row is
updated from `StringMap[T]`; the full rejection-reason matcher is retained.
No checker code or compiler artifact changed for this correction.

The ordinary `pkf run release-check -j 1` completed with exit 0: 112 tasks,
106 executed and six cached (61m27s). Its bootstrap lane asserted the
stage2/stage3 fixpoint. The retained named candidate stage2/stage3 and every
measured compiler-source and harness hash were rechecked after the gate and
remain unchanged. The release receipt records the compiler-source tree IDs.
