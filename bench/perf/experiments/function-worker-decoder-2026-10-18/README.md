# Function-product decoder experiment (2026-10-18)

The [report](../../../../docs/internal/reports/function-worker-decoder-2026-10-18.md) and [raw record](../../../../bench/perf/analysis/function-worker-decoder-2026-10-18.json) bind the measured source and images. These are historical reproduction commands, not a latest-main promotion gate. All builds, tests, unprofiled measurements and diagnostics run sequentially.

Use Python 3.12+, Node 24.7.0, the repository Rust runner and the pinned seed. Start from a fresh checkout of `eeba680337dae422362c465439bd60f5d53da040`; retain a copy of this directory outside that checkout as `decoder_archive`. The original source archive hash is in the record. Keep before/after paths the same length and run on an idle machine. Do not reuse populated experiment output directories.

## Corrected-digest baseline

Run from the fresh checkout root. These commands produce 12 actual bootstrap and 72 route-matrix samples, with N=3 cold/warm. The actual bootstrap emits target RC0; the separate filesystem worker corpus emits target RC1. This base includes corrected bump BLAKE3 and ABI2; the old metadata experiment's wire4/receipt3 or incorrect-digest observations are not relabelled here.

```sh
set -e
bash scripts/ensure_seed.sh
bash scripts/ensure_viberun.sh
decoder_lab=_build/function-worker-parent-memory-3483-20261018
python3 bench/perf/selfbuild_baseline.py prepare "$decoder_lab/baseline" --ref eeba680337dae422362c465439bd60f5d53da040
python3 bench/perf/selfbuild_baseline.py clock "$decoder_lab/baseline"
python3 bench/perf/selfbuild_baseline.py bootstrap "$decoder_lab/baseline" --rounds 3
python3 bench/perf/selfbuild_baseline.py images "$decoder_lab/baseline"
python3 bench/perf/selfbuild_baseline.py matrix "$decoder_lab/baseline" --rounds 3
python3 "$decoder_archive/baseline_diagnostics.py" "$decoder_lab" "$decoder_archive"
```

`baseline_diagnostics.py` is a reproduction convenience wrapper supplied after measurement. It executes the unchanged `selfbuild_profiles.py` parents/workers/memory/summarize commands, then the exact archived control and before-phase drivers. Completion markers are written only after the corresponding commands succeed. The raw record retains the actual original profile/control/phase observations and their hashes.

## Exact candidate and comparisons

Apply the measured tracked-file patch and copy the two new tests from `untracked/`. The patch deliberately excludes the later report/archive files. New test contents and all relevant source/generated files are separately bound by the candidate build authority.

```sh
set -e
gzip -dc "$decoder_archive/measured-implementation.patch.gz" > "$decoder_lab/measured-implementation.patch"
git apply "$decoder_lab/measured-implementation.patch"
cp -R "$decoder_archive/untracked/lib/." lib/
bash scripts/ensure_generated.sh
mkdir -p "$decoder_lab/decoder-candidate"
cp "$decoder_archive/build_validate.py" "$decoder_lab/decoder-candidate/build_validate.py"
python3 "$decoder_lab/decoder-candidate/build_validate.py"
printf '0\n' > "$decoder_lab/decoder-candidate/pipeline.exit"
cp "$decoder_lab/decoder-candidate/source-overlay.patch" "$decoder_lab/decoder-candidate/images/source-overlay.patch"
cp "$decoder_lab/decoder-candidate/build-authority.json" "$decoder_lab/decoder-candidate/images/source-authority.json"
cp "$decoder_archive/compare.py" "$decoder_lab/decoder-candidate/compare.py"
python3 "$decoder_lab/decoder-candidate/compare.py" stage "$decoder_lab/baseline" "$decoder_lab/decoder-candidate/images" "$decoder_lab/decoder-candidate/generation/stage2.wasm" "$decoder_lab/decoder-candidate/comparison"
python3 "$decoder_lab/decoder-candidate/compare.py" run "$decoder_lab/baseline" "$decoder_lab/decoder-candidate/images" "$decoder_lab/decoder-candidate/generation/stage2.wasm" "$decoder_lab/decoder-candidate/comparison" --rounds 3
printf '0\n' > "$decoder_lab/decoder-candidate/comparison.exit"
python3 "$decoder_archive/parent_phase_probe_after.py" "$decoder_lab"
```

Stop on any failed command (`set -e` in a reproduction shell); the success markers above belong only to successful commands. Copy `build_validate.py` into the ignored lab before running it: it locates outputs relative to itself. It binds sources throughout generation, unit/native/GC/negative controls and image building; its own `complete=true` and step results are the actual build proof. Every selected compiler must prove stage2 == stage3 and every image receipt must match its producer and runner.

`compare.py` checks all 132 output hashes against the original ordinary reference. There are 120 alternating A/B builds over ordinary, same-driver serial and process workers 1/2/4, plus 12 identical-before-compiler ordinary A/A controls. New processes, private per-round parsed-source caches, cold then warm, equal path lengths and reversed pair order control the comparison. All twelve A/A guest-memory pairs must match exactly. Native code is primed on another input. Simultaneous process-tree RSS is sampled every 20ms; shared mappings can be counted repeatedly. Final artifact/source/image/input checks must succeed before `verified_complete` is set.

## Diagnostic-only heap observer

The before/after phase drivers compile an isolated parent-entry copy, preserving the Exception-only executor callback. The only post-build Wasm change replaces a validated exported `i64.const0` marker body with a read of the exported mutable i32 heap global, using the caller's Int1 representation. All other function bodies and section payloads remain unchanged. Main explicitly grants the real Profiler and requires its value to equal the observer. Native raw heap_peak independently calibrates the final value. The source patches and Wasm receipts are archived here.

Each version runs one cold and three warm samples per subject (eight runs); all outputs must match the unprofiled reference and all three warm absolute spans must be exact. Region deltas include reserved capacity and are not RSS. Never add inclusive worker-group/execute totals to their children. Diagnostic walls do not enter promotion statistics. The after driver refuses to run before the complete 132-sample comparison and rechecks current candidate source/image authority.

The retained negative-control source replaces only the optimized adapter with the portable byte-wise reference. Its long-name allocation test must fail after compiling successfully; failure to build or an unrelated test failure is not detecting evidence. Positive tests overwrite the original wire before re-encoding every decoded field and cover arbitrary raw bytes, bounds, nested string groups and owned buffers.

The final implementation still requires release-check, normal hooks and exact-head CI/review completion. None of these measurements enables native threads, target-RC0 worker selfbuild, seed publication or a default change.

Patch artifacts are stored as gzip files to retain their exact context lines and original bytes. The raw record binds both compressed and uncompressed SHA-256 values; decompression preserves the measured patch without whitespace normalization.
