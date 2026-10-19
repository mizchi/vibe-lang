# Release the function preparer's Store before workers

The opt-in function executor used to start its worker wave from a synchronous
native callback. The preparing Wasmtime Store stayed alive, retaining syntax,
checker/lowering state, string tables and temporary buffers through worker
execution and replay. Clearing bump-allocated arrays did not reclaim that heap.

The returning-phase implementation finishes preparation, copies an original
owned receipt, completes the normal runner cleanup and drops the preparing
Store before starting workers. A fresh Store from the same compiled Module
finishes the artifact using owned section/replay metadata. No AST, active
Caller or Store-bound handle crosses that boundary. This is still the isolated
**process** backend; native CPU threads and actual bootstrap selection remain
separate roadmap work.

The [machine-readable analysis](../../../bench/perf/analysis/function-parent-lifetime-2026-10-19.json)
and [retained raw evidence](../../../bench/perf/experiments/function-parent-lifetime-2026-10-19/README.md)
bind 3,174 exact records, including final source/producer identities, all timed
samples, complete profile counters and explicitly separate historical trials.

## Final formatted-source filesystem results

These numbers belong to the final formatted candidate and its rebuilt producer
`7a078f788566e7847e310700f4648256e375509b6c4d6d67d0e102372c082325`.
The initial pre-format trial remains archived independently; its samples are
not pooled with the final source. All eight formatting changes, source hashes,
producer fixed points and matching image receipts are preserved.

The submission later removes one extra blank line at EOF from
`file_body_preparation.vibe`; every preceding byte is identical.
[The source delta](../../../bench/perf/experiments/function-parent-lifetime-2026-10-19/submission-source-delta.json)
records both hashes. The retained producer and timing identities continue to
describe the original measured snapshot. Normal release/commit/CI checks apply
separately to the final submission; no retiming or new-source speedup is claimed.
The same delta record identifies the later source-gate reader repair: explicit
same-directory `linked_*` imports are followed across the new preparation-module
stem; other compatibility facades retain their original ownership boundary.
Detecting tests reject unreachable/outside decoys and missing modules; the
previous reader fails them. This changes gate visibility, not compiled compiler
or native runtime behavior.
The gate changes also make the native-service mutation target its actual
`linker.func_wrap` registration while retaining unrelated denial references,
and include lane shell/Python sources in the compiler-gate cache inputs.
Failed required-gate attempts are retained. The second attempt verifies
the submitted compiler's stage2 == stage3 (`b199e63033bb7d90…`) before stopping
at the mutation-test issue; this is a compiler fixpoint proof, not full signoff.
The third attempt completes the language regression lanes and collects every
gate self-test; only the partial doc-command fixture fails under the overly
broad source view. A scoped reader repair, six detecting tests and the exact
doc fixture/negative control pass separately before the next full rerun.
The fourth attempt passes every compiler-gate lane and stops later at document
classification because this report was missing from the audience index. The
report is now registered as a dated maintainer report in `docs/README.md`;
compiler/runtime sources and the retained measurements remain unchanged.
The fifth attempt passes document classification and stops at eight missing
qualified method companions. These are now additive forwarding methods in the
worker/phase packages; every pre-existing implementation is byte-identical.
[Separate validation](../../../bench/perf/experiments/function-parent-lifetime-2026-10-19/method-companion-validation/manifest.json)
executes the qualified entries in 18 host/mode combinations and passes the
rebuilt public jobs 1/2/4, receipt, mutation and failure suite. Compiler and
native binaries are unchanged from attempt five. New-file documentation floors
record the actual existing counts without weakening older rows. The reported timings
remain bound to the earlier measured sources/images; these additions
are not a new performance experiment.
The sixth full attempt runs 105 tasks and stops at compile-only lane absence:
reading finish flags from the preparation record loses constant-Bool
provenance and retains two shadow helpers. Ordinary callers now pass those
same flags directly to a checked finisher; deferred callers retain the record
adapter. A mismatch refuses before consuming the canonical plan. The actual
pre-fix artifact is rejected, while the rebuilt current artifact passes lane
absence, refusal and acceptance. Six preparation host/mode executions and the
current public jobs 1/2/4/failure suite pass. The
[separate repair evidence](../../../bench/perf/experiments/function-parent-lifetime-2026-10-19/direct-finish-flags-validation/manifest.json)
qualifies this later source change; the retained performance results describe
the original measured implementation, and are not retimed final-source claims.

