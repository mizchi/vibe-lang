# Substitution value-key bounds — 2026-10-03

The compiler-sized CPU profile spends 1.283 s in substitution value
lookup. Diagnostic builds that preserve the same emitted output record 58,750
queries and 74,231,137 binding-node visits. Misses account for 73,977,978 visits
(99.66%). Queries above the maximum value key on wholly uncached chains account
for 63,394,503 visits (85.40% of all visits). This identifies repeated full-chain
absence searches as the bottleneck; merely deferring integer-to-string conversion
produced only a small, inconsistent wall-time change in the earlier local probe.

`subst_bind_value` now wraps each covered value chain in an immutable
`SubstValueRange(max_key, rest)` frame. A lookup above that maximum returns
`None` before key formatting or chain traversal. Other queries use the original
first-binding-wins scan. Six value-binding sites in unification use the factory.
The underlying value chain remains authoritative, and older scopes/forks retain
their own frame. Extending a framed chain replaces only its top metadata frame.
Raw prefixes are examined before publishing coverage; bounds and effect bindings
do not contribute value keys. Encountering any arbitrary `SubstCached` map stops
coverage publication, because partial maps may hold larger or unusually spelled
keys. Cached hits and misses retain their existing semantics. There is no global
ID cache, mutable value authority, key-string sentinel, or cached `Type` payload.

The new variant is appended after the existing five tags. Bound/effect observers
skip the frame. Program transport, typedef v2 transport, and normalized checked
implementation bytes omit it and serialize the authoritative rest; decode retains
the existing format. Typedef v2 continues to reject observable cached maps.

Selfcompile median is 16.984 → 15.366 s
(-9.52%). Individual paired deltas are
-8.64%, -9.59%, -9.52%. The diagnostic lookup profile falls
from 1.283 to 0.096 s including its nested private scan.
Nested inclusive times must not be added together. Profiles are diagnostic and
their elapsed times are not the controlled wall comparison.

## Controlled comparison

The source base is `d09f40513e6f7976dc3d0450a7005b1850e2a080` (#3291), with the same
geometric host runtime on both sides. A fresh baseline was generated before
source edits. Both final named compilers pass stage2 == stage3. Only the name
section is stripped for timed compilers, preserving ABI metadata. Both compilers
emit the frozen baseline artifact for the frozen baseline flat input.

Three alternating AB/BA pairs for five corpora yield 54 samples. Flat builds
disable persistent guest caches. Every FS cold build has a fresh isolated cache;
its warm build is a separate process using that same cache. Compiler, output, and
cache paths have equal lengths across lanes. Normal host wrappers retain Wasm
inlining, use zero memory pregrow, and bypass `_start` for `cli_main`. Measurements
run without overlapping tests/builds. All output, source, artifact, HEAD and
staged-patch guards pass. Thirty additional A/A samples use the frozen baseline
on both sides for flat, FS and JSON: paired bump heap frontiers and capacities
agree exactly. Raw timing and RSS remain in the record.

A/A flat wall medians differ by +0.39%; FS cold differs by +5.20% and warm
by −1.07%. The small FS A/B changes below therefore do not establish a speedup.

| Corpus | Baseline median | Bounded median | Wall delta | Bump allocation delta | Reserved capacity |
| --- | ---: | ---: | ---: | ---: | ---: |
| flat/uncached | 16.984 s | 15.366 s | -9.52% | -37,344 B (-0.00179%) | 2575.50 → 2575.50 MiB |
| fs/cold | 4.575 s | 4.543 s | -0.69% | -23,592 B (-0.00258%) | 1166.44 → 1166.44 MiB |
| fs/warm | 2.994 s | 2.945 s | -1.64% | -3,712 B (-0.00073%) | 518.44 → 518.44 MiB |
| json/cold | 0.338 s | 0.341 s | +1.03% | -1,224 B (-0.00904%) | 13.50 → 13.50 MiB |
| json/warm | 0.300 s | 0.301 s | +0.35% | -712 B (-0.00676%) | 13.50 → 13.50 MiB |
| optimizer/cold | 0.401 s | 0.407 s | +1.64% | -568 B (-0.00201%) | 30.38 → 30.38 MiB |
| optimizer/warm | 0.345 s | 0.343 s | -0.52% | -512 B (-0.00265%) | 20.25 → 20.25 MiB |
| parser/cold | 1.203 s | 1.212 s | +0.72% | -520 B (-0.00058%) | 102.44 → 102.44 MiB |
| parser/warm | 1.038 s | 1.042 s | +0.38% | -424 B (-0.00078%) | 68.31 → 68.31 MiB |

The allocation changes are tiny and reserved capacity is unchanged throughout.
This is a CPU optimization; it does not establish a meaningful memory reduction.
FS and subsecond package timing should be read against individual pairs and A/A
noise, rather than taken as speedup claims. `heap_ptr` measures bump allocation
volume, not live memory. Reserved capacity is page-granular; RSS is advisory.
The JSON/optimizer/parser probes follow #2509's corpora without completing its
broader KPI scope. The earlier pre-comment-fix candidate/results are preserved
locally under `pre-doc-fix/` and are not used for final artifact claims.

## Validation

282 actual test blocks run through the final integrated compiler with bump and
RC allocation, across nine modules. Fourteen new factory/oracle tests cover
negative and large signed keys, duplicates, first-binding precedence, scopes and
forks, raw prefixes, partial caches, exact key spelling, growing chains, payload
lifetime under allocation pressure, bounds, effects and nested types. Added
program and typedef transport tests require byte-identical existing encodings
and successful roundtrips. Existing snapshot, equality, canonical type-state,
effect observation and unification tests also pass. All changed Vibe sources
pass the CST formatter. Full release-check passes: 122 tasks (40 cached, 82 run) in 43m08s. The gated compiler hash matches the frozen measurement compiler, and the producer/test/runner and staged snapshots agree through the gate. AST-required staged pre-commit passes and is repeated after staging these validation-status updates.

## Evidence and replay

`bench/perf/analysis/substitution-value-key-bounds-2026-10-03.json` retains 54
A/B and 30 A/A samples with commands, environment/cache flags, memory and output
hashes, compiler generation receipts, source hashes, diagnostic counts, profile
summaries, and actual executed test exports. Replay helpers and full artifacts
are local under `_build/subst-key-range-perf/` (`preserve-generation.py`,
`run-integrated-tests.py`, `profile.py`, `compare.py`, `aa-control.py`). The public
record contains exact invocations; local artifact paths describe this run.
