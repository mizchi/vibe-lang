# Async-effect environment index — 2026-10-02

## Problem and measured scope

After indexing callable bodies, a named-artifact profile spends 8.267 seconds
(29.08% of sampled self time) in `env_lookup_binding`. Most callers belong to
the async-effect walk, including handler-payload inference. They repeatedly
scan the completed checker environment.

The baseline is `edab861d9307282e538e91f32775e3278c244ac1` (PR #3279).
Its release compiler, named compiler and full flat compiler input were frozen
before changing production code. Both lanes compile that same frozen input.
The measurements below use the cache-row-preserving revision after review.

## Change and semantics

For entries with at least 256 statements, create one read snapshot before
building the field-type table and walking statements. The walk reads one
environment; lexical bindings remain in `AfeLocals`. Small programs, expression
entries and single-statement entries retain their existing behavior.

`env_cache_read_snapshot` is a new core constructor for this read-only case.
It preserves cached rows that have no mirrored `EnvBind` in the tail, as well
as their binding origins. Cached rows are selected through their existing
lookup function, including duplicate and unsorted-row behavior. Existing
complete-node miss barriers still hide older rows where the original lookup
would stop. Stable sorting and deduplication retain the nearest visible row.

The original environment stays in the tail for declaration, type-origin,
trait and mutability walks. Existing memo resets run before any query, and
the snapshot belongs to the current entry. The canonical `env_cache` and
`env_cache_complete` rebuilders keep their existing freshness semantics;
read snapshots preserve the current lookup-visible view instead.

## Controlled comparison

Three alternating AB/BA pairs per configuration, on an idle WSL machine with
Node 24.7.0. Compiler/cache/output paths have equal length across lanes. Flat
compilation disables the persistent artifact cache. FS pairs each use a fresh
cache for cold compilation and reuse it in a fresh process for their warm run.
All six flat outputs and twelve FS outputs are byte-identical within their
respective corpora. Timing uses `time.monotonic`.

| Corpus / cache | Before median | After median | Time delta | Allocation delta |
| --- | ---: | ---: | ---: | ---: |
| Full flat compiler / uncached | 27.488 s | 19.935 s | -27.48% | +0.1943% |
| Codegen lexer test / FS cold | 4.902 s | 4.883 s | -0.39% | -0.0005% |
| Codegen lexer test / FS warm | 3.061 s | 3.029 s | -1.02% | -0.0003% |

Full-flat allocation high water is 2,074,478,516 →
2,078,508,852 bytes. Reserved linear memory changes by
+0.00% for this corpus. The raw report includes
allocation, reserved-memory and RSS medians for all configurations. RSS is
not a deterministic allocation metric. FS wall deltas below roughly 5%
should be treated as noise.

The diagnostic profile reduces `env_lookup_binding` sampled self time from
8.267 seconds to 1.060 seconds. Diagnostic profiles are separate from the
interleaved comparison used for whole compile-time claims.

## Validation

The original eight large-entry tests cover memo resets, builtin AsyncIter
provenance, projected fields/call results, nearest bindings, cached tails,
surface barriers, lexical shadowing and exact diagnostic order. They passed
before the original optimization and still pass after this revision.

Review found that a canonical rebuild could discard valid cache-only bindings.
Three additional large-entry tests cover cache-only user `sleep`, builtin
AsyncIter provenance and factory results. The user-binding case fails on the
reviewed artifact, then passes on the fixed artifact. Six new core tests
compare actual lookup answers across cache-only rows, duplicate and nested
caches, flat tails, surface barriers, complete misses, later bindings,
unsorted rows, mutability facts and trait declarations.

The fixed artifact passes all 133 affected test blocks on bump, including
55 existing async-effect tests, six entry-memo tests, six callable-body-index
tests and 49 type-environment tests. The eleven large-entry tests and six core
snapshot tests also pass with emitted RC code: 150 test-block executions total.

A fresh fixed-seed → stage1 → stage2 → stage3 build converges with names enabled.
The release artifact removes only the name section, retaining `vibe.abi`;
its SHA-256 is `4d609f23fc011dff002a52e6ad3f993a7a2c255291b77cd3ed2e279567ae833f`.
Generation run-validation was skipped; targeted tests were run separately.
Full release-check passes: 121 tasks, 107 run and 14 cached, in 45m22s.
The final gated stage2 is byte-identical to the measured fixed artifact.
AST-required staged pre-commit also passes with this artifact.

## Reproduce

Build baseline stage2 and generated flat source at
`edab861d9307282e538e91f32775e3278c244ac1`, and build candidate stage2 from the
same pinned seed. Place the release artifacts and frozen source at
`_build/afe-environment-index/review-cache-rows/baseline.wasm`,
`_build/afe-environment-index/review-cache-rows/candidate.wasm`, and
`_build/afe-environment-index/review-cache-rows/baseline-flat.vibe`.
Keep other compiler jobs idle. With Python and Node 24.7.0 available, run:

```bash
python3 - <<'REPLAY'
import json
from pathlib import Path
report = json.loads(Path("bench/perf/analysis/async-effect-environment-index-2026-10-02.json").read_text())
exec(compile(report["reproduction_python"], "async-effect-env-reproduction", "exec"))
REPLAY
```

The replay creates a fresh output directory. The raw report records every
sample, invocation, environment override, output hash, producer/artifact
identity, profile summary and validation receipt. It also retains the reviewed
revision's medians for comparison with the corrected implementation.
