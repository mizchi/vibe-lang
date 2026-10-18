# String-layout fingerprint batching (2026-10-18)

Four-byte Horner batches reduce the measured CLI function-worker range cost by **9.0–13.5%** across its four captured ranges. The persisted dual-modulus fingerprint is byte-identical. This is a CPU optimization: all captured-range guest-memory counters are unchanged. The complete fixed-corpus compiles show **no established walltime or peak-RSS improvement**; every median wall change is inside the prespecified 5% noise threshold. Parallelism remains opt-in.

The [analysis](../../../bench/perf/analysis/string-layout-batches-2026-10-18.json) retains N=3 medians, min/max and paired changes. The [archive](../../../bench/perf/experiments/string-layout-batches-2026-10-18/README.md) contains 1,057 verified raw records, exact executed drivers, source/engine authorities, profiles and detecting negative-control logs. It preserves original bytes, including whitespace and EOFs.

## Change and correctness

`bcc_fp_string` previously applied two remainder operations after each byte. It now performs four Horner steps before each remainder, then consumes the remaining zero to three bytes with the existing scalar loop and appends the same separator. With normalized accumulators, even the larger dividend is below `2^31 * 137^4 + 2^30 < 2^60`, inside the tagged Int range. A fifth unreduced step can overflow. The count encoding, separators, slot order, cache/wire formats and validation remain unchanged.

The existing persisted-value oracle and an independent per-byte scalar oracle pass on 2,088 substring/length cases covering every byte value, unaligned starts and every batch tail. Empty strings, NUL/non-UTF-8 bytes, Unicode, long strings, prefix limits, repeated values and consecutive output slots are covered. Bump, RC and shadow binaries pass on both Node and native hosts. A source-overlay mutant using five unreduced steps compiles on bump and RC, then fails the actual substring/byte test; its failure occurs in that test block, not at compilation.

