# Reference-name membership index — 2026-10-03

Reference collection previously scanned the entire output array for every name.
The compiler-sized baseline CPU profile attributes 0.921 s to this
collector. Each public collection now seeds a fresh exact-string `MutSet` from
the current output and carries it through expression/type walks and nested
modules. Existing output entries, including duplicates, are preserved; new
references append once in their original first-encounter order. Empty statement
queries return without allocating an index. Lexical binding stacks and their
push/truncate boundaries are unchanged. The shared type-reference walker also
serves alias reachability; that caller uses a fresh set for its empty output,
with recursive/acyclic/formal-shadowing alias cases covered by a regression.

The compiler-sized flat build median falls from 17.692 s
to 16.759 s (-5.27%). All
three paired runs improve (4.37–6.06%). Its bump allocation volume rises by
0.0858%; FS cold rises by 0.3249% and FS warm by 0.00145%. Reserved capacity
is unchanged for every measured corpus and temperature. This is a CPU
optimization with a small allocation cost, not a memory-reduction claim.

## Controlled comparison

The source base is `b382d6c5f1261f8a6a1442f7474143f829611124` (#3290). Both lanes use its
geometric host runtime. Fresh named compiler builds retain the name section for
CPU profiles and pass stage2 == stage3. Only the name section is removed for the
timed artifacts; ABI custom sections remain. The flat input is frozen from the
baseline, and both compilers emit the baseline artifact for it.

Three alternating AB/BA pairs per corpus produce 54 samples. Flat runs disable
persistent guest caches; every FS cold run uses an isolated empty cache and is
followed by a warm run in a fresh process. Compiler/cache/output paths have equal
lengths across lanes. All outputs agree within each corpus, and source, artifact,
HEAD and staged-patch guards pass. Timing uses an otherwise idle local machine.
An additional 30-sample A/A control uses the same baseline artifact in both
lanes for flat, FS cold/warm and JSON cold/warm builds; its raw memory and timing deltas are
retained beside the A/B record.
All A/A heap frontiers and reserved capacities agree within each paired
configuration, supporting interpretation of the small A/B allocation deltas.

| Corpus | Baseline median | Indexed median | Wall delta | Bump heap delta | Reserved capacity |
| --- | ---: | ---: | ---: | ---: | ---: |
| flat/uncached | 17.692 s | 16.759 s | -5.27% | +0.0858% | 2575.50 → 2575.50 MiB |
| fs/cold | 4.638 s | 4.635 s | -0.05% | +0.3249% | 1166.44 → 1166.44 MiB |
| fs/warm | 2.957 s | 2.959 s | +0.08% | +0.0015% | 518.44 → 518.44 MiB |
| json/cold | 0.338 s | 0.348 s | +3.06% | +0.2347% | 13.50 → 13.50 MiB |
| json/warm | 0.299 s | 0.301 s | +0.60% | +0.0047% | 13.50 → 13.50 MiB |
| optimizer/cold | 0.399 s | 0.400 s | +0.22% | +0.1666% | 30.38 → 30.38 MiB |
| optimizer/warm | 0.336 s | 0.338 s | +0.62% | +0.0002% | 20.25 → 20.25 MiB |
| parser/cold | 1.212 s | 1.224 s | +0.94% | +0.2949% | 102.44 → 102.44 MiB |
| parser/warm | 1.046 s | 1.053 s | +0.62% | +0.0012% | 68.31 → 68.31 MiB |

JSON cold initially shows +3.06% (about 10 ms). Five additional alternating
A/B pairs (20 cold/warm samples) show -1.69% cold wall instead;
the same-artifact JSON cold A/A control shows -4.93%. This
subsecond row does not support a reliable speedup or slowdown claim. The
repeat uses its own isolated equal-length paths; its baseline allocation values
are not pooled with the original harness's values.

The profiles are diagnostic rather than wall benchmarks: reference collection
falls from 0.921 s to 0.064 s, and the old linear membership
function disappears. Bump heap frontiers measure allocation volume on this lane,
not live bytes. Reserved capacity changes in pages and is sensitive to growth
trajectories. RSS is advisory. The package probes are the JSON, optimizer and
parser corpora from #2509; this change does not complete that issue's KPI scope.

## Validation

There are 90 actual test blocks through the integrated compiler: 11 new reference
collection/alias tests, 24 existing unused-import/discard tests and 10 prelude
module-oracle tests, each compiled and run with both bump and RC allocation.
The new tests cover existing duplicate prefixes, exact spelling/Unicode, first
encounter order, fresh public queries, output truncation, lexical binder lifetimes,
nested modules, declaration type positions, repeated large queries, empty inputs
and strings surviving a temporary AST and the local membership index. Both
changed files pass the repository CST formatter check.

Full release-check passes: 122 tasks (15 cached, 107 run) in 44m19s. The gated stage2 hash matches the frozen measurement compiler; producer, test and runner hashes and the staged snapshot are unchanged through the gate. AST-required staged pre-commit passes; it is rerun after staging these validation-status updates.

## Raw evidence

`bench/perf/analysis/warning-reference-name-index-2026-10-03.json` retains all 54
samples plus 30 A/A controls and 20 JSON repeat samples, commands/environment/cache
flags, memory/output hashes, named/release
compiler receipts, source snapshots, CPU profile summaries and actual test export
lists. Local replay scripts/artifacts live under `_build/warning-name-index-perf/`;
replay uses fresh directories and the recorded artifacts. Initial integration
and formatting diagnostics are separate from the final measurement.
