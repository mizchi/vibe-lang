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

The parent serializes a shared interface pool, typed equality rows, trait facts,
namespace originals and prelude environment once. Pool positions retain each
source declaration, including equal names with different contents. Each job
contains its owned AST and the exact ordered positions selected by the existing
import closure and own-key exclusion. Workers decode the shared context once
per instance, before their bounded job loop; each wave still starts fresh
instances. The shared-job format carries the context's BLAKE3 digest, bound by
the existing parent-validated input receipt. The native service also verifies
the context file after each wave. Legacy standalone job codecs remain available.

Inputs and shared context use one reusable 64 MiB raw Bytes buffer; product
storage is reused up to the largest product seen so far. Decoding copies strings and AST values, so later buffer reuse cannot
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
allocations live through worker execution, while job encoding, product
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
and remains slower than serial split. This route therefore stays opt-in. The shared-context transport above is the next optimization. Retained products
and higher worker counts still need separate full-build measurements.


## Shared immutable context measurements (2026-10-13)

The [raw report](../../../bench/perf/analysis/module-shared-context-2026-10-13.json)
compares merged retained-parent baseline `b26188a4` with shared-context transport
on one frozen corpus. It records the pre-edit baseline and volume probe,
48 final full builds, source/artifact hashes and the measurement harness.
Three rounds alternate old/new TaskGroup 2 cold/warm pairs with isolated
parsed-source caches; other guest caches are off and native JIT is primed.
No local builds, tests or edits overlap measurements.

| full build | retained-parent TG2 | shared-context TG2 | wall change | summed RSS, old → new | RSS change | candidate serial split | baseline ordinary whole |
|---|---:|---:|---:|---:|---:|---:|---:|
| compiler cold | 16.87 s | 15.16 s | -10.2% | 1,228 → 1,198 MiB | -2.4% | 13.08 s | 6.02 s |
| compiler warm | 12.40 s | 10.78 s | -13.0% | 844 → 822 MiB | -2.7% | 9.01 s | 4.13 s |
| CLI cold | 48.19 s | 43.45 s | -9.8% | 3,198 → 3,095 MiB | -3.2% | 33.24 s | 16.80 s |
| CLI warm | 38.52 s | 34.06 s | -11.6% | 2,450 → 2,365 MiB | -3.4% | 24.70 s | 12.32 s |

Each cell is the median of three runs. The 36 TaskGroup and serial-split
outputs are byte-identical per subject. Ordinary whole builds produce a
different Wasm and are separately consistent across their 12 control runs.
RSS samples sum the process tree every 25 ms, can double-count shared pages,
and do not measure allocation volume.

Parent serialization falls from 40,208,406 to 8,410,453 bytes for 324 compiler
modules (-79.1%), and from 144,308,880 to 64,982,064 bytes for 619 CLI modules
(-55.0%). The shared files are 472,168 and 888,865 bytes respectively. Those
totals count each shared file once at the parent; fresh worker instances still
read and decode it once per wave. Context files and each wave's queued jobs
have separate 64 MiB limits, and slot queues retain the 16-job bound.

The native wave protocol uses version 2 with an explicit context path. Version
1 remains available for legacy standalone jobs and removes inherited shared
context settings. Unsupported fields, missing/empty/oversized contexts and
wrong job context digests are refused. Context mutation after preparation is
also checked before products merge. Interface positions preserve provenance,
closure order, duplicates and own-key exclusions; workers do not expose every
pool declaration to every job.

Sharing improves both temperatures but leaves cold RSS near 1.2/3.0 GiB and
TaskGroup 2 slower than serial split. Default enablement stays off. Next:
reduce retained product and decode allocations, then measure higher worker
counts only after that memory work.

## Bounded product decoding measurements (2026-10-14)

The parent already consumes one product at a time. The remaining copy was
inside the product envelope: decoding its nested module blob pushed every byte
into a fresh growing `Bytes` buffer before decoding the AST. The parent now
uses a child `AstBinaryReader` over the original bytes with an independent
end bound. Byte, varint, string/UTF-8 and nested count checks respect that bound,
and the module decoder still rejects trailing bytes inside the child. The wire
format and input/product receipts are unchanged. Keep the shared bytes immutable
until both cursors finish reading; decoded AST nodes and strings own their data.
Tests cover nested bounds, invalid child lengths, UTF-8 across a child boundary,
shortened/extended product blobs and overwriting the buffer after decoding.

After the synchronous lowering service returns and all products are consumed,
the compile image clears its callback buffer references and capacity/digest
state. `Bytes` remain bump-backed even on the RC lane: this bookkeeping does
not reclaim their capacity or shrink linear memory. Workers and host callbacks
cannot retain those pointers past the service return. The measured allocation
reduction comes from avoiding copies, rather than releasing those reservations.

The [raw report](../../../bench/perf/analysis/module-product-decode-2026-10-14.json)
records a pre-edit baseline, 36 final full builds, codec probes, separate parent
CPU profiles, source/artifact hashes and the harnesses. Baseline `77733f789` and
the candidate compile one frozen main corpus; three rounds alternate TaskGroup
2 cold/warm pairs, with candidate serial-split controls. Parsed-source caches
are isolated per pair, other guest caches are off and native JIT is primed.
Generated vpkg type declarations are prepared before measurement with separate
scratch caches: the initial attempt that created them during a build was refused
by input freshness checks and is excluded. No builds, tests or edits overlap
the measured runs. All 36 Wasm outputs are byte-identical per subject; all 945
captured worker product envelopes also match byte for byte.

| full build | shared-context TG2 | bounded decoder TG2 | wall change | summed RSS, old → new | RSS change | candidate serial split |
|---|---:|---:|---:|---:|---:|---:|
| compiler cold | 14.29 s | 14.13 s | -1.2% | 1,204 → 1,186 MiB | -1.6% | 12.41 s |
| compiler warm | 10.23 s | 9.97 s | -2.5% | 819 → 807 MiB | -1.4% | 8.58 s |
| CLI cold | 40.70 s | 39.12 s | -3.9% | 3,112 → 2,947 MiB | -5.3% | 31.30 s |
| CLI warm | 31.89 s | 30.20 s | -5.3% | 2,363 → 2,190 MiB | -7.3% | 23.25 s |

Cells are medians of three runs. Small compiler wall differences remain near
the noise floor. RSS sums the process tree every 25 ms, can double-count shared
pages and measures neither total allocations nor uniquely resident physical
memory. These results use a different main corpus from the preceding table;
compare old/new rows within each table rather than combining them.

Compiler products total 7,804,337 bytes across 325 modules; CLI products total
63,731,031 bytes across 620 modules, including one 39,170,471-byte envelope.
On those same captured products, three codec runs reduce RC1 decode time from
2.24 to 1.57 s for the compiler and 15.58 to 10.21 s for the CLI. Bump-mode
decode allocation volume falls by 22,023,488 and 210,765,440 bytes respectively.
RC1 heap-pointer deltas measure additional heap growth under reuse, not total
allocation volume; the report retains both modes. These standalone codec times
are not full-build walltime. Separate cold parent CPU samples no longer contain
the blob-copy frame; inclusive result-decode samples fall from 6.0% to 4.1% for
the compiler and 14.2% to 9.9% for the CLI. Inclusive percentages overlap and are
approximate.

The change reduces transfer allocations and full-build memory, but TaskGroup 2
remains slower than serial split. Default parallel lowering stays off. Next,
measure higher worker counts and the remaining serialization/codegen costs
before choosing an enablement policy.
