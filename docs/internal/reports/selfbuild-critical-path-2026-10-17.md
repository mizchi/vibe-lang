# Selfbuild critical path and parallelism baseline (2026-10-17)

The three-round whole-bootstrap baseline, 72-compile native matrix and separate
CPU/memory diagnostics are complete. Current workers fail the proposed
promotion budgets below. Keep them opt-in; first investigate receipt-bound
reuse of the seed validation artifact as stage1, then checker lookup costs.

The [machine-readable record](../../../bench/perf/analysis/selfbuild-critical-path-2026-10-17.json)
retains all 102 timed samples (12 bootstrap, 72 matrix, 18 small-input startup),
36 separate CPU-profile summaries, memory controls, input/output hashes and
the manifest of retained raw files. No optimization is implemented here.

The reference compiler bootstrap takes 245.49 s cold and 196.32 s warm.
Its source preparation includes a complete seed validation compile before the
seed compiles stage1. Current function workers use separate native processes;
the reusable native-thread executor is tracked by #3484.

## Workloads and authority

The source archive is commit `c9df5fd62477bd4c4b42a0b662df2d8f7e2481c7`,
tree `855fcd6c0a6be843bb9beebd059c4660418afb51`. The archive hash, input
receipts, seed pin, per-run generation manifests and output hashes are retained.
Only the host trace helper is patched to support opt-in monotonic spans;
compiler source, seed and build decisions are the archived versions.
Generation driver labels can observe the enclosing developer checkout, so the
frozen archive and verified contents establish source authority.

| Workload | Actual command/entry | Published product | Worker selection today |
| --- | --- | --- | --- |
| Compiler bootstrap | `generations.sh build --stage3`; low-level `cli_main` | stage1, stage2, stage3 | Ordinary serial pipeline |
| Portable CLI | `build_cli_wasm.sh`, artifact cache disabled; target entry `main` | stage2 portable CLI | Ordinary serial pipeline |
| Compiler corpus | FS compile of `compiler/tests/codegen_lexer_test.vibe` | compiler-sized test module | Ordinary, serial-driver control, native 1/2/4 processes |
| Split CLI corpus | FS compile of `cli/entry.vibe` | split CLI module, entry `cli_main` | Ordinary, serial-driver control, native 1/2/4 processes |

The bootstrap invokes its low-level compiler directly and installs no function
executor. Its emitted target uses bump allocation (`VIBE_RC=0`), while the
function frontend, parent and native service currently require target RC1.
Compiler-engine allocation is independent: the ordinary compiler, parent and
worker engines use bump; the async coordinator uses RC. #3485 now explicitly
requires support for the bootstrap's actual target before integration.

## Whole-bootstrap baseline

Each temperature has three complete runs. Cold starts with an absent merge-tool
image/stamp and a fresh guest cache. Warm retains those caches and regenerates
every stage output. Subject order alternates between rounds. OS source-page
cache is warm; each Node process/JIT is fresh. Checked-module, body and final
artifact caches are off. The portable CLI artifact cache is explicitly disabled.
Packaging, installation and native-runner compilation are outside these totals.

| Workload | Cache | Wall median [min–max], s | Aggregate peak RSS median [min–max], MiB |
| --- | --- | ---: | ---: |
| compiler | cold | 245.491 [244.649–245.614] | 3450.2 [3449.6–3451.4] |
| compiler | warm | 196.320 [195.410–196.518] | 3452.3 [3446.8–3460.6] |
| portable-cli | cold | 200.301 [199.898–200.414] | 3459.2 [3440.5–3462.1] |
| portable-cli | warm | 151.810 [150.730–152.014] | 3452.8 [3450.8–3467.2] |

RSS sums simultaneously resident processes every 20 ms. Shared mappings can be
counted in several processes. It is distinct from guest reserved pages, bump
frontier and allocation volume; those counters remain in the raw logs.
All six outputs per workload are byte-identical. Every compiler run verifies
stage2 == stage3; the portable CLI's production pipeline stops at stage2 and
its output hash is checked against that explicit generation producer.

### Host phase attribution

