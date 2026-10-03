# Re-export surface query miss bounds — 2026-10-03

Compiler-sized flat wall median falls from 15.340 s to
14.965 s (-2.44%).
All five paired trials improve; their median delta is
-2.39%, while A/A reports
+0.60% by ratio of medians.
FS cold median improves -2.30%.
FS warm and package wall effects remain inconclusive. This supports a
compiler-sized wall-time improvement with tiny allocation costs.

## Measured bottleneck and semantics

The baseline profile spends 0.363 s
self in env_has_reexport_surface_binding. The final profile samples
0.014 s self and
0.015 s inclusive there.
These are diagnostic single profiles, not independent wall trials.
Earlier counters on input d727573d (a different frozen closure, alongside a
release gate) reduced binding visits 58,256,271 → 2,582,297 while retaining
the emitted Wasm. The report preserves that separate protocol.

The historical query deliberately sees older same-named surface bindings even
behind newer ordinary locals. A cached positive row must therefore keep
scanning; arbitrary acceleration rows do not own surface authority.
Complete factories cover names in the canonical chain, including surfaces.
A name absent from their owned index and shared added-tail-name set can end
the historical scan. Read snapshots, duplicate names, shared forks and
canonical tail invalidation retain their existing semantics.

The final predicate first checks env_name_index_miss_is_final, then checks
env_name_index_find < 0. Partial or nonfinal nodes skip an unnecessary name
probe. Both conditions are required; a positive name always falls through.
No TypeEnv shape, ownership, refresh cadence or persistent schema changes.

## Controlled protocol

Base: f7ca2d2a6432e139bf96d5fab8b2b168d60b853e (PR #3293). A fresh clean build precedes
edits; every candidate satisfies stage2 == stage3. Timed binaries remove only
the name custom section and retain ABI. Frozen baseline input SHA:
0b1204ffcd92ff506beed395443b1b31d7e81296a40ff34758f66db72bb500a1.
Its absolute totals form a separate series from #3293's older flat input.

Initial and final variants each use five alternating pairs for flat/FS and
three for JSON/optimizer/parser: 66 A/B and 66 A/A samples per variant.
Flat guest caches are disabled; FS caches are isolated per pair/lane with
cold and warm runs in separate processes. Equal-length a/b paths, bump,
zero pregrow, cli_main and run-init bypass are held fixed. time.monotonic()
measures wall time; no overlapping local compile or test runs occur.
Output, compiler, input, source, runner, HEAD and staged guards pass.
Every A/A pair has identical allocation and capacity. Paired timings and
advisory RSS are retained in the raw record.

| Corpus | Baseline | Final | Wall median delta | Paired median delta | A/A wall delta | Allocation delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| flat/uncached | 15.340 s | 14.965 s | -2.44% | -2.39% | +0.60% | +0 B |
| fs/cold | 4.733 s | 4.624 s | -2.30% | -3.48% | +0.52% | +2,880 B |
| fs/warm | 2.974 s | 2.974 s | +0.01% | +0.01% | -0.47% | +1,640 B |
| json/cold | 0.340 s | 0.338 s | -0.36% | -0.67% | -0.51% | +1,576 B |
| json/warm | 0.298 s | 0.301 s | +0.88% | +0.50% | +0.13% | +920 B |
| optimizer/cold | 0.403 s | 0.405 s | +0.36% | +0.36% | -0.04% | +616 B |
| optimizer/warm | 0.341 s | 0.350 s | +2.48% | +2.03% | +1.14% | +224 B |
| parser/cold | 1.211 s | 1.204 s | -0.56% | -0.56% | +1.14% | -56 B |
| parser/warm | 1.028 s | 1.055 s | +2.70% | +2.89% | +0.97% | -104 B |

All controlled reserved Wasm capacities remain byte-identical. Flat allocation
is unchanged; FS/package deltas range from -104 B to +2,880 B in the final
initial series. Code size 3,915,480 → 3,915,531 B (+51 B).
Allocation volume, reserved capacity and advisory RSS are separate; this
change makes no peak-live-memory or RAM-saving claim.

## Retained concerns and follow-ups

The first predicate order probes names before checking proof availability.
It improves flat -2.39%
but optimizer cold reports +2.72%, versus its A/A -0.72%.
That complete original series and exact source snapshots are retained.
Checking the proof first avoids probing partial nodes. Final initial optimizer
and parser warm medians are +2.48% and +2.70%, prompting six-pair follow-ups
without changing source or artifacts.

Instrumented actual compilation reproduces the emitted package Wasm.
Optimizer/parser warm execute zero surface queries; cold invokes 3/168
queries and visits 3/336 partial nodes, with zero positive name probes.
These counts exclude direct surface-query call overhead as the warm cause,
but do not establish a cause for total wall variation or prove wall neutrality.

| Corpus | Final initial A/B | Follow-up A/B | Follow-up A/A |
| --- | ---: | ---: | ---: |
| optimizer/cold | +0.36% | +0.12% | -3.89% |
| optimizer/warm | +2.48% | +0.02% | +0.64% |
| parser/cold | -0.56% | +0.24% | +0.10% |
| parser/warm | +2.70% | -1.16% | +1.27% |

The warm directional concerns do not repeat consistently. Follow-up optimizer
cold A/A itself varies -3.89%; two large negative first-pair A/B deltas
(-23.43% optimizer cold, -29.65% parser cold) are preserved.
Package timing remains inconclusive. There are 360 controlled observations,
including both complete variants and the 48 A/B plus 48 A/A follow-up.

## Ordinary CI KPI and validation

Three unchanged ordinary default cold KPI runs per artifact agree:
1,019,548,368 → 1,019,551,480 B (+3,112 B,
+0.000305%). The current FS tree includes the staged
producer, so the parent's +8,952 B drift from the committed
1,019,539,416 B baseline is separate. Retain that baseline and +10% tolerance.
These default allocator/entry/cache observations are separate from the
explicit-bump protocol. Realtime wall values are advisory only.

216 actual blocks across index, environment, transport and canonical-state
suites pass with bump and RC for each variant. Fourteen new cases cover empty/
plain environments, older hidden surfaces, shared branches, partial positive
and missing rows, stale acceleration-only surfaces, duplicate flat rows,
metadata, invalidation, read snapshots and malformed partial ordering.
CST formatting passes. Full release-check passes: 122 tasks (15 cached, 107 run) in 45m50s. The gated compiler hash matches the frozen measurement compiler, and the producer/test/runner and staged snapshots agree through the gate. AST-required staged pre-commit passes and is repeated after staging these validation-status updates.

The raw record includes all timings, memory/output records, executed exports,
source/runtime/compiler/input hashes, generation receipts, profiles, diagnostic
counts, ordinary KPI observations and the source-order refinement audit.
Local replay scripts live under _build/surface-miss-perf; published artifacts
are reproducible with generations.sh and the recorded runner commands.
