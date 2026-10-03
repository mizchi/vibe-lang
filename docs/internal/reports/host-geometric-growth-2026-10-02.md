# Host geometric memory growth — 2026-10-02

Host-produced strings and bytes previously extended linear memory by their exact
page deficit. The guest allocator instead grows by at least half its current
capacity. Interleaving the policies changes the base of later guest growth;
small metadata/path differences can therefore change final reserved capacity.

The Node and Rust hosts now use `max(deficit, floor(current_pages / 2))` for
allocation growth. A rejected preferred request retries the exact deficit, so a
module maximum or native store limit can still admit a fitting allocation. An
unsatisfiable request retains the original failure without advancing the heap.
Node preserves non-capacity errors. Explicit Node pre-grow remains an exact
target. Alignment, heap addresses, raw string packing, byte headers and payloads
are unchanged. The Node helper stays inside the existing runtime file, including
in the trusted Docker script package; no new runtime import or export is added.

## Controlled comparison

Both lanes use the same frozen compiler from #3289
(`2f9d0bf0708761ce86cc6999babbdf506d57676f246929c0fd1628438bc88775`).
The candidate runtime is the exact integrated Node source, measured before
committing. Three alternating AB/BA pairs per corpus produce 54 samples on an
otherwise idle local machine. Flat builds have persistent guest caches disabled;
every FS cold run starts with an isolated empty cache, followed by a warm run in
a fresh process. Compiler/cache/output paths have equal lengths between lanes.
All outputs match within each corpus; paired heap frontiers and host allocation
cursors match for every temperature. Source/artifact/HEAD guards pass.

| Corpus | Exact-growth median | Geometric median | Wall delta | Reserved memory |
| --- | ---: | ---: | ---: | ---: |
| flat/uncached | 17.760 s | 17.572 s | -1.06% | 2575.50 → 2575.50 MiB |
| fs/cold | 4.656 s | 4.743 s | +1.87% | 1166.44 → 1166.44 MiB |
| fs/warm | 2.941 s | 2.929 s | -0.39% | 538.00 → 518.44 MiB |
| json/cold | 0.345 s | 0.341 s | -1.14% | 13.50 → 13.50 MiB |
| json/warm | 0.298 s | 0.299 s | +0.28% | 13.50 → 13.50 MiB |
| optimizer/cold | 0.405 s | 0.404 s | -0.21% | 30.38 → 30.38 MiB |
| optimizer/warm | 0.341 s | 0.345 s | +1.09% | 20.25 → 20.25 MiB |
| parser/cold | 1.207 s | 1.198 s | -0.72% | 102.44 → 102.44 MiB |
| parser/warm | 1.030 s | 1.040 s | +0.99% | 68.31 → 68.31 MiB |

FS warm reserved memory falls by 20,512,768 bytes (19.56 MiB,
-3.64%), with identical heap/output. Other tested
capacities are unchanged. All median wall deltas are within 2%; no speedup is
claimed. RSS remains advisory: this is a capacity reduction, not an allocation
or physical-memory saving. JSON, optimizer and parser are the package probes
from #2509; this change does not complete its KPI ratchet or live-bytes scope.

The earlier helper-routing prototype used a different harness prefix and showed
585,170,944 → 543,621,120 warm bytes; the final comparison shows
564,133,888 → 543,621,120. The exact-growth baseline is path-sensitive, while
both geometric runs finish at 8,295 pages. Each experiment controls path length
inside its own pair. Its baseline is not interchangeable with the other's.

## Correctness and timing audit

The production task executes 15 Node tests through existing public host entry
points and five native release tests through actual Wasmtime import callbacks
(20 native matrix cases). Coverage includes i32/i64 raw heaps, UTF-8 strings,
byte headers/payloads, preserved old memory, declared maxima, native store caps,
failed growth and fitting allocations. Node also covers Preview2 stream reads,
raw arena allocation, zero initial capacity, exact dominant deficits and
unchanged pre-grow. An isolated native full unit run passes 43 tests; restoring
exact growth makes the geometric-capacity regression fail before the candidate
passes again. The task is in local release-check and the CI mid lane.

The first Node routing variant showed parser-warm +5.41% median wall, and a
separate five-pair repeat showed +3.38% (+0.78% median paired). Five A/A pairs
measured same-source warm pair variation from -2.55% to +2.66%. A further
24-run diagnostic times runtime loading, instantiation, the export invocation
and host grows; its six warm traced runs make zero host grows, and tracing and
restoration preserve output/heap/capacity. There is no consistent startup or
instantiation increase. The final Node implementation retains the original
allocator calculations and checks, replacing only four growth calls; its parser
warm median is +0.99%. Those diagnostics are excluded from the controlled wall
comparison. The original results remain in the raw record.

Full release-check passes: 122 tasks (13 cached, 109 run) in 44m05s. The gated stage2 hash matches the frozen measurement compiler; producer, test and runner hashes and the staged snapshot are unchanged through the gate. Final AST-required staged pre-commit passes.

## Raw evidence

`bench/perf/analysis/host-geometric-growth-2026-10-02.json` records all final
54 samples, commands, cache flags, paired memory/output hashes, source receipts,
test evidence and the timing audit. Local replay scripts/artifacts are under
`_build/effect-row-local-index-main/next-host-growth-node/`; replay requires fresh
cache/output directories and the recorded artifact. The Node preload substitutes
the runtime source at its original filename, keeping worker/module resolution
unchanged. It is a measurement tool, not product code.