These are medians of matching per-run spans. Validation is a **subset** of
preparation. Phase medians are descriptive; adding independent medians does not
reconstruct one observed end-to-end sample.

| Workload/cache | Source preparation, s | Validation subset, s | Seed→stage1, s | Stage1→stage2, s | Stage2→stage3, s |
| --- | ---: | ---: | ---: | ---: | ---: |
| compiler/cold | 109.848 | 44.256 | 44.169 | 44.527 | 44.785 |
| compiler/warm | 60.459 | 43.833 | 44.361 | 44.894 | 44.036 |
| portable-cli/cold | 109.421 | 44.285 | 44.511 | 44.123 | — |
| portable-cli/warm | 61.026 | 44.608 | 44.104 | 44.910 | — |

A separate copied-input seed probe reproduces the exact measured stage1 bytes
for each entry: `cli_main` produces compiler SHA-256 `6a9cd4d5…4712ad` and
`main` produces portable CLI `5dc346ff…d8559`. The record contains full hashes.
Receipt-bound reuse of that successful validation artifact is a candidate for
#3482, with an upper bound equal to the validation span. The current validator
always requests `cli_main`, so portable CLI reuse needs entry-consistent
validation. This probe establishes byte identity, not a safe reuse protocol.
Freshness, options, the #979 sticky-failure guard, old-output protection and
atomic publication remain required; no validation is removed here.

## Native function-worker matrix

There are three cold/warm pairs per configuration, in forward/reverse/forward
order. Native machine code is primed with a different input; parsed-source
caches are isolated per pair. A/A paths have equal lengths and identical
compiler/runner bytes. Their guest frontier, allocation volume and reserved
pages agree exactly. Every one of the 36 outputs per corpus is byte-identical.

`o0` is ordinary compilation; `s0` is the same parent driver with serial body
emission. `p1/p2/p4` include the public native frontend, image/ABI receipts,
source freshness checks, worker execution, replay and final publication.
These are emitted RC1 corpora, separately from the bump-target bootstrap above.

| Corpus | Route | Cold wall median [min–max], s | Warm wall median [min–max], s | Warm peak RSS median, MiB |
| --- | --- | ---: | ---: | ---: |
| compiler | o0 | 6.142 [6.042–6.327] | 4.095 [3.998–4.123] | 639.2 |
| compiler | s0 | 6.326 [6.275–6.471] | 4.284 [4.178–4.566] | 689.5 |
| compiler | p1 | 7.875 [7.801–8.008] | 5.432 [5.384–5.737] | 949.4 |
| compiler | p2 | 7.474 [7.436–7.588] | 5.070 [5.019–5.139] | 1004.7 |
| compiler | p4 | 7.287 [7.266–7.364] | 4.756 [4.715–4.842] | 1120.8 |
| split-cli | o0 | 16.456 [16.428–16.513] | 11.980 [11.869–12.111] | 2013.7 |
| split-cli | s0 | 16.667 [16.563–16.775] | 12.125 [12.002–12.267] | 2067.2 |
| split-cli | p1 | 20.772 [20.735–20.824] | 15.369 [15.162–15.373] | 2300.8 |
| split-cli | p2 | 19.762 [19.731–19.952] | 14.488 [14.177–14.577] | 2416.7 |
| split-cli | p4 | 19.333 [19.279–19.362] | 13.986 [13.947–14.195] | 2756.6 |

Four workers lose against the ordinary route on both corpora. Warm deltas:

- compiler: wall +16.13%; simultaneous process-tree RSS +75.34%.
- split-cli: wall +16.75%; simultaneous process-tree RSS +36.89%.

The service's worker interval includes transport, startup, decode and validation.
Its name does not identify pure useful emission. Separate CPU profiles and
captured-job replays supply that attribution; inclusive ancestors overlap.

| Warm p4 corpus | Preparation, ms | Worker interval, ms | Finalization, ms | Queued job bytes |
| --- | ---: | ---: | ---: | ---: |
| compiler | 3143.8 | 918.1 | 217.4 | 7,864,332 |
| split-cli | 10078.1 | 2433.2 | 927.1 | 13,146,682 |

