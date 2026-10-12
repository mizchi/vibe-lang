# Independent module-lowering boundary

`PreludeModuleJob` runs passes 4 through 10 after the coordinator has run
passes 0 through 3 and projected dependency interfaces. Each job contains one
owned module AST, its exact resolved bodyless import interfaces, typed lowering
rows, source-name metadata, and the whole-program facts those passes require.
It never carries `LinkedFunctionPlan` or other modules' function bodies.

The coordinator must compute import visibility using the loader's exact
re-export closure. Supplying every transitive dependency would expose private
imports. Trait wrapper names, explicit derived-operation names, function alias
renames and the host-future predicates come from the checked whole program;
a worker cannot derive those facts from its own partition.

`run_prelude_module_job` consumes its owned AST. Workers must use independent
Wasm instances: simultaneous calls inside one instance remain unsafe because
the individual passes still use instance-local mutable scratch tables. The
trait-dictionary job installs its namespace metadata, clears its equality
ledger, and returns that job's deferred equality requests and refusals. It
restores the caller's namespace and ledger on both success and exception.
Invisible-nominal observations are returned separately. Existing pass-entry
resets initialize the other scratch tables.

The product contains the lowered owned AST, synthesized declaration keys,
append-pass ranks, diagnostics, extracted inline-Wasm names and bodies, and
the equality side channels. The module tag identifies the requested partition.
A coordinator must validate that identity and merge products in source-module
order. Merge append-pass ranks using `prelude_tail_record` (lowest pass wins),
merge equality requests using `module_lowering_deferred_merge` (first key wins),
and preserve inline-Wasm name/body pairing. Whole-program passes 11 onward,
structural-helper minting, ownership fixpoints and validators remain at link.
A job failure must be propagated instead of publishing a partial linked program.

The worker is a separate build unit and is not enrolled in the selfhost
compiler source manifest. Importing the ordinary compiler does not load its
job runners or transport codecs.

`@vibe/lowering_worker` provides checked codecs built on AST binary
ABI v4. The versioned job/product envelopes reject unsupported formats, trailing
bytes and inconsistent parallel arrays. These are transient worker messages,
not persistent cache entries. Callers own job freshness and must not reuse a
product from a different input. `worker.vibe` is a Vibe entry that reads a list
of job paths from `VIBE_LOWERING_WORKER_LIST`, processes jobs sequentially in
its independent instance, and writes each successful product beside its job.
The parent owns unique paths, result validation and process lifecycle.

## Validation and measurements

The [measurement receipt](../../../bench/perf/analysis/module-worker-boundary-2026-10-11.json)
records 587 compiler jobs and 624 CLI jobs. Preparing every job before any
lowering produced exactly the same input bytes as the sequential collector.
Independent workers returned byte-identical complete products for every job,
including changed batch order. Replacing the coordinator's module processing
with these products preserved the complete generated Wasm for both subjects.

Three interleaved one/two-worker rounds measure worker startup, job reads and
decode, passes 4..10, and product encode/writes. They exclude coordinator
preparation, job encoding and global finalization. Median worker-phase walltime
was 11.21 → 5.98 seconds for the compiler and 15.78 → 8.96 seconds for the CLI.
Median summed worker peak RSS was approximately 1,420 → 1,426 MiB and
1,959 → 1,781 MiB respectively; shared mappings can be counted twice.
Largest serialized jobs were 705,305 and 38,727,787 bytes. The large CLI job
contains generated compiler-source text, rather than a whole-program plan.

The diagnostic collector retains all job and expected-product byte buffers.
Cold CLI collection trapped in the allocator; warm collection reached almost
4 GiB of linear memory. That collector is not a production implementation.
A production coordinator needs bounded outstanding jobs and products instead
of retaining both complete serialized sets. No full-build speedup or total
memory improvement is claimed. The default CLI remains sequential.

## Bounded TaskGroup dogfood

`scripts/build_taskgroup_lowering.sh <stage2.wasm>` builds three independent
images: the synchronous compiler entry, the lowering worker, and an
Async-only coordinator. Their receipt binds the compiler, native runner and
all three images. `VIBE_TASKGROUP_LOWERING=1 VIBE_UNSTABLE=1 vibe build --jobs 2`
selects this route in a repository checkout. `VIBE_LOWERING_ARTIFACT_DIR`
selects a different artifact directory. This currently accepts the RC backend
and `.vibe` core builds without `--minify`. Installed-toolchain packaging and
other build modes remain follow-up work.

The coordinator uses `TaskGroup::spawn_suspend` to await at most four native
worker instances. Each wave contains at most 16 jobs per slot and 64 MiB of
serialized input. The native bridge independently enforces both limits and
rejects duplicate jobs and pre-existing products. Every future owns its child;
drop/cancellation kills and reaps it through the existing checker supervisor.
The parent waits for a complete wave, consumes its products in source order,
and deletes its input and product files before opening another wave. Disk
products and the final compiler output stay private until all phases succeed.

The Async component composition cannot satisfy the compiler's Env/Fs imports.
`prelude_with_module_batch_executor` therefore suspends one synchronous compiler
instance after passes 0..3. The opt-in native `compiler_lowering_run` CPU service
reenters that same instance's exports to encode job inputs and consume products;
it invokes the existing Vibe TaskGroup component for each bounded wave. The
compiler retains its prepared AST and runs passes 11 onward and final codegen
once after all products have merged. There is no second preparation or replay.
The old per-module executor and the batch executor share a scope guard, restore
the sequential path on success or exception, and refuse nested scopes. Oracle
observations still use the sequential path.

