# Bounded post-wave context verification (2026-10-18)

The native lowering service now verifies its shared context using incremental SHA-256 and a **64 KiB fixed stack buffer**. It previously read the complete context into a Vec whose scope included product consumption. The initial preparation Vec was already moved into `fs::write` and freed before workers; it is not the buffer changed here.

All median wall changes are below the prespecified 5% noise threshold. The measurements establish **no whole-build speedup or peak-RSS improvement**. Four-process warm peak RSS is compiler 1039.3 → 1040.3 MiB and CLI 2717.1 → 2722.4 MiB; the sampled post-worker peak is also unchanged at this scale. This change bounds verifier scratch; it does not resolve the parallelism performance/memory blocker.

Verification still completes before product reads or callbacks, checks the original byte length and full raw-byte SHA-256, and reads at most the 64 MiB limit plus one sentinel byte. Short reads and `Interrupted` are handled; other I/O errors propagate. The caller still verifies its input snapshot first. Wire formats, ABI, guest heaps and execution defaults are unchanged.

The [raw record](../../../bench/perf/analysis/function-context-verification-2026-10-18.json) retains **144 unprofiled samples**: 12 fresh before controls followed by 132 fresh interleaved comparisons, including 12 identical-before A/A samples. All outputs match their ordinary reference; all 12 A/A guest-memory pairs match exactly. [Archived drivers and receipts](../../../bench/perf/experiments/function-context-verification-2026-10-18/README.md) retain reproduction commands, source/image authority, every sample, phase/PID observations and detecting negative-control evidence.

## Scope and protocol

The engine source base is `8f7f95477ded1dc62d743d900a8635e7fdccaed2`, tree `aebd073fc64089ccf15b140596d2755fcfc33a40`. Only `runtime/viberun/src/lowering_service.rs` and `scripts/test_taskgroup_functions.py` differ in the measured overlay. All compiler/library sources and generated inputs are unchanged. The existing current compiler has stage2 == stage3; all three worker images were rebuilt and are byte-identical. Each lane uses its actual selected native runner hash in its build receipt. Later reporting and archive additions do not relabel the samples as a different Git-head measurement.

Compiler SHA-256: `9715fe9d46cec3181b252750d19ba8755f7e1334ba2a2ff0faa44ea27e8b911b`. Before runner: `b9e5e4dce33d3f42c73c0b5858d7862237260069a3a52edd3cb010228da53e66`; after runner: `05e073e416d9117044d2c035069557048407011306cd5f8cec82d4cdb53ab97d`. Guest parent/worker remain bump, coordinator RC, emitted target RC1; context6/job2 and callback ABI2 remain unchanged.

The target is the same frozen `eeba680337dae422362c465439bd60f5d53da040` filesystem compiler/CLI corpus used by the preceding decoder experiment. This preserves workload continuity; it is **not a new actual-bootstrap comparison**. The current bootstrap emits targetRC0 and does not select this process-worker emitter. No native thread backend is exercised.

Reference host: Ryzen 7 7700, 16 logical CPUs, 64 GiB WSL2/ext4, Node 24.7.0. There are three rounds per configuration, cold then warm with fresh processes and private parsed-source caches; pair order reverses in the middle round. Lane/cache/output paths have equal lengths. Native JIT is primed on another input; OS pages remain warm. Checked-module,body and final-artifact caches are off. No other builds, profiles or source edits overlap the measurements.

## Whole-build observations

Medians, N=3, before → after. Min/max and all raw samples remain in the record. `o0` is ordinary, `s0` the same parent with serial emission, `p1/p2/p4` public process workers. RSS is the maximum simultaneous process-tree sum at 20 ms sampling intervals; shared mappings may count repeatedly. It is not guest allocation volume, reserved pages or a sum of independent child maxima.