These are independent medians, not additive components of an observed sample.
Preparation includes canonical function planning; worker time includes context
encoding and product validation; finalization includes canonical replay,
assembly and private output writing. External elapsed time also pays frontend
receipt checks and final publication. No interval is labelled pure emission.

## CPU attribution and memory ownership

The named compiler has stage2 == stage3 and differs from the measured compiler
only in custom name sections. Ordinary profiles use the repository runner
wrapper with its Wasm flags. Each workload has one warmup followed by three
profiles; native parent profiles and four captured worker slots also have
three profiles each. Every output/product matches its unprofiled reference.
The FS CLI profile output also matches the native matrix output exactly.

The ordinary columns below use V8 sample weights, including host work and GC.
The native parent columns count guest epoch samples and exclude host work;
their percentages have different denominators. Values are medians. Inclusive
rows overlap with children, so they must never be summed.

| Ordinary profile | Actual flat selfcompile | FS split CLI |
| --- | ---: | ---: |
| `env_lookup_binding`, self | 17.70% | — |
| `afe_lookup_local`, self | 6.27% | — |
| `lookup_labeled_check_fn`, self | 5.32% | — |
| V8 garbage collector, self | 23.72% | 0.20% |
| Effect lowering, inclusive | 12.42% | 38.72% |
| Evidence dictionary pass, inclusive | 7.20% | 22.90% |
| `edp_rq_fold`, inclusive | 1.26% | 4.46% |
| `LinkedFunctionPlan::emit`, inclusive | 1.06% | 12.09% |

The flat workload spends about 52% of inclusive samples in source-offset/checker
observation, including the lookup costs above. The FS workload has a different
critical path. A fast function emitter on that FS corpus alone does not prove a
faster production bootstrap. GC is a measured category, not proof that linear
memory growth caused it; change growth policy only after a separate controlled
experiment.

Native parent profiles locate effect lowering at 38.30% compiler / 43.13% CLI
of guest samples; evidence dictionaries at 13.66% / 25.51%, and canonical
function planning at 3.89% / 2.06%. CLI context encoding is 2.29% and canonical
replay 1.97% of parent guest samples. These describe guest CPU attribution,
not isolated encode/decode/host elapsed times.

Captured worker jobs replay exactly. By slot, median inclusive emission is
60.57–77.69% compiler and 52.91–63.40% CLI; context decode alone is
10.31–23.16% compiler and 24.66–34.07% CLI. CLI literal hashing/fingerprinting
also remains inside emission, so emission is not wholly useful instruction
selection. Compiler worker samples are sparse (175–388 per profile); use the
three repeats and these broad ranges, not sub-percent distinctions.

| Snapshot / wave | Compiler bytes | FS CLI bytes |
| --- | ---: | ---: |
| Shared context, serialized once | 5,704,530 | 50,067,552 |
| String-pool prefix, including lengths | 95,654 | 38,983,105 |
| Four queued job inputs, total | 7,864,332 | 13,146,682 |
| Four completed products, total | 6,485,510 | 8,704,738 |

The CLI pool is about 78% of its context. Its two largest literals total
24,897,700 bytes; one is byte-identical to the generated flat compiler source.
The record stores lengths and hashes, not literal contents. Preserve canonical
string indices when investigating replication: truncating the pool without
proving emitter reachability would be incorrect.

The parent retains the lowered program/plan. The host copies encoded context
to a file and checks its hash before consumption; each worker reads and decodes
it into a private guest heap. Input buffers are released logically after host
copy, but bump allocation does not reclaim the frontier. Results are validated
and consumed in canonical order before files are removed. The captured wave
holds all four job inputs; the product total above is the wave's file volume,
not a sampled peak of simultaneously live host buffers. The snapshot/job sizes,
source-level lifetime and guest frontiers bound this diagnosis; no per-buffer
allocation tracer or exact peak of completed products was collected.

