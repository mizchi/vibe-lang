# Compiler source splitting: allocation attribution and follow-ups

## Result

PR [#3254](https://github.com/mizchi/vibe-lang/pull/3254)'s perf report records
1.03 GiB / +14.28% for the compiler-closure workload. The increase comes
mainly from doing more work at module boundaries: projecting imports,
publishing environments and collecting typed-lowering metadata. The source
split converts local helper calls into imported calls and exposes more helper
signatures. These costs remain optimization work after the source-size refactor.

Two local allocation fixes are included in the PR:

- Namespace path sanitization appends valid byte spans instead of allocating a
  String and builder entry for every valid byte. Rejected bytes still each
  become one underscore, including every byte of a non-ASCII name.
- Persistent environment encoders push length-prefixed segments directly into
  the builder they already own, avoiding two temporary payload copies at 23
  call sites. The v9/v10 wire formats are unchanged.

On one fixed modified source tree and identical cache/output paths, three cold
trials per compiler measured **1,111,480,632 -> 1,107,431,352 bytes**:
**4,049,280 bytes / 3.86 MiB less allocation**. Each alternative produced the
same heap pointer in all three trials. The ordinary KPI harness measures the
new compiler at **1,107,397,680 bytes**, also identical across three trials.
The small difference between harnesses comes from their guest-visible paths.

## What was compared

- Input: `lib/@vibe/compiler/tests/codegen_lexer_test.vibe`, filesystem compile
  to `__no_entry__`. This is a compiler-closure compile, not the full bootstrap
  pipeline or a full CLI build.
- Before source: `5ac16bcd09e81e291eef21a62ec0faa6085759d1`.
- Split source before these fixes: `22e13f47aa1140efc179f2d7130568f946d30e07`.
- Attribution compiler: the same compiler on both source trees, built from the
  latter revision; original stage2 SHA-256
  `3ba06903fd5d9d2668e99adfdfd78df7852b49eac1083dcf91b76c733a602121`.
- Fixed stage2 SHA-256:
  `2e03ef94037a2ce9f57884ec69037758b07256a9acaf2889ab8e4486e0a524dd`.
- Compiler execution uses the linear bump allocator; generated programs use
  linear RC. These are separate selectors.
- Every allocation trial starts a fresh process with an empty isolated
  `VIBE_BUILD_CACHE_DIR`. No wall-time improvement is claimed.

The input closure grows from **225 to 351 dependencies**, or **226 to 352 module
checks including the root**. Raw source bytes grow from 7,180,838 to 7,470,711,
about 4.0%. The allocation increase is larger because multiple consumers
materialize each module's interface and metadata.

`heap_ptr_bytes` is the bump allocator's high-water/cumulative allocation
measure. It is not live memory, peak RSS or proof of an RC leak. In these runs,
reserved linear memory even falls from 20,668 to 18,663 pages because memory
growth is geometric. Those page counts must not replace the allocation metric.

## Attribution on the ordinary production compile path

Temporary Wasm probes measured heap-pointer deltas at function entry/exit.
They add static globals and heap reads, with no guest allocations. A same-path
instrumented/uninstrumented control measured **1,111,158,848 bytes in both**
and emitted the same output SHA-256. Early-return and nested-call controls
verified the inclusive and exclusive counters. Three instrumentation variants
also produced identical output within each source tree.
The two attribution worktrees/cache paths have slightly different lengths;
the tables identify MiB-scale growth, not exact sub-MiB source-only effects.
The local-fix comparison above uses one source tree and identical paths.

The following top-level calls are disjoint. They explain most of the
132.4 MiB increase measured by that harness:

| Region | Before bytes | After bytes | Increase |
| --- | ---: | ---: | ---: |
| Source-group collection | 176,710,040 | 206,462,488 | 28.4 MiB |
| Module typecheck/cache preparation | 338,039,828 | 428,277,844 | 86.1 MiB |
| Merged statement construction | 70,391,744 | 81,236,264 | 10.3 MiB |
| All other work, including codegen | — | — | 7.7 MiB net |

The dedicated `VIBE_PROFILE_MEMORY_MARKS` path initially located the increase
but takes a different preparation/merge path. Its codegen region fell by about
5.5 MiB; its phase totals are not interchangeable with the ordinary KPI path.
The ordinary-path probes above are the attribution used for follow-up work.

### Import interfaces

`bind_import_names_from_cache_collecting` runs **857 -> 2,090 times** and its
inclusive allocation grows by **26.5 MiB**. Within the broader compile:

- `env_flat_bindings`: 1,308 -> 2,824 calls, **+6.3 MiB**. It constructs a new
  array of `(name, Type)` tuples each time.
- `note_identity_closure`: 2,372 -> 5,692 calls, **+8.8 MiB**. Importing more
  signatures repeats their referenced declaration/provenance closure work.
- `env_selectable_type_defs`: 3,129 -> 7,324 calls, **+2.5 MiB**.

The 26.5 MiB includes its children; adding these rows would double-count.
Actual statement inference, `check_stmts_with_binders`, is nearly flat:
136,574,376 -> 137,064,652 bytes, **+0.47 MiB**. Most preparation growth is
outside that core inference invocation.

### Conservative imported renderer detection

`irc_show_shim_names` adds **every imported/re-exported name** to its candidate
set. It cannot inspect the imported body, so an ordinary imported function
must conservatively count as a possible direct `__to_string(param)` wrapper.
`irc_collect_expr` then visits its arguments as possible render arguments.

Moving local calls across the new file boundaries magnifies this existing
tradeoff. `checked_render_offsets_and_rows` grows from 10,774,660 to
22,972,944 allocated bytes, **+11.6 MiB**. Persisted typed-key rows grow from
**4,197 to 9,303**, their text from 289,135 to 734,554 bytes, while distinct keys
grow only from 66 to 100. Inert rows remain correct type facts; their collection
and serialization are the cost.

Issue [#2472](https://github.com/mizchi/vibe-lang/issues/2472) was closed as
not planned after measuring only 0.28% overhead on its old workload. Its
[closing decision](https://github.com/mizchi/vibe-lang/issues/2472#issuecomment-5678847452)
allows reconsideration after a new profile changes that cost. This workload
satisfies that condition. The collector's increase is measured; a precise
metadata implementation's net saving still needs measurement.

### Publication and serialization

Committing checked modules adds **17.1 MiB** of inclusive allocation. Its
combined cache serialization grows from 22,517,208 to 40,294,512 bytes. Included
in that figure are `serialize_type_env` (**+11.3 MiB**) and the typed-lowering
serializer (**+4.1 MiB**).

Published environment payloads on disk grow from 1,334,833 to 2,236,622 bytes;
lowering sections grow from 661,935 to 1,369,926 bytes. Allocation exceeds
output bytes because recursive encoders materialize nested strings and row
arrays before producing the final record. The local segment fix removes one
bounded part; recursive type encoding and digest/row construction remain.

The experimental dependency-environment reuse/TDRE9 compile lane is disabled.
Its eligibility and transport-key functions ran **zero times** in the profile;
that experimental serialization is not the cause of this default-lane increase.

## Remaining work

| Issue | Implementation direction | Required contract |
| --- | --- | --- |
| [#3256](https://github.com/mizchi/vibe-lang/issues/3256) | Share immutable dependency-interface views across importers | Keep aliases, lexical order, selected declarations and collision/provenance checks specific to each importer; invalidate by the actual published product |
| [#3257](https://github.com/mizchi/vibe-lang/issues/3257) | Transport precise exported renderer-wrapper metadata | Preserve actual render answers across aliases/re-exports and cold/warm cache hits; missing metadata must trigger checking or the conservative fallback |
| [#3258](https://github.com/mizchi/vibe-lang/issues/3258) | Stream recursive type/cache encoders and lowering rows | Preserve canonical transport bytes, counts, digest, empty-vs-unavailable tables and corruption rejection |

All three are performance / P2 / Backlog (unscheduled), indexed from
[#2833](https://github.com/mizchi/vibe-lang/issues/2833). Each issue includes
Red/Green regressions, isolated cold/warm allocation measurements and compiler
fixpoint/output checks. Attribution gives where bytes are spent, not a promised
saving for any unimplemented design. Additional loader and merge overhead is
recorded above; it has not been assigned to an unmeasured cache redesign.

## Evidence and validation

The [machine-readable counter table](../../../bench/perf/analysis/file-split-memory-2026-10-01.json)
retains all 78 paired function counters, cache sizes and instrumentation controls.
Inclusive counters include descendants and recursion; `self` subtracts completed
instrumented descendants and includes uninstrumented children. Exceptional
unwinds skip that leaving function's exit counter, so use the successful
top-level totals rather than treating every nested row as an exact partition.

Both allocation regression tests failed before the fixes and pass afterwards.
The byte/mangling tests cover empty and valid paths, separators, non-ASCII byte
replacement, export/private names and a long canonical environment segment.
All 66 targeted codec/import tests pass under the fresh compiler; bump and RC
runs pass. Stage2 equals stage3. Seven fixed user inputs produce byte-identical
Wasm and runtime answers with the pre-fix and fixed compilers.

To reproduce the ordinary KPI, build the PR's compiler, then run three times
with the harness's independent empty caches:

```bash
bash scripts/generations.sh build --out-dir _build/memory-audit/generations --stage3 --skip-run-validation
bash scripts/selfcompile_kpi.sh _build/memory-audit/generations/stage2.wasm
```

For a before/after optimization decision, use the same input tree and a fixed
`VIBE_KPI_WORK_DIR` under `_build`, alternate compiler order, and compare
cold/cold and warm/warm separately. The current fixes were measured cold;
warm allocation savings are not claimed.
