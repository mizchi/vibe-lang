# Inline-WAT representation isolation (#1953)

Baseline: `eb11670de200115bf49307d141ec138cef7710bc` (merged #4007).
The candidate removes the representation cell and carries an immutable Bool in
its per-assembly traversal state. Codegen supplies its own `enable_rc`;
standard assembler and type-validation entries use tagged Ints.

Both compilers consumed the same candidate source. Four rounds alternate AB/BA,
with equal-length compiler, output and cache paths and no concurrent local
compiler/test jobs. The filesystem CLI corpus uses a fresh persistent cache per
lane/round, then a second fresh-process warm compile. The flat selfbuild corpus
has persistent artifact caching disabled: its cold/warm labels in the receipt
are two repetitions, not cache temperatures. The identical harness passed an
A/A CLI control in the preceding #4007 slice.

| Corpus | Median wall: baseline → candidate | Raw heap pointer: baseline → candidate |
| --- | --- | --- |
| Flat compiler selfbuild | 40.042 → 39.822 s | 3,455,784,460 → 3,455,784,428 B |
| CLI cold | 18.448 → 18.265 s | 2,453,421,728 → 2,453,415,344 B |
| CLI warm | 10.086 → 10.103 s | 1,402,682,176 → 1,402,679,608 B |

Wall differences are within about ±1%; this is configuration isolation with
roughly unchanged performance. Heap pointers include static data and cumulative
bump allocation, rather than live RC heap, RSS or CI peak memory. All 32 outputs
match within their corpus. Candidate stage2 and stage3 also match.
[results.json](results.json) retains every sample and artifact/output digest.

## Reproduction inputs

Build both revisions with the pinned seed and `scripts/generations.sh build
--stage3`; regenerate the candidate SDK before freezing its source. Use each
explicit stage2 as `COMPILER`, at equal-length paths. These are the individual
compile commands; repeat in the order and cache protocol above, recording
monotonic walltime and the runner's `heap_ptr` line. Use a clean environment
without inherited `VIBE_*` overrides.

```sh
# Flat compiler: no persistent artifact cache; two repetitions per lane/round.
VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_RC=0 VIBE_IMPORT_ABI=raw \
VIBE_PREOPEN_DIR="$PWD" VIBE_FS_COMPILE=0 VIBE_WASM_MEMORY_STATS=1 \
VIBE_NODE_STACK_SIZE=131072 VIBE_SKIP_RUN_INIT=1 \
VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE=1 VIBE_BUILD_CACHE_DIR="$CACHE" \
bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
  lib/@vibe/compiler/_cli_adapter_module_source.vibe "$OUTPUT" cli_main

# CLI: fresh CACHE per lane/round, reused for its warm invocation only.
VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_RC=0 VIBE_IMPORT_ABI=raw \
VIBE_PREOPEN_DIR="$PWD" VIBE_FS_COMPILE=1 VIBE_WASM_MEMORY_STATS=1 \
VIBE_BUILD_CACHE_DIR="$CACHE" \
bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
  lib/@vibe/cli/main.vibex "$OUTPUT" main
```

Regression: the current-main stage2 passes the standard tagged control but fails
both same-process leak probes, after successful and failed bump codegen.
The candidate passes all four cases, including alternating explicit tagged/raw
assemblies. Related compiler tests pass (4 files / 69 harness exports), as do
the runtime Int conversion fixture on both allocator lanes and the full
inline-WAT runtime fixture on its supported tagged/RC ABI.