| Warm native guest control | Allocated volume, MiB | Reserved pages | Frontier, MiB |
| --- | ---: | ---: | ---: |
| Ordinary compiler | 634.3 | 12,442 | 634.7 |
| Worker parent compiler | 757.2 | 18,724 | 802.8 |
| Each compiler worker, range | 73.0–93.5 | 1,639 | 73.4–93.8 |
| Ordinary FS CLI | 2440.9 | 41,991 | 2441.3 |
| Worker parent FS CLI | 2581.1 | 42,129 | 2626.8 |
| Each CLI worker, range | 204.9–251.7 | 3,901–5,851 | 205.3–252.1 |

Parent counters come from separate successful warm diagnostic builds; workers
from exact captured-job replays with fresh Stores. These controls explain
ownership and allocation, but do not reproduce simultaneous RSS or allow
summing independent peaks. The timed matrix supplies simultaneous RSS.
Reserved pages are 64 KiB each and differ from frontier, resident memory and
allocated volume. On these bump engines volume equals frontier minus heap base.

### Small-input native startup control

Both sides start with an empty guest cache; only native machine-code caching
changes. Three alternating rounds compile the same subtraction program, with
identical output across all routes. These are unprofiled whole-driver samples.

| Route | Native cache cold median [min–max], s | Native cache warm median [min–max], s |
| --- | ---: | ---: |
| ordinary | 0.515 [0.500–0.516] | 0.047 [0.047–0.047] |
| serial driver | 1.045 [1.042–1.051] | 0.214 [0.212–0.218] |
| one-process worker | 1.777 [1.720–1.844] | 0.520 [0.497–0.544] |

These differences measure net native-cache/JIT benefit, not pure engine
instantiation. Even with primed machine code, the small-input worker route
costs about 0.47 s extra over ordinary execution. Resource admission must
handle small inputs before any default rollout.

## Ranked next bounded changes