The seventh attempt reused the ignored failed compile-only artifact from the
sixth run. Rebuilding it with the normal builder and current stage2 passes
both the real gate and its mutation/control self-tests without source or
gate-policy changes. The eighth normal full `pkf run release-check` then
completes successfully on
frozen tree `b34e56881c9a3b2ec64e073ceb5e8e28baae360d` with the source/index unchanged
throughout (126 tasks; 111 ran, 15 cached,
0 skipped; 3613.8 seconds). The current compiler proves
stage2 == stage3 (`4004489dc623e413bd16bcc1020d07db3bd7081698c1003136bdf3d24267134c`).
[The complete gate evidence](../../../bench/perf/experiments/function-parent-lifetime-2026-10-19/release-attempts/v8/manifest.json)
retains the raw log, runner, source hashes and generation identity. Subsequent
submission edits only retain this evidence and update documentation/status.

The completed final matrix has **144 unprofiled builds**: three alternating cold/warm
rounds for two corpora, ordinary before/after with both A/A controls, same-image
serial controls and process jobs 1/2/4. All artifacts agree. All 24 paired A/A
controls have identical guest frontier/allocation/committed-memory observations.
Source, input, compiler, native runner, helper-image and driver identities are
checked before and after the matrix. The corpus is fixed at main
`8bed6e9e61bb178af06cdb7fbae62d9bc19c6c7e`; emitted target RC1, compiler/worker
engines bump and coordinator RC are unchanged between lanes.

Four-process whole-build medians (N=3 in each cell):

| Corpus | Temperature | Wall before → after (s) | Simultaneous process-tree RSS before → after (MiB) | RSS change |
| --- | --- | ---: | ---: | ---: |
| Compiler | Cold | 7.117 → 7.140 | 1,525.0 → 1,231.1 | -19.27% |
| Compiler | Warm | 4.624 → 4.755 | 1,041.8 → 750.2 | -27.99% |
| Split CLI | Cold | 18.896 → 19.090 | 3,698.1 → 2,838.2 | -23.25% |
| Split CLI | Warm | 13.490 → 13.965 | 2,737.6 → 1,875.4 | -31.50% |

Whole-wall median increases are +0.33%, +2.83%, +1.03% and +3.52%, respectively.
All remain below the prespecified 5% noise/decision threshold. **No whole-build
speedup is established.** Raw observations, min/max, per-mode controls and gate
results are retained; the result must not be described as a faster selfbuild.

The explicit same-image **serial control also becomes slower**. This is a
material limitation even though the ordinary compiler route stays within the
5% whole-wall noise threshold on both corpora:

| Serial control | Temperature | Wall before → after (s) | Change |
| --- | --- | ---: | ---: |
| Compiler | Cold | 6.140 → 6.715 | +9.37% |
| Compiler | Warm | 4.137 → 4.363 | +5.46% |
| Split CLI | Cold | 16.425 → 17.799 | +8.36% |
| Split CLI | Warm | 11.874 → 12.554 | +5.72% |

The returning serial invocation now participates in native input-snapshot
observation/freshness verification. The historical callback-image serial path
had no CPU service configuration and did not install that observation scope.
That changes the control's host work; it must not be hidden or attributed to a
specific pass without a separate diagnostic. Image/code changes also remain
part of the measured route. Ordinary-route wall deltas are −1.98%/+1.78% for
compiler cold/warm and −0.14%/+0.34% for CLI cold/warm. The actual bootstrap
controls below are still needed.

RSS is sampled every 20 ms as a simultaneous process-tree sum. Shared mappings
can be counted more than once. It is distinct from allocation volume, guest
frontier and reserved linear-memory bytes. No independent per-process maxima
are added together.

## The retained heap is released

The raw four-process timelines identify workers by their current command at
each sample, including exec transitions. The following are medians of the
simultaneous phase peaks from the same three runs; sampled intervals are bounds,
not exact native phase timestamps.

| Corpus / temperature | Before workers, before → after | Workers alive, before → after | After workers, before → after |
| --- | ---: | ---: | ---: |
| Compiler / cold | 1,222.5 → 1,231.1 MiB | 1,525.0 → 496.5 MiB | 1,355.2 → 307.6 MiB |
| Compiler / warm | 741.5 → 750.2 MiB | 1,041.8 → 496.4 MiB | 874.7 → 306.6 MiB |
| Split CLI / cold | 2,838.0 → 2,838.2 MiB | 3,698.1 → 1,104.4 MiB | 3,299.2 → 774.7 MiB |
| Split CLI / warm | 1,878.0 → 1,875.4 MiB | 2,737.6 → 1,099.6 MiB | 2,339.2 → 777.1 MiB |

The candidate peak now occurs before workers start. The large reduction during
and after the worker wave is physical RSS evidence in addition to the native
Store-lifetime guard; it is not inferred from `Array::truncate` or a lower
allocation counter. The remaining preparation peak is the next memory floor.

## Actual bootstrap ordinary-route controls