| Corpus / route | Cold wall,s | Warm wall,s | Cold peak RSS,MiB | Warm peak RSS,MiB |
| --- | ---: | ---: | ---: | ---: |
| compiler / o0 | 6.173 → 6.054 | 4.161 → 4.128 | 1123.5 → 1124.3 | 646.4 → 647.0 |
| compiler / s0 | 6.464 → 6.409 | 4.339 → 4.273 | 1173.8 → 1173.6 | 697.0 → 696.9 |
| compiler / p1 | 7.784 → 7.869 | 5.436 → 5.336 | 1414.8 → 1414.3 | 932.4 → 934.3 |
| compiler / p2 | 7.382 → 7.388 | 4.972 → 5.039 | 1438.9 → 1436.7 | 950.3 → 958.4 |
| compiler / p4 | 7.244 → 7.055 | 4.765 → 4.811 | 1513.7 → 1510.4 | 1039.3 → 1040.3 |
| split-cli / o0 | 16.849 → 16.749 | 12.046 → 12.043 | 2985.9 → 2985.8 | 2032.0 → 2031.8 |
| split-cli / s0 | 16.720 → 16.836 | 12.377 → 12.300 | 3039.9 → 3038.7 | 2086.4 → 2086.3 |
| split-cli / p1 | 20.681 → 20.698 | 15.637 → 15.291 | 3243.9 → 3243.8 | 2290.8 → 2290.6 |
| split-cli / p2 | 19.870 → 19.890 | 14.397 → 14.349 | 3343.5 → 3345.8 | 2393.4 → 2389.6 |
| split-cli / p4 | 19.664 → 19.675 | 14.087 → 14.073 | 3668.4 → 3661.6 | 2717.1 → 2722.4 |

The candidate remains slower and uses more simultaneous RSS than its contemporaneous ordinary control. All median before/after wall changes are within −2.60% to +1.33%, with mixed paired directions. No default promotion is justified.

## Post-wave phase observations

The verifier no longer creates a context-sized host Vec. Context wire lengths are 2,936,061 bytes for compiler and 44,990,116 bytes for CLI. These lengths are not measured Vec capacities or promises of equal RSS savings. The sampled interval below starts after the last observed worker sample and includes verification, product handling and finalization. Its boundaries are quantized; it does not isolate verifier allocation or exact cleanup time.

| Corpus | Cold after-workers peak RSS,MiB | Warm after-workers peak RSS,MiB |
| --- | ---: | ---: |
| compiler | 1344.9 → 1345.1 | 861.0 → 867.3 |
| split-cli | 3275.9 → 3275.6 | 2322.8 → 2323.0 |

## Correctness and limits

Ten lowering-service module tests pass, including five new tests for all raw bytes across chunk boundaries, same-length edits, truncation/extra bytes, exact 64 MiB acceptance, oversized inputs, fixed read requests, short reads, repeated `Interrupted`, and partial I/O errors. An isolated buffered-reference implementation compiled successfully then failed the actual bounded-read test with `context read request exceeds 64 KiB`. The read-request test guards this buffering regression; the fixed scratch allocation follows from the verifier source.

The public function suite passes all seven semantic cases at jobs 1/2/4, byte parity and execution, receipt/ABI checks and failure/output protection. New probes mutate, shorten or append the real shared context after successful workers and delete the first product: the required context-refusal diagnostic proves rejection precedes product reads, and prior output survives. The complete lowering suite also passes 1/2/4, bounded multi-wave work, input freshness, aliases and protected output.

#3483 stays open: parent lowered plans, guest packet/decoded-product buffers, merge/replay scratch and the CLI literal pool remain. This change does not reclaim a bump frontier or supply threads. #3484 owns native threads, #3485 actual targetRC0/stage/install integration, and #3486 the whole-build promotion gate. The route remains opt-in.

## Integration validation after #3502

After these measurements, main advanced to `8f999be77878bb2119cbf9c1f2fb944012ed51f1` with #3502 and context format 7. The implementation branch was rebased cleanly, preserving the measured native verifier byte for byte. A fresh source-bound generation and all three worker images were built with the updated compiler. Stage2 == stage3, all ten Rust module tests, the full public function suite at jobs 1/2/4 (including context mutation/short/extra refusal before product reads), and the full bounded-wave lowering suite pass again.

The new compiler SHA-256 is `8a3f1b2e14898710e0c911e8211ac398358f76b9f0acf239c5c7aad882dc7457`. Its image receipt uses context 7/job 2 and callback ABI2, with the selected runner `05e073e416d9117044d2c035069557048407011306cd5f8cec82d4cdb53ab97d`. [Separate integration proof](../../../bench/perf/experiments/function-context-verification-2026-10-18/current-main-validation.json) and compressed source authority retain every producer/image hash and all eight successful steps. The 144 historical samples above remain scoped to the original context6 engines on `8f7f95477`; they are not timings of these updated images. Required release-check, normal-hook and exact-head CI/review outcomes belong to the implementation PR.
