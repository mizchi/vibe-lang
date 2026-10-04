# TaskGroup checked-product replay, 2026-10-04

The opt-in TaskGroup frontend can reuse successful checker products for an
identical input snapshot. Warm compiler and CLI builds avoid all worker checks;
cold builds still run the real CPU workers. This remains an experimental
helper, enabled with `VIBE_TASKGROUP_JOB_CACHE=1`. It does not enable public
`vibe build --jobs`, implement codegen parallelism, or complete the checker
responsibility split. The ordinary serial build remains faster.

## Reuse contract

The lookup digest includes the exact UTF-8 module-job manifest and source,
ordered dependency occurrence names/fingerprints, and each supplied dependency
Env's bytes. It includes compiler, checker, coordinator and native-runner image
digests, the project root and the environment. Known observation-only variables
are excluded; unknown environment settings conservatively cause misses. Only
digests of environment values are persisted in replay metadata.

The fingerprint remains the real checker's output. A replay restores the
successful checked Env, fingerprint and complete lowering transport. The same
live-job parser checks the record; the compiler validates canonical publication
before new records are stored. Version/input/context/output-digest mismatches
are misses, so corruption causes real checks. Diagnostic products are never
stored. Image changes during a build reject publication. Cache records use
atomic file replacement and live under `taskgroup-jobs-v1` inside the selected
build cache.

The first version prepared every job directory, then reread the files to hash
its input. The current version shares an in-memory wire-input builder with the
original host checker. It hashes the exact bytes that the writer receives,
including UTF-8 byte lengths, and writes directories only for misses. It keeps
the original manifest/source/lexical dependency-filename digest order, so
existing entries remain valid. This removes both readback and warm-hit writes.

## Whole-build measurement

Both experiments use the #3325 source snapshot (`4d36fd102`), its same bump
checker images, a frozen 5,447-file source tree, isolated Vibe caches with
equal-length paths, a primed shared native-code cache, three alternating rounds
and an idle host. Each experiment has 24 complete compiler/CLI builds. Timing
includes discovery, preparation, TaskGroup execution, canonical publication and
the final serial build. Every output matches byte for byte within its workload;
the final compiler performs zero checks in both variants. `t` is replay off,
`b` is replay on. Warm replay executes zero worker modules and reuses all
560 compiler / 611 CLI modules; cold executes every module.

These measurements isolate the host replay change on the merged #3325 baseline.
Later main changes to checker/CLI/runner sources are not part of this corpus or
compiler image. They require fresh functional validation separately.

### Current prepared-byte lookup

| Workload/cache | Replay off | Replay on | Wall change | Aggregate tree RSS, off/on (MiB) |
| --- | ---: | ---: | ---: | ---: |
| compiler cold | 24.908s | 25.800s | +3.58% | 1276.7 / 1287.6 |
| compiler warm | 23.811s | 13.014s | -45.34% | 1200.5 / 1196.8 |
| cli cold | 29.098s | 30.280s | +4.06% | 2053.0 / 2056.2 |
| cli warm | 28.004s | 16.477s | -41.16% | 2123.4 / 2132.0 |

RSS is the median sampled maximum across the complete process tree, including
detached coordinator/worker descendants. Sampling is every 25ms; shared pages
are counted repeatedly and short peaks may be missed. Whole-build RSS stays
within about 1%, but frontend RSS increases: compiler warm 300.2 to 338.4 MiB,
CLI warm 540.2 to 554.7 MiB. This is a time improvement with a cold cost, not a
memory or allocation-volume improvement. Final serial codegen/linking still
dominates warm builds; its guest heap is unchanged between replay variants.

### Initial file-readback version

| Workload/cache | Replay off | Replay on | Wall change | Aggregate tree RSS, off/on (MiB) |
| --- | ---: | ---: | ---: | ---: |
| compiler cold | 24.764s | 26.885s | +8.56% | 1274.2 / 1284.1 |
| compiler warm | 24.021s | 16.214s | -32.50% | 1207.0 / 1183.7 |
| cli cold | 29.331s | 31.882s | +8.70% | 2047.8 / 2050.0 |
| cli warm | 28.352s | 20.055s | -29.26% | 2132.5 / 2134.4 |