The candidate compiler is rebuilt through stage3 and stage2 == stage3. All 33 body-cache persistence, edit-class and replay tests and the real public function-worker semantic/receipt/failure suite pass. GC runs the exact extracted fingerprint definitions plus the complete scalar/legacy tests on Node and Wasmtime. The full original common_base import graph fails GC instantiation with an out-of-bounds active data segment on unmodified main, and the expanded candidate graph fails likewise. Separate controls retain both failures; [#3512](https://github.com/mizchi/vibe-lang/issues/3512) owns that pre-existing defect. The extracted algorithm probe does not establish full-graph GC support.

## Provenance and measurement scope

The engine base and frozen input corpus are main `403d735929db48325c23252630725a0d16b5ab69`, tree `b65ec2641871d81c22e5a66f41769e15a64315c7`. The measured candidate overlay changes only the fingerprint implementation and its test file. Later documentation, archive, reproduction-helper integrity checks and mutation-gate path fixes do not relabel the timings as a different Git-head experiment. The required release-check exposed the mutation gate passing a relative compiler path after changing into a temporary project; its driver now anchors both selected executables before that change of directory, and the existing end-to-end suite passes with relative compiler/runner overrides. All five generated target inputs are frozen and hashed. Both compiler producers have a verified fixpoint.

Before compiler SHA-256: `bd1c73455658d7957e6aefd8a0f4e83790a7f0d35a13de2563a9761b5ca053a4`. Candidate: `8ea387b844fa6accd85ec2ea746c18de2903a047bc4d35b20a5188bac7232ca4`. The native runner is unchanged: `8c52776ac4ea68642facac11c8da5d5df4a33fe2f423943a4c83eaab6bbd55cc`. Individual image hashes, source hashes and producer manifests are retained in the archive. Parent/worker engines use bump allocation; the coordinator uses RC; the emitted target is RC1, with context7/job2 and callback ABI2.

These are fixed filesystem compiler/CLI compiles and separate native processes. Actual selfbuild emits target RC0; this experiment does not time that bootstrap pipeline or execute native threads. Required stage/install and thread integration remain separate roadmap work.

The reference host is Ryzen 7 7700, 16 logical CPUs, 64 GiB WSL2/ext4, Node 24.7.0. Before editing, 72 current-main uninstrumented controls and 30 separate diagnostic profiles established the baseline. The before/after matrix then runs 132 fresh interleaved samples: ordinary A/B plus identical-before A/A, same-driver serial, and process jobs 1/2/4, three cold/warm rounds each. Pair order reverses in the middle round; cache/output/image paths have equal lengths. Parsed-source caches are private and cold then warm; checked-module/body/final-artifact caches are off. Native JIT is primed on another input; OS pages are warm. No source edits, other builds or CPU profiles overlap the timings.

All 132 outputs match their ordinary reference; all 12 A/A guest-memory pairs match exactly. Engine, input, source and driver hashes remain unchanged. Peak RSS is the maximum simultaneous process-tree sum at 20 ms intervals; shared mappings may count repeatedly. It is separate from guest allocation/frontier, reserved pages and a sum of independent child maxima.

## Complete fixed-corpus compiles

Medians, N=3, before → after. Full spread, paired directions and phase observations are in the analysis. Independent phase medians must not be summed.

| Corpus / route | Cold wall, s | Warm wall, s | Cold peak RSS, MiB | Warm peak RSS, MiB |
| --- | ---: | ---: | ---: | ---: |
| compiler / o0 | 6.167 → 6.246 | 4.150 → 4.150 | 1125.3 → 1124.8 | 647.7 → 647.2 |
| compiler / s0 | 6.420 → 6.343 | 4.275 → 4.336 | 1179.9 → 1175.5 | 697.8 → 697.7 |
| compiler / p1 | 8.055 → 7.862 | 5.414 → 5.412 | 1415.0 → 1413.4 | 935.5 → 939.5 |
| compiler / p2 | 7.524 → 7.526 | 5.014 → 4.990 | 1435.4 → 1443.5 | 962.0 → 961.3 |
| compiler / p4 | 7.301 → 7.253 | 4.845 → 4.766 | 1517.7 → 1518.0 | 1042.1 → 1035.0 |
| split-cli / o0 | 16.848 → 16.727 | 12.167 → 12.135 | 2994.3 → 2993.4 | 2038.0 → 2037.8 |
| split-cli / s0 | 17.175 → 16.900 | 12.470 → 12.276 | 3048.4 → 3048.5 | 2092.0 → 2092.1 |
| split-cli / p1 | 21.021 → 20.696 | 15.503 → 15.206 | 3251.4 → 3252.7 | 2297.1 → 2297.2 |
| split-cli / p2 | 20.092 → 19.715 | 14.584 → 14.310 | 3351.6 → 3355.5 | 2405.4 → 2402.7 |
| split-cli / p4 | 19.642 → 19.429 | 14.150 → 14.037 | 3679.8 → 3675.2 | 2721.0 → 2730.5 |

`o0` is ordinary, `s0` the same parent with serial emission, and `p1/p2/p4` the public process route. All median wall changes lie between −2.39% and +1.43%, with mixed paired directions. The candidate still loses to its contemporaneous ordinary route: warm process4 takes 4.766 versus 4.150 s for compiler and 14.037 versus 12.135 s for CLI. Its sampled RSS also exceeds the ordinary control. The promotion budgets are not met.

## Isolated worker attribution

After the complete matrix, 48 uninstrumented serial A/B replays use the exact eight real coordinator ranges captured from the baseline. Each configuration has three fresh worker processes, alternating order; native JIT is already primed. Workers do not load/check source or consult parsed-source caches, so these are range costs rather than cold/warm bootstrap measurements. All products match the original captured bytes. Every guest-memory counter, including allocated bytes, heap base/frontier, reserved bytes and pages, is unchanged in every matching range.

| Captured range | Before wall, s | After wall, s | Change |
| --- | ---: | ---: | ---: |
| compiler / 0 | 0.2900 | 0.2704 | -6.76% |
| compiler / 1 | 0.3905 | 0.3926 | +0.52% |
| compiler / 2 | 0.3418 | 0.3419 | +0.03% |
| compiler / 3 | 0.6084 | 0.5876 | -3.42% |
| split-cli / 0 | 1.1290 | 0.9802 | -13.18% |
| split-cli / 1 | 1.2429 | 1.1027 | -11.28% |
| split-cli / 2 | 1.4559 | 1.3246 | -9.02% |
| split-cli / 3 | 1.1056 | 0.9560 | -13.53% |

Do not sum these medians or substitute them for concurrent worker-wave or whole-build walltime. Compiler range changes are mixed; the four CLI ranges consistently improve.

48 further guest CPU profiles replay the same ranges, three per range and lane, after every uninstrumented replay has finished. All products still match. Pooled CLI `bcc_fp_string` inclusive samples fall from 1,378/9,110 (15.13%) to 641/8,403 (7.63%); self samples fall from 14.95% to 1.00%. Inclusive parents overlap, and attribution can move into callees, so the uninstrumented range timings and inclusive share are the useful cross-checks. Guest samples exclude host work and are not wall-clock measurements.

## Remaining bottlenecks and rollout

CLI context restoration still consumes 30.80% inclusive guest samples after the change; UTF-8 span validation is 14.30% inclusive, string-table construction 8.97%, and string hashing across all callers 14.08%. These overlap. Their sample counts remain similar while the fingerprint share shrinks. The CLI shared context is 45,110,806 bytes, including 39,359,150 literal payload bytes, which each isolated worker restores. Wire sizes are not an equal amount of live memory or a promise of RSS savings.

Parent preparation/live-set, repeated literal decoding/indexing, packet/product lifetime and canonical merge/replay still require measured work in #3483. The source-bound baseline records separate phase and memory observations for that selection. Native threads belong to #3484; actual target-RC0/stage/install integration to #3485; default promotion to #3486. This change supplies neither a whole-selfbuild speedup nor a memory reduction, and does not close #3483.

## Required integration checks

Local release-check, normal commit hooks and exact-head hosted CI/review are recorded on the implementation PR when completed. The targeted checks and fixpoint above are completed evidence, not a substitute for those required gates.

## Integration after runtime helper trimming

After measurement, the branch was integrated with main `6406ca9f6df1081a5ef40244b2fc6fe3d892474a` (#3514). A fresh source-bound compiler and all three matching worker images were rebuilt. Stage2 == stage3; fingerprint tests pass on bump, RC and shadow, including native execution of the shadow artifact. All 37 tests in the three cache regression files plus the runtime-trim file, the real public worker suite at jobs 1/2/4 and its receipt/failure probes, and the complete mutation suite with relative compiler/runner overrides pass.

Current compiler SHA-256: `770568c265d19a9ca1e06f29dad70a496f0589e786388b5292b45cbbc0144869`. [Separate integration proof](../../../bench/perf/experiments/string-layout-batches-2026-10-18/integration-6406/validation.json) retains every step and producer; compressed source authority, generation, image receipts and logs are adjacent. New emitted runtime bytes are compared against contemporaneous ordinary output. The 403d performance samples remain historical; they are not retimed or relabelled as measurements of this integrated source. The initial failed release-check and its relative-path error are retained separately, and final required gate results belong to the PR.