1. **Reuse a validated seed product as stage1 (#3482).** The copied-source
   probes establish exact byte identity at both entries. The impossible
   zero-overhead ceiling is one 43.8–44.6 s validation compile: about 18–22%
   of compiler bootstrap wall and 22–29% of portable CLI wall, by temperature.
   Implement receipt-bound freshness and atomic publication; retain validation
   and refuse a changed source/seed/flags/entry/runner. This is the first
   bounded experiment, not an implemented saving.
2. **Index measured flat checker lookups (#3482).** `env_lookup_binding` alone
   is 17.70% self samples. Under a proportional sample-to-wall cost model,
   removing all of that work would bound savings around 16 s across the two
   compiler-bootstrap hops run by the current compiler (stage1→2, stage2→3),
   or 8 s across the portable CLI's stage1→2 hop. The seed runs validation
   and stage0→1; it was not CPU-profiled, so applying the same percentage to
   those calls would be an unverified assumption. Replacement indexing costs
   remain, and profiles are not walltime wins. Preserve scope,
   shadowing, generalized types and source diagnostics. Investigate GC in a
   separate controlled experiment before attributing its 23.72%.
3. **Reduce snapshot decode/retention (#3483).** The 50 MB CLI context and
   25–34% context-decode share per worker justify work before adding threads.
   Even deleting the *entire* current p4 worker interval could save at most
   0.918 s compiler / 2.433 s FS CLI warm; that includes emission and is an
   intentionally loose ceiling for transport alone. Actual bootstrap gains
   remain zero until its route is integrated.
4. **Add bounded CPU threads (#3484), integrate (#3485), then gate (#3486).**
   Reuse compiled engine/module state while isolating Stores and heaps.
   Threading cannot remove preparation (3.144 s compiler / 10.078 s CLI
   warm), and actual flat body emission is only about 1.06% inclusive samples.
   That sampled guest CPU share does not justify expecting a 15% whole-build
   win from body parallelism. V8 GC/host samples are outside that ancestry;
   measure any indirect benefit separately. A larger safe parallel boundary
   may be needed; reuse the existing build-unit work (#2507/#2826/#2508) if
   measurements select it. Bootstrap integration must support its actual bump
   target and prove stage2 == stage3 before default promotion.

## Proposed promotion budgets

These decisions are based on the completed baseline, before implementing the
next optimization. Seconds refer to the reference Ryzen 7 7700 / 16-logical-CPU
WSL2 ext4 machine with Node 24.7.0. Promotion reruns the actual proposed merge
tree and records any workload changes explicitly.

| Whole pipeline | Cold wall ceiling | Warm wall ceiling | Reference peak RSS ceiling |
| --- | ---: | ---: | ---: |
| Compiler bootstrap through stage3 | 208 s | 166 s | 3,634 MiB |
| Portable CLI through stage2 | 170 s | 129 s | 3,641 MiB |

The wall targets require at least approximately 15% improvement from this
baseline. The RSS ceilings round up 105% of the worst observed complete-build
sample. Also require an absolute 4,096 MiB simultaneous RSS ceiling for the
supported actual selfbuild lane. Existing heap KPIs remain authoritative.

To attribute a win to parallel execution, the selected worker route must also
beat the **contemporaneous** ordinary pipeline and same-driver serial control
by at least 5% end-to-end, at both temperatures, on compiler and CLI. Serial
improvements elsewhere cannot by themselves establish a worker speedup. Its
aggregate RSS must stay within 110% of the matching ordinary control and all
whole-build ceilings above.

Forced one-worker overhead must stay within 5% wall and 5% RSS of its matching
serial-driver control. Small-input default builds must stay within the larger
of 5% or 50 ms additional walltime over ordinary execution; automatic admission
may select the ordinary route. Explicit forced-worker requests must retain
their documented execution/refusal behavior.

Use at least three alternating pairs per configuration and retain min/max as
well as medians. Treat changes below 5% as inconclusive; collect more samples
when spread or inconsistent paired directions prevents a decision. Require
output identity, matching receipts, stage2 == stage3, specified failure behavior
and required checks before default selection. A negative result keeps the
route opt-in and records the measured blocker.

## Clock integrity

A pilot exposed realtime steps under WSL: a 5.004 s monotonic wait advanced
realtime by only 2.515 s. In the first complete bootstrap, realtime reported
227.824 s against 245.614 s monotonic. Realtime pilot spans are excluded from
phase attribution. `VIBE_TRACE_MONOTONIC=1` supplies a same-host monotonic clock
to all spans; their clock origin is labelled and mixed-clock trees are refused.
The external runner lifetime and root spans agree within approximately 0.13 s.
Clock regression probes poison `date` with a backwards clock and demonstrate
red/green behavior. Actual timed rows use the monotonic path.

## Reproduction and evidence integrity

Run the sequential workflow in
[Isolated CPU function generation](../compiler/function-cpu-workers.md#reproduce-the-selfbuild-baseline).
The native matrix keeps equal-length paths, primed native JIT, isolated guest
caches, A/A controls and a same-driver serial control. Its complete public
frontend includes receipts, source verification and publication. CPU profiles
and exact captured-job replays run separately after walltime measurement.
Their instrumented timings do not enter promotion walltime.

The committed record includes full source/compiler/runner/image hashes and
every timed sample. Large profiles, per-process observations, complete logs,
source archive and generation manifests are retained locally under
`_build/selfbuild-critical-path-20261017`; their path, length and SHA-256 form
the record's raw manifest. This is local evidence retention, not a hosted raw
profile archive. A clean reproduction uses a fresh workspace and the recorded
source commit; absolute developer paths do not establish source authority.

Bootstrap ran an earlier driver snapshot. Every function that measured or
verified those samples is AST-identical to the current driver; the proof and
snapshot hashes are retained. Matrix ran the current baseline driver.
Ordinary CPU profiles completed before a missing output-directory setting
was corrected in the parent diagnostic launcher. That correction changes no
ordinary-profile invocation; the failed parent attempt is retained separately.
The resumed diagnostic script snapshot is retained. After diagnostics
completed, the validation probe was strengthened to refuse a wrong-entry
product, and both actual products already satisfy the stronger rule.
A regression probe demonstrates
that the earlier probe accepted the wrong product and the current one refuses
it. No timed measurement is relabelled as having run another harness.

Measurement-integrity tests cover stale/mismatched producers, changed source
and seed, actual fixed-point bytes, exact captures, recursive sample counting,
bounded context-prefix decoding and clock behavior. They run in CI and
`release-check`; they do not impose host-specific timing budgets in CI.
