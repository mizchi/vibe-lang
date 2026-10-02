# Completed substitution index for formal publication — 2026-10-02

## Measured problem

On a frozen full compiler input, `subst_lookup` consumes 2.052 seconds of
sampled self time. Three formal-publication query paths account for 0.789
seconds of that time. They repeatedly read the same completed substitution
while producing the printed and binder-qualified effect-row instantiations.
The baseline is PR #3281 at `c1a83b08a4cbba29c56059da5af7b98b0df4fdc7`.
Its release/named artifacts and input were frozen before production edits.

## Change

Call tables with at least 256 rows share one `subst_cache_read_snapshot`
between the two publication passes. The snapshot indexes current value
lookup answers, including authoritative cache-only rows and nearest-binding
precedence. Maps contain at most 256 rows each, bounding builder search work.
The original substitution remains at the tail for missing values, effect
bindings and ordered bound contributions. Small tables keep the original path.

`formal_var_display_subst` can extend this read view normally. The checked
observation still publishes the original `final_subst`, so transport schemas
and published substitution authority remain unchanged. No global cache is added.

## Controlled comparison

Nine alternating AB/BA pairs for the uncached flat compiler and three pairs
for isolated FS cold/warm runs. The first three flat pairs precede the FS
pairs; six additional flat pairs check the small whole-compile effect.
Compiler/cache/output paths have equal length between a/b lanes. Flat runs
use the same frozen input and disable the persistent artifact cache. FS
pairs use a fresh cache for cold and reuse it in a new process for warm.
Other local compiler jobs were idle. Timing uses `time.monotonic`.

All 18 flat outputs match the frozen baseline compiler byte-for-byte; all
12 FS outputs match each other for that separate corpus. Eight of nine flat
pairs favor the candidate. The median paired delta is -3.24%; individual
pairs include timing variation, so the report retains every sample.

| Corpus / cache | Before median | After median | Time delta | Allocation delta |
| --- | ---: | ---: | ---: | ---: |
| Full flat compiler / uncached | 19.977 s | 19.312 s | -3.32% | +0.0747% |
| Codegen lexer test / FS cold | 4.628 s | 4.499 s | -2.79% | -0.0005% |
| Codegen lexer test / FS warm | 2.981 s | 2.974 s | -0.21% | -0.0006% |

Flat allocation high water is 2,079,151,524 →
2,080,703,996 bytes, an increase of
1,552,472 bytes. Reserved linear memory
is unchanged. FS time changes are within noise; allocation is essentially
neutral there. RSS and reserved-memory changes in the warm FS lane are not
claims of reduced allocation.

Separate diagnostic profiles reduce the two publication functions' combined
inclusive sampled time from 0.807 s to 0.105 s; snapshot construction costs
0.008 s. `subst_lookup` sampled self time falls from 2.052 s to 1.404 s.
These single profiles locate the change and are not the timing comparison.

## Validation

Fresh pinned-seed stage1/stage2/stage3 builds converge with names enabled.
The release artifact strips only `name`, preserving other custom sections.
The candidate passes 199 affected test blocks on bump, plus the eight core
snapshot and two publication blocks with emitted RC code: 209 executions.
Cases cover empty/plain/cached chains, nearest bindings, zero/negative/wide
IDs, cache-only values, multiple map chunks, ordered bounds, effects,
transitive aliases, open variables, cycles, the 255/256 call-table threshold,
and equality of actual printed/marked publication rows.
Existing type/unification, generic effect-row, unbounded formal and canonical
checked-type-state tests also pass. Full release-check passes: 121 tasks,
107 run and 14 cached, in 47m39s. The final gated compiler is byte-identical
to the measured artifact. AST-required staged pre-commit also passes.

## Reproduce

Build baseline artifacts/input at the baseline commit and candidate stage2
from the same pinned seed. Place release compilers at
`_build/formal-substitution-index/baseline.wasm` and `candidate.wasm`, and
freeze the baseline generated input as `baseline-flat.vibe` in that directory.
Keep other compiler jobs idle. The raw report includes the exact expected
hashes, source identities, samples and a replay that creates a fresh output
folder. With Python and Node 24.7.0 available, run:

```bash
python3 - <<'REPLAY'
import json
from pathlib import Path
report = json.loads(Path("bench/perf/analysis/formal-substitution-index-2026-10-02.json").read_text())
exec(compile(report["reproduction_python"], "formal-substitution-replay", "exec"))
REPLAY
```