All **24 actual target-RC0 serial pipeline controls** are complete: compiler
through stage3 and portable CLI through stage2, three alternating cold/warm
rounds per source lane. These use equal-length fresh main `8bed6e9e6` and exact
formatted-candidate checkouts, matching source-bound native runners and the
pinned seed. Cold removes the isolated merge-tool artifact/stamp and starts a
fresh parsed-source cache; warm reuses those inputs while rebuilding every stage.
OS pages are warm, and the shared native-cache state is explicit. Source
generation, seed validation/reuse and all selected stages are included; setup
and compiler packaging are outside these ordinary regression controls.

Whole-pipeline monotonic walltime, median [min, max] seconds (N=3 per cell):

| Pipeline | Temperature | Before | After | Median change |
| --- | --- | ---: | ---: | ---: |
| Compiler through stage3 | Cold | 200.669 [200.061, 200.984] | 200.004 [199.667, 200.244] | -0.33% |
| Compiler through stage3 | Warm | 151.983 [151.523, 152.447] | 152.476 [152.184, 152.795] | +0.32% |
| Portable CLI through stage2 | Cold | 155.586 [154.727, 155.666] | 156.221 [154.907, 156.453] | +0.41% |
| Portable CLI through stage2 | Warm | 107.335 [106.705, 107.622] | 107.044 [106.921, 107.143] | -0.27% |

Simultaneous process-tree peak RSS medians:

| Pipeline | Temperature | Before → after (MiB) |
| --- | --- | ---: |
| Compiler through stage3 | Cold | 3,502.7 → 3,495.4 |
| Compiler through stage3 | Warm | 3,502.0 → 3,499.5 |
| Portable CLI through stage2 | Cold | 3,505.4 → 3,495.9 |
| Portable CLI through stage2 | Warm | 3,490.8 → 3,495.8 |

Each lane retains identical bootstrap artifacts across temperatures and rounds.
All 12 compiler manifests prove stage2 == stage3 and match the independently
verified source-bound producers. The final audit also checks all 24 raw process
records against the recorded metrics, all 24 monotonic span records, source
commit/dirty-lane identity and setup-log hashes. Common-input binary equivalence
is established by the separate filesystem matrix and paired module oracles.

All eight ordinary-route cells meet the recorded compiler 208/166-second and
3,634-MiB budgets, portable CLI 170/129-second and 3,641-MiB budgets, and the
absolute 4,096-MiB ceiling. Whole-wall changes remain inside the 5% decision
threshold. This establishes no material ordinary-route regression or measured
speedup. These controls use the serial bootstrap emitter; native-thread/stage
selection and the worker promotion criteria remain #3484/#3485/#3486.

Actual-pipeline `processes.json` preserves the online simultaneous aggregate
peak and process observations. It does not contain a complete per-tick tree
timeline. The fixed-filesystem four-process experiment separately preserves
its full sampled timelines; neither result sums independent child maxima.

## Remaining CPU and preparation floor

The final formatted-source diagnostics reproduce 16 parent and 64 worker runs
with exact artifacts/products. Their **66 raw guest CPU profiles** are
authenticated against the diagnostic receipts before aggregation. Complete
per-profile tables and ten pooled groups retain every function row, avoiding
top-list truncation before pooling. These are warm filesystem/target-RC1
diagnostics; guest epoch sample counts exclude host work. Preparation, callback,
finisher and worker groups have different denominators, and inclusive ancestors
overlap. Their percentages cannot be added or read as whole-wall savings.

| Candidate diagnostic | Compiler | Split CLI |
| --- | ---: | ---: |
| Preparation: effect-lowering prelude, inclusive | 42.40% | 46.33% |
| Preparation: `hash_string`, self | 8.37% | 12.84% |
| Worker: `LinkedFunctionPlan::emit`, inclusive | 75.72% | 56.81% |
| Worker: shared-context decode, inclusive | 12.73% | 31.77% |
| Finisher: assembly decode, inclusive | 11.60% | 30.26% |

The unprofiled candidate four-process warm traces separately report preparation,
worker-wave and finalization medians of 3.499/0.582/0.313 seconds for compiler
and 10.913/1.372/1.143 seconds for CLI. These independent phase medians are not
added to manufacture a whole-build time; public receipt checks and native
preflight work also contribute to the measured complete invocation. Releasing
the preparation Store removes overlap during workers, but leaves the large
serial preparation time and peak intact. More worker threads alone cannot
remove that floor. Context/assembly decoding and narrower helper import/export
roots remain measured follow-up candidates, with no extra optimization bundled
into this lifetime change.

## Ownership, authentication and bounded admission

Preparation and the ordinary filesystem path share their real load/check,
typed-lowering, heap-elaboration and canonical planning prefix. Assembly carries
a 208-field owned section plan plus owned validation/layout/replay state.
The common builtin/layout factories and one canonical function plan remain
shared with ordinary compilation. Fresh replay cells preserve canonical
lambda, slot, source and line-map ordering; validation precedes publication
into output/cache tables.