Job inputs use two reusable 64 MiB raw Bytes buffers; product storage is reused
up to the largest product seen so far. The codecs preserve the existing wire
format. Decoding copies strings and AST values, so later buffer reuse cannot
change a merged module. This bounds retained transfer buffers; it does not
reclaim every temporary allocation made by the decoder or compiler. A fresh
cold CLI compile exhausted wasm32 memory before the buffer reuse fix.

Worker receipts bind the consumed input and encoded product. The parent
checks both hashes and the module tag before merging side channels. The native
service snapshots compiler filesystem reads, probes and directory listings,
checks source freshness after each wave and before writing the private output,
and excludes build-cache data. An empty cache setting selects the same default
cache directory as the compiler. The frontend rechecks image, compiler and
runner hashes before atomically publishing the final Wasm. Failure preserves
an existing output.

The service requires an explicit private configuration and unstable RC mode.
Its parent callbacks use tagged Int arguments followed by the closure environment
slot, raw Bytes pointers, and packed String values. The native bridge validates
callback types, product allocation bounds and lengths before writing guest memory.

`VIBE_LOWERING_TRACE_OUT` optionally saves a versioned lowering report. Its
path must not alias the entry or output, including symlinks and hardlinks.
An existing file is replaceable only when it identifies itself as a report
from this route; imported source files and unrelated user data are refused.
The report is staged before the output is published, so a trace write failure
also preserves the previous output.

Outstanding worker inputs are bounded; total compiler memory is not thereby
bounded. Preparation still holds the whole raw AST. The retained parent keeps preparation
allocations live through worker execution, while job context encoding, product
decoding and final codegen remain serial. Full-build walltime includes these
costs and transport digest computation. The
route is opt-in dogfood until coordinator-inclusive cold/warm measurements
justify a default change; worker-only timings above do not establish that.

Full-build dogfood measurements (three interleaved rounds per temperature)
are recorded in the [TaskGroup report](../../../bench/perf/analysis/taskgroup-module-lowering-2026-10-12.json).
The preparation CPU profile put scalar BLAKE3 at 58.0–58.2% inclusive. The RC-only
build units now use the existing SIMD BLAKE3 implementation, with official
vector parity. It changes the transport validation cost, not the job format.

| warm full build | ordinary whole | serial split | TaskGroup 1 | TaskGroup 2 |
|---|---:|---:|---:|---:|
| compiler closure | 3.78 s | 8.64 s | 16.24 s | 13.48 s |
| CLI | 11.23 s | 23.00 s | 48.11 s | 41.99 s |

Before SIMD, TaskGroup 2 took 20.99 s and 75.10 s respectively. The new route
improved by 35.8% and 44.1%, but remains slower than both existing controls.
Sampled summed warm RSS is about 895 MiB and 2,789 MiB with two workers,
compared with 574 MiB and 2,039 MiB for ordinary whole builds. These are live
process RSS sums, not allocation volume; shared mappings may be counted twice.

The batch service above removes the second compiler preparation. Default
enablement remains blocked by repeated immutable facts and interface transport,
serial parent encoding/decoding and final codegen, and cold memory pressure from
retaining the parent instance. Shared immutable context transport and its full
cold/warm memory measurements must precede increasing worker counts. The table
above describes the earlier two-preparation route; it is not a measurement of
the retained-parent service.

## Retained-parent full-build measurements (2026-10-13)

The [raw report](../../../bench/perf/analysis/module-single-preparation-2026-10-13.json)
records 24 final full builds against `b49d197282991286d7c222ec011aa9355e426be2`,
including the source-kind freshness guard added during review. Each cold/warm
pair has an isolated parsed-source cache; other guest caches are off and native
JIT caches are primed. Three rounds alternate old/new order on one frozen corpus
with no concurrent builds, tests or source edits. All output Wasm bytes agree
across these 24 runs and the preceding 48-run experiment, including serial controls.
Both experiments and their separate artifact receipts are retained in the report.

| full build | old TaskGroup 2 | retained-parent TaskGroup 2 | wall change | summed RSS, old → new | RSS change | earlier serial split |
|---|---:|---:|---:|---:|---:|---:|
| compiler cold | 17.54 s | 16.24 s | -7.4% | 957 → 1,217 MiB | +27.2% | 12.67 s |
| compiler warm | 13.69 s | 11.98 s | -12.5% | 905 → 845 MiB | -6.7% | 8.73 s |
| cli cold | 50.43 s | 46.52 s | -7.7% | 2,822 → 3,203 MiB | +13.5% | 31.95 s |
| cli warm | 41.98 s | 37.20 s | -11.4% | 2,822 → 2,451 MiB | -13.1% | 23.67 s |

Values are medians of three samples per cell. RSS sums the live process tree
every 25 ms and can count shared mappings twice; it is not allocation volume.
The serial controls were measured in the preceding experiment, before the
native source-kind guard; they are not new samples from the final experiment.
The new service's `worker_ms` includes parent encoding, decoding and merging,
so it cannot be compared directly with the old worker-only phase field.

One preparation improves TaskGroup walltime and warm RSS, but raises cold RSS
and remains slower than serial split. This route therefore stays opt-in. The
next step is to share immutable context once, then reduce retained products,
and only then assess higher worker counts.