These are separate controlled experiments; the speed claim compares off/on
within each experiment. Initial host profiles use Node's named CPU profiler on
real compiler/CLI prewarm runs. Open/close/read/stat and buffer/hash work are
visible; most host samples are idle while the native workers run. They do not
profile native checker CPU or prove that all idle time is filesystem overhead.
Cold preparation medians in the initial version were 3.176s / 3.604s for
compiler / CLI. Successful-product storage adds work on cold builds; it remains
included in current timings. The cold regression prevents default enablement.

## Evidence

The adjacent `taskgroup-checker-replay-2026-10-04.samples.jsonl` contains both
experiments' 48 raw samples and two receipts, plus eight current-source
functional samples and their receipt. Receipts include runtime-script
and image hashes, source-receipt digest, aggregate guard digest and measurement
scope. Each full local result retains all 518 immutable guards; all guards and
frozen input bytes are checked before each build and at completion.

The retained Wasm digests are compiler
`50dc32eba5f5be653d2d73b28f6198fd13180fe737264ceb4369a3191638001d`
and CLI `e8d235464c746a357ebf0f8397611e3447fcfe63cb4a00eaf55fee2d8c2581a6`.

The maintained oracle exercises jobs 1/2/4, typed lowering/runtime behavior,
source-body invalidation, damaged records, CFG/error-row changes, producer-image
changes and repeated diagnostics. The TaskGroup CI helper runs replay off and
on. Independent prepared-file byte auditing also covers Japanese/emoji text,
ill-formed-surrogate UTF-8 encoding, 13 duplicate dependency occurrences,
changed Env bytes at a fixed fingerprint and omitted Env files.

After integration onto main `c0cad513f`, a fresh stage2 compiler
(`bcb6088b97c9fbde366b18eb8214ad94a6e92e3ffd64bb62802e60bc90d7329f`)
passes the existing 17 host tests. The maintained native TaskGroup oracle also
passes with fresh checker/coordinator artifacts: actual overlapping CPU ticks,
bounded slots, cancellation/reaping, diagnostics, CFG/error-row parity, and
frontend byte/runtime parity with replay both off and on. A valid unused Wasm
custom-section mutation at the same producer path forces real checks, then
warms again. Repeated diagnosed modules execute again while successful
dependencies replay.

The public `scripts/build_taskgroup_project.sh` also passes eight full compiler
and CLI builds on that main base: jobs 1/4, cold/warm, with isolated caches.
All 564 compiler / 615 CLI modules execute on cold builds and replay on warm
builds; every final compile has zero checker executions. Outputs match separate
ordinary serial controls byte for byte. The complete source, scripts and
producer images remain unchanged throughout. Functional timings are not a speed
claim. Output digests are compiler
`012fc54d9b5c3a42aca5f15c96cdb604947f552379d79410230568f8fa8a6df9`
and CLI `dd066f91454aff4b0f9496083d66f35ff9466eabe6faf07d3ad66792a8303f1e`.

Four complete host CPU profiles are retained as adjacent gzip JSON files:
`taskgroup-checker-replay-2026-10-04.compiler-b-cold.json.gz`,
`taskgroup-checker-replay-2026-10-04.compiler-b-warm.json.gz`,
`taskgroup-checker-replay-2026-10-04.cli-b-cold.json.gz`, and
`taskgroup-checker-replay-2026-10-04.cli-b-warm.json.gz`. These capture the initial
file-readback version and do not attribute native checker CPU time.

Full `pkf run release-check` passes on the main base above: 123 tasks,
32 cached and 91 executed in 43m04s. The compiler reaches the byte-identical
stage2/stage3 fixpoint above. The tracked diff remains unchanged throughout
the gate; AST-required pre-commit and documentation classification also pass.
