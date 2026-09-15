# Wasm data-section reservation — 2026-09-16

The data-section writer reserves one buffer from the sum of payload lengths
plus an upper bound on framing: five bytes for the vector count and thirteen
per wasm32 segment. It reserves estimated sections of at least 1 KiB, up to
`Bytes::with_capacity`'s limit of 1,073,741,816 bytes. Smaller and larger sections
use the existing growable allocation. The public writer signature is unchanged.

Implementation: [builders.vibe](../../../lib/@vibe/compiler/codegen/wasm_emit/builders.vibe).
The existing seed supports the Bytes allocator; this change needs no seed bump.

## Local wall-time measurements

Apple M5, Node v24.21.0, macOS arm64. The compiler binaries retain Wasm names and use bump allocation;
the full-build outputs target linear RC. Baseline source: `d92802abef34c06be145149acabc314473ad721f`.
Candidate implementation: `f03d391cb0e2ab415fca776846a56e148a5418cd`. Artifact hashes, source hashes,
raw samples and the exact build selectors are in [the measurement data](compiler-data-reservation-2026-09-16.json).

The [opt-in benchmark](../../../bench/regression/data_buffers_bench.vibe) puts a
growing reference and the production writer in **the same Wasm**. Both variants
run the same module setup before timing, so their initial guest heap layout and
runtime code agree. Each sample uses a fresh process, 20 warmup batches and 200
measured batches; 12 pairs alternate execution order. Small cases batch 1,000
operations, the 1 KiB case 64, the 8 KiB case 32, and the 128 KiB case eight.
Inputs are prepared before timing. Each section contains four equal segments.
The table gives medians per section, including amortized runner invocation cost.

| Payload | Growing reference | Reserved writer | Change |
| --- | ---: | ---: | ---: |
| 128 B | 0.134 µs | 0.135 µs | +0.6% |
| 1 KiB | 0.395 µs | 0.351 µs | -11.2% |
| 8 KiB | 2.041 µs | 1.778 µs | -12.9% |
| 128 KiB | 20.614 µs | 17.787 µs | -13.7% |

The two unchanged string-conversion controls differ by -1.7% and -0.1%.
The small-section difference is about one nanosecond; the useful result is the
11–14% improvement at 1–128 KiB. The setup also checks byte equality with the
reference at all four sizes. The benchmark is opt-in and adds no tracked CI series.

## End-to-end confirmation

Both artifacts compile identical checkout inputs. Each pair has an empty,
isolated cache for cold compilation and reuses only its own populated cache
for warm compilation. Processes are fresh; paths have equal lengths; A/B order
alternates. Generated Wasm must match across compilers and cache temperatures.
The OS file cache is uncontrolled.

| Corpus / cache | Pairs | Baseline median | Candidate median | Median paired change |
| --- | ---: | ---: | ---: | ---: |
| closure / cold | 12 | 2.118 s | 2.103 s | -0.58% |
| closure / warm | 12 | 1.473 s | 1.475 s | -0.86% |
| cli / cold | 6 | 5.130 s | 5.100 s | +0.05% |
| cli / warm | 6 | 3.995 s | 3.965 s | +0.00% |

These full-build differences do **not** establish an end-to-end speedup.
Concurrent local work made earlier short runs unstable, including an apparent
5–7% closure regression that did not persist in the 12-pair confirmation.
An eight-pair same-artifact calibration gave -0.79% cold and +0.66% warm median
paired changes. The largest observed Liftoff workspace stayed at 121,801,256 bytes
(72,175-byte function body) on both artifacts.

Validation: stage2 equals stage3; 31 related tests pass. A 40,960-byte UTF-8 and
NUL-containing literal produces byte-identical linear-RC and GC modules across
the two compilers, and both backends verify every byte at runtime. Rebuilding
the microbenchmark with the final compiler reproduces the measured Wasm exactly.

## Reproduce

Compile the benchmark once with the candidate compiler, then alternate the two
exports of that **same** artifact. For the 128 KiB case:

```bash
VIBE_PREOPEN_DIR="$PWD" VIBE_LIB="$PWD/lib" VIBE_FS_COMPILE=1 \
VIBE_IMPORT_ABI=raw VIBE_RC=0 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
  bench/regression/data_buffers_bench.vibe /tmp/data-buffers.wasm __no_entry__

VIBE_PREOPEN_DIR="$PWD" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke __bench_growing_data_4x32_kib_batch_8 \
  --bench-count 200 --bench-warmup 20 --bench-setup _start /tmp/data-buffers.wasm
VIBE_PREOPEN_DIR="$PWD" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke __bench_data_4x32_kib_batch_8 \
  --bench-count 200 --bench-warmup 20 --bench-setup _start /tmp/data-buffers.wasm
```

The runner prints total microseconds. Divide by 200 × 8 for microseconds per
section. The full-build harness is
[scripts/compare_compiler_memory.mjs](../../../scripts/compare_compiler_memory.mjs);
use its `full` suite for the closure and CLI together.
