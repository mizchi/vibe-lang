# Heap growth factor: 1/2 to 1/16 — 2026-11-08

Linear memory now grows by `max(deficit, memory_size / 16)` (#3931). Before
this change the factor was `memory_size / 2`. The factor is the same in three
places:

- the guest allocator (`emit_heap_memory_grow_check` in
  `lib/@vibe/compiler/codegen/wasm_emit/extra.vibe`);
- the Node host (`growHostMemory` in `scripts/wasm_vibe_host_runtime.js`);
- the Rust host (`ensure_vibe_memory_capacity` in
  `runtime/viberun/src/host_imports.rs`).

The exact-deficit retry near a capacity limit is unchanged.

## Why

**Reserved memory is what an isolate limit counts.** The reserved-page KPI
gates it, against the #2494 target of 128 MiB per package.

**At 1/2, reserved memory was a step function of the heap.** Each grow added
half the current memory, so memory sizes followed a ladder of ×1.5 steps. A
probe reserved up to 50% more than its heap. ADR-0120's acceptance
measurement showed the consequence. The KPI input's heap grew by 21.7%, from
16,107 to 19,609 pages. That crossed one step, from 18,663 pages to
18,663 + 9,331 = 27,994 pages, so reserved pages grew by 50.0%.

The same step makes the reserved-page gate misread changes:

- A heap change of a few percent that crosses a step trips the +10% gate.
- Growth of up to ~50% that stays inside a step moves pages by zero.

**At 1/16, the overshoot and the step are each at most 6.25%,** under the
gate's 10% tolerance. A grow is still geometric. The number of grows for a
compiler-sized heap rises from about 20 to about 100, far from the thousands
of 1–2 page grows that made exact-deficit growth spend 38% of the self-compile
in V8 GC (2026-07).

## Measurement

**Controls:**

- **A** is main `368fe52`: its tree, its stage2 and its host runtime.
- **B** is the same commit plus this change: tree, stage2 (rebuilt through
  stage1) and host runtime.
- Both trees are checked out at equal-length paths.
- Each run compiles cold through `scripts/selfcompile_kpi.sh`'s command, with
  an isolated empty `VIBE_BUILD_CACHE_DIR`.
- The runs alternate A/B on one otherwise idle machine.
- Pages and `heap_ptr` were identical in every trial of a side.

| Input | Heap, A → B | Pages, A | Pages, B | Change |
|---|---:|---:|---:|---:|
| selfcompile KPI (`codegen_lexer_test.vibe`) | 1,277,322,264 → 1,277,338,248 B | 27,994 | 20,376 | -27.2% |
| json probe | 15.7 MB | 324 | 252 | -22.2% |
| optimizer probe | 34.3 MB | 729 | 544 | -25.4% |
| parser probe | 124.6 MB | 2,458 | 1,922 | -21.8% |

The parser probe is under `target_pages` (2,048) for the first time. B's heap
for the KPI input is 15,984 bytes larger only because B's compiler sources,
which are that input's closure, carry this change.

**RSS does not follow reserved pages.** With A's stage2, pre-growing the same
compile to 40,000 pages, against 27,994 without pre-grow, left RSS at
1,402 MB against 1,409 MB. Across the A/B runs RSS stayed between 1.40 and
1.45 GB on both sides. This is a reduction in capacity, not in physical
memory.

**Wall time is unchanged within noise.** For the KPI input, the median of
eight alternating runs per side was:

- A: 11,638 ms (range 10,796–12,438);
- B: 11,843 ms (range 11,129–12,350).

That is +1.8%, inside the run-to-run spread. The probes were within ±10% in
both directions.

`bench/perf/reserved_pages_baseline.tsv` was rebaselined down to B's rows.
`bench/perf/heap_baseline.txt` is unaffected, because `heap_ptr` does not
depend on the growth factor.
