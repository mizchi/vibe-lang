# Checker environment snapshots — 2026-10-02

## Problem and measurement

The full flat compiler build took a median 126.828 seconds through the current
selfhost compiler. A named-artifact CPU profile put 82.1% of sampled self time
in `env_lookup_binding` and `env_lookup_binding_including_surface`. The named
baseline differs from the production artifact only by its name section.

An isolated diagnostic compiler counted 885,500 lookups and 7,962,636,282
visited environment nodes. Failed lookups account for 5,683,759,977 visits
(71.4% of the total). `String`, `Array`, and `Array::get` are prominent misses;
successful lookups also repeatedly traverse the large hoisted binding prefix.
The diagnostic compiler emits exactly the original compiler bytes. Its
instrumented timing is not a performance comparison.

## Change

Large checker statement lists (at least 256 remaining statements) receive a
fresh lookup snapshot every 512 statements. Each snapshot indexes all
canonical value bindings and can refuse a missing name without scanning its
tail. Partial and decoded accelerators retain their existing fallback behavior.

The existing tuck-behind layout remains intact. A shared set records names
added behind a complete snapshot. It only grows: an older branch may perform
an unnecessary fallback, but cannot incorrectly answer absent. Shadowing
bindings remain ahead of an index containing their name. Tail transformations
discard canonical snapshots entirely, including stale positive type/origin
rows. Rebuilding removes the preceding snapshot while preserving canonical
binding order, mutable-cell markers, declarations, and re-export barriers.

A first experiment rebuilding every 64 statements increased allocation volume
by about 25%, despite byte-equivalent output. That cadence was rejected. The
512-statement candidate below trades 3.4% more allocation for a large CPU gain.
It is not presented as a memory improvement.

## Controlled results

Three alternating AB/BA pairs for each configuration, on an idle local WSL
machine with Node 24.7.0. Both lanes use equal-length compiler/cache/output
paths. Elapsed time uses `time.monotonic`. The flat input is frozen before the
implementation changes and its persistent artifact cache is disabled. FS
runs use a separate empty cache per lane and pair, followed by a warm repeat.
All six flat outputs and all twelve FS outputs are byte-identical within their
respective corpora.

| Corpus / cache | Before median | After median | Time delta | Heap-pointer delta |
| --- | ---: | ---: | ---: | ---: |
| Full flat compiler / uncached | 126.828 s | 30.015 s | −76.3% | +3.376% |
| Codegen lexer test / FS cold | 4.785 s | 4.719 s | −1.4% | +0.00025% |
| Codegen lexer test / FS warm | 2.959 s | 2.994 s | +1.2% | −0.00083% |

FS wall changes are below the noise floor. Flat allocation high water is
2,007,505,308 → 2,075,269,932 bytes; reserved linear memory remains
2,696,675,328 bytes. FS cold reserved memory is unchanged; FS warm reserved
memory is +3.57%, while its allocation high water is essentially unchanged.
RSS medians are +3.12% flat, +0.20% FS cold, and −1.26% FS warm; RSS is not a
byte-deterministic allocation metric.

A diagnostic re-profile reduces the two lookup functions' combined self time
from 108.760 to 8.929 seconds (−91.8%). The whole elapsed-time claim comes from
the interleaved samples, not that single profile.

The baseline FS invocation failed with an absolute input spelling, reporting
missing AST declarations. The normal repo-relative spelling succeeds and is
used identically in both measured lanes. The failed invocation is retained in
the raw report and excluded from all deltas.

## Validation

The 49 type-environment tests pass, including shared branches, shadowing,
partial-index fallback, re-export barriers, mutable facts, positive/negative
snapshot invalidation, and bounded snapshot history. Two additional large-list
checker tests cross the snapshot boundary and check generic aliases, forward
calls, and rejection of a wrong argument type.

A fresh fixed-seed → stage1 → stage2 → stage3 build passes. Stage2 and stage3
are byte-identical and match the exact candidate artifact measured above:
`fac1095255fe5dbfb2bc273b639061cfbb2db6bba377673e6ba82d3cd07dee4e`.
Full `pkf run release-check --timing` passes (121 tasks: 107 ran, 14 cached;
44m31s is validation duration only), including a freshly executed compiler gate.
AST-required staged pre-commit passes with the explicit fresh stage2 compiler.

## Reproduce

Prepare a baseline checkout at `f6c9d348193b57f5fe904ca0747c7ee13272be79` and
build its fresh stage2 with `scripts/generations.sh`. Build the candidate's
fresh stage2 with the same pinned seed. In the candidate checkout, place the
baseline stage2 at `_build/type-env-lookup/baseline.wasm`, its generated
`_cli_adapter_module_source.vibe` at `_build/type-env-lookup/baseline-flat.vibe`,
and candidate stage2 at `_build/type-env-lookup/candidate.wasm`. These must be
release artifacts with names stripped. Keep other compiler jobs idle.

With Python and Node 24.7.0 available, replay the recorded harness:

```bash
python3 - <<'PY'
import json
from pathlib import Path
report = json.loads(Path("bench/perf/analysis/checker-environment-snapshots-2026-10-02.json").read_text())
exec(compile(report["reproduction_python"], "checker-snapshot-reproduction", "exec"))
PY
```

The replay creates a fresh output directory. The raw report retains individual
samples, producer and artifact identities, diagnostic counts, profile summaries,
validation receipts, and the runnable harness.
