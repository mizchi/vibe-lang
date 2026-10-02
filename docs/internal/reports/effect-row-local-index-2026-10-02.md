# Effect-row local-name membership index — 2026-10-02

`env_row_labels_from` collects effect labels known through external function
signatures. It must exclude the module's own declarations: a declaration's row
cannot establish that its own otherwise-unknown effect exists. The old query
scanned every local name for every environment signature.

The query now builds a function-local `MutSet[String]` when both the local-name
and signature tables have at least 64 entries. Small tables keep a scan. Set
membership answers the same exact-spelling exclusion question; the result still
follows signature order, then result-row and parameter-row order. Duplicate and
kinded labels remain intact. The index does not escape the query or change
published environment, substitution or checked-module transport authority. An
empty local-name list still skips the signature name column entirely.

## Fresh comparison on main

The parent PR #3285 merged together with main's #3286 structural-equality fix.
The final comparison therefore rebuilds both sides on
`0b9e44442cba850a8069a3342bca57b78bf92395`; it does not reuse the older compiler.
Both fresh pinned-seed builds converge at stage2/stage3. The candidate was built
with the exact staged implementation patch before committing, and integration
into the primary checkout preserves its producer and test hashes. The primary
generated input also matches the candidate's frozen build input byte-for-byte.

Three alternating AB/BA pairs per corpus, on an otherwise idle local machine:

| Corpus | Baseline median | Candidate median | Wall delta | Allocation delta |
| --- | ---: | ---: | ---: | ---: |
| Frozen full compiler, uncached | 18.946 s | 17.444 s | -7.93% | +1,760,488 B (+0.0846%) |
| FS compiler test, cold | 4.693 s | 4.647 s | -0.97% (noise) | +239,752 B (+0.0263%) |
| FS compiler test, warm | 2.955 s | 2.966 s | +0.35% (noise) | -6,960 B (-0.00137%) |

All three flat pairs improve: -10.81%, -8.19%, -7.79%; the median paired delta is
-8.19%. Reserved linear memory is unchanged for flat and FS cold. FS warm capacity
is 592,445,440 → 564,133,888 bytes (-4.78%), explained separately below. RSS is
advisory; this is not a 27 MiB allocation or physical-memory saving.

Flat runs compile the same frozen baseline input with persistent guest caches
disabled. Every FS cold run starts with an isolated empty cache and its warm run
reuses that cache in a fresh process. The `a`/`b` compiler, cache and output paths
have equal lengths. Source, dependency, patch and artifact guards pass before and
after the comparison. All 18 output binaries match within their corpora; the
flat output also matches the frozen baseline release compiler.

Three additional A/A FS pairs use the same frozen baseline artifact on both
sides with the same path lengths. Cold/warm allocation, reserved bytes and
outputs agree inside every pair. This rules out a path-lane bias for these runs.

Separate diagnostic profiles on the fresh artifacts record 1.312 s inclusive /
0.477 s self in the old query and 0.0119 s inclusive in the candidate, including
index construction. No candidate self sample lands at the 1 ms interval, which
does not imply zero CPU cost. These diagnostic runs overlap the earlier full
gate; their elapsed time is excluded from the controlled wall comparison.

## FS warm growth history

A separate diagnostic replaces guest `memory.grow` operations with an appended
wrapper that records events in Wasm globals, without allocating or writing linear
memory. A Node preload records host growth. Original function/global indices are
preserved; both trace binaries validate. Original, traced and restored-original
runs have identical output, heap high water and capacity inside each lane, and
all eight outputs match the controlled FS comparison. Source guards pass.

The guest grows by `max(deficit, memory_size / 2)`, while host allocations grow by
exact deficit. The host grows at different points, changing the base of later
guest growth. Both binaries make 12 guest grows; the baseline makes 13 host grows
and ends at 9,040 pages, while the candidate makes 9 and ends at 8,608 pages. All
observed guest deltas and chronological page transitions match the recurrence.
This explains the exact 432-page (28,311,552-byte) capacity decrease despite only
6,960 fewer allocated bytes.

The earlier comparison on #3285's branch head `3ba3f3cd06` instead showed warm
capacity **+5.02%**, with a 2,312-byte allocation increase. Its independently
verified trace shows the opposite growth trajectory. Keeping both records makes
the capacity sensitivity visible rather than attributing it to index storage.
An external geometric-host experiment on those historical artifacts preserves
heap/output and makes both warm capacities 8,295 pages (543,621,120 bytes).
The runtime policy remains a separate follow-up, with package-size probes from
#2509 required before generalizing the full-compiler capacity result.

## Artifacts and correctness

Release artifacts remove only the Wasm name section; the ABI section is retained.

| Fresh artifact on main | SHA-256 |
| --- | --- |
| Baseline release | `9ca673c7fd8cfd6624743c7c5d039de131607b7eb99b0d91f86ff5b036189117` |
| Candidate release | `2f9d0bf0708761ce86cc6999babbdf506d57676f246929c0fd1628438bc88775` |
| Baseline named | `fe2d665a563492ff3c5e862168dff6d104df27e0e0a097c15b08595396432d5c` |
| Candidate named | `e8c24d8757de38fa70cdead4e704f3e82d6d48eacd2111e1fffce16c59ebcf78` |
| Frozen comparison input | `c7c6cd51ac4802eec56ff423faccbca9879ffbbba54e31b058c026c0db266246` |
| Candidate build input | `bbdf535aebda04500c13fc377ff11d4b4e3c507b4dd5448d2df51786967749e1` |

The fresh main candidate passes 37 actual test-block executions: six new tests
on bump and RC plus the function-table, generic-effect and three effect-overlay
regression suites on bump. Every emitted test module's `_start` was executed.
The cases preserve external-row order and duplicates, parameter rows, exact name
matching, empty inputs and a large local table. An end-to-end diagnostics case
with 81 declarations confirms that a local row cannot authorize `Missing`.
The empty-local fixture accepts omitted signature names and retains parameter
labels; the original scan established that behavior independently in a frozen
old-function source probe. The eager-name variant fails that regression on both
allocators, and the corrected query passes.

The historical full `pkf run release-check` passes (121 tasks, 43m33s), with its
compiler artifact matching the measured historical candidate. The first attempt
had failed only the new test's formatting check; that file is now formatted.
Full release-check on integrated main passes (121 tasks, 45m17s); its
compiler artifact matches the fresh measured candidate above. Final AST-required
staged pre-commit also passes.

## Replay and raw evidence

Fresh samples, commands, cache flags, output/source hashes, artifact receipts,
tests and growth histories are in
`bench/perf/analysis/effect-row-local-index-main-2026-10-02.json`.
The original pre-merge comparison and its full-gate receipt remain in
`bench/perf/analysis/effect-row-local-index-2026-10-02.json`.
Local replay scripts and frozen artifacts are under `_build/effect-row-local-index-main/`:

```bash
python3 _build/effect-row-local-index-main/profile.py baseline
python3 _build/effect-row-local-index-main/profile.py candidate
python3 _build/effect-row-local-index-main/compare.py
python3 _build/effect-row-local-index-main/aa-control.py
python3 _build/effect-row-local-index-main/growth-audit/instrument.py
python3 _build/effect-row-local-index-main/growth-audit/run.py
```

Replay needs the recorded artifacts and fresh output/cache directories. The
comparison guards require the baseline source commit and exact staged candidate
patch; its receipt includes source hashes because the implementation was measured
before committing. Diagnostic profiles are never substituted for the idle wall
comparison. Full CPU profiles and emitted test modules remain local scratch.