The private image uses `bump-core-returning-phases-3`: an init-only `_start`,
original phase receipt format 1, assembly format 1, context 7 and job 2. Only
the original Bytes returned by preparation authorize finishing. Rewriting an
assembly file and then hashing that same file cannot replace the original
binding. The guest authenticates actual input buffers; native source and
artifact observations are rechecked before publication.

The finisher can read only admitted artifacts. Source reads, import resolution,
directory probing, output writes and recursive compiler-service entry are
refused. A suppressed refusal still fails the invocation. The same immutable
Engine/Module can be retained while each invocation owns a new Store/Instance.
The regular sampler, profiler, diagnostics and memory cleanup finish before
the invocation returns; no active Caller is reset or dropped.

Context, assembly and aggregate outstanding job inputs have separate 64 MiB
limits. Finisher admission caps aggregate product wire bytes at 256 MiB, using
fixed 64 KiB streaming scratch before constructing its Store. Actual artifact
reads charge that aggregate budget too, including repeated reads; the guest
also checks cumulative product bytes. Product/receipt identities are verified
again before publication. This bounds admitted wire volume, not decoded heaps,
worker production or whole-process RSS. Producer admission/backpressure is
owned by #3484.

## Verification completed so far

- Current-main and candidate compiler producers each prove stage2 == stage3.
- The measured formatted-source producer passes 24 foundation host/mode executions: four test
  modules, bump/RC/shadow, Wasmtime and Node.
- Pure main and candidate produce 49 byte-identical paired modules. Compiled
  replanning and missing-location mutants are rejected on both hosts.
- The native suite passes 64 unit and four integration tests, including owned
  returns, actual Store drop/fresh instantiation, receipt bounds, original trap
  classification, read admission and aggregate-product pressure.
- Matching current-source public CLI images pass all eight fixture families
  at jobs 1/2/4, runtime answers, changed jobs/products/context, stale receipts,
  unsupported settings, worker traps and old-output protection. Compiled
  source-recompiling finisher and original-receipt mutants exercise the real
  native path. Sampler/profiler cleanup and parent-only filesystem counters
  are checked with actual instrumented invocations.
- Measurement selection explicitly handles archived callback ABI2 and current
  returning ABI3. Twenty-three measurement/refusal tests and actual ABI2/ABI3
  serial builds pass. An actual init-only `_start` control produces no artifact;
  it cannot serve as the serial build control. Preparation/finisher diagnostic
  memory observations remain separate.
- The post-measurement reproduction helper reconstructs all 2,522 recorded
  candidate source files and 2,456 baseline files in fresh checkouts. Its 24
  tiny-input ABI2/ABI3 serial/process builds retain artifact and A/A equivalence.
  Source-mutation, unrecorded-module, existing-workspace and inappropriate
  state/image-reuse controls refuse before benchmarking. This checks the helper;
  the full fresh performance/image-building recipe is documented separately and
  is not claimed as an additional performance experiment.

The final formatted producer and all its library/runtime inputs are bound to
the final measurement authority. Measurement-helper edits were independently
checked with 23 refusal/unit tests and actual ABI2/ABI3 serial invocations;
those helpers are unchanged in the final producer verification and matrix.

## Remaining rollout gates

The process route still fails the 5% whole-wall win and forced-one-worker
walltime gates. Compiler warm process RSS also remains above 110% of ordinary
RSS; CLI and the other measured memory cells pass that relative check. All
four-process cases stay below the absolute 4,096 MiB limit. These are relative
**filesystem corpus** checks, not the actual bootstrap ceilings.

The initial source-bound diagnostics completed 16 parent and 64 worker replays,
including 66 CPU profiles, with exact artifacts/products. A separate 36-run
serial observation experiment isolates the native scope using the same old
binary: scope installation adds about 5.1–8.3% whole-wall cost, while
observation-matched old/new serial medians differ by −1.1% to +1.5%. These
results explain why the unqualified historical/new serial comparison cannot
attribute its change to compiler work. The final-source diagnostics above are
retained separately from that initial pre-format experiment.

The actual target-RC0 ordinary-route controls and complete profile aggregation
are finished, and the normal full release gate passes on the frozen source
recorded above. Normal repository hooks remain enforced at commit; hosted
review/CI results are reported on the implementation PR. Default enablement is
unproven. #3484 owns native CPU threads, #3485 actual stage/installed integration
and #3486 the final whole-build promotion decision.

The helper image starts with about 46 MiB of static guest address space versus
about 0.42 MiB for the ordinary compiler. Both historical and returning helper
images retain broad compiler exports. Narrower import/export roots are a
measurement candidate, not an established RSS saving: static addresses and
retained image bytes do not prove resident pages. The remaining CPU/preparation
floor must be selected from the separate profiles rather than inferred from
inclusive samples or worker-only timing.
