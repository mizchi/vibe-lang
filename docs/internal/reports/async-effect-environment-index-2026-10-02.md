# Async-effect environment index — 2026-10-02

## Problem and measured scope

After indexing callable bodies, a fresh named-artifact profile spends 8.267
seconds (29.08% of sampled self time) in `env_lookup_binding`. Most callers
belong to the async-effect walk, including handler-payload inference. The
completed checker environment has lost its earlier acceleration snapshots;
these lookups repeatedly scan its authoritative binding chain.

The baseline is `edab861d9307282e538e91f32775e3278c244ac1` (PR #3279).
Its release compiler, named compiler and complete flat compiler input were
frozen before changing production code. Both lanes compile that same input.

## Change and semantics

For program entries with at least 256 statements, build one complete environment
snapshot before constructing the field-type table and walking the statements.
The walk reads one environment; lexical bindings remain in `AfeLocals`. Reuse
the existing `env_cache_complete` constructor, which indexes canonical bindings
and preserves nearest-binding order, surface barriers, binding provenance,
type definitions and mutability markers in its authoritative tail.

The existing memo reset still runs before any environment question. The
snapshot belongs to the current entry, with no new cross-entry cache. Small
programs, expression entries and single-statement entries retain their existing
cost and behavior. No exported APIs or diagnostics change.

## Controlled comparison

Three alternating AB/BA pairs per configuration, on an idle WSL machine with
Node 24.7.0. Compiler/cache/output paths have equal length across lanes. Flat
compilation disables the persistent artifact cache. FS pairs each use a fresh
cache for cold compilation and reuse it in a fresh process for their warm run.
All six flat outputs and twelve FS outputs are byte-identical within their
respective corpora. Timing uses `time.monotonic`.

| Corpus / cache | Before median | After median | Time delta | Allocation delta |
| --- | ---: | ---: | ---: | ---: |
| Full flat compiler / uncached | 28.076 s | 20.615 s | -26.57% | +0.2258% |
| Codegen lexer test / FS cold | 4.813 s | 4.747 s | -1.38% | -0.0002% |
| Codegen lexer test / FS warm | 3.065 s | 3.075 s | +0.33% | -0.0002% |

Full-flat allocation high water is 2,074,478,356 →
2,079,163,428 bytes. Reserved linear memory changes by
+0.00% for this corpus. The raw report includes
allocation, reserved-memory and RSS medians for all configurations; RSS is
not a deterministic allocation metric. FS allocation is essentially unchanged;
warm reserved linear memory falls by 3.45%. FS wall deltas below roughly 5% should
be treated as noise, not evidence of a speed improvement.

The diagnostic profile reduces `env_lookup_binding` sampled self time from
8.267 seconds to 1.059 seconds. This single diagnostic profile is separate
from the interleaved comparison used for whole compile-time claims.

## Validation

Eight new tests exercise actual large-program entries for memo resets, builtin
AsyncIter provenance, projected fields, call results, nearest environment
bindings, partial cached tails, surface barriers, lexical shadowing and exact
diagnostic order. They pass with both baseline and candidate. The candidate
also passes all 55 existing async-effect tests, six entry-memo tests and six
callable-body-index tests: 75 test blocks in total.

A fresh fixed-seed → stage1 → stage2 → stage3 build converges with names enabled.
The release artifact removes only the name section, retaining `vibe.abi`;
its SHA-256 is `d3dea3044767fb4df3bec2de237e6d79061e8db4c46258eda068979dc56801ff`.
Generation run-validation was skipped; targeted tests were run separately.
Full release-check passes: 121 tasks, 107 run and 14 cached, in 44m28s.
The fresh gated compiler is byte-identical to the measured artifact, and the
staged production/test source hashes match the measured identities.
AST-required staged pre-commit also passes with the candidate compiler.

## Reproduce

Build baseline stage2 and generated flat source at
`edab861d9307282e538e91f32775e3278c244ac1`, and build candidate stage2 from the
same pinned seed. Place the release artifacts and frozen source at
`_build/afe-environment-index/baseline.wasm`,
`_build/afe-environment-index/candidate.wasm`, and
`_build/afe-environment-index/baseline-flat.vibe`. Keep other compiler jobs idle.
With Python and Node 24.7.0 available, run:

```bash
python3 - <<'REPLAY'
import json
from pathlib import Path
report = json.loads(Path("bench/perf/analysis/async-effect-environment-index-2026-10-02.json").read_text())
exec(compile(report["reproduction_python"], "async-effect-env-reproduction", "exec"))
REPLAY
```

The replay creates a fresh output directory. The raw report records all samples,
invocations, environment overrides, output hashes, producer/artifact identities,
profile summaries and validation receipts.
