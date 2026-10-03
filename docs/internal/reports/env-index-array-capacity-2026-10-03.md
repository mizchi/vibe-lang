# Known-size environment index arrays — 2026-10-03

Reserving four known-size arrays reduces compiler-sized bump allocation by
29,620,104 B (1.42%,
28.25 MiB). Allocation falls
on every measured flat/FS/package corpus; reserved Wasm capacity stays the same.
Wall time remains inconclusive. Initial and follow-up timing data are retained.

The new baseline profile spends 1.025 s self in env_lookup_binding (6.47%).
Earlier private counters on the parent identify 195,227,439 binding visits and
60,474,912 B allocated inside 20 env_cache calls. Wasm heap-boundary attribution
adds no guest allocations and matches the uninstrumented frontier. That probe
uses a different frozen flat input and overlaps a gate, so it informs selection
without a wall claim. The private preallocation screen is likewise diagnostic.

sort_perm_by_names reserves its integer permutation to names.length;
apply_perm_strings reserves reordered names to perm.length; env_cache reserves
reordered EnvValueBinding rows to that length; env_name_index_new reserves its
power-of-two probe table before filling it. Stable ordering, first-binding wins,
mutable facts, provenance, surface barriers and shared scope semantics remain
intact. The index still copies and owns immutable names. Empty/singleton and
unsorted indexes retain the existing no-table lookup. Refresh stays at 512
statements; shorter cadence requires a separately controlled CPU/allocation test.

## Controlled measurements

Base: e6b614eb58502ee10cd7eb78c6ffb367fcf89679 (PR #3292). A fresh clean baseline precedes
edits; both named compilers satisfy stage2 == stage3. Timed artifacts remove
only names, preserving ABI. Frozen parent flat input SHA:
d727573da5f476af442a5107513b9e69f7892f31f35b384ae1953cea47457e54.
It differs from #3292's pre-range input, so absolute totals are separate series.

Initial comparison: three alternating AB/BA pairs for five corpora, 54 samples.
Equal-length lane paths; flat guest caches disabled; isolated FS cold caches
followed by warm builds in separate processes; bump allocation, zero pregrow,
cli_main and run-init bypass. No overlapping local builds/tests. Initial A/A
adds 30 same-artifact samples for flat/FS/JSON. Follow-up adds six pairs each
for FS/JSON/parser: 72 A/B and 72 A/A samples. Output/source/artifact/HEAD/staged
guards pass throughout. Every A/A pair agrees byte-exactly on bump frontier and
capacity. Raw timings and advisory RSS are preserved.

| Corpus | Baseline median | Reserved median | Wall delta | Bump allocation delta | Reserved capacity |
| --- | ---: | ---: | ---: | ---: | ---: |
| flat/uncached | 15.330 s | 15.362 s | +0.21% | -29,620,104 B (-1.420%) | 2575.50 → 2575.50 MiB |
| fs/cold | 4.657 s | 4.636 s | -0.45% | -6,260,256 B (-0.685%) | 1166.44 → 1166.44 MiB |
| fs/warm | 2.961 s | 3.000 s | +1.31% | -1,440,040 B (-0.284%) | 518.44 → 518.44 MiB |
| json/cold | 0.321 s | 0.348 s | +8.60% | -290,480 B (-2.146%) | 13.50 → 13.50 MiB |
| json/warm | 0.304 s | 0.307 s | +0.69% | -257,992 B (-2.449%) | 13.50 → 13.50 MiB |
| optimizer/cold | 0.401 s | 0.403 s | +0.51% | -78,208 B (-0.277%) | 30.38 → 30.38 MiB |
| optimizer/warm | 0.338 s | 0.342 s | +1.22% | -47,112 B (-0.243%) | 20.25 → 20.25 MiB |
| parser/cold | 1.184 s | 1.211 s | +2.23% | -618,536 B (-0.693%) | 102.44 → 102.44 MiB |
| parser/warm | 1.052 s | 1.051 s | -0.10% | -334,240 B (-0.611%) | 68.31 → 68.31 MiB |

JSON cold initially reports +8.60% by ratio of medians, with paired deltas
+2.92%, +8.70%, -1.02%. Parser cold has three positive pairs; FS warm also warrants
more controls. These concerns trigger six follow-up pairs without changing
producers/artifacts. Initial data is retained alongside the follow-up.

| Corpus | Initial A/B wall | Follow-up A/B wall | Follow-up A/A wall |
| --- | ---: | ---: | ---: |
| fs/cold | -0.45% | +0.76% | -1.96% |
| fs/warm | +1.31% | +0.16% | +0.75% |
| json/cold | +8.60% | -1.19% | -2.38% |
| json/warm | +0.69% | +1.78% | +1.31% |
| parser/cold | +2.23% | +0.58% | -0.50% |
| parser/warm | -0.10% | -0.74% | +1.77% |

Directional regressions do not reproduce consistently. Wall effects remain
inconclusive; the result supports allocation-volume reduction at existing
capacity. Flat initial wall is +0.21% versus initial A/A +0.38%. Profiles are
diagnostic and nested inclusive times overlap. Code size:
3,915,221 → 3,915,480 B (+259 B). heap_ptr measures allocation
volume; reserved pages and advisory RSS are separate. The package probes do not
complete #2509's broader KPI contract.

## Ordinary CI KPI and ratchet

Three ordinary default selfcompile_kpi.sh cold runs per artifact agree exactly:
1,026,358,856 → 1,019,539,416 B (-6,819,440 B). Normal default
allocator/entry behavior and fresh /tmp caches make this a separate series from
the explicit-bump comparison. Ratchet the committed absolute baseline
1,023,482,488 → 1,019,539,416 B, retaining +10% tolerance. The parent already
measures 1,026,358,856 B on this source tree; the full committed-baseline delta
is not attributed to this patch.

One default KPI run reports -363 ms after a system clock adjustment. Its date(1)
wall values make no timing claim here. Controlled comparisons use time.monotonic().
The harness keeps all five successful logs, accepts signed wall values and runs
only the missing sixth compile. Raw data retains that event and parser provenance.

## Validation and evidence

188 actual blocks across five modules pass with bump and RC. Four new tests
cover empty/singleton permutations and cached lookups, reordered strings under
caller mutation, and returned type/origin payloads after temporary snapshots and
allocation pressure. Existing collision, ownership, malformed-ordering,
zero-allocation lookup, environment shadow/provenance/surface, complete/partial
snapshot, program transport and canonical-state tests pass. All five changed
Vibe files pass CST formatting. Full release-check passes: 122 tasks (15 cached, 107 run) in 45m29s. The gated compiler hash matches the frozen measurement compiler, and the producer/test/runner and staged snapshots agree through the gate. AST-required staged pre-commit passes and is repeated after staging these validation-status updates.

bench/perf/analysis/env-index-array-capacity-2026-10-03.json records 228 controlled
samples, six default KPI samples, commands/cache flags, output/memory records,
generation/source hashes, profiles and executed exports. Local replay artifacts
are under _build/env-index-capacity-perf/: preserve-generation.py, profile.py,
run-integrated-tests.py, compare.py, aa-control.py, followup-compare.py and
followup-aa-control.py.
