# Invocation-owned checked lowering (#1953)

Baseline: `29116ea1f0117e42f14d6583f2a670dca530e7f4` (merged #3884). The process memo retains only the latest lowering row per path. Checking identical text under another target can replace String/equality observations, builtin identities and argument placements needed by a retained invocation. This slice adds an opaque copied `CheckedLoweringInputs`, a `TypeDb` capture provider, and an explicit-config typed merge data entry.

Capture requires matching path, exact source, checked fingerprint and published target identity. Fresh configured checks and accepting cache providers bind that identity. Missing/stale/unbound publications require a recheck; empty complete channels and declined placement markers keep their separate meanings. Arrays copy while immutable strings share. Queries return copies. The merger validates all supplied sources and the target before changing metadata, clears shared call cells, and restores identities/placements exclusively from retained rows. Ordinary unions and alias-clone lookup use the same owned input; rebase and equality-name rewriting share the compatibility implementation.

Namespace/location metadata remain owned by the serial merge phase. CLI, codegen/final artifacts, workers and other configuration/authority families remain later work. The new data entry needs only `Exception` and does not expose a configured typed-codegen entry or enable concurrent whole-compiler calls. Compatibility lifecycle remains serial.

Runs were serial on WSL/Linux, Node 24.7.0 with the local exnref shim, raw ABI and RC=0. Production sources and both generated SDKs were fixed before measurements; no compiler/test jobs ran alongside samples.

## Snapshot and typed merge regions

The [workload](lowering_inputs.vibe) checks 128 virtual providers plus an entry with default target flags. Each fresh process captures once, primes parsing, then measures one compatibility merge and one owned merge on identical checked inputs. Both execution orders have three samples. Full printed AST and equality channels are compared after each measured merge. Source setup/checking and output serialization are outside the regions. Capture includes validation and array copies. These are candidate-only measurements; the baseline has no owned API. The workload is a small virtual graph, not the full compiler closure.

| Region | Median allocated | Median wall |
| --- | --- | --- |
| Snapshot capture | 64,508 B | 386.5 µs |
| Compatibility typed merge | 1,765,242 B | 3,744.0 µs |
| Owned typed merge | 1,763,526 B | 3,856.5 µs |

Capture adds 64,508 B once for this graph. The owned merge allocates 1,716 B less than the compatibility call in this fixture, while its wall median is 112.5 µs higher. Short regional wall differences are advisory; no speed improvement or full-compiler memory reduction is claimed. Regional heap deltas measure cumulative bump allocation, excluding the static heap base. Four-byte order-dependent bookkeeping remains in both merge regions and cancels in their allocation difference.

## Filesystem integration

The standard compiler KPI and CLI corpora each have cold/warm samples from three fresh isolated cache pairs in AB/BA/AB order. Compiler, input root, cache and output use the same literal paths across lanes. The first matrix compiles each checkout’s own source with AST caching off; the second compiles the same candidate source with AST caching on and requires cross-compiler byte identity. Each revision uses its own pinned, fresh SDK for the own-source matrix.

| Source / AST cache | Corpus | Cache | Heap pointer baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own source / off | kpi | cold | 1,171,875,240 → 1,171,894,032 B | +0.0016% | 8.135 → 8.147 s |
| Own source / off | kpi | warm | 656,443,048 → 656,470,688 B | +0.0042% | 4.513 → 4.561 s |
| Own source / off | cli | cold | 2,535,819,192 → 2,537,938,192 B | +0.0836% | 17.663 → 17.526 s |
| Own source / off | cli | warm | 1,398,232,040 → 1,399,663,296 B | +0.1024% | 10.287 → 10.405 s |
| Same candidate / on | kpi | cold | 1,202,534,688 → 1,202,553,080 B | +0.0015% | 8.193 → 8.172 s |
| Same candidate / on | kpi | warm | 629,762,584 → 629,789,952 B | +0.0043% | 4.628 → 4.713 s |
| Same candidate / on | cli | cold | 2,597,188,888 → 2,597,220,128 B | +0.0012% | 17.709 → 17.857 s |
| Same candidate / on | cli | warm | 1,362,134,536 → 1,362,184,800 B | +0.0037% | 10.928 → 10.941 s |

All 24 same-source outputs are byte-identical across compilers. Own-source outputs are stable within each revision; CLI images can differ because the compiler source changed. Heap pointer includes the static heap base and cumulative bump allocation, not live heap, RSS or the CI selfcompile peak-memory metric. Timing is advisory and no speed improvement is claimed. The filesystem paths exercise the common compatibility pipeline, while the regional workload directly measures the new capture/owned API.

Compiler artifact: 5,672,386 → 5,676,714 bytes. Candidate stage2 and stage3 are identical (`c272331a0509275b4710d9bb986227ad76085776cc25a505ecc917a1e3c6a982`); both validate as Wasm. Raw receipts, compiler/image hashes, measured index trees and all 54 process samples are in [results.json](results.json). Report-only changes after measurement leave the production-input fingerprint unchanged.

## Correctness

The final new suite has nine source cases and ten harness tests, passing with AST caching off, on, and with RC plus AST caching on. Related AST-on and RC suites passed 63 and 28 harness tests respectively; these totals overlap the new suite. Coverage includes copy/reset isolation, complete-empty versus missing channels, source/fingerprint/context refusal, tag-7 identity and declined-placement rebasing, Alpha→Beta String/equality lowering, configured builtin shadows, reordered argument labels, shared call-cell cleanup, resident reuse and disk-warm FS publication. The bootstrap gate also runs the new suite against its own fresh stage2 with AST caching on.

Fifteen injected faults compile successfully, validate as Wasm, and fail at runtime: omitted capture fingerprint/source/context checks; borrowed offset/equality arrays or query result; omitted merge source/context or DB context validation; global lowering/equality unions or call restoration; stale call cells; and validation moved after metadata reset. Every production source is restored byte-for-byte. The serial alias-collision clone route uses the same owned provider query, but no new independently reachable clone-specific runtime case is claimed.

The baseline reproduction checks the same source under Alpha then Beta and observes missing String concatenation through the compatibility entry. It compiles/validates and fails at runtime with an explicit `owned-repro false` observation. The candidate reproduction captures before Beta and uses the new owned entry; it compiles/validates, observes `owned-repro true` and succeeds. This demonstrates the new retained-invocation contract; compatibility calls keep their existing serial lifecycle.

## Reproduction

```sh
python3 bench/perf/experiments/invocation-config-lowering-1953/measure_lowering.py \
  CANDIDATE_ROOT CANDIDATE_STAGE2 OUTPUT_REGION
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_OWN
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_SAME \
  --same-source --ast-cache 1
```

Stage inputs before using the filesystem driver; output directories must not exist. Regenerate each checkout’s SDK, pass explicit stage2 artifacts and keep runs serial. See the [regional driver](measure_lowering.py) and [filesystem driver](../invocation-config-1953/measure_own_source.py).
