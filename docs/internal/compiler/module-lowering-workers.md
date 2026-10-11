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
memory improvement is claimed. The default CLI remains sequential; TaskGroup
scheduling, coordinator-inclusive cold/warm measurements and failure/cancellation
integration remain follow-up work.
